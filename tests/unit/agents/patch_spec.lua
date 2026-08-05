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
      local new_side, old_side = patch.sides(hunk(1, { "\\ No newline at end of file" }))
      expect(#new_side).to_be(1)
      expect(#old_side).to_be(1)
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
