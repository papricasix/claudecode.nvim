-- luacheck: globals expect
require("tests.busted_setup")

describe("health", function()
  local health
  local reports

  -- State the stubs expose to the module under test
  local fake_state
  local instances
  local server_status
  local executables
  local lock_readable

  local function record(level)
    return function(msg)
      table.insert(reports, { level = level, msg = msg })
    end
  end

  local function has_report(level, pattern)
    for _, r in ipairs(reports) do
      if r.level == level and r.msg:find(pattern) then
        return true
      end
    end
    return false
  end

  before_each(function()
    reports = {}
    executables = { claude = true }
    lock_readable = true
    server_status = { running = true, port = 12345, client_count = 1 }
    instances = {
      ["tab:1"] = {
        id = "tab:1",
        kind = "tab",
        tab = 1,
        server = {
          get_status = function()
            return server_status
          end,
        },
      },
    }
    fake_state = {
      initialized = true,
      config = { terminal_cmd = nil, terminal = { provider = "native" }, diff_opts = {} },
    }

    vim.health = {
      start = record("start"),
      ok = record("ok"),
      warn = record("warn"),
      error = record("error"),
      info = record("info"),
    }
    vim.trim = vim.trim or function(s)
      return s:match("^%s*(.-)%s*$")
    end
    vim.v = vim.v or {}
    vim.v.shell_error = 0
    vim.fn.executable = function(exe)
      return executables[exe] and 1 or 0
    end
    vim.fn.exepath = function(exe)
      return "/usr/bin/" .. exe
    end
    vim.fn.system = function(_)
      return "1.0.0 (Claude Code)\n"
    end
    vim.fn.filereadable = function(_)
      return lock_readable and 1 or 0
    end

    package.loaded["claudecode"] = {
      version = {
        string = function()
          return "0.2.0"
        end,
      },
      state = fake_state,
      instances = instances,
    }
    package.loaded["claudecode.lockfile"] = { lock_dir = "/tmp/claude/ide" }

    package.loaded["claudecode.health"] = nil
    health = require("claudecode.health")
  end)

  after_each(function()
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.lockfile"] = nil
    package.loaded["claudecode.health"] = nil
  end)

  it("reports all-ok for a healthy setup", function()
    health.check()

    expect(has_report("ok", "Neovim")).to_be_true()
    expect(has_report("ok", "is set up")).to_be_true()
    expect(has_report("ok", "Claude CLI found")).to_be_true()
    expect(has_report("ok", "WebSocket server on port 12345")).to_be_true()
    expect(has_report("ok", "lock file present")).to_be_true()
    expect(has_report("info", "1 client%(s%) connected")).to_be_true()
    expect(has_report("error", ".")).to_be_false()
  end)

  it("errors when setup() was not called and stops early", function()
    fake_state.initialized = false

    health.check()

    expect(has_report("error", "setup%(%) has not been called")).to_be_true()
    expect(has_report("ok", "Claude CLI found")).to_be_false()
  end)

  it("errors when the Claude CLI is missing", function()
    executables = {}

    health.check()

    expect(has_report("error", "Claude CLI not found")).to_be_true()
  end)

  it("resolves the executable from a custom terminal_cmd", function()
    fake_state.config.terminal_cmd = "/opt/claude/bin/claude --flag"
    executables["/opt/claude/bin/claude"] = true

    health.check()

    expect(has_report("ok", "Claude CLI found: /opt/claude/bin/claude")).to_be_true()
  end)

  it("warns when nothing is running", function()
    for key in pairs(instances) do
      instances[key] = nil
    end

    health.check()

    expect(has_report("warn", "No WebSocket server is running")).to_be_true()
    expect(has_report("ok", "lock file present")).to_be_false()
  end)

  it("errors when the lock file is missing", function()
    lock_readable = false

    health.check()

    expect(has_report("error", "lock file missing")).to_be_true()
  end)

  it("reports info when no client is connected", function()
    server_status.client_count = 0

    health.check()

    expect(has_report("info", "no Claude connected yet")).to_be_true()
  end)

  it("names an agent instance by its conversation", function()
    instances["agent:abc123"] = {
      id = "agent:abc123",
      kind = "agent",
      tab = 1,
      session_id = "abc123",
      server = {
        get_status = function()
          return { running = true, port = 23456, client_count = 0 }
        end,
      },
    }

    health.check()

    expect(has_report("ok", "agent abc123: WebSocket server on port 23456")).to_be_true()
  end)

  it("errors when snacks provider is configured but unavailable", function()
    fake_state.config.terminal = { provider = "snacks" }

    health.check()

    expect(has_report("error", "snacks.nvim is not installed")).to_be_true()
  end)

  it("warns when a float layout is configured without unified.nvim", function()
    fake_state.config.diff_opts = { layout = "float" }

    health.check()

    expect(has_report("warn", "unified.nvim is not installed")).to_be_true()
  end)
end)
