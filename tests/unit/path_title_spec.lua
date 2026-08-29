-- luacheck: globals expect
-- How a float's border title names the file it is showing (`utils.path_title`).
-- Its own file rather than `utils_spec`, which deliberately loads `utils` bare,
-- with no Neovim at all; these rules are about display width and need one.
require("tests.busted_setup")

describe("claudecode.utils.path_title", function()
  local utils = require("claudecode.utils")

  it("names a file by where it is, not by its tail alone", function()
    expect(utils.path_title("/proj/lua/agents/init.lua", "/proj", nil, 60)).to_be("lua/agents/init.lua")
  end)

  it("shows a file outside the root as a path rather than a bare name", function()
    local home = os.getenv("HOME") or "/home/u"
    local title = utils.path_title(home .. "/.config/nvim/init.lua", "/proj", nil, 60)
    expect(title).to_be("~/.config/nvim/init.lua")
  end)

  it("keeps the note beside the path", function()
    expect(utils.path_title("/proj/lua/a.lua", "/proj", "(vs HEAD)", 60)).to_be("lua/a.lua  (vs HEAD)")
  end)

  it("cuts from the inside so the filename survives a narrow border", function()
    -- Neovim cuts a title that does not fit at its right edge, which is the one
    -- part the title exists to show.
    local title = utils.path_title("/proj/lua/claudecode/agents/deep/file_view.lua", "/proj", nil, 22)
    expect(title:find("…", 1, true) ~= nil).to_be_true()
    expect(title:sub(-13)).to_be("file_view.lua")
    expect(vim.fn.strdisplaywidth(title) <= 22).to_be_true()
  end)

  it("makes room for the note before fitting the path", function()
    local title = utils.path_title("/proj/lua/claudecode/agents/deep/file_view.lua", "/proj", "(read)", 22)
    expect(title:sub(-8)).to_be("  (read)")
    expect(vim.fn.strdisplaywidth(title) <= 22).to_be_true()
  end)

  it("answers with the note alone when there is no path", function()
    expect(utils.path_title(nil, "/proj", "(read)", 60)).to_be("(read)")
    expect(utils.path_title(nil, "/proj", nil, 60)).to_be("")
  end)
end)
