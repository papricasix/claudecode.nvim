-- luacheck: globals expect
require("tests.busted_setup")

describe("session_state", function()
  local session_state

  local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

  --- Pretend every session id has (or has not) a transcript on disk.
  local function stub_transcripts(exists)
    vim.fn.isdirectory = function()
      return 1
    end
    vim.fn.glob = function()
      return exists and { "/home/user/.claude/projects/-proj/x.jsonl" } or {}
    end
  end

  --- Pretend only the listed session ids have a transcript on disk.
  local function stub_transcripts_for(ids)
    vim.fn.isdirectory = function()
      return 1
    end
    vim.fn.glob = function(pattern)
      local id = pattern:match("([^/]+)%.jsonl$")
      return ids[id] and { "/home/user/.claude/projects/-proj/" .. id .. ".jsonl" } or {}
    end
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    -- The mock's json.decode is a stub; the test harness ships a real one.
    vim.json.encode = _G.json_encode
    vim.json.decode = _G.json_decode
    vim.fn.isdirectory = nil
    vim.fn.glob = nil
    vim._tabs = { [1] = true, [2] = true }
    vim._current_tabpage = 1

    package.loaded["claudecode.session_state"] = nil
    session_state = require("claudecode.session_state")
    session_state.reset()
  end)

  local function enable(mode)
    session_state.setup({ session_persistence = mode or "global" })
  end

  describe("configuration", function()
    it("is off by default", function()
      package.loaded["claudecode.config"] = nil
      expect(require("claudecode.config").defaults.session_persistence).to_be("off")
    end)

    it("rejects an unknown mode", function()
      package.loaded["claudecode.config"] = nil
      local config = require("claudecode.config")
      local base = {
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
      }
      base.session_persistence = "external"
      expect(pcall(config.validate, base)).to_be_true()
      base.session_persistence = "sometimes"
      expect(pcall(config.validate, base)).to_be_false()
    end)

    it("tracks nothing while off", function()
      session_state.setup({ session_persistence = "off" })
      expect(session_state.is_enabled()).to_be_false()
      expect(session_state.launch_args("claude")).to_be("")
      expect(session_state.capture()).to_be_nil()
    end)
  end)

  describe("launch_args", function()
    it("names a fresh conversation with a v4 UUID", function()
      enable()
      local args = session_state.launch_args("claude")
      local id = args:match("^%-%-session%-id (.+)$")
      expect(id).to_be_string()
      assert.is_truthy(id:match(UUID_PATTERN))
    end)

    it("hands the same tab the same id on every toggle", function()
      enable()
      expect(session_state.launch_args("claude")).to_be(session_state.launch_args("claude"))
    end)

    it("gives each tab its own conversation", function()
      enable()
      local first = session_state.launch_args("claude")
      vim._current_tabpage = 2
      assert.are_not.equal(first, session_state.launch_args("claude"))
    end)

    it("resumes once the conversation exists on disk", function()
      enable()
      local id = session_state.launch_args("claude"):match("([^ ]+)$")
      stub_transcripts(true)
      expect(session_state.launch_args("claude")).to_be("--resume " .. id)
    end)

    it("keeps out of the way when the command already picks a conversation", function()
      enable()
      expect(session_state.launch_args("claude --continue")).to_be("")
      expect(session_state.launch_args("claude -r 123")).to_be("")
      expect(session_state.launch_args("claude --session-id=abc")).to_be("")
      expect(session_state.launch_args("claude --fork-session")).to_be("")
    end)
  end)

  describe("capture / restore", function()
    it("keys tabs by position and round-trips through JSON", function()
      enable()
      session_state.launch_args("claude", "/proj")
      vim._current_tabpage = 2
      session_state.launch_args("claude", "/other")

      local payload = session_state.capture()
      expect(payload.version).to_be(1)
      expect(payload.tabs["1"].cwd).to_be("/proj")
      expect(payload.tabs["2"].cwd).to_be("/other")

      local decoded = session_state.decode(session_state.encode())
      expect(decoded.tabs["1"].session_id).to_be(payload.tabs["1"].session_id)
    end)

    it("mirrors the payload into g:CLAUDECODE_SESSION in global mode", function()
      enable("global")
      session_state.launch_args("claude", "/proj")
      expect(vim.g.CLAUDECODE_SESSION).to_be_string()
    end)

    it("stores nothing itself in external mode", function()
      enable("external")
      session_state.launch_args("claude", "/proj")
      expect(vim.g.CLAUDECODE_SESSION).to_be_nil()
      expect(session_state.capture()).to_be_table()
    end)

    it("arms a restored tab so its next launch resumes", function()
      enable()
      local data = {
        version = 1,
        tabs = { ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" } },
      }
      expect(session_state.restore(data)).to_be_true()
      expect(session_state.launch_args("claude", "/proj")).to_be("--resume 11111111-1111-4111-8111-111111111111")
    end)

    it("resumes only in the directory the conversation belongs to", function()
      enable()
      session_state.restore({
        version = 1,
        tabs = { ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" } },
      })
      local args = session_state.launch_args("claude", "/somewhere/else")
      expect(args:match("^%-%-session%-id")).to_be_string()
    end)

    it("starts fresh when the restored conversation is gone from disk", function()
      enable()
      session_state.restore({
        version = 1,
        tabs = { ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" } },
      })
      stub_transcripts(false)
      local args = session_state.launch_args("claude", "/proj")
      expect(args:match("^%-%-session%-id")).to_be_string()
      assert.is_nil(args:match("11111111"))
    end)

    it("never retargets a tab that already runs a Claude", function()
      enable()
      local live = session_state.launch_args("claude", "/proj")
      session_state.restore({
        version = 1,
        tabs = { ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" } },
      })
      expect(session_state.launch_args("claude", "/proj")).to_be(live)
    end)

    it("ignores a payload written by another version", function()
      enable()
      expect(session_state.restore({ version = 99, tabs = { ["1"] = { session_id = "x" } } })).to_be_false()
      expect(session_state.restore("not json at all")).to_be_false()
      expect(session_state.restore(nil)).to_be_false()
    end)

    it("leaves out a Claude that never became a conversation", function()
      -- The CLI writes no transcript until the first message, and `--resume` on
      -- such an id fails. Persisting it armed the tab with something unresumable,
      -- which is what made restores resume some tabs and start the rest fresh.
      enable()
      session_state.launch_args("claude", "/proj")
      stub_transcripts(false)
      expect(session_state.capture()).to_be_nil()
    end)

    it("keeps the tab's last real conversation when the new one has no transcript", function()
      enable()
      stub_transcripts_for({ ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"] = true })
      session_state.note_session_id(1, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "/proj")
      -- The tab moves on (a /clear, say) before that conversation exists on disk.
      session_state.note_session_id(1, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "/proj")
      expect(session_state.capture().tabs["1"].session_id).to_be("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

      -- Once the new one is real it takes over.
      stub_transcripts_for({ ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"] = true })
      expect(session_state.capture().tabs["1"].session_id).to_be("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    end)

    it("forgets a closed conversation rather than falling back to it", function()
      enable()
      stub_transcripts_for({ ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"] = true })
      session_state.note_session_id(1, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "/proj")
      expect(session_state.forget(1)).to_be_true()
      session_state.launch_args("claude", "/proj")
      expect(session_state.capture()).to_be_nil()
    end)

    it("keeps unclaimed restored ids in the next capture", function()
      enable()
      session_state.restore({
        version = 1,
        tabs = { ["2"] = { session_id = "22222222-2222-4222-8222-222222222222", cwd = "/proj" } },
      })
      expect(session_state.capture().tabs["2"].session_id).to_be("22222222-2222-4222-8222-222222222222")
    end)
  end)

  describe("open_pending", function()
    local function armed_two_tabs()
      session_state.restore({
        version = 1,
        tabs = {
          ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" },
          ["2"] = { session_id = "22222222-2222-4222-8222-222222222222", cwd = "/proj" },
        },
      })
    end

    it("counts the tabs waiting on a restored conversation", function()
      enable()
      expect(session_state.pending_count()).to_be(0)
      armed_two_tabs()
      expect(session_state.pending_count()).to_be(2)
      -- Claiming a tab's id (its terminal opened) takes it off the pending list.
      session_state.launch_args("claude", "/proj")
      expect(session_state.pending_count()).to_be(1)
    end)

    it("visits every armed tab and returns to where it started", function()
      enable()
      armed_two_tabs()
      local visited = {}
      package.loaded["claudecode.terminal"] = {
        ensure_visible = function()
          table.insert(visited, vim.api.nvim_get_current_tabpage())
        end,
      }

      vim._current_tabpage = 2
      expect(session_state.open_pending()).to_be(2)
      expect(visited[1]).to_be(1)
      expect(visited[2]).to_be(2)
      expect(vim.api.nvim_get_current_tabpage()).to_be(2)
      package.loaded["claudecode.terminal"] = nil
    end)

    it("does nothing when no tab is armed", function()
      enable()
      package.loaded["claudecode.terminal"] = {
        ensure_visible = function()
          error("should not be called")
        end,
      }
      expect(session_state.open_pending()).to_be(0)
      package.loaded["claudecode.terminal"] = nil
    end)
  end)

  describe("forget", function()
    it("drops a live conversation so nothing resumes it", function()
      enable()
      session_state.launch_args("claude", "/proj")
      assert.is_truthy(session_state.get(1))

      expect(session_state.forget(1)).to_be_true()
      expect(session_state.get(1)).to_be_nil()
      expect(session_state.capture()).to_be_nil()
      -- Reopening the terminal in this tab starts a new conversation, not a resume.
      expect(session_state.launch_args("claude", "/proj"):match("^%-%-session%-id")).to_be_string()
    end)

    it("drops a restored id the tab has not claimed yet", function()
      enable()
      session_state.restore({
        version = 1,
        tabs = { ["1"] = { session_id = "11111111-1111-4111-8111-111111111111", cwd = "/proj" } },
      })
      expect(session_state.pending_count()).to_be(1)

      expect(session_state.forget(1)).to_be_true()
      expect(session_state.pending_count()).to_be(0)
      expect(session_state.launch_args("claude", "/proj"):match("^%-%-session%-id")).to_be_string()
    end)

    it("leaves other tabs alone and reports when there was nothing to forget", function()
      enable()
      session_state.launch_args("claude", "/proj")
      vim._current_tabpage = 2
      local other = session_state.launch_args("claude", "/proj")

      expect(session_state.forget(1)).to_be_true()
      expect(session_state.get(2).session_id).to_be(other:match("(%x+%-.*)$"))
      expect(session_state.forget(1)).to_be_false()
    end)
  end)

  describe("note_session_id", function()
    it("replaces the id we guessed with the one the CLI reports", function()
      enable()
      session_state.launch_args("claude", "/proj")
      session_state.note_session_id(1, "33333333-3333-4333-8333-333333333333", "/proj")
      expect(session_state.get(1).session_id).to_be("33333333-3333-4333-8333-333333333333")
      expect(session_state.capture().tabs["1"].session_id).to_be("33333333-3333-4333-8333-333333333333")
    end)

    it("ignores events from tabs that are gone", function()
      enable()
      session_state.note_session_id(99, "44444444-4444-4444-8444-444444444444")
      expect(session_state.get(99)).to_be_nil()
    end)
  end)

  describe("forget_closed_tabs", function()
    it("drops bookkeeping for tabs that no longer exist", function()
      enable()
      session_state.launch_args("claude", "/proj")
      vim._tabs = { [2] = true }
      vim._current_tabpage = 2
      session_state.forget_closed_tabs()
      expect(session_state.get(1)).to_be_nil()
    end)
  end)
end)
