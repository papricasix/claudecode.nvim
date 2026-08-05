-- luacheck: globals expect
require("tests.busted_setup")

describe("interrupt_watch", function()
  local watch, status, transcript

  --- A fake transcript store: [path] = string. Reads and stats come from here,
  --- so no libuv and no filesystem are involved.
  local files

  local function base_config(st)
    return {
      port_range = { min = 10000, max = 65535 },
      auto_start = true,
      log_level = "info",
      track_selection = true,
      visual_demotion_delay_ms = 50,
      connection_wait_delay = 200,
      connection_timeout = 10000,
      queue_timeout = 5000,
      diff_opts = {},
      env = {},
      models = { { name = "Test Model", value = "test" } },
      terminal = { provider = "native" },
      status = vim.tbl_deep_extend("force", { enabled = true, auto_redraw = false }, st or {}),
    }
  end

  --- The CLI's own record of a cancel: the marker as the *whole* message content.
  local function marker_line()
    return vim.json.encode({
      type = "user",
      message = { role = "user", content = "[Request interrupted by user]" },
      timestamp = "2026-08-02T21:00:00.000Z",
    })
  end

  --- A tool result that merely *quotes* the marker. `type` is `"user"` here too,
  --- which is exactly why a substring match is not enough — folding this repo's
  --- own transcripts with a naive test flagged the session that wrote this code.
  local function quoting_line()
    return vim.json.encode({
      type = "user",
      message = { role = "user", content = "grep found [Request interrupted by user] in the binary, 2 hits" },
      timestamp = "2026-08-02T21:00:00.000Z",
    })
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    for _, name in ipairs({
      "claudecode.interrupt_watch",
      "claudecode.status",
      "claudecode.agents.transcript",
    }) do
      package.loaded[name] = nil
    end
    watch = require("claudecode.interrupt_watch")
    status = require("claudecode.status")
    transcript = require("claudecode.agents.transcript")

    -- The mock's `vim.json.decode` is a non-functional stub; the busted setup
    -- ships a real one, and `_is_interrupt_line` decodes structurally rather than
    -- matching a substring, so it needs the real thing to be exercised at all.
    vim.json.decode = _G.json_decode

    files = {}
    transcript._io.stat = function(path)
      local body = files[path]
      if not body then
        return nil
      end
      return { size = #body, mtime = 1, ino = 1 }
    end
    transcript._io.read = function(path, offset, len, cb)
      local body = files[path] or ""
      cb(body:sub(offset + 1, offset + len), nil)
    end

    -- Resolution is a glob in production; here the id *is* the path.
    watch._resolve = function(session_id)
      local path = "/store/" .. session_id .. ".jsonl"
      return files[path] and path or nil
    end

    status.setup(base_config())
    watch.reset()
  end)

  after_each(function()
    watch.reset()
  end)

  ---Put a tab into `busy` the way a real `UserPromptSubmit` would.
  local function go_busy(tab, session_id)
    vim._tabs[tab] = true
    status.note({ hook_event_name = "UserPromptSubmit", session_id = session_id }, tab)
  end

  describe("the clock", function()
    it("does not run while nothing is busy", function()
      expect(watch._is_running()).to_be(false)
      watch.sync()
      expect(watch._is_running()).to_be(false)
    end)

    it("runs while a tab is busy, and stops when it is not", function()
      files["/store/s1.jsonl"] = ""
      go_busy(2, "s1")
      expect(status.get_state(2)).to_be("busy")
      expect(watch._is_running()).to_be_true()

      status.note({ hook_event_name = "Stop", session_id = "s1" }, 2)
      expect(watch._is_running()).to_be(false)
    end)

    it("stays stopped while the feature is off", function()
      status.setup(base_config({ enabled = false }))
      go_busy(2, "s1")
      watch.sync()
      expect(watch._is_running()).to_be(false)
    end)
  end)

  describe("detecting a cancel", function()
    it("ends a busy turn when the CLI records the marker", function()
      files["/store/s1.jsonl"] = ""
      go_busy(2, "s1")
      expect(status.get_state(2)).to_be("busy")

      files["/store/s1.jsonl"] = marker_line() .. "\n"
      watch._tick()
      expect(status.get_state(2)).to_be("idle")
    end)

    it("ignores a tool result that merely quotes the marker", function()
      -- The false positive that is not theoretical: `toolUseResult` entries are
      -- `type:"user"` too. `transcript._is_interrupt_line` decodes and checks the
      -- marker is the whole message content, and this must go through it.
      files["/store/s1.jsonl"] = ""
      go_busy(2, "s1")

      files["/store/s1.jsonl"] = quoting_line() .. "\n"
      watch._tick()
      expect(status.get_state(2)).to_be("busy")
    end)

    it("never fires on an interrupt from an earlier turn", function()
      -- A transcript keeps every cancel the conversation ever had, so its mere
      -- presence says nothing. Arming at end-of-file is what makes any marker we
      -- go on to see belong to the turn being watched — the agents side needed
      -- timestamps to answer this same question.
      files["/store/s1.jsonl"] = marker_line() .. "\n"
      go_busy(2, "s1")

      watch._tick()
      expect(status.get_state(2)).to_be("busy")

      -- A *new* one still lands.
      files["/store/s1.jsonl"] = files["/store/s1.jsonl"] .. marker_line() .. "\n"
      watch._tick()
      expect(status.get_state(2)).to_be("idle")
    end)

    it("leaves a tab that is not busy alone", function()
      files["/store/s1.jsonl"] = ""
      go_busy(2, "s1")
      status.note({ hook_event_name = "Notification", message = "needs your permission", session_id = "s1" }, 2)
      expect(status.get_state(2)).to_be("waiting")

      files["/store/s1.jsonl"] = marker_line() .. "\n"
      watch._tick()
      -- Looking at a question is not answering it, and neither is a stale marker.
      expect(status.get_state(2)).to_be("waiting")
    end)

    it("re-reads only what was appended", function()
      local reads = {}
      transcript._io.read = function(path, offset, len, cb)
        reads[#reads + 1] = { offset = offset, len = len }
        cb((files[path] or ""):sub(offset + 1, offset + len), nil)
      end
      files["/store/s1.jsonl"] = string.rep("x", 500) .. "\n"
      go_busy(2, "s1")

      local tail = marker_line() .. "\n"
      files["/store/s1.jsonl"] = files["/store/s1.jsonl"] .. tail
      watch._tick()

      expect(#reads).to_be(1)
      expect(reads[1].offset).to_be(501)
      expect(reads[1].len).to_be(#tail)
    end)

    it("survives a transcript that was compacted under it", function()
      files["/store/s1.jsonl"] = string.rep("x", 500) .. "\n"
      go_busy(2, "s1")
      files["/store/s1.jsonl"] = "tiny\n"
      expect((pcall(watch._tick))).to_be_true()
      expect(status.get_state(2)).to_be("busy")
    end)

    it("does nothing for a busy tab whose transcript is not there yet", function()
      go_busy(2, "s1")
      expect((pcall(watch._tick))).to_be_true()
      expect(status.get_state(2)).to_be("busy")
    end)
  end)
end)
