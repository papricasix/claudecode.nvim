---Native Neovim terminal provider for Claude Code.
---@module 'claudecode.terminal.native'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

-- Per-tab state: [tabpage_id] = { bufnr, winid, jobid }
local instances = {}
local tip_shown = false

---@type ClaudeCodeTerminalConfig
local config = require("claudecode.terminal").defaults

---Return the state table for a given (or current) tabpage, creating it if missing.
local function get_tab_state(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  if not instances[tab_id] then
    instances[tab_id] = { bufnr = nil, winid = nil, jobid = nil }
  end
  return instances[tab_id]
end

local function cleanup_state(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)
  s.bufnr = nil
  s.winid = nil
  s.jobid = nil
end

local function is_valid(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    cleanup_state(tab_id)
    return false
  end

  if not s.winid or not vim.api.nvim_win_is_valid(s.winid) then
    -- Search windows in this tab for our terminal buffer
    local tab_wins = vim.api.nvim_tabpage_list_wins(tab_id)
    for _, win in ipairs(tab_wins) do
      if vim.api.nvim_win_get_buf(win) == s.bufnr then
        s.winid = win
        logger.debug("terminal", "Recovered terminal window ID:", win)
        return true
      end
    end
    -- Buffer exists but no window in this tab displays it (hidden)
    return true
  end

  return true
end

local function open_terminal(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  if is_valid(tab_id) then
    if focus then
      vim.api.nvim_set_current_win(s.winid)
      vim.cmd("startinsert")
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  vim.api.nvim_win_call(new_winid, function()
    vim.cmd("enew")
  end)

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  -- Capture tab_id and state slot at spawn time so on_exit cleans up the right entry
  local spawned_tab = tab_id

  s.jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    cwd = effective_config.cwd,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        local spawned_s = instances[spawned_tab]
        if spawned_s and job_id == spawned_s.jobid then
          logger.debug("terminal", "Terminal process exited, cleaning up")

          local current_winid_for_job = spawned_s.winid
          local current_bufnr_for_job = spawned_s.bufnr

          cleanup_state(spawned_tab)

          if not effective_config.auto_close then
            return
          end

          if current_winid_for_job and vim.api.nvim_win_is_valid(current_winid_for_job) then
            if current_bufnr_for_job and vim.api.nvim_buf_is_valid(current_bufnr_for_job) then
              if vim.api.nvim_win_get_buf(current_winid_for_job) == current_bufnr_for_job then
                vim.api.nvim_win_close(current_winid_for_job, true)
              end
            else
              vim.api.nvim_win_close(current_winid_for_job, true)
            end
          end
        end
      end)
    end,
  })

  if not s.jobid or s.jobid == 0 then
    vim.notify("Failed to open native terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_state(tab_id)
    return false
  end

  s.winid = new_winid
  s.bufnr = vim.api.nvim_get_current_buf()
  vim.bo[s.bufnr].bufhidden = "hide"

  if focus then
    vim.api.nvim_set_current_win(s.winid)
    vim.cmd("startinsert")
  else
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
  return true
end

local function close_terminal()
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)
  if is_valid(tab_id) then
    vim.api.nvim_win_close(s.winid, true)
    cleanup_state(tab_id)
  end
end

local function focus_terminal()
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)
  if is_valid(tab_id) then
    vim.api.nvim_set_current_win(s.winid)
    vim.cmd("startinsert")
  end
end

local function is_terminal_visible()
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    return false
  end

  local tab_wins = vim.api.nvim_tabpage_list_wins(tab_id)
  for _, win in ipairs(tab_wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == s.bufnr then
      s.winid = win
      return true
    end
  end

  s.winid = nil
  return false
end

local function hide_terminal()
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)
  if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) and s.winid and vim.api.nvim_win_is_valid(s.winid) then
    vim.api.nvim_win_close(s.winid, false)
    s.winid = nil
    logger.debug("terminal", "Terminal window hidden, process preserved")
  end
end

local function show_hidden_terminal(effective_config, focus)
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  if not s.bufnr or not vim.api.nvim_buf_is_valid(s.bufnr) then
    return false
  end

  if is_terminal_visible() then
    if focus then
      focus_terminal()
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()

  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  vim.api.nvim_win_set_buf(new_winid, s.bufnr)
  s.winid = new_winid

  if focus then
    vim.api.nvim_set_current_win(s.winid)
    vim.cmd("startinsert")
  else
    vim.api.nvim_set_current_win(original_win)
  end

  logger.debug("terminal", "Showed hidden terminal in new window")
  return true
end

local function find_existing_claude_terminal()
  -- Only search windows in the current tab
  local tab_id = vim.api.nvim_get_current_tabpage()
  local tab_wins = vim.api.nvim_tabpage_list_wins(tab_id)
  for _, win in ipairs(tab_wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name:match("claude") then
        logger.debug("terminal", "Found existing Claude terminal in buffer", buf, "window", win)
        return buf, win
      end
    end
  end
  return nil, nil
end

---Setup the terminal module.
---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config
end

---@param cmd_string string
---@param env_table table
---@param effective_config table
---@param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  if is_valid(tab_id) then
    if not s.winid or not vim.api.nvim_win_is_valid(s.winid) then
      show_hidden_terminal(effective_config, focus)
    else
      if focus then
        focus_terminal()
      end
    end
  else
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      s.bufnr = existing_buf
      s.winid = existing_win
      logger.debug("terminal", "Recovered existing Claude terminal")
      if focus then
        focus_terminal()
      end
    else
      if not open_terminal(cmd_string, env_table, effective_config, focus) then
        vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
      end
    end
  end
end

function M.close()
  close_terminal()
end

---Simple toggle: always show/hide terminal regardless of focus.
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  local has_buffer = s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr)
  local visible = has_buffer and is_terminal_visible()

  if visible then
    hide_terminal()
  else
    if has_buffer then
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    else
      local existing_buf, existing_win = find_existing_claude_terminal()
      if existing_buf and existing_win then
        s.bufnr = existing_buf
        s.winid = existing_win
        logger.debug("terminal", "Recovered existing Claude terminal")
        focus_terminal()
      else
        if not open_terminal(cmd_string, env_table, effective_config) then
          vim.notify("Failed to open Claude terminal using native fallback (simple_toggle).", vim.log.levels.ERROR)
        end
      end
    end
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  local tab_id = vim.api.nvim_get_current_tabpage()
  local s = get_tab_state(tab_id)

  local has_buffer = s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr)
  local visible = has_buffer and is_terminal_visible()

  if has_buffer then
    if visible then
      local current_win_id = vim.api.nvim_get_current_win()
      if s.winid == current_win_id then
        hide_terminal()
      else
        focus_terminal()
      end
    else
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    end
  else
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      s.bufnr = existing_buf
      s.winid = existing_win
      logger.debug("terminal", "Recovered existing Claude terminal")

      local current_win_id = vim.api.nvim_get_current_win()
      if existing_win == current_win_id then
        hide_terminal()
      else
        focus_terminal()
      end
    else
      if not open_terminal(cmd_string, env_table, effective_config) then
        vim.notify("Failed to open Claude terminal using native fallback (focus_toggle).", vim.log.levels.ERROR)
      end
    end
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle).
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

---@return number|nil
function M.get_active_bufnr()
  local tab_id = vim.api.nvim_get_current_tabpage()
  if is_valid(tab_id) then
    return get_tab_state(tab_id).bufnr
  end
  return nil
end

---@return boolean
function M.is_available()
  return true
end

---@type ClaudeCodeTerminalProvider
return M
