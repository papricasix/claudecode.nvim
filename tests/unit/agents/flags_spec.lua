-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.flags", function()
  local flags
  local store -- what the stubbed file holds; nil when there is no file
  local writes
  local reads
  local unreadable -- the file is there, and reading it fails

  ---Write the file the way another Neovim would: behind this module's back.
  local function write_elsewhere(sessions)
    store = _G.json_encode({ version = 1, sessions = sessions })
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    store, writes, reads, unreadable = nil, 0, 0, false
    -- The mock's decoder is a stub; the store is read back through a real one.
    vim.json.decode = _G.json_decode
    package.loaded["claudecode.agents.flags"] = nil
    flags = require("claudecode.agents.flags")
    flags.reset()
    flags._io = {
      read = function()
        reads = reads + 1
        if unreadable then
          return nil
        end
        return store
      end,
      write = function(_, data)
        writes = writes + 1
        store = data
        return true
      end,
      -- The content stands in for size and mtime: it changes exactly when the
      -- file does.
      stat = function()
        return store
      end,
    }
  end)

  describe("a bare flag", function()
    it("starts with none", function()
      expect(flags.get("s")).to_be(nil)
      expect(flags.pending("s")).to_be(false)
      assert.same({}, flags.all())
    end)

    it("is set and taken off by the same toggle", function()
      local flag = flags.toggle("s", 100)
      expect(flag.at).to_be(100)
      expect(flag.note).to_be(nil)
      expect(flags.get("s").at).to_be(100)
      expect(flags.pending("s")).to_be_true()

      expect(flags.toggle("s", 200)).to_be(nil)
      expect(flags.get("s")).to_be(nil)
      expect(writes).to_be(2)
    end)

    it("ends at a reply that came after it", function()
      flags.set("s", nil, 100)
      expect(flags.settle("s", 101)).to_be_true()
      expect(flags.get("s")).to_be(nil)
    end)

    it("outlasts what was said before it, and in its own second", function()
      -- Both clocks count whole seconds: a reply in the flag's second was already
      -- on screen when the flag went up.
      flags.set("s", nil, 100)
      expect(flags.settle("s", 99)).to_be(false)
      expect(flags.settle("s", 100)).to_be(false)
      expect(flags.settle("s", 0)).to_be(false)
      expect(flags.settle("s", nil)).to_be(false)
      expect(flags.get("s").at).to_be(100)
    end)

    it("keeps its moment when set again", function()
      flags.set("s", nil, 100)
      flags.set("s", nil, 500)
      expect(flags.get("s").at).to_be(100)
      expect(writes).to_be(1)
    end)

    it("hands out copies", function()
      flags.set("s", nil, 100)
      flags.get("s").at = 1
      flags.all().s.at = 1
      expect(flags.get("s").at).to_be(100)
    end)

    it("ignores a conversation with no id", function()
      expect(flags.set("", nil, 100)).to_be(nil)
      expect(flags.set(nil, "x", 100)).to_be(nil)
      expect(flags.settle(nil, 500)).to_be(false)
      expect(flags.clear(nil)).to_be(false)
      expect(writes).to_be(0)
    end)
  end)

  describe("a flag with a note", function()
    it("is not ended by a reply", function()
      flags.set("s", "review before merging", 100)
      expect(flags.pending("s")).to_be(false)
      expect(flags.settle("s", 9999)).to_be(false)
      expect(flags.get("s").note).to_be("review before merging")
    end)

    it("is taken off by hand like any other", function()
      flags.set("s", "review", 100)
      expect(flags.toggle("s", 200)).to_be(nil)
      expect(flags.get("s")).to_be(nil)
    end)

    it("keeps one tidy line of note", function()
      flags.set("s", "  check\n the   CI  ", 100)
      expect(flags.get("s").note).to_be("check the CI")
    end)

    it("turns a bare flag into one that stays", function()
      flags.set("s", nil, 100)
      flags.set("s", "review", 300)
      local flag = flags.get("s")
      expect(flag.note).to_be("review")
      -- Its moment is not what holds it any more, and is left as it was.
      expect(flag.at).to_be(100)
    end)

    it("starts waiting from now when the note is taken off", function()
      -- What was said while the note held the flag must not count against a wait
      -- that had not begun: the flag would vanish with the note.
      flags.set("s", "review", 100)
      flags.set("s", "   ", 300)
      local flag = flags.get("s")
      expect(flag.note).to_be(nil)
      expect(flag.at).to_be(300)
      expect(flags.settle("s", 200)).to_be(false)
      expect(flags.settle("s", 301)).to_be_true()
    end)

    it("writes nothing when the note is unchanged", function()
      flags.set("s", "review", 100)
      flags.set("s", "review", 200)
      expect(writes).to_be(1)
    end)
  end)

  describe("the store", function()
    it("round-trips both kinds", function()
      flags.set("a", nil, 100)
      flags.set("b", "check CI", 200)
      flags.reset()
      assert.same({ a = { at = 100 }, b = { at = 200, note = "check CI" } }, flags.all())
    end)

    it("is read once for any number of questions", function()
      flags.set("a", nil, 100)
      local before = reads
      for _ = 1, 10 do
        flags.get("a")
        flags.pending("a")
        flags.all()
        flags.settle("a", 50)
      end
      expect(reads).to_be(before)
    end)

    it("treats a missing, corrupt or foreign file as empty", function()
      assert.same({}, flags.all())

      flags.reset()
      store = "{ not json"
      assert.same({}, flags.all())

      flags.reset()
      store = _G.json_encode({ version = 99, sessions = { a = { at = 100 } } })
      assert.same({}, flags.all())
    end)

    it("keeps what it knows when the file is there and cannot be read", function()
      -- Emptying memory first and failing second is how every flag was lost at
      -- once: the next change then wrote the empty copy back.
      flags.set("a", nil, 100)
      flags.set("b", "review", 100)
      local on_disk = store

      unreadable = true
      expect(flags.set("c", nil, 200)).to_be(nil) -- refused, not written blind
      expect(flags.toggle("a", 200)).to_be_table() -- still flagged; the clear did not happen
      expect(flags.settle("a", 500)).to_be(false)
      expect(flags.refresh()).to_be(false)
      expect(flags.get("a").at).to_be(100)
      expect(flags.get("b").note).to_be("review")
      expect(store).to_be(on_disk)

      unreadable = false
      expect(flags.settle("a", 500)).to_be_true()
      expect(flags.get("b").note).to_be("review")
    end)

    it("says there is no store, rather than raising, when first asked from a fast context", function()
      -- Where it lives is a `vim.fn` answer too. A fold that somehow got here
      -- before the list's own refresh must not die inside the transcript's
      -- callback; it is simply told nothing is flagged, and the next call from
      -- the main loop finds the store.
      store = _G.json_encode({ version = 1, sessions = { a = { at = 100 } } })
      local in_fast_event = vim.in_fast_event
      vim.in_fast_event = function()
        return true
      end
      package.loaded["claudecode.agents.flags"] = nil
      local fresh = require("claudecode.agents.flags")
      fresh._io = flags._io

      local ok, cleared = pcall(fresh.settle, "a", 500)
      vim.in_fast_event = in_fast_event
      expect(ok).to_be_true()
      expect(cleared).to_be(false)
      expect(writes).to_be(0)

      expect(fresh.get("a").at).to_be(100)
      expect(fresh.settle("a", 500)).to_be_true()
    end)

    it("reads and writes without a single vim.fn call", function()
      -- `settle` runs where a transcript fold finishes: inside a libuv callback,
      -- a fast context, where every `vim.fn` call raises E5560. The first
      -- version used `readfile`/`writefile` and lost flags exactly there. So the
      -- module's own filesystem is driven here, over a fake libuv, with `vim.fn`
      -- raising the way a fast context makes it.
      local files, dirs = {}, {}
      local fds, next_fd = {}, 10
      local real_fn, real_loop, real_uv = vim.fn, vim.loop, vim.uv
      local fake = {
        os_getpid = function()
          return 4242
        end,
        fs_stat = function(path)
          if files[path] then
            return { size = #files[path], mtime = { sec = #files[path], nsec = 0 } }
          end
          return dirs[path] and { size = 0, mtime = { sec = 0, nsec = 0 } } or nil
        end,
        fs_mkdir = function(path)
          dirs[path] = true
          return true
        end,
        fs_open = function(path, mode)
          if mode == "r" and not files[path] then
            return nil
          end
          if mode == "w" then
            files[path] = ""
          end
          next_fd = next_fd + 1
          fds[next_fd] = path
          return next_fd
        end,
        fs_fstat = function(fd)
          return { size = #files[fds[fd]] }
        end,
        fs_read = function(fd)
          return files[fds[fd]]
        end,
        fs_write = function(fd, data)
          files[fds[fd]] = data
          return #data
        end,
        fs_close = function(fd)
          fds[fd] = nil
          return true
        end,
        fs_rename = function(from, to)
          files[to], files[from] = files[from], nil
          return true
        end,
        fs_unlink = function(path)
          files[path] = nil
          return true
        end,
      }

      vim.loop, vim.uv = fake, fake
      package.loaded["claudecode.agents.flags"] = nil
      local real = require("claudecode.agents.flags") -- resolves its path now, as on the main loop
      local path = real.path()
      vim.fn = setmetatable({}, {
        __index = function(_, name)
          error("E5560: Vimscript function must not be called in a fast event context: " .. tostring(name))
        end,
      })

      local ok, err = pcall(function()
        real.set("a", nil, 100)
        real.set("b", "review", 100)
        expect(real.settle("a", 500)).to_be_true()
        real.refresh()
        real.reset()
        assert.same({ b = { at = 100, note = "review" } }, real.all())
      end)

      vim.fn, vim.loop, vim.uv = real_fn, real_loop, real_uv
      package.loaded["claudecode.agents.flags"] = nil
      assert.is_true(ok, tostring(err))

      -- Written through a temporary file of this process's own, then renamed.
      expect(files[path] ~= nil).to_be_true()
      expect(files[path .. ".4242.tmp"]).to_be(nil)
      expect(dirs[path:match("^(.*)/[^/]*$")]).to_be_true()
    end)

    it("drops records that are not flags", function()
      write_elsewhere({ good = { at = 100 }, undated = { note = "x" }, zero = { at = 0 }, junk = "flag" })
      assert.same({ good = { at = 100 } }, flags.all())
    end)

    it("clearing a conversation that has no flag costs no read or write", function()
      -- Asked for every deleted conversation, and most have none.
      flags.set("a", nil, 100)
      local before_reads, before_writes = reads, writes
      expect(flags.clear("other")).to_be(false)
      expect(reads).to_be(before_reads)
      expect(writes).to_be(before_writes)
    end)
  end)

  describe("a second Neovim", function()
    it("does not lose what the other one flagged since we last read", function()
      -- One file holds every project's flags. Writing back a copy read at startup
      -- would drop the other editor's flag — the one failure a reminder cannot
      -- have — so a change is applied to the file as it is now.
      flags.set("ours", nil, 100)
      write_elsewhere({ ours = { at = 100 }, theirs = { at = 150, note = "from the other editor" } })

      flags.set("more", nil, 200)

      flags.reset()
      local all = flags.all()
      expect(all.ours.at).to_be(100)
      expect(all.theirs.note).to_be("from the other editor")
      expect(all.more.at).to_be(200)
    end)

    it("does not bring back a flag the other one took off", function()
      flags.set("a", nil, 100)
      flags.set("b", nil, 100)
      write_elsewhere({ b = { at = 100 } })

      flags.set("c", nil, 200)

      flags.reset()
      expect(flags.get("a")).to_be(nil)
      expect(flags.get("c").at).to_be(200)
    end)

    it("is noticed by a refresh, which reads only when the file moved", function()
      flags.set("a", nil, 100)
      local before = reads
      expect(flags.refresh()).to_be(false)
      expect(reads).to_be(before)

      write_elsewhere({ a = { at = 100 }, theirs = { at = 150 } })
      expect(flags.get("theirs")).to_be(nil) -- not until asked to look
      expect(flags.refresh()).to_be_true()
      expect(flags.get("theirs").at).to_be(150)
      expect(flags.refresh()).to_be(false)
    end)

    it("does not end a flag the other one has given a note meanwhile", function()
      flags.set("a", nil, 100)
      write_elsewhere({ a = { at = 100, note = "keep" } })
      expect(flags.settle("a", 500)).to_be(false)
      expect(flags.get("a").note).to_be("keep")
    end)

    it("clears a flag it only learns of from the file", function()
      flags.all() -- read while the store is empty
      write_elsewhere({ theirs = { at = 150 } })
      expect(flags.clear("theirs")).to_be_true()
      flags.reset()
      expect(flags.get("theirs")).to_be(nil)
    end)
  end)
end)
