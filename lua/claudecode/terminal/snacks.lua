---Snacks.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local utils = require("claudecode.utils")

-- Per-tab terminal instances: [tabpage_id] = snacks terminal instance
local instances = {}

local function get_terminal(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  return instances[tab_id]
end

local function set_terminal(tab_id, term)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  instances[tab_id] = term
end

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

---Setup event handlers for terminal instance.
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
---@param registered_tab number The tabpage this terminal belongs to
local function setup_terminal_events(term_instance, config, registered_tab)
  local logger = require("claudecode.logger")

  if config.auto_close then
    term_instance:on("TermClose", function()
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      set_terminal(registered_tab, nil)
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped")
    set_terminal(registered_tab, nil)
  end, { buf = true })
end

---Builds Snacks terminal options with focus control.
---@param config ClaudeCodeTerminalConfig
---@param env_table table
---@param focus boolean|nil
---@return snacks.terminal.Opts
local function build_opts(config, env_table, focus)
  focus = utils.normalize_focus(focus)
  return {
    env = env_table,
    cwd = config.cwd,
    -- `start_insert` is a one-shot "enter insert now", so it follows `focus`: an
    -- unfocused open must not drag you into the terminal. `auto_insert` is a
    -- different thing — it installs a lasting BufEnter autocmd that starts insert
    -- whenever you step into the terminal window later — so it must NOT follow
    -- `focus`, or a terminal opened without focus (the session-restore path opens
    -- every tab's Claude that way) would never capture your typing again.
    start_insert = focus,
    auto_insert = true,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
      keys = {
        claude_new_line = {
          "<S-CR>",
          function()
            vim.api.nvim_feedkeys("\\", "t", true)
            vim.defer_fn(function()
              vim.api.nvim_feedkeys("\r", "t", true)
            end, 10)
          end,
          mode = "t",
          desc = "New line",
        },
      },
    } --[[@as snacks.win.Config]], config.snacks_win_opts or {}),
  } --[[@as snacks.terminal.Opts]]
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim.
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)
  local tab_id = vim.api.nvim_get_current_tabpage()
  local terminal = get_terminal(tab_id)

  if terminal and terminal:buf_valid() then
    if not terminal.win or not vim.api.nvim_win_is_valid(terminal.win) then
      terminal:toggle()
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    else
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    end
    return
  end

  local opts = build_opts(config, env_table, focus)
  -- Pass an argv list (not a string) so Snacks spawns Claude via termopen()
  -- without a shell. A shell would glob-expand bracketed model aliases like
  -- "opus[1m]" (e.g. zsh aborts with "no matches found"). parse_command keeps
  -- quoted arguments intact and expands a leading "~". Mirrors native.
  local cmd = utils.parse_command(cmd_string)
  local term_instance = Snacks.terminal.open(cmd, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config, tab_id)
    set_terminal(tab_id, term_instance)
  else
    set_terminal(tab_id, nil)
    local logger = require("claudecode.logger")
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

---Close the terminal.
function M.close()
  if not is_available() then
    return
  end
  local tab_id = vim.api.nvim_get_current_tabpage()
  local terminal = get_terminal(tab_id)
  if terminal and terminal:buf_valid() then
    terminal:close()
  end
end

---Simple toggle: always show/hide terminal regardless of focus.
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local tab_id = vim.api.nvim_get_current_tabpage()
  local terminal = get_terminal(tab_id)

  if terminal and terminal:buf_valid() and terminal:win_valid() then
    logger.debug("terminal", "Simple toggle: hiding visible terminal")
    terminal:toggle()
  elseif terminal and terminal:buf_valid() and not terminal:win_valid() then
    logger.debug("terminal", "Simple toggle: showing hidden terminal")
    terminal:toggle()
  else
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local tab_id = vim.api.nvim_get_current_tabpage()
  local terminal = get_terminal(tab_id)

  if terminal and terminal:buf_valid() and not terminal:win_valid() then
    logger.debug("terminal", "Focus toggle: showing hidden terminal")
    terminal:toggle()
  elseif terminal and terminal:buf_valid() and terminal:win_valid() then
    local claude_term_neovim_win_id = terminal.win
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    if claude_term_neovim_win_id == current_neovim_win_id then
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      terminal:toggle()
    else
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(claude_term_neovim_win_id)
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        if vim.api.nvim_buf_get_option(terminal.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(claude_term_neovim_win_id, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
  else
    logger.debug("terminal", "Focus toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle).
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number for the current tab.
---@return number?
function M.get_active_bufnr()
  local tab_id = vim.api.nvim_get_current_tabpage()
  local terminal = get_terminal(tab_id)
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes.
---@return table? terminal The terminal instance for the current tab, or nil
function M._get_terminal_for_test()
  return get_terminal()
end

---@type ClaudeCodeTerminalProvider
return M
