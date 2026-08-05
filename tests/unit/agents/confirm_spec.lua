-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.confirm", function()
  local confirm
  local opened -- config the stubbed snacks.win was called with
  local closed -- how many times the float closed itself

  ---Stand in for snacks.win: records the config and exposes the keymaps so a
  ---test can press a key without a real window.
  local function stub_snacks()
    opened, closed = nil, 0
    local win = {}
    win.close = function()
      closed = closed + 1
      if win.opts and win.opts.on_close then
        win.opts.on_close()
      end
    end
    package.loaded["snacks.win"] = setmetatable({}, {
      __call = function(_, cfg)
        opened = cfg
        win.opts = cfg
        return win
      end,
    })
    return win
  end

  local function press(win, lhs)
    win.opts.keys[lhs](win)
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["snacks.win"] = nil
    package.loaded["claudecode.agents.confirm"] = nil
    confirm = require("claudecode.agents.confirm")
  end)

  after_each(function()
    package.loaded["snacks.win"] = nil
    vim.fn.confirm = nil
  end)

  describe("the snacks float", function()
    it("answers yes and closes", function()
      local win = stub_snacks()
      local answers = {}
      confirm.ask({ title = "Delete session", message = "gone for good" }, function(ok)
        answers[#answers + 1] = ok
      end)

      expect(opened).to_be_table()
      expect(opened.enter).to_be_true()
      press(win, "y")
      expect(answers).to_be_table()
      expect(answers[1]).to_be_true()
      expect(closed).to_be(1)
    end)

    it("answers exactly once, even though closing also answers", function()
      -- Every key closes the window and closing answers "no", so without the
      -- guard a confirmed delete would be followed by a cancel.
      local win = stub_snacks()
      local answers = {}
      confirm.ask({ message = "gone for good" }, function(ok)
        answers[#answers + 1] = ok
      end)
      press(win, "<CR>")
      expect(#answers).to_be(1)
      expect(answers[1]).to_be_true()
    end)

    it("treats a plain close as no", function()
      local win = stub_snacks()
      local answer = nil
      confirm.ask({ message = "gone for good" }, function(ok)
        answer = ok
      end)
      win.close()
      expect(answer).to_be(false)
    end)

    it("cancels on q and on <Esc>", function()
      for _, key in ipairs({ "q", "<Esc>", "n" }) do
        local win = stub_snacks()
        local answer = nil
        confirm.ask({ message = "gone for good" }, function(ok)
          answer = ok
        end)
        press(win, key)
        expect(answer).to_be(false)
      end
    end)

    it("sizes itself around the question and shows how to answer", function()
      local win = stub_snacks()
      confirm.ask({ title = "Delete session", confirm = "delete", message = { "one", "two" } }, function() end)
      local text = opened.text
      expect(text[1]).to_be("one")
      expect(text[2]).to_be("two")
      expect(text[#text]:find("delete", 1, true) ~= nil).to_be_true()
      expect(opened.height).to_be(#text)
      expect(opened.width > 0).to_be_true()
      press(win, "n")
    end)
  end)

  describe("without snacks", function()
    it("falls back to vim.fn.confirm, defaulting to no", function()
      local asked = nil
      vim.fn.confirm = function(message, choices, default)
        asked = { message = message, choices = choices, default = default }
        return 2 -- "No"
      end

      local answer = nil
      confirm.ask({ title = "Delete session", message = "gone for good" }, function(ok)
        answer = ok
      end)

      expect(answer).to_be(false)
      expect(asked.default).to_be(2)
      expect(asked.message:find("gone for good", 1, true) ~= nil).to_be_true()
    end)

    it("passes a yes through", function()
      vim.fn.confirm = function()
        return 1
      end
      local answer = nil
      confirm.ask({ message = "gone for good" }, function(ok)
        answer = ok
      end)
      expect(answer).to_be_true()
    end)
  end)
end)
