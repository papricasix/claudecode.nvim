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
---
--- The frame is deliberately global rather than per tab, so every view showing a
--- spinner shows the *same* one — but that also means more than one timer can be
--- driving it (the agents view runs its own, since its rows are keyed by
--- conversation, not by tab). `last_advance_ms` is what keeps the sequence at
--- one frame per interval no matter how many tickers there are; see `M._tick`.
local frame = 1
local spinner_timer = nil
local spinner_interval = nil
local last_advance_ms = nil

--- Views that need the clock running even when no tab shows an animated icon,
--- `[name] = interval_ms`. See `M.request_frames`.
local frame_requests = {}

--- Views that draw the animation somewhere a `redrawtabline` cannot reach — the
--- agents view paints its own buffers — keyed by name so re-registering
--- replaces rather than stacks. They are called on the tick that *advances* the
--- frame, whichever timer that was, so every spinner on screen changes glyph in
--- the same tick instead of on its own timer's phase.
local frame_listeners = {}

---@param name string
---@param fn fun()|nil nil unregisters.
function M.on_frame(name, fn)
  frame_listeners[name] = fn
end

local function notify_frame()
  if next(frame_listeners) == nil then
    return
  end
  -- Scheduled, not called inline: a listener repaints buffers, and doing that
  -- from inside the redraw this function follows is a good way to corrupt
  -- Neovim's state. It still lands in the same frame, just after it.
  vim.schedule(function()
    for _, fn in pairs(frame_listeners) do
      pcall(fn)
    end
  end)
end

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
  -- A reload may have turned the feature off, and the transcript watcher's clock
  -- is ours to stop; it re-arms itself the next time a tab goes busy.
  pcall(function()
    require("claudecode.interrupt_watch").sync()
  end)
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
  last_advance_ms = nil
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
  -- What the animation clock has to serve: any tab drawing a multi-frame icon,
  -- plus any view that asked for frames because it animates something a tabline
  -- redraw cannot reach (the agents view's rows are keyed by conversation, so no
  -- tab's state describes them).
  -- `status.spinner_ms` is *the* animation pace: the user set it to say how fast
  -- Claude's spinner should move, and every view showing that spinner is showing
  -- the same one.
  local base = (config and config.spinner_ms) or 120
  local want, interval = false, nil
  if not (config and (config.auto_redraw == false or config.spinner_ms == 0)) then
    for _, entry in pairs(entries) do
      local spec = icon_spec(entry.state)
      if type(spec) == "table" and #spec > 1 then
        want = true
        break
      end
    end
  end
  for _, requested in pairs(frame_requests) do
    want = true
    -- Only an *explicit* rate overrides the configured pace, and the fastest of
    -- those wins since one clock cannot serve two. A plain request (`true`) is a
    -- view saying "keep the clock running", not "run it at my speed" — taking a
    -- minimum over its default would silently overrule the user: with
    -- `status.spinner_ms = 250` and the agents view defaulted to 120, opening
    -- that tab sped the tabline up to more than twice its configured pace.
    if requested ~= true and (not interval or requested < interval) then
      interval = requested
    end
  end
  interval = interval or base

  -- A running timer at the wrong rate is restarted rather than left alone: the
  -- rate can change when a requester comes or goes.
  if want and spinner_timer and spinner_interval ~= interval then
    pcall(function()
      spinner_timer:stop()
      spinner_timer:close()
    end)
    spinner_timer = nil
  end

  if want and not spinner_timer then
    local ok, timer = pcall(function()
      return vim.loop.new_timer()
    end)
    if not ok or not timer then
      return
    end
    spinner_timer = timer
    spinner_interval = interval
    pcall(function()
      timer:start(interval, interval, function()
        vim.schedule(function()
          M._tick(interval)
        end)
      end)
    end)
  elseif not want and spinner_timer then
    pcall(function()
      spinner_timer:stop()
      spinner_timer:close()
    end)
    spinner_timer = nil
    spinner_interval = nil
    -- The frame is **not** reset. It is shared with every other view drawing a
    -- spinner, and resetting it here yanked those animations back to their first
    -- glyph every time some tab's Claude happened to finish (measured: a pane
    -- jumped ✻ → ✢ mid-cycle, which is what "random order" looks like). Nothing
    -- needs it to start at 1; the icon is picked modulo the frame count.
  end
end

---Ask for the animation clock to run even when no tab shows an animated icon.
---
---**There is exactly one clock in the process, and this is how you share it.**
---The agents view used to run a second timer over the same global frame counter,
---because its rows are keyed by conversation and `sync_spinner` only counts
---tabs. Two timers driving one counter is a race held in check only by `_tick`'s
---interval guard, and it leaked: measured, leaving the agents tab and coming
---back left the view's timer armed *in addition to* status's, doubling `_tick`
---calls (10 → 20 per 1.2s) for one animation. Both were repeating full-UI
---redraws. Asking for frames instead means the second timer never exists.
---
---Paired with `on_frame`, which is how a requester learns the frame moved.

---Who currently wants the clock, for tests and for debugging a spinner that will
---not stop.
---@return table<string, number>
function M._frame_requests()
  return vim.deepcopy(frame_requests)
end

---The rate the animation clock is actually running at, or nil when it is not.
---The pace a user configures and the pace they get have been two different
---numbers before now; this is how a test tells them apart.
---@return number|nil
function M._spinner_interval()
  return spinner_timer and spinner_interval or nil
end

---@param name string Same key as `on_frame`; re-requesting replaces.
---@param interval_ms number|nil A rate to *override* `status.spinner_ms` with.
---       Omit it — the normal case — to run at the configured pace.
function M.request_frames(name, interval_ms)
  if type(name) ~= "string" then
    return
  end
  frame_requests[name] = (type(interval_ms) == "number" and interval_ms > 0) and interval_ms or true
  sync_spinner()
end

---Withdraw a frame request, so the clock can stop when nothing else wants it.
---@param name string
function M.release_frames(name)
  if type(name) ~= "string" or frame_requests[name] == nil then
    return
  end
  frame_requests[name] = nil
  sync_spinner()
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

---Whether Neovim has focus, for the other places that decide whether an answer
---counts as seen — `agents.model` runs the same rule per conversation, and it
---must not have its own idea of this. True when nothing tracks focus, which is
---the same degradation `finished_state` accepts.
---@return boolean
function M.is_focused()
  return focused
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

  -- A cancelled turn is reported by no hook at all, so `busy` is the one state
  -- that cannot end on its own. Arm the transcript watcher on the way in — it
  -- records where the file ends, which is what makes any marker it later sees
  -- belong to *this* turn — and let it re-check whether it still has work.
  pcall(function()
    local watch = require("claudecode.interrupt_watch")
    if state == "busy" and prev_state ~= "busy" then
      watch.arm(entry.session_id)
    end
    watch.sync()
  end)

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

---Classify one Claude Code hook event into a status state.
---
---Pure: no enabled check, no tab lookup, nothing written. Kept separate from
---`note` so a consumer keyed by something other than a tabpage can reuse the
---rules — the agents view tracks several Claudes inside one tab and therefore
---keys by conversation id, where per-tab state has no single answer.
---@param event table Decoded hook payload.
---@param opts { finished: ClaudeCodeStatusState? }|nil State a finished turn lands
---       in. The caller decides, because "have you read this yet" depends on where
---       the answer arrived. Defaults to `done`.
---@return ClaudeCodeStatusState|nil state nil when the event says nothing about state.
---@return { tool: string?, message: string?, session_id: string? } info
function M.classify(event, opts)
  if type(event) ~= "table" then
    return nil, {}
  end

  local finished = (opts and opts.finished) or "done"
  local ehn = event.hook_event_name
  local tool = type(event.tool_name) == "string" and event.tool_name or nil
  local session_id = type(event.session_id) == "string" and event.session_id or nil
  local info = { tool = tool, session_id = session_id }

  if ehn == "SessionStart" then
    return "idle", { session_id = session_id }
  elseif ehn == "SessionEnd" then
    return "none", {}
  elseif ehn == "UserPromptSubmit" then
    return "busy", { session_id = session_id }
  elseif ehn == "PreToolUse" then
    if tool == "ExitPlanMode" then
      -- The plan is on screen and Claude cannot continue until you accept or
      -- reject it — the same "your move" state as a permission prompt.
      info.message = "plan review"
      return "waiting", info
    end
    return "busy", info
  elseif ehn == "PostToolUse" or ehn == "PreCompact" then
    return "busy", info
  elseif ehn == "Notification" then
    local message = type(event.message) == "string" and event.message or ""
    if message:lower():find(IDLE_NOTIFICATION, 1, true) then
      -- Not a question: the "you have been idle" nudge Claude sends at the prompt.
      return finished, { session_id = session_id }
    end
    info.message = message ~= "" and message or nil
    return "waiting", info
  elseif ehn == "Stop" then
    return finished, { session_id = session_id }
  end

  return nil, info
end

---Fold one Claude Code hook event into the status of the tab it came from.
---@param event table Decoded hook payload.
---@param source_tab integer|nil Tabpage the triggering Claude was launched in.
function M.note(event, source_tab)
  if not M.is_enabled() or type(event) ~= "table" then
    return
  end

  local state, info = M.classify(event, { finished = finished_state(source_tab) })
  if state then
    apply(source_tab, state, info)
  end
end

---Publish a state for a tab directly, bypassing the hook rules.
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

---Note that the user interrupted a running turn.
---
---**There is no hook for this.** Verified against the real CLI (2.1.221) by
---driving an interactive session through a pty with a hook registered on every
---event Claude Code defines: submitting a prompt fires `UserPromptSubmit`, and
---pressing `<Esc>` mid-turn fires **nothing at all** — not `Stop`, not the
---`StopFailure` the binary also carries. So a tab that was interrupted stayed
---`busy` for ever, and the spinner kept animating (and kept redrawing every
---tabline and statusline) until the next prompt. That is the bug this closes.
---
---What Claude Code *does* do is write `[Request interrupted by user]` into the
---conversation as a real `user` entry, so the transcript is the one place the
---cancel is reported. Two things read it and both call this:
---`claudecode.interrupt_watch`, which tails a busy tab's transcript for exactly
---this purpose, and the agents view, which folds transcripts anyway.
---Reading the keypress instead was tried and rejected: `<Esc>` means
---a dozen other things in Claude's TUI (dismissing a panel, clearing the input),
---and during a turn with no tool calls there is no later event to correct a
---wrong guess with, so a tab could read idle for minutes while Claude worked.
---Only a `busy` tab can be interrupted; anything else ignores the call.
---@param tab integer|nil
---@return boolean noted
function M.note_interrupt(tab)
  if not M.is_enabled() then
    return false
  end
  local resolved = normalize_tab(tab)
  local entry = resolved and entries[resolved]
  if not entry or entry.state ~= "busy" then
    return false
  end
  apply(resolved, "idle", { session_id = entry.session_id })
  return true
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
  pcall(function()
    require("claudecode.interrupt_watch").sync()
  end)
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
---
---`interval_ms` marks a **timer-driven** tick and is what keeps the spinner at
---its configured speed when more than one timer is running. The frame counter is
---shared on purpose — a working tab and a running agent must show the same glyph
---— so with the agents view open alongside an animated tabline, two timers were
---each advancing it and the spinner ran at double speed (measured: 19 frame
---changes per 1.2s instead of 10). A tick arriving before its interval is up
---therefore only redraws. Whichever timer crosses the deadline first advances,
---so the sequence keeps time even if one of them stops. Called with no interval
---it always advances, which is what a test stepping the animation by hand wants.
---@param interval_ms number|nil Frame interval of the calling timer.
---@private
function M._tick(interval_ms)
  if type(interval_ms) == "number" and interval_ms > 0 then
    local now = now_ms()
    -- A little early counts as on time: libuv timers fire a few ms late as often
    -- as not, and rejecting those would drop every other frame down to the
    -- *other* timer's beat.
    local due = interval_ms - math.floor(interval_ms / 8)
    if now > 0 and last_advance_ms and (now - last_advance_ms) < due then
      -- Nothing changed, so nothing is redrawn: the glyph is the same one that is
      -- already on screen. Every view repaints below instead, on the tick that
      -- actually advances, so they cannot drift apart by a timer's phase.
      return
    end
    last_advance_ms = now
  end
  frame = frame + 1
  if frame > 1e6 then
    frame = 1 -- keep the counter small; the icon is picked modulo the frame count
  end
  redraw()
  notify_frame()
end

---Highlight group configured for a state, independent of any tab.
---@param state ClaudeCodeStatusState|nil
---@return string|nil
function M.hl_group_for_state(state)
  if not state or state == "none" then
    return nil
  end
  local groups = (config and config.highlights) or {}
  local group = groups[state]
  if group == nil then
    group = DEFAULT_HIGHLIGHTS[state]
  end
  return (type(group) == "string" and group ~= "") and group or nil
end

---Highlight group for a tab's state, or nil when there is nothing to draw.
---@param tab integer|nil
---@return string|nil
function M.hl_group(tab)
  return M.hl_group_for_state(M.get_state(tab))
end

---The glyph and highlight for a state, independent of any tab.
---
---For consumers that track Claudes by something other than a tabpage — the agents
---view keys by conversation, since several share one tab — so a running agent
---animates with the same spinner, on the same frame, as a working tab.
---@param state ClaudeCodeStatusState|nil
---@return string icon
---@return string|nil hl_group
function M.icon_for_state(state)
  local spec = icon_spec(state or "none")
  local glyph
  if type(spec) == "table" then
    glyph = #spec > 0 and (spec[((frame - 1) % #spec) + 1] or "") or ""
  else
    glyph = spec or ""
  end
  return glyph, M.hl_group_for_state(state)
end

---Whether a state's icon has more than one frame, i.e. whether drawing it needs
---the animation clock at all.
---
---`sync_spinner` asks this of the tabs it knows about. A view keyed by something
---else — the agents view, whose rows are conversations — has to ask it of the
---rows it just drew, or it would hold the clock open for a pane where nothing
---moves.
---@param state ClaudeCodeStatusState|nil
---@return boolean
function M.is_animated(state)
  local spec = icon_spec(state or "none")
  return type(spec) == "table" and #spec > 1
end

return M
