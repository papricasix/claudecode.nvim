-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.sort_menu", function()
  local menu
  local SORTS = require("claudecode.agents.model").SORTS

  ---Stand in for snacks.win, so both float paths can be exercised without one.
  local function stub_snacks()
    local win = { win = 4242 }
    win.close = function()
      if win.opts and win.opts.on_close then
        win.opts.on_close()
      end
    end
    package.loaded["snacks.win"] = setmetatable({}, {
      __call = function(_, cfg)
        win.opts = cfg
        return win
      end,
    })
    return win
  end

  ---Press a key on the menu's buffer, the way the user would.
  local function press(buf, lhs)
    local entry = vim._buf_keymaps[buf] and vim._buf_keymaps[buf].n and vim._buf_keymaps[buf].n[lhs]
    assert(entry, "no mapping for " .. lhs)
    entry.rhs()
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["snacks.win"] = nil
    package.loaded["claudecode.agents.sort_menu"] = nil
    menu = require("claudecode.agents.sort_menu")
  end)

  after_each(function()
    package.loaded["snacks.win"] = nil
  end)

  describe("render", function()
    it("offers every criterion with its accelerator", function()
      local lines = menu.render(SORTS, { key = "recent", desc = true })
      expect(lines[1]:find("r  Recent activity", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("n  Name", 1, true) ~= nil).to_be_true()
      expect(lines[3]:find("c  Changes", 1, true) ~= nil).to_be_true()
      expect(lines[4]:find("s  Status", 1, true) ~= nil).to_be_true()
    end)

    it("marks the active criterion and says which way it runs", function()
      local lines = menu.render(SORTS, { key = "recent", desc = true })
      expect(lines[1]:find("❯", 1, true)).to_be(1)
      -- In the words of the thing being sorted: the menu is the only place the
      -- order is stated, so "↓" would leave the reader to work it out.
      expect(lines[1]:find("newest first", 1, true) ~= nil).to_be_true()
      expect(lines[2]:find("A → Z", 1, true)).to_be(nil) -- only the active one
    end)

    it("names the reversed direction when the criterion is reversed", function()
      local lines = menu.render(SORTS, { key = "name", desc = true })
      expect(lines[2]:find("Z → A", 1, true) ~= nil).to_be_true()
      local ascending = menu.render(SORTS, { key = "name", desc = false })
      expect(ascending[2]:find("A → Z", 1, true) ~= nil).to_be_true()
    end)

    it("says that picking the active one again reverses it", function()
      local lines = menu.render(SORTS, { key = "recent", desc = true })
      expect(lines[#lines]:find("reverse", 1, true) ~= nil).to_be_true()
    end)

    it("reports which line offers which criterion", function()
      local _, _, by_line = menu.render(SORTS, { key = "recent", desc = true })
      expect(by_line[1]).to_be("recent")
      expect(by_line[4]).to_be("status")
      expect(by_line[6]).to_be(nil) -- the footer is not a choice
    end)
  end)

  describe("opening", function()
    it("floats natively when snacks is absent", function()
      expect(menu.open(SORTS, { key = "recent", desc = true }, function() end)).to_be_true()
      expect(menu.is_open()).to_be_true()
    end)

    it("uses snacks when it is there, with our own buffer", function()
      local win = stub_snacks()
      expect(menu.open(SORTS, { key = "recent", desc = true }, function() end)).to_be_true()
      expect(type(win.opts.buf)).to_be("number")
      expect(win.opts.enter).to_be_true()
      expect(win.opts.title:find("Sort sessions", 1, true) ~= nil).to_be_true()
    end)

    it("toggles: asking again while it is open closes it", function()
      expect(menu.open(SORTS, { key = "recent", desc = true }, function() end)).to_be_true()
      expect(menu.open(SORTS, { key = "recent", desc = true }, function() end)).to_be(false)
      expect(menu.is_open()).to_be(false)
    end)
  end)

  describe("picking", function()
    it("answers with the criterion whose key was pressed, and closes", function()
      local win = stub_snacks()
      local picked = {}
      menu.open(SORTS, { key = "recent", desc = true }, function(key)
        picked[#picked + 1] = key
      end)
      press(win.opts.buf, "c")
      expect(picked[1]).to_be("changes")
      expect(menu.is_open()).to_be(false)
    end)

    it("answers exactly once, however many times the buffer's keys are pressed", function()
      -- A buffer-local mapping outlives the close it triggered, and the buffer is
      -- still there for as long as anything holds it.
      local win = stub_snacks()
      local picked = {}
      menu.open(SORTS, { key = "recent", desc = true }, function(key)
        picked[#picked + 1] = key
      end)
      press(win.opts.buf, "n")
      press(win.opts.buf, "s")
      expect(#picked).to_be(1)
      expect(picked[1]).to_be("name")
    end)

    -- The native path, where the window is a real one as far as the mock is
    -- concerned and so has a cursor to move.
    it("picks the row under the cursor on <CR>", function()
      local picked
      menu.open(SORTS, { key = "recent", desc = true }, function(key)
        picked = key
      end)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, { 3, 0 })
      press(vim.api.nvim_win_get_buf(win), "<CR>")
      expect(picked).to_be("changes")
    end)

    it("starts the cursor on the criterion already in force", function()
      menu.open(SORTS, { key = "changes", desc = true }, function() end)
      expect(vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]).to_be(3)
    end)
  end)
end)
