-- luacheck: globals expect
require("tests.busted_setup")

describe("plan_view", function()
  local plan_view

  local function base_config(plan)
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
      plan = plan,
    }
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.plan_view"] = nil
    plan_view = require("claudecode.plan_view")
  end)

  describe("config validation", function()
    local config

    before_each(function()
      package.loaded["claudecode.config"] = nil
      config = require("claudecode.config")
    end)

    it("accepts a fully specified plan block", function()
      local ok = pcall(
        config.validate,
        base_config({ enabled = true, layout = "horizontal", split_size_percentage = 0.4, focus = false })
      )
      expect(ok).to_be_true()
    end)

    it("rejects an unknown layout", function()
      expect(pcall(config.validate, base_config({ enabled = true, layout = "diagonal" }))).to_be_false()
    end)

    it("rejects a split_size_percentage outside (0, 1]", function()
      expect(pcall(config.validate, base_config({ enabled = true, split_size_percentage = 0 }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, split_size_percentage = 1.5 }))).to_be_false()
    end)

    it("rejects a non-boolean focus", function()
      expect(pcall(config.validate, base_config({ enabled = true, focus = "yes" }))).to_be_false()
    end)
  end)

  describe("is_enabled", function()
    it("is false by default / when disabled", function()
      plan_view.setup(base_config({ enabled = false }))
      expect(plan_view.is_enabled()).to_be_false()
    end)

    it("is true when enabled", function()
      plan_view.setup(base_config({ enabled = true }))
      expect(plan_view.is_enabled()).to_be_true()
    end)
  end)

  -- The plan takes over an existing editor window (the one closest to the Claude
  -- terminal) rather than opening its own split, and restores that window's buffer
  -- when the plan resolves.
  describe("take-over / restore lifecycle", function()
    local closest

    before_each(function()
      vim._tabs = { [1] = true }
      vim._current_tabpage = 1
      -- An editor window (1000) showing file.lua, and a "terminal" window (1001)
      -- that the user is currently focused in.
      vim._mock.add_buffer(60, "/proj/file.lua", { "old1", "old2", "old3" }, { buftype = "" })
      vim._mock.add_window(1000, 60, { 2, 0 })
      vim._mock.add_window(1001, 70, { 1, 0 })
      vim._win_tab[1000] = 1
      vim._win_tab[1001] = 1
      vim._tab_windows[1] = { 1000, 1001 }
      vim._current_window = 1001
      vim._next_winid = 2000

      closest = 1000
      package.loaded["claudecode.diff"] = {
        find_window_closest_to_terminal = function()
          return closest
        end,
        find_main_editor_window = function()
          return 1000
        end,
      }
    end)

    after_each(function()
      package.loaded["claudecode.diff"] = nil
    end)

    it("takes over the closest editor window (no new split) and marks it", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))

      plan_view.show("# Plan\n1. step one\n2. step two", 1)

      expect(plan_view._state.plan_win).to_be(1000)
      expect(plan_view._state.created_split).to_be_false()
      assert.is_truthy(vim.wo[1000].winbar:match("Claude plan"))
      assert.is_truthy(vim.wo[1000].winbar:match("ClaudeCodePlan"))
    end)

    it("renders the plan markdown into a read-only scratch buffer shown in that window", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))

      plan_view.show("# Plan\nfirst\nsecond", 1)

      local buf = plan_view._state.plan_buf
      assert.is_not_nil(buf)
      expect(vim.api.nvim_win_get_buf(1000)).to_be(buf)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.are.same({ "# Plan", "first", "second" }, lines)
    end)

    it("restores the displaced buffer and cursor when the plan resolves", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))
      expect(vim.api.nvim_win_get_buf(1000)).to_be(60) -- file.lua before

      plan_view.show("# Plan", 1)
      expect(vim.api.nvim_win_get_buf(1000)).to_be(plan_view._state.plan_buf) -- plan during

      plan_view.close()
      expect(vim.api.nvim_win_get_buf(1000)).to_be(60) -- file.lua restored
      assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(1000)) -- cursor restored
      expect(plan_view._state.plan_win).to_be_nil()
      expect(plan_view.is_open()).to_be_false()
    end)

    it("moves focus into the plan window when focus = true", function()
      plan_view.setup(base_config({ enabled = true, focus = true }))
      plan_view.show("# Plan", 1)
      expect(vim.api.nvim_get_current_win()).to_be(1000)
    end)

    it("keeps focus where it was when focus = false", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))
      plan_view.show("# Plan", 1)
      expect(vim.api.nvim_get_current_win()).to_be(1001)
    end)

    it("reuses the same window across plans and keeps the original displaced buffer", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))

      plan_view.show("# Plan A", 1)
      expect(plan_view._state.plan_win).to_be(1000)

      plan_view.show("# Plan B", 1)
      expect(plan_view._state.plan_win).to_be(1000)

      plan_view.close()
      expect(vim.api.nvim_win_get_buf(1000)).to_be(60) -- still restores file.lua
    end)

    it("does not clobber the window if the user navigated away before resolve", function()
      plan_view.setup(base_config({ enabled = true, focus = false }))
      plan_view.show("# Plan", 1)
      -- User opened a different buffer in that window while reading the plan.
      vim.api.nvim_win_set_buf(1000, 99)

      plan_view.close()
      expect(vim.api.nvim_win_get_buf(1000)).to_be(99) -- left alone
      expect(plan_view._state.plan_win).to_be_nil()
    end)

    it("close() is a no-op when close_on_resolve = false", function()
      plan_view.setup(base_config({ enabled = true, focus = false, close_on_resolve = false }))
      plan_view.show("# Plan", 1)
      local buf = plan_view._state.plan_buf

      plan_view.close()

      expect(vim.api.nvim_win_get_buf(1000)).to_be(buf)
      expect(plan_view.is_open()).to_be_true()
    end)

    it("falls back to a created split when there is no editor window to take over", function()
      closest = nil -- diff reports no suitable editor window
      plan_view.setup(base_config({ enabled = true, focus = false }))

      plan_view.show("# Plan", 1)
      local pw = plan_view._state.plan_win
      assert.is_not_nil(pw)
      expect(plan_view._state.created_split).to_be_true()

      -- A created split is closed (not restored) on resolve.
      plan_view.close()
      expect(vim.api.nvim_win_is_valid(pw)).to_be_false()
      expect(plan_view._state.plan_win).to_be_nil()
    end)

    it("does nothing when disabled", function()
      plan_view.setup(base_config({ enabled = false }))
      plan_view.show("# Plan", 1)
      expect(plan_view._state.plan_win).to_be_nil()
    end)

    it("ignores an empty plan", function()
      plan_view.setup(base_config({ enabled = true }))
      plan_view.show("", 1)
      expect(plan_view._state.plan_win).to_be_nil()
    end)
  end)

  describe("tab awareness", function()
    it("does not restrict when the source tab is unknown", function()
      plan_view.setup(base_config({ enabled = true }))
      vim._tabs = { [5] = true }
      vim._current_tabpage = 5
      expect(plan_view._wrong_tab(0)).to_be_false()
    end)

    it("skips a plan whose Claude lives in a different (open) tab", function()
      plan_view.setup(base_config({ enabled = true }))
      vim._tabs = { [1] = true, [2] = true }
      vim._current_tabpage = 1
      expect(plan_view._wrong_tab(2)).to_be_true()
    end)

    it("skips a plan whose Claude tab has been closed", function()
      plan_view.setup(base_config({ enabled = true }))
      vim._tabs = { [1] = true }
      vim._current_tabpage = 1
      expect(plan_view._wrong_tab(99)).to_be_true()
    end)
  end)

  describe("toggle", function()
    it("flips enabled state", function()
      plan_view.setup(base_config({ enabled = false }))
      expect(plan_view.toggle()).to_be_true()
      expect(plan_view.is_enabled()).to_be_true()
      expect(plan_view.toggle()).to_be_false()
      expect(plan_view.is_enabled()).to_be_false()
    end)

    it("honors explicit on/off", function()
      plan_view.setup(base_config({ enabled = false }))
      expect(plan_view.toggle("on")).to_be_true()
      expect(plan_view.toggle("off")).to_be_false()
    end)
  end)
end)

-- The "closest editor window to the terminal" picker is pure geometry; test the
-- rectangle math directly so we don't need a full window-layout mock.
describe("diff.find_window_closest_to_terminal geometry", function()
  local diff

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
  end)

  it("picks the window adjacent to the terminal over a farther one", function()
    -- terminal on the right (x 20..30); edB (x 10..20) touches it, edA (x 0..10) is farther.
    local term = { x0 = 20, y0 = 0, x1 = 30, y1 = 10 }
    local edA = { x0 = 0, y0 = 0, x1 = 10, y1 = 10 }
    local edB = { x0 = 10, y0 = 0, x1 = 20, y1 = 10 }
    expect(diff._closest_rect_index(term, { edA, edB })).to_be(2)
  end)

  it("breaks ties between equally-adjacent windows by center distance", function()
    -- Two windows stacked left of the terminal, both touching it (gap 0). The one
    -- whose center is vertically nearer the terminal center wins.
    local term = { x0 = 10, y0 = 0, x1 = 20, y1 = 10 } -- center y = 5
    local top = { x0 = 0, y0 = 0, x1 = 10, y1 = 4 } -- center y = 2
    local bottom = { x0 = 0, y0 = 4, x1 = 10, y1 = 10 } -- center y = 7 (closer to 5)
    expect(diff._closest_rect_index(term, { top, bottom })).to_be(2)
  end)
end)
