-- luacheck: globals expect
require("tests.busted_setup")

describe("float", function()
  local float

  local function base_config(overrides)
    return vim.tbl_deep_extend("force", {
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
    }, overrides or {})
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.float"] = nil
    package.loaded["claudecode.agents.float"] = nil
    float = require("claudecode.float")
    float.reset()
  end)

  describe("geometry", function()
    it("falls back to its own defaults when nothing is configured", function()
      float.setup(base_config())
      local opts = float.opts()
      expect(opts.width).to_be(0.7)
      expect(opts.height).to_be(0.7)
      expect(opts.border).to_be("rounded")
      expect(opts.cascade_offset).to_be(2)
    end)

    it("takes the top-level float block", function()
      float.setup(base_config({ float = { width = 0.4, border = "single" } }))
      local opts = float.opts()
      expect(opts.width).to_be(0.4)
      expect(opts.border).to_be("single")
      -- Unmentioned keys keep the default rather than vanishing.
      expect(opts.height).to_be(0.7)
    end)

    it("lets a feature's own table win over the global one", function()
      -- This is the whole point of the split: `diff_opts.layout = "float"` used
      -- to read `agents.float`, so a user with agents disabled was sizing their
      -- diffs through a feature they had turned off.
      float.setup(base_config({ float = { width = 0.4, height = 0.4 } }))
      local opts = float.opts({ width = 0.9 })
      expect(opts.width).to_be(0.9)
      expect(opts.height).to_be(0.4)
    end)

    it("sizes the window from the resolved options", function()
      vim.o.columns = 200
      vim.o.lines = 50
      float.setup(base_config({ float = { width = 0.5, height = 0.5 } }))
      local win = float.create({ title = "a.lua" })
      local config = vim.api.nvim_win_get_config(win)
      expect(config.width).to_be(100)
      expect(config.height).to_be(25)
    end)
  end)

  describe("tagging", function()
    it("marks every float as not a normal editor window", function()
      float.setup(base_config())
      local win = float.create({ title = "a.lua" })
      expect(vim.w[win].claudecode_live_preview).to_be_true()
      expect(vim.w[win].claudecode_float).to_be_true()
    end)

    it("adds a caller's own tags without losing the shared ones", function()
      float.setup(base_config())
      local win = float.create({ title = "a.lua", tags = { claudecode_agents_float = true } })
      expect(vim.w[win].claudecode_live_preview).to_be_true()
      expect(vim.w[win].claudecode_agents_float).to_be_true()
    end)
  end)

  describe("bind_close", function()
    it("binds q and <Tab> on the float's buffer", function()
      float.setup(base_config())
      local win, buf = float.create({ title = "a.lua" })
      float.bind_close(win)
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        maps[map.lhs] = true
      end
      expect(maps["q"]).to_be_true()
      expect(maps["<Tab>"]).to_be_true()
    end)

    it("drops its keymaps when the float closes", function()
      -- A float can hold a *real file buffer* — `open_file` puts one there, and
      -- with openFile routed to floats that is the common case. A buffer-local
      -- map outlives the window it was made for, so without this every file
      -- Claude ever showed you would carry a `q` that closes a window, in every
      -- window, for the rest of the session.
      float.setup(base_config())
      local win, buf = float.create({ title = "a.lua" })
      float.bind_close(win)
      expect(#vim.api.nvim_buf_get_keymap(buf, "n")).to_be(2)

      float.close(win)
      expect(#vim.api.nvim_buf_get_keymap(buf, "n")).to_be(0)
    end)

    it("drops them however the float went away", function()
      -- `:q`, `<C-w>c` and a closing tab never reach `M.close`, which is why the
      -- cleanup hangs off WinClosed rather than off our own close path.
      float.setup(base_config())
      local win, buf = float.create({ title = "a.lua" })
      float.bind_close(win)
      vim.api.nvim_win_close(win, true)
      expect(#vim.api.nvim_buf_get_keymap(buf, "n")).to_be(0)
    end)

    it("leaves a mapping somebody else made alone", function()
      -- A real file buffer may already carry a buffer-local `q` from an ftplugin
      -- or the user's config. Overwriting it and then deleting it on close would
      -- lose theirs.
      float.setup(base_config())
      local win, buf = float.create({ title = "a.lua" })
      local theirs = function() end
      vim.keymap.set("n", "q", theirs, { buffer = buf })

      float.bind_close(win)
      local maps = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        maps[map.lhs] = map.rhs
      end
      expect(maps["q"]).to_be(theirs)
      expect(maps["<Tab>"]).not_to_be_nil()

      -- And closing must not take theirs with it.
      float.close(win)
      local after = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        after[map.lhs] = map.rhs
      end
      expect(after["q"]).to_be(theirs)
      expect(after["<Tab>"]).to_be_nil()
    end)
  end)

  describe("terminal mode", function()
    local saved_mode

    ---A terminal window the user is typing in, made current.
    ---@return integer win
    ---@return integer buf
    local function terminal_window()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "terminal"
      local win = vim.api.nvim_open_win(buf, true, { relative = "editor", width = 10, height = 5, row = 0, col = 0 })
      return win, buf
    end

    before_each(function()
      saved_mode = vim.fn.mode
      vim._last_command = nil
    end)

    after_each(function()
      vim.fn.mode = saved_mode
    end)

    it("puts the terminal back in insert mode when the float closes", function()
      -- The float opens over a terminal the user is typing into, so answering a
      -- diff and dismissing it must not cost them an `i` to carry on.
      float.setup(base_config())
      local term_win = terminal_window()
      vim.fn.mode = function()
        return "t"
      end

      local win = float.create({ title = "a.lua" })
      -- Closing a float hands focus back to the window under it.
      vim.api.nvim_set_current_win(term_win)
      float.close(win)

      expect(vim._last_command).to_be("startinsert")
    end)

    it("leaves normal mode alone", function()
      float.setup(base_config())
      local term_win = terminal_window()

      local win = float.create({ title = "a.lua" })
      vim.api.nvim_set_current_win(term_win)
      float.close(win)

      expect(vim._last_command).to_be_nil()
    end)

    it("ignores a current window that is not a terminal", function()
      -- A diff float is opened from inside `nvim_win_call`, which makes another
      -- window current for the duration while leaving the mode alone: `mode()`
      -- still says `t` and `nvim_get_current_win()` names a window the user is
      -- not in. Recording that one meant the restore never matched the window
      -- focus came back to.
      float.setup(base_config())
      local term_win = terminal_window()
      local other = vim.api.nvim_open_win(
        vim.api.nvim_create_buf(false, true),
        true,
        { relative = "editor", width = 10, height = 5, row = 0, col = 0 }
      )
      vim.fn.mode = function()
        return "t"
      end

      expect(float.terminal_mode_window()).to_be_nil()
      vim.api.nvim_set_current_win(term_win)
      expect(float.terminal_mode_window()).to_be(term_win)
      expect(other).not_to_be_nil()
    end)

    it("takes the terminal the caller noticed before the spoof", function()
      -- Which is why `_setup_blocking_diff_unified` reads it before entering
      -- `in_owning_tab` and hands it over.
      float.setup(base_config())
      local term_win = terminal_window()
      vim.api.nvim_open_win(
        vim.api.nvim_create_buf(false, true),
        true,
        { relative = "editor", width = 10, height = 5, row = 0, col = 0 }
      )
      vim.fn.mode = function()
        return "t"
      end

      local win = float.create({ title = "a.lua", term_win = term_win })
      vim.api.nvim_set_current_win(term_win)
      float.close(win)

      expect(vim._last_command).to_be("startinsert")
    end)

    it("refuses a handed-over window that is not a terminal", function()
      float.setup(base_config())
      local plain = vim.api.nvim_open_win(
        vim.api.nvim_create_buf(false, true),
        true,
        { relative = "editor", width = 10, height = 5, row = 0, col = 0 }
      )

      local win = float.create({ title = "a.lua", term_win = plain })
      vim.api.nvim_set_current_win(plain)
      float.close(win)

      expect(vim._last_command).to_be_nil()
    end)

    it("does nothing when focus did not go back to that terminal", function()
      -- Floats stack: closing the top one often lands on another float, which
      -- will restore the mode itself when *it* closes.
      float.setup(base_config())
      terminal_window()
      vim.fn.mode = function()
        return "t"
      end

      local first = float.create({ title = "a.lua" })
      local second = float.create({ title = "b.lua" })
      vim.api.nvim_set_current_win(second)
      float.close(first)

      expect(vim._last_command).to_be_nil()
    end)
  end)

  describe("ownership", function()
    it("knows whether it made the buffer it is showing", function()
      float.setup(base_config())
      float.create({ title = "scratch" })
      expect(float.list()[1].owned_buf).to_be_true()

      local existing = vim.api.nvim_create_buf(false, true)
      float.create({ title = "given", buf = existing })
      expect(float.list()[2].owned_buf).to_be(false)
    end)
  end)

  describe("retag", function()
    it("follows a conversation that was renamed under an open float", function()
      -- An agent that runs /clear keeps its floats but goes by a new id, and
      -- `close_all` — what takes them down when the agent ends — asks by id.
      float.setup(base_config())
      float.create({ session_id = "old", title = "a" })
      float.create({ session_id = "other", title = "b" })

      expect(float.retag("old", "new")).to_be(1)
      expect(float.close_all("old")).to_be(0)
      expect(float.close_all("new")).to_be(1)
      expect(float.count()).to_be(1)
    end)
  end)

  describe("diff float titles", function()
    local diff

    before_each(function()
      package.loaded["claudecode.diff"] = nil
      diff = require("claudecode.diff")
      float.setup(base_config())
    end)

    after_each(function()
      package.loaded["claudecode.diff"] = nil
    end)

    ---@return string|nil
    local function last_title()
      local list = float.list()
      local entry = list[#list]
      return entry and entry.title or nil
    end

    it("says where the file is, not just its tail", function()
      diff.open_float({ file_path = vim.fn.getcwd() .. "/lua/claudecode/diff.lua" })
      expect(last_title()).to_be("lua/claudecode/diff.lua")
    end)

    it("shows a file outside the editor's directory as a path", function()
      local home = os.getenv("HOME") or "/home/u"
      diff.open_float({ file_path = home .. "/.config/nvim/init.lua" })
      expect(last_title()).to_be("~/.config/nvim/init.lua")
    end)

    it("keeps naming the agent that asked", function()
      -- Several agents answer at once, so a float has to say whose question it is.
      diff.open_float({ file_path = vim.fn.getcwd() .. "/lua/a.lua", session_id = "abcdef1234" })
      expect(last_title()).to_be("lua/a.lua  ·  abcdef12")
    end)

    it("still names a float with no file at all", function()
      diff.open_float({ session_id = "abcdef1234" })
      expect(last_title()).to_be("diff  ·  abcdef12")
      diff.open_float({})
      expect(last_title()).to_be("diff")
    end)

    it("leaves a title the caller supplied alone", function()
      diff.open_float({ file_path = "/proj/a.lua", title = "mine" })
      expect(last_title()).to_be("mine")
    end)
  end)

  describe("config", function()
    local config

    before_each(function()
      package.loaded["claudecode.config"] = nil
      config = require("claudecode.config")
    end)

    it("ships a top-level float block", function()
      local applied = config.apply({})
      expect(applied.float).to_be_table()
      expect(applied.float.width).to_be(0.7)
    end)

    it("validates the top-level block the same way as agents.float", function()
      expect((pcall(config.validate_float, { width = 0.5 }, "float"))).to_be_true()
      expect((pcall(config.validate_float, { width = 42 }, "float"))).to_be(false)
      expect((pcall(config.validate_float, { cascade_offset = -1 }, "float"))).to_be(false)
      expect((pcall(config.validate_float, { border = "single" }, "float"))).to_be_true()
      expect((pcall(config.validate_float, "nonsense", "float"))).to_be(false)
      -- Absent is always fine: neither block is required.
      expect((pcall(config.validate_float, nil, "float"))).to_be_true()
    end)
  end)
end)
