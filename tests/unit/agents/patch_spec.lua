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

    it("takes an added line from newString, for redoing the edit", function()
      local h = hunk(1, { "-old", "+  new()" })
      patch.annotate({ h }, { oldString = "old", newString = "\tnew()" })
      expect(h.exact_new[1]).to_be("\tnew()")
      expect(h.exact_old).to_be_nil()
    end)
  end)

  describe("split_lines", function()
    it("reads text the way readfile reads a file", function()
      assert.same({ "a", "b" }, patch.split_lines("a\nb\n"))
      assert.same({ "a", "b" }, patch.split_lines("a\r\nb"))
      assert.same({ "a", "" }, patch.split_lines("a\n\n"))
      assert.same({}, patch.split_lines(""))
    end)
  end)

  describe("forward_apply", function()
    it("redoes an edit, yielding what the call left behind", function()
      local after, applied, skipped = patch.forward_apply(
        { "one", "two", "three" },
        { hunk(2, { " one", "-two", "+TWO", " three" }) }
      )
      assert.same({ "one", "TWO", "three" }, after)
      expect(applied).to_be(1)
      expect(skipped).to_be(0)
    end)

    it("applies one call's hunks bottom-up, so earlier positions still hold", function()
      -- Both hunks are numbered against the file before the call.
      local after = patch.forward_apply({ "a", "b", "c" }, {
        hunk(1, { "-a", "+A", "+A2" }, 1),
        hunk(4, { "-c", "+C" }, 3),
      })
      assert.same({ "A", "A2", "b", "C" }, after)
    end)

    it("locates a hunk that moved, since the file grew above it", function()
      local after = patch.forward_apply({ "new", "one", "two" }, { hunk(1, { "-two", "+TWO" }, 2) })
      assert.same({ "new", "one", "TWO" }, after)
    end)

    it("inserts into an empty file where the patch says", function()
      local after, applied = patch.forward_apply({}, {
        { oldStart = 0, oldLines = 0, newStart = 1, newLines = 2, lines = { "+a", "+b" } },
      })
      assert.same({ "a", "b" }, after)
      expect(applied).to_be(1)
    end)

    it("skips a hunk whose old side is not in the file, and says so", function()
      local after, applied, skipped = patch.forward_apply({ "x" }, { hunk(1, { "-gone", "+new" }) })
      assert.same({ "x" }, after)
      expect(applied).to_be(0)
      expect(skipped).to_be(1)
    end)

    it("puts an added line back with its tab, from newString", function()
      local h = hunk(1, { " func a():", "-  old()", "+  new()" })
      patch.annotate({ h }, { oldString = "\told()", newString = "\tnew()" })
      local after = patch.forward_apply({ "func a():", "\told()" }, { h })
      assert.same({ "func a():", "\tnew()" }, after)
    end)

    it("re-tabs an added line by its block when the result's text is missing", function()
      local h = hunk(1, { " func a():", "-  old()", "+  new()" })
      local after = patch.forward_apply({ "func a():", "\told()" }, { h })
      assert.same({ "func a():", "\tnew()" }, after)
    end)
  end)

  describe("reconstruct", function()
    local function step(hunks, extra)
      local s = { hunks = hunks, created = false }
      for k, v in pairs(extra or {}) do
        s[k] = v
      end
      return s
    end

    it("walks forward from an originalFile", function()
      local states = patch.reconstruct({
        step({ hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\nthree\n" }),
        step({ hunk(3, { "-three", "+THREE" }) }),
      })
      assert.same({ "one", "two", "three" }, states[0])
      assert.same({ "one", "TWO", "three" }, states[1])
      assert.same({ "one", "TWO", "THREE" }, states[2])
    end)

    it("walks back from a write's content", function()
      local states = patch.reconstruct({
        step({ hunk(2, { "-two", "+TWO" }) }),
        step({ hunk(3, { "-three", "+THREE" }) }, { content = "one\nTWO\nTHREE\n" }),
      })
      assert.same({ "one", "two", "three" }, states[0])
      assert.same({ "one", "TWO", "three" }, states[1])
      assert.same({ "one", "TWO", "THREE" }, states[2])
    end)

    it("anchors the end on a whole read after the last step", function()
      local states = patch.reconstruct({ step({ hunk(1, { "-a", "+A" }) }) }, { step = 1, content = "A\nb\n" })
      assert.same({ "A", "b" }, states[1])
      assert.same({ "a", "b" }, states[0])
    end)

    it("starts a created file from nothing", function()
      local states = patch.reconstruct({ step({}, { content = "a\n", created = true }) })
      assert.same({}, states[0])
      assert.same({ "a" }, states[1])
    end)

    it("knows nothing without an anchor", function()
      local states = patch.reconstruct({ step({ hunk(1, { "-a", "+A" }) }) })
      expect(states[0]).to_be_nil()
      expect(states[1]).to_be_nil()
    end)

    it("leaves states unknown past a step that no longer applies, until the next anchor", function()
      -- Something outside the session changed the file between steps 1 and 2:
      -- step 2's old side is nowhere in the state step 1 produced.
      local states = patch.reconstruct({
        step({ hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\n" }),
        step({ hunk(1, { "-gone", "+GONE" }) }),
        step({ hunk(2, { "-x", "+X" }) }),
      })
      assert.same({ "one", "TWO" }, states[1])
      expect(states[2]).to_be_nil()
      expect(states[3]).to_be_nil()

      states = patch.reconstruct({
        step({ hunk(2, { "-two", "+TWO" }) }, { before = "one\ntwo\n" }),
        step({ hunk(1, { "-gone", "+GONE" }) }),
        step({ hunk(2, { "-x", "+X" }) }, { content = "GONE\nX\n" }),
      })
      assert.same({ "one", "TWO" }, states[1])
      assert.same({ "GONE", "x" }, states[2])
      assert.same({ "GONE", "X" }, states[3])
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
