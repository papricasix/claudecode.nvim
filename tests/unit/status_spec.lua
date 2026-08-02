-- luacheck: globals expect
require("tests.busted_setup")

describe("status", function()
  local status

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
      status = st,
    }
  end

  local function enable(st)
    status.setup(base_config(vim.tbl_deep_extend("force", { enabled = true }, st or {})))
  end

  --- Feed one hook event for a tab (defaults to the current one).
  local function note(hook_event_name, extra, tab)
    local event = { hook_event_name = hook_event_name, session_id = "sess-1" }
    for k, v in pairs(extra or {}) do
      event[k] = v
    end
    status.note(event, tab or 1)
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    vim._tabs = { [1] = true, [2] = true }
    vim._current_tabpage = 1

    package.loaded["claudecode.status"] = nil
    status = require("claudecode.status")
    status.reset()
  end)

  describe("configuration", function()
    it("is off by default", function()
      package.loaded["claudecode.config"] = nil
      expect(require("claudecode.config").defaults.status.enabled).to_be_false()
    end)

    it("records nothing while disabled", function()
      status.setup(base_config({ enabled = false }))
      expect(status.is_enabled()).to_be_false()
      note("UserPromptSubmit")
      expect(status.get_state(1)).to_be("none")
      expect(status.icon(1)).to_be("")
      expect(status.hl_group(1)).to_be_nil()
    end)

    it("rejects unknown icon states and non-string glyphs", function()
      package.loaded["claudecode.config"] = nil
      local config = require("claudecode.config")
      expect(pcall(config.validate, base_config({ enabled = true, icons = { busy = "*" } }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, icons = { thinking = "*" } }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, icons = { busy = 42 } }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, auto_redraw = "yes" }))).to_be_false()
    end)
  end)

  describe("event mapping", function()
    before_each(function()
      enable()
    end)

    it("reads a submitted prompt as busy", function()
      note("UserPromptSubmit")
      expect(status.get_state(1)).to_be("busy")
    end)

    it("reads a running tool as busy and records which one", function()
      note("PreToolUse", { tool_name = "Bash" })
      local entry = status.get(1)
      expect(entry.state).to_be("busy")
      expect(entry.tool).to_be("Bash")
      expect(entry.session_id).to_be("sess-1")
    end)

    it("reads a permission notification as waiting, keeping the message", function()
      note("PreToolUse", { tool_name = "Bash" })
      note("Notification", { message = "Claude needs your permission to use Bash" })
      local entry = status.get(1)
      expect(entry.state).to_be("waiting")
      expect(entry.message).to_be("Claude needs your permission to use Bash")
    end)

    it("reads the idle nudge notification as idle, not as a question", function()
      note("UserPromptSubmit")
      note("Notification", { message = "Claude is waiting for your input" })
      expect(status.get_state(1)).to_be("idle")
    end)

    it("leaves the permission wait once the tool actually runs", function()
      note("PreToolUse", { tool_name = "Bash" })
      note("Notification", { message = "Claude needs your permission to use Bash" })
      note("PostToolUse", { tool_name = "Bash" })
      expect(status.get_state(1)).to_be("busy")
    end)

    it("reads a presented plan as waiting", function()
      note("PreToolUse", { tool_name = "ExitPlanMode" })
      local entry = status.get(1)
      expect(entry.state).to_be("waiting")
      expect(entry.message).to_be("plan review")
    end)

    it("reads the end of a turn as idle", function()
      note("PreToolUse", { tool_name = "Read" })
      note("Stop")
      local entry = status.get(1)
      expect(entry.state).to_be("idle")
      expect(entry.tool).to_be_nil()
    end)

    it("starts a session idle and drops the tab when it ends", function()
      note("SessionStart")
      expect(status.get_state(1)).to_be("idle")
      note("SessionEnd")
      expect(status.get_state(1)).to_be("none")
    end)

    it("ignores events it has no meaning for", function()
      note("Stop")
      note("SubagentStop")
      expect(status.get_state(1)).to_be("idle")
    end)

    it("keeps `since` across a busy->busy tool change", function()
      note("PreToolUse", { tool_name = "Read" })
      local first = status.get(1).since
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.get(1).since).to_be(first)
      expect(status.get(1).tool).to_be("Bash")
    end)
  end)

  describe("tabs", function()
    before_each(function()
      enable()
    end)

    it("keeps each tab's Claude separate", function()
      note("PreToolUse", { tool_name = "Bash" }, 1)
      note("Stop", {}, 2)
      expect(status.get_state(1)).to_be("busy")
      expect(status.get_state(2)).to_be("idle")
    end)

    it("lists only the tabs that have a Claude", function()
      note("Stop", {}, 2)
      local all = status.all()
      expect(all[1]).to_be_nil()
      expect(all[2].state).to_be("idle")
    end)

    it("ignores events stamped with a tab that is gone", function()
      status.note({ hook_event_name = "Stop" }, 99)
      expect(status.get_state(99)).to_be("none")
    end)

    it("forgets closed tabs", function()
      note("Stop", {}, 2)
      vim._tabs[2] = nil
      status.forget_closed_tabs()
      expect(status.all()[2]).to_be_nil()
    end)

    it("marks a launched tab present without overriding a known state", function()
      status.note_launch(1)
      expect(status.get_state(1)).to_be("idle")
      note("PreToolUse", { tool_name = "Bash" })
      status.note_launch(1)
      expect(status.get_state(1)).to_be("busy")
    end)

    it("clears a tab whose Claude is gone", function()
      note("PreToolUse", { tool_name = "Bash" })
      status.clear(1)
      expect(status.get_state(1)).to_be("none")
    end)
  end)

  describe("notifications", function()
    before_each(function()
      enable()
    end)

    local function last_event()
      local fired = vim._fired_autocmds or {}
      return fired[#fired]
    end

    it("fires ClaudeCodeStatusChanged with the old and new state", function()
      note("UserPromptSubmit")
      local event = last_event()
      assert.is_not_nil(event)
      expect(event.events).to_be("User")
      expect(event.opts.pattern).to_be("ClaudeCodeStatusChanged")
      expect(event.opts.data.state).to_be("busy")
      expect(event.opts.data.prev).to_be("none")
      expect(event.opts.data.tab).to_be(1)
    end)

    it("stays quiet when nothing user-visible changed", function()
      note("PreToolUse", { tool_name = "Bash" })
      local count = #(vim._fired_autocmds or {})
      note("PreToolUse", { tool_name = "Bash" })
      expect(#(vim._fired_autocmds or {})).to_be(count)
    end)
  end)

  describe("presentation", function()
    it("serves the configured glyph and highlight per state", function()
      enable({ icons = { busy = "B", waiting = "W", idle = "I" } })
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.icon(1)).to_be("B")
      expect(status.hl_group(1)).to_be("ClaudeCodeStatusBusy")

      note("Notification", { message = "Claude needs your permission to use Bash" })
      expect(status.icon(1)).to_be("W")
      expect(status.hl_group(1)).to_be("ClaudeCodeStatusWaiting")

      note("Stop")
      expect(status.icon(1)).to_be("I")
      expect(status.hl_group(1)).to_be("ClaudeCodeStatusIdle")
    end)

    it("shows nothing for a tab without a Claude", function()
      enable()
      expect(status.icon(2)).to_be("")
      expect(status.hl_group(2)).to_be_nil()
    end)

    it("cycles an icon configured as a list of frames", function()
      enable({ icons = { busy = { "a", "b", "c" } } })
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.icon(1)).to_be("a")
      status._tick()
      expect(status.icon(1)).to_be("b")
      status._tick()
      expect(status.icon(1)).to_be("c")
      status._tick()
      expect(status.icon(1)).to_be("a") -- wraps
    end)

    it("ships the CLI's spinner frames, all single-width", function()
      expect(#status.SPINNER > 1).to_be_true()
      for _, f in ipairs(status.SPINNER) do
        expect(type(f)).to_be("string")
      end
    end)

    it("animates only while a tab shows an animated icon", function()
      enable({ icons = { busy = { "a", "b" } } })
      expect(status.is_spinning()).to_be_false()
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.is_spinning()).to_be_true()
      note("Stop") -- idle is a plain glyph
      expect(status.is_spinning()).to_be_false()
    end)

    it("stops animating when the last animated tab is gone", function()
      enable({ icons = { busy = { "a", "b" } } })
      note("PreToolUse", { tool_name = "Bash" }, 1)
      note("PreToolUse", { tool_name = "Bash" }, 2)
      expect(status.is_spinning()).to_be_true()
      status.clear(1)
      expect(status.is_spinning()).to_be_true() -- tab 2 is still busy
      vim._tabs[2] = nil
      status.forget_closed_tabs()
      expect(status.is_spinning()).to_be_false()
    end)

    it("never animates when the consumer owns redrawing, or when disabled", function()
      enable({ icons = { busy = { "a", "b" } }, auto_redraw = false })
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.is_spinning()).to_be_false()

      status.reset()
      enable({ icons = { busy = { "a", "b" } }, spinner_ms = 0 })
      note("PreToolUse", { tool_name = "Bash" })
      expect(status.is_spinning()).to_be_false()
      expect(status.icon(1)).to_be("a") -- still shows a frame, just a still one
    end)

    it("validates frame lists", function()
      package.loaded["claudecode.config"] = nil
      local config = require("claudecode.config")
      expect(pcall(config.validate, base_config({ enabled = true, icons = { busy = { "a", "b" } } }))).to_be_true()
      expect(pcall(config.validate, base_config({ enabled = true, icons = { busy = {} } }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, icons = { busy = { 1, 2 } } }))).to_be_false()
      expect(pcall(config.validate, base_config({ enabled = true, spinner_ms = -1 }))).to_be_false()
    end)

    it("hands out copies, so a consumer cannot corrupt our state", function()
      enable()
      note("PreToolUse", { tool_name = "Bash" })
      local entry = status.get(1)
      entry.state = "idle"
      expect(status.get_state(1)).to_be("busy")
    end)
  end)

  describe("launch injection", function()
    local live_cursor

    local function injected_settings(injection)
      local path = injection.args:match("%-%-settings%s+'?([^']+)'?")
      assert.is_not_nil(path)
      local f = assert(io.open(path, "r"))
      local contents = f:read("*a")
      f:close()
      return contents
    end

    before_each(function()
      package.loaded["claudecode.live_cursor"] = nil
      live_cursor = require("claudecode.live_cursor")
      live_cursor.setup(base_config({ enabled = true }))
    end)

    it("injects the activity hooks on its own, with live cursor and plan off", function()
      enable()
      local injection = live_cursor.build_launch_injection()
      assert.is_not_nil(injection)
      local contents = injected_settings(injection)
      for _, event in ipairs({ "UserPromptSubmit", "Notification", "Stop", "SessionEnd", "PostToolUse" }) do
        assert.is_truthy(contents:match(event))
      end
      -- Activity means *every* tool call, not just the file tools live cursor wants.
      assert.is_truthy(contents:match('"matcher":"%*"'))
    end)

    it("injects nothing when every feature is off", function()
      status.setup(base_config({ enabled = false }))
      expect(live_cursor.build_launch_injection()).to_be_nil()
    end)
  end)
end)
