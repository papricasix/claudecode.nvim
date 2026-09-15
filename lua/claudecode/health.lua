--- Health check for claudecode.nvim, run via `:checkhealth claudecode`.
---
--- Verifies the prerequisites (Neovim version, Claude CLI, terminal provider)
--- and reports live integration state -- every running instance's WebSocket
--- server, its lock file and whether a Claude is connected to it -- without
--- launching anything.
---@module 'claudecode.health'
local M = {}

-- vim.health gained start/ok/warn/error in Neovim 0.10; older versions use report_* variants.
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error
local info = health.info or health.report_info or ok

---Extracts the executable (first token) from a command string.
---@param cmd string
---@return string executable
local function executable_of(cmd)
  assert(type(cmd) == "string" and cmd ~= "", "cmd must be a non-empty string")
  return cmd:match("^(%S+)") or cmd
end

local function check_neovim()
  if vim.fn.has("nvim-0.8.0") == 1 then
    ok("Neovim >= 0.8.0")
  else
    error_("Neovim >= 0.8.0 is required")
  end
end

---@param claudecode table The main plugin module
---@return boolean set_up
local function check_setup(claudecode)
  if claudecode.state.initialized then
    ok("claudecode.nvim " .. claudecode.version:string() .. " is set up")
    return true
  end
  error_("setup() has not been called", { 'Call require("claudecode").setup() (or use your plugin manager\'s opts)' })
  return false
end

---@param config table The merged plugin config
local function check_cli(config)
  local terminal_cmd = config.terminal_cmd
  local cmd = (terminal_cmd and terminal_cmd ~= "") and terminal_cmd or "claude"
  local exe = executable_of(cmd)

  if vim.fn.executable(exe) ~= 1 then
    error_(("Claude CLI not found: '%s' is not executable"):format(exe), {
      "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
      "Or set `terminal_cmd` in setup() to the full path of the CLI",
    })
    return
  end

  ok(("Claude CLI found: %s (%s)"):format(exe, vim.fn.exepath(exe)))

  local version_ok, output = pcall(vim.fn.system, { exe, "--version" })
  if version_ok and vim.v.shell_error == 0 then
    info("CLI version: " .. vim.trim(output))
  else
    warn(("'%s --version' failed; the configured command may not be the Claude CLI"):format(exe))
  end
end

---@param config table The merged plugin config
local function check_terminal_provider(config)
  local provider = config.terminal and config.terminal.provider or "auto"
  if type(provider) == "table" then
    info("Terminal provider: custom (table)")
    return
  end

  if provider == "auto" or provider == "snacks" then
    local has_snacks = pcall(require, "snacks")
    if has_snacks then
      ok(("Terminal provider '%s': snacks.nvim available"):format(provider))
    elseif provider == "snacks" then
      error_("Terminal provider 'snacks' configured but snacks.nvim is not installed")
    else
      ok("Terminal provider 'auto': snacks.nvim not installed, will fall back to native terminal")
    end
  elseif provider == "external" then
    local cmd = config.terminal.provider_opts and config.terminal.provider_opts.external_terminal_cmd
    if cmd and (type(cmd) == "function" or cmd:find("%%s")) then
      ok("Terminal provider 'external' configured")
    else
      error_("Terminal provider 'external' requires provider_opts.external_terminal_cmd containing '%s'")
    end
  else
    ok(("Terminal provider: %s"):format(provider))
  end
end

---Features that only work with a plugin we do not depend on say so here rather
---than at the moment they silently fall back.
---@param config table The merged plugin config
local function check_optional_deps(config)
  local diff_opts = config.diff_opts or {}
  local wants_unified = diff_opts.provider == "unified" or diff_opts.layout == "float"
  local has_unified = pcall(require, "unified.diff")

  if has_unified then
    ok("unified.nvim available (inline diffs, live cursor edit previews, file history)")
  elseif wants_unified then
    warn("unified.nvim is not installed; inline/float diffs fall back to a two-window split", {
      "Install kiyoon/unified.nvim (or papricasix/unified.nvim) for the inline renderer",
    })
  else
    info("unified.nvim not installed: diffs use the native two-window split")
  end

  if config.agents and config.agents.enabled and not pcall(require, "snacks") then
    info("snacks.nvim not installed: agents mode uses plain floating windows")
  end
end

---Each Claude the plugin is running -- a tab's own one and any agents -- has its
---own server, port, token and lock file, so the report is per instance.
---@param claudecode table The main plugin module
local function check_instances(claudecode)
  local lockfile = require("claudecode.lockfile")
  local instances = {}
  for _, inst in pairs(claudecode.instances or {}) do
    instances[#instances + 1] = inst
  end

  if #instances == 0 then
    warn("No WebSocket server is running", {
      "A server starts per tab when that tab's Claude is launched (auto_start = true)",
      "Or start one manually with :ClaudeCodeStart",
    })
    return
  end

  table.sort(instances, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)

  for _, inst in ipairs(instances) do
    local label = inst.kind == "agent" and ("agent " .. tostring(inst.session_id)) or ("tab " .. tostring(inst.tab))
    local status = inst.server and inst.server.get_status() or { running = false }

    if not status.running then
      error_(("%s: server registered but not running"):format(label))
    else
      ok(("%s: WebSocket server on port %d"):format(label, status.port))

      local lock_path = lockfile.lock_dir .. "/" .. tostring(status.port) .. ".lock"
      if vim.fn.filereadable(lock_path) == 1 then
        ok(("%s: lock file present (%s)"):format(label, lock_path))
      else
        error_(("%s: lock file missing (%s)"):format(label, lock_path), {
          "Claude discovers this Neovim instance through the lock file",
          "Restart the integration with :ClaudeCodeStop and :ClaudeCodeStart",
        })
      end

      local connected = status.client_count and status.client_count > 0
      if connected then
        info(("%s: %d client(s) connected"):format(label, status.client_count))
      else
        info(("%s: no Claude connected yet (launch one with :ClaudeCode)"):format(label))
      end
    end
  end
end

function M.check()
  start("claudecode.nvim")

  check_neovim()

  local loaded, claudecode = pcall(require, "claudecode")
  if not loaded then
    error_("Could not load claudecode module: " .. tostring(claudecode))
    return
  end

  if not check_setup(claudecode) then
    return
  end

  check_cli(claudecode.state.config)
  check_terminal_provider(claudecode.state.config)
  check_optional_deps(claudecode.state.config)
  check_instances(claudecode)
end

return M
