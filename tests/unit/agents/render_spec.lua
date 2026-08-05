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

    it("says so when the session changed nothing", function()
      local changes = render.create_buf("changes")
      render.changes(changes, {}, { width = 40 })
      expect(lines_of(changes)[1]:find("no files", 1, true) ~= nil).to_be_true()
    end)
  end)
end)
