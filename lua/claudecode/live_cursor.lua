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
local utils = require("claudecode.utils")

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

--- Arms the autocmds that notice the user taking the preview window over.
--- Forward-declared: setup() runs before the window plumbing is defined.
---@type fun()
local ensure_preview_watcher

local state = {
  preview_win = nil, -- window handle reused in "preview" mode
  preview_buf = nil, -- buffer WE last put in that window (to spot a user takeover)
  marker = nil, -- { win, winbar, winhighlight }: window options the marker overwrote
  augroup = nil, -- autocmd group watching the preview window
  last_buf = nil, -- last buffer we painted into (for clearing)
  diff_buf = nil, -- scratch buffer holding the inline unified diff for edits
  clear_timer = nil, -- inactivity timer handle
  settings_files = {}, -- temp --settings files to clean up on stop
  server_addr = nil, -- resolved RPC address we handed to the hook
  owned_bufs = {}, -- set of file buffers WE opened (for later reaping) -> true
}

local EDIT_TOOLS = { Edit = true, Write = true, MultiEdit = true }

--- Present-tense verb shown in the preview winbar for each action kind.
local ACTION_VERB = { read = "reading", write = "writing" }

---@return boolean
local function is_enabled()
  return config ~= nil and config.enabled == true and (config.mode == "preview" or config.mode == "open")
end

--- Whether the (separately toggled) plan view wants the launch hook injected.
---@return boolean
local function plan_enabled()
  local ok, pv = pcall(require, "claudecode.plan_view")
  return ok and pv.is_enabled() == true
end

--- Whether session persistence wants the launch hook injected, so the CLI reports
--- the session id it actually runs under.
---@return boolean
local function session_enabled()
  local ok, ss = pcall(require, "claudecode.session_state")
  return ok and ss.is_enabled() == true
end

--- Whether per-tab status tracking wants the launch hook injected. It needs the
--- widest set of events of any feature (see below).
---@return boolean
local function status_enabled()
  local ok, st = pcall(require, "claudecode.status")
  return ok and st.is_enabled() == true
end

--- Whether agents mode wants the hooks. It only does when its live state is
--- actually hook-driven: under polling the transcripts answer everything except
--- sub-second status, which is not worth a headless Neovim per tool call *per
--- running agent*.
---@return boolean
local function agents_enabled()
  local ok, av = pcall(require, "claudecode.agents_view")
  return ok and av.wants_hooks() == true
end

--- Whether agents mode is switched on at all, regardless of whether its live
--- state is hook-driven. It needs exactly one event under polling too: the
--- `PostToolUse(ExitPlanMode)` that dismisses the float a plan file was shown in.
--- One hook invocation per plan *answered* — the cost that makes hooks opt-in is
--- the `"*"` matcher, not this.
---@return boolean
local function agents_on_at_all()
  local ok, av = pcall(require, "claudecode.agents_view")
  return ok and av.is_enabled() == true
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---The group a "Claude read these lines" whole-line mark is painted in.
---
---Re-asserts the default for our *own* group every time rather than only at
---setup: if the colorscheme loaded afterwards, or the group was never defined,
---an extmark referencing it would paint nothing. A user-supplied group is left
---alone, and `default = true` lets a colorscheme win.
---
---Exported because the agents file view marks the same thing with the same
---meaning — hardcoding the group name there ignored `live_cursor.highlight`, so
---the two views disagreed for anyone who set it.
---@return string
function M.read_highlight()
  local hl = (config and config.highlight) or "ClaudeCodeLiveCursor"
  if hl == "ClaudeCodeLiveCursor" then
    pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeLiveCursor", { link = "Visual", default = true })
  end
  return hl
end

---@param full_config table The full plugin config (expects a `live_cursor` field).
function M.setup(full_config)
  config = (full_config and full_config.live_cursor) or {}
  ns = vim.api.nvim_create_namespace("claudecode_live_cursor")
  M.read_highlight()
  -- Theme-fitting green for the preview marker; user can override the group.
  if (config.preview_highlight or "ClaudeCodeLivePreview") == "ClaudeCodeLivePreview" then
    pcall(vim.api.nvim_set_hl, 0, "ClaudeCodeLivePreview", { link = "DiagnosticOk", default = true })
  end
  ensure_preview_watcher()
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
  return root .. "/scripts/live_cursor_hook.lua"
end

---Build the per-launch injection: extra `claude` args and env vars.
---Returns nil when the feature is disabled or no RPC address is available.
---@return { args: string, env: table<string,string> }|nil
function M.build_launch_injection()
  local lc_on = is_enabled()
  local plan_on = plan_enabled()
  local session_on = session_enabled()
  local status_on = status_enabled()
  local agents_on = agents_enabled()
  local agents_any = agents_on_at_all()
  local plan_close_on = plan_on or agents_any
  if not lc_on and not plan_on and not session_on and not status_on and not agents_on and not plan_close_on then
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

  -- The hook command is executed by Claude Code's hook runner — /bin/sh on
  -- macOS/Linux, cmd.exe on native Windows — NOT by Neovim's shell, so
  -- vim.fn.shellescape (which follows the user's 'shell' option) is the wrong
  -- quoting: an nvim configured with shell=pwsh/bash on Windows would emit
  -- POSIX single quotes that cmd.exe passes through literally, silently
  -- breaking the hook. Quote explicitly for the runner we know will be used.
  local is_windows = vim.fn.has("win32") == 1
  local function quote_for_hook_runner(path)
    if is_windows then
      return '"' .. path .. '"' -- cmd.exe: double quotes (no escape needed; " is illegal in paths)
    end
    return "'" .. path:gsub("'", "'\\''") .. "'" -- /bin/sh: single quotes
  end

  -- Use the absolute path of the running Neovim rather than relying on `nvim`
  -- being on the Claude process's PATH (it often isn't for GUI launches).
  local nvim_bin = (vim.v and vim.v.progpath) or "nvim"
  local hook_cmd = quote_for_hook_runner(nvim_bin)
    .. " --headless -u NONE -l "
    .. quote_for_hook_runner(hook_script_path())
  local hook = { type = "command", command = hook_cmd, async = true }
  -- Build the PreToolUse matcher from whichever features are enabled: live-cursor
  -- wants the file tools; the plan view wants ExitPlanMode (which carries the plan).
  local pre_tools = {}
  if lc_on then
    table.insert(pre_tools, "Read|Edit|Write|MultiEdit")
  end
  if plan_on then
    table.insert(pre_tools, "ExitPlanMode")
  end
  local settings = { hooks = {} }
  ---@param event string Claude Code hook event name.
  ---@param matcher string|nil Tool matcher, omitted for events that carry no tool.
  local function register(event, matcher)
    settings.hooks[event] = { matcher and { matcher = matcher, hooks = { hook } } or { hooks = { hook } } }
  end

  if status_on or agents_on then
    -- Status tracks *activity*, so it needs every tool call rather than the file
    -- tools above, and both sides of one: PostToolUse is the only event between
    -- answering a permission prompt and the tool's result, so without it a tab
    -- would stay "waiting" for the whole run. Agents mode wants the same set for
    -- the same reason, plus PostToolUse specifically: the transcript's record of
    -- a tool is written when the tool *returns*, so that is when its line counts
    -- are worth re-reading. This is the one feature that costs a hook invocation
    -- per tool call.
    register("PreToolUse", "*")
    register("PostToolUse", "*")
    register("UserPromptSubmit")
    -- `Notification` matches on the notification *type*, so we ask only for the
    -- ones that say something about the conversation's state and let Claude drop
    -- the rest (auth_success, elicitation_*, ...). A CLI that predates typed
    -- notification matchers ignores the matcher and sends us everything, which
    -- `status.note` still classifies correctly from the message.
    register("Notification", "permission_prompt|agent_needs_input|idle_prompt")
    register("Stop")
    register("SessionEnd")
  else
    if #pre_tools > 0 then
      -- For the file tools we use only PreToolUse: a PostToolUse would clear the
      -- highlight the instant a near-instant Read finishes, so live-cursor relies
      -- on its inactivity timer instead.
      -- Only registered when some feature actually wants tool events: an empty
      -- matcher would match *every* tool call and fire the hook for nothing.
      register("PreToolUse", table.concat(pre_tools, "|"))
    end
    if plan_close_on then
      -- PostToolUse(ExitPlanMode) is the "user accepted" signal. It closes the
      -- plan window for the plan view, and the float a plan file was shown in for
      -- agents mode. Scoped to ExitPlanMode so it never fires for the file tools
      -- above — and registered whenever either feature is on, including agents
      -- mode under polling, which asks for no other hook at all.
      register("PostToolUse", "ExitPlanMode")
    end
  end
  if session_on or status_on or agents_on or agents_any then
    -- SessionStart carries the id the CLI runs under (including after /clear or a
    -- manual --resume), which is what session persistence stores per tab.
    --
    -- Agents mode asks for it even under polling, where it is the second and last
    -- hook it wants. Everything there is keyed by conversation, and `/clear`
    -- changes which conversation a running agent is having without touching its
    -- terminal or its process — a change nothing on disk attributes to a
    -- particular agent, so no amount of polling can see it. One headless nvim per
    -- session start (a launch, a `/clear`, a resume) is a different order of cost
    -- from the `"*"` tool matcher that makes hooks opt-in.
    register("SessionStart")
  end

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
-- Transport: the hook forwards the event JSON over RPC and we decode it here
--------------------------------------------------------------------------------

---Entry point invoked from the hook over RPC (`nvim_exec_lua`). The JSON event
---passed through directly — no tempfile — so the transport is the same on platform.
---@param data string The raw tool-event JSON Claude piped to the hook.
---@param source_tab integer|string|nil Tabpage the triggering Claude was launched in.
---@param agent_id string|nil Agents-mode launch key, empty for every other launch.
---@return string Empty string (the remote call expects a return value).
function M.ingest(data, source_tab, agent_id)
  if type(data) ~= "string" or data == "" then
    return ""
  end
  local ok, event = pcall(vim.json.decode, data)
  if not ok or type(event) ~= "table" then
    return ""
  end
  local tab = tonumber(source_tab)
  local agent = (type(agent_id) == "string" and agent_id ~= "") and agent_id or nil
  vim.schedule(function()
    pcall(M.dispatch, event, tab, agent)
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

---Whether this event came from a Claude that agents mode is hosting.
---
---Agents mode owns its whole tabpage: every window in it is one of its four
---panes. A preview or a plan that takes one over is not showing the user a file,
---it is dismantling the layout the view exists to give them — and with no
---editor window to fall back on, the preview lands wherever the cursor happens
---to be, which is worse still. So these events drive the status and the agents
---model (fed before this check) and nothing that opens a window.
---@param event table
---@param source_tab integer|nil
---@return boolean
local function from_agents_mode(event, source_tab)
  local ok, agents = pcall(require, "claudecode.agents_view")
  if ok and type(agents.is_agents_tab) == "function" and agents.is_agents_tab(source_tab) then
    return true
  end
  -- The stamp is the tab the CLI was launched in; the registry knows which
  -- conversations the view runs whatever the stamp says.
  if type(event.session_id) == "string" then
    local ok_reg, registry = pcall(require, "claudecode.agents.registry")
    if ok_reg and type(registry.is_live) == "function" and registry.is_live(event.session_id) then
      return true
    end
  end
  return false
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
  -- Edit carries new/old_string; Write has neither (it carries whole-file
  -- `content` instead, handled separately) -> nil, nil.
  return input.new_string, input.old_string
end

---The file's current on-disk content, as one string. Returns "" when the file
---does not exist yet — the pre-image of a `Write` that creates it.
---@param file_path string
---@return string
local function disk_text(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return ""
  end
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  return table.concat(lines, "\n")
end

---Fallback plan-text extractor: the longest string value in a tool_input table.
---Used only if ExitPlanMode's field is ever named something other than `plan`, so
---a field-name surprise degrades to "show something" rather than showing nothing.
---@param tbl table|nil
---@return string|nil
local function longest_string(tbl)
  if type(tbl) ~= "table" then
    return nil
  end
  local best
  for _, v in pairs(tbl) do
    if type(v) == "string" and (not best or #v > #best) then
      best = v
    end
  end
  return best
end

---Route a hook event to the appropriate visual action.
---@param event table Decoded hook payload.
---@param source_tab integer|nil Tabpage the triggering Claude was launched in.
---@param agent_id string|nil Agents-mode launch key, if this Claude is one.
function M.dispatch(event, source_tab, agent_id)
  local tool = event.tool_name
  local ehn = event.hook_event_name

  -- Per-tab activity status. Fed first and from every event kind (including the
  -- ones below that return early), since it is the only consumer that cares about
  -- Stop/Notification/UserPromptSubmit.
  pcall(function()
    require("claudecode.status").note(event, source_tab)
  end)

  -- Agents mode keys by conversation rather than tab, since several agents share
  -- its tabpage; it folds the same events into per-agent state and live counts.
  -- The launch key goes with it: a conversation id names the chat and `/clear`
  -- swaps it for another one mid-terminal, so this is what says which agent the
  -- event came from once that has happened.
  pcall(function()
    require("claudecode.agents_view").note(event, source_tab, agent_id)
  end)

  -- Every hook payload names the session it came from. Recording it makes the
  -- id we persist per tab authoritative rather than the one we guessed at launch.
  if type(event.session_id) == "string" then
    pcall(function()
      require("claudecode.session_state").note_session_id(source_tab, event.session_id, event.cwd)
    end)
  end
  if ehn == "SessionStart" then
    return -- carries no tool; it exists purely for the id above
  end

  -- A plan Claude wrote to a file and showed you with `openFile` is over once you
  -- have answered the prompt in the terminal, so the float it is in gets out of
  -- the way. Scoped to that conversation *and* to floats opened for viewing: a
  -- diff float is a question still waiting for an answer, and closing one is not
  -- answering it. Runs before the guard below because a float is exactly what the
  -- agents tab does have to spare.
  if ehn == "PostToolUse" and tool == "ExitPlanMode" and type(event.session_id) == "string" then
    pcall(function()
      require("claudecode.float").close_all(event.session_id, "open")
    end)
  end

  -- Everything below opens a window. Agents mode has none to spare.
  if from_agents_mode(event, source_tab) then
    return
  end

  -- Plan view: ExitPlanMode carries the plan markdown. Routed independently of the
  -- live-cursor enabled gate, since the two features toggle separately. PreToolUse
  -- (plan ready to read) opens it; PostToolUse (user accepted) closes it.
  if tool == "ExitPlanMode" then
    local ok, pv = pcall(require, "claudecode.plan_view")
    if ok then
      if ehn == "PreToolUse" then
        local input = event.tool_input or {}
        pv.show(input.plan or longest_string(input), source_tab)
      elseif ehn == "PostToolUse" then
        pv.close()
      end
    end
    return
  end

  -- Any other tool event resolves an open plan: after acceptance Claude starts
  -- executing (Read/Edit/Write), after a reject it resumes planning — either way
  -- the plan presentation is over, so close the window. This covers the reject
  -- case, which PostToolUse may not fire for.
  if ehn == "PreToolUse" then
    local ok, pv = pcall(require, "claudecode.plan_view")
    if ok and pv.is_open() then
      pv.close()
    end
  end

  if not is_enabled() then
    return
  end
  if ehn ~= "PreToolUse" then
    return
  end
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
    -- A pending review diff already owns this file's window; a preview here would
    -- fight it for the same screen real estate (and can leave the diff's acwrite
    -- buffer in a state where accepting with :w fails). Stand down.
    local diff = get_diff()
    if diff and diff.is_live_for_file and diff.is_live_for_file(file) then
      logger.debug("live_cursor", "skip Read", file, "(review diff open)")
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
    -- `Write` hands us the whole new file up front, so we never have to find it
    -- on disk (see M.show_write). Snapshot the pre-write content *now*: the tool
    -- only runs once this hook returns, so by the time the deferred preview fires
    -- the file may already hold the new content and would diff to nothing.
    local content = (tool == "Write" and type(input.content) == "string") and input.content or nil
    local before = content and disk_text(file) or nil
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
      -- Whole-file write: render the payload's content directly.
      if content and M.show_write(file, content, before) then
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
---explorers/pickers). Prefers the window closest to the Claude terminal (matching
---the plan view) and falls back to diff.lua's canonical first-suitable finder, so
---the two never drift.
---@return integer|nil
local function find_editor_window()
  local d = get_diff()
  if not d then
    return nil
  end
  local win = d.find_window_closest_to_terminal and d.find_window_closest_to_terminal()
  if win then
    return win
  end
  return d.find_main_editor_window and d.find_main_editor_window() or nil
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

---Read a window option, or nil if the window is gone.
---@param win integer
---@param name string
---@return string|nil
local function get_winopt(win, name)
  local ok, value = pcall(function()
    return vim.wo[win][name]
  end)
  return ok and value or nil
end

---Restore a window option we overwrote, when we have a remembered value.
---@param win integer
---@param name string
---@param value string|nil
local function set_winopt(win, name, value)
  if value == nil then
    return
  end
  pcall(function()
    utils.set_win_option(win, name, value)
  end)
end

---Put the preview window's `winbar`/`winhighlight` back to what they were before
---we marked it. Keeps the remembered values, so the marker can be re-applied.
---
---This must run *before* any buffer leaves the preview window. Neovim stores
---window-local options per (window, buffer) pair and restores them when that
---buffer returns to that window: a swap made while the marker is up records it,
---and re-opening the file later resurrects the caption with no code of ours
---running. Stripping first is what keeps the recorded values clean.
---@param win integer|nil
local function strip_preview_marker(win)
  local marker = state.marker
  if not marker or not win or marker.win ~= win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  set_winopt(win, "winbar", marker.winbar)
  set_winopt(win, "winhighlight", marker.winhighlight)
end

---Mark a freshly-created preview window so the user can tell it is a live preview,
---and what Claude is currently reading/writing.
---@param win integer
---@param info { action: string?, file: string? }|nil What Claude is doing (for the winbar).
local function apply_preview_marker(win, info)
  local hl = config.preview_highlight or "ClaudeCodeLivePreview"
  local did_winbar, did_divider = false, false
  -- Remember what the window looked like before we touched it, so the marker can
  -- be undone without clobbering a winbar/winhighlight the user (or a plugin)
  -- had set. 'winhighlight' in particular is window-local only — not remembered
  -- per buffer — so blanking it on release would be a visible loss.
  if not state.marker or state.marker.win ~= win then
    state.marker = {
      win = win,
      winbar = get_winopt(win, "winbar"),
      winhighlight = get_winopt(win, "winhighlight"),
    }
  end
  if config.preview_winbar ~= false then
    -- Escape '%' (statusline meta) in the visible text only; the highlight
    -- directive '%#group#' and the '%=' alignment items must stay literal.
    local label = winbar_text(info):gsub("%%", "%%%%")
    -- Centering uses a '%=' on each side of the text: the two alignment items
    -- split the bar into equal-width sections, pushing the label to the middle.
    local bar = (config.preview_align or "center") == "left" and ("%#" .. hl .. "#" .. label)
      or ("%#" .. hl .. "#%=" .. label .. "%=")
    did_winbar = pcall(function()
      utils.set_win_option(win, "winbar", bar)
    end)
  end
  if config.preview_divider ~= false then
    did_divider = pcall(function()
      utils.set_win_option(win, "winhighlight", "WinSeparator:" .. hl)
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

---Put `buf` in the preview window, the only way we ever should.
---
---Two things have to happen around the swap. The marker comes off first, so the
---options Neovim snapshots for the *outgoing* buffer are the window's own and
---re-opening that file later doesn't bring the caption back with it (see
---strip_preview_marker). And `preview_buf` is recorded *before* the swap, since
---`nvim_win_set_buf` fires BufWinEnter synchronously — the takeover watcher runs
---inside this call and must see the new buffer as ours, not as the user's doing.
---@param win integer
---@param buf integer
local function swap_preview_buf(win, buf)
  strip_preview_marker(win)
  if win == state.preview_win then
    state.preview_buf = buf
  end
  pcall(vim.api.nvim_win_set_buf, win, buf)
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
      -- The split starts out showing the base window's buffer. Record it so the
      -- takeover watcher doesn't read the inherited buffer as the user putting
      -- their own file here, in the gap before the caller swaps ours in.
      state.preview_buf = vim.api.nvim_win_get_buf(new_win)
      -- Tag the preview window so the review diff's window discovery skips it and
      -- never opens a diff into the ride-along split (see diff.find_main_editor_window).
      pcall(function()
        vim.w[new_win].claudecode_live_preview = true
      end)
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

---Split text into lines the way `readfile()` does, since every comparison we
---make is against its output: drop the spurious empty final element a trailing
---newline produces, and drop the CR of a CRLF file. Without the latter a Windows
---file's every line differs from its on-disk form and the whole file reads as
---changed.
---@param text string
---@return string[]
local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    if line:sub(-1) == "\r" then
      lines[i] = line:sub(1, -2)
    end
  end
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---`split_lines` for an optional snippet: nil in, nil out.
---@param text string|nil
---@return string[]|nil
local function snippet_lines(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local lines = split_lines(text)
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

---Delete the file buffers the live view opened once they are no longer on screen
---and carry no unsaved changes. Only buffers WE created are tracked (see M.show —
---a file you already had open is never owned), so this reaps our own ephemeral
---previews without touching your buffers, keeping the buffer list from growing
---over a long session. A still-displayed, modified, or currently-active buffer is
---left alone and retried on a later pass (e.g. after you save or switch away).
local function reap_owned()
  for buf in pairs(state.owned_bufs) do
    if not vim.api.nvim_buf_is_valid(buf) then
      state.owned_bufs[buf] = nil
    elseif buf ~= state.last_buf and #vim.fn.win_findbuf(buf) == 0 then
      local ok_mod, modified = pcall(function()
        return vim.bo[buf].modified
      end)
      -- force=false so a buffer with unsaved changes refuses deletion (pcall
      -- swallows it) and stays owned for a later, safer pass.
      if ok_mod and not modified and pcall(vim.api.nvim_buf_delete, buf, { force = false }) then
        state.owned_bufs[buf] = nil
      end
    end
  end
end

function M.clear()
  if state.last_buf and ns then
    pcall(vim.api.nvim_buf_clear_namespace, state.last_buf, ns, 0, -1)
  end
  clear_unified(state.diff_buf)
end

---Stop treating the reserved split as our preview window: undo the marker, drop
---the tag review diffs avoid, and forget it. The next event opens a fresh one.
---
---`handover` is for when the window outlives us with a previewed file still in
---it (the user is reading there): the buffer becomes theirs — unowned so we
---never reap it out from under them, listed so it shows up in the buffer list
---like any file they opened, and stripped of our highlight.
---@param handover boolean|nil
local function release_preview_window(handover)
  local win = state.preview_win
  if win and vim.api.nvim_win_is_valid(win) then
    strip_preview_marker(win)
    pcall(function()
      vim.w[win].claudecode_live_preview = nil
    end)
    if handover then
      local buf = vim.api.nvim_win_get_buf(win)
      if state.owned_bufs[buf] then
        state.owned_bufs[buf] = nil
        pcall(function()
          vim.bo[buf].buflisted = true
        end)
      end
      if ns then
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
      end
      if state.last_buf == buf then
        state.last_buf = nil
      end
    end
  end
  state.marker = nil
  state.preview_win = nil
  state.preview_buf = nil
end

---Watch for the user taking the preview window over. Idempotent; armed from
---setup().
---
---A file picker, a `:edit`, a jump to a definition — anything that puts another
---buffer in that window means it is no longer a preview, and leaving our marker
---on it is how a plain file ends up wearing the "Claude live preview" caption
---and the green separator.
ensure_preview_watcher = function()
  if state.augroup then
    return
  end
  state.augroup = vim.api.nvim_create_augroup("ClaudeCodeLiveCursorPreview", { clear = true })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = state.augroup,
    callback = function()
      local win = state.preview_win
      if not win then
        return
      end
      if not vim.api.nvim_win_is_valid(win) then
        release_preview_window(false)
        return
      end
      local previewed = state.preview_buf
      if vim.api.nvim_win_get_buf(win) == previewed then
        return -- still showing what we put there
      end
      release_preview_window(true)
      -- The file we had been previewing just left the screen. Unpaint it and
      -- stop treating it as the active buffer so it is reaped like any other
      -- preview, instead of lingering as an unlisted stray.
      if previewed and vim.api.nvim_buf_is_valid(previewed) then
        if ns then
          pcall(vim.api.nvim_buf_clear_namespace, previewed, ns, 0, -1)
        end
        if state.last_buf == previewed then
          state.last_buf = nil
        end
      end
      -- Deleting a buffer from inside a buffer-event autocmd is refused; reap on
      -- the next tick.
      vim.schedule(reap_owned)
    end,
  })

  -- Our buffer is about to leave the preview window by someone else's doing.
  -- Strip the marker while it is still up, so the per-(window, buffer) options
  -- Neovim snapshots at that moment don't carry it (see strip_preview_marker).
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = state.augroup,
    callback = function(args)
      if state.preview_win and args.buf == state.preview_buf then
        strip_preview_marker(state.preview_win)
      end
    end,
  })
end

---Close the reserved preview window when Claude goes idle. If the user is
---focused in it we don't yank the rug out from under them — but we do stop
---calling it ours: the marker comes off (its caption is stale the moment the
---preview stops updating) and the window, with whatever it shows, is theirs.
local function close_idle_preview()
  if config.mode ~= "preview" then
    return
  end
  local win = state.preview_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    release_preview_window(false)
    return
  end
  if vim.api.nvim_get_current_win() == win then
    release_preview_window(true)
    return
  end
  release_preview_window(false)
  pcall(vim.api.nvim_win_close, win, true)
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
    -- The paint is gone, so the most recently previewed buffer is no longer the
    -- "active" one: drop it from last_buf, which reap_owned exempts. Without
    -- this the final file of every burst of activity stays behind forever —
    -- loaded, unlisted (so invisible in the buffer list), and carrying the
    -- window's remembered preview marker for the next time it is opened.
    state.last_buf = nil
    close_idle_preview()
    reap_owned()
  end, delay)
end

---Called by diff.lua the moment a review diff opens, to make the live preview
---stand down. The two features both arrange windows and would otherwise fight:
---the preview can land on or split the diff window, and its idle timer can later
---close a window the diff owns — leaving the diff's acwrite buffer in a state
---where accepting with :w fails (E676). Closing the preview here also closes the
---race where the preview opened just before the diff registered as pending (so
---the deferred is_live_for_file check missed it). Best-effort; never throws.
---@param file_path string|nil The file the diff is for (unused; we always yield).
function M.on_diff_opened(file_path) -- luacheck: ignore file_path
  M.clear()
  stop_clear_timer()
  local preview_win = state.preview_win
  release_preview_window(false)
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    pcall(vim.api.nvim_win_close, preview_win, true)
  end
  -- The previewed buffer is off-screen now; nothing keeps it "active".
  state.last_buf = nil
  reap_owned()
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

  -- Whether this file was already open before we touched it. Only buffers we
  -- create here become "owned" and eligible for reaping; a buffer you already
  -- had open is never ours to delete.
  local pre_existing = vim.fn.bufexists(file_path) == 1
  local buf = vim.fn.bufadd(file_path)
  if not buf or buf == 0 then
    return
  end
  pcall(vim.fn.bufload, buf)
  swap_preview_buf(win, buf)
  if not pre_existing then
    state.owned_bufs[buf] = true
  end

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

    local hl = M.read_highlight()

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
  -- The previously-previewed file just left the window; reap it (and any earlier
  -- stragglers) so the buffer list doesn't grow one entry per file Claude touches.
  reap_owned()
end

---Load `lines` into the reusable scratch preview buffer and show it in the
---resolved preview window, without moving focus. Returns nil when there is no
---window to preview into or the buffer could not be created.
---@param file_path string Only used to pick the filetype.
---@param lines string[]
---@return integer|nil win
---@return integer|nil buf
local function scratch_preview(file_path, lines)
  local win = resolve_window()
  if not win then
    return nil
  end

  -- Scratch buffer holding the new content (reused across edits).
  local buf = state.diff_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    if not buf or buf == 0 then
      return nil
    end
    pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
    pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
    pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
    state.diff_buf = buf
  end
  clear_unified(buf)
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local d = get_diff()
  local ft = d and d.detect_filetype and d.detect_filetype(file_path, nil)
  if ft and ft ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
  end

  -- Drop any flat highlight from a previous read before switching to the diff.
  M.clear()
  state.last_buf = nil
  swap_preview_buf(win, buf)
  return win, buf
end

---Render the inline unified diff of the scratch buffer against `old_text` and
---scroll the change into view. Returns false if unified.nvim refused it.
---@param win integer
---@param buf integer
---@param old_text string The pre-change content of the whole file.
---@param anchor integer 1-based line to scroll to if unified reports no hunks.
---@param anchor_len integer How many lines that anchor spans.
---@return boolean ok
local function apply_unified(win, buf, old_text, anchor, anchor_len)
  ensure_unified()
  local unified_diff = require("unified.diff")
  if not pcall(unified_diff.show_against_text, buf, old_text) then
    return false
  end

  -- Scroll the change into view the way the review diff does: centered when the
  -- whole change — the deleted lines unified.nvim renders as virtual lines
  -- included — fits the window, otherwise pinned with its first changed line at
  -- the top. Falls back to the flat-highlight scrolling if that isn't available.
  local hunks = vim.b[buf].unified_hunks or {}
  local row = math.max(1, math.min(hunks[1] or anchor, vim.api.nvim_buf_line_count(buf)))
  local d = get_diff()
  if d and d.center_diff_region then
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    d.center_diff_region(win, buf)
  else
    scroll_into_view(win, row, anchor_len)
  end
  return true
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

  local win, buf = scratch_preview(file_path, file_lines)
  if not win or not buf then
    return false
  end
  if not apply_unified(win, buf, old_text, ls, le - ls + 1) then
    return false
  end

  schedule_preview_marker(win, { action = "write", file = file_path })
  arm_clear_timer()
  -- The file buffer we may have previewed a moment ago is now off-screen (the
  -- scratch diff buffer took the window); reap it and any earlier stragglers.
  reap_owned()
  logger.debug("live_cursor", "edit diff for", file_path, "block", ls .. "-" .. le)
  return true
end

---Preview a whole-file `Write`.
---
---`Write` fires its PreToolUse hook *before* the tool runs, so for a file Claude
---is creating there is nothing on disk to open — previewing the path yields an
---empty buffer, and it stays empty because the write may land much later (after
---you answer the permission prompt) or never (if you reject it). The payload
---already carries the entire new file, so we render that instead: the content in
---the scratch buffer, diffed against the pre-write content (`""` for a file being
---created, so every line reads as an addition). When unified.nvim is absent we
---still show the content, just without the diff colouring.
---
---The auto-close timer is armed here, i.e. from the moment the content is on
---screen, and a later preview replaces this one as usual.
---@param file_path string
---@param content string Whole new file content, from the tool payload.
---@param before string|nil Pre-write disk content, snapshotted at dispatch time
---       (by the time we run, the write may already have landed). Read here if omitted.
---@return boolean ok
function M.show_write(file_path, content, before)
  local lines = vim.split(content or "", "\n", { plain = true })
  -- A trailing newline (nearly every file has one) leaves a spurious empty final
  -- element; the buffer's own end-of-file newline supplies it.
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end

  local win, buf = scratch_preview(file_path, lines)
  if not win or not buf then
    return false
  end

  local diffed = false
  if unified_available() then
    diffed = apply_unified(win, buf, before or disk_text(file_path), 1, #lines)
  end
  if not diffed then
    scroll_into_view(win, 1, 1) -- plain content: show it from the top
  end

  schedule_preview_marker(win, { action = "write", file = file_path })
  arm_clear_timer()
  reap_owned()
  logger.debug(
    "live_cursor",
    "write preview for",
    file_path,
    tostring(#lines) .. " lines",
    "diffed=" .. tostring(diffed)
  )
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
  local preview_win = state.preview_win
  -- Undo the marker (and forget the window) before closing it, so a window that
  -- refuses to close is at least handed back looking like the user's own.
  release_preview_window(false)
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    pcall(vim.api.nvim_win_close, preview_win, true)
  end
  if state.diff_buf and vim.api.nvim_buf_is_valid(state.diff_buf) then
    pcall(vim.api.nvim_buf_delete, state.diff_buf, { force = true })
  end
  state.diff_buf = nil
  -- Reap our ephemeral file buffers before forgetting them. last_buf is cleared
  -- first so the final previewed buffer is no longer exempt from reaping; any
  -- buffer with unsaved changes still refuses deletion and is simply forgotten.
  state.last_buf = nil
  reap_owned()
  state.owned_bufs = {}
end

-- Exposed for tests.
M._state = state
M._is_enabled = is_enabled
M._close_idle_preview = close_idle_preview
M._apply_preview_marker = apply_preview_marker
M._strip_preview_marker = strip_preview_marker
M._release_preview_window = release_preview_window
M._winbar_text = winbar_text
M._locate_block = locate_block
M._common_context = common_context
M._locate_in_array = locate_in_array
M._reconstruct_old = reconstruct_old

return M
