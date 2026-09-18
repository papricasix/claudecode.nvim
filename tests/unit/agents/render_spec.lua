-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.render", function()
  local render
  local buf

  local function lines_of(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.render"] = nil
    render = require("claudecode.agents.render")
    render.setup({ agents = { enabled = true } })
    render.reset()
    buf = render.create_buf("sessions")
  end)

  describe("buffers", function()
    it("creates a read-only scratch buffer", function()
      expect(type(buf)).to_be("number")
      expect(vim.api.nvim_buf_get_option(buf, "buftype")).to_be("nofile")
      expect(vim.api.nvim_buf_get_option(buf, "modifiable")).to_be(false)
      expect(vim.api.nvim_buf_get_option(buf, "swapfile") ~= true).to_be_true()
    end)

    it("keeps no undo history, so polled repaints cannot accumulate", function()
      expect(vim.api.nvim_buf_get_option(buf, "undolevels")).to_be(-1)
    end)
  end)

  describe("paint", function()
    local writes, set_lines

    before_each(function()
      writes = 0
      set_lines = vim.api.nvim_buf_set_lines
      vim.api.nvim_buf_set_lines = function(...)
        writes = writes + 1
        return set_lines(...)
      end
    end)

    after_each(function()
      vim.api.nvim_buf_set_lines = set_lines
    end)

    local function marks_for(hl)
      return { { row = 0, col = 0, end_col = 1, hl = hl } }
    end

    it("switches undo off on buffers it did not create", function()
      local other = vim.api.nvim_create_buf(false, true)
      render.paint(other, { "x" }, {})
      expect(vim.api.nvim_buf_get_option(other, "undolevels")).to_be(-1)
    end)

    it("skips a repaint that would change nothing", function()
      render.paint(buf, { "a", "b" }, marks_for("Comment"))
      render.paint(buf, { "a", "b" }, marks_for("Comment"))
      expect(writes).to_be(1)
    end)

    it("repaints when a line or a mark changed", function()
      render.paint(buf, { "a", "b" }, marks_for("Comment"))
      render.paint(buf, { "a", "c" }, marks_for("Comment"))
      render.paint(buf, { "a", "c" }, marks_for("String"))
      expect(writes).to_be(3)
    end)

    it("repaints when a caller mutated and re-passed the same tables", function()
      local lines, marks = { "a" }, marks_for("Comment")
      render.paint(buf, lines, marks)
      lines[1] = "b"
      marks[1].hl = "String"
      render.paint(buf, lines, marks)
      expect(writes).to_be(2)
    end)

    it("repaints a buffer something else wrote to since", function()
      render.paint(buf, { "a" }, {})
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "scribbled" })
      render.paint(buf, { "a" }, {})
      expect(writes).to_be(3)
      expect(lines_of(buf)[1]).to_be("a")
    end)

    it("still updates the row payloads on a skipped paint", function()
      render.paint(buf, { "a" }, {}, { { id = 1 } })
      render.paint(buf, { "a" }, {}, { { id = 2 } })
      expect(render.payload_at(buf, 1).id).to_be(2)
    end)

    it("repaints after forget", function()
      render.paint(buf, { "a" }, {})
      render.forget(buf)
      render.paint(buf, { "a" }, {})
      expect(writes).to_be(2)
    end)
  end)

  describe("terminal background", function()
    it("paints Normal, NormalNC and the filler below the last line", function()
      -- Without EndOfBuffer the area under the last line of output keeps the
      -- editor background and the pane looks half-painted.
      local wh = render.terminal_winhighlight()
      expect(wh:find("Normal:ClaudeCodeAgentsNormal", 1, true) ~= nil).to_be_true()
      expect(wh:find("NormalNC:ClaudeCodeAgentsNormalNC", 1, true) ~= nil).to_be_true()
      expect(wh:find("EndOfBuffer:ClaudeCodeAgentsNormal", 1, true) ~= nil).to_be_true()
    end)

    it("falls back to NormalFloat when snacks is absent", function()
      -- Which is what SnacksNormal resolves to anyway, so the fallback looks the
      -- same rather than merely being safe.
      local defined = (vim._highlights or {})["ClaudeCodeAgentsNormal"]
      expect(defined).not_to_be_nil()
      expect(defined.link).to_be("NormalFloat")
      expect(defined.default).to_be_true() -- a colorscheme still gets the last word
    end)

    it("lets the user point the terminal somewhere else", function()
      render.setup({ agents = { highlights = { normal = "MyOwnGroup" } } })
      expect(render.terminal_winhighlight():find("Normal:MyOwnGroup", 1, true) ~= nil).to_be_true()
    end)
  end)

  describe("relative time", function()
    local now = 1785700000

    it("reads as a compact age", function()
      expect(render.rel_time(now, now)).to_be("now")
      expect(render.rel_time(now - 30, now)).to_be("now")
      expect(render.rel_time(now - 120, now)).to_be("2m")
      expect(render.rel_time(now - 7200, now)).to_be("2h")
      expect(render.rel_time(now - 86400 * 3, now)).to_be("3d")
      expect(render.rel_time(now - 86400 * 90, now)).to_be("3mo")
    end)

    it("is empty when nothing is known", function()
      expect(render.rel_time(0, now)).to_be("")
      expect(render.rel_time(nil, now)).to_be("")
    end)
  end)

  describe("paths", function()
    it("shows a path relative to the session's own directory", function()
      -- The session's cwd, not Neovim's: an agent may be running elsewhere.
      expect(render.relative_path("/proj/lua/a.lua", "/proj")).to_be("lua/a.lua")
      expect(render.relative_path("/proj/lua/a.lua", "/proj/")).to_be("lua/a.lua")
      expect(render.relative_path("/other/a.lua", "/proj")).to_be("/other/a.lua")
      expect(render.relative_path("/proj/a.lua", nil)).to_be("/proj/a.lua")
    end)

    it("strips the session's directory however either path spells it", function()
      -- On Windows the session's cwd is `D:\Git\proj` while the same directory
      -- can reach us as `D:/Git/proj`; neither spelling should show the row a
      -- full absolute path.
      expect(render.relative_path("D:\\Git\\proj\\lua\\a.lua", "D:\\Git\\proj")).to_be("lua\\a.lua")
      expect(render.relative_path("D:\\Git\\proj\\lua\\a.lua", "D:/Git/proj/")).to_be("lua\\a.lua")
    end)

    describe("fitting a path into a narrow pane", function()
      -- A tail cut throws away the one part the row is read for: it turned
      -- `lua/claudecode/agents/render.lua` into `lua/claudecod…`, so every file
      -- in a directory looked alike.
      local path = "lua/claudecode/agents/render.lua"

      it("leaves a path that fits alone", function()
        expect(render.shorten_path(path, 40)).to_be(path)
        expect(render.shorten_path(path, #path)).to_be(path)
      end)

      it("drops interior directories, keeping the first folder and the parent", function()
        expect(render.shorten_path(path, 28)).to_be("lua/…/agents/render.lua")
      end)

      it("gives up the parent before the first folder", function()
        -- The first folder is the coarser answer: `lua/…/init.lua` and
        -- `tests/…/init.lua` are told apart by it, while their parents are
        -- often the same word.
        expect(render.shorten_path(path, 20)).to_be("lua/…/render.lua")
      end)

      it("keeps the filename when nothing else fits", function()
        expect(render.shorten_path(path, 14)).to_be("…/render.lua")
        expect(render.shorten_path(path, 11)).to_be("render.lua")
      end)

      it("keeps the extension when even the filename must be cut", function()
        -- `render…` names no file; the extension is half of what the name says.
        expect(render.shorten_path(path, 9)).to_be("rend….lua")
        expect(render.shorten_path("aaaaaaaaaaaa.lua", 8)).to_be("aaa….lua")
      end)

      it("drops the extension only when keeping it would leave no name", function()
        expect(render.shorten_path("aaaaaaaaaaaa.lua", 5)).to_be("aaaa…")
      end)

      it("never spells a cut mark for nothing", function()
        -- Three segments: `first/…/parent/name` would be the whole path with an
        -- ellipsis in the middle of it.
        expect(render.shorten_path("lua/agents/render.lua", 20)).to_be("lua/…/render.lua")
        expect(render.shorten_path("agents/render.lua", 14)).to_be("…/render.lua")
      end)

      it("keeps the root of an absolute path outside the session's cwd", function()
        expect(render.shorten_path("/tmp/scratch/deep/notes.md", 22)).to_be("/tmp/…/deep/notes.md")
      end)

      it("says nothing when there is no room to say it", function()
        expect(render.shorten_path("a/b.lua", 0)).to_be("")
        expect(render.shorten_path(nil, 20)).to_be("")
      end)

      it("shortens a Windows path from the inside too", function()
        -- Splitting on `/` alone left one segment, so a Windows path fell
        -- through to the tail cut this exists to avoid — and every file in a
        -- directory looked alike again.
        expect(render.shorten_path("lua\\claudecode\\agents\\render.lua", 28)).to_be("lua\\…\\agents\\render.lua")
        expect(render.shorten_path("lua\\claudecode\\agents\\render.lua", 14)).to_be("…\\render.lua")
      end)

      it("keeps a drive with the folder it names", function()
        -- `D:` alone is not the coarse "where in the project" answer a first
        -- segment is picked for.
        expect(render.shorten_path("D:\\proj\\lua\\claudecode\\agents\\a.lua", 22)).to_be(
          "D:\\proj\\…\\agents\\a.lua"
        )
      end)
    end)
  end)

  describe("sessions pane", function()
    local rows = {
      {
        session_id = "aaaa1111",
        title = "Fix session restoration",
        last_ts = 1785700000,
        added = 90,
        removed = 5,
        icon = "✳",
        hl = "ClaudeCodeStatusBusy",
        selected = true,
      },
      {
        session_id = "bbbb2222",
        title = "Expose tab status API",
        last_ts = 1785690000,
        added = 865,
        removed = 100,
        icon = "○",
      },
    }

    it("draws one line per session with its counts", function()
      render.sessions(buf, rows, { width = 60, now = 1785700000 })
      local lines = lines_of(buf)
      expect(#lines).to_be(2)
      expect(lines[1]:find("Fix session restoration", 1, true) ~= nil).to_be_true()
      expect(lines[1]:find("+90", 1, true) ~= nil).to_be_true()
      expect(lines[1]:find("-5", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("+865", 1, true) ~= nil).to_be_true()
    end)

    it("shows placeholders while the counts are still unknown", function()
      -- The list paints before any transcript is folded; empty cells would read
      -- as "this session changed nothing", which is a different claim.
      render.sessions(buf, { { session_id = "cccc", title = "Unfolded" } }, { width = 40 })
      expect(lines_of(buf)[1]:find("+·", 1, true) ~= nil).to_be_true()
    end)

    it("records which session each line refers to", function()
      render.sessions(buf, rows, { width = 40 })
      expect(render.payload_at(buf, 1).session_id).to_be("aaaa1111")
      expect(render.payload_at(buf, 2).session_id).to_be("bbbb2222")
      expect(render.payload_at(buf, 3)).to_be(nil)
    end)

    it("marks the selected row so it stays visible from another pane", function()
      render.sessions(buf, rows, { width = 40 })
      local band = nil
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == buf and mark.opts and mark.opts.hl_group == "ClaudeCodeAgentsSelected" then
          band = mark
        end
      end
      expect(band).not_to_be_nil()
      expect(band.row).to_be(0)
      expect(band.col).to_be(0)
    end)

    it("leaves the selected row's counts their own colour", function()
      -- The band used to be a `line_hl_group`, which composes *over* the
      -- background of every character highlight on its line whatever the
      -- priorities say — so the selected row's `+N`/`-N` lost the coloured
      -- blocks that are the point of them, on the one row you most want to read
      -- them. It stops where the counts start instead.
      render.sessions(buf, rows, { width = 40 })
      local line = lines_of(buf)[1]
      local counts_at = line:find("+90", 1, true) - 1

      local band, count_spans = nil, {}
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == buf and mark.row == 0 and mark.opts then
          if mark.opts.hl_group == "ClaudeCodeAgentsSelected" then
            band = mark
          elseif mark.opts.hl_group == "ClaudeCodeAgentsAdded" or mark.opts.hl_group == "ClaudeCodeAgentsRemoved" then
            count_spans[#count_spans + 1] = mark
          end
        end
      end

      expect(band).not_to_be_nil()
      -- No line highlight anywhere: that is the mechanism, not a detail.
      for _, mark in ipairs(vim._extmarks or {}) do
        expect(mark.opts and mark.opts.line_hl_group).to_be_nil()
      end
      expect(band.opts.end_col <= counts_at).to_be_true()
      expect(#count_spans >= 2).to_be_true()
      for _, span in ipairs(count_spans) do
        expect(span.col >= band.opts.end_col).to_be_true()
      end
    end)

    it("says so when there is nothing to list", function()
      render.sessions(buf, {}, { width = 40 })
      expect(lines_of(buf)[1]:find("no sessions", 1, true) ~= nil).to_be_true()
    end)
  end)

  describe("activity pane", function()
    it("draws one line per event, without any file contents", function()
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1785700000, kind = "read", path = "/proj/a.lua", added = 0, removed = 0 },
        { ts = 1785700060, kind = "edit", path = "/proj/b.lua", added = 12, removed = 3 },
        { ts = 1785700120, kind = "add", path = "/proj/c.lua", added = 40, removed = 0 },
      }, { width = 40, cwd = "/proj" })

      local lines = lines_of(feed)
      expect(#lines).to_be(3)
      expect(lines[1]:find("read", 1, true) ~= nil).to_be_true()
      expect(lines[1]:find("a.lua", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("edit", 1, true) ~= nil).to_be_true()
      expect(lines[3]:find("added", 1, true) ~= nil).to_be_true()
    end)

    it("gives every span of a row a group, so the fade can reach all of them", function()
      -- The read/edit column had none, so it fell through to `Normal` — the
      -- brightest thing in the pane and the one span dimming could not touch,
      -- leaving a settled row with a white label on it.
      local feed = render.create_buf("feed")
      render.feed(feed, { { ts = 1785700000, kind = "read", path = "/proj/a.lua" } }, { width = 40, cwd = "/proj" })
      local line = lines_of(feed)[1]
      local groups = {}
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == feed and mark.row == 0 and mark.opts.end_col then
          groups[line:sub(mark.col + 1, mark.opts.end_col)] = mark.opts.hl_group
        end
      end
      expect(groups["read"]).to_be("ClaudeCodeAgentsKind")
      expect(groups["a.lua"]).to_be("ClaudeCodeAgentsPath")
    end)

    it("records the file each row refers to", function()
      local feed = render.create_buf("feed")
      render.feed(feed, { { ts = 1, kind = "edit", path = "/proj/b.lua" } }, { width = 40, cwd = "/proj" })
      expect(render.payload_at(feed, 1).path).to_be("/proj/b.lua")
    end)

    it("draws a checkpoint as a rule between the events, dated from the next day on", function()
      local ts = os.time({ year = 2026, month = 9, day = 17, hour = 14, min = 32, sec = 0 })
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = ts + 60, kind = "edit", path = "/proj/b.lua" },
        { kind = "checkpoint", ts = ts, index = 1, count = 1 },
        { ts = ts - 60, kind = "read", path = "/proj/a.lua" },
      }, { width = 40, cwd = "/proj", now = ts + 86400 })
      local lines = lines_of(feed)
      expect(#lines).to_be(3)
      expect(lines[2]:find("── checkpoint Sep 17 14:32 ─", 1, true) ~= nil).to_be_true()
      expect(render.payload_at(feed, 2).kind).to_be("checkpoint")
      expect(render.payload_at(feed, 3).path).to_be("/proj/a.lua")
    end)

    it("draws a tool call as the tool and what the call was for", function()
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1785700000, kind = "tool", tool = "Bash", label = "Count commits", tool_id = "t1", status = "done" },
      }, { width = 44, cwd = "/proj" })
      local line = lines_of(feed)[1]
      expect(line:find("bash", 1, true) ~= nil).to_be_true()
      expect(line:find("Count commits", 1, true) ~= nil).to_be_true()
    end)

    it("says nothing about a call that simply worked", function()
      -- Most of them do, and a pane of ticks is a pane with no signal in it.
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1, kind = "tool", tool = "Bash", label = "ok", tool_id = "t1", status = "done" },
      }, { width = 40 })
      expect(lines_of(feed)[1]:find("✗", 1, true)).to_be_nil()
      expect(lines_of(feed)[1]:find("…", 1, true)).to_be_nil()
    end)

    it("marks the three outcomes that are worth a glance", function()
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1, kind = "tool", tool = "Bash", label = "a", tool_id = "t1", status = "running" },
        { ts = 1, kind = "tool", tool = "Bash", label = "b", tool_id = "t2", status = "error" },
        { ts = 1, kind = "tool", tool = "Bash", label = "c", tool_id = "t3", status = "rejected" },
      }, { width = 40 })
      local lines = lines_of(feed)
      expect(lines[1]:find("…", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("✗", 1, true) ~= nil).to_be_true()
      expect(lines[3]:find("⊘", 1, true) ~= nil).to_be_true()
    end)

    it("keeps the marker inside the pane rather than past its edge", function()
      -- A row that reads to the edge and then grows a marker would reflow the
      -- whole column.
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1, kind = "tool", tool = "Bash", label = string.rep("x", 200), tool_id = "t1", status = "error" },
      }, { width = 30 })
      expect(vim.fn.strdisplaywidth(lines_of(feed)[1]) <= 30).to_be_true()
    end)

    it("records what a tool row is, so <CR> can read the call back", function()
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1, kind = "tool", tool = "Bash", label = "Count commits", tool_id = "toolu_9", status = "error" },
      }, { width = 40 })
      local payload = render.payload_at(feed, 1)
      expect(payload.kind).to_be("tool")
      expect(payload.tool_id).to_be("toolu_9")
      expect(payload.tool).to_be("Bash")
      expect(payload.status).to_be("error")
      expect(payload.path).to_be_nil() -- it is not a file, and `.`/`gf` rely on that
    end)
  end)

  describe("row keys", function()
    -- The view keeps each pane's cursor on its row by these. A repaint keeps the
    -- cursor on its line, so a row landing above it slid another under it.
    it("names an Activity row by its call, wherever it is drawn", function()
      local feed = render.create_buf("feed")
      local edit = { ts = 1, kind = "edit", path = "/proj/a.lua", tool_id = "toolu_e" }
      local bash = { ts = 2, kind = "tool", tool = "Bash", label = "ls", tool_id = "toolu_b", status = "done" }
      render.feed(feed, { bash, edit }, { width = 40 })
      expect(render.payload_at(feed, 2).key).to_be("toolu_e")

      render.feed(feed, { { ts = 3, kind = "read", path = "/proj/b.lua", tool_id = "toolu_r" }, bash, edit }, {
        width = 40,
      })
      expect(render.payload_at(feed, 2).key).to_be("toolu_b")
      expect(render.payload_at(feed, 3).key).to_be("toolu_e")
    end)

    it("names a session by its id and a changed file by its path", function()
      local sessions = render.create_buf("sessions")
      render.sessions(sessions, { { session_id = "aaaa1111", title = "First" } }, { width = 40 })
      expect(render.payload_at(sessions, 1).key).to_be("aaaa1111")

      local changes = render.create_buf("changes")
      render.changes(changes, { { path = "/proj/a.lua", added = 1, removed = 0 } }, { width = 40 })
      expect(render.payload_at(changes, 1).key).to_be("/proj/a.lua")
    end)

    it("names a task by its kind as well as its id", function()
      local pane = render.create_buf("subagents")
      render.subagents(pane, {
        { id = "x1", kind = "subagent", agent_type = "Explore", prefix = "", state = "done" },
        { id = "x1", kind = "shell", agent_type = "Bash", prefix = "", state = "done" },
        { id = "x1", kind = "workflow", agent_type = "review", prefix = "", state = "done" },
      }, { width = 40 })
      local subagent, shell, workflow =
        render.payload_at(pane, 1).key, render.payload_at(pane, 2).key, render.payload_at(pane, 3).key
      expect(subagent ~= shell and shell ~= workflow and subagent ~= workflow).to_be_true()
    end)
  end)

  describe("the leading blank cell", function()
    -- A word-highlight plugin (mini.cursorword, vim-illuminate, ...) paints every
    -- other occurrence of the word under the cursor. Parked in column 1 of a list
    -- that lit up every row sharing a timestamp or a status letter. All of them
    -- stand down over whitespace, so a gutter turns the behaviour off for plugins
    -- we have never heard of as well as the one we have.
    local function first_column_is_blank(bufnr)
      for _, line in ipairs(lines_of(bufnr)) do
        if line:sub(1, 1) ~= " " then
          return false, line
        end
      end
      return true
    end

    it("starts every Sessions row with a space", function()
      render.sessions(buf, {
        { session_id = "aaa", title = "First", last_ts = 100, added = 1, removed = 0, icon = "✳", hl = "Normal" },
        { session_id = "bbb", title = "Second", last_ts = 100 },
      }, { width = 40, now = 100 })
      local ok, offender = first_column_is_blank(buf)
      expect(ok).to_be_true()
      expect(offender).to_be(nil)
    end)

    it("starts every Activity row with a space", function()
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1785700000, kind = "read", path = "/proj/a.lua" },
        { ts = 1785700060, kind = "edit", path = "/proj/b.lua" },
      }, { width = 40, cwd = "/proj" })
      expect((first_column_is_blank(feed))).to_be_true()
    end)

    it("starts every Changes row with a space, as it already did", function()
      local changes = render.create_buf("changes")
      render.changes(changes, {
        { path = "/proj/a.lua", status = "M", added = 12, removed = 3 },
      }, { width = 40, cwd = "/proj" })
      expect((first_column_is_blank(changes))).to_be_true()
    end)

    it("turns mini.cursorword off in the panes as well", function()
      -- The gutter is the general fix; this is the exact one for the plugin we
      -- know honours a per-buffer switch.
      expect(vim.b[buf].minicursorword_disable).to_be_true()
    end)

    it("keeps the marks aligned with the text they colour", function()
      -- The gutter shifts every column, so a mark computed against the old
      -- offsets would paint the wrong bytes.
      local feed = render.create_buf("feed")
      render.feed(feed, { { ts = 1785700000, kind = "edit", path = "/proj/b.lua" } }, { width = 40, cwd = "/proj" })
      local line = lines_of(feed)[1]
      local painted = {}
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == feed and mark.row == 0 and mark.opts.end_col then
          painted[line:sub(mark.col + 1, mark.opts.end_col)] = mark.opts.hl_group
        end
      end
      -- Keyed by the text each mark actually covers, so adding a column cannot
      -- make this pass by coincidence: the gutter would shift every span by one
      -- and none of these three would match.
      expect(painted["b.lua"]).to_be("ClaudeCodeAgentsPath")
      expect(painted["edit"]).to_be("ClaudeCodeAgentsKind")
      local clock_painted = false
      for text, _ in pairs(painted) do
        if text:match("^%d%d:%d%d$") then
          clock_painted = true
        end
      end
      expect(clock_painted).to_be_true() -- the clock, not the gutter plus four digits
    end)
  end)

  describe("changes pane", function()
    it("draws the git letter next to transcript counts", function()
      local changes = render.create_buf("changes")
      render.changes(changes, {
        { path = "/proj/a.lua", status = "M", added = 12, removed = 3 },
        { path = "/proj/new.lua", status = "A", added = 40, removed = 0 },
      }, { width = 40, cwd = "/proj" })

      local lines = lines_of(changes)
      expect(#lines).to_be(2)
      expect(lines[1]:find("M", 1, true) ~= nil).to_be_true()
      expect(lines[1]:find("a.lua", 1, true) ~= nil).to_be_true()
      expect(lines[1]:find("+12", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("A", 1, true) ~= nil).to_be_true()
    end)

    it("dims a deleted file's whole row and leaves the D standing out", function()
      local changes = render.create_buf("changes")
      render.changes(changes, {
        { path = "/proj/gone.lua", status = "D", deleted = true, added = 40, removed = 0 },
      }, { width = 40, cwd = "/proj" })

      local line = lines_of(changes)[1]
      expect(line:find("D", 1, true) ~= nil).to_be_true()
      expect(line:find("+40", 1, true) ~= nil).to_be_true()
      local groups = {}
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == changes and mark.row == 0 and mark.opts.end_col then
          groups[#groups + 1] = { text = line:sub(mark.col + 1, mark.opts.end_col), hl = mark.opts.hl_group }
        end
      end
      -- One span from the path to the end of the counts, and nothing else: no
      -- path colour, no count blocks, and the letter left alone.
      expect(#groups).to_be(1)
      expect(groups[1].hl).to_be("ClaudeCodeAgentsDeleted")
      expect(groups[1].text:find("gone.lua", 1, true)).to_be(1)
      expect(groups[1].text:find("+40", 1, true) ~= nil).to_be_true()
      expect(groups[1].text:find("D", 1, true)).to_be_nil()
    end)

    it("draws a scratchpad file's path like a settled tool call's label, keeping its counts", function()
      ---Each marked span of a buffer's rows, keyed by row, with the text it covers.
      local function spans(pane)
        local lines = lines_of(pane)
        local by_row = {}
        for _, mark in ipairs(vim._extmarks or {}) do
          if mark.bufnr == pane and mark.opts.end_col then
            by_row[mark.row + 1] = by_row[mark.row + 1] or {}
            local text = lines[mark.row + 1]:sub(mark.col + 1, mark.opts.end_col)
            table.insert(by_row[mark.row + 1], { text = text, hl = mark.opts.hl_group })
          end
        end
        return by_row
      end
      local function group_of(row_spans, needle)
        for _, span in ipairs(row_spans or {}) do
          if span.text:find(needle, 1, true) then
            return span.hl
          end
        end
      end

      -- What Activity draws a Bash call's description in once the row has settled.
      local feed = render.create_buf("feed")
      render.feed(feed, {
        { ts = 1785700000, kind = "tool", tool = "Bash", label = "run the tests", tool_id = "t1" },
      }, { width = 60, cwd = "/proj" })
      local tool_group = group_of(spans(feed)[1], "run the tests")
      expect(tool_group ~= nil).to_be_true()

      local changes = render.create_buf("changes")
      render.changes(changes, {
        { path = "/proj/a.lua", status = "M", added = 1, removed = 0 },
        { path = "/tmp/pad/probe.lua", status = "A", added = 7, removed = 0, scratchpad = true },
        { path = "/tmp/pad/gone.lua", status = "D", added = 2, removed = 0, scratchpad = true, deleted = true },
      }, { width = 60, cwd = "/proj" })
      local by_row = spans(changes)

      expect(group_of(by_row[1], "a.lua")).to_be("ClaudeCodeAgentsPath")
      expect(group_of(by_row[2], "probe.lua")).to_be(tool_group)
      -- Its counts are still drawn as blocks: a span of their own beyond the path.
      expect(#by_row[2] > 1).to_be_true()
      -- Gone is gone, scratchpad or not: grey wins.
      expect(#by_row[3]).to_be(1)
      expect(by_row[3][1].hl).to_be("ClaudeCodeAgentsDeleted")
    end)

    it("says so when the session changed nothing", function()
      local changes = render.create_buf("changes")
      render.changes(changes, {}, { width = 40 })
      expect(lines_of(changes)[1]:find("no files", 1, true) ~= nil).to_be_true()
    end)

    it("draws a checkpoint as a rule across the pane, and tells the same file's eras apart", function()
      local ts = os.time({ year = 2026, month = 9, day = 17, hour = 14, min = 32, sec = 0 })
      local changes = render.create_buf("changes")
      render.changes(changes, {
        { path = "/proj/a.lua", status = "M", added = 1, removed = 0, era = { index = 1, count = 1, to = ts } },
        { kind = "checkpoint", ts = ts, index = 1, count = 1 },
        { path = "/proj/a.lua", status = "M", added = 2, removed = 0, era = { index = 2, count = 1, from = ts } },
      }, { width = 40, cwd = "/proj", now = ts + 60 })

      local lines = lines_of(changes)
      expect(#lines).to_be(3)
      expect(lines[2]:find("── checkpoint 14:32 ─", 1, true) ~= nil).to_be_true()
      expect(vim.fn.strdisplaywidth(lines[2])).to_be(40)
      -- The rule is one span in its own group, and is not a file.
      local rule = render.payload_at(changes, 2)
      expect(rule.kind).to_be("checkpoint")
      expect(rule.path).to_be(nil)
      local group
      for _, mark in ipairs(vim._extmarks or {}) do
        if mark.bufnr == changes and mark.row == 1 then
          group = mark.opts.hl_group
        end
      end
      expect(group).to_be("ClaudeCodeAgentsCheckpoint")
      -- Two rows of one file, each its own row to the cursor and to `<CR>`.
      expect(render.payload_at(changes, 1).key ~= render.payload_at(changes, 3).key).to_be_true()
      expect(render.payload_at(changes, 3).era.from).to_be(ts)
    end)
  end)

  describe("subagents", function()
    local pane

    before_each(function()
      pane = render.create_buf("subagents")
    end)

    it("draws the tree with cost and runtime aligned at the right edge", function()
      render.subagents(pane, {
        { id = "a", agent_type = "general-purpose", prefix = "", state = "running", tokens = 167410, runtime_s = 830 },
        { id = "b", agent_type = "Explore", prefix = "├─", state = "running", tokens = 42000, runtime_s = 124 },
        { id = "c", agent_type = "Explore", prefix = "│ └─", state = "done", tokens = 18000, runtime_s = 51 },
        { id = "d", agent_type = "Plan", prefix = "└─", state = "failed", tokens = nil, runtime_s = 12 },
      }, { width = 40 })

      local lines = lines_of(pane)
      expect(#lines).to_be(4)
      -- Tokens in a 5-cell field, a space, the runtime in a 7-cell field.
      expect(lines[1]).to_be(" ● general-purpose" .. string.rep(" ", 9) .. " 167k   13:50")
      expect(lines[3]).to_be(" │ └─✓ Explore" .. string.rep(" ", 13) .. "  18k    0:51")
      expect(lines[4]:find("└─✗ Plan", 1, true) ~= nil).to_be_true()
      -- An unknown count keeps its field, so the runtime stays in its column.
      expect(lines[4]:find("    ·    0:12$") ~= nil).to_be_true()
      for _, line in ipairs(lines) do
        expect(vim.fn.strdisplaywidth(line)).to_be(40)
      end
      expect(render.payload_at(pane, 2).agent_id).to_be("b")
    end)

    it("draws a checkpoint as a rule across the tree", function()
      local ts = os.time({ year = 2026, month = 9, day = 17, hour = 14, min = 32, sec = 0 })
      render.subagents(pane, {
        { id = "a", agent_type = "Explore", prefix = "", state = "done", tokens = 100, runtime_s = 5 },
        { kind = "checkpoint", ts = ts, index = 1, count = 1, prefix = "", depth = 0 },
        { id = "b", agent_type = "Plan", prefix = "", state = "running", tokens = 100, runtime_s = 5 },
      }, { width = 40, now = ts + 60 })
      local lines = lines_of(pane)
      expect(#lines).to_be(3)
      expect(lines[2]:find("── checkpoint 14:32 ─", 1, true) ~= nil).to_be_true()
      expect(vim.fn.strdisplaywidth(lines[2])).to_be(40)
      expect(render.payload_at(pane, 2).kind).to_be("checkpoint")
      expect(render.payload_at(pane, 3).agent_id).to_be("b")
    end)

    it("names a run by its description, cut with an ellipsis to fit, or by its type on request", function()
      local rows = {
        {
          id = "a",
          agent_type = "general-purpose",
          description = "Custom components\ncompat with 2026.9",
          prefix = "",
          state = "done",
          tokens = 167410,
          runtime_s = 830,
        },
        { id = "b", agent_type = "Explore", description = "", prefix = "└─", state = "running", runtime_s = 3 },
      }
      render.subagents(pane, rows, { width = 40 })
      local lines = lines_of(pane)
      -- 40 cells: gutter, glyph and space (3), the name (23), a gap, the numbers (13).
      expect(lines[1]).to_be(" ✓ Custom components comp…  167k   13:50")
      expect(vim.fn.strdisplaywidth(lines[1])).to_be(40)
      -- No description to show: the type stands in rather than a blank.
      expect(lines[2]:find("└─● Explore", 1, true) ~= nil).to_be_true()

      render.subagents(pane, rows, { width = 40, label = "type" })
      expect(lines_of(pane)[1]:find("✓ general-purpose", 1, true) ~= nil).to_be_true()
    end)

    it("marks a background shell with $, names it by description or command, and leaves tokens blank", function()
      local rows = {
        { id = "a", kind = "subagent", agent_type = "Explore", prefix = "", state = "running", runtime_s = 60 },
        {
          id = "b1",
          kind = "shell",
          agent_type = "Bash",
          description = "Build it",
          command = "make build",
          tool_id = "toolu_b",
          transcript = "/s.jsonl",
          prefix = "└─",
          state = "failed",
          runtime_s = 13,
        },
      }
      render.subagents(pane, rows, { width = 40 })
      local lines = lines_of(pane)
      expect(lines[2]).to_be(" └─✗ $ Build it" .. string.rep(" ", 12) .. "         0:13")
      expect(vim.fn.strdisplaywidth(lines[2])).to_be(40)
      local payload = render.payload_at(pane, 2)
      expect(payload.kind).to_be("shell")
      expect(payload.task_id).to_be("b1")
      expect(payload.tool_id).to_be("toolu_b")
      expect(payload.transcript).to_be("/s.jsonl")

      render.subagents(pane, rows, { width = 40, label = "type" })
      expect(lines_of(pane)[2]:find("✗ $ make build", 1, true) ~= nil).to_be_true()
    end)

    it("marks a monitor with ~ and shows its event count where tokens go", function()
      render.subagents(pane, {
        {
          id = "bm",
          kind = "shell",
          task_type = "monitor",
          agent_type = "Monitor",
          description = "errors",
          prefix = "",
          state = "running",
          events = 12,
          runtime_s = 42,
        },
      }, { width = 40 })
      expect(lines_of(pane)[1]).to_be(" ● ~ errors" .. string.rep(" ", 16) .. " 12ev    0:42")
    end)

    it("marks a workflow run with » and carries what opens it and its agents", function()
      render.subagents(pane, {
        {
          id = "wtask",
          kind = "workflow",
          task_type = "workflow",
          agent_type = "review-changes",
          description = "Review",
          prefix = "",
          state = "running",
          tokens = 125000,
          runtime_s = 9,
        },
        {
          id = "a1",
          kind = "subagent",
          agent_type = "Phase",
          description = "find bugs",
          path = "/run/agent-a1.jsonl",
          prefix = "└─",
          state = "done",
          tokens = 62000,
          runtime_s = 1,
        },
      }, { width = 40 })
      local lines = lines_of(pane)
      expect(lines[1]).to_be(" ● » Review" .. string.rep(" ", 16) .. " 125k    0:09")
      expect(render.payload_at(pane, 1).kind).to_be("workflow")
      expect(render.payload_at(pane, 1).task_id).to_be("wtask")
      expect(render.payload_at(pane, 2).path).to_be("/run/agent-a1.jsonl")
    end)

    it("keeps the numbers inside a pane too narrow for any name", function()
      render.subagents(pane, {
        {
          id = "a",
          agent_type = "general-purpose",
          prefix = "│ └─",
          state = "done",
          tokens = 1000,
          runtime_s = 1,
        },
      }, { width = 22 })
      local line = lines_of(pane)[1]
      expect(vim.fn.strdisplaywidth(line)).to_be(22)
      expect(line:find("…", 1, true) ~= nil).to_be_true()
    end)

    it("says so when the session started none", function()
      render.subagents(pane, {}, { width = 30 })
      expect(lines_of(pane)[1]:find("no subagents", 1, true) ~= nil).to_be_true()
    end)
  end)
end)
