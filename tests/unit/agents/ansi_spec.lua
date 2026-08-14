-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.ansi", function()
  local ansi

  ---The mark covering `text` on `row`, if there is one.
  local function mark_over(clean, marks, row, text)
    local at = clean[row]:find(text, 1, true)
    if not at then
      return nil
    end
    for _, mark in ipairs(marks) do
      if mark.row == row - 1 and mark.col <= at - 1 and mark.end_col >= at - 1 + #text then
        return mark
      end
    end
    return nil
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.ansi"] = nil
    ansi = require("claudecode.agents.ansi")
    ansi.reset()
  end)

  describe("stripping", function()
    it("leaves the text a command actually wrote", function()
      local clean = ansi.parse({ "\27[32mPASS\27[0m  foo_spec.lua" })
      expect(clean[1]).to_be("PASS  foo_spec.lua")
    end)

    it("drops what a buffer cannot act on", function()
      -- Cursor moves, erases and an OSC title are a terminal's business; left in
      -- they would show as litter.
      local clean = ansi.parse({ "\27[2K\27[1;1H\27]0;a title\7done", "\27]8;;file:///x\27\\linked\27]8;;\27\\" })
      expect(clean[1]).to_be("done")
      expect(clean[2]).to_be("linked")
    end)

    it("says whether there is anything to parse at all", function()
      expect(ansi.has_escapes({ "plain", "text" })).to_be_false()
      expect(ansi.has_escapes({ "plain", "\27[31mred" })).to_be_true()
    end)
  end)

  describe("colour", function()
    it("highlights the span a colour was opened over", function()
      local clean, marks = ansi.parse({ "\27[32mPASS\27[0m  foo" })
      local mark = mark_over(clean, marks, 1, "PASS")
      expect(mark).not_to_be_nil()
      expect(mark.col).to_be(0)
      expect(mark.end_col).to_be(4)
    end)

    it("does not colour what came after the reset", function()
      local clean, marks = ansi.parse({ "\27[32mPASS\27[0m  foo" })
      expect(mark_over(clean, marks, 1, "foo")).to_be_nil()
    end)

    it("survives a parameter list, rather than being reset by its own trailing field", function()
      -- Splitting with `gmatch("[^;]*")` yields an extra empty match at the end,
      -- which reads as a trailing `0` — that reset every colour immediately after
      -- setting it, and nothing was ever highlighted.
      local clean, marks = ansi.parse({ "\27[1;31mFAIL\27[0m rest" })
      local mark = mark_over(clean, marks, 1, "FAIL")
      expect(mark).not_to_be_nil()
      local spec = (vim._highlights or {})[mark.hl]
      expect(spec).not_to_be_nil()
      expect(spec.bold).to_be_true()
      expect(type(spec.fg)).to_be("string")
    end)

    it("resolves a 256-colour index", function()
      expect(ansi.xterm_hex(208)).to_be("#ff8700")
      expect(ansi.xterm_hex(232)).to_be("#080808")
      expect(ansi.xterm_hex(300)).to_be_nil()
    end)

    it("takes the sixteen from the user's own terminal colours", function()
      vim.g.terminal_color_2 = "#00ff00"
      local _, marks = ansi.parse({ "\27[32mgreen\27[0m" })
      local spec = (vim._highlights or {})[marks[1].hl]
      expect(spec.fg).to_be("#00ff00")
      vim.g.terminal_color_2 = nil
    end)

    it("reads a 24-bit colour", function()
      local _, marks = ansi.parse({ "\27[38;2;18;52;86mtruecolor\27[39m" })
      local spec = (vim._highlights or {})[marks[1].hl]
      expect(spec.fg).to_be("#123456")
    end)

    it("keeps a background separate from a foreground", function()
      local _, marks = ansi.parse({ "\27[41;37mwarn\27[0m" })
      local spec = (vim._highlights or {})[marks[1].hl]
      expect(type(spec.fg)).to_be("string")
      expect(type(spec.bg)).to_be("string")
    end)
  end)

  describe("attributes", function()
    it("carries bold, italic and underline", function()
      local clean, marks = ansi.parse({ "\27[4munderlined\27[24m plain" })
      local mark = mark_over(clean, marks, 1, "underlined")
      expect((vim._highlights or {})[mark.hl].underline).to_be_true()
      expect(mark_over(clean, marks, 1, "plain")).to_be_nil()
    end)

    it("reuses one group per distinct appearance", function()
      local _, marks = ansi.parse({ "\27[31mone\27[0m", "\27[31mtwo\27[0m" })
      expect(#marks).to_be(2)
      expect(marks[1].hl).to_be(marks[2].hl)
    end)
  end)

  describe("state across lines", function()
    it("keeps a colour open until the command closes it", function()
      -- A terminal does; a command that opens a colour and writes several lines
      -- before resetting is ordinary.
      local clean, marks = ansi.parse({ "\27[31mfirst", "second", "third\27[0m" })
      expect(clean[2]).to_be("second")
      expect(mark_over(clean, marks, 2, "second")).not_to_be_nil()
      expect(mark_over(clean, marks, 3, "third")).not_to_be_nil()
    end)

    it("leaves plain output entirely unmarked", function()
      local clean, marks = ansi.parse({ "nothing here", "or here" })
      expect(#marks).to_be(0)
      expect(clean[1]).to_be("nothing here")
    end)
  end)
end)
