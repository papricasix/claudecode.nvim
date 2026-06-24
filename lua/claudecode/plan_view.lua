---@brief [[
--- Plan view: render Claude's plan-mode plan in the editor, like the VS Code extension.
---
--- When Claude runs in plan mode it presents the finished plan by calling the
--- built-in `ExitPlanMode` tool, whose input carries the plan as a markdown
--- string. That tool is internal to the Claude CLI and is never sent to the IDE
--- over the MCP WebSocket, so we tap the same hook seam the live-cursor feature
--- uses: a `PreToolUse` hook (injected at launch via `claude --settings`) forwards
--- every matched tool event into Neovim. `live_cursor.dispatch` routes the
--- `ExitPlanMode` event here, and we open the plan markdown in a reused split.
---
--- The window is opened the moment the plan is ready to read (PreToolUse, before
--- the user accepts/rejects) and closed once the plan is resolved — either by the
--- `PostToolUse(ExitPlanMode)` accept signal or by the next tool event Claude
--- emits (which means it has started executing an accepted plan, or resumed
--- planning after a reject). See `live_cursor.dispatch`.
---@brief ]]
---@module 'claudecode.plan_view'

local M = {}

local logger = require("claudecode.logger")

--- Cached `claudecode.diff` module — reused only for its canonical editor-window
--- finder. `false` means a load attempt already failed (don't retry every event).
local _diff
local function get_diff()
  if _diff == nil then
    local ok, mod = pcall(require, "claudecode.diff")
    _diff = ok and mod or false
  end
  return _diff or nil
end

--- Plan config subtable (see config.lua defaults / validation).
---@type table|nil
local config = nil

local state = {
  plan_win = nil, -- window currently hosting the plan (a taken-over editor window, or a created split)
  plan_buf = nil, -- scratch buffer holding the plan markdown
  prev_buf = nil, -- buffer displaced from plan_win, restored on resolve (take-over case only)
  prev_cursor = nil, -- cursor position to restore alongside prev_buf
  created_split = nil, -- true when plan_win is a split we created (no editor window to take over)
  clear_timer = nil, -- inactivity backstop timer handle
}

---@return boolean
function M.is_enabled()
  return config ~= nil and config.enabled == true
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param full_config table The full plugin config (expects a `plan` field).
function M.setup(full_config)
  config = (full_config and full_config.plan) or {}
  -- Provide a sensible default highlight for our own group only, leaving any
  -- user-supplied group untouched. `default = true` lets a user colorscheme win.
  if (config.highlight or "ClaudeCodePlan") == "ClaudeCodePlan" then
    pcall(vim.api.nvim_set_hl, 0, "ClaudeCodePlan", { link = "DiagnosticInfo", default = true })
  end
end

--------------------------------------------------------------------------------
-- Tab awareness (mirrors live_cursor: a background-tab Claude must not open its
-- plan in whatever tab the user happens to be looking at).
--------------------------------------------------------------------------------

---Whether the triggering Claude lives in a different tab than the one the user is
---viewing.
---@param source_tab integer|nil The tabpage the Claude was launched in (0/nil = unknown).
---@return boolean
local function wrong_tab(source_tab)
  if not source_tab or source_tab == 0 then
    return false -- unknown (e.g. single instance / old hook): don't restrict
  end
  if not vim.api.nvim_tabpage_is_valid(source_tab) then
    return true -- the launching tab was closed; never hijack a still-open tab
  end
  local ok, cur = pcall(vim.api.nvim_get_current_tabpage)
  return ok and cur ~= source_tab
end

--------------------------------------------------------------------------------
-- Window + buffer
--------------------------------------------------------------------------------

---Apply the winbar marker to the plan window so it reads as a Claude plan view.
---@param win integer
local function apply_marker(win)
  local hl = config.highlight or "ClaudeCodePlan"
  -- Escape '%' (statusline meta) in the visible label; keep the '%#group#' and
  -- '%=' alignment items literal so they render as a centered, colored label.
  local label = (config.label or "● Claude plan"):gsub("%%", "%%%%")
  pcall(function()
    vim.wo[win].winbar = "%#" .. hl .. "#%=" .. label .. "%="
  end)
  pcall(function()
    vim.wo[win].winhighlight = "WinSeparator:" .. hl
  end)
end

---Create a dedicated split for the plan — the fallback when there is no editor
---window to take over (e.g. only the Claude terminal is visible).
---@return integer|nil
local function create_plan_split()
  local original = vim.api.nvim_get_current_win()
  local base = original
  local split_cmd = config.layout == "horizontal" and "belowright split" or "rightbelow vsplit"
  local new_win = nil
  pcall(vim.api.nvim_win_call, base, function()
    vim.cmd(split_cmd)
    new_win = vim.api.nvim_get_current_win()
  end)
  if original and vim.api.nvim_win_is_valid(original) then
    pcall(vim.api.nvim_set_current_win, original)
  end
  if not (new_win and vim.api.nvim_win_is_valid(new_win)) then
    return nil
  end
  local size = config.split_size_percentage or 0.5
  if config.layout == "horizontal" then
    pcall(vim.api.nvim_win_set_height, new_win, math.max(1, math.floor(vim.o.lines * size)))
  else
    pcall(vim.api.nvim_win_set_width, new_win, math.max(1, math.floor(vim.o.columns * size)))
  end
  return new_win
end

---Resolve the window to render the plan into.
---Prefers taking over the editor window closest to the Claude terminal; falls back
---to a dedicated split only when there is no editor window to reuse.
---@return integer|nil win
---@return boolean created True when `win` is a split we created (vs. a taken-over editor window).
local function resolve_window()
  -- Reuse the window already hosting the plan (a second plan in the same session).
  if
    state.plan_win
    and vim.api.nvim_win_is_valid(state.plan_win)
    and state.plan_buf
    and vim.api.nvim_win_get_buf(state.plan_win) == state.plan_buf
  then
    return state.plan_win, state.created_split == true
  end

  local d = get_diff()
  local target = d and d.find_window_closest_to_terminal and d.find_window_closest_to_terminal()
  if target and vim.api.nvim_win_is_valid(target) then
    return target, false
  end

  -- No editor window to take over: open a dedicated split instead.
  local split = create_plan_split()
  if split then
    return split, true
  end
  return nil, false
end

---Create (or reuse) the read-only scratch buffer holding the plan markdown.
---@param markdown string
---@return integer|nil
local function ensure_buf(markdown)
  local buf = state.plan_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    if not buf or buf == 0 then
      return nil
    end
    pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
    pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
    pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
    pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
    pcall(vim.api.nvim_buf_set_name, buf, "Claude plan")
    state.plan_buf = buf
  end
  local lines = vim.split(markdown, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", true)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", false)
  return buf
end

--------------------------------------------------------------------------------
-- Inactivity backstop
--------------------------------------------------------------------------------

local function stop_clear_timer()
  if state.clear_timer then
    pcall(function()
      state.clear_timer:stop()
      state.clear_timer:close()
    end)
    state.clear_timer = nil
  end
end

local function arm_clear_timer()
  local delay = config and config.clear_delay_ms or 0
  if not delay or delay <= 0 then
    return
  end
  stop_clear_timer()
  state.clear_timer = vim.defer_fn(function()
    state.clear_timer = nil
    M.close()
  end, delay)
end

--------------------------------------------------------------------------------
-- Public API (called from live_cursor.dispatch)
--------------------------------------------------------------------------------

---Open Claude's plan markdown in the reused plan split.
---@param markdown string The plan markdown (from the ExitPlanMode tool input).
---@param source_tab integer|nil Tabpage the triggering Claude was launched in.
function M.show(markdown, source_tab)
  if not M.is_enabled() then
    return
  end
  if type(markdown) ~= "string" or markdown == "" then
    return
  end
  if wrong_tab(source_tab) then
    logger.debug("plan_view", "skip plan: Claude in tab", tostring(source_tab), "is not the current tab")
    return
  end

  local buf = ensure_buf(markdown)
  if not buf then
    return
  end
  local win, created = resolve_window()
  if not win then
    logger.debug("plan_view", "no window available for plan")
    return
  end

  -- Record the buffer we're displacing so we can restore it when the plan resolves
  -- — but only when taking over an existing editor window, and not when we're
  -- already showing the plan there (so a second plan keeps the original prev_buf).
  if not created then
    local cur = vim.api.nvim_win_get_buf(win)
    if cur ~= buf then
      state.prev_buf = cur
      local okc, c = pcall(vim.api.nvim_win_get_cursor, win)
      state.prev_cursor = okc and c or nil
    end
  end
  state.plan_win = win
  state.created_split = created

  pcall(vim.api.nvim_win_set_buf, win, buf)
  -- Tag the window so a review diff / live preview never opens into the plan while
  -- it is showing. Cleared on resolve so a taken-over editor window is normal again.
  pcall(function()
    vim.w[win].claudecode_live_preview = true
  end)
  apply_marker(win)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  if config.focus ~= false then
    pcall(vim.api.nvim_set_current_win, win)
  end

  arm_clear_timer()
  logger.debug(
    "plan_view",
    "rendered plan (" .. #markdown .. " bytes) in win",
    tostring(win),
    created and "(new split)" or "(took over editor window)"
  )
end

---Tear down the plan view: close the split we created, or restore the buffer we
---displaced from a taken-over editor window. Best-effort; never throws.
local function teardown()
  stop_clear_timer()
  local win = state.plan_win
  if win and vim.api.nvim_win_is_valid(win) then
    if state.created_split then
      pcall(vim.api.nvim_win_close, win, true)
    else
      -- Drop our tag so the editor window is a normal target again.
      pcall(function()
        vim.w[win].claudecode_live_preview = nil
      end)
      -- Restore the displaced buffer, but only if the window still shows our plan
      -- (if the user navigated away to another buffer, leave their choice alone).
      local still_plan = state.plan_buf and vim.api.nvim_win_get_buf(win) == state.plan_buf
      if still_plan and state.prev_buf and vim.api.nvim_buf_is_valid(state.prev_buf) then
        pcall(vim.api.nvim_win_set_buf, win, state.prev_buf)
        if state.prev_cursor then
          pcall(vim.api.nvim_win_set_cursor, win, state.prev_cursor)
        end
      end
    end
  end
  state.plan_win = nil
  state.prev_buf = nil
  state.prev_cursor = nil
  state.created_split = nil
end

---Close the plan view when the plan is resolved (accepted or rejected): the split
---we created is closed; a taken-over editor window gets its previous buffer back.
---Idempotent and best-effort; never throws.
function M.close()
  if config and config.close_on_resolve == false then
    return
  end
  teardown()
end

---Whether a plan window is currently open (used by the dispatch router to decide
---whether an unrelated tool event should close it).
---@return boolean
function M.is_open()
  return state.plan_win ~= nil and vim.api.nvim_win_is_valid(state.plan_win)
end

--------------------------------------------------------------------------------
-- Runtime toggle (:ClaudeCodePlanView) and teardown
--------------------------------------------------------------------------------

---Toggle the plan view at runtime, or set it explicitly.
---@param arg string|nil "on" to enable; "off"/"disable" to turn off; nil to flip.
---@return boolean enabled The resulting enabled state.
function M.toggle(arg)
  config = config or {}
  if arg == "on" then
    config.enabled = true
  elseif arg == "off" or arg == "disable" then
    config.enabled = false
  else
    config.enabled = not config.enabled
  end

  if config.enabled then
    -- The hook is injected only at launch, so enabling mid-session won't affect a
    -- Claude process that's already running until it's restarted.
    vim.notify("Claude plan view enabled — restart Claude to apply to a running session", vim.log.levels.INFO)
  else
    M.close()
    vim.notify("Claude plan view disabled", vim.log.levels.INFO)
  end
  return config.enabled
end

function M.cleanup()
  -- Force teardown regardless of close_on_resolve (the plugin is shutting down).
  teardown()
  if state.plan_buf and vim.api.nvim_buf_is_valid(state.plan_buf) then
    pcall(vim.api.nvim_buf_delete, state.plan_buf, { force = true })
  end
  state.plan_buf = nil
end

-- Exposed for tests.
M._state = state
M._wrong_tab = wrong_tab

return M
