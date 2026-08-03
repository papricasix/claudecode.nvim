---@brief [[
--- Per-tab Claude activity status, published for tablines, statuslines and other
--- plugins.
---
--- With several tabs each running their own Claude, the question "which tab is
--- working and which one is waiting on me?" has no answer from the outside: the
--- CLI is a terminal process, and the MCP WebSocket only carries the editor
--- actions Claude asks for (open this file, show this diff) — nothing about the
--- conversation's own state. So we ride the same launch hook the live cursor and
--- plan view use (`claude --settings`, see `live_cursor.build_launch_injection`)
--- and derive the state from Claude Code's lifecycle hooks:
---
---   UserPromptSubmit          -> busy     (you asked, Claude started)
---   PreToolUse / PostToolUse  -> busy     (a tool is running / just finished)
---   PreToolUse(ExitPlanMode)  -> waiting  (a plan is on screen for you to accept)
---   Notification              -> waiting  (permission prompt), or idle when the
---                                         message is the "waiting for your input"
---                                         idle nudge
---   Stop                      -> done     (finished; `idle` if you were looking)
---   SessionStart / SessionEnd -> idle / none
---
--- `PostToolUse` matters more than it looks: it is what ends a permission wait
--- once you answer it, since nothing else fires between the answer and the tool's
--- result. That is also why enabling this feature widens the injected `PreToolUse`
--- matcher to every tool — the file-tool matcher the live cursor uses would leave
--- a `Bash` call reading as idle.
---
--- `done` versus `idle` is the "you have not read this yet" distinction: a turn
--- that ends while you are on some other tab (or with Neovim in the background)
--- lands in `done`, and arriving at the tab — or refocusing Neovim — clears it to
--- `idle`. A tabline can therefore shout only about answers you have not seen.
---
--- State is keyed by tabpage *handle* (what `nvim_list_tabpages()` hands you), so
--- a tabline can ask about the tab it is drawing. It is intentionally not keyed
--- by tab number like `session_state`: nothing here outlives the Neovim session,
--- so handles — which never repeat — are the safer key.
---
--- Consuming it:
---
---   local status = require("claudecode.status")
---   status.get_state(tab)   -- "busy" | "waiting" | "done" | "idle" | "none"
---   status.icon(tab)        -- the configured glyph for that state
---   status.hl_group(tab)    -- highlight group for that state (nil when "none")
---   status.all()            -- { [tabpage] = ClaudeCodeStatus }
---
--- and to redraw on change, `User ClaudeCodeStatusChanged` fires with the tab,
--- the new state and the previous one in its `data`.
---@brief ]]
---@module 'claudecode.status'

local M = {}

--- Status config subtable (see config.lua defaults / validation).
---@type table|nil
local config = nil

--- Live state: [tabpage handle] = ClaudeCodeStatus. A tab with no entry is "none".
local entries = {}

local DEFAULT_ICONS = { busy = "●", waiting = "◆", done = "●", idle = "○", none = "" }

local DEFAULT_HIGHLIGHTS = {
  busy = "ClaudeCodeStatusBusy",
  waiting = "ClaudeCodeStatusWaiting",
  done = "ClaudeCodeStatusDone",
  idle = "ClaudeCodeStatusIdle",
}

--- Sensible links for our own groups; `default = true` lets a colorscheme win.
local HIGHLIGHT_LINKS = {
  ClaudeCodeStatusBusy = "DiagnosticInfo",
  ClaudeCodeStatusWaiting = "DiagnosticWarn",
  ClaudeCodeStatusDone = "DiagnosticOk",
  ClaudeCodeStatusIdle = "Comment",
}

--- The `Notification` message Claude sends when it has simply been idle at the
--- prompt, as opposed to actually asking you something.
local IDLE_NOTIFICATION = "waiting for your input"

---Whether this terminal draws emoji-capable codepoints with the colour emoji
---font instead of the text font. `✳` (U+2733) is the one frame Unicode lists as
---emoji-capable, and Windows Terminal (PowerShell *and* WSL Neovim, hence the
---`WT_SESSION` check rather than only `win32`) paints it as a coloured, often
---double-width glyph, which both looks wrong and shifts the tabline every time
---that frame comes round.
---@return boolean
local function prefers_text_glyphs()
  local ok_win, win = pcall(vim.fn.has, "win32")
  if ok_win and win == 1 then
    return true
  end
  local env = vim.env or {}
  return (env.WT_SESSION or "") ~= "" or (env.ConEmuANSI or "") ~= ""
end

--- The Claude Code CLI's own "working" spinner, for
--- `icons = { busy = require("claudecode.status").SPINNER }`.
---
--- Taken from the CLI itself rather than approximated. It animates six glyphs
--- and then plays them **backwards** — `[...frames, ...frames.reverse()]` in its
--- own words — so the motion breathes rather than jumping from the last frame
--- back to the first; the twelve entries here are that full sequence, doubled
--- turning points included. All are single-width, so a tabline does not jitter
--- as they cycle, and the CLI advances one frame per 120ms (our `spinner_ms`
--- default). On Ghostty it swaps the last glyph for the previous one, which we
--- mirror off `$TERM` so the tabline matches the terminal it is drawn in.
local function spinner_frames()
  local base = { "·", "✢", "✳", "✶", "✻", "✽" }
  local ok, term = pcall(function()
    return vim.env and vim.env.TERM or ""
  end)
  if ok and term == "xterm-ghostty" then
    base[6] = "✻"
  end
  if prefers_text_glyphs() then
    base[3] = "✱" -- U+2731, the same asterisk shape with no emoji presentation
  end
  local frames = {}
  for i = 1, #base do
    frames[i] = base[i]
  end
  for i = #base, 1, -1 do
    frames[#frames + 1] = base[i]
  end
  return frames
end

M.SPINNER = spinner_frames()

--- Current animation frame, and the timer advancing it. The timer only runs
--- while some tab actually shows an animated icon, so an all-idle Neovim ticks
--- nothing: a repeating redraw of every tabline and statusline is not something
--- to leave running for a glyph nobody is looking at.
local frame = 1
local spinner_timer = nil

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param full_config table|nil The full plugin config (expects a `status` field).
function M.setup(full_config)
  config = (full_config and full_config.status) or {}
  for group, link in pairs(HIGHLIGHT_LINKS) do
    pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
  end
  M.ensure_visit_watcher()
end

---Watch for the user reading a finished answer: arriving at a tab clears its
---`done`, and so does coming back to Neovim, since an answer that landed while
---the editor was in the background was never actually seen.
function M.ensure_visit_watcher()
  if not M.is_enabled() then
    return
  end
  pcall(function()
    local group = vim.api.nvim_create_augroup("ClaudeCodeStatusVisit", { clear = true })
    vim.api.nvim_create_autocmd({ "TabEnter", "TabNewEntered" }, {
      group = group,
      callback = function()
        M.mark_read()
      end,
      desc = "Mark this tab's finished Claude answer as read",
    })
    vim.api.nvim_create_autocmd("FocusGained", {
      group = group,
      callback = function()
        M.set_focused(true)
        M.mark_read()
      end,
      desc = "Coming back to Neovim reads the current tab's Claude answer",
    })
    vim.api.nvim_create_autocmd("FocusLost", {
      group = group,
      callback = function()
        M.set_focused(false)
      end,
      desc = "An answer arriving while Neovim is in the background was not seen",
    })
  end)
end

---Whether status tracking is on. When off nothing is recorded and every tab
---reports "none" (the launch hook for it is not injected either).
---@return boolean
function M.is_enabled()
  return config ~= nil and config.enabled == true
end

---Test/reload helper: forget every tab's state and stop animating.
function M.reset()
  entries = {}
  if spinner_timer then
    pcall(function()
      spinner_timer:stop()
      spinner_timer:close()
    end)
    spinner_timer = nil
  end
  frame = 1
end

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

---@return number ms Monotonic milliseconds, 0 when unavailable.
local function now_ms()
  local ok, t = pcall(function()
    return vim.loop.now()
  end)
  return (ok and type(t) == "number") and t or 0
end

---Resolve a tab argument to a valid tabpage handle (nil/0 = the current tab).
---@param tab integer|nil
---@return integer|nil
local function normalize_tab(tab)
  tab = tonumber(tab)
  if not tab or tab == 0 then
    local ok, cur = pcall(vim.api.nvim_get_current_tabpage)
    if not ok then
      return nil
    end
    tab = cur
  end
  if type(tab) ~= "number" then
    return nil
  end
  local ok_valid, valid = pcall(vim.api.nvim_tabpage_is_valid, tab)
  if ok_valid and not valid then
    return nil
  end
  return tab
end

---@param tab integer
---@return integer|nil tabnr The tab's left-to-right position, if it can be read.
local function tabnr_of(tab)
  local ok, nr = pcall(vim.api.nvim_tabpage_get_number, tab)
  return (ok and type(nr) == "number") and nr or nil
end

---@param entry table
---@return ClaudeCodeStatus
local function copy(entry)
  local out = {}
  for k, v in pairs(entry) do
    out[k] = v
  end
  out.tabnr = tabnr_of(entry.tab)
  return out
end

---Refresh whatever draws the status, unless the user redraws it themselves.
local function redraw()
  if config and config.auto_redraw == false then
    return
  end
  pcall(function()
    vim.cmd("redrawtabline")
    vim.cmd("redrawstatus")
  end)
end

---The configured icon for a state: either a glyph or a list of frames.
---@param state ClaudeCodeStatusState
---@return string|string[]
local function icon_spec(state)
  local icons = (config and config.icons) or {}
  local spec = icons[state]
  if spec == nil then
    spec = DEFAULT_ICONS[state]
  end
  return spec
end

---Start or stop the animation timer to match what is on screen. Animating costs
---a repeating redraw of every tabline and statusline, so it runs only while a
---tab actually shows a multi-frame icon -- and never when the user has taken
---redrawing into their own hands (`auto_redraw = false`), where a timer we own
---could not refresh anything anyway.
local function sync_spinner()
  local want = false
  if not (config and (config.auto_redraw == false or config.spinner_ms == 0)) then
    for _, entry in pairs(entries) do
      local spec = icon_spec(entry.state)
      if type(spec) == "table" and #spec > 1 then
        want = true
        break
      end
    end
  end

  if want and not spinner_timer then
    local ok, timer = pcall(function()
      return vim.loop.new_timer()
    end)
    if not ok or not timer then
      return
    end
    spinner_timer = timer
    local interval = (config and config.spinner_ms) or 120
    pcall(function()
      timer:start(interval, interval, function()
        vim.schedule(M._tick)
      end)
    end)
  elseif not want and spinner_timer then
    pcall(function()
      spinner_timer:stop()
      spinner_timer:close()
    end)
    spinner_timer = nil
    frame = 1
  end
end

---Whether Neovim itself has focus. Terminals that report focus keep this
---honest; one that does not simply leaves it true, which degrades to "the tab
---you are on counts as seen".
local focused = true

---The state a finished turn lands in: `idle` when you were looking at that tab
---when the answer arrived, `done` when it landed somewhere you were not — the
---distinction between "Claude is done" and "Claude is done and you have not seen
---it yet", which is the whole point of a tab indicator.
---@param tab integer|nil Tabpage the answer arrived in.
---@return ClaudeCodeStatusState
local function finished_state(tab)
  local resolved = normalize_tab(tab)
  if not resolved or not focused then
    return "done"
  end
  local ok, current = pcall(vim.api.nvim_get_current_tabpage)
  if ok and current == resolved then
    return "idle"
  end
  return "done"
end

---Record whether Neovim has focus (wired to `FocusGained`/`FocusLost`).
---@param value boolean
function M.set_focused(value)
  focused = value ~= false
end

---Tell the world a tab changed, and refresh the UI that draws it.
---@param entry ClaudeCodeStatus
---@param prev ClaudeCodeStatusState
local function announce(entry, prev)
  redraw()
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "ClaudeCodeStatusChanged",
    modeline = false,
    data = {
      tab = entry.tab,
      tabnr = entry.tabnr,
      state = entry.state,
      prev = prev,
      status = entry,
    },
  })
end

---Record a tab's state, emitting `ClaudeCodeStatusChanged` when it is news.
---@param tab integer|nil
---@param state ClaudeCodeStatusState
---@param info { tool: string?, message: string?, session_id: string? }|nil
local function apply(tab, state, info)
  tab = normalize_tab(tab)
  if not tab then
    return
  end
  info = info or {}

  local prev = entries[tab]
  local prev_state = prev and prev.state or "none"
  local entry = {
    tab = tab,
    state = state,
    tool = info.tool,
    message = info.message,
    session_id = info.session_id or (prev and prev.session_id) or nil,
    -- `since` marks when this *state* was entered, so a tabline can age it
    -- ("busy for 30s"); a busy->busy tool change must not reset it.
    since = (prev_state == state and prev and prev.since) or now_ms(),
    updated_at = now_ms(),
  }

  if state == "none" then
    entries[tab] = nil
  else
    entries[tab] = entry
  end
  sync_spinner()

  local unchanged = prev_state == state
    and (prev and prev.tool) == entry.tool
    and (prev and prev.message) == entry.message
  if unchanged then
    return
  end
  entry.tabnr = tabnr_of(tab)
  announce(entry, prev_state)
end

--------------------------------------------------------------------------------
-- Ingest (driven by live_cursor.dispatch, which owns the hook transport)
--------------------------------------------------------------------------------

---Fold one Claude Code hook event into the status of the tab it came from.
---@param event table Decoded hook payload.
---@param source_tab integer|nil Tabpage the triggering Claude was launched in.
function M.note(event, source_tab)
  if not M.is_enabled() or type(event) ~= "table" then
    return
  end

  local ehn = event.hook_event_name
  local tool = type(event.tool_name) == "string" and event.tool_name or nil
  local session_id = type(event.session_id) == "string" and event.session_id or nil

  if ehn == "SessionStart" then
    apply(source_tab, "idle", { session_id = session_id })
  elseif ehn == "SessionEnd" then
    apply(source_tab, "none", {})
  elseif ehn == "UserPromptSubmit" then
    apply(source_tab, "busy", { session_id = session_id })
  elseif ehn == "PreToolUse" then
    if tool == "ExitPlanMode" then
      -- The plan is on screen and Claude cannot continue until you accept or
      -- reject it — the same "your move" state as a permission prompt.
      apply(source_tab, "waiting", { tool = tool, message = "plan review", session_id = session_id })
    else
      apply(source_tab, "busy", { tool = tool, session_id = session_id })
    end
  elseif ehn == "PostToolUse" or ehn == "PreCompact" then
    apply(source_tab, "busy", { tool = tool, session_id = session_id })
  elseif ehn == "Notification" then
    local message = type(event.message) == "string" and event.message or ""
    if message:lower():find(IDLE_NOTIFICATION, 1, true) then
      -- Not a question: the "you have been idle" nudge Claude sends at the prompt.
      apply(source_tab, finished_state(source_tab), { session_id = session_id })
    else
      apply(source_tab, "waiting", { tool = tool, message = message ~= "" and message or nil, session_id = session_id })
    end
  elseif ehn == "Stop" then
    apply(source_tab, finished_state(source_tab), { session_id = session_id })
  end
end

---Mark a tab's finished answer as read, which is what turns `done` into `idle`.
---Wired to the user arriving at the tab (`TabEnter`) or coming back to Neovim
---(`FocusGained`); `waiting` is deliberately untouched, since looking at a
---question is not answering it.
---@param tab integer|nil Defaults to the current tab.
---@return boolean marked Whether a tab actually went from `done` to `idle`.
function M.mark_read(tab)
  local resolved = normalize_tab(tab)
  local entry = resolved and entries[resolved]
  if not entry or entry.state ~= "done" then
    return false
  end
  apply(resolved, "idle", { session_id = entry.session_id })
  return true
end

---Note that a Claude terminal was launched in a tab, so it reads as present
---before its first hook event arrives. Never overrides a state we already know.
---@param tab integer|nil
function M.note_launch(tab)
  if not M.is_enabled() then
    return
  end
  local resolved = normalize_tab(tab)
  if not resolved or entries[resolved] then
    return
  end
  apply(resolved, "idle", {})
end

---Forget a tab's status (its Claude is gone).
---@param tab integer|nil
function M.clear(tab)
  local resolved = normalize_tab(tab)
  if not resolved or not entries[resolved] then
    return
  end
  apply(resolved, "none", {})
end

---Drop bookkeeping for tabs that no longer exist (wired to TabClosed).
function M.forget_closed_tabs()
  for tab in pairs(entries) do
    local ok, valid = pcall(vim.api.nvim_tabpage_is_valid, tab)
    if ok and not valid then
      entries[tab] = nil
    end
  end
  sync_spinner() -- the last busy tab may have been one of them
end

--------------------------------------------------------------------------------
-- Public API (this is what other plugins consume)
--------------------------------------------------------------------------------

---Status of a tab's Claude. Always returns a table; an unknown tab is "none".
---@param tab integer|nil Tabpage handle (nil/0 = current tab).
---@return ClaudeCodeStatus
function M.get(tab)
  local resolved = normalize_tab(tab)
  local entry = resolved and entries[resolved]
  if not entry then
    return { tab = resolved, tabnr = resolved and tabnr_of(resolved) or nil, state = "none", since = 0 }
  end
  return copy(entry)
end

---@param tab integer|nil Tabpage handle (nil/0 = current tab).
---@return ClaudeCodeStatusState
function M.get_state(tab)
  return M.get(tab).state
end

---Every tab that has a Claude, keyed by tabpage handle. Tabs with no Claude are
---absent rather than reported as "none".
---@return table<integer, ClaudeCodeStatus>
function M.all()
  local out = {}
  for tab, entry in pairs(entries) do
    local ok, valid = pcall(vim.api.nvim_tabpage_is_valid, tab)
    if not ok or valid then
      out[tab] = copy(entry)
    end
  end
  return out
end

---Glyph configured for a tab's state (`""` when there is nothing to show).
---An icon configured as a list of frames animates: the frame advances on a
---timer while any tab shows one, so this returns whichever frame is current.
---@param tab integer|nil
---@return string
function M.icon(tab)
  local spec = icon_spec(M.get_state(tab))
  if type(spec) == "table" then
    if #spec == 0 then
      return ""
    end
    return spec[((frame - 1) % #spec) + 1] or ""
  end
  return spec or ""
end

---Whether the animation timer is currently running (i.e. some tab shows an
---animated icon). Exposed for tests and for a consumer that wants to know.
---@return boolean
function M.is_spinning()
  return spinner_timer ~= nil
end

---Advance the animation one frame and refresh whatever draws it. Called by the
---timer; exposed so a test can step the animation without waiting on real time.
---@private
function M._tick()
  frame = frame + 1
  if frame > 1e6 then
    frame = 1 -- keep the counter small; the icon is picked modulo the frame count
  end
  redraw()
end

---Highlight group for a tab's state, or nil when there is nothing to draw.
---@param tab integer|nil
---@return string|nil
function M.hl_group(tab)
  local state = M.get_state(tab)
  if state == "none" then
    return nil
  end
  local groups = (config and config.highlights) or {}
  local group = groups[state]
  if group == nil then
    group = DEFAULT_HIGHLIGHTS[state]
  end
  return (type(group) == "string" and group ~= "") and group or nil
end

return M
