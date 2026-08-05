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
      note("Stop", {}, 2) -- finished on a tab we are not looking at
      expect(status.get_state(1)).to_be("busy")
      expect(status.get_state(2)).to_be("done")
    end)

    it("lists only the tabs that have a Claude", function()
      note("Stop", {}, 2)
      local all = status.all()
      expect(all[1]).to_be_nil()
      expect(all[2].state).to_be("done")
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

  describe("a turn the user cancelled", function()
    before_each(function()
      enable()
    end)

    it("ends a busy tab", function()
      -- Pressing <Esc> fires no Claude Code hook at all — verified against the
      -- real CLI by driving a session through a pty with every hook event
      -- registered. Without this the tab stays busy and the spinner animates
      -- (redrawing every tabline) until the next prompt. The transcript's
      -- `[Request interrupted by user]` entry is what calls this.
      note("UserPromptSubmit", {}, 1)
      expect(status.get_state(1)).to_be("busy")
      expect(status.note_interrupt(1)).to_be_true()
      expect(status.get_state(1)).to_be("idle")
    end)

    it("leaves a tab that is not working alone", function()
      -- The reason this is not driven off the keypress: <Esc> also closes panels
      -- in Claude's TUI, and during a turn with no tool calls no later event
      -- would correct a wrong guess.
      note("Notification", { message = "Claude needs your permission to run git push" }, 1)
      expect(status.get_state(1)).to_be("waiting")
      expect(status.note_interrupt(1)).to_be(false)
      expect(status.get_state(1)).to_be("waiting")
    end)

    it("ignores a tab with no Claude", function()
      expect(status.note_interrupt(3)).to_be(false)
    end)
  end)

  describe("read and unread answers", function()
    before_each(function()
      enable()
      status.set_focused(true)
    end)

    it("lands a finished turn in done when you were looking elsewhere", function()
      note("PreToolUse", { tool_name = "Bash" }, 2)
      note("Stop", {}, 2) -- current tab is 1
      expect(status.get_state(2)).to_be("done")
    end)

    it("lands it in idle when you were on that tab", function()
      note("Stop", {}, 1)
      expect(status.get_state(1)).to_be("idle")
    end)

    it("counts an answer that arrived while Neovim was in the background as unread", function()
      status.set_focused(false)
      note("Stop", {}, 1) -- your tab, but you were in another app
      expect(status.get_state(1)).to_be("done")
      status.set_focused(true)
      expect(status.mark_read(1)).to_be_true()
      expect(status.get_state(1)).to_be("idle")
    end)

    it("clears done when the tab is visited", function()
      note("Stop", {}, 2)
      expect(status.get_state(2)).to_be("done")
      expect(status.mark_read(2)).to_be_true()
      expect(status.get_state(2)).to_be("idle")
      expect(status.mark_read(2)).to_be_false() -- nothing left to read
    end)

    it("never reads away a question or ongoing work", function()
      note("Notification", { message = "Claude needs your permission to use Bash" }, 2)
      expect(status.mark_read(2)).to_be_false()
      expect(status.get_state(2)).to_be("waiting")

      note("PreToolUse", { tool_name = "Bash" }, 2)
      expect(status.mark_read(2)).to_be_false()
      expect(status.get_state(2)).to_be("busy")
    end)

    it("keeps the session id across the done -> idle transition", function()
      note("Stop", {}, 2)
      status.mark_read(2)
      expect(status.get(2).session_id).to_be("sess-1")
    end)

    it("serves done its own glyph and highlight", function()
      status.setup(base_config({ enabled = true, icons = { done = "D", idle = "I" } }))
      note("Stop", {}, 2)
      expect(status.icon(2)).to_be("D")
      expect(status.hl_group(2)).to_be("ClaudeCodeStatusDone")
      status.mark_read(2)
      expect(status.icon(2)).to_be("I")
      expect(status.hl_group(2)).to_be("ClaudeCodeStatusIdle")
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

    it("keeps one beat when two timers drive the same frame", function()
      -- The agents view runs its own spinner timer and advances this counter too,
      -- so a busy agent and a busy tab show the same glyph. Both timers ticking
      -- must not add up to double speed.
      enable({ icons = { busy = { "a", "b", "c" } } })
      note("PreToolUse", { tool_name = "Bash" })

      local clock = 1000
      local saved_now = vim.loop.now
      vim.loop.now = function()
        return clock
      end
      finally(function()
        vim.loop.now = saved_now
      end)

      expect(status.icon(1)).to_be("a")
      status._tick(120) -- status's own timer
      expect(status.icon(1)).to_be("b")
      clock = clock + 40
      status._tick(120) -- the agents view, on its own phase: too soon
      expect(status.icon(1)).to_be("b")
      clock = clock + 80 -- a full interval since the last advance
      status._tick(120)
      expect(status.icon(1)).to_be("c")

      -- A manual step (a test, not a timer) always advances.
      status._tick()
      expect(status.icon(1)).to_be("a")
    end)

    it("ships the CLI's spinner as the ping-pong sequence the CLI plays", function()
      local frames = status.SPINNER
      expect(#frames).to_be(12) -- six glyphs, then the same six backwards
      for _, f in ipairs(frames) do
        expect(type(f)).to_be("string")
      end
      for i = 1, 6 do
        expect(frames[i]).to_be(frames[13 - i])
      end
      expect(frames[1]).to_be("·")
      expect(frames[4]).to_be("✶")
    end)

    it("swaps the one emoji-capable frame on terminals that colour it", function()
      local saved_has, saved_env = vim.fn.has, vim.env
      local function frames_with(setup_env)
        vim.fn.has = function()
          return 0
        end
        vim.env = setup_env
        package.loaded["claudecode.status"] = nil
        local frames = require("claudecode.status").SPINNER
        vim.fn.has, vim.env = saved_has, saved_env
        package.loaded["claudecode.status"] = nil
        status = require("claudecode.status")
        return frames
      end

      -- ✳ is U+2733, the only frame Unicode lists as emoji-capable
      expect(frames_with({})[3]).to_be("✳")
      expect(frames_with({ WT_SESSION = "abc" })[3]).to_be("✱") -- Windows Terminal
      expect(frames_with({ ConEmuANSI = "ON" })[3]).to_be("✱")

      vim.fn.has = function(feature)
        return feature == "win32" and 1 or 0
      end
      vim.env = {}
      package.loaded["claudecode.status"] = nil
      expect(require("claudecode.status").SPINNER[3]).to_be("✱")
      vim.fn.has, vim.env = saved_has, saved_env
      package.loaded["claudecode.status"] = nil
      status = require("claudecode.status")
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
