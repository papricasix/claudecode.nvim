-- luacheck: globals expect
require("tests.busted_setup")

describe("agents seams", function()
  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
  end)

  describe("status.classify", function()
    local status

    before_each(function()
      package.loaded["claudecode.status"] = nil
      status = require("claudecode.status")
    end)

    local function classify(event, finished)
      return status.classify(event, finished and { finished = finished } or nil)
    end

    it("maps the lifecycle events to states", function()
      expect((classify({ hook_event_name = "SessionStart" }))).to_be("idle")
      expect((classify({ hook_event_name = "SessionEnd" }))).to_be("none")
      expect((classify({ hook_event_name = "UserPromptSubmit" }))).to_be("busy")
      expect((classify({ hook_event_name = "PreToolUse", tool_name = "Bash" }))).to_be("busy")
      expect((classify({ hook_event_name = "PostToolUse", tool_name = "Bash" }))).to_be("busy")
      expect((classify({ hook_event_name = "PreCompact" }))).to_be("busy")
    end)

    it("treats a plan awaiting your decision as waiting", function()
      local state, info = classify({ hook_event_name = "PreToolUse", tool_name = "ExitPlanMode" })
      expect(state).to_be("waiting")
      expect(info.message).to_be("plan review")
    end)

    it("treats a permission prompt as waiting, carrying its message", function()
      local state, info = classify({ hook_event_name = "Notification", message = "Claude needs your permission" })
      expect(state).to_be("waiting")
      expect(info.message).to_be("Claude needs your permission")
    end)

    it("treats the idle nudge as a finished turn, not a question", function()
      local state = classify({ hook_event_name = "Notification", message = "Claude is waiting for your input" })
      expect(state).to_be("done")
    end)

    it("lands a finished turn wherever the caller says", function()
      -- The caller decides, because "have you read this yet" depends on where the
      -- answer arrived — which a per-session consumer answers differently.
      expect((classify({ hook_event_name = "Stop" }, "idle"))).to_be("idle")
      expect((classify({ hook_event_name = "Stop" }, "done"))).to_be("done")
      expect((classify({ hook_event_name = "Stop" }))).to_be("done")
    end)

    it("carries the conversation id through", function()
      local _, info = classify({ hook_event_name = "PreToolUse", tool_name = "Edit", session_id = "abc" })
      expect(info.session_id).to_be("abc")
      expect(info.tool).to_be("Edit")
    end)

    it("says nothing about events it does not recognise", function()
      expect((classify({ hook_event_name = "SomethingNew" }))).to_be(nil)
      expect((classify(nil))).to_be(nil)
      expect((classify("not a table"))).to_be(nil)
    end)

    it("is pure: classifying never records anything", function()
      status.reset()
      classify({ hook_event_name = "PreToolUse", tool_name = "Edit" })
      expect(next(status.all())).to_be(nil)
    end)
  end)

  describe("session_state disown", function()
    local session_state

    local function base_config(mode)
      return { session_persistence = mode, terminal = {}, diff_opts = {} }
    end

    before_each(function()
      package.loaded["claudecode.session_state"] = nil
      session_state = require("claudecode.session_state")
      session_state.setup(base_config("global"))
      session_state.reset()
      vim._tabs[1] = true
      vim._current_tabpage = 1
    end)

    it("mints no id for a disowned tab", function()
      expect(session_state.launch_args(nil, "/proj") ~= "").to_be_true()
      session_state.reset()
      session_state.disown_tab(1)
      expect(session_state.launch_args(nil, "/proj")).to_be("")
    end)

    it("ignores hook events for a disowned tab", function()
      -- Every agent in the tab reports its own id; recording them per tab would
      -- leave whichever fired last pretending to be the tab's conversation.
      session_state.disown_tab(1)
      session_state.note_session_id(1, "agent-session", "/proj")
      expect(session_state.get(1)).to_be(nil)
    end)

    it("drops what the tab had, so nothing stale is resumed", function()
      session_state.note_session_id(1, "old-session", "/proj")
      expect(session_state.get(1)).to_be_table()
      session_state.disown_tab(1)
      expect(session_state.get(1)).to_be(nil)
    end)

    it("leaves a disowned tab out of the persisted payload", function()
      session_state.note_session_id(1, "old-session", "/proj")
      session_state.disown_tab(1)
      local payload = session_state.capture()
      expect(payload == nil or next(payload.tabs) == nil).to_be_true()
    end)

    it("takes the tab back on reclaim", function()
      session_state.disown_tab(1)
      expect(session_state.is_disowned(1)).to_be_true()
      session_state.reclaim_tab(1)
      expect(session_state.is_disowned(1)).to_be(false)
      expect(session_state.launch_args(nil, "/proj") ~= "").to_be_true()
    end)

    it("hands out conversation ids in the CLI's shape", function()
      local id = session_state.new_session_id()
      expect(id).to_be_string()
      expect(#id).to_be(36)
      expect(id:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$") ~= nil).to_be_true()
      expect(id ~= session_state.new_session_id()).to_be_true()
    end)
  end)

  describe("terminal.build_launch", function()
    local terminal

    before_each(function()
      package.loaded["claudecode.terminal"] = nil
      terminal = require("claudecode.terminal")
      terminal.setup({ provider = "native" }, "claude", {})
    end)

    it("builds the command without opening anything", function()
      local cmd, env = terminal.build_launch("--resume abc", { instance = { port = 4242 } })
      expect(cmd:find("claude", 1, true)).to_be(1)
      expect(cmd:find("--resume abc", 1, true) ~= nil).to_be_true()
      expect(env.CLAUDE_CODE_SSE_PORT).to_be("4242")
      expect(env.ENABLE_IDE_INTEGRATION).to_be("true")
    end)

    it("binds the launch to the instance it is given", function()
      -- Each agent has its own server; without this every agent would inherit the
      -- tab's port and they would all talk to one server.
      local _, env_a = terminal.build_launch(nil, { instance = { port = 1111 } })
      local _, env_b = terminal.build_launch(nil, { instance = { port = 2222 } })
      expect(env_a.CLAUDE_CODE_SSE_PORT).to_be("1111")
      expect(env_b.CLAUDE_CODE_SSE_PORT).to_be("2222")
    end)

    it("honours a cwd override", function()
      -- Regression: build_config only accepted an override when the key already
      -- had a value, and `cwd` defaults to nil — so this was silently dropped.
      local _, _, effective = terminal.build_launch(nil, { instance = { port = 1 }, cwd = "/tmp/somewhere" })
      expect(effective.cwd).to_be("/tmp/somewhere")
    end)

    it("honours a cwd passed as a terminal override", function()
      local _, _, effective =
        terminal.build_launch(nil, { instance = { port = 1 }, overrides = { cwd = "/tmp/override" } })
      expect(effective.cwd).to_be("/tmp/override")
    end)

    it("still applies the other terminal overrides", function()
      local _, _, effective = terminal.build_launch(nil, {
        instance = { port = 1 },
        overrides = { split_side = "left", split_width_percentage = 0.5 },
      })
      expect(effective.split_side).to_be("left")
      expect(effective.split_width_percentage).to_be(0.5)
    end)
  end)

  describe("diff layout ownership", function()
    local diff

    before_each(function()
      package.loaded["claudecode.diff"] = nil
      diff = require("claudecode.diff")
    end)

    it("reports a tab that owns its layout", function()
      vim._tabs[3] = true
      expect(diff._tab_forbids_split(3)).to_be(false)
      vim.api.nvim_tabpage_set_var(3, "claudecode_layout_owner", { forbids_split = true, host = "float" })
      expect(diff._tab_forbids_split(3)).to_be_true()
    end)

    it("is false for an unknown or missing tab", function()
      expect(diff._tab_forbids_split(nil)).to_be(false)
      expect(diff._tab_forbids_split(4242)).to_be(false)
    end)

    it("reads the whole descriptor, not just the flag", function()
      -- The routing protocol: a view that builds a fixed arrangement of windows
      -- declares that a split would carve it up, where files go instead, and
      -- which ordinary tab to fall back to. Nothing here knows which feature
      -- built the tab.
      vim._tabs[5] = true
      vim._tabs[6] = true
      vim.api.nvim_tabpage_set_var(5, "claudecode_layout_owner", {
        forbids_split = true,
        host = "float",
        float_module = "claudecode.agents.float",
        origin = 6,
      })
      local owner = diff._layout_owner(5)
      expect(owner).not_to_be_nil()
      expect(owner.host).to_be("float")
      expect(owner.float_module).to_be("claudecode.agents.float")
      expect(diff._redirect_tab_for_diff(5)).to_be(6)
    end)

    it("does not redirect to an origin tab that has gone", function()
      vim._tabs[7] = true
      vim.api.nvim_tabpage_set_var(7, "claudecode_layout_owner", {
        forbids_split = true,
        host = "float",
        origin = 999,
      })
      expect(diff._redirect_tab_for_diff(7)).to_be_nil()
    end)
  end)
end)
