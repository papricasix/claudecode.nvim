-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.checkpoints", function()
  local checkpoints
  local store -- what the stubbed file holds, as lines
  local writes

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    store, writes = nil, 0
    -- The mock's decoder is a stub; the store is read back through a real one.
    vim.json.decode = _G.json_decode
    package.loaded["claudecode.agents.checkpoints"] = nil
    checkpoints = require("claudecode.agents.checkpoints")
    checkpoints.reset()
    checkpoints._io = {
      read = function()
        return store
      end,
      write = function(_, lines)
        writes = writes + 1
        store = lines
      end,
    }
  end)

  describe("the store", function()
    it("starts empty", function()
      expect(#checkpoints.list("s")).to_be(0)
    end)

    it("stacks checkpoints on a conversation, oldest first, and writes each one", function()
      expect(checkpoints.add("s", 200)).to_be(200)
      local ts, count = checkpoints.add("s", 100)
      expect(ts).to_be(100)
      expect(count).to_be(2)
      assert.same({ 100, 200 }, checkpoints.list("s"))
      expect(writes).to_be(2)
      assert.same({}, checkpoints.list("other"))
    end)

    it("refuses a second checkpoint in the same second", function()
      checkpoints.add("s", 100)
      local ts, count = checkpoints.add("s", 100)
      expect(ts).to_be(nil)
      expect(count).to_be(1)
      expect(writes).to_be(1)
    end)

    it("drops the newest first, and says when there is none", function()
      checkpoints.add("s", 100)
      checkpoints.add("s", 200)
      local ts, left = checkpoints.drop("s")
      expect(ts).to_be(200)
      expect(left).to_be(1)
      expect(checkpoints.drop("s")).to_be(100)
      expect(checkpoints.drop("s")).to_be(nil)
      expect(#checkpoints.list("s")).to_be(0)
    end)

    it("forgets a deleted conversation's checkpoints", function()
      checkpoints.add("s", 100)
      checkpoints.add("t", 100)
      checkpoints.forget("s")
      expect(#checkpoints.list("s")).to_be(0)
      expect(#checkpoints.list("t")).to_be(1)
    end)

    it("hands out a copy, so a caller cannot edit the store", function()
      checkpoints.add("s", 100)
      local list = checkpoints.list("s")
      list[1] = 999
      expect(checkpoints.list("s")[1]).to_be(100)
    end)

    it("reads back what it wrote, across a reload", function()
      checkpoints.add("s", 300)
      checkpoints.add("s", 100)
      checkpoints.reset()
      assert.same({ 100, 300 }, checkpoints.list("s"))
    end)

    it("ignores a store it cannot read or from another version", function()
      store = { "not json" }
      expect(#checkpoints.list("s")).to_be(0)
      checkpoints.reset()
      store = { vim.json.encode({ version = 99, sessions = { s = { 1 } } }) }
      expect(#checkpoints.list("s")).to_be(0)
    end)

    it("drops what is not a moment when reading", function()
      store = { vim.json.encode({ version = 2, sessions = { s = { marks = { 5, "x", 0, 3 } }, t = "no" } }) }
      assert.same({ 3, 5 }, checkpoints.list("s"))
      expect(#checkpoints.list("t")).to_be(0)
    end)

    it("still reads a version 1 store, which held the bare list", function()
      store = { vim.json.encode({ version = 1, sessions = { s = { 5, 3 } } }) }
      assert.same({ 3, 5 }, checkpoints.list("s"))
      assert.same({}, checkpoints.names("s"))
    end)
  end)

  describe("names", function()
    it("names a checkpoint, and only one that exists", function()
      checkpoints.add("s", 100)
      expect(checkpoints.set_name("s", 100, "before the refactor")).to_be_true()
      expect(checkpoints.set_name("s", 999, "nope")).to_be(false)
      assert.same({ [100] = "before the refactor" }, checkpoints.names("s"))
    end)

    it("tidies the name and clears it with an empty one", function()
      checkpoints.add("s", 100)
      checkpoints.set_name("s", 100, "  reviewed\nup to here  ")
      expect(checkpoints.names("s")[100]).to_be("reviewed up to here")
      expect(checkpoints.set_name("s", 100, "   ")).to_be_true()
      assert.same({}, checkpoints.names("s"))
    end)

    it("reads names back across a reload, and forgets one dropped or deleted", function()
      checkpoints.add("s", 100)
      checkpoints.add("s", 200)
      checkpoints.set_name("s", 100, "first")
      checkpoints.set_name("s", 200, "second")
      checkpoints.reset()
      assert.same({ [100] = "first", [200] = "second" }, checkpoints.names("s"))

      checkpoints.drop("s")
      checkpoints.reset()
      assert.same({ [100] = "first" }, checkpoints.names("s"))

      checkpoints.forget("s")
      checkpoints.reset()
      assert.same({}, checkpoints.names("s"))
    end)

    it("keeps no name for a moment that is not a checkpoint", function()
      store =
        { vim.json.encode({ version = 2, sessions = { s = { marks = { 5 }, names = { ["5"] = "a", ["9"] = "b" } } } }) }
      assert.same({ [5] = "a" }, checkpoints.names("s"))
    end)
  end)

  describe("eras", function()
    local marks = { 100, 200 }

    it("puts a moment at or before a checkpoint in the era before it", function()
      expect(checkpoints.era(marks, 50)).to_be(1)
      expect(checkpoints.era(marks, 100)).to_be(1)
      expect(checkpoints.era(marks, 101)).to_be(2)
      expect(checkpoints.era(marks, 200)).to_be(2)
      expect(checkpoints.era(marks, 201)).to_be(3)
    end)

    it("reads nothing known as the oldest era", function()
      expect(checkpoints.era(marks, nil)).to_be(1)
      expect(checkpoints.era(marks, 0)).to_be(1)
      expect(checkpoints.era({}, 5)).to_be(1)
    end)

    it("names an era's bounds, open at either end", function()
      local from, to = checkpoints.bounds(marks, 1)
      expect(from).to_be(nil)
      expect(to).to_be(100)
      from, to = checkpoints.bounds(marks, 2)
      expect(from).to_be(100)
      expect(to).to_be(200)
      from, to = checkpoints.bounds(marks, 3)
      expect(from).to_be(200)
      expect(to).to_be(nil)
    end)
  end)

  describe("labels", function()
    -- A moment and the same day's noon, in local time, so the date rule can be
    -- checked without knowing the zone.
    local ts = os.time({ year = 2026, month = 9, day = 17, hour = 14, min = 32, sec = 0 })
    local same_day = os.time({ year = 2026, month = 9, day = 17, hour = 20, min = 0, sec = 0 })
    local next_day = os.time({ year = 2026, month = 9, day = 18, hour = 9, min = 0, sec = 0 })

    it("is the clock alone on the day it was taken", function()
      expect(checkpoints.label(ts, same_day)).to_be("14:32")
    end)

    it("carries the date from the next day on", function()
      expect(checkpoints.label(ts, next_day)).to_be("Sep 17 14:32")
    end)

    it("names an era by the checkpoints around it", function()
      local marks = { ts, ts + 3600 }
      expect(checkpoints.era_note(marks, 1, same_day)).to_be("until 14:32")
      expect(checkpoints.era_note(marks, 2, same_day)).to_be("14:32 – 15:32")
      expect(checkpoints.era_note(marks, 3, same_day)).to_be("since 15:32")
      expect(checkpoints.era_note({}, 1, same_day)).to_be("")
    end)
  end)
end)
