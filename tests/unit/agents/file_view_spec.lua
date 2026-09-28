-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.file_view", function()
  local file_view, float, transcript
  local disk, shown

  ---One hunk in the CLI's shape.
  local function hunk(new_start, lines)
    return { oldStart = new_start, oldLines = 0, newStart = new_start, newLines = 0, lines = lines }
  end

  ---Stand in for unified.nvim. Records what it was asked to diff against, which
  ---is the only thing this module owes it.
  local function install_unified()
    package.loaded["unified.diff"] = {
      show_against_text = function(buf, old_text)
        shown[#shown + 1] = { buf = buf, old_text = old_text }
        vim.b[buf] = vim.b[buf] or {}
        vim.b[buf].unified_hunks = { 2 }
        return true
      end,
    }
  end

  ---What `file_history` will answer with, per file.
  local histories

  local function open(opts)
    local win, called = nil, false
    file_view.open(opts, function(w)
      win, called = w, true
    end)
    assert.is_true(called, "file_view.open() did not answer")
    return win
  end

  ---The buffer a float was opened with, and its lines.
  local function float_buf()
    local list = float.list()
    local entry = list[#list]
    return entry and entry.buf or nil, entry and entry.title or nil
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    disk, shown, histories = {}, {}, {}

    package.loaded["unified.diff"] = nil
    package.loaded["claudecode.agents.float"] = nil
    package.loaded["claudecode.agents.transcript"] = nil
    package.loaded["claudecode.agents.file_view"] = nil

    float = require("claudecode.agents.float")
    float.reset()
    transcript = require("claudecode.agents.transcript")
    transcript.file_history = function(_path, file, cb)
      cb(histories[file])
    end

    file_view = require("claudecode.agents.file_view")
    file_view._io = {
      read_lines = function(path)
        return disk[path]
      end,
    }
  end)

  after_each(function()
    package.loaded["unified.diff"] = nil
    package.loaded["claudecode.agents.transcript"] = nil
  end)

  it("diffs the file against what the session started from", function()
    install_unified()
    disk["/proj/a.lua"] = { "one", "TWO", "three" }
    histories["/proj/a.lua"] = { hunks = { hunk(2, { "-two", "+TWO" }) }, created = false, reads = {} }

    local win = open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
    expect(win).not_to_be_nil()
    expect(#shown).to_be(1)
    -- The baseline is the file with the session's edit undone, not the file itself.
    -- It ends in a newline, as unified.nvim reads the buffer's own text: without
    -- one every diff marked the file's last line changed.
    expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
  end)

  it("shows every edit to a tab-indented file, not only those without a tab", function()
    -- The CLI writes tabs in a patch as two spaces. Matched verbatim, the tabbed
    -- hunk never located and the float showed only the other change.
    install_unified()
    disk["/proj/a.gd"] = { "func a():", "\tTWO", "ONE" }
    histories["/proj/a.gd"] = {
      hunks = { hunk(3, { "-one", "+ONE" }), hunk(1, { " func a():", "-  two", "+  TWO" }) },
      created = false,
      reads = {},
    }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.gd" })
    expect(shown[1].old_text).to_be("func a():\n\ttwo\none\n")
    local _, title = float_buf()
    expect(title:find("still present", 1, true)).to_be_nil()
  end)

  it("diffs a file the session created against nothing, so it reads as all new", function()
    install_unified()
    disk["/proj/new.lua"] = { "a", "b" }
    histories["/proj/new.lua"] = { hunks = {}, created = true, reads = {} }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/new.lua" })
    expect(#shown).to_be(1)
    expect(shown[1].old_text).to_be("")
  end)

  it("says how much of the session's work is still in the file", function()
    install_unified()
    disk["/proj/a.lua"] = { "one", "TWO", "three" }
    histories["/proj/a.lua"] = {
      hunks = { hunk(2, { "-two", "+TWO" }), hunk(9, { "-gone", "+ALSO GONE" }) },
      created = false,
      reads = {},
    }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
    local _, title = float_buf()
    expect(title:find("1/2 changes still present", 1, true) ~= nil).to_be_true()
  end)

  it("shows the patches themselves when nothing can be located any more", function()
    -- The file moved on entirely. Diffing it against itself would claim the
    -- session changed nothing; the record cannot be stale.
    install_unified()
    disk["/proj/a.lua"] = { "utterly", "different" }
    histories["/proj/a.lua"] = { hunks = { hunk(1, { "-one", "+ONE" }) }, created = false, reads = {} }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
    expect(#shown).to_be(0)
    local buf = float_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    expect(lines[1]).to_be("--- a//proj/a.lua")
    expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
  end)

  it("shows the patches when the file is gone from disk", function()
    install_unified()
    histories["/proj/deleted.lua"] = { hunks = { hunk(1, { "-one" }) }, created = false, reads = {} }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/deleted.lua" })
    local _, title = float_buf()
    expect(title:find("deleted", 1, true) ~= nil).to_be_true()
  end)

  it("shows the patches rather than a plain file when unified.nvim is absent", function()
    disk["/proj/a.lua"] = { "one", "TWO" }
    histories["/proj/a.lua"] = { hunks = { hunk(2, { "-two", "+TWO" }) }, created = false, reads = {} }

    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
    local buf = float_buf()
    expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
  end)

  describe("one edit at a time", function()
    ---A step in the history's shape.
    local function step(tool_id, kind, hunks, extra)
      local s = { tool_id = tool_id, kind = kind, hunks = hunks, created = false }
      for k, v in pairs(extra or {}) do
        s[k] = v
      end
      return s
    end

    ---A history built from steps, the way `file_history` folds one.
    local function history_of(steps, extra)
      local hunks = {}
      for _, s in ipairs(steps) do
        for _, h in ipairs(s.hunks) do
          hunks[#hunks + 1] = h
        end
      end
      local hist = { hunks = hunks, steps = steps, created = false, reads = {} }
      for k, v in pairs(extra or {}) do
        hist[k] = v
      end
      return hist
    end

    local function open_step(tool_id, path)
      return open({
        session_id = "s",
        transcript = "/p/a.jsonl",
        path = path or "/proj/a.lua",
        prefer = "step",
        tool_id = tool_id,
      })
    end

    it("shows that call's edit, in the file as the call left it", function()
      -- Two edits; the row for the first must not show the second.
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "THREE" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      local win = open_step("toolu_1")
      expect(win).not_to_be_nil()
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local buf, title = float_buf()
      assert.same({ "one", "TWO", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      -- No anchor in the record, so this came from today's file, and says so.
      expect(title:find("(edit 1 of 2, on disk)", 1, true) ~= nil).to_be_true()
    end)

    it("shows the last edit against the file just before it", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "THREE" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      open_step("toolu_2")
      expect(shown[1].old_text).to_be("one\nTWO\nthree\n")
      local buf, title = float_buf()
      assert.same({ "one", "TWO", "THREE" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(edit 2 of 2, on disk)", 1, true) ~= nil).to_be_true()
    end)

    it("shows the call's own patch when a later edit can no longer be undone", function()
      -- The second edit's lines were rewritten outside the session, so the file
      -- at the moment of the first cannot be rebuilt: the record is shown instead.
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "utterly different" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      open_step("toolu_1")
      expect(#shown).to_be(0)
      local buf, title = float_buf()
      expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
      expect(title:find("(edit 1 of 2, file moved on)", 1, true) ~= nil).to_be_true()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      expect(text:find("+TWO", 1, true) ~= nil).to_be_true()
      expect(text:find("+THREE", 1, true)).to_be_nil()
    end)

    it("shows the call's own patch when its own edit can no longer be located", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "gone", "three" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
      })

      open_step("toolu_1")
      expect(#shown).to_be(0)
      local _, title = float_buf()
      expect(title:find("(edit 1 of 1, file moved on)", 1, true) ~= nil).to_be_true()
    end)

    it("shows the call's own patch when the file is gone", function()
      install_unified()
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
      })

      open_step("toolu_1")
      expect(#shown).to_be(0)
      local _, title = float_buf()
      expect(title:find("(edit 1 of 1, deleted)", 1, true) ~= nil).to_be_true()
    end)

    it("takes a write's file from its own result, not from disk", function()
      -- A Write records the whole file as it left it, so later edits and outside
      -- changes do not matter.
      install_unified()
      disk["/proj/a.lua"] = { "totally", "other", "now" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_w", "write", { hunk(1, { "-x", "+a", " b" }) }, { content = "a\nb\n" }),
        step("toolu_2", "edit", { hunk(1, { "-a", "+totally" }) }),
      })

      open_step("toolu_w")
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("x\nb\n")
      local buf, title = float_buf()
      assert.same({ "a", "b" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      -- The content is the record's own, so this one is a reconstruction.
      expect(title:find("(write 1 of 2, reconstructed)", 1, true) ~= nil).to_be_true()
    end)

    it("reads a write that created the file as all new", function()
      install_unified()
      disk["/proj/new.lua"] = { "a", "b" }
      histories["/proj/new.lua"] = history_of({
        step("toolu_w", "write", {}, { content = "a\nb\n", created = true }),
      }, { created = true })

      open_step("toolu_w", "/proj/new.lua")
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("")
    end)

    it("falls back to the session's diff for a call the history has no step for", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "THREE" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      open_step("toolu_elsewhere")
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
    end)

    it("shows the call from the record when an anchor reaches it, not from disk", function()
      install_unified()
      disk["/proj/a.lua"] = { "rewritten", "entirely", "since" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\nthree\n" }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      open_step("toolu_2")
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("one\nTWO\nthree\n")
      local buf, title = float_buf()
      assert.same({ "one", "TWO", "THREE" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(edit 2 of 2, reconstructed)", 1, true) ~= nil).to_be_true()
    end)

    it("shows the patch without unified.nvim, scoped to the one call", function()
      disk["/proj/a.lua"] = { "one", "TWO", "THREE" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", "edit", { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_2", "edit", { hunk(3, { "-three", "+THREE" }) }),
      })

      open_step("toolu_2")
      local buf, title = float_buf()
      expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
      expect(title:find("(edit 2 of 2)", 1, true) ~= nil).to_be_true()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      expect(text:find("+TWO", 1, true)).to_be_nil()
      expect(text:find("+THREE", 1, true) ~= nil).to_be_true()
    end)
  end)

  describe("an era between checkpoints", function()
    local function step(tool_id, ts, hunks, extra)
      local s = { tool_id = tool_id, ts = ts, kind = "edit", hunks = hunks, created = false }
      for k, v in pairs(extra or {}) do
        s[k] = v
      end
      return s
    end

    local function history_of(steps)
      local hunks = {}
      for _, s in ipairs(steps) do
        for _, h in ipairs(s.hunks) do
          hunks[#hunks + 1] = h
        end
      end
      return { hunks = hunks, steps = steps, created = false, reads = {} }
    end

    local function open_era(era)
      return open({
        session_id = "s",
        transcript = "/p/a.jsonl",
        path = "/proj/a.lua",
        era = era,
      })
    end

    before_each(function()
      install_unified()
      -- Three edits; a checkpoint between the second and the third.
      disk["/proj/a.lua"] = { "ONE", "TWO", "THREE" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", 10, { hunk(1, { "-one", "+ONE" }) }),
        step("toolu_2", 20, { hunk(2, { "-two", "+TWO" }) }),
        step("toolu_3", 30, { hunk(3, { "-three", "+THREE" }) }),
      })
    end)

    it("shows the edits before the checkpoint as one diff, the later one undone", function()
      local win = open_era({ to = 25, note = "until 14:32" })
      expect(win).not_to_be_nil()
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local buf, title = float_buf()
      assert.same({ "ONE", "TWO", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(until 14:32, on disk)", 1, true) ~= nil).to_be_true()
    end)

    it("shows what changed since the checkpoint against the file as it stood then", function()
      open_era({ from = 25, note = "since 14:32" })
      expect(shown[1].old_text).to_be("ONE\nTWO\nthree\n")
      local buf, title = float_buf()
      assert.same({ "ONE", "TWO", "THREE" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(since 14:32, on disk)", 1, true) ~= nil).to_be_true()
    end)

    it("takes an era between two checkpoints", function()
      open_era({ from = 15, to = 25, note = "14:00 – 14:32" })
      expect(shown[1].old_text).to_be("ONE\ntwo\nthree\n")
      local buf = float_buf()
      assert.same({ "ONE", "TWO", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("takes both sides from the record when an anchor reaches them", function()
      histories["/proj/a.lua"].steps[1].before = "one\ntwo\nthree\n"
      disk["/proj/a.lua"] = { "utterly", "different" }
      open_era({ to = 25, note = "until 14:32" })
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local buf, title = float_buf()
      assert.same({ "ONE", "TWO", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(until 14:32, reconstructed)", 1, true) ~= nil).to_be_true()
    end)

    it("shows the era's own patches when the file has moved on", function()
      disk["/proj/a.lua"] = { "utterly", "different", "file" }
      open_era({ to = 25, note = "until 14:32" })
      expect(#shown).to_be(0)
      local buf, title = float_buf()
      expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
      expect(title:find("file moved on", 1, true) ~= nil).to_be_true()
      -- Only the era's two hunks, not the third.
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      expect(text:find("+TWO", 1, true) ~= nil).to_be_true()
      expect(text:find("+THREE", 1, true)).to_be_nil()
    end)

    it("says so when the era left the file as it found it", function()
      local notified = {}
      local notify = vim.notify
      vim.notify = function(msg)
        notified[#notified + 1] = msg
      end
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", 10, { hunk(1, { "-one", "+ONE" }) }),
        step("toolu_2", 20, { hunk(1, { "-ONE", "+one" }) }),
      })
      disk["/proj/a.lua"] = { "one", "two", "three" }
      local win = open_era({ to = 25, note = "until 14:32" })
      vim.notify = notify
      expect(win).to_be(nil)
      expect(#shown).to_be(0)
      expect(notified[1]:find("left as it was found", 1, true) ~= nil).to_be_true()
    end)

    it("falls back to the session's whole diff for an era with no edit in it", function()
      open_era({ from = 100, note = "since 15:00" })
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
    end)
  end)

  describe("the session's changes, from the record", function()
    local function step(tool_id, hunks, extra)
      local s = { tool_id = tool_id, kind = "edit", hunks = hunks, created = false }
      for k, v in pairs(extra or {}) do
        s[k] = v
      end
      return s
    end
    local function history_of(steps, extra)
      local hunks = {}
      for _, s in ipairs(steps) do
        for _, h in ipairs(s.hunks) do
          hunks[#hunks + 1] = h
        end
      end
      local hist = { hunks = hunks, steps = steps, created = false, reads = {} }
      for k, v in pairs(extra or {}) do
        hist[k] = v
      end
      return hist
    end

    it("diffs the file the session found against the file it left, whatever is on disk now", function()
      -- The file has moved on entirely since; the record still knows both sides.
      install_unified()
      disk["/proj/a.lua"] = { "rewritten", "since" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", { hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\nthree\n" }),
        step("toolu_2", { hunk(3, { "-three", "+THREE" }) }),
      })

      open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local buf, title = float_buf()
      assert.same({ "one", "TWO", "THREE" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      expect(title:find("(session changes, reconstructed)", 1, true) ~= nil).to_be_true()
    end)

    it("anchors on a whole read after the last edit", function()
      install_unified()
      disk["/proj/a.lua"] = { "rewritten" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", { hunk(2, { "-two", "+TWO" }) }),
      }, { read_anchor = { step = 1, content = "one\nTWO\n" } })

      open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      expect(shown[1].old_text).to_be("one\ntwo\n")
    end)

    it("says so rather than opening an empty diff when the session left the file as it found it", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "two" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", { hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\n" }),
        step("toolu_2", { hunk(2, { "-TWO", "+two" }) }),
      })
      local notes = {}
      local notify = vim.notify
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end
      local win = open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      vim.notify = notify
      expect(win).to_be_nil()
      expect(#shown).to_be(0)
      expect(notes[1]:find("as it found it", 1, true) ~= nil).to_be_true()
    end)

    it("falls back to today's file when the record holds no anchor, and says so", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "three" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", { hunk(2, { "-two", "+TWO" }) }),
      })

      open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local _, title = float_buf()
      expect(title:find("(on disk)", 1, true) ~= nil).to_be_true()
    end)

    it("falls back to today's file when an outside edit broke the chain and nothing re-anchors it", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "utterly different" }
      histories["/proj/a.lua"] = history_of({
        step("toolu_1", { hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\nthree\n" }),
        step("toolu_2", { hunk(3, { "-gone", "+THREE" }) }),
      })

      open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      local _, title = float_buf()
      expect(title:find("(on disk, 1/2 changes still present)", 1, true) ~= nil).to_be_true()
    end)
  end)

  it("highlights the lines an activity read covered", function()
    disk["/proj/a.lua"] = { "1", "2", "3", "4", "5" }
    open({
      session_id = "s",
      transcript = "/p/a.jsonl",
      path = "/proj/a.lua",
      read = { start_line = 2, num_lines = 3 },
      prefer = "read",
    })
    local buf, title = float_buf()
    expect(title:find("(read)", 1, true) ~= nil).to_be_true()
    local rows = {}
    for _, mark in ipairs(vim._extmarks or {}) do
      if mark.bufnr == buf then
        rows[#rows + 1] = mark.row
      end
    end
    expect(#rows).to_be(3) -- lines 2, 3 and 4
    expect(rows[1]).to_be(1)
  end)

  it("marks every window a read-only file was read through", function()
    disk["/proj/r.lua"] = { "1", "2", "3", "4", "5" }
    histories["/proj/r.lua"] = {
      hunks = {},
      created = false,
      reads = { { start_line = 1, num_lines = 1 }, { start_line = 4, num_lines = 2 } },
    }

    local buf
    open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/r.lua" })
    buf = float_buf()
    local rows = 0
    for _, mark in ipairs(vim._extmarks or {}) do
      if mark.bufnr == buf then
        rows = rows + 1
      end
    end
    expect(rows).to_be(3) -- line 1, plus lines 4 and 5
  end)

  it("opens plainly when there is no history to show", function()
    disk["/proj/a.lua"] = { "one" }
    open({ session_id = "s", path = "/proj/a.lua" })
    expect(float.count()).to_be(1)
  end)

  describe("naming the file in the title", function()
    it("shows where the file is, relative to the directory the session ran in", function()
      -- The tail alone does not say which `init.lua` this is, and the project
      -- prefix every file shares says nothing.
      disk["/proj/lua/agents/init.lua"] = { "one" }
      open({ session_id = "s", path = "/proj/lua/agents/init.lua", cwd = "/proj" })
      local _, title = float_buf()
      expect(title).to_be("lua/agents/init.lua")
    end)

    it("shows a file outside that directory as a path, not as a bare name", function()
      local home = os.getenv("HOME") or "/home/u"
      local path = home .. "/.config/nvim/init.lua"
      disk[path] = { "one" }
      open({ session_id = "s", path = path, cwd = "/proj" })
      local _, title = float_buf()
      expect(title).to_be("~/.config/nvim/init.lua")
    end)

    it("cuts a path too long for the border from the inside, keeping the filename", function()
      -- Neovim would cut the title at its right edge, throwing away the one part
      -- the title is there for.
      local columns = vim.o.columns
      vim.o.columns = 40
      local path = "/proj/lua/claudecode/agents/deeply/nested/file_view.lua"
      disk[path] = { "one" }
      open({ session_id = "s", path = path, cwd = "/proj" })
      vim.o.columns = columns

      local _, title = float_buf()
      expect(title:find("…", 1, true) ~= nil).to_be_true()
      expect(title:sub(-13)).to_be("file_view.lua")
      expect(vim.fn.strdisplaywidth(title) <= 22).to_be_true()
    end)

    it("keeps the note beside the path", function()
      disk["/proj/lua/a.lua"] = { "1", "2", "3" }
      open({
        session_id = "s",
        transcript = "/p/a.jsonl",
        path = "/proj/lua/a.lua",
        read = { start_line = 1, num_lines = 2 },
        prefer = "read",
        cwd = "/proj",
      })
      local _, title = float_buf()
      expect(title).to_be("lua/a.lua  (read)")
    end)
  end)

  describe("against git HEAD", function()
    local git

    ---Answer for `git show HEAD:<file>`; nil means the file is not in HEAD.
    local head
    ---What the reader says it read; nil answers the way a git repository does.
    local info
    local notified

    local function open_head(path)
      local win, called = nil, false
      file_view.open_against_head({ session_id = "s", path = path }, function(w)
        win, called = w, true
      end)
      assert.is_true(called, "open_against_head() did not answer")
      return win
    end

    local notify

    before_each(function()
      head, info, notified = {}, nil, {}
      package.loaded["claudecode.agents.git"] = nil
      git = require("claudecode.agents.git")
      git._set_head_reader(function(path, cb)
        cb(head[path], info)
      end)
      notify = vim.notify
      vim.notify = function(msg)
        notified[#notified + 1] = msg
      end
    end)

    after_each(function()
      vim.notify = notify
      git._set_head_reader(nil)
      package.loaded["claudecode.agents.git"] = nil
    end)

    it("diffs the working tree against HEAD, not against the session", function()
      -- The neighbouring question to <CR>: everything uncommitted in this file,
      -- whichever agent (or hand) put it there.
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "three" }
      head["/proj/a.lua"] = { "one", "two", "three" }

      local win = open_head("/proj/a.lua")
      expect(win).not_to_be_nil()
      expect(#shown).to_be(1)
      expect(shown[1].old_text).to_be("one\ntwo\nthree\n")
      local _, title = float_buf()
      expect(title:find("vs HEAD", 1, true) ~= nil).to_be_true()
    end)

    describe("in an svn working copy", function()
      before_each(function()
        info = { vcs = "svn", rev = "BASE" }
      end)

      it("diffs against BASE, and says so", function()
        install_unified()
        disk["/proj/a.lua"] = { "one", "TWO" }
        head["/proj/a.lua"] = { "one", "two" }

        expect(open_head("/proj/a.lua")).not_to_be_nil()
        expect(shown[1].old_text).to_be("one\ntwo\n")
        local _, title = float_buf()
        expect(title:find("vs BASE", 1, true) ~= nil).to_be_true()
      end)

      it("reads a file svn has no BASE for as all new", function()
        install_unified()
        disk["/proj/new.lua"] = { "a" }

        open_head("/proj/new.lua")
        local _, title = float_buf()
        expect(title:find("new since BASE", 1, true) ~= nil).to_be_true()
      end)

      it("names BASE in the text diff's header", function()
        disk["/proj/a.lua"] = { "one", "TWO" }
        head["/proj/a.lua"] = { "one", "two" }

        open_head("/proj/a.lua")
        local lines = vim.api.nvim_buf_get_lines(float_buf(), 0, -1, false)
        expect(lines[1]:find("(BASE)", 1, true) ~= nil).to_be_true()
      end)
    end)

    it("says a file is not versioned rather than showing every line as new", function()
      -- Previously any failure read as "not in HEAD", so a file outside every
      -- repository opened as one long addition.
      install_unified()
      info = { vcs = "git", rev = "HEAD", unversioned = true }
      disk["/proj/a.lua"] = { "one" }

      expect(open_head("/proj/a.lua")).to_be_nil()
      expect(#shown).to_be(0)
      expect(notified[1]:find("not in a git or svn working copy", 1, true) ~= nil).to_be_true()
    end)

    it("says the command could not run rather than showing every line as new", function()
      install_unified()
      info = { vcs = "svn", rev = "BASE", failed = true }
      disk["/proj/a.lua"] = { "one" }

      expect(open_head("/proj/a.lua")).to_be_nil()
      expect(notified[1]:find("could not run svn", 1, true) ~= nil).to_be_true()
    end)

    it("reads a file that is not in HEAD as all new", function()
      install_unified()
      disk["/proj/new.lua"] = { "a", "b" }

      open_head("/proj/new.lua")
      expect(shown[1].old_text).to_be("")
      local _, title = float_buf()
      expect(title:find("new since HEAD", 1, true) ~= nil).to_be_true()
    end)

    it("says so rather than opening an empty diff when the file matches HEAD", function()
      install_unified()
      disk["/proj/a.lua"] = { "one", "two" }
      head["/proj/a.lua"] = { "one", "two" }

      expect(open_head("/proj/a.lua")).to_be_nil()
      expect(float.count()).to_be(0)
    end)

    it("shows a deleted file as everything HEAD held, removed", function()
      install_unified()
      head["/proj/gone.lua"] = { "one", "two" }

      expect(open_head("/proj/gone.lua")).not_to_be_nil()
      -- Never the inline renderer: that needs a buffer on the missing path.
      expect(#shown).to_be(0)
      local lines = vim.api.nvim_buf_get_lines(float_buf(), 0, -1, false)
      local removed, added = 0, 0
      for _, line in ipairs(lines) do
        if line:match("^%-[^%-]") then
          removed = removed + 1
        elseif line:match("^%+[^%+]") or line == "+" then
          added = added + 1
        end
      end
      expect(removed).to_be(2)
      expect(added).to_be(0)
    end)

    it("opens nothing for a file that is neither on disk nor in HEAD", function()
      expect(open_head("/proj/gone.lua")).to_be_nil()
      expect(float.count()).to_be(0)
    end)

    it("falls back to diff text without unified.nvim", function()
      -- vim.diff is a built-in, so the answer stays a diff either way.
      disk["/proj/a.lua"] = { "one", "TWO" }
      head["/proj/a.lua"] = { "one", "two" }

      expect(open_head("/proj/a.lua")).not_to_be_nil()
      expect(#shown).to_be(0)
      local buf = float_buf()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      expect(lines[1]:find("(HEAD)", 1, true) ~= nil).to_be_true()
      expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
    end)
  end)

  describe("a key that edits", function()
    -- A float is a reading frame, not modifiable; reaching for `o` or `dd` while
    -- reading a diff used to answer E21. Now it opens the file in a new tab, on
    -- the same line, closes the float and types the key there.
    local fed, real

    ---The buffer-local mapping for `lhs` in `mode` on a buffer, or nil.
    local function map_of(buf, mode, lhs)
      local per_buf = vim._buf_keymaps[buf] and vim._buf_keymaps[buf][mode]
      return per_buf and per_buf[lhs] or nil
    end

    local function press(buf, lhs, mode)
      local map = map_of(buf, mode or "n", lhs)
      assert.is_not_nil(map, "no " .. (mode or "n") .. " mapping for " .. lhs)
      map.rhs()
    end

    before_each(function()
      fed = {}
      real = {
        filereadable = vim.fn.filereadable,
        maparg = vim.fn.maparg,
        feedkeys = vim.api.nvim_feedkeys,
        termcodes = vim.api.nvim_replace_termcodes,
        count = vim.v.count,
        register = vim.v.register,
        clipboard = vim.o.clipboard,
      }
      vim.fn.filereadable = function(path)
        return disk[path] and 1 or 0
      end
      vim.api.nvim_feedkeys = function(keys, mode)
        fed[#fed + 1] = { keys = keys, mode = mode }
      end
      vim.api.nvim_replace_termcodes = function(keys)
        return keys
      end
      vim.v.count, vim.v.register, vim.o.clipboard = 0, '"', ""
      vim._last_command = nil
    end)

    after_each(function()
      vim.fn.filereadable = real.filereadable
      vim.fn.maparg = real.maparg
      vim.api.nvim_feedkeys = real.feedkeys
      vim.api.nvim_replace_termcodes = real.termcodes
      vim.v.count, vim.v.register, vim.o.clipboard = real.count, real.register, real.clipboard
    end)

    ---A session diff of `/proj/a.lua`, open in a float; its buffer.
    local function open_diff()
      install_unified()
      disk["/proj/a.lua"] = { "one", "TWO", "three" }
      histories["/proj/a.lua"] = { hunks = { hunk(2, { "-two", "+TWO" }) }, created = false, reads = {} }
      local win = open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      return (vim.api.nvim_win_get_buf(win)), win
    end

    it("opens the file in a new tab, closes the float and types the key there", function()
      local buf, win = open_diff()
      vim.api.nvim_win_set_cursor(win, { 2, 1 })

      press(buf, "o")
      expect(float.count()).to_be(0)
      expect(vim._last_command).to_be("tabnew /proj/a.lua")
      -- At the front of typeahead, remapped: whatever was typed after the key
      -- (the `iw` of a quick `ciw`) must follow it, not precede it.
      expect(#fed).to_be(1)
      expect(fed[1].keys).to_be("o")
      expect(fed[1].mode).to_be("mi")
    end)

    it("binds an operator alone, so what follows it completes in the file", function()
      local buf = open_diff()
      expect(map_of(buf, "n", "d")).not_to_be_nil()
      expect(map_of(buf, "n", "d").opts.nowait).to_be_true()
      expect(map_of(buf, "n", "dd")).to_be_nil()
      expect(map_of(buf, "x", "d")).not_to_be_nil()
      -- Reading keys stay what they are.
      expect(map_of(buf, "n", "y")).to_be_nil()
      expect(map_of(buf, "n", "u")).to_be_nil()
      expect(map_of(buf, "n", ".")).to_be_nil()
    end)

    it("types the count and register again", function()
      local buf = open_diff()
      vim.v.count, vim.v.register = 3, "a"
      press(buf, "d")
      expect(fed[1].keys).to_be('"a3d')
    end)

    it("leaves out the register a plain key would use anyway", function()
      expect(file_view._key_prefix(0, '"')).to_be("")
      vim.o.clipboard = "unnamedplus"
      expect(file_view._key_prefix(2, "+")).to_be("2")
      expect(file_view._key_prefix(0, '"')).to_be('""')
    end)

    it("does nothing when the file is gone from disk", function()
      local buf = open_diff()
      disk["/proj/a.lua"] = nil
      vim._last_command = nil
      press(buf, "i")
      expect(float.count()).to_be(1)
      expect(vim._last_command).to_be_nil()
      expect(#fed).to_be(0)
    end)

    it("leaves a key the user mapped alone", function()
      -- flash, leap and sneak put a jump on `s`; a reading float is where one is wanted.
      vim.fn.maparg = function(lhs)
        if lhs == "s" or lhs == "gc" then
          return { lhs = lhs }
        end
        return {}
      end
      local buf = open_diff()
      expect(map_of(buf, "n", "s")).to_be_nil()
      expect(map_of(buf, "n", "x")).not_to_be_nil()
      -- A comment toggle is an edit under every mapping anyone gives it.
      expect(map_of(buf, "n", "gc")).not_to_be_nil()
    end)

    it("reselects a visual selection in the file before typing the key", function()
      local buf, win = open_diff()
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      local real_mode, real_getpos = vim.fn.mode, vim.fn.getpos
      vim.fn.mode = function()
        return "V"
      end
      vim.fn.getpos = function()
        return { 0, 1, 1, 0 }
      end
      press(buf, "d", "x")
      vim.fn.mode, vim.fn.getpos = real_mode, real_getpos

      expect(vim._last_command).to_be("tabnew /proj/a.lua")
      -- Fed in reverse, each at the front: the selection runs first.
      expect(#fed).to_be(2)
      expect(fed[1].keys).to_be("d")
      expect(fed[2].keys).to_be("V<Cmd>call cursor(3, 1)<CR>")
      expect(fed[2].mode).to_be("ni")
    end)

    it("is bound on a patch shown as text too", function()
      disk["/proj/a.lua"] = { "one", "TWO" }
      histories["/proj/a.lua"] = { hunks = { hunk(2, { "-two", "+TWO" }) }, created = false, reads = {} }
      open({ session_id = "s", transcript = "/p/a.jsonl", path = "/proj/a.lua" })
      local buf = float_buf()
      expect(vim.api.nvim_buf_get_option(buf, "filetype")).to_be("diff")
      expect(map_of(buf, "n", "o")).not_to_be_nil()
    end)

    describe("where the cursor lands", function()
      it("moves a line by what was added above it since", function()
        -- `vim.diff` indices: two lines added at the top.
        expect(file_view._map_line({ { 0, 0, 1, 2 } }, 3, 6)).to_be(5)
      end)

      it("puts a changed line on its counterpart", function()
        -- "b" (line 2) became "B", "B2".
        local hunks = { { 2, 1, 2, 2 } }
        expect(file_view._map_line(hunks, 2, 4)).to_be(2)
        expect(file_view._map_line(hunks, 3, 4)).to_be(4)
      end)

      it("puts a deleted line where it was", function()
        -- Lines 2-3 removed; line 1 of the new file is what precedes them.
        expect(file_view._map_line({ { 2, 2, 1, 0 } }, 3, 3)).to_be(2)
        expect(file_view._map_line({ { 2, 2, 1, 0 } }, 4, 3)).to_be(2)
      end)

      it("reads a patch line for the new file's line and text", function()
        local lines = { "--- a/x", "+++ b/x", "@@ -4,3 +4,3 @@", " four", "-five", "+FIVE", " six" }
        expect(file_view._patch_line(lines, 4)).to_be(4)
        local line, text = file_view._patch_line(lines, 6)
        expect(line).to_be(5)
        expect(text).to_be("FIVE")
        line, text = file_view._patch_line(lines, 5)
        expect(line).to_be(5)
        expect(text).to_be_nil()
        -- The file headers: the first hunk.
        expect(file_view._patch_line(lines, 1)).to_be(4)
      end)

      it("finds a patch line by its text, tabs written as two spaces", function()
        -- The patch is older than the file: three lines were added above since.
        local patch_lines = { "@@ -1,2 +1,2 @@", " func a():", "+  TWO" }
        local disk_lines = { "x", "y", "z", "func a():", "\tTWO" }
        local at = file_view._disk_position(patch_lines, disk_lines, "patch", 3, 3)
        expect(at.line).to_be(5)
        -- Not the same bytes, so the column is the line's indent rather than a guess.
        expect(at.col).to_be(1)
      end)
    end)
  end)
end)
