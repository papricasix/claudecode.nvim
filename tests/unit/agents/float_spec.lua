-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.float", function()
  local float

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.float"] = nil
    float = require("claudecode.agents.float")
    float.setup({ agents = { enabled = true, float = { width = 0.5, height = 0.5, cascade_offset = 2 } } })
    float.reset()
  end)

  describe("creating", function()
    it("opens a floating window", function()
      local win, buf = float.create("aaa", { title = "a.lua" })
      expect(win).not_to_be_nil()
      expect(buf).not_to_be_nil()
      local config = vim.api.nvim_win_get_config(win)
      expect(config.relative).to_be("editor")
      expect(float.count()).to_be(1)
    end)

    it("tags the float so another agent's diff never targets it", function()
      local win = float.create("aaa", { title = "a.lua" })
      expect(vim.w[win].claudecode_live_preview).to_be_true()
      expect(vim.w[win].claudecode_agents_float).to_be_true()
    end)

    it("shows a file the way the user's own settings say to", function()
      -- A float copies its window-local options from the *current* window, which
      -- for these is an agents pane — and a pane turns `wrap`, `number` and the
      -- rest off because it draws fixed-width list rows. Inherited, that left a
      -- long line running off the right edge of a diff with no way to read it.
      vim.go.wrap = true
      vim.go.number = true
      vim.go.list = true
      vim.go.signcolumn = "yes"
      local win = float.create("aaa", { title = "a.lua" })
      expect(vim.wo[win].wrap).to_be_true()
      expect(vim.wo[win].number).to_be_true()
      expect(vim.wo[win].list).to_be_true()
      expect(vim.wo[win].signcolumn).to_be("yes")
    end)

    it("follows the user the other way too", function()
      vim.go.wrap = false
      vim.go.number = false
      local win = float.create("aaa", { title = "a.lua" })
      expect(vim.wo[win].wrap).to_be_false()
      expect(vim.wo[win].number).to_be_false()
    end)

    it("remembers which conversation each float belongs to", function()
      float.create("aaa", { title = "a" })
      float.create("bbb", { title = "b" })
      local open = float.list()
      expect(#open).to_be(2)
      expect(open[1].session_id).to_be("aaa")
      expect(open[2].session_id).to_be("bbb")
    end)
  end)

  describe("cascading", function()
    it("offsets each float from the last, so none hides another entirely", function()
      local first = float.create("aaa", { title = "a" })
      local second = float.create("bbb", { title = "b" })

      local a = vim.api.nvim_win_get_config(first)
      local b = vim.api.nvim_win_get_config(second)
      expect(b.row > a.row).to_be_true()
      expect(b.col > a.col).to_be_true()
    end)

    it("stops stepping rather than walking off the screen", function()
      -- The cascade must stay answerable however many agents pile up.
      local last
      for _ = 1, 40 do
        last = float.create("x", { title = "x" })
      end
      local config = vim.api.nvim_win_get_config(last)
      expect(config.row + config.height <= vim.o.lines).to_be_true()
      expect(config.col + config.width <= vim.o.columns).to_be_true()
    end)
  end)

  describe("closing", function()
    it("closes one float without touching the others", function()
      local first = float.create("aaa", { title = "a" })
      float.create("bbb", { title = "b" })

      float.close(first)

      expect(float.count()).to_be(1)
      expect(float.list()[1].session_id).to_be("bbb")
    end)

    it("closes every float of one conversation", function()
      -- An agent that ended cannot answer, so its floats must not linger.
      float.create("aaa", { title = "a1" })
      float.create("aaa", { title = "a2" })
      float.create("bbb", { title = "b" })

      expect(float.close_all("aaa")).to_be(2)
      expect(float.count()).to_be(1)
      expect(float.list()[1].session_id).to_be("bbb")
    end)

    it("forgets a float the user closed themselves", function()
      local win = float.create("aaa", { title = "a" })
      vim.api.nvim_win_close(win, true)
      expect(float.count()).to_be(0)
    end)

    it("closes everything when the view goes", function()
      float.create("aaa", { title = "a" })
      float.create("bbb", { title = "b" })
      expect(float.close_every()).to_be(2)
      expect(float.count()).to_be(0)
    end)
  end)

  describe("cycling", function()
    it("moves focus to the next float in the stack", function()
      local first = float.create("aaa", { title = "a" })
      local second = float.create("bbb", { title = "b" })

      vim.api.nvim_set_current_win(first)
      expect(float.focus_next()).to_be(second)
      vim.api.nvim_set_current_win(second)
      expect(float.focus_next()).to_be(first)
    end)

    it("does nothing when there is nothing open", function()
      expect(float.focus_next()).to_be(nil)
    end)
  end)
end)
