-- luacheck: globals expect
require("tests.busted_setup")

describe("instance registry", function()
  local claudecode
  local started -- server instances handed out by the stubbed server module

  local function stub_server_module()
    started = {}
    package.loaded["claudecode.server.init"] = {
      new_instance = function(tab_id, opts)
        local record = { tab_id = tab_id, opts = opts or {}, stopped = false }
        started[#started + 1] = record
        record.start = function()
          record.port = 10000 + #started
          return true, tostring(record.port)
        end
        record.stop = function()
          record.stopped = true
          return true
        end
        return record
      end,
    }
    package.loaded["claudecode.lockfile"] = {
      generate_auth_token = function()
        return "0123456789abcdef0123456789abcdef"
      end,
      create = function(port, token)
        return true, "/tmp/lock-" .. tostring(port), token
      end,
      remove = function()
        return true
      end,
      cleanup_stale = function() end,
    }
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    stub_server_module()
    package.loaded["claudecode"] = nil
    claudecode = require("claudecode")
    claudecode.instances = {}
    claudecode.tab_instance = {}
    claudecode.state.config = vim.tbl_deep_extend("force", claudecode.state.config or {}, {
      track_selection = false,
    })
  end)

  after_each(function()
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.lockfile"] = nil
    package.loaded["claudecode"] = nil
    require("claudecode.request_context").clear()
  end)

  describe("tab instances", function()
    it("files a registered instance under its id and points its tab at it", function()
      local inst = claudecode.register_tab_instance(7, { server = {}, port = 1 })
      expect(inst.id).to_be("tab:7")
      expect(inst.tab).to_be(7)
      expect(inst.kind).to_be("tab")
      expect(claudecode.instances["tab:7"]).to_be(inst)
      expect(claudecode.get_instance(7)).to_be(inst)
    end)

    it("hands out a stub for a tab with no Claude", function()
      local inst = claudecode.get_instance(99)
      expect(inst.server).to_be(nil)
      expect(inst.port).to_be(nil)
    end)

    it("forgets a tab instance without stopping it", function()
      claudecode.register_tab_instance(7, { server = {}, port = 1 })
      claudecode.unregister_tab_instance(7)
      expect(claudecode.instances["tab:7"]).to_be(nil)
      expect(claudecode.get_instance(7).server).to_be(nil)
    end)
  end)

  describe("agent instances", function()
    it("gives each agent its own server, port and auth token", function()
      local a = claudecode.start_agent_instance("session-a", 3)
      local b = claudecode.start_agent_instance("session-b", 3)

      expect(a).to_be_table()
      expect(b).to_be_table()
      expect(a.port ~= b.port).to_be_true()
      expect(a.id).to_be("agent:session-a")
      expect(b.id).to_be("agent:session-b")
      expect(a.kind).to_be("agent")
      -- Same tab, different instances: that is the whole point.
      expect(a.tab).to_be(3)
      expect(b.tab).to_be(3)
    end)

    it("tells the server which conversation it serves", function()
      claudecode.start_agent_instance("session-a", 3)
      expect(started[1].opts.session_id).to_be("session-a")
      expect(started[1].opts.instance_id).to_be("agent:session-a")
      expect(started[1].opts.kind).to_be("agent")
    end)

    it("does not claim the tab's own Claude slot", function()
      claudecode.register_tab_instance(3, { server = {}, port = 1 })
      claudecode.start_agent_instance("session-a", 3)
      -- The tab still resolves to its own Claude, not to an agent.
      expect(claudecode.get_instance(3).id).to_be("tab:3")
    end)

    it("is idempotent for one conversation", function()
      local first = claudecode.start_agent_instance("session-a", 3)
      local again = claudecode.start_agent_instance("session-a", 3)
      expect(again).to_be(first)
      expect(#started).to_be(1)
    end)

    it("refuses a launch with no conversation id", function()
      local inst, err = claudecode.start_agent_instance("", 3)
      expect(inst).to_be(nil)
      expect(err).to_be_string()
    end)

    it("finds the instance serving a conversation", function()
      local a = claudecode.start_agent_instance("session-a", 3)
      expect(claudecode.instance_for_session("session-a")).to_be(a)
      expect(claudecode.instance_for_session("nobody")).to_be(nil)
    end)

    it("lists every instance living in a tab", function()
      claudecode.register_tab_instance(3, { server = {}, port = 1 })
      claudecode.start_agent_instance("session-a", 3)
      claudecode.start_agent_instance("session-b", 3)
      claudecode.start_agent_instance("elsewhere", 4)

      expect(#claudecode.instances_in_tab(3)).to_be(3)
      expect(#claudecode.instances_in_tab(4)).to_be(1)
    end)

    it("stops one agent without touching its siblings", function()
      local a = claudecode.start_agent_instance("session-a", 3)
      local b = claudecode.start_agent_instance("session-b", 3)

      claudecode.stop_agent_instance("session-a")

      expect(a.server.stopped).to_be_true()
      expect(b.server.stopped).to_be(false)
      expect(claudecode.instance_for_session("session-a")).to_be(nil)
      expect(claudecode.instance_for_session("session-b")).to_be(b)
    end)
  end)

  describe("request context", function()
    local ctx

    before_each(function()
      ctx = require("claudecode.request_context")
      ctx.clear()
    end)

    it("is empty before any message is handled", function()
      expect(ctx.get()).to_be(nil)
      expect(ctx.tab()).to_be(nil)
      expect(ctx.session_id()).to_be(nil)
      expect(ctx.get_instance_id()).to_be(nil)
    end)

    it("names the sender of the message being handled", function()
      vim._tabs[5] = true
      ctx.set({ tab = 5, instance_id = "agent:x", session_id = "x", kind = "agent" })
      expect(ctx.tab()).to_be(5)
      expect(ctx.session_id()).to_be("x")
      expect(ctx.get_instance_id()).to_be("agent:x")
      expect(ctx.get().kind).to_be("agent")
    end)

    it("reports no tab once the sender's tab is gone", function()
      -- A Claude can outlive its tab; callers must fall back rather than target
      -- a stale handle.
      vim._tabs[5] = true
      ctx.set({ tab = 5, instance_id = "tab:5", kind = "tab" })
      expect(ctx.tab()).to_be(5)
      vim._tabs[5] = nil
      expect(ctx.tab()).to_be(nil)
      expect(ctx.get_instance_id()).to_be("tab:5")
    end)
  end)
end)
