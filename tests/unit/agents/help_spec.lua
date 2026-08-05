-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.help", function()
  local help

  local ENTRIES = {
    { group = "Sessions", keys = { { lhs = "<CR>", desc = "Show this session" }, { lhs = "a", desc = "New agent" } } },
    { group = "Anywhere in the view", keys = { { lhs = "q", desc = "Close the view" } } },
  }

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

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["snacks.win"] = nil
    package.loaded["claudecode.agents.help"] = nil
    help = require("claudecode.agents.help")
  end)

  after_each(function()
    package.loaded["snacks.win"] = nil
  end)

  describe("render", function()
    it("pads the key column so the descriptions line up", function()
      local lines = help.render(ENTRIES)
      expect(lines[1]).to_be("Sessions")
      expect(lines[2]).to_be("  <CR>  Show this session")
      expect(lines[3]).to_be("  a     New agent")
      -- The descriptions of both keys start in the same column.
      expect(lines[2]:find("Show", 1, true)).to_be(lines[3]:find("New", 1, true))
    end)

    it("separates groups with a blank line and heads each one", function()
      local lines = help.render(ENTRIES)
      expect(lines[4]).to_be("")
      expect(lines[5]).to_be("Anywhere in the view")
      expect(lines[6]).to_be("  q     Close the view")
    end)

    it("marks the headings and the keys, and nothing else", function()
      local _, marks = help.render(ENTRIES)
      -- Two headings and three keys.
      expect(#marks).to_be(5)
      expect(marks[1].hl).to_be("ClaudeCodeAgentsHelpHeader")
      expect(marks[1].row).to_be(0)
      expect(marks[2].hl).to_be("ClaudeCodeAgentsKey")
      expect(marks[2].col).to_be(2)
      expect(marks[2].end_col).to_be(6) -- "<CR>"
    end)
  end)

  describe("opening", function()
    it("floats natively when snacks is absent", function()
      expect(help.open(ENTRIES, "sessions")).to_be_true()
      expect(help.is_open()).to_be_true()
    end)

    it("uses snacks when it is there, with our own buffer", function()
      local win = stub_snacks()
      expect(help.open(ENTRIES, "changes")).to_be_true()
      expect(type(win.opts.buf)).to_be("number")
      expect(win.opts.enter).to_be_true()
      expect(win.opts.title:find("Changes", 1, true) ~= nil).to_be_true()
    end)

    it("toggles: asking again while it is open closes it", function()
      expect(help.open(ENTRIES, "sessions")).to_be_true()
      expect(help.open(ENTRIES, "sessions")).to_be(false)
      expect(help.is_open()).to_be(false)
    end)

    it("closes on request", function()
      help.open(ENTRIES, "sessions")
      help.close()
      expect(help.is_open()).to_be(false)
    end)

    it("shows nothing when the pane has no keys at all", function()
      expect(help.open({}, "sessions")).to_be(false)
      expect(help.is_open()).to_be(false)
    end)
  end)
end)
