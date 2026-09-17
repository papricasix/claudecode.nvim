-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.patch", function()
  local patch

  ---A hunk in the CLI's own shape.
  local function hunk(new_start, lines, old_start)
    return {
      oldStart = old_start or new_start,
      oldLines = 0,
      newStart = new_start,
      newLines = 0,
      lines = lines,
    }
  end

  before_each(function()
    package.loaded["claudecode.agents.patch"] = nil
    patch = require("claudecode.agents.patch")
  end)

  describe("sides", function()
    it("splits a hunk into its before and after", function()
      local new_side, old_side = patch.sides(hunk(1, { " keep", "-gone", "+fresh", " tail" }))
      expect(table.concat(new_side, "|")).to_be("keep|fresh|tail")
      expect(table.concat(old_side, "|")).to_be("keep|gone|tail")
    end)

    it("treats an unprefixed line as context, so neither side shifts", function()
      -- A truncation marker, or anything else the CLI writes without a prefix:
      -- dropping it from one side would misalign every line after it.
      local new_side, old_side = patch.sides(hunk(1, { "… truncated" }))
      expect(#new_side).to_be(1)
      expect(#old_side).to_be(1)
    end)

    it("leaves a no-newline marker out of both sides", function()
      -- It annotates the line before it. As context it put a line in the block
      -- that no file holds, and the hunk never located.
      local new_side, old_side = patch.sides(hunk(1, { "-last", "\\ No newline at end of file", "+last" }))
      expect(table.concat(new_side, "|")).to_be("last")
      expect(table.concat(old_side, "|")).to_be("last")
    end)
  end)

  describe("shown", function()
    it("writes a line the way the CLI writes it into a patch", function()
      expect(patch.shown("\tif x then")).to_be("  if x then")
      expect(patch.shown("a\tb")).to_be("a  b")
      expect(patch.shown("crlf\r")).to_be("crlf")
    end)
  end)

  describe("locate", function()
    it("finds the block where the patch says it is", function()
      local lines = { "a", "b", "c", "d" }
      expect(patch.locate(lines, { "b", "c" }, 1)).to_be(1)
    end)

    it("finds it after the file shifted, preferring the nearest match", function()
      -- The same two lines appear twice; the one the patch pointed at wins.
      local lines = { "b", "c", "x", "x", "x", "b", "c" }
      expect(patch.locate(lines, { "b", "c" }, 5)).to_be(5)
      expect(patch.locate(lines, { "b", "c" }, 0)).to_be(0)
    end)

    it("answers nil when the block is gone", function()
      expect(patch.locate({ "a", "b" }, { "q" }, 0)).to_be_nil()
    end)
  end)

  describe("reverse_apply", function()
    it("undoes an edit, yielding what the session started from", function()
      local now = { "one", "TWO", "three" }
      local before, applied, skipped = patch.reverse_apply(now, { hunk(2, { "-two", "+TWO" }) })
      expect(table.concat(before, "|")).to_be("one|two|three")
      expect(applied).to_be(1)
      expect(skipped).to_be(0)
    end)

    it("undoes several edits newest-first, so earlier line numbers still hold", function()
      local now = { "ONE", "two", "THREE" }
      local before, applied = patch.reverse_apply(now, {
        hunk(1, { "-one", "+ONE" }),
        hunk(3, { "-three", "+THREE" }),
      })
      expect(table.concat(before, "|")).to_be("one|two|three")
      expect(applied).to_be(2)
    end)

    it("locates a hunk that moved, since the file grew above it", function()
      local now = { "new", "header", "ONE", "two" }
      local before, applied, skipped = patch.reverse_apply(now, { hunk(1, { "-one", "+ONE" }) })
      expect(table.concat(before, "|")).to_be("new|header|one|two")
      expect(applied).to_be(1)
      expect(skipped).to_be(0)
    end)

    it("skips a change that is no longer in the file, and says so", function()
      -- Overwritten by later work: leaving it out is the honest answer, and the
      -- count is what the caller reports instead of showing a partial diff silently.
      local now = { "something", "else" }
      local before, applied, skipped = patch.reverse_apply(now, { hunk(1, { "-one", "+ONE" }) })
      expect(table.concat(before, "|")).to_be("something|else")
      expect(applied).to_be(0)
      expect(skipped).to_be(1)
    end)

    it("leaves the input untouched", function()
      local now = { "ONE" }
      patch.reverse_apply(now, { hunk(1, { "-one", "+ONE" }) })
      expect(table.concat(now, "|")).to_be("ONE")
    end)

    it("locates a hunk that came from a no-newline edit", function()
      local now = { "a", "LAST" }
      local before, applied = patch.reverse_apply(now, {
        hunk(1, { " a", "-last", "\\ No newline at end of file", "+LAST" }),
      })
      expect(applied).to_be(1)
      expect(table.concat(before, "|")).to_be("a|last")
    end)

    describe("in a tab-indented file", function()
      -- The CLI writes each tab in a patch as two spaces; the file has the tab.
      -- Matched verbatim, none of these hunks ever located.

      it("undoes every edit, not only the ones without a tab in them", function()
        local now = { "func a():", "\tTWO", "", "func b():", "\tFOUR" }
        local before, applied, skipped = patch.reverse_apply(now, {
          hunk(1, { " func a():", "-  two", "+  TWO" }),
          hunk(4, { " func b():", "-  four", "+  FOUR" }),
        })
        expect(applied).to_be(2)
        expect(skipped).to_be(0)
        expect(table.concat(before, "|")).to_be("func a():|\ttwo||func b():|\tfour")
      end)

      it("keeps context lines as the file has them", function()
        -- Taken from the patch, the untouched `\tkeep` came back as spaces and read
        -- as a change the session never made.
        local now = { "\tkeep", "\tNEW" }
        local before = patch.reverse_apply(now, { hunk(1, { "   keep", "-  old", "+  NEW" }) })
        expect(before[1]).to_be("\tkeep")
      end)

      it("puts a removed line back with its tabs", function()
        local now = { "\tkeep", "\t\tNEW" }
        local before = patch.reverse_apply(now, { hunk(1, { "   keep", "-    old", "+    NEW" }) })
        expect(before[2]).to_be("\t\told")
      end)

      it("prefers the result's own text for a removed line over re-tabbing", function()
        -- Alignment spaces after a tab cannot be told from tabs by counting.
        local now = { "\tkeep", "\tNEW" }
        local h = hunk(1, { "   keep", "-      old", "+  NEW" })
        h.exact_old = { [2] = "\t    old" }
        local before = patch.reverse_apply(now, { h })
        expect(before[2]).to_be("\t    old")
      end)

      it("leaves the spaces of a space-indented file alone", function()
        local now = { "  keep", "  NEW" }
        local before = patch.reverse_apply(now, { hunk(1, { "   keep", "-  old", "+  NEW" }) })
        expect(before[2]).to_be("  old")
      end)
    end)
  end)

  describe("annotate", function()
    it("takes a removed line from originalFile, by its position", function()
      local h = hunk(2, { "   keep", "-      old", "+  NEW" }, 2)
      patch.annotate({ h }, { originalFile = "top\n\tkeep\n\t    old\n", oldString = "x" })
      expect(h.exact_old[2]).to_be("\t    old")
    end)

    it("falls back to oldString when originalFile was left out", function()
      -- The CLI drops originalFile for files above ~10KB; oldString is always there.
      local h = hunk(1, { "   keep", "-    old", "+    NEW" })
      patch.annotate({ h }, { originalFile = vim.NIL, oldString = "\t\told" })
      expect(h.exact_old[2]).to_be("\t\told")
    end)

    it("records nothing for a line that could not have held a tab", function()
      local h = hunk(1, { "-old", "+new" })
      patch.annotate({ h }, { oldString = "old" })
      expect(h.exact_old).to_be_nil()
    end)

    it("ignores an originalFile line that is not the patch's line", function()
      local h = hunk(1, { "-  old", "+  new" })
      patch.annotate({ h }, { originalFile = "\tsomething else\n" })
      expect(h.exact_old).to_be_nil()
    end)
  end)

  describe("to_diff_lines", function()
    it("renders the hunks as unified-diff text", function()
      local out = patch.to_diff_lines("/proj/a.lua", {
        { oldStart = 1, oldLines = 1, newStart = 1, newLines = 1, lines = { "-one", "+ONE" } },
      })
      expect(out[1]).to_be("--- a//proj/a.lua")
      expect(out[2]).to_be("+++ b//proj/a.lua")
      expect(out[3]).to_be("@@ -1,1 +1,1 @@")
      expect(out[4]).to_be("-one")
      expect(out[5]).to_be("+ONE")
    end)
  end)
end)
