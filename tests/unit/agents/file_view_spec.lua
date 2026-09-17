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
end)
