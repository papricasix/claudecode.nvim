-- luacheck: globals expect
require("tests.busted_setup")

describe("live_cursor", function()
  local live_cursor

  local function base_config(live)
    return {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {},
      env = {},
      models = { { name = "Test Model", value = "test" } },
      terminal = { provider = "native" },
      live_cursor = live,
    }
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.live_cursor"] = nil
    live_cursor = require("claudecode.live_cursor")
  end)

  describe("config validation", function()
    local config

    before_each(function()
      package.loaded["claudecode.config"] = nil
      config = require("claudecode.config")
    end)

    it("rejects enabled=true without a mode", function()
      local cfg = base_config({ enabled = true })
      local ok, err = pcall(config.validate, cfg)
      expect(ok).to_be_false()
      assert.is_truthy(tostring(err):match("live_cursor.mode is required"))
    end)

    it("accepts enabled with a valid mode", function()
      local ok = pcall(config.validate, base_config({ enabled = true, mode = "preview" }))
      expect(ok).to_be_true()
      ok = pcall(config.validate, base_config({ enabled = true, mode = "open" }))
      expect(ok).to_be_true()
    end)

    it("rejects an unknown mode", function()
      local ok = pcall(config.validate, base_config({ enabled = true, mode = "sideways" }))
      expect(ok).to_be_false()
    end)

    it("accepts disabled with no mode", function()
      local ok = pcall(config.validate, base_config({ enabled = false }))
      expect(ok).to_be_true()
    end)

    it("accepts valid layouts and rejects unknown ones", function()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", layout = "vertical" }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", layout = "horizontal" }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", layout = "diagonal" }))).to_be_false()
    end)

    it("accepts a valid preview_align and rejects unknown ones", function()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", preview_align = "center" }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", preview_align = "left" }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", preview_align = "middle" }))).to_be_false()
    end)

    it("accepts a split_size_percentage between 0 and 1 and rejects others", function()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", split_size_percentage = 0.5 }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", split_size_percentage = 1 }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", split_size_percentage = 0 }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, mode = "preview", split_size_percentage = 1.5 }))).to_be_false()
    end)
  end)

  describe("build_launch_injection", function()
    it("returns nil when disabled", function()
      live_cursor.setup(base_config({ enabled = false }))
      expect(live_cursor.build_launch_injection()).to_be_nil()
    end)

    it("returns --settings args and the RPC env var when enabled", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))
      local injection = live_cursor.build_launch_injection()
      assert.is_not_nil(injection)
      assert.is_truthy(injection.args:match("%-%-settings"))
      expect(injection.env.CLAUDECODE_NVIM_SERVER).to_be("/tmp/nvim_mock_server.sock")
      assert.is_not_nil(injection.env.CLAUDECODE_NVIM_TAB)
    end)

    it("writes a settings file containing the PreToolUse hook", function()
      live_cursor.setup(base_config({ enabled = true, mode = "open" }))
      local injection = live_cursor.build_launch_injection()
      -- args look like: --settings '<path>'
      local path = injection.args:match("%-%-settings%s+'?([^']+)'?")
      assert.is_not_nil(path)
      local f = io.open(path, "r")
      assert.is_not_nil(f)
      local contents = f:read("*a")
      f:close()
      assert.is_truthy(contents:match("PreToolUse"))
      assert.is_truthy(contents:match("Read|Edit|Write|MultiEdit"))
      assert.is_truthy(contents:match("nvim %-%-headless"))
      assert.is_truthy(contents:match("live_cursor_hook%.lua"))
    end)
  end)

  describe("dispatch", function()
    local shown

    before_each(function()
      live_cursor.setup(base_config({ enabled = true, mode = "open", clear_delay_ms = 0, diff_suppress_ms = 0 }))
      shown = {}
      live_cursor.show = function(file, opts)
        table.insert(shown, { file = file, opts = opts })
      end
    end)

    it("ignores non-PreToolUse events", function()
      live_cursor.dispatch({ hook_event_name = "PostToolUse", tool_name = "Read", tool_input = { file_path = "/x" } })
      expect(#shown).to_be(0)
    end)

    it("paints the read range from offset/limit", function()
      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Read",
        tool_input = { file_path = "/x", offset = 10, limit = 5 },
      })
      expect(#shown).to_be(1)
      expect(shown[1].file).to_be("/x")
      expect(shown[1].opts.start_line).to_be(10)
      expect(shown[1].opts.end_line).to_be(14)
    end)

    it("defaults a read with no range to line 1", function()
      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Read",
        tool_input = { file_path = "/x" },
      })
      expect(shown[1].opts.start_line).to_be(1)
      expect(shown[1].opts.end_line).to_be_nil()
    end)

    it("suppresses an edit when a review diff owns the file", function()
      package.loaded["claudecode.diff"] = {
        is_live_for_file = function()
          return true
        end,
      }
      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Edit",
        tool_input = { file_path = "/x", old_string = "foo" },
      })
      expect(#shown).to_be(0)
    end)

    it("paints an edit, preferring new_string with old_string as fallback", function()
      package.loaded["claudecode.diff"] = {
        is_live_for_file = function()
          return false
        end,
      }
      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Edit",
        tool_input = { file_path = "/x", old_string = "foo\nbar", new_string = "baz\nqux" },
      })
      expect(#shown).to_be(1)
      expect(shown[1].opts.locate).to_be("baz\nqux")
      expect(shown[1].opts.locate_fallback).to_be("foo\nbar")
    end)

    it("ignores events without a file path", function()
      live_cursor.dispatch({ hook_event_name = "PreToolUse", tool_name = "Read", tool_input = {} })
      expect(#shown).to_be(0)
    end)

    local function read_event()
      return { hook_event_name = "PreToolUse", tool_name = "Read", tool_input = { file_path = "/x", offset = 1 } }
    end

    it("skips a read whose Claude lives in a different (but open) tab", function()
      vim._tabs = { [1] = true, [2] = true }
      vim._current_tabpage = 1
      live_cursor.dispatch(read_event(), 2)
      expect(#shown).to_be(0)
    end)

    it("shows a read whose Claude lives in the current tab", function()
      vim._tabs = { [2] = true }
      vim._current_tabpage = 2
      live_cursor.dispatch(read_event(), 2)
      expect(#shown).to_be(1)
    end)

    it("skips a read whose Claude tab has been closed", function()
      vim._tabs = { [1] = true } -- tab 99 no longer exists (e.g. closed, orphaned external Claude)
      vim._current_tabpage = 1
      live_cursor.dispatch(read_event(), 99)
      expect(#shown).to_be(0)
    end)

    it("does not restrict when the source tab is unknown", function()
      vim._tabs = { [5] = true }
      vim._current_tabpage = 5
      live_cursor.dispatch(read_event(), 0)
      expect(#shown).to_be(1)
    end)
  end)

  describe("toggle", function()
    it("refuses to enable without a mode", function()
      live_cursor.setup(base_config({ enabled = false }))
      expect(live_cursor.toggle()).to_be_false()
      expect(live_cursor._is_enabled()).to_be_false()
    end)

    it("enables when a mode is already set", function()
      live_cursor.setup(base_config({ enabled = false, mode = "open" }))
      expect(live_cursor.toggle()).to_be_true()
      expect(live_cursor._is_enabled()).to_be_true()
    end)

    it("sets the mode and enables when given an explicit mode", function()
      live_cursor.setup(base_config({ enabled = false }))
      expect(live_cursor.toggle("preview")).to_be_true()
      expect(live_cursor._is_enabled()).to_be_true()
    end)

    it("disables with off", function()
      live_cursor.setup(base_config({ enabled = true, mode = "open" }))
      expect(live_cursor.toggle("off")).to_be_false()
      expect(live_cursor._is_enabled()).to_be_false()
    end)

    it("flips an enabled feature off", function()
      live_cursor.setup(base_config({ enabled = true, mode = "open" }))
      expect(live_cursor.toggle()).to_be_false()
    end)
  end)

  describe("preview auto-close", function()
    it("closes an idle, unfocused preview window", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))
      vim._windows[1000] = { buf = 1 }
      vim._windows[2000] = { buf = 2 }
      vim.api.nvim_set_current_win(2000) -- focused elsewhere
      live_cursor._state.preview_win = 1000

      live_cursor._close_idle_preview()

      expect(vim.api.nvim_win_is_valid(1000)).to_be_false()
      expect(live_cursor._state.preview_win).to_be_nil()
    end)

    it("keeps the preview window when it is focused", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))
      vim._windows[1000] = { buf = 1 }
      vim.api.nvim_set_current_win(1000) -- focused in the preview
      live_cursor._state.preview_win = 1000

      live_cursor._close_idle_preview()

      expect(vim.api.nvim_win_is_valid(1000)).to_be_true()
      expect(live_cursor._state.preview_win).to_be(1000)
    end)

    it("does nothing in open mode", function()
      live_cursor.setup(base_config({ enabled = true, mode = "open" }))
      vim._windows[1000] = { buf = 1 }
      vim.api.nvim_set_current_win(2000)
      live_cursor._state.preview_win = 1000

      live_cursor._close_idle_preview()

      expect(vim.api.nvim_win_is_valid(1000)).to_be_true()
    end)
  end)

  describe("preview marker", function()
    it("sets a winbar label and a tinted divider by default", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))
      live_cursor._apply_preview_marker(1000)
      assert.is_truthy(vim.wo[1000].winbar:match("Claude live preview"))
      assert.is_truthy(vim.wo[1000].winbar:match("ClaudeCodeLivePreview"))
      expect(vim.wo[1000].winhighlight).to_be("WinSeparator:ClaudeCodeLivePreview")
    end)

    it("omits the winbar when preview_winbar is false", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", preview_winbar = false }))
      live_cursor._apply_preview_marker(1001)
      expect(vim.wo[1001].winbar).to_be_nil()
      expect(vim.wo[1001].winhighlight).to_be("WinSeparator:ClaudeCodeLivePreview")
    end)

    it("omits the divider when preview_divider is false", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", preview_divider = false }))
      live_cursor._apply_preview_marker(1002)
      expect(vim.wo[1002].winhighlight).to_be_nil()
      assert.is_truthy(vim.wo[1002].winbar:match("Claude live preview"))
    end)

    it("shows the action and file name alongside the brand label (centered by default)", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))

      -- Logical order: brand · action · file (basename only); centered via %=…%=.
      live_cursor._apply_preview_marker(1003, { action = "read", file = "/proj/src/config.lua" })
      expect(vim.wo[1003].winbar).to_be("%#ClaudeCodeLivePreview#%=● Claude live preview · reading · config.lua%=")

      live_cursor._apply_preview_marker(1003, { action = "write", file = "/proj/src/config.lua" })
      expect(vim.wo[1003].winbar).to_be("%#ClaudeCodeLivePreview#%=● Claude live preview · writing · config.lua%=")
    end)

    it("left-aligns the winbar when preview_align is 'left'", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", preview_align = "left" }))
      live_cursor._apply_preview_marker(1007, { action = "read", file = "/proj/src/config.lua" })
      expect(vim.wo[1007].winbar).to_be("%#ClaudeCodeLivePreview#● Claude live preview · reading · config.lua")
    end)

    it("falls back to just the brand label when no action/file is given", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview" }))
      expect(live_cursor._winbar_text(nil)).to_be("● Claude live preview")
      expect(live_cursor._winbar_text({ file = "/a/b.lua" })).to_be("● Claude live preview · b.lua")
      expect(live_cursor._winbar_text({ action = "read" })).to_be("● Claude live preview · reading")
    end)

    it("escapes '%' in the file name so the winbar renders it literally", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", preview_align = "left" }))
      live_cursor._apply_preview_marker(1004, { action = "read", file = "/proj/jan%2025.md" })
      -- The visible text doubles '%' (statusline meta); the directive keeps one.
      expect(vim.wo[1004].winbar).to_be("%#ClaudeCodeLivePreview#● Claude live preview · reading · jan%%2025.md")
    end)
  end)

  describe("locate_block", function()
    local function set_buf(lines)
      vim._mock.add_buffer(7, "/x", lines)
      return 7
    end

    it("matches the exact block, not an earlier line that shares the first line", function()
      -- "if cond then" appears at lines 2 and 5; only the line-5 block is the
      -- real match. Substring/first-line matching would wrongly pick line 2.
      local buf = set_buf({ "x = 1", "if cond then", "  x = 1", "end", "if cond then", "  x = 2", "end" })
      local s, e = live_cursor._locate_block(buf, "if cond then\n  x = 2\nend")
      expect(s).to_be(5)
      expect(e).to_be(7)
    end)

    it("matches a single exact line", function()
      local buf = set_buf({ "alpha", "beta", "gamma" })
      local s, e = live_cursor._locate_block(buf, "beta")
      expect(s).to_be(2)
      expect(e).to_be(2)
    end)

    it("returns nil when the block is not present", function()
      local buf = set_buf({ "alpha", "beta" })
      expect(live_cursor._locate_block(buf, "zzz")).to_be_nil()
    end)
  end)

  describe("common_context (changed-line trimming)", function()
    it("counts shared leading and trailing lines", function()
      local prefix, suffix = live_cursor._common_context(
        { "ctx1", "ctx2", "OLD", "ctx3" },
        { "ctx1", "ctx2", "NEW", "ctx3" }
      )
      expect(prefix).to_be(2)
      expect(suffix).to_be(1)
    end)

    it("handles a leading anchor that new_string keeps", function()
      -- old=2-line anchor kept at the start of an otherwise-new block.
      local prefix, suffix = live_cursor._common_context({ "a", "b" }, { "a", "b", "n1", "n2", "n3" })
      expect(prefix).to_be(2)
      expect(suffix).to_be(0)
    end)

    it("reports no shared context when nothing matches", function()
      local prefix, suffix = live_cursor._common_context({ "x" }, { "y" })
      expect(prefix).to_be(0)
      expect(suffix).to_be(0)
    end)
  end)

  describe("reconstruct_old (for the inline diff)", function()
    it("swaps the new block back to old_string to rebuild the pre-edit file", function()
      local post = { "a", "NEW1", "NEW2", "b" }
      local rebuilt = live_cursor._reconstruct_old(post, 2, 3, { "OLD" })
      assert.are.same({ "a", "OLD", "b" }, rebuilt)
    end)

    it("removes the block for a pure insertion (empty old)", function()
      local post = { "a", "INS1", "INS2", "b" }
      local rebuilt = live_cursor._reconstruct_old(post, 2, 3, {})
      assert.are.same({ "a", "b" }, rebuilt)
    end)

    it("locate_in_array finds the exact block", function()
      local s, e = live_cursor._locate_in_array({ "a", "x", "y", "b" }, { "x", "y" })
      expect(s).to_be(2)
      expect(e).to_be(3)
    end)
  end)

  -- Preview mode owns a dedicated split: it must be created on demand (a *new*
  -- window, never the editor window itself) and torn down when Claude goes idle.
  describe("preview own-split lifecycle", function()
    before_each(function()
      -- A single main editor window (1000) in tab 1. reset() leaves _next_winid
      -- at 1000, so bump it past our hand-placed window or :vsplit would reuse id
      -- 1000 and collide with the editor window.
      vim._tabs = { [1] = true }
      vim._current_tabpage = 1
      vim._mock.add_window(1000, 1, { 1, 0 })
      vim._win_tab[1000] = 1
      vim._tab_windows[1] = { 1000 }
      vim._current_window = 1000
      vim._next_winid = 2000

      -- A loaded file buffer for /x so show() can paint into it.
      vim._mock.add_buffer(
        50,
        "/x",
        { "line1", "line2", "line3", "line4", "line5" },
        { buftype = "", modified = false }
      )

      -- bufadd/bufload are not in the shared mock; stub them for the file open.
      vim.fn.bufadd = function()
        return 50
      end
      vim.fn.bufload = function() end

      -- diff module supplies the canonical window finder and reports that no
      -- review diff owns the file (so the edit path is not suppressed here).
      package.loaded["claudecode.diff"] = {
        find_main_editor_window = function()
          return 1000
        end,
        is_live_for_file = function()
          return false
        end,
      }
    end)

    after_each(function()
      vim.fn.bufadd = nil
      vim.fn.bufload = nil
      package.loaded["claudecode.diff"] = nil
    end)

    it("read: opens a dedicated preview split, then the idle handler closes it", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", clear_delay_ms = 0 }))

      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Read",
        tool_input = { file_path = "/x", offset = 2, limit = 2 },
      })

      local pw = live_cursor._state.preview_win
      assert.is_not_nil(pw)
      assert.are_not.equal(1000, pw) -- a NEW window, not the editor window
      expect(vim.api.nvim_win_is_valid(pw)).to_be_true()
      -- The winbar reports the action and file end-to-end (dispatch → show → marker).
      assert.is_truthy(vim.wo[pw].winbar:match("reading · x"))

      -- Auto-close when Claude goes idle (the timer calls _close_idle_preview).
      live_cursor._close_idle_preview()
      expect(vim.api.nvim_win_is_valid(pw)).to_be_false()
      expect(live_cursor._state.preview_win).to_be_nil()
    end)

    it("write (edit): opens a dedicated preview split, then the idle handler closes it", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", clear_delay_ms = 0, diff_suppress_ms = 0 }))

      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Edit",
        tool_input = { file_path = "/x", old_string = "line2", new_string = "line2-changed" },
      })

      local pw = live_cursor._state.preview_win
      assert.is_not_nil(pw)
      assert.are_not.equal(1000, pw)
      expect(vim.api.nvim_win_is_valid(pw)).to_be_true()
      assert.is_truthy(vim.wo[pw].winbar:match("writing · x"))

      live_cursor._close_idle_preview()
      expect(vim.api.nvim_win_is_valid(pw)).to_be_false()
      expect(live_cursor._state.preview_win).to_be_nil()
    end)

    it("opens a new window for its own split rather than hijacking the editor window", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", clear_delay_ms = 0 }))

      local before = vim.api.nvim_get_current_win()
      live_cursor.show("/x", { start_line = 1 })

      local pw = live_cursor._state.preview_win
      assert.is_not_nil(pw)
      assert.are_not.equal(before, pw) -- split lives in its own window
      expect(vim.api.nvim_win_is_valid(pw)).to_be_true()
      -- Focus is not stolen: the user stays in the window they were in.
      expect(vim.api.nvim_get_current_win()).to_be(before)
    end)

    it("reuses its own preview window across events instead of opening another", function()
      live_cursor.setup(base_config({ enabled = true, mode = "preview", clear_delay_ms = 0 }))

      live_cursor.show("/x", { start_line = 1 })
      local first = live_cursor._state.preview_win
      assert.is_not_nil(first)

      live_cursor.show("/x", { start_line = 3 })
      expect(live_cursor._state.preview_win).to_be(first)
    end)

    it("the idle clear timer auto-closes the preview (timer wiring)", function()
      -- clear_delay_ms > 0 arms the timer; the mock fires deferred callbacks
      -- immediately, so the split is created and then auto-closed within show().
      live_cursor.setup(base_config({ enabled = true, mode = "preview", clear_delay_ms = 50 }))

      live_cursor.show("/x", { start_line = 1 })

      expect(live_cursor._state.preview_win).to_be_nil()
    end)
  end)

  -- In non-auto-accept mode Claude's edit lands behind a pending review diff that
  -- already visualizes the change; the live preview must stand down so the two
  -- don't fight over the same file.
  describe("review-diff suppression (non-auto-accept diff)", function()
    local diff
    local calls

    before_each(function()
      package.loaded["claudecode.diff"] = nil
      diff = require("claudecode.diff")
      local active = diff._get_active_diffs()
      for k in pairs(active) do
        active[k] = nil
      end

      live_cursor.setup(base_config({ enabled = true, mode = "preview", diff_suppress_ms = 0 }))

      calls = { show = 0, show_diff = 0 }
      live_cursor.show = function()
        calls.show = calls.show + 1
      end
      live_cursor.show_diff = function()
        calls.show_diff = calls.show_diff + 1
        return false
      end
    end)

    after_each(function()
      local active = diff._get_active_diffs()
      for k in pairs(active) do
        active[k] = nil
      end
      package.loaded["claudecode.diff"] = nil
    end)

    it("does NOT trigger a live preview when a pending review diff owns the file", function()
      diff._get_active_diffs()["t1"] = { new_file_path = "/x", old_file_path = "/x.orig", status = "pending" }

      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Edit",
        tool_input = { file_path = "/x", old_string = "a", new_string = "b" },
      })

      expect(calls.show).to_be(0)
      expect(calls.show_diff).to_be(0)
    end)

    it("does trigger a live preview when no review diff owns the file", function()
      -- No active diff registered for /x.
      live_cursor.dispatch({
        hook_event_name = "PreToolUse",
        tool_name = "Edit",
        tool_input = { file_path = "/x", old_string = "a", new_string = "b" },
      })

      -- show_diff is attempted first (returns false here), then show is the fallback.
      expect(calls.show_diff).to_be(1)
      expect(calls.show).to_be(1)
    end)
  end)
end)

describe("diff.is_live_for_file", function()
  local diff

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
    local active = diff._get_active_diffs()
    for k in pairs(active) do
      active[k] = nil
    end
  end)

  it("is true for a pending diff matching new or old path", function()
    local active = diff._get_active_diffs()
    active["t1"] = { new_file_path = "/a", old_file_path = "/b", status = "pending" }
    expect(diff.is_live_for_file("/a")).to_be_true()
    expect(diff.is_live_for_file("/b")).to_be_true()
  end)

  it("is false for an unrelated path", function()
    local active = diff._get_active_diffs()
    active["t1"] = { new_file_path = "/a", old_file_path = "/b", status = "pending" }
    expect(diff.is_live_for_file("/c")).to_be_false()
  end)

  it("is false once the diff is no longer pending", function()
    local active = diff._get_active_diffs()
    active["t1"] = { new_file_path = "/a", old_file_path = "/b", status = "saved" }
    expect(diff.is_live_for_file("/a")).to_be_false()
  end)
end)
