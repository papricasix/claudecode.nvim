-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.input", function()
  local input

  ---Press a key the prompt bound on its buffer.
  local function press(buf, lhs)
    local map = vim._buf_keymaps[buf] and vim._buf_keymaps[buf].i and vim._buf_keymaps[buf].i[lhs]
    assert.is_truthy(map, "no mapping for " .. lhs)
    map.rhs()
  end

  ---The prompt's buffer: the newest scratch buffer with our filetype.
  local function prompt_buf()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_option(buf, "filetype") == "claudecode-agents-input" then
        return buf
      end
    end
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.input"] = nil
    package.loaded["claudecode.agents.render"] = nil
    require("claudecode.agents.render").setup({ agents = { enabled = true } })
    input = require("claudecode.agents.input")
    input.reset()
  end)

  it("opens on the default text and answers what was typed on <CR>, once", function()
    local answers = {}
    expect(input.ask({ title = "Name", default = "old" }, function(text)
      answers[#answers + 1] = text
    end)).to_be_true()
    local buf = prompt_buf()
    expect(buf ~= nil).to_be_true()
    assert.same({ "old" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    expect(input.is_open()).to_be_true()

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "new name" })
    press(buf, "<CR>")
    press(buf, "<Esc>") -- closing afterwards must not answer again
    assert.same({ "new name" }, answers)
    expect(input.is_open()).to_be(false)
  end)

  it("answers nil when cancelled", function()
    local answers, called = {}, false
    input.ask({ title = "Name" }, function(text)
      answers[#answers + 1] = text
      called = true
    end)
    press(prompt_buf(), "<Esc>")
    expect(called).to_be_true()
    expect(answers[1]).to_be(nil)
  end)

  it("answers an empty line as an empty string, which is how a name is cleared", function()
    local answer = "unset"
    input.ask({ default = "old" }, function(text)
      answer = text
    end)
    local buf = prompt_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    press(buf, "<CR>")
    expect(answer).to_be("")
  end)
end)
