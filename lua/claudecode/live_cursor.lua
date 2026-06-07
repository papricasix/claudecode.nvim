---@brief [[
--- Live Claude cursor: a real-time "ride-along" view of what Claude is doing.
---
--- Claude's own `Read`/`Edit`/`Write` tools run inside the Claude CLI and are
--- invisible to Neovim. This module taps Claude Code's hook system: at launch we
--- inject a `PreToolUse` hook (via `claude --settings <tmpfile>`, so the user's
--- own settings are never mutated) that pushes each tool event back into the
--- running Neovim over its RPC socket. We then open/preview the touched file and
--- highlight the exact line range Claude is reading or editing.
---
--- Edits are only painted when no review diff already owns the file (auto /
--- accept-edits mode) so we never duplicate what the diff view already shows.
---@brief ]]
---@module 'claudecode.live_cursor'

local M = {}

local logger = require("claudecode.logger")

--- Cached `claudecode.diff` module — reused for window discovery, filetype
--- detection, unified.nvim init, and the review-diff suppression check. `false`
--- means a load attempt already failed (don't retry every event).
local _diff
local function get_diff()
  if _diff == nil then
    local ok, mod = pcall(require, "claudecode.diff")
    _diff = ok and mod or false
  end
  return _diff or nil
end

--- Live-cursor config subtable (see config.lua defaults / validation).
---@type table|nil
local config = nil

--- Highlight namespace, created in setup().
local ns = nil

local state = {
  preview_win = nil, -- window handle reused in "preview" mode
  last_buf = nil, -- last buffer we painted into (for clearing)
  diff_buf = nil, -- scratch buffer holding the inline unified diff for edits
  clear_timer = nil, -- inactivity timer handle
  settings_files = {}, -- temp --settings files to clean up on stop
  server_addr = nil, -- resolved RPC address we handed to the hook
}

local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true }

--- Present-tense verb shown in the preview winbar for each action kind.
local ACTION_VERB = { read = "reading", write = "writing" }

---@return boolean
local function is_enabled()
  return config ~= nil and config.enabled == true and (config.mode == "preview" or config.mode == "open")
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param full_config table The full plugin config (expects a `live_cursor` field).
function M.setup(full_config)
  config = (full_config and full_config.live_cursor) or {}
  ns = vim.api.nvim_create_namespace("claudecode_live_cursor")
  -- Provide a sensible default highlight only for our own group, leaving any
  -- user-supplied group untouched. `default = true` lets a user colorscheme win.
  if (config.highlight or "ClaudeCodeLiveCursor") == "ClaudeCodeLiveCursor" then
    pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeLiveCursor", { link = "Visual", default = true })
  end
  -- Theme-fitting green for the preview marker; user can override the group.
  if (config.preview_highlight or "ClaudeCodeLivePreview") == "ClaudeCodeLivePreview" then
    pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeLivePreview", { link = "DiagnosticOk", default = true })
  end
end

--------------------------------------------------------------------------------
-- Launch injection (terminal.lua calls this when building the claude command)
--------------------------------------------------------------------------------

---Absolute path of the shipped hook script, resolved from this module's location.
---@return string
local function hook_script_path()
  local src = debug.getinfo(1, "S").source or ""
  local file = src:gsub("^@", "")
  local root = file:gsub("[/\\]lua[/\\]claudecode[/\\]live_cursor%.lua$", "")
  return root .. "/scripts/claudecode_live_cursor_hook.sh"
end

---Build the per-launch injection: extra `claude` args and env vars.
---Returns nil when the feature is disabled or no RPC address is available.
---@return { args: string, env: table<string,string> }|nil
function M.build_launch_injection()
  if not is_enabled() then
    return nil
  end

  local addr = (vim.v and vim.v.servername) or ""
  if addr == nil or addr == "" then
    local ok, started = pcall(vim.fn.serverstart)
    if ok and type(started) == "string" and started ~= "" then
      addr = started
    end
  end
  if addr == nil or addr == "" then
    logger.warn("live_cursor", "no RPC server address available; live cursor disabled for this launch")
    return nil
  end
  state.server_addr = addr

  local hook = { type = "command", command = hook_script_path(), async = true }
  local settings = {
    hooks = {
      -- Only PreToolUse: PostToolUse would clear the highlight the instant a
      -- near-instant Read finishes, so we rely on the inactivity timer instead.
      PreToolUse = { { matcher = "Read|Edit|Write|MultiEdit", hooks = { hook } } },
    },
  }

  local tmp = vim.fn.tempname()
  local ok_w = pcall(function()
    local f = assert(io.open(tmp, "w"))
    f:write(vim.json.encode(settings))
    f:close()
  end)
  if not ok_w then
    logger.error("live_cursor", "failed to write temp settings file")
    return nil
  end
  table.insert(state.settings_files, tmp)

  -- Stamp the tabpage this Claude is launching in, so its tool events only drive
  -- the preview when the user is viewing that tab (a background-tab Claude must
  -- not open previews in whatever tab the user happens to be looking at).
  local tab = 0
  local ok_tab, t = pcall(vim.api.nvim_get_current_tabpage)
  if ok_tab and type(t) == "number" then
    tab = t
  end

  return {
    args = "--settings " .. vim.fn.shellescape(tmp),
    env = { CLAUDECODE_NVIM_SERVER = addr, CLAUDECODE_NVIM_TAB = tostring(tab) },
  }
end

--------------------------------------------------------------------------------
-- Transport: the hook writes the event JSON to a tempfile and passes us its path
--------------------------------------------------------------------------------

---Entry point invoked from the hook via `nvim --server ... --remote-expr`.
---@param arg string|table Either the tempfile path, or `{ path, source_tab }`.
---@return string Empty string (remote-expr expects a return value).
function M.ingest_file(arg)
  local path, source_tab
  if type(arg) == "table" then
    path, source_tab = arg[1], tonumber(arg[2])
  else
    path = arg
  end
  if type(path) ~= "string" then
    return ""
  end
  local f = io.open(path, "r")
  local data = nil
  if f then
    data = f:read("*a")
    f:close()
  end
  pcall(os.remove, path)
  if not data or data == "" then
    return ""
  end
  local ok, event = pcall(vim.json.decode, data)
  if not ok or type(event) ~= "table" then
    return ""
  end
  vim.schedule(function()
    pcall(M.dispatch, event, source_tab)
  end)
  return ""
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

---Whether the triggering Claude lives in a different tab than the one the user is
---viewing. A background-tab Claude must not open previews in the current tab.
---@param source_tab integer|nil The tabpage the Claude was launched in (0/nil = unknown).
---@return boolean
local function wrong_tab(source_tab)
  if not source_tab or source_tab == 0 then
    return false -- unknown (e.g. single instance / old hook): don't restrict
  end
  -- The stamped tab was closed (its Claude may be an orphaned external process):
  -- never preview for it. Neovim does not reuse tabpage handles within a session,
  -- so a closed stamp can never false-match a still-open tab.
  if not vim.api.nvim_tabpage_is_valid(source_tab) then
    return true
  end
  local ok, cur = pcall(vim.api.nvim_get_current_tabpage)
  return ok and cur ~= source_tab
end

---Snippets to locate the edit by. We prefer new_string (the file is usually
---already edited by the time we look, in auto/accept mode) and fall back to
---old_string (when the buffer still shows pre-edit content).
---@param input table The tool_input from the hook event.
---@param tool string The tool name.
---@return string|nil new_text
---@return string|nil old_text
local function edit_texts(input, tool)
  if tool == "MultiEdit" and type(input.edits) == "table" and type(input.edits[1]) == "table" then
    return input.edits[1].new_string, input.edits[1].old_string
  end
  -- Edit carries new/old_string; Write has neither (whole-file) -> nil, nil.
  return input.new_string, input.old_string
end

---Route a hook event to the appropriate visual action.
---@param event table Decoded hook payload.
---@param source_tab integer|nil Tabpage the triggering Claude was launched in.
function M.dispatch(event, source_tab)
  if not is_enabled() then
    return
  end
  if event.hook_event_name ~= "PreToolUse" then
    return
  end
  local tool = event.tool_name
  local input = event.tool_input or {}
  local file = input.file_path
  if type(file) ~= "string" or file == "" then
    return
  end

  if tool == "Read" then
    if wrong_tab(source_tab) then
      logger.debug("live_cursor", "skip Read: Claude in tab", tostring(source_tab), "is not the current tab")
      return
    end
    -- offset/limit are only present when Claude reads a *slice*; a whole-file
    -- read carries no range, so we open the file but highlight its first line.
    local s = tonumber(input.offset)
    if s and s < 1 then
      s = 1
    end
    local limit = tonumber(input.limit)
    local e = (s and limit and limit > 0) and (s + limit - 1) or nil
    logger.debug("live_cursor", "Read", file, "offset=", tostring(input.offset), "limit=", tostring(input.limit))
    M.show(file, { start_line = s or 1, end_line = e, action = "read" })
  elseif EDIT_TOOLS[tool] then
    local delay = config.diff_suppress_ms or 250
    local new_text, old_text = edit_texts(input, tool)
    vim.defer_fn(function()
      -- Re-check the tab here too: the user may have switched during the delay.
      if wrong_tab(source_tab) then
        return
      end
      -- Suppress if a review diff already owns this file (it visualizes the change).
      local diff = get_diff()
      if diff and diff.is_live_for_file and diff.is_live_for_file(file) then
        logger.debug("live_cursor", tool, file, "suppressed (review diff open)")
        return
      end
      -- Prefer a real inline diff (unified.nvim); fall back to the highlight.
      if new_text and new_text ~= "" and M.show_diff(file, new_text, old_text) then
        return
      end
      if (new_text and new_text ~= "") or (old_text and old_text ~= "") then
        M.show(file, { locate = new_text, locate_fallback = old_text, action = "write" })
      else
        M.show(file, { start_line = 1, action = "write" }) -- Write / no snippet: whole-file change
      end
    end, delay)
  end
end

--------------------------------------------------------------------------------
-- Window resolution (never steals focus)
--------------------------------------------------------------------------------

---A normal editor window in the current tab (skips terminals, floats, and file
---explorers/pickers). Reuses diff.lua's canonical finder so the two never drift.
---@return integer|nil
local function find_editor_window()
  local d = get_diff()
  return d and d.find_main_editor_window() or nil
end

---Compose the winbar text: the brand label, then what Claude is doing, then the
---file it is doing it to — e.g. "● Claude live preview · reading · config.lua".
---Each piece is optional: with no `info` it degrades to just the brand label.
---@param info { action: string?, file: string? }|nil
---@return string
local function winbar_text(info)
  local parts = { config.preview_label or "● Claude live preview" }
  local verb = info and info.action and ACTION_VERB[info.action]
  if verb then
    parts[#parts + 1] = verb
  end
  if info and type(info.file) == "string" and info.file ~= "" then
    parts[#parts + 1] = vim.fn.fnamemodify(info.file, ":t")
  end
  return table.concat(parts, " · ")
end

---Mark a freshly-created preview window so the user can tell it is a live preview,
---and what Claude is currently reading/writing.
---@param win integer
---@param info { action: string?, file: string? }|nil What Claude is doing (for the winbar).
local function apply_preview_marker(win, info)
  local hl = config.preview_highlight or "ClaudeCodeLivePreview"
  local did_winbar, did_divider = false, false
  if config.preview_winbar ~= false then
    -- Escape '%' (statusline meta) in the visible text only; the highlight
    -- directive '%#group#' and the '%=' alignment items must stay literal.
    local label = winbar_text(info):gsub("%%", "%%%%")
    -- Centering uses a '%=' on each side of the text: the two alignment items
    -- split the bar into equal-width sections, pushing the label to the middle.
    local bar = (config.preview_align or "center") == "left" and ("%#" .. hl .. "#" .. label)
      or ("%#" .. hl .. "#%=" .. label .. "%=")
    did_winbar = pcall(function()
      vim.wo[win].winbar = bar
    end)
  end
  if config.preview_divider ~= false then
    did_divider = pcall(function()
      vim.wo[win].winhighlight = "WinSeparator:" .. hl
    end)
  end
  logger.debug(
    "live_cursor",
    "marker on win",
    tostring(win),
    "winbar=" .. tostring(did_winbar),
    "divider=" .. tostring(did_divider)
  )
end

---In preview mode, (re-)apply the marker on the next tick so it wins against any
---winbar plugin that sets its own on BufWinEnter (see M.show for the rationale).
---@param win integer
---@param info { action: string?, file: string? }|nil What Claude is doing (for the winbar).
local function schedule_preview_marker(win, info)
  if config.mode ~= "preview" then
    return
  end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      apply_preview_marker(win, info)
    end
  end)
end

---Scroll `win` so the change at `line` (spanning `range_len` lines) is visible,
---without moving focus. A change that fits within 'scrolloff' is centered (`zz`)
---for symmetric context; a longer one is pinned to the top with `zt`, which the
---user's 'scrolloff' already pads with that many context lines — keeping the
---change's start and any deleted lines (rendered just above it) on screen.
---@param win integer
---@param line integer 1-based
---@param range_len integer Number of lines the change/selection spans.
local function scroll_into_view(win, line, range_len)
  pcall(vim.api.nvim_win_call, win, function()
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    if (range_len or 1) > vim.o.scrolloff then
      vim.cmd("normal! zt")
    else
      vim.cmd("normal! zz")
    end
  end)
end

---Resolve the window to load the file into, per configured mode. No focus change.
---@return integer|nil
local function resolve_window()
  if config.mode == "preview" then
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
      return state.preview_win
    end
    local base = find_editor_window() or vim.api.nvim_get_current_win()
    local original = vim.api.nvim_get_current_win()
    local split_cmd = config.layout == "horizontal" and "belowright split" or "rightbelow vsplit"
    local new_win = nil
    pcall(vim.api.nvim_win_call, base, function()
      vim.cmd(split_cmd)
      new_win = vim.api.nvim_get_current_win()
    end)
    -- Restore focus: nvim_win_call restores the call's window, but a :split made
    -- inside it leaves the new window current within the callback only.
    if original and vim.api.nvim_win_is_valid(original) then
      pcall(vim.api.nvim_set_current_win, original)
    end
    if new_win and vim.api.nvim_win_is_valid(new_win) then
      state.preview_win = new_win
      -- Size the split as a fraction of the screen: height for a horizontal
      -- (below) split, width for a vertical (beside) split.
      local size = config.split_size_percentage or 0.5
      if config.layout == "horizontal" then
        pcall(vim.api.nvim_win_set_height, new_win, math.max(1, math.floor(vim.o.lines * size)))
      else
        pcall(vim.api.nvim_win_set_width, new_win, math.max(1, math.floor(vim.o.columns * size)))
      end
      return new_win
    end
    return nil
  end

  -- "open" mode: use the current window if it is a normal editor window,
  -- otherwise the main editor window.
  local cur = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(cur)
  local ok_bt, bt = pcall(vim.api.nvim_buf_get_option, buf, "buftype")
  if ok_bt and bt == "" then
    return cur
  end
  return find_editor_window()
end

--------------------------------------------------------------------------------
-- Painting
--------------------------------------------------------------------------------

---Split a snippet into lines, dropping the spurious empty final element a
---trailing newline produces.
---@param text string|nil
---@return string[]|nil
local function snippet_lines(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  if #lines == 0 then
    return nil
  end
  return lines
end

---Count the leading/trailing lines that `old` and `new` share (the unchanged
---anchor/context Claude includes in an edit). Used to trim the highlight down to
---the lines that actually changed.
---@param old string[]
---@param new string[]
---@return integer prefix
---@return integer suffix
local function common_context(old, new)
  local maxc = math.min(#old, #new)
  local prefix = 0
  while prefix < maxc and old[prefix + 1] == new[prefix + 1] do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < (maxc - prefix) and old[#old - suffix] == new[#new - suffix] do
    suffix = suffix + 1
  end
  return prefix, suffix
end

---Find a contiguous run within `lines` that exactly equals `needle`.
---Whole-line exact matching (not substring) so we land on the real edit site,
---not the first line that merely contains the snippet's first line.
---@param lines string[]
---@param needle string[]|nil
---@return integer|nil start_line 1-based
---@return integer|nil end_line 1-based
local function locate_in_array(lines, needle)
  if not needle or #needle == 0 then
    return nil
  end
  local n = #needle
  for i = 1, #lines - n + 1 do
    local matched = true
    for j = 1, n do
      if lines[i + j - 1] ~= needle[j] then
        matched = false
        break
      end
    end
    if matched then
      return i, i + n - 1
    end
  end
  return nil
end

---@param buf integer
---@param needle string[]|nil
---@return integer|nil start_line 1-based
---@return integer|nil end_line 1-based
local function locate_lines(buf, needle)
  if not needle or #needle == 0 then
    return nil
  end
  return locate_in_array(vim.api.nvim_buf_get_lines(buf, 0, -1, false), needle)
end

---Reconstruct the pre-edit file: take the post-edit `file_lines` and swap the
---new block at `[ls, le]` back to `old_snippet`.
---@param file_lines string[]
---@param ls integer
---@param le integer
---@param old_snippet string[]|nil
---@return string[]
local function reconstruct_old(file_lines, ls, le, old_snippet)
  local out = {}
  for i = 1, ls - 1 do
    out[#out + 1] = file_lines[i]
  end
  for _, l in ipairs(old_snippet or {}) do
    out[#out + 1] = l
  end
  for i = le + 1, #file_lines do
    out[#out + 1] = file_lines[i]
  end
  return out
end

---Convenience wrapper: locate a raw snippet string.
---@param buf integer
---@param text string|nil
---@return integer|nil start_line
---@return integer|nil end_line
local function locate_block(buf, text)
  return locate_lines(buf, snippet_lines(text))
end

---@return boolean available
local function unified_available()
  return (pcall(require, "unified.diff"))
end

---Lazily initialize unified.nvim, reusing diff.lua's idempotent initializer.
local function ensure_unified()
  local d = get_diff()
  if d and d.ensure_unified_initialized then
    d.ensure_unified_initialized()
  end
end

---Clear unified.nvim's inline diff extmarks from a buffer.
---@param buf integer|nil
local function clear_unified(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ok, ucfg = pcall(require, "unified.config")
  if ok and ucfg and ucfg.ns_id then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ucfg.ns_id, 0, -1)
  end
end

function M.clear()
  if state.last_buf and ns then
    pcall(vim.api.nvim_buf_clear_namespace, state.last_buf, ns, 0, -1)
  end
  clear_unified(state.diff_buf)
end

---Close the reserved preview window when Claude goes idle, unless the user is
---currently focused in it (don't yank the rug out while they're reading/editing).
local function close_idle_preview()
  if config.mode ~= "preview" then
    return
  end
  local win = state.preview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    state.preview_win = nil
    return
  end
  if vim.api.nvim_get_current_win() == win then
    return -- focused: leave it; the next idle timeout closes it after they leave
  end
  pcall(vim.api.nvim_win_close, win, true)
  state.preview_win = nil
end

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
  local delay = config.clear_delay_ms or 0
  if not delay or delay <= 0 then
    return
  end
  stop_clear_timer()
  state.clear_timer = vim.defer_fn(function()
    M.clear()
    state.clear_timer = nil
    close_idle_preview()
  end, delay)
end

---Open/preview a file and highlight a line range, without moving focus.
---@param file_path string
---@param opts { start_line: integer?, end_line: integer?, locate: string?, locate_fallback: string?, action: string? }
function M.show(file_path, opts)
  opts = opts or {}
  if not ns then
    return
  end

  local win = resolve_window()
  if not win then
    return
  end

  local buf = vim.fn.bufadd(file_path)
  if not buf or buf == 0 then
    return
  end
  pcall(vim.fn.bufload, buf)
  pcall(vim.api.nvim_win_set_buf, win, buf)

  -- Loading the file fires BufWinEnter, where a winbar plugin (dropbar, barbecue,
  -- lualine winbar, ...) may set its own winbar. Re-apply our marker on the next
  -- tick so it wins (see schedule_preview_marker).
  schedule_preview_marker(win, { action = opts.action, file = file_path })

  local s, e = opts.start_line, opts.end_line
  if opts.locate or opts.locate_fallback then
    -- The file was just written (auto/accept mode). If the buffer is an unmodified
    -- file buffer it may still hold pre-edit content; reload it from disk so the
    -- preview shows the new content and new_string can be located deterministically.
    local ok_bt, bt = pcall(function()
      return vim.bo[buf].buftype
    end)
    local ok_mod, modified = pcall(function()
      return vim.bo[buf].modified
    end)
    if ok_bt and bt == "" and ok_mod and not modified then
      pcall(vim.api.nvim_buf_call, buf, function()
        vim.cmd("silent! edit")
      end)
    end

    local new_lines = snippet_lines(opts.locate)
    local old_lines = snippet_lines(opts.locate_fallback)

    -- Prefer the post-edit text; fall back to the pre-edit text if the buffer
    -- still shows the old content. Exact-block match avoids landing on the wrong
    -- occurrence of a common line. Read the buffer once for both attempts.
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ls, le = locate_in_array(buf_lines, new_lines)
    if not ls then
      ls, le = locate_in_array(buf_lines, old_lines)
    end

    if ls then
      local raw_ls, raw_le = ls, le
      local prefix, suffix = 0, 0
      -- Trim the leading/trailing context Claude shares between old_string and
      -- new_string, so the highlight covers only the lines that changed.
      if new_lines and old_lines then
        prefix, suffix = common_context(old_lines, new_lines)
        local cs, ce = ls + prefix, le - suffix
        if cs <= ce then
          ls, le = cs, ce
        end
      end
      s, e = ls, le
      logger.debug(
        "live_cursor",
        "edit locate: new=" .. tostring(new_lines and #new_lines or 0),
        "old=" .. tostring(old_lines and #old_lines or 0),
        "block=" .. raw_ls .. "-" .. raw_le,
        "prefix=" .. prefix,
        "suffix=" .. suffix,
        "final=" .. ls .. "-" .. le
      )
    else
      logger.debug("live_cursor", "edit snippet not found; opening without a line highlight")
    end
  end

  -- Clear prior highlights from both the previous buffer and this one (the latter
  -- guards against any stale marks lingering on a re-shown buffer).
  M.clear()
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  state.last_buf = buf

  if s then
    e = e or s
    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count < 1 then
      line_count = 1
    end
    s = math.max(1, math.min(s, line_count))
    e = math.max(s, math.min(e, line_count))

    local hl = config.highlight or "ClaudeCodeLiveCursor"
    -- Re-assert the default group: if the colorscheme loaded after setup, or the
    -- group was never defined, an extmark referencing it would paint nothing.
    if hl == "ClaudeCodeLiveCursor" then
      pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeLiveCursor", { link = "Visual", default = true })
    end

    -- Highlight whole lines across the range (capped) so it is unmistakable.
    local last = math.min(e, s + 999)
    for row = s, last do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, {
        line_hl_group = hl,
        priority = 200,
      })
    end

    scroll_into_view(win, s, e - s + 1)
    logger.debug(
      "live_cursor",
      "painted",
      file_path,
      "lines",
      tostring(s) .. "-" .. tostring(e),
      "in win",
      tostring(win)
    )
  else
    logger.debug("live_cursor", "opened", file_path, "(no line range to highlight)")
  end

  arm_clear_timer()
end

---Show an inline unified diff for an edit, in the resolved preview window.
---Reconstructs the pre-edit file (post-edit content with new_string swapped back
---to old_string at its located position) and renders the real diff via
---unified.nvim. Returns false if it can't (caller falls back to the highlight).
---@param file_path string
---@param new_string string
---@param old_string string|nil
---@return boolean ok
function M.show_diff(file_path, new_string, old_string)
  if not unified_available() then
    return false
  end
  local new_lines = snippet_lines(new_string)
  if not new_lines then
    return false
  end

  -- Authoritative post-edit content straight from disk.
  local read_ok, file_lines = pcall(vim.fn.readfile, file_path)
  if not read_ok or type(file_lines) ~= "table" or #file_lines == 0 then
    return false
  end

  -- Where the new snippet sits in the post-edit file.
  local ls, le = locate_in_array(file_lines, new_lines)
  if not ls then
    return false
  end

  -- Reconstruct the pre-edit file: swap the new block back to old_string.
  local old_text = table.concat(reconstruct_old(file_lines, ls, le, snippet_lines(old_string)), "\n")

  local win = resolve_window()
  if not win then
    return false
  end

  -- Scratch buffer holding the new content (reused across edits).
  local buf = state.diff_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    if not buf or buf == 0 then
      return false
    end
    pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
    pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
    pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
    state.diff_buf = buf
  end
  clear_unified(buf)
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, file_lines)
  local d = get_diff()
  local ft = d and d.detect_filetype and d.detect_filetype(file_path, nil)
  if ft and ft ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
  end

  -- Drop any flat highlight from a previous read before switching to the diff.
  M.clear()
  state.last_buf = nil
  pcall(vim.api.nvim_win_set_buf, win, buf)

  ensure_unified()
  local unified_diff = require("unified.diff")
  local rok = pcall(unified_diff.show_against_text, buf, old_text)
  if not rok then
    return false
  end

  -- Scroll the first changed hunk into view. A short change is centered (which
  -- keeps leading deleted lines in the upper half); a long one is pinned near the
  -- top with headroom (which keeps those deleted virtual lines on screen too).
  local hunks = vim.b[buf].unified_hunks or {}
  scroll_into_view(win, math.max(1, math.min(hunks[1] or ls, vim.api.nvim_buf_line_count(buf))), le - ls + 1)

  schedule_preview_marker(win, { action = "write", file = file_path })
  arm_clear_timer()
  logger.debug("live_cursor", "edit diff for", file_path, "block", ls .. "-" .. le)
  return true
end

--------------------------------------------------------------------------------
-- Runtime toggle (:ClaudeCodeLiveCursor)
--------------------------------------------------------------------------------

---Toggle the live cursor at runtime, or set its mode explicitly.
---@param arg string|nil "preview"/"open" to enable in that mode; "off"/"disable" to turn off; nil to flip.
---@return boolean enabled The resulting enabled state.
function M.toggle(arg)
  config = config or {}

  if arg == "preview" or arg == "open" then
    config.mode = arg
    config.enabled = true
  elseif arg == "off" or arg == "disable" then
    config.enabled = false
  else
    config.enabled = not config.enabled
  end

  if config.enabled and not (config.mode == "preview" or config.mode == "open") then
    config.enabled = false
    vim.notify("Claude live cursor: set a mode first — :ClaudeCodeLiveCursor preview  (or open)", vim.log.levels.WARN)
    return false
  end

  if config.enabled then
    -- The hook is injected only at launch, so enabling mid-session won't affect a
    -- Claude process that's already running until it's restarted.
    vim.notify(
      "Claude live cursor enabled (" .. config.mode .. ") — restart Claude to apply to a running session",
      vim.log.levels.INFO
    )
  else
    M.clear()
    vim.notify("Claude live cursor disabled", vim.log.levels.INFO)
  end

  return config.enabled
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

function M.cleanup()
  for _, f in ipairs(state.settings_files) do
    pcall(os.remove, f)
  end
  state.settings_files = {}

  M.clear()
  stop_clear_timer()
  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_close, state.preview_win, true)
  end
  if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
    pcall(vim.api.nvim_buf_delete, state.diff_buf, { force = true })
  end
  state.diff_buf = nil
  state.preview_win = nil
  state.last_buf = nil
end

-- Exposed for tests.
M._state = state
M._is_enabled = is_enabled
M._close_idle_preview = close_idle_preview
M._apply_preview_marker = apply_preview_marker
M._winbar_text = winbar_text
M._locate_block = locate_block
M._common_context = common_context
M._locate_in_array = locate_in_array
M._reconstruct_old = reconstruct_old

return M
