-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.registry", function()
  local registry
  local spawned -- every M._spawn call, in order
  local instances -- agent server instances handed out by the stubbed main module
  local stopped_instances

  local function stub_dependencies()
    spawned, instances, stopped_instances = {}, {}, {}

    local next_port = 5000
    package.loaded["claudecode"] = {
      start_agent_instance = function(session_id, tab)
        if instances[session_id] then
          return instances[session_id]
        end
        next_port = next_port + 1
        local inst = { id = "agent:" .. session_id, port = next_port, tab = tab }
        instances[session_id] = inst
        return inst
      end,
      stop_agent_instance = function(session_id)
        stopped_instances[#stopped_instances + 1] = session_id
        instances[session_id] = nil
      end,
    }

    package.loaded["claudecode.terminal"] = {
      build_launch = function(cmd_args, opts)
        local port = opts and opts.instance and opts.instance.port
        return "claude " .. (cmd_args or ""), { CLAUDE_CODE_SSE_PORT = tostring(port) }, { cwd = opts and opts.cwd }
      end,
    }
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    stub_dependencies()

    package.loaded["claudecode.agents.registry"] = nil
    registry = require("claudecode.agents.registry")
    registry._spawn = function(cmd, opts)
      spawned[#spawned + 1] = { cmd = cmd, opts = opts }
      return 100 + #spawned
    end

    vim._tabs[1] = true
    vim._current_tabpage = 1
    vim._mock.add_buffer(1, "editor", "")
    vim._mock.add_window(1000, 1)
    vim._win_tab[1000] = 1
    vim._tab_windows[1] = { 1000 }
    vim._current_window = 1000
    vim._next_winid = 1001
  end)

  after_each(function()
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.terminal"] = nil
  end)

  describe("launching", function()
    it("names a fresh conversation with --session-id", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(term).to_be_table()
      expect(#spawned).to_be(1)
      expect(table.concat(spawned[1].cmd, " "):find("--session-id abc", 1, true) ~= nil).to_be_true()
    end)

    it("resumes an existing conversation with --resume", function()
      registry.launch("abc", { win = 1000, tab = 1, resume = true })
      expect(table.concat(spawned[1].cmd, " "):find("--resume abc", 1, true) ~= nil).to_be_true()
      expect(registry.get("abc").resumed).to_be_true()
    end)

    it("gives each agent its own server port", function()
      registry.launch("abc", { win = 1000, tab = 1 })
      registry.launch("def", { win = 1000, tab = 1 })
      expect(spawned[1].opts.env.CLAUDE_CODE_SSE_PORT ~= spawned[2].opts.env.CLAUDE_CODE_SSE_PORT).to_be_true()
    end)

    it("marks the buffer so hiding it does not kill the process", function()
      -- bufhidden = "hide" is the whole basis of "switch away, keep working".
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(vim.bo[term.bufnr].bufhidden).to_be("hide")
    end)

    it("stamps the tab and conversation on the buffer", function()
      -- TermClose is handed only a buffer, and by then the terminal may be in no
      -- window at all.
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(vim.b[term.bufnr].claudecode_tab).to_be(1)
      expect(vim.b[term.bufnr].claudecode_agent_session).to_be("abc")
    end)

    it("spawns in the window it was given", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(vim.api.nvim_win_get_buf(1000)).to_be(term.bufnr)
    end)

    it("refuses a launch without a valid window", function()
      local term, err = registry.launch("abc", { win = 4242 })
      expect(term).to_be(nil)
      expect(err).to_be_string()
      expect(#spawned).to_be(0)
    end)

    it("refuses a launch with no conversation id", function()
      local term, err = registry.launch("", { win = 1000 })
      expect(term).to_be(nil)
      expect(err).to_be_string()
    end)

    it("does not leave a server running when the spawn fails", function()
      registry._spawn = function()
        return 0
      end
      local term, err = registry.launch("abc", { win = 1000, tab = 1 })
      expect(term).to_be(nil)
      expect(err).to_be_string()
      expect(stopped_instances[1]).to_be("abc")
    end)
  end)

  describe("showing and hiding", function()
    it("re-shows a running agent without restarting it", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      -- Hide it: the buffer simply leaves the window.
      vim.api.nvim_win_set_buf(1000, 1)
      expect(registry.show("abc", 1000)).to_be_true()
      expect(vim.api.nvim_win_get_buf(1000)).to_be(term.bufnr)
      expect(#spawned).to_be(1) -- never respawned
    end)

    it("relaunching a live agent reuses its terminal", function()
      local first = registry.launch("abc", { win = 1000, tab = 1 })
      local again = registry.launch("abc", { win = 1000, tab = 1 })
      expect(again.bufnr).to_be(first.bufnr)
      expect(#spawned).to_be(1)
    end)

    it("cannot show a conversation it never launched", function()
      expect(registry.show("nobody", 1000)).to_be(false)
    end)

    it("keeps siblings alive while one is displayed", function()
      registry.launch("abc", { win = 1000, tab = 1 })
      registry.launch("def", { win = 1000, tab = 1 })
      -- "def" is on screen, "abc" is hidden -- both still running.
      expect(registry.is_live("abc")).to_be_true()
      expect(registry.is_live("def")).to_be_true()
      expect(#registry.live_ids()).to_be(2)
    end)
  end)

  describe("lookup", function()
    it("maps a terminal buffer back to its conversation", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(registry.session_for_buf(term.bufnr)).to_be("abc")
      expect(registry.session_for_buf(9999)).to_be(nil)
    end)
  end)

  describe("exit", function()
    it("stops the agent's server when its process ends", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      registry._on_exit("abc", term.jobid, 0)
      expect(registry.get("abc").exited).to_be_true()
      expect(registry.is_live("abc")).to_be(false)
      expect(stopped_instances[1]).to_be("abc")
    end)

    it("ignores an exit from a stale job id", function()
      -- A relaunched conversation must not be torn down by the previous run's exit.
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      registry._on_exit("abc", term.jobid + 999, 1)
      expect(registry.get("abc").exited).to_be(false)
    end)
  end)

  describe("teardown", function()
    it("stops one agent without touching its siblings", function()
      registry.launch("abc", { win = 1000, tab = 1 })
      registry.launch("def", { win = 1000, tab = 1 })

      expect(registry.stop("abc")).to_be_true()
      expect(registry.get("abc")).to_be(nil)
      expect(registry.is_live("def")).to_be_true()
    end)

    it("stops only the agents of the tab it is given", function()
      vim._tabs[2] = true
      registry.launch("abc", { win = 1000, tab = 1 })
      registry.launch("def", { win = 1000, tab = 2 })

      expect(registry.cleanup_tab(1)).to_be(1)
      expect(registry.get("abc")).to_be(nil)
      expect(registry.is_live("def")).to_be_true()
    end)

    it("stopping an unknown conversation is a no-op", function()
      expect(registry.stop("nobody")).to_be(false)
    end)
  end)
end)
