-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.registry", function()
  local registry
  local spawned -- every M._spawn call, in order
  local instances -- agent server instances handed out by the stubbed main module
  local stopped_instances
  local retagged_floats

  local function stub_dependencies()
    spawned, instances, stopped_instances, retagged_floats = {}, {}, {}, {}

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
      rekey_agent_instance = function(inst, session_id)
        instances[inst.session_id or ""] = nil
        inst.id = "agent:" .. session_id
        inst.session_id = session_id
        instances[session_id] = inst
      end,
    }

    package.loaded["claudecode.float"] = {
      retag = function(previous, session_id)
        retagged_floats[#retagged_floats + 1] = { previous, session_id }
        return 1
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
    package.loaded["claudecode.float"] = nil
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

    it("starts in the directory it was given", function()
      vim._mock.add_dir("/proj")
      registry.launch("abc", { win = 1000, tab = 1, cwd = "/proj" })
      expect(spawned[1].opts.cwd).to_be("/proj")
    end)

    it("drops a recorded directory that no longer exists", function()
      -- A renamed or moved project leaves every one of its transcripts naming a
      -- path that is gone, and `termopen` refuses such a cwd outright -- which
      -- made those conversations unstartable rather than merely misplaced.
      local term = registry.launch("abc", { win = 1000, tab = 1, cwd = "/moved/away" })
      expect(term).to_be_table()
      expect(spawned[1].opts.cwd).to_be(nil)
      expect(term.cwd).to_be(nil)
    end)

    it("says why a spawn failed", function()
      registry._spawn = function()
        error("Vim:E475: Invalid argument: expected valid directory")
      end
      local _, err = registry.launch("abc", { win = 1000, tab = 1 })
      expect(err:find("E475", 1, true) ~= nil).to_be_true()
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

  describe("following /clear", function()
    -- Measured against the real CLI (2.1.226): `/clear` fires SessionEnd(clear)
    -- for the old id and SessionStart(clear) with a brand new one, in the same
    -- terminal and the same process.
    local function key_of(session_id)
      return registry.get(session_id).agent_key
    end

    it("hands the hook a launch key that is not the conversation id", function()
      registry.launch("abc", { win = 1000, tab = 1 })
      local key = spawned[1].opts.env.CLAUDECODE_AGENT_ID
      expect(type(key)).to_be("string")
      expect(key ~= "abc").to_be_true()
      expect(key:find("abc", 1, true) ~= nil).to_be_true()
    end)

    it("moves a running agent onto the conversation it reports", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(registry.rekey(key_of("abc"), "def")).to_be("abc")

      expect(registry.is_live("abc")).to_be(false)
      expect(registry.is_live("def")).to_be_true()
      expect(registry.get("def")).to_be(term)
      expect(term.session_id).to_be("def")
      expect(vim.b[term.bufnr].claudecode_agent_session).to_be("def")
    end)

    it("keeps the same terminal and the same server", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      local bufnr, jobid, inst = term.bufnr, term.jobid, term.instance
      registry.rekey(key_of("abc"), "def")

      expect(term.bufnr).to_be(bufnr)
      expect(term.jobid).to_be(jobid)
      expect(term.instance).to_be(inst)
      expect(#stopped_instances).to_be(0)
      -- Renamed, not replaced: the client is still connected to that port.
      expect(inst.session_id).to_be("def")
    end)

    it("takes the agent's open floats with it", function()
      registry.launch("abc", { win = 1000, tab = 1 })
      registry.rekey(key_of("abc"), "def")
      expect(#retagged_floats).to_be(1)
      expect(retagged_floats[1][1]).to_be("abc")
      expect(retagged_floats[1][2]).to_be("def")
    end)

    it("stops the right server once the moved agent ends", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      registry.rekey(key_of("abc"), "def")
      registry._on_exit("def", term.jobid, 0)
      expect(stopped_instances[1]).to_be("def")
      expect(registry.is_live("def")).to_be(false)
    end)

    it("leaves the id it was launched with free to start again", function()
      -- The old conversation is a row like any other; picking it starts a second
      -- agent, and that one must not be addressed by the first one's key.
      local first = registry.launch("abc", { win = 1000, tab = 1 })
      local first_key = key_of("abc")
      registry.rekey(first_key, "def")

      local second = registry.launch("abc", { win = 1000, tab = 1, resume = true })
      expect(second ~= first).to_be_true()
      expect(registry.rekey(key_of("def"), "ghi")).to_be("def")
      expect(registry.get("abc")).to_be(second)
      expect(second.session_id).to_be("abc")
    end)

    it("does not drift back onto a conversation it has left", function()
      -- `/clear` fires SessionEnd for the old chat and SessionStart for the new
      -- one as two async hook processes, so the CLI's order is not the order they
      -- arrive in. A late SessionEnd used to point the agent back at the
      -- conversation it had just abandoned.
      registry.launch("abc", { win = 1000, tab = 1 })
      local key = key_of("abc")
      registry.rekey(key, "def")

      expect(registry.rekey(key, "abc")).to_be(nil)
      expect(registry.is_live("def")).to_be_true()
      expect(registry.is_live("abc")).to_be(false)
    end)

    it("follows a SessionStart back to an earlier conversation", function()
      -- Resuming one from inside the CLI is the user saying so; only a stale
      -- mention of it is refused above.
      registry.launch("abc", { win = 1000, tab = 1 })
      local key = key_of("abc")
      registry.rekey(key, "def")

      expect(registry.rekey(key, "abc", { reclaim = true })).to_be("def")
      expect(registry.is_live("abc")).to_be_true()
    end)

    it("ignores an unknown key, a repeat of the same id, and a dead agent", function()
      local term = registry.launch("abc", { win = 1000, tab = 1 })
      expect(registry.rekey("nobody", "def")).to_be(nil)
      expect(registry.rekey(key_of("abc"), "abc")).to_be(nil)
      expect(registry.rekey(key_of("abc"), nil)).to_be(nil)

      registry._on_exit("abc", term.jobid, 0)
      expect(registry.rekey(key_of("abc"), "def")).to_be(nil)
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
