---@brief [[
--- Agents mode: a tabpage that runs several Claudes on one project side by side.
---
---   ┌───────────┬──────────────────────────┬───────────────┐
---   │ Changes   │  the selected agent's    │ Sessions      │
---   │ (files it │  Claude terminal         ├───────────────┤
---   │  touched) │                          │ Activity      │
---   └───────────┴──────────────────────────┴───────────────┘
---
--- The question it answers is one nothing else can: with several conversations
--- going at once, which of them is working, which one wants an answer, and what
--- has each actually changed. The MCP WebSocket carries only the editor actions
--- Claude asks for, so the answers come from the CLI's own transcript store
--- (counts, titles, activity) and its lifecycle hooks (live state).
---
--- Three things about this tab differ from a normal one, and each is deliberate:
---
--- *It owns its Claudes.* Agents run in the centre pane through
--- `agents/registry.lua`, not the terminal providers, which hold one terminal per
--- tabpage. Switching agents is a buffer swap, so the one you leave keeps working.
---
--- *Each agent has its own server.* `claudecode.start_agent_instance` gives every
--- agent its own port, token and lock file, so a diff, a file open or an @ mention
--- reaches the agent it belongs to rather than every Claude in the tab.
---
--- *Its windows are not editor windows.* All four panes carry the
--- `claudecode_live_preview` tag and the tab is marked `claudecode_agents`, so
--- review diffs, the plan view and live-cursor previews never take one over, and
--- the diff fallback that would otherwise split "whatever window is current"
--- refuses instead.
---@brief ]]
---@module 'claudecode.agents_view'

local fade = require("claudecode.agents.fade")
local logger = require("claudecode.logger")
local model = require("claudecode.agents.model")
local registry = require("claudecode.agents.registry")
local render = require("claudecode.agents.render")
local utils = require("claudecode.utils")

local M = {}

--- Agents config subtable.
---@type table|nil
local config = nil

local AUGROUP = "ClaudeCodeAgents"

local state = {
  tab = nil, ---@type integer|nil
  origin_tab = nil, ---@type integer|nil Tab the view was opened from.
  wins = {}, ---@type table<string, integer> pane -> window id
  bufs = {}, ---@type table<string, integer> pane -> buffer id
  augroup = nil, ---@type integer|nil
  -- Only the poll timer is ours. The animation clock belongs to `status`, asked
  -- for with `request_frames`; see `arm_spinner`.
  poll_timer = nil,
  --- Whether anything drawn last frame is still moving. nil = not yet decided,
  --- so the first paint of a freshly opened view never releases the clock before
  --- it has seen anything.
  animating = nil,
  --- Last pane sizes seen while the tab held nothing but the four panes. What a
  --- foreign split disturbs is restored from here rather than recomputed, so a
  --- size the user set by hand survives one.
  sizes = nil, ---@type { left: integer, right: integer, sessions: integer }|nil
  --- Set between a window closing in this tab and the sizes being put back.
  --- Without it a redraw landing in that gap would snapshot the very sizes the
  --- close disturbed — the layout is already "clean" by then, the foreign window
  --- having gone — and the restore would then faithfully restore the damage.
  sizes_locked = false,
  --- The scratch buffer the centre pane holds when it is showing something other
  --- than an agent: the "press i to start" screen, or a dead agent's notice.
  notice_buf = nil, ---@type integer|nil
  --- Which screen that buffer is currently showing: "loading" | "offer" | "empty".
  --- The buffer is reused, so the keys that belong to one screen have to be taken
  --- off again when it becomes another (see `apply_notice_keys`).
  notice_kind = nil, ---@type string|nil
  --- The conversation the centre is *offering* to start. Set by cycling onto a
  --- stopped session, cleared the moment a terminal takes the centre back.
  pending_start = nil, ---@type string|nil
  --- What each open row-float is a view of, so its own `<C-n>`/`<C-p>` can step
  --- through the pane it came from: [win] = { pane, action, lnum, aim, opening }.
  --- `aim` is where the stepping has got to, and runs ahead of `lnum` — the row
  --- actually on screen — while an open is in flight.
  float_nav = {}, ---@type table<integer, table>
  --- Set from `open` until the first session list arrives and one is offered.
  await_initial = false,
  --- The session the cursor was last put on to follow the selection. Compared
  --- against the selection on every paint so the cursor follows a selection that
  --- only becomes reachable later — a new agent has no row until its first
  --- message — without fighting the user's own cursor while it has not changed.
  cursor_selection = nil, ---@type string|nil
}

--- A record from a restored Neovim session, waiting to be claimed when the view
--- next opens: { tabnr, cwd, sessions }.
local restored = nil

--- What the view looked like when it stood down for a session write, held for
--- the `capture` that the session manager asks for afterwards (see
--- `close_for_session`). Consumed once.
local pending_capture = nil

local PANES = { "center", "sessions", "feed", "changes" }

--- How often `redraw` re-snapshots the pane sizes. The autocmds are what
--- normally catch a change; this is the backstop for a programmatic resize that
--- fires no event, so it does not need the frame clock's pace.
local SIZE_SNAPSHOT_MS = 1000

--- Rows drawn beyond what the Activity pane can show. Slack, not scrollback: the
--- pane repaints wholesale on every frame, so anything below the fold is
--- unreachable anyway.
local FEED_OVERDRAW = 5

---@return table
local function opts()
  return config or {}
end

---Name the tabpage the view lives in, if the user asked for one.
---
---Neovim has no tab names of its own, so this is a question only the tabline can
---answer. Nearly all of them read a tab-local variable and disagree about which
---(`t:name`, tabby's `tab_name`, taboo's `taboo_tab_name`), hence a name plus the
---variable it goes in; a function is handed the tabpage instead, for a tabline
---that renames through a command. Nothing here has to be undone on close: the
---tab is ours from `tabnew` and goes with the view.
---@param tab integer
local function apply_tab_name(tab)
  local name = opts().tab_name
  if not name then
    return
  end
  if type(name) == "function" then
    local ok, err = pcall(name, tab)
    if not ok then
      logger.warn("agents", "agents.tab_name failed: " .. tostring(err))
    end
    return
  end
  local var = opts().tab_name_var
  if type(var) ~= "string" or var == "" then
    var = "name"
  end
  pcall(vim.api.nvim_tabpage_set_var, tab, var, name)
end

---@return table
local function layout_opts()
  return opts().layout or {}
end

---@return table
local function keymaps()
  return opts().keymaps or {}
end

---A directory that still exists, or nil.
---
---A row records the directory its conversation *ran* in, and a rename or a move
---can have taken that directory away from under it — every transcript of a moved
---project names a path that is gone. Starting a CLI there is not a near miss but
---an outright failure (`termopen` refuses a cwd it cannot enter), so a recorded
---path is only used while it is real.
---@param path string|nil
---@return string|nil
local function usable_dir(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fn.isdirectory(vim.fn.expand(path)) == 1 and path or nil
end

--- Forward-declared: `setup` registers a frame listener that calls this, and a
--- `local function` declared further down the file would not be in scope there —
--- the reference resolves to a nil global instead, and the listener then dies
--- inside the pcall that calls it, silently. (It did. The spinner simply stopped
--- repainting.)
---@type fun(): boolean
local tab_visible

--- Declared here because `setup` and `open` both reach for it, and its body has
--- to sit below `reveal_session`. A `local function` further down would not be in
--- scope up here — the reference would silently resolve to a nil global, which is
--- the trap this file has fallen into four times now.
---@type fun(): boolean
local offer_initial_session
--- Same reason: `redraw` keeps the sessions cursor on its own row across a
--- re-sort, and the body has to sit with the rest of the row helpers.
---@type fun(session_id: string): boolean
local reveal_session
--- Same reason: `setup` registers a change listener that repaints the offer.
---@type fun()
local refresh_start_prompt
--- Same reason: that listener also has to notice a project with no conversations
--- in it, and this body belongs with the other centre-pane notices.
---@type fun(): boolean
local sync_empty_notice

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param full_config table|nil The whole plugin config.
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
  render.setup(full_config)
  model.setup(full_config)
  require("claudecode.agents.float").setup(full_config)
  model.on_change("agents_view", function()
    M.redraw()
    -- After the paint, so the sessions pane exists for the cursor to be put on
    -- the offered row; only repaint again when something actually changed.
    if offer_initial_session() then
      M.redraw()
    elseif sync_empty_notice() then
      M.redraw()
    else
      refresh_start_prompt()
    end
  end)
  -- Repaint whenever the shared animation frame advances, so the spinner in the
  -- session list and the one in the tabline are always the same glyph.
  pcall(function()
    require("claudecode.status").on_frame("agents_view", function()
      if M.is_open() and tab_visible() then
        M.redraw()
      end
    end)
  end)
end

---@return boolean
function M.is_enabled()
  return config ~= nil and config.enabled == true
end

---Whether the launch hook should be widened for this feature.
---
---Only when live state is actually driven by hooks: under `poll` the transcripts
---answer everything except sub-second status, and paying a headless Neovim per
---tool call per agent for that would be a poor trade.
---@return boolean
function M.wants_hooks()
  if not M.is_enabled() then
    return false
  end
  local source = opts().source or "auto"
  if source == "hooks" then
    return true
  end
  if source == "poll" then
    return false
  end
  -- "auto": ride the hooks that status already pays for, otherwise poll.
  local ok, status = pcall(require, "claudecode.status")
  return ok and status.is_enabled() == true
end

--------------------------------------------------------------------------------
-- Tab identity
--------------------------------------------------------------------------------

---@param tab integer|nil
---@return boolean
function M.is_agents_tab(tab)
  if not tab then
    return false
  end
  return state.tab ~= nil and state.tab == tab
end

---The tab the view was opened from — where files an agent opens should land,
---since none of the panes here is an editor window.
---@return integer|nil
function M.origin_tab()
  if state.origin_tab and vim.api.nvim_tabpage_is_valid(state.origin_tab) then
    return state.origin_tab
  end
  return nil
end

---@return boolean
function M.is_open()
  return state.tab ~= nil and vim.api.nvim_tabpage_is_valid(state.tab)
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Declared here so the layout can bind keys to a buffer it has just rebuilt; the
--- bodies live with the rest of the keymap code below.
---@type fun(buf: integer, pane: string)
local bind_keys
---@type fun(buf: integer, terminal: boolean|nil)
local map_cycle

---Paint the centre pane with the raised background snacks gives its own
---terminals, which sets the conversation apart from the panes describing it. The
---sidebars keep the editor's own `Normal`, so they read as part of the editor
---rather than as three more floating surfaces.
---
---**Re-applied on every buffer change, not once when the pane is built.** Neovim
---remembers window-local options per *(window, buffer)* pair, so the moment
---another buffer lands in the pane the window takes that pair's value — empty
---for a buffer that has never been here. Measured: `nvim_win_set_buf` on a
---window carrying `winhighlight` leaves it blank. The very first agent's
---terminal was therefore the buffer that lost the background, and every switch
---after it.
---
---Entries somebody else put there are kept: `termopen` appends
---`StatusLine:StatusLineTerm` when a buffer becomes a terminal, and dropping it
---would restyle the pane's statusline on every agent switch.
---@param win integer
local function paint_center(win)
  local ours = render.terminal_winhighlight()
  local claimed = {}
  for group in ours:gmatch("([^,:]+):") do
    claimed[group] = true
  end

  local existing = ""
  pcall(function()
    existing = vim.wo[win].winhighlight or ""
  end)
  local entries = { ours }
  for entry in existing:gmatch("[^,]+") do
    local group = entry:match("^([^:]+):")
    if group and not claimed[group] then
      entries[#entries + 1] = entry
    end
  end

  utils.set_win_option(win, "winhighlight", table.concat(entries, ","))
end

---Mark a window as belonging to the view: not an editor window, and named.
---@param win integer
---@param pane string
local function tag_window(win, pane)
  pcall(function()
    -- The existing "this is not a normal editor window" protocol, honoured by
    -- diff.find_main_editor_window and therefore by the plan view too.
    vim.w[win].claudecode_live_preview = true
    vim.w[win].claudecode_agents = pane
  end)
  if pane == "center" then
    paint_center(win)
  end

  -- The sidebars hold their size; the terminal absorbs whatever is left. Fixing
  -- the centre as well leaves Neovim no window it may take space from, and it
  -- takes it from a sidebar instead: widening Changes shrank the right column,
  -- widening that shrank Changes back, and a pane lost to a dead terminal healed
  -- into a **one-cell** Changes pane. All three were the same missing degree of
  -- freedom (measured).
  local fixed = pane ~= "center"
  local chrome = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    wrap = false,
    list = false,
    spell = false,
    cursorline = pane ~= "center",
    winfixwidth = fixed,
    winfixheight = fixed,
  }
  for name, value in pairs(chrome) do
    -- Local scope, or configuring a pane rewrites the user's own global: a pane
    -- is the current window while it is being built, and there `vim.wo` means
    -- `:set` rather than `:setlocal`. See `utils.set_win_option`.
    utils.set_win_option(win, name, value)
  end
end

---@param win integer
---@param label string
local function apply_marker(win, label)
  local group = (opts().highlights and opts().highlights.title) or "ClaudeCodeAgentsTitle"
  -- Escape '%' in the visible label; keep the '%#group#'/'%=' items literal.
  local safe = label:gsub("%%", "%%%%")
  utils.set_win_option(win, "winbar", "%#" .. group .. "#%=" .. safe .. "%=")
end

---The pane sizes the config asks for, in cells.
---
---One place, because a fresh build and a `VimResized` must agree: the defaults
---used to be spelled out at both call sites, which made a changed default dead
---code until someone remembered to edit both (it happened once already with
---`sessions_height`).
---@return integer left_width
---@return integer right_width
---@return integer sessions_height
local function pane_sizes()
  local columns = vim.o.columns
  local lines = vim.o.lines
  local layout = layout_opts()
  return math.max(12, math.floor(columns * (layout.left_width or 0.23))),
    math.max(16, math.floor(columns * (layout.right_width or 0.23))),
    -- The session list is the pane you steer from; Activity is a running
    -- commentary you glance at. So the split favours Sessions.
    math.max(3, math.floor(lines * (layout.sessions_height or 0.55)))
end

---Build the four panes in a fresh tabpage.
---@return boolean ok
local function build_layout()
  local center = vim.api.nvim_get_current_win()
  state.wins.center = center
  -- Until an agent starts, the centre holds whatever `tabnew` left there. Bind the
  -- cycling keys on it too, or they would be the one thing that does not work from
  -- the pane the cursor opens in.
  local center_buf = vim.api.nvim_win_get_buf(center)
  if center_buf and vim.api.nvim_buf_is_valid(center_buf) then
    map_cycle(center_buf, false)
  end

  -- topleft/botright rather than plain splits so the arrangement does not depend
  -- on the user's 'splitright'/'splitbelow'.
  local left_width, right_width, sessions_height = pane_sizes()

  -- A rebuild splits from a *surviving* pane, which still carries the previous
  -- layout's `winfixwidth`. Splitting a window that refuses to give up width
  -- makes Neovim take that width from somewhere else — which is how a healed
  -- layout ended up with a one-cell Changes pane. Clearing the flags first costs
  -- nothing on a fresh open, where the window has none.
  --
  -- ('equalalways' is deliberately left alone: turning it off for the
  -- construction works, but turning it back on immediately re-equalises every
  -- window, which throws away the sizes just applied. Measured.)
  utils.set_win_option(center, "winfixwidth", false)
  utils.set_win_option(center, "winfixheight", false)

  pcall(vim.cmd, "topleft " .. left_width .. "vsplit")
  state.wins.changes = vim.api.nvim_get_current_win()

  pcall(vim.api.nvim_set_current_win, center)
  pcall(vim.cmd, "botright " .. right_width .. "vsplit")
  state.wins.sessions = vim.api.nvim_get_current_win()

  pcall(vim.cmd, "belowright split")
  state.wins.feed = vim.api.nvim_get_current_win()

  for _, pane in ipairs({ "sessions", "feed", "changes" }) do
    -- Reuse the pane's buffer when there is one: a rebuild after a window was
    -- lost must not throw away what the pane already had drawn in it.
    local buf = state.bufs[pane]
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = render.create_buf(pane == "changes" and "changes" or pane)
      if not buf then
        return false
      end
      state.bufs[pane] = buf
      bind_keys(buf, pane)
    end
    pcall(vim.api.nvim_win_set_buf, state.wins[pane], buf)
  end

  for _, pane in ipairs(PANES) do
    local win = state.wins[pane]
    if win and vim.api.nvim_win_is_valid(win) then
      tag_window(win, pane)
    end
  end
  apply_marker(state.wins.sessions, "Sessions")
  apply_marker(state.wins.feed, "Activity")
  apply_marker(state.wins.changes, "Changes")

  -- Sized last, after the buffers, the tags and the winbars are in place: doing
  -- it between the splits leaves Neovim free to redistribute afterwards, and it
  -- did — Sessions asked for 27 rows of 50 and ended up with 22 (measured). The
  -- widths ride on the split counts above and hold, but are re-asserted here for
  -- the same reason.
  pcall(vim.api.nvim_win_set_width, state.wins.changes, left_width)
  pcall(vim.api.nvim_win_set_width, state.wins.sessions, right_width)
  pcall(vim.api.nvim_win_set_height, state.wins.sessions, sessions_height)
  -- The baseline a foreign split is measured against, replaced by any later
  -- deliberate resize.
  state.sizes = { left = left_width, right = right_width, sessions = sessions_height }

  pcall(vim.api.nvim_set_current_win, center)
  return true
end

---@param pane string
---@return integer|nil
local function pane_win(pane)
  local win = state.wins[pane]
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  return nil
end

---Which pane a window is, if it is one of ours.
---@param win integer|nil
---@return string|nil
local function pane_of(win)
  if not win then
    return nil
  end
  for _, pane in ipairs(PANES) do
    if state.wins[pane] == win then
      return pane
    end
  end
  return nil
end

---Which pane the cursor is in, by window rather than by buffer: a pane's window
---is what the view tracks, and the centre one shows whichever agent is selected.
---@return string|nil
local function current_pane()
  return pane_of(vim.api.nvim_get_current_win())
end

---The centre pane, rebuilding the layout first if it has been lost.
---
---Every path that shows an agent goes through here, so a view whose terminal
---window was closed heals on the next thing you ask of it rather than staying
---inert until you close and reopen it.
---@return integer|nil
local function ensure_center()
  local center = pane_win("center")
  if center then
    return center
  end
  if opts().restore_panes == false then
    return nil
  end
  if M.rebuild_layout() then
    return pane_win("center")
  end
  return nil
end

--------------------------------------------------------------------------------
-- Keymaps
--------------------------------------------------------------------------------

---@param buf integer
---@param lhs string|nil|false
---@param fn function
---@param desc string
local function map(buf, lhs, fn, desc)
  if type(lhs) ~= "string" or lhs == "" then
    return
  end
  pcall(vim.keymap.set, "n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

---Session cycling, bound everywhere in this tab — including inside the agent's
---terminal, in both normal and terminal mode, so it works without leaving insert.
---@param buf integer
---@param terminal boolean|nil Also bind in terminal mode.
function map_cycle(buf, terminal)
  local keys = keymaps()
  local modes = terminal and { "n", "t" } or { "n" }
  for delta, lhs in pairs({ [1] = keys.next_session, [-1] = keys.prev_session }) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.set, modes, lhs, function()
        M.cycle_session(delta)
      end, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = delta > 0 and "Select the next Claude session" or "Select the previous Claude session",
      })
    end
  end
end

---Bind the cycling keys on an agent's terminal buffer.
---@param bufnr integer|nil
function M.bind_terminal_keys(bufnr)
  if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) then
    map_cycle(bufnr, true)
  end
end

---Every action a pane's keys can take, in the order `?` lists them.
---
---One table drives both the binding and the help window, so what a key does and
---what the help says it does cannot drift apart — the failure mode of a help
---screen written by hand, and the reason there is no second list anywhere.
---@class ClaudeCodeAgentsKeySpec
---@field field string Which `keymaps` entry supplies the key.
---@field panes string[]|nil Panes it applies to; nil means all of them.
---@field group string Heading it appears under in the help window.
---@field desc string
---@field run fun(pane: string)
---@field bind boolean|nil `false` when something else binds it (see `map_cycle`).
---@field visual fun(pane: string)|nil Also bound in visual mode, under `visual_lhs`.

---@type ClaudeCodeAgentsKeySpec[]
local KEY_SPECS = {
  {
    field = "select",
    panes = { "sessions" },
    group = "Sessions",
    desc = "Show this session (resume it, or jump to its tab)",
    run = function()
      M.select_under_cursor()
    end,
  },
  {
    field = "new",
    panes = { "sessions" },
    group = "Sessions",
    desc = "Start a new agent",
    run = function()
      M.new_agent()
    end,
  },
  {
    field = "stop",
    panes = { "sessions" },
    group = "Sessions",
    desc = "Stop this agent, keeping the conversation",
    run = function()
      M.stop_under_cursor()
    end,
  },
  {
    field = "delete",
    panes = { "sessions" },
    group = "Sessions",
    desc = "Delete this conversation from disk — takes a count, or a visual range (asks first)",
    run = function()
      -- The count typed in front of the mapping, so `3dd` reaches three rows the
      -- way it reaches three lines anywhere else.
      M.delete_under_cursor(vim.v.count1)
    end,
    visual = function()
      M.delete_visual()
    end,
  },
  {
    field = "search",
    -- The sessions pane alone. `gf` opens a *file* in the other two, and the same
    -- key can mean two things in one view only because no pane is offered both.
    panes = { "sessions" },
    group = "Sessions",
    desc = "Search these conversations for what was said in them",
    run = function()
      M.show_search()
    end,
  },
  {
    field = "sort",
    -- Every pane you can read the list from, so re-ordering it does not first
    -- mean navigating back to it. Not the terminal: `gs` belongs to Claude there.
    panes = { "sessions", "feed", "changes" },
    group = "Sessions",
    desc = "Choose how the session list is ordered",
    run = function()
      M.show_sort_menu()
    end,
  },
  {
    field = "open",
    panes = { "feed", "changes" },
    group = "This file",
    desc = "Open it, showing what this agent did to it (a command: what it ran and printed)",
    run = function()
      M.open_under_cursor()
    end,
  },
  {
    field = "filter",
    -- The Activity pane alone: it is the only list with two kinds of row in it.
    panes = { "feed" },
    group = "Activity",
    desc = "Show everything / only files / only commands",
    run = function()
      M.cycle_feed_filter()
    end,
  },
  {
    field = "git_diff",
    panes = { "feed", "changes" },
    group = "This file",
    desc = "Diff it against git HEAD (everything uncommitted, not just this agent's work)",
    run = function()
      M.diff_head_under_cursor()
    end,
  },
  {
    field = "goto_file",
    panes = { "feed", "changes" },
    group = "This file",
    desc = "Open the file itself in a new tab, to work in",
    run = function()
      M.goto_file_under_cursor()
    end,
  },
  {
    field = "next_session",
    group = "Anywhere in the view",
    desc = "Select the next session (works in the terminal too)",
    bind = false, -- map_cycle binds it, in terminal mode as well
    run = function()
      M.cycle_session(1)
    end,
  },
  {
    field = "prev_session",
    group = "Anywhere in the view",
    desc = "Select the previous session",
    bind = false,
    run = function()
      M.cycle_session(-1)
    end,
  },
  {
    field = "next_pane",
    group = "Anywhere in the view",
    desc = "Focus the next pane",
    run = function()
      M.focus_next_pane()
    end,
  },
  {
    field = "focus_term",
    group = "Anywhere in the view",
    desc = "Focus the agent's terminal",
    run = function()
      M.focus_terminal()
    end,
  },
  {
    field = "refresh",
    group = "Anywhere in the view",
    desc = "Refresh",
    run = function()
      M.refresh()
    end,
  },
  {
    field = "help",
    group = "Anywhere in the view",
    desc = "Show these keys",
    run = function(pane)
      M.show_help(pane)
    end,
  },
  {
    field = "close",
    group = "Anywhere in the view",
    desc = "Close the view (agents keep running)",
    run = function()
      M.close()
    end,
  },
}

---@param spec ClaudeCodeAgentsKeySpec
---@param pane string
---@return boolean
local function spec_applies(spec, pane)
  if not spec.panes then
    return true
  end
  for _, name in ipairs(spec.panes) do
    if name == pane then
      return true
    end
  end
  return false
end

---What `?` shows for a pane: the keys that actually reach it, grouped.
---
---Built from the same table that binds them, and skips anything the user has
---turned off — a help window listing a key that does nothing is worse than one
---that is short.
---@param pane string
---@return { group: string, keys: { lhs: string, desc: string }[] }[]
function M.help_entries(pane)
  local keys = keymaps()
  local groups, order = {}, {}
  for _, spec in ipairs(KEY_SPECS) do
    local lhs = keys[spec.field]
    if type(lhs) == "string" and lhs ~= "" and spec_applies(spec, pane) then
      if not groups[spec.group] then
        groups[spec.group] = { group = spec.group, keys = {} }
        order[#order + 1] = groups[spec.group]
      end
      table.insert(groups[spec.group].keys, { lhs = lhs, desc = spec.desc })
    end
  end
  return order
end

---Show the help window for a pane.
---@param pane string|nil Defaults to the pane the cursor is in.
function M.show_help(pane)
  pane = pane or current_pane() or "sessions"
  local ok, help = pcall(require, "claudecode.agents.help")
  if not ok then
    return
  end
  help.open(M.help_entries(pane), pane)
end

---Show the sort menu, and apply what it picks.
---
---The list keeps whatever order it was last given, so this window is the only
---place the criterion is stated — and the only place it can change.
function M.show_sort_menu()
  local ok, menu = pcall(require, "claudecode.agents.sort_menu")
  if not ok then
    return
  end
  menu.open(model.SORTS, model.sort_mode(), function(key)
    model.set_sort(key)
    M.redraw()
  end)
end

---What a doubled normal-mode key is called in visual mode.
---
---`dd` is the linewise form of `d`, and Vim has no doubled key in visual mode:
---the range is the selection, so the second press would only extend it. So a key
---the user spelled as a repeated character is bound over a selection under its
---single form, and anything else (`<C-x>`, `gx`, a rebinding to `X`) is bound as
---it stands.
---@param lhs string
---@return string
function M._visual_lhs(lhs)
  return lhs:match("^(%a)%1$") or lhs:match("^(%p)%1$") or lhs
end

---@param buf integer
---@param pane string
function bind_keys(buf, pane)
  local keys = keymaps()

  map_cycle(buf, false)
  for _, spec in ipairs(KEY_SPECS) do
    if spec.bind ~= false and spec_applies(spec, pane) then
      local lhs = keys[spec.field]
      map(buf, lhs, function()
        spec.run(pane)
      end, "Claude agents: " .. spec.desc)
      if spec.visual and type(lhs) == "string" and lhs ~= "" then
        pcall(vim.keymap.set, "x", M._visual_lhs(lhs), function()
          spec.visual(pane)
        end, { buffer = buf, nowait = true, silent = true, desc = "Claude agents: " .. spec.desc })
      end
    end
  end
end

--------------------------------------------------------------------------------
-- The centre pane with no agent in it
--------------------------------------------------------------------------------

---The scratch buffer the centre shows when it holds no terminal.
---
---One buffer for both notices (a stopped session, an ended agent), reused rather
---than recreated: the centre is the one pane whose buffer is normally not ours,
---so a fresh one per notice would leak a buffer per keypress while cycling.
---@return integer|nil
local function notice_buf()
  local buf = state.notice_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = render.create_buf("center")
  if not buf then
    return nil
  end
  state.notice_buf = buf
  bind_keys(buf, "center")
  -- `focus_term` (`i`) already reaches here from `bind_keys`, and it starts the
  -- offered conversation before focusing — "put me in this session" is one
  -- intent whether the CLI is running or not. `<CR>` is added because that is
  -- what opens a session in the pane next door, and this screen is about one.
  map(buf, keymaps().select or "<CR>", function()
    M.focus_terminal()
  end, "Claude agents: start this session")
  return buf
end

---Keys that belong to one notice screen only.
---
---`new` is a sessions-pane key everywhere else. The empty screen is the one place
---where the centre has nothing to resume, so it carries the key it advertises —
---and gives it back when the screen becomes an offer to resume a conversation,
---since the buffer is reused and a stale mapping there would start a *second*
---conversation from a screen about a particular one.
---The key bound to an action, or nothing when the user turned it off.
---
---An unset field is the default rather than "off": `keymaps()` is the applied
---config, which always carries every key, so a missing one means the config was
---never applied — as in a test that hands the view a bare `agents` table.
---@param field string
---@param default string
---@return string|nil
local function keymap_for(field, default)
  local lhs = keymaps()[field]
  if lhs == nil then
    return default
  end
  if type(lhs) ~= "string" or lhs == "" then
    return nil
  end
  return lhs
end

---@param buf integer
---@param kind string
local function apply_notice_keys(buf, kind)
  local lhs = keymap_for("new", "a")
  if not lhs then
    return
  end
  if kind == "empty" then
    map(buf, lhs, function()
      M.new_agent()
    end, "Claude agents: start a new agent")
  else
    -- Errors when there is nothing to delete, which is the usual case: every
    -- other screen reaches here having never bound it.
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
end

---Put lines in the centre pane's notice buffer and show it.
---@param lines string[]
---@param marks { row: integer, col: integer, end_col: integer, hl: string }[]|nil
---@param kind string Which screen this is: "loading" | "offer" | "empty".
---@return boolean
local function show_notice(lines, marks, kind)
  local center = ensure_center()
  local buf = center and notice_buf()
  if not center or not buf then
    return false
  end
  apply_notice_keys(buf, kind)
  render.paint(buf, lines, marks)
  pcall(vim.api.nvim_win_set_buf, center, buf)
  -- The opening notice is shown before `arm_autocmds` runs, so the backstop is
  -- not listening yet and this is the one swap that has to paint itself.
  paint_center(center)
  state.notice_kind = kind
  return true
end

---Append `key  what it does` lines, highlighting the keys.
---@param lines string[]
---@param marks table[]
---@param hints { [1]: string, [2]: string }[]
local function append_hints(lines, marks, hints)
  lines[#lines + 1] = ""
  for _, hint in ipairs(hints) do
    local key = "  " .. hint[1]
    lines[#lines + 1] = key .. "  " .. hint[2]
    marks[#marks + 1] = { row = #lines - 1, col = 2, end_col = #key, hl = "ClaudeCodeAgentsKey" }
  end
end

---Offer to start a conversation, without starting it.
---
---Cycling deliberately does not resume: passing over a row must not spawn a CLI,
---and the whole point of the counts, the file list and the activity feed is that
---you can read what a session did before deciding to reopen it. So the centre
---says what it is holding and which key starts it.
---@param session_id string
local function show_start_prompt(session_id)
  local row = model.row(session_id)
  local title = (row and row.title) or session_id:sub(1, 8)
  local start_key = keymaps().focus_term or "i"
  local foreign_state = model.foreign_state(session_id)

  local lines = {
    "",
    "  " .. title,
    "",
  }
  local marks = {
    { row = 1, col = 0, end_col = -1, hl = (opts().highlights and opts().highlights.title) or "ClaudeCodeAgentsTitle" },
  }
  local hints
  if foreign_state then
    lines[#lines + 1] = "  This conversation is running in another tab."
    hints = { { start_key, "jump to it" } }
  else
    lines[#lines + 1] = "  This conversation is not running."
    hints = { { start_key, "start it here" } }
  end
  hints[#hints + 1] = {
    tostring(keymaps().next_session or "<C-n>") .. "/" .. tostring(keymaps().prev_session or "<C-p>"),
    "another session",
  }
  append_hints(lines, marks, hints)

  if show_notice(lines, marks, "offer") then
    state.pending_start = session_id
  end
end

---Redraw the offer as the session list fills in.
---
---Transcripts are folded asynchronously, so the first rows carry a placeholder
---title — the session id — and the real one lands moments later. Without this the
---centre would keep offering `fa57df11` for a conversation that has a name.
function refresh_start_prompt()
  local session_id = state.pending_start
  if not session_id then
    return
  end
  local center = pane_win("center")
  if not center then
    return
  end
  -- Only while the notice is what the pane is showing: a terminal took it over
  -- otherwise, and this must not pull that back out.
  local ok, buf = pcall(vim.api.nvim_win_get_buf, center)
  if not ok or buf ~= state.notice_buf then
    return
  end
  show_start_prompt(session_id)
end

---Forget the offer: something else now owns the centre pane.
local function clear_start_prompt()
  state.pending_start = nil
end

---What selecting a session does to the centre pane.
---
---A live conversation is swapped in at once, which costs nothing. A stopped one
---is **offered**, never started: selecting is how you read what a session did,
---and reading one must not spawn a CLI. `focus_term` (`i`) is what accepts.
---@param session_id string
local function show_or_offer(session_id)
  if registry.is_live(session_id) then
    local center = ensure_center()
    if center then
      clear_start_prompt()
      registry.show(session_id, center)
    end
    return
  end
  show_start_prompt(session_id)
end

---Is an agent's terminal in the centre pane?
---@return boolean
local function center_has_terminal()
  local center = pane_win("center")
  if not center then
    return false
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, center)
  if not ok or not buf then
    return false
  end
  local ok_bt, buftype = pcall(vim.api.nvim_buf_get_option, buf, "buftype")
  return ok_bt and buftype == "terminal"
end

---What the centre says before the session list has arrived.
---
---`tabnew` leaves a blank, *modifiable* buffer there, so without this `i` drops
---the user into insert mode in a scratch file — and the pane says nothing about
---what it is for.
local function show_opening_notice()
  show_notice({
    "",
    "  Reading this project's sessions…",
  }, {}, "loading")
end

---What the centre says in a project Claude has never run in.
---
---Enumeration is synchronous (`transcript.list` is stat-only), so "this project
---has no conversations" is known the moment the view opens — but the code that
---offers a session bails on an empty list and waits for one to arrive, which in
---such a project never happens. The opening notice was then simply never
---replaced, and the pane read as loading for ever. There is nothing to resume
---here, so the screen offers the one thing that does apply, and carries the key
---for it: `new` is otherwise a sessions-pane key.
---@return boolean
local function show_empty_notice()
  local lines = {
    "",
    "  No conversations in this project yet",
  }
  local marks = {
    { row = 1, col = 0, end_col = -1, hl = (opts().highlights and opts().highlights.title) or "ClaudeCodeAgentsTitle" },
  }
  local hints = {}
  local new_key, help_key = keymap_for("new", "a"), keymap_for("help", "?")
  if new_key then
    hints[#hints + 1] = { new_key, "start a new agent" }
  end
  if help_key then
    hints[#hints + 1] = { help_key, "keys" }
  end
  append_hints(lines, marks, hints)
  return show_notice(lines, marks, "empty")
end

---Show that screen whenever the project is empty and nothing else owns the centre.
---
---Also covers a project that *becomes* empty: deleting the last conversation with
---`dd` would otherwise leave the centre offering to resume one that no longer
---exists. The offer is dropped and the view goes back to awaiting a first
---session, so one that turns up later is offered as it would have been on open.
---@return boolean acted Whether the centre changed.
function sync_empty_notice()
  if not M.is_open() then
    return false
  end
  if #model.rows() > 0 then
    return false
  end
  -- An agent started here owns the centre until its first message writes the
  -- transcript that puts it in the list, so an empty list is not an empty pane.
  if center_has_terminal() then
    return false
  end
  if state.notice_kind == "empty" and pane_win("center") then
    local ok, buf = pcall(vim.api.nvim_win_get_buf, pane_win("center"))
    if ok and buf == state.notice_buf then
      return false
    end
  end
  clear_start_prompt()
  if not show_empty_notice() then
    return false
  end
  state.await_initial = true
  return true
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

---Open the agents view in a new tabpage.
---@return boolean ok
function M.open()
  if not M.is_enabled() then
    vim.notify("ClaudeCode: agents mode is disabled (agents = { enabled = true })", vim.log.levels.WARN)
    return false
  end
  if M.is_open() then
    pcall(vim.api.nvim_set_current_tabpage, state.tab)
    return true
  end

  local provider = nil
  local ok_term, terminal = pcall(require, "claudecode.terminal")
  if ok_term and terminal.defaults then
    provider = terminal.defaults.provider
  end
  if provider == "none" then
    vim.notify("ClaudeCode: agents mode needs a terminal (terminal.provider is 'none')", vim.log.levels.ERROR)
    return false
  end
  if provider == "external" then
    -- Agents live in this Neovim's windows; an external terminal has no buffer to
    -- put in the centre pane.
    vim.notify("ClaudeCode: agents mode runs its agents in Neovim, not in your external terminal", vim.log.levels.WARN)
  end

  state.origin_tab = vim.api.nvim_get_current_tabpage()
  -- A live view answers for itself; the snapshot a previous stand-down left is
  -- stale from here on.
  pending_capture = nil

  local ok_tab = pcall(vim.cmd, "tabnew")
  if not ok_tab then
    return false
  end
  state.tab = vim.api.nvim_get_current_tabpage()
  pcall(vim.api.nvim_tabpage_set_var, state.tab, "claudecode_agents", true)
  apply_tab_name(state.tab)
  -- The routing protocol, read by `diff.resolve_target_window` and by nothing
  -- that knows this feature exists. A tab that builds a fixed arrangement of
  -- windows declares three things: that an automatic split would carve it up,
  -- where a file should go instead, and which ordinary tab to fall back to. Any
  -- future view that owns a tabpage sets the same var and inherits the routing.
  pcall(vim.api.nvim_tabpage_set_var, state.tab, "claudecode_layout_owner", {
    forbids_split = true,
    host = "float",
    float_module = "claudecode.agents.float",
    origin = state.origin_tab,
  })

  if not build_layout() then
    M.close()
    return false
  end

  -- This tab's conversations are ours to track: per-tab session bookkeeping has
  -- no single answer here, and would otherwise record whichever agent last fired
  -- a hook as "the tab's" conversation.
  pcall(function()
    require("claudecode.session_state").disown_tab(state.tab)
  end)

  for pane, buf in pairs(state.bufs) do
    bind_keys(buf, pane)
  end
  state.await_initial = true
  show_opening_notice()

  -- A restored session says which project the view was showing and which agents
  -- were running in it. Claim it once: the list rebuilds itself from the
  -- transcripts either way, so all this adds is the right project and a mark on
  -- the conversations that were live.
  local cwd = vim.fn.getcwd()
  if restored then
    cwd = restored.cwd or cwd
    model.set_armed(restored.sessions)
    restored = nil
  end
  model.attach(state.tab, cwd)
  M.arm_autocmds()
  -- Both timers, not just the poll one. Arming only `arm_poll` here left the
  -- animation clock unrequested until the first `TabEnter` — so a freshly opened
  -- view did not animate at all, and leaving the tab and coming back was what
  -- started it. That asymmetry is what made a round trip look like it changed
  -- the animation's speed.
  M.sync_timers()
  M.redraw()
  -- A warm cache can have the list ready in frame one; otherwise the model's
  -- change callback picks this up when the transcripts have been folded. A
  -- project with no conversations at all is answered here and now: nothing will
  -- ever arrive for the offer to act on.
  if offer_initial_session() or sync_empty_notice() then
    M.redraw()
  end

  if opts().focus == "sessions" then
    local win = pane_win("sessions")
    if win then
      pcall(vim.api.nvim_set_current_win, win)
    end
  end

  logger.debug("agents", "agents view opened in tab", tostring(state.tab))
  return true
end

---Close the view, leaving its agents running unless told otherwise.
---@param close_opts { keep_tab: boolean? }|nil `keep_tab` takes only our own
---       windows out of the tab, for a tab that holds something of the user's too.
function M.close(close_opts)
  if not state.tab then
    return
  end
  local tab = state.tab
  local origin = M.origin_tab()
  local keep_tab = close_opts and close_opts.keep_tab or false
  --- The pane windows, collected before `forget` drops them.
  local pane_wins = {}

  -- Floats belong to the view, not the agents: they sit over this tab's layout,
  -- so they go with it even when the agents themselves keep running.
  pcall(function()
    require("claudecode.agents.float").close_every()
  end)
  pcall(function()
    require("claudecode.agents.help").close()
  end)
  -- The query outlives the picker but not the view, like the sort criterion: a
  -- later sitting starts from a blank search rather than from an old one.
  pcall(function()
    local search = require("claudecode.agents.search")
    search.close(true)
    search.reset()
  end)

  if opts().kill_on_close then
    registry.cleanup_tab(tab)
  end

  for _, buf in pairs(state.bufs) do
    render.forget(buf)
  end

  -- Untag before tearing down, so a window that survives (the user moved
  -- something into it) does not stay marked as ours forever.
  for _, pane in ipairs(PANES) do
    local win = state.wins[pane]
    if win and vim.api.nvim_win_is_valid(win) then
      pane_wins[#pane_wins + 1] = win
      pcall(function()
        vim.w[win].claudecode_live_preview = nil
        vim.w[win].claudecode_agents = nil
      end)
    end
  end

  -- The rest of the teardown is exactly what `forget` does for a tab that has
  -- already gone, and keeping two copies means a field added to `state` has to
  -- be remembered in both — miss one and it leaks on whichever path you did not
  -- edit.
  M.forget()

  if vim.api.nvim_tabpage_is_valid(tab) then
    local current = vim.api.nvim_get_current_tabpage()
    if keep_tab then
      -- Our windows only. Neovim refuses to close the last window of a tab, so
      -- the survivor — there is one whenever nothing of the user's is left to
      -- keep the tab alive — is emptied instead of closed, leaving what a bare
      -- `tabnew` would have left.
      for _, win in ipairs(pane_wins) do
        if vim.api.nvim_win_is_valid(win) then
          if #vim.api.nvim_tabpage_list_wins(tab) <= 1 then
            pcall(vim.api.nvim_win_call, win, function()
              vim.cmd("enew")
            end)
          else
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end
    elseif current == tab then
      pcall(vim.cmd, "tabclose")
    else
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  if origin and vim.api.nvim_tabpage_is_valid(origin) then
    pcall(vim.api.nvim_set_current_tabpage, origin)
  end
  logger.debug("agents", "agents view closed")
end

---@param arg string|nil "on" | "off" | nil to toggle
function M.toggle(arg)
  if arg == "on" or arg == "open" then
    M.open()
  elseif arg == "off" or arg == "close" then
    M.close()
  elseif M.is_open() then
    M.close()
  else
    M.open()
  end
end

--------------------------------------------------------------------------------
-- Autocmds and timers
--------------------------------------------------------------------------------

function M.arm_autocmds()
  state.augroup = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = state.augroup,
    callback = function()
      if state.tab and not vim.api.nvim_tabpage_is_valid(state.tab) then
        -- The tab went away under us; drop the handles without trying to close
        -- windows that no longer exist.
        M.forget()
      end
    end,
    desc = "Forget the Claude agents view when its tab closes",
  })

  vim.api.nvim_create_autocmd({ "TabEnter", "TabLeave" }, {
    group = state.augroup,
    callback = function()
      -- Nothing is drawn while the tab is off screen: the spinner drives a full
      -- UI redraw, which must not outlive the work it depicts.
      M.sync_timers()
      M.mark_selected_read()
    end,
    desc = "Pause the Claude agents view while its tab is not visible",
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = state.augroup,
    callback = function()
      -- The other half of the unread rule: an answer that arrived while Neovim
      -- was in the background is unread until the user comes back to it.
      M.mark_selected_read()
    end,
    desc = "Clear the Claude agents view's unread marker on returning to Neovim",
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = state.augroup,
    callback = function()
      M.resize()
    end,
    desc = "Keep the Claude agents panes sized to the window",
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      if not M.is_open() then
        return
      end
      local closed = tonumber(args.match)
      -- A float that has gone takes its navigation state with it: nothing else
      -- prunes `float_nav`, so closing floats with `q` leaked one table apiece
      -- for the life of the view.
      if closed then
        state.float_nav[closed] = nil
      end
      if not pane_of(closed) then
        -- Not a pane — but if it was a window *in* this tab, closing it just
        -- handed its rows or columns to whichever neighbour Neovim chose, and
        -- the panes are as likely to be that neighbour as not.
        local ok, tab = pcall(vim.api.nvim_win_get_tabpage, closed)
        if not ok or tab ~= state.tab then
          return
        end
        state.sizes_locked = true
        vim.schedule(function()
          M.restore_sizes()
        end)
        return
      end
      state.sizes_locked = true
      -- Deferred: the window is still in the tab list while WinClosed fires, so
      -- rebuilding now would count it as a survivor and split around a ghost.
      vim.schedule(function()
        M.redraw()
        M.restore_sizes()
      end)
    end,
    desc = "Put a closed Claude agents pane, and the sizes a split disturbed, back",
  })

  -- Every buffer that lands in the centre pane arrives with the `winhighlight`
  -- Neovim remembers for *that* buffer in *this* window, which for a buffer that
  -- has never been here is nothing at all. So the background is re-applied per
  -- swap rather than once when the pane was built: an agent's terminal, another
  -- agent's terminal, a notice. `TermOpen` as well, because `termopen` rewrites
  -- the option as the buffer becomes a terminal.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "TermOpen" }, {
    group = state.augroup,
    callback = function(args)
      local center = pane_win("center")
      if not center then
        return
      end
      -- `BufWinEnter` names a buffer, not a window, and the pane is often not the
      -- current one (a swap into it is made from wherever the cursor is).
      local ok, buf = pcall(vim.api.nvim_win_get_buf, center)
      if ok and buf == args.buf then
        paint_center(center)
      end
    end,
    desc = "Keep the Claude agents terminal on its own background",
  })

  -- Synchronous, and `WinEnter`/`WinLeave` rather than the more obvious `WinNew`:
  -- measured, `WinNew` fires *after* Neovim has already taken the space for the
  -- new window (sessions read 27 inside it, having been 34 the line before), so
  -- it is too late to record anything. A focus change is the last moment the
  -- layout is reliably still intact, and you must focus a window before you split
  -- from it. `WinResized` covers a drag or a `<C-w>+`, and `redraw` backstops
  -- both. `remember_sizes` refuses whenever the tab holds anything but the four
  -- panes, so none of these can record a disturbed layout.
  vim.api.nvim_create_autocmd({ "WinResized", "WinEnter", "WinLeave" }, {
    group = state.augroup,
    callback = function()
      M.remember_sizes()
    end,
    desc = "Remember deliberate Claude agents pane sizes",
  })

  if opts().follow_cursor then
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = state.augroup,
      buffer = state.bufs.sessions,
      callback = function()
        M.select_under_cursor()
      end,
      desc = "Select the Claude session under the cursor",
    })
  end
end

---@return boolean
function tab_visible()
  local ok, current = pcall(vim.api.nvim_get_current_tabpage)
  return ok and state.tab ~= nil and current == state.tab
end

function M.sync_timers()
  if not M.is_open() or not tab_visible() then
    M.stop_timers()
    return
  end
  M.arm_poll()
  M.arm_spinner()
end

---Arriving at the view is reading the conversation it is showing.
---
---`model.select` covers reaching a session with `<CR>` or `<C-n>`/`<C-p>`; this
---covers the answer that arrived while you were elsewhere, on the tab or the
---selection you had already made. The tab-level counterpart is `status`'s own
---`TabEnter`/`FocusGained` wiring, which cannot help here: its entries are keyed
---by tab, and a conversation's state is not a tab's.
---@return boolean marked
function M.mark_selected_read()
  if not M.is_open() or not tab_visible() then
    return false
  end
  local selected = model.selected()
  return selected ~= nil and model.mark_read(selected)
end

---Ask `status` to run the animation clock while this view is on screen.
---
---**This view owns no animation timer.** It used to, and that was the bug: the
---frame counter is global (deliberately — a busy tab and a busy agent must show
---the same glyph), so a second timer over it is a race, held in check only by
---`_tick`'s interval guard. It also leaked. Measured: leaving the agents tab and
---coming back left this timer armed *as well as* status's, doubling `_tick`
---calls from 10 to 20 per 1.2s — two repeating full-UI redraws for one
---animation. Requesting frames instead means there is only ever one clock, and
---`status.on_frame` (registered in `setup`) is still what repaints these panes.
function M.arm_spinner()
  -- Nil unless the user set `agents.spinner_ms`, and that is deliberate: the
  -- animation's pace is `status.spinner_ms`, one setting for one spinner. Asking
  -- at this view's own default overruled it — `status.spinner_ms = 250` with the
  -- agents default of 120 sped the tabline to more than twice the configured
  -- pace whenever this tab was active.
  local interval = opts().spinner_ms
  if opts().auto_redraw == false or interval == 0 then
    M.release_frames()
    return
  end
  -- Nothing on screen animates: the clock would drive a repeating redraw of the
  -- whole UI to paint the identical picture. `redraw` sets this from what it just
  -- drew and calls back here when the answer changes, so a fade starting or an
  -- agent going busy takes the clock again on the very next paint.
  if state.animating == false then
    M.release_frames()
    return
  end
  pcall(function()
    require("claudecode.status").request_frames("agents_view", interval)
  end)
end

---Withdraw the frame request, so the clock can stop when nothing else wants it.
function M.release_frames()
  pcall(function()
    require("claudecode.status").release_frames("agents_view")
  end)
end

function M.arm_poll()
  if state.poll_timer then
    return
  end
  -- Runs in both modes. Hooks report what a *running* agent does; they say
  -- nothing about a conversation started elsewhere, so the list still has to be
  -- re-enumerated on a timer or a new session never appears.
  local hooks = M.wants_hooks()
  local interval = opts().poll_ms or 500
  local timer = vim.loop.new_timer()
  if not timer then
    return
  end
  state.poll_timer = timer
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if not M.is_open() or not tab_visible() then
        M.stop_timers()
        return
      end
      model.poll({ list_only = hooks })
    end)
  )
end

function M.stop_timers()
  local timer = state.poll_timer
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    state.poll_timer = nil
  end
  -- The animation clock is status's, not ours; stopping means letting go of it,
  -- or it keeps running (and keeps redrawing the whole UI) for a view that is no
  -- longer on screen.
  M.release_frames()
end

function M.resize()
  if not M.is_open() then
    return
  end
  local left_width, right_width, sessions_height = pane_sizes()
  local changes = pane_win("changes")
  local sessions = pane_win("sessions")
  if changes then
    pcall(vim.api.nvim_win_set_width, changes, left_width)
  end
  if sessions then
    pcall(vim.api.nvim_win_set_width, sessions, right_width)
    pcall(vim.api.nvim_win_set_height, sessions, sessions_height)
  end
  M.remember_sizes()
end

---Whether the tab holds the four panes and nothing else.
---
---Floats do not count: they overlay the layout rather than taking space from it,
---and a diff float open must not stop the sizes being tracked.
---@return boolean
local function layout_clean()
  if not M.is_open() then
    return false
  end
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, state.tab)
  if not ok then
    return false
  end
  local count = 0
  for _, win in ipairs(wins) do
    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
    local floating = ok_cfg and type(cfg) == "table" and cfg.relative ~= nil and cfg.relative ~= ""
    if not floating then
      count = count + 1
      if not pane_of(win) then
        return false
      end
    end
  end
  return count == #PANES
end

---Record the pane sizes, if they are currently worth recording.
---
---Only while the tab is undisturbed: measuring during a foreign split would
---save the very sizes that split imposed, which is what we exist to undo.
function M.remember_sizes()
  if state.sizes_locked or not layout_clean() then
    return
  end
  local changes, sessions = pane_win("changes"), pane_win("sessions")
  if not changes or not sessions then
    return
  end
  local ok, sizes = pcall(function()
    return {
      left = vim.api.nvim_win_get_width(changes),
      right = vim.api.nvim_win_get_width(sessions),
      sessions = vim.api.nvim_win_get_height(sessions),
    }
  end)
  if ok and sizes.left > 1 and sizes.right > 1 and sizes.sessions > 1 then
    state.sizes = sizes
  end
end

---Put the pane sizes back after something else in the tab took space.
---
---A split opened in this tab has to come from somewhere, and `winfixheight` does
---not stop Neovim taking the rows when there is no unfixed window in the column
---to take them from. Closing it hands the freed space to whichever neighbour
---Neovim picks — reported as Activity growing at Sessions' expense every time a
---split was opened and closed — and nothing put it back, because sizes were only
---ever asserted at build and on `VimResized`.
---
---Restoring the snapshot rather than recomputing from the config fractions is
---deliberate: a size the user dragged is as much theirs as the default is ours.
function M.restore_sizes()
  if not M.is_open() or not layout_clean() then
    -- Still disturbed, or gone. Leave the lock on; the next close unlocks it.
    return
  end
  local sizes = state.sizes
  if not sizes then
    state.sizes_locked = false
    M.resize()
    return
  end
  local changes, sessions = pane_win("changes"), pane_win("sessions")
  if changes then
    pcall(vim.api.nvim_win_set_width, changes, sizes.left)
  end
  if sessions then
    pcall(vim.api.nvim_win_set_width, sessions, sizes.right)
    pcall(vim.api.nvim_win_set_height, sessions, sizes.sessions)
  end
  state.sizes_locked = false
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

---Whether every pane is still on screen.
---@return boolean
local function layout_intact()
  for _, pane in ipairs(PANES) do
    if not pane_win(pane) then
      return false
    end
  end
  return true
end

---Put the layout back after a pane was lost.
---
---Losing the centre pane is the case that matters: when an agent's process ends,
---Neovim closes the dead terminal buffer on the next keypress and takes the
---window with it, and without the centre there is nowhere to show an agent — the
---view is open but unusable. Rebuilding wholesale rather than re-splitting the
---one gap keeps a single description of what the layout is.
---@return boolean rebuilt
function M.rebuild_layout()
  if not M.is_open() then
    return false
  end
  -- Splitting has to happen in the tab itself, so only rebuild while the user is
  -- looking at it; otherwise wait for them to come back (TabEnter redraws).
  local ok_tab, current = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tab or current ~= state.tab then
    return false
  end

  local selected = model.selected()
  local wins = vim.api.nvim_tabpage_list_wins(state.tab)
  -- Keep one window to split from; anything else in the tab is a leftover pane.
  for index = 2, #wins do
    pcall(vim.api.nvim_win_close, wins[index], true)
  end
  local base = wins[1]
  if not base or not vim.api.nvim_win_is_valid(base) then
    return false
  end
  pcall(vim.api.nvim_set_current_win, base)
  -- The surviving window may still hold a dead terminal; the centre is rebuilt
  -- around it, so give it a clean buffer first.
  pcall(vim.api.nvim_win_set_buf, base, vim.api.nvim_create_buf(false, true))

  state.wins = {}
  if not build_layout() then
    return false
  end

  -- Put the selected agent back on screen if it is still running.
  local center = pane_win("center")
  if center and selected and registry.is_live(selected) then
    registry.show(selected, center)
  end
  logger.debug("agents", "rebuilt the agents layout after a pane was lost")
  return true
end

---Rebuild any pane the user closed, so a stray `:q` — or an agent's terminal
---taking its window down with it — degrades to a blink rather than a dead view.
local function restore_panes()
  if opts().restore_panes == false or not M.is_open() then
    return
  end
  if not layout_intact() then
    M.rebuild_layout()
  end
end

---Whether anything just drawn will look different on the next frame.
---
---Two things move in these panes: an animated status icon (the CLI's spinner on
---a working agent) and a fade still walking down its ramp. Nothing else does, so
---when neither is present the clock is holding a repeating full-UI redraw open
---to paint the identical picture — which on an idle project is all of the time.
---
---Computed from the rows that were *actually drawn* rather than by asking the
---model again: the answer is a by-product of a paint we have already done, and
---asking separately would double the work on every frame that does animate.
---@param rows table[] Session rows, as handed to the renderer.
---@param ages number[] How long each Activity row has been on screen.
---@return boolean
local function anything_moving(rows, ages)
  local ok_status, status = pcall(require, "claudecode.status")
  for _, row in ipairs(rows) do
    if ok_status and status.is_animated and status.is_animated(row.state) then
      return true
    end
    if fade.animating(row.added_age_ms) or fade.animating(row.removed_age_ms) then
      return true
    end
  end
  for _, age in ipairs(ages) do
    if fade.animating(age) then
      return true
    end
  end
  return false
end

function M.redraw()
  if not M.is_open() then
    return
  end
  restore_panes()
  -- The snapshot a foreign split is undone from. Taken here as well as on
  -- `WinResized` because that event needs a screen redraw to fire and a
  -- programmatic `nvim_win_set_height` does not always cause one — a resize made
  -- that way was silently never recorded, and the next split-and-close reverted
  -- it to the configured proportion (measured headless).
  --
  -- Throttled, because this is the frame tick: it lists the tab's windows and
  -- asks each for its config before it can even decide the layout is clean, so
  -- at `spinner_ms` it was a dozen window queries eight times a second to catch
  -- something that only happens when a size changes. The event handlers above
  -- are the prompt path; this is the backstop, and a backstop can be lazy.
  local now = (vim.loop and vim.loop.now and vim.loop.now()) or 0
  if not state.sizes_at or now < state.sizes_at or (now - state.sizes_at) >= SIZE_SNAPSHOT_MS then
    state.sizes_at = now
    M.remember_sizes()
  end

  -- What was drawn, so the clock can be released when none of it moves.
  local rows, ages = {}, {}

  local sessions_win = pane_win("sessions")
  if sessions_win and state.bufs.sessions then
    -- Which *conversation* the cursor is on, not which line. Rows no longer move
    -- on their own (the order is frozen — see `model.apply_order`), but they still
    -- move when the list is re-sorted with `gs` or `r`, and a new session sorted
    -- in above the cursor pushes everything below it down by one. That is not
    -- cosmetic — `<CR>`, `x` and `dd` act on the row under the cursor, and
    -- `cursorline` paints it exactly like the selection, so a session that had
    -- merely done something looked like the selected one.
    local anchor = nil
    local ok_cursor, pos = pcall(vim.api.nvim_win_get_cursor, sessions_win)
    if ok_cursor and pos then
      local payload = render.payload_at(state.bufs.sessions, pos[1])
      anchor = payload and payload.session_id or nil
    end

    rows = model.rows()
    render.sessions(state.bufs.sessions, rows, {
      width = vim.api.nvim_win_get_width(sessions_win),
      now = os.time(),
    })

    -- The cursor follows the selection whenever the selection has moved since it
    -- was last placed — including the case where it could not be placed at the
    -- time, because a conversation started here is selected before the CLI has
    -- written its transcript and so has no row to sit on for the first few
    -- seconds. Anchoring alone left the cursor (and with it `cursorline`) on the
    -- previously selected session when the new row finally appeared.
    local selected = model.selected()
    local followed = false
    if selected ~= state.cursor_selection then
      if not selected then
        state.cursor_selection = nil
      elseif reveal_session(selected) then
        state.cursor_selection = selected
        followed = true
      end
    end

    if anchor and not followed then
      reveal_session(anchor)
    end
  end

  local feed_win = pane_win("feed")
  if feed_win and state.bufs.feed then
    -- Only what the pane can show, plus a little slack so a row is not missing
    -- if the window grows between the measurement and the paint.
    local visible = vim.api.nvim_win_get_height(feed_win) + FEED_OVERDRAW
    local events
    events, ages = model.feed(visible)
    -- A caller (or a spec) may hand back events without ages; the pane then just
    -- draws them at their resting colour.
    ages = ages or {}
    render.feed(state.bufs.feed, events, {
      width = vim.api.nvim_win_get_width(feed_win),
      cwd = model.selected_cwd(),
      ages = ages,
    })
  end

  local changes_win = pane_win("changes")
  if changes_win and state.bufs.changes then
    render.changes(state.bufs.changes, model.changes(), {
      width = vim.api.nvim_win_get_width(changes_win),
      cwd = model.selected_cwd(),
    })
  end

  -- Hand the animation clock back when nothing on screen is going to change, and
  -- take it again the moment something is. Every path that puts new content in
  -- these panes ends in a redraw, so this is the one place that has to decide.
  local moving = anything_moving(rows, ages)
  if moving ~= state.animating then
    state.animating = moving
    M.arm_spinner()
  end
end

---Re-read everything the view shows, order included.
---
---The list is otherwise frozen (see `model.apply_order`), and `r` is where that
---is deliberately undone: an explicit refresh is the one moment a list that jumps
---is what was asked for.
function M.refresh()
  if not M.is_open() then
    return
  end
  model.refresh_list()
  model.refresh_git(true)
  model.resort()
  M.redraw()
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

---@return table|nil payload
---@return string|nil pane The pane the cursor is in, when it is one of ours.
---@return integer lnum
local function payload_under_cursor()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local pos = vim.api.nvim_win_get_cursor(win)
  local lnum = pos and pos[1] or 1
  local pane = nil
  for name, pane_buf in pairs(state.bufs) do
    if pane_buf == buf then
      pane = name
      break
    end
  end
  return render.payload_at(buf, lnum), pane, lnum
end

function M.select_under_cursor()
  local payload = payload_under_cursor()
  if payload and payload.session_id then
    M.select(payload.session_id)
  end
end

---Put the cursor on a session's row, so the sessions pane shows where the
---selection is even when it moved from another pane.
---@param session_id string
---@return boolean placed Whether the session had a row to put the cursor on.
function reveal_session(session_id)
  local win, buf = pane_win("sessions"), state.bufs.sessions
  if not win or not buf then
    return false
  end
  for lnum = 1, vim.api.nvim_buf_line_count(buf) do
    local payload = render.payload_at(buf, lnum)
    if payload and payload.session_id == session_id then
      pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
      return true
    end
  end
  return false
end

---Behave as if the list had been cycled onto once, as soon as there is a list.
---
---The centre pane is empty when the view opens and the sessions arrive
---asynchronously, so there is a window in which every key that means "the
---selected session" has nothing to act on. This closes it: the moment rows exist,
---the selected one — or the newest, which is what a first `<C-n>` would land on —
---is selected and offered, without starting anything.
---@return boolean acted Whether the view changed and needs repainting.
function offer_initial_session()
  if not state.await_initial or not M.is_open() then
    return false
  end
  -- Something already owns the centre: an agent the user started while the list
  -- was still loading, or an offer already made.
  if state.pending_start or center_has_terminal() then
    state.await_initial = false
    return false
  end
  local rows = model.rows()
  if #rows == 0 then
    return false -- still filling; the next change will call back
  end

  local target = model.selected()
  if not target or not model.row(target) then
    target = rows[1].session_id
  end
  state.await_initial = false

  model.select(target)
  reveal_session(target)
  show_or_offer(target)
  return true
end

---Which row `delta` steps from the selected one lands on, wrapping at both ends.
---With nothing selected yet, forwards starts at the top and backwards at the
---bottom — so the first `<C-p>` reaches the oldest session rather than doing
---nothing.
---@param rows table[] Session rows in display order.
---@param current string|nil Selected session id.
---@param delta integer
---@return integer index 0 when there is nothing to select.
---@private
function M._next_index(rows, current, delta)
  if #rows == 0 then
    return 0
  end
  local at = 0
  for index, row in ipairs(rows) do
    if row.session_id == current then
      at = index
      break
    end
  end
  if at == 0 then
    return delta > 0 and 1 or #rows
  end
  return ((at - 1 + delta) % #rows) + 1
end

---Move the selection to the next (or previous) session in the list.
---
---Bound in every pane and in the agent's terminal, because "which conversation am
---I looking at" is a question you ask from wherever you happen to be — most often
---from the terminal, which is where the cursor lives.
---
---A live conversation is swapped into the centre pane at once, which costs
---nothing. A stopped one is **not started**: cycling is how you look through what
---the sessions did — the counts, the files, the activity feed all follow the
---selection — and reading a conversation must not cost a CLI. The centre pane
---says so instead, and `focus_term` (`i`) starts the one you settled on.
---@param delta integer 1 for the next session, -1 for the previous one.
function M.cycle_session(delta)
  if not M.is_open() then
    return
  end
  local rows = model.rows()
  if #rows == 0 then
    return
  end

  local target = rows[M._next_index(rows, model.selected(), delta)]
  if not target then
    return
  end

  model.select(target.session_id)
  reveal_session(target.session_id)
  show_or_offer(target.session_id)
  M.redraw()
end

---Select a session without starting anything: what cycling does, from an id.
---
---The panes all follow the selection, so this is "look at that conversation" —
---and it is what the search picker calls as the highlighted row moves, which is
---why it must stay as cheap as `<C-n>` is.
---@param session_id string
function M.preview_session(session_id)
  if not M.is_open() or type(session_id) ~= "string" then
    return
  end
  model.select(session_id)
  reveal_session(session_id)
  show_or_offer(session_id)
  M.redraw()
end

---Select a session and land in it, resuming it if it is not running.
---
---`focus_term`'s intent — "put me in this session" — reached from an id rather
---than from the offer on screen. This is what choosing a search result does:
---searching for a conversation is looking for one to work in, so it does the
---starting that merely moving the selection deliberately does not.
---@param session_id string
function M.enter_session(session_id)
  if not M.is_open() or type(session_id) ~= "string" then
    return
  end
  M.select(session_id)
  -- `select` jumps tabs for a conversation running elsewhere; following it with a
  -- focus of our centre pane would drag the user straight back out of it.
  if vim.api.nvim_get_current_tabpage() ~= state.tab then
    return
  end
  reveal_session(session_id)
  M.focus_terminal()
end

---Search this project's conversations, and select the one you pick.
---
---The selection follows the highlighted result while the picker is open, so
---cancelling has to put back the conversation that was selected when it opened —
---otherwise browsing would leave the panes on whatever you happened to scroll
---past. Only `<CR>` commits.
function M.show_search()
  if not M.is_open() then
    return
  end
  local ok, search = pcall(require, "claudecode.agents.search")
  if not ok then
    return
  end

  local sessions = {}
  for _, row in ipairs(model.rows()) do
    sessions[#sessions + 1] = {
      session_id = row.session_id,
      title = row.title,
      icon = row.icon,
      hl = row.hl,
      path = model.transcript_path(row.session_id),
    }
  end
  if #sessions == 0 then
    vim.notify("ClaudeCode: no conversations to search yet", vim.log.levels.INFO)
    return
  end

  local restore = model.selected()
  local settings = opts().search or {}
  search.open({
    sessions = sessions,
    query = search.last_query(),
    limit = settings.max_per_session,
    debounce_ms = settings.debounce_ms,
    on_preview = function(session_id)
      M.preview_session(session_id)
    end,
    on_accept = function(session_id)
      M.enter_session(session_id)
    end,
    on_cancel = function()
      if restore then
        M.preview_session(restore)
      end
    end,
  })
end

---Show a conversation in the centre pane, resuming it if it is not already live.
---@param session_id string
function M.select(session_id)
  if not M.is_open() or type(session_id) ~= "string" then
    return
  end
  local center = ensure_center()
  if not center then
    return
  end

  model.select(session_id)

  if registry.is_live(session_id) then
    clear_start_prompt()
    registry.show(session_id, center)
    M.redraw()
    return
  end

  -- Running somewhere else in this Neovim: resuming it a second time would put
  -- two CLIs on one transcript, interleaving their writes. Go to it instead.
  local foreign_state, foreign_tab = model.foreign_state(session_id)
  if foreign_state and foreign_tab and vim.api.nvim_tabpage_is_valid(foreign_tab) then
    vim.notify("ClaudeCode: that conversation is running in another tab", vim.log.levels.INFO)
    pcall(vim.api.nvim_set_current_tabpage, foreign_tab)
    return
  end

  local row = model.row(session_id)
  local term, err = registry.launch(session_id, {
    win = center,
    tab = state.tab,
    -- The view's own cwd is where the user is now, and for a moved project it is
    -- where these transcripts live — so it is the right place to fall back to
    -- when the row names a directory that no longer exists.
    cwd = usable_dir(row and row.cwd) or model.cwd(),
    -- `--resume` needs a transcript to read, and a conversation that was started
    -- and then stopped before its first message has none — it is a name, not yet
    -- a conversation, and it is off the list because nothing enumerates it. Such
    -- an id is claimed rather than resumed, which is what starting it meant the
    -- first time too.
    resume = row ~= nil,
    focus = false,
  })
  if not term then
    vim.notify("ClaudeCode: could not start that agent: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  clear_start_prompt()
  M.bind_terminal_keys(term.bufnr)
  M.redraw()
end

---Start a brand new conversation in the centre pane.
function M.new_agent()
  if not M.is_open() then
    return
  end
  local center = ensure_center()
  if not center then
    return
  end
  local ok, session_state = pcall(require, "claudecode.session_state")
  if not ok then
    return
  end
  local session_id = session_state.new_session_id()

  local term, err = registry.launch(session_id, {
    win = center,
    tab = state.tab,
    cwd = model.cwd(),
    resume = false,
    focus = true,
  })
  if not term then
    vim.notify("ClaudeCode: could not start a new agent: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  clear_start_prompt()
  M.bind_terminal_keys(term.bufnr)
  model.select(session_id)
  -- Straight away rather than on the next poll: the CLI writes no transcript
  -- until the first message, so this conversation is listed from the registry
  -- until then — and a row is the only way back to it once the selection moves.
  model.refresh_list()
  M.redraw()
end

function M.stop_under_cursor()
  local payload = payload_under_cursor()
  if not payload or not payload.session_id then
    return
  end
  local session_id = payload.session_id
  if not registry.is_live(session_id) then
    return
  end
  local choice = vim.fn.confirm("Stop this agent?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  registry.stop(session_id)
  M.redraw()
end

--- How many rows a delete dialog names one by one before it starts counting. A
--- confirmation you have to scroll is one nobody reads.
local DELETE_LIST_MAX = 8

---The session ids on a range of lines, in order and without repeats.
---
---A line with no session on it is skipped rather than refused: a visual range is
---drawn by eye, and the "no sessions for this project" placeholder — or a range
---dragged past the last row — must not turn the whole gesture into an error.
---@param buf integer
---@param first integer
---@param last integer
---@return string[]
local function sessions_in_range(buf, first, last)
  local ids, seen = {}, {}
  if not buf then
    return ids
  end
  -- Only to bound the walk: a count is whatever the user typed, and `999dd` on a
  -- four-row list must not be 999 lookups. The lookups themselves already answer
  -- nil past the end, so a buffer that cannot report a length costs nothing.
  local ok_count, count = pcall(vim.api.nvim_buf_line_count, buf)
  if ok_count and type(count) == "number" and count > 0 and last > count then
    last = count
  end
  for lnum = math.max(1, first), last do
    local payload = render.payload_at(buf, lnum)
    local session_id = payload and payload.session_id
    if session_id and not seen[session_id] then
      seen[session_id] = true
      ids[#ids + 1] = session_id
    end
  end
  return ids
end

---How a session reads in the confirmation: its title, and what it changed.
---@param session_id string
---@return string
local function delete_label(session_id)
  local row = model.row(session_id)
  local label = (row and row.title) or session_id:sub(1, 8)
  if row and (row.added or row.removed) then
    return label .. ("  +%d  -%d"):format(row.added or 0, row.removed or 0)
  end
  return label
end

---Ask about a batch of conversations, then delete the ones the user agreed to.
---
---Running agents are set aside rather than refusing the whole gesture: with a
---count or a visual range the user is pointing at a stretch of the list, not at
---one row, and one busy agent in the middle of it should not mean nothing
---happens. The dialog says how many were left alone, and by which key they can be
---stopped. When *every* row is busy there is nothing to ask about, so that is the
---one case that only warns.
---@param session_ids string[]
local function confirm_and_delete(session_ids)
  local deletable, blocked = {}, 0
  for _, session_id in ipairs(session_ids) do
    -- No row means the list has already moved on from it — nothing to delete and
    -- nothing worth reporting.
    if model.row(session_id) then
      if registry.is_live(session_id) or model.foreign_state(session_id) then
        blocked = blocked + 1
      else
        deletable[#deletable + 1] = session_id
      end
    end
  end

  local stop_key = keymaps().stop
  local how = type(stop_key) == "string" and stop_key ~= "" and (" (" .. stop_key .. ")") or ""

  if #deletable == 0 then
    if blocked > 0 then
      local message = blocked == 1 and "stop this agent before deleting its session"
        or ("stop these %d agents before deleting their sessions"):format(blocked)
      vim.notify("ClaudeCode: " .. message .. how, vim.log.levels.WARN)
    end
    return
  end

  local message = {}
  for index, session_id in ipairs(deletable) do
    if index > DELETE_LIST_MAX then
      message[#message + 1] = ("… and %d more"):format(#deletable - DELETE_LIST_MAX)
      break
    end
    message[#message + 1] = delete_label(session_id)
  end
  message[#message + 1] = ""
  if #deletable == 1 then
    message[#message + 1] = "Removes the conversation from disk. It cannot be resumed."
  else
    message[#message + 1] = "Removes the conversations from disk. They cannot be resumed."
  end
  if blocked > 0 then
    message[#message + 1] = blocked == 1 and ("1 still running, left alone" .. how)
      or ("%d still running, left alone%s"):format(blocked, how)
  end

  local confirm = require("claudecode.agents.confirm")
  confirm.ask({
    title = #deletable == 1 and "Delete session" or ("Delete %d sessions"):format(#deletable),
    confirm = "delete",
    message = message,
  }, function(ok)
    if not ok then
      return
    end
    local deleted, failed = model.delete_sessions(deletable)
    if #failed > 0 then
      local first = failed[1]
      local detail = tostring(first.err)
      if #failed > 1 then
        detail = detail .. (" (and %d more)"):format(#failed - 1)
      end
      local what = #deleted > 0 and ("could not delete %d of %d sessions: "):format(#failed, #deletable)
        or "could not delete the session: "
      vim.notify("ClaudeCode: " .. what .. detail, vim.log.levels.ERROR)
    end
    M.redraw()
  end)
end

---Delete every conversation on a range of the sessions pane, transcript and all.
---
---The range comes from a visual selection; `delete_under_cursor` supplies a
---cursor-relative one for a count.
---@param first integer
---@param last integer
function M.delete_range(first, last)
  local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
  confirm_and_delete(sessions_in_range(buf, first, last))
end

---Delete the conversation under the cursor, transcript and all.
---
---Takes a count, so `3dd` deletes three rows the way it would delete three lines
---anywhere else — one dialog for the batch, not three in a row.
---
---Refuses while an agent runs: the CLI still has the transcript open, and the row
---would come back the next time it writes a line. Stopping it first is one
---keypress away, and the message says so.
---@param count integer|nil Rows from the cursor down. Defaults to one.
function M.delete_under_cursor(count)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local pos = vim.api.nvim_win_get_cursor(win)
  local lnum = (pos and pos[1]) or 1
  local rows = math.max(1, tonumber(count) or 1)
  confirm_and_delete(sessions_in_range(buf, lnum, lnum + rows - 1))
end

---`d` over a visual selection of the sessions pane.
---
---The range is read from `v` and `.` **before** leaving visual mode: `'<` and `'>`
---are only written when the mode ends, so reading those here would act on the
---previous selection. Visual mode is then left at once, since the confirmation
---opens a window over the pane and answering it from visual mode would extend the
---selection into whatever came next.
function M.delete_visual()
  local first = vim.fn.line("v")
  local last = vim.fn.line(".")
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  if first > last then
    first, last = last, first
  end
  M.delete_range(first, last)
end

--------------------------------------------------------------------------------
-- Opening a row, and stepping through the rows from inside the float
--------------------------------------------------------------------------------

--- Mutually recursive with the stepping below: a float knows the row it came
--- from, and stepping opens the next one into the same window.
---@type fun(payload: table|nil, pane: string|nil, lnum: integer|nil, action: string, nav_opts: table|nil)
local open_row

---The next row of a pane there is something to open on, wrapping at both ends.
---
---Wrapping rather than stopping, like the session cycling: a pane is a ring of
---rows, and running off the end of the Changes list with no way back would be the
---one place in this view where a key silently does nothing.
---
---A tool call counts: the float is a view of one row, and a row that is a command
---has as much to show as one that is a file. Stepping therefore walks the feed as
---it is drawn, swapping between a file's diff and a command's output — one reading
---frame for the whole session rather than one per kind of row.
---A HEAD float is the exception, and skips them: `.` asks what is uncommitted in
---a file, which a command has no answer to at all.
---@param pane string
---@param lnum integer
---@param delta integer
---@param action string|nil What the float is showing; "head" wants files only.
---@return integer|nil
local function next_open_row(pane, lnum, delta, action)
  local buf = state.bufs[pane]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if count == 0 then
    return nil
  end
  for step = 1, count do
    local candidate = ((lnum - 1 + delta * step) % count) + 1
    local payload = render.payload_at(buf, candidate)
    local openable = payload and (payload.path or (payload.kind == "tool" and action ~= "head"))
    if openable then
      return candidate
    end
  end
  return nil
end

---Open whatever row the stepping is currently aimed at.
---
---Coalesced rather than queued: only one open is ever in flight, and when it
---lands the aim is checked again. A held `<C-n>` therefore walks the aim forward
---as fast as the key repeats and opens the row it settled on, instead of firing
---an asynchronous transcript read per keypress and letting them land in whatever
---order they finish.
---@param win integer
local function open_aimed(win)
  local nav = state.float_nav[win]
  if not nav or nav.opening or nav.aim == nil or nav.aim == nav.lnum then
    return
  end
  local buf = state.bufs[nav.pane]
  local payload = buf and render.payload_at(buf, nav.aim)
  if not payload then
    nav.aim = nav.lnum
    return
  end

  local wanted = nav.aim
  nav.opening = true
  open_row(payload, nav.pane, wanted, nav.action, {
    reuse = win,
    done = function(new_win)
      nav.opening = false
      if not new_win then
        -- Nothing opened — a file that matches HEAD, say. Stay on what is on
        -- screen rather than chasing an aim that has no view behind it.
        nav.aim = nav.lnum
        return
      end
      nav.lnum = wanted
      if new_win ~= win then
        -- The float could not be reused (the user closed it), so a new one was
        -- built. Move the state across, or the next key would step a dead window.
        state.float_nav[win] = nil
        state.float_nav[new_win] = nav
      end
      open_aimed(new_win)
    end,
  })
end

---Point a float at the next (or previous) row of the pane it came from.
---@param win integer
---@param delta integer
local function step_float(win, delta)
  local nav = state.float_nav[win]
  if not nav then
    return
  end
  local target = next_open_row(nav.pane, nav.aim or nav.lnum, delta, nav.action)
  if not target then
    return
  end
  -- The aim moves on the keypress, the window follows when it can: that is what
  -- makes holding the key feel like scrolling a list rather than opening files.
  nav.aim = target
  -- Move the pane's own cursor with it: the float is a view of a row, so that is
  -- the row the pane should be sitting on when the float closes.
  local pane_window = pane_win(nav.pane)
  if pane_window then
    pcall(vim.api.nvim_win_set_cursor, pane_window, { target, 0 })
  end
  open_aimed(win)
end

---Give a float the keys that step through the pane it came from.
---
---`<C-n>`/`<C-p>` change the session everywhere else in the view; in a float they
---change the file, which is the same intent one level down — the float *is* a
---view of one row, so the keys walk the rows. Rebinding them per float keeps both
---meanings without a mode to be in.
---
---Only on a scratch buffer we made. `float.open_file` shows the real file buffer,
---and a buffer-local map there would follow that file out of the float and into
---the editor, where `<C-n>` means something else entirely.
---@param win integer|nil
---@param pane string|nil
---@param lnum integer|nil
---@param action string
local function bind_float_nav(win, pane, lnum, action)
  if not win or not pane or not lnum or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok or not buf then
    return
  end
  local ok_bt, buftype = pcall(vim.api.nvim_buf_get_option, buf, "buftype")
  if not ok_bt or buftype ~= "nofile" then
    return
  end

  local nav = state.float_nav[win]
  if nav then
    nav.pane, nav.action, nav.lnum = pane, action, lnum
    -- Deliberately not `nav.aim = lnum`: the aim may have moved on while this
    -- open was in flight, and that later keypress is the one to honour.
    nav.aim = nav.aim or lnum
  else
    state.float_nav[win] = { pane = pane, action = action, lnum = lnum, aim = lnum, opening = false }
  end

  local keys = keymaps()
  for delta, lhs in pairs({ [1] = keys.next_session, [-1] = keys.prev_session }) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.set, "n", lhs, function()
        step_float(win, delta)
      end, {
        buffer = buf,
        nowait = true,
        silent = true,
        desc = delta > 0 and "Show the next file" or "Show the previous file",
      })
    end
  end
end

---Open the file on a row, showing what the selected session did to it.
---
---A row in either pane is a record of work, not a file reference: the Changes pane
---answers "what did this agent change here", and an Activity row answers "what did
---this one tool call do". So the file opens as the session's own diff — or, for a
---read, with the lines it read marked — rather than as a plain file. `file_view`
---decides which, and falls back to the plain open when there is no history to show.
---@param payload table|nil Row payload.
---@param pane string|nil Pane it came from, for the float's own navigation.
---@param lnum integer|nil
---@param action string "diff" (what the session did) | "head" (what is uncommitted)
---@param nav_opts { reuse: integer?, done: fun(win: integer|nil)? }|nil
function open_row(payload, pane, lnum, action, nav_opts)
  nav_opts = nav_opts or {}
  ---Every exit runs through here, so a caller waiting on the open (the stepping
  ---above) is told even when nothing opened, rather than waiting for ever.
  ---@param win integer|nil
  local function opened(win)
    bind_float_nav(win, pane, lnum, action)
    if nav_opts.done then
      nav_opts.done(win)
    end
  end

  -- A tool call: not a file, so none of what follows applies. `.` and `gf` are
  -- about a file and say so; `<CR>` is the row's own question and is answered by
  -- reading the call and its output back out of the transcript.
  if payload and payload.kind == "tool" then
    if action ~= "diff" then
      logger.warn("agents", "this row is a " .. (payload.tool or "tool") .. " call, not a file")
      return opened(nil)
    end
    local ok_tool, tool_view = pcall(require, "claudecode.agents.tool_view")
    if not ok_tool then
      return opened(nil)
    end
    tool_view.open({
      session_id = model.selected(),
      transcript = model.transcript_path(),
      tool_id = payload.tool_id,
      tool = payload.tool,
      label = payload.label,
      status = payload.status,
      reuse = nav_opts.reuse,
    }, opened)
    return
  end

  if not payload or not payload.path then
    return opened(nil)
  end

  local ok_view, file_view = pcall(require, "claudecode.agents.file_view")
  if not ok_view then
    if action == "diff" then
      M.open_file(payload.path, payload.line)
    end
    return opened(nil)
  end

  if action == "head" then
    file_view.open_against_head({
      session_id = model.selected(),
      path = payload.path,
      line = payload.line,
      reuse = nav_opts.reuse,
    }, opened)
    return
  end

  local read = nil
  if payload.event_kind == "read" and payload.start_line then
    read = { start_line = payload.start_line, num_lines = payload.num_lines or 1 }
  end

  file_view.open({
    session_id = model.selected(),
    transcript = model.transcript_path(),
    path = payload.path,
    line = payload.line,
    read = read,
    prefer = read and "read" or "diff",
    reuse = nav_opts.reuse,
  }, opened)
end

---`<CR>` on a Changes or Activity row.
function M.open_under_cursor()
  local payload, pane, lnum = payload_under_cursor()
  open_row(payload, pane, lnum, "diff")
end

---Diff the file under the cursor against git HEAD.
---
---The neighbour of `<CR>`: that shows what *this agent* did to the file, this
---shows everything uncommitted in it. With several agents over one tree the two
---answers diverge, and no session's history can produce the second one.
function M.diff_head_under_cursor()
  local payload, pane, lnum = payload_under_cursor()
  open_row(payload, pane, lnum, "head")
end

---`gf` on a Changes or Activity row: the file itself, in a new tab.
---
---The third question a row can be asked, and the only one that is not about the
---row: `<CR>` shows what this agent did to the file and `.` what is uncommitted
---in it, both to read; this opens what is on disk, to work in. A new tab rather
---than a float or the origin tab, because neither is somewhere to edit — a float
---is a reading frame that `q` throws away, and the origin tab is a layout the
---user arranged for something else. A tab of its own leaves both alone, and
---carries none of this tab's vars, so diffs and previews treat it as the
---ordinary editor tab it is.
function M.goto_file_under_cursor()
  local payload = payload_under_cursor()
  if payload and payload.kind == "tool" then
    logger.warn("agents", "this row is a " .. (payload.tool or "tool") .. " call, not a file")
    return
  end
  if not payload or not payload.path then
    return
  end
  M.open_file_in_tab(payload.path, payload.line)
end

---`f` in the Activity pane: show files only, tool calls only, or everything.
---
---A busy agent runs several tools per file it touches, so the two halves of the
---feed crowd each other out. The filter is a way of reading the list rather than a
---setting about it, so it lives on the view and dies with it, like the sort order.
function M.cycle_feed_filter()
  local filter = model.cycle_feed_filter()
  M.redraw()
  vim.notify("ClaudeCode: activity — " .. filter.desc, vim.log.levels.INFO)
end

---Open a path in a new tabpage, on `line` when there is one.
---@param path string
---@param line integer|nil
---@return boolean opened
function M.open_file_in_tab(path, line)
  -- A row records work, and that work may have been a delete — or the file may
  -- have moved since. `tabnew` on a path that is not there opens an empty buffer
  -- whose first `:w` resurrects the file, which is not what `gf` asks for.
  if vim.fn.filereadable(path) ~= 1 then
    logger.warn("agents", "no file on disk at " .. path)
    return false
  end
  local ok = pcall(vim.cmd, "tabnew " .. vim.fn.fnameescape(path))
  if not ok then
    return false
  end
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end
  return true
end

---Open a file somewhere that is not one of our panes.
---@param path string
---@param line integer|nil
function M.open_file(path, line)
  local ok_float, float = pcall(require, "claudecode.agents.float")
  if ok_float and float.open_file and float.open_file(model.selected(), path, line) then
    return
  end
  -- No float available: fall back to the tab the view was opened from, which is
  -- the only other place a file can land without disturbing the layout.
  local origin = M.origin_tab()
  if origin then
    pcall(vim.api.nvim_set_current_tabpage, origin)
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    if line then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    end
  end
end

---Put the cursor in the agent's terminal, in insert mode.
---
---When the centre is offering a stopped conversation instead (see
---`show_start_prompt`), this is the key that accepts the offer: "get me into this
---session" is the same intent whether the CLI is already running or not, so it
---starts it first and lands in it.
function M.focus_terminal()
  local pending = state.pending_start
  if not pending and not center_has_terminal() then
    -- Nothing to focus and nothing offered: the list arrived late, or the user
    -- reached for this key before it did. Offer now rather than dropping them
    -- into insert mode in an empty pane.
    offer_initial_session()
    pending = state.pending_start
    if not pending and #model.rows() == 0 then
      -- Nothing to resume and nothing to read: Claude has never run in this
      -- project, so "put me in a session" can only mean starting one. `new_agent`
      -- focuses the centre and enters insert mode itself.
      M.new_agent()
      return
    end
  end
  if pending then
    M.select(pending)
    -- `select` jumps tabs for a conversation running elsewhere. Focusing the
    -- centre pane afterwards would drag the user straight back out of it.
    if vim.api.nvim_get_current_tabpage() ~= state.tab then
      return
    end
  end
  local center = ensure_center()
  if not center then
    return
  end
  pcall(vim.api.nvim_set_current_win, center)
  -- Only a terminal takes insert mode. The notice is a scratch buffer, and this
  -- project has no conversation to start when there is not even one to offer.
  if center_has_terminal() then
    pcall(vim.cmd, "startinsert")
  end
end

function M.focus_next_pane()
  local order = { "sessions", "feed", "changes", "center" }
  local current = vim.api.nvim_get_current_win()
  local at = 0
  for index, pane in ipairs(order) do
    if state.wins[pane] == current then
      at = index
      break
    end
  end
  for step = 1, #order do
    local pane = order[((at + step - 1) % #order) + 1]
    local win = pane_win(pane)
    if win then
      pcall(vim.api.nvim_set_current_win, win)
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Hook ingestion
--------------------------------------------------------------------------------

---Fold one Claude Code hook event into the view.
---@param event table Decoded hook payload.
---@param source_tab integer|nil
---@param agent_id string|nil Launch key of the agent that reported it, if it is one.
function M.note(event, source_tab, agent_id)
  if not M.is_enabled() then
    return
  end
  if type(event) == "table" then
    -- `SessionStart` is the CLI stating which conversation it is having; every
    -- other event merely mentions one, and may well be a late report from the
    -- conversation this agent has just left.
    M.note_session_switch(agent_id, event.session_id, {
      reclaim = event.hook_event_name == "SessionStart",
    })
  end
  model.note(event, source_tab)
end

---A running agent is having a different conversation than it was.
---
---`/clear` ends the chat and starts another one under a fresh id in the same
---terminal — the process, the port and the buffer all carry on. Everything in
---this view is keyed by conversation, so until this runs the list describes a
---chat that has been abandoned: the old row keeps its running bullet, and the new
---conversation shows up minutes later (whenever the CLI first writes its
---transcript) as a row that looks stopped, which is what a user sees as "a new
---session appeared and it is not active".
---
---The selection follows the terminal, but only if it was on the conversation
---being left: the centre pane is showing that terminal, and leaving the panes
---describing the old chat while the terminal shows the new one is the same lie
---one level down. A selection parked on some other agent is the user's and is not
---moved.
---@param agent_id string|nil
---@param session_id string|nil
---@param switch_opts { reclaim: boolean? }|nil
---@return boolean moved
function M.note_session_switch(agent_id, session_id, switch_opts)
  local previous = registry.rekey(agent_id, session_id, switch_opts)
  if not previous then
    return false
  end
  local follow = model.note_session_change(previous, session_id)
  -- Straight away rather than on the next poll: the CLI writes no transcript for
  -- the new conversation until its first message, so it is listed from the
  -- registry until then — and a row is the only way back to it.
  model.refresh_list()
  if follow then
    if M.is_open() then
      M.select(session_id)
    else
      model.select(session_id)
    end
  end
  M.redraw()
  return true
end

---An agent's terminal ended.
---
---The dead terminal buffer is taken out of the centre pane straight away. Neovim
---closes such a buffer on the next keypress and the window goes with it, which
---left the view open but with nowhere to put an agent. Swapping in a placeholder
---means the keypress has nothing to close.
---@param bufnr integer
function M.note_terminal_closed(bufnr)
  local session_id = registry.session_for_buf(bufnr)
  if not session_id then
    return
  end
  registry._on_exit(session_id, nil, nil)

  local center = pane_win("center")
  if center and vim.api.nvim_win_get_buf(center) == bufnr then
    -- The conversation itself survives its CLI, so this is the same screen a
    -- cycled-to stopped session gets: `i` picks it back up where it left off.
    show_start_prompt(session_id)
  end
  M.redraw()
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

---What is worth carrying into the next Neovim.
---
---Not much, deliberately: the session list rebuilds itself from the transcript
---store, so all that has to survive is *where* the view was and which
---conversations were running in it — enough to reopen it in the same place with
---the same agents marked, without storing anything the CLI already knows.
---@return table|nil
function M.capture()
  if not M.is_open() then
    -- A view that stood down for the session write still has to describe itself.
    -- The manager asks for this payload *after* `:mksession` (auto-session runs
    -- pre_save → mksession → save_extra_data), by which time `close_for_session`
    -- has taken the view away, so what it snapshotted on the way out is the
    -- answer. Consumed once: a later save must not resurrect a view that is
    -- genuinely gone.
    local pending = pending_capture
    pending_capture = nil
    return pending
  end
  local ok, tabnr = pcall(vim.api.nvim_tabpage_get_number, state.tab)
  if not ok then
    return nil
  end
  return {
    tabnr = tabnr,
    cwd = model.cwd(),
    -- Only conversations the CLI wrote a transcript for can be resumed at all;
    -- the registry's ids are proven by definition, since they have been talked to.
    sessions = registry.live_ids(),
  }
end

---Whether Neovim is on its way out.
---
---`v:exiting` is `v:null` until it is, and an exit code from `VimLeavePre`
---onwards (measured) — which is where a session manager's save runs, so it is the
---one thing that tells a quit from a `:AutoSession save` typed mid-work. Our own
---`shutting_down` flag cannot answer it: that is set by an autocmd registered
---when claudecode loads, which for a lazily-loaded plugin is *after* the session
---manager's own `VimLeavePre`, so it is still unset while the save runs. It is
---read anyway, as a second opinion for a caller that has one.
---@return boolean
local function neovim_is_exiting()
  -- An exit code once it is set, `v:null` (a userdata, not `nil`) before that,
  -- so the type is the test.
  if type(vim.v and vim.v.exiting) == "number" then
    return true
  end
  local ok, main = pcall(require, "claudecode")
  return (ok and main.state and main.state.shutting_down) == true
end

---Whether every window in the tab is one of ours.
---
---A weaker question than `layout_clean`, which also wants all four panes present:
---a tab missing a pane still holds nothing of the user's, and is still ours to
---take away.
---@return boolean
local function tab_is_ours()
  if not M.is_open() then
    return false
  end
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, state.tab)
  if not ok then
    return false
  end
  for _, win in ipairs(wins) do
    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
    local floating = ok_cfg and type(cfg) == "table" and cfg.relative ~= nil and cfg.relative ~= ""
    if not floating and not pane_of(win) then
      return false
    end
  end
  return true
end

---Take the view out of the Neovim session that is about to be written.
---
---`:mksession` records this tab like any other — four windows holding buffers
---named `Claude agents: changes` and friends, and, with 'sessionoptions' carrying
---`terminal` (the default), each live agent as a `term://` buffer that Neovim
---restores by *running the command again*. None of that is worth keeping: the
---view already describes itself through `capture`, and reopening rebuilds the
---panes from scratch.
---
---Call it from a session manager's pre-save hook — auto-session's
---`pre_save_cmds`, resession's `pre_save` — which is the only point that lands
---before the write (auto-session runs pre_save → mksession → save_extra_data, so
---closing from `capture` would already be too late). A plain `VimLeavePre`
---autocmd of ours cannot do it either: the session manager loads first and so
---saves first.
---
---Only on the way out, unless forced: a save can also be a `cd` or a
---`:AutoSession save` typed mid-work, and neither is a reason to tear down a view
---the user is in.
---
---A tab holding something of the user's as well keeps the tab — only our own
---windows go, and the session records what is left.
---@param force boolean|nil Stand down whether or not Neovim is exiting.
---@return "closed"|"panes"|nil what it did — never `false`, which auto-session
---        reads from a pre-save hook as "abandon the save"
function M.close_for_session(force)
  if not M.is_open() then
    return nil
  end
  if not force and not neovim_is_exiting() then
    logger.debug("agents", "session save is not a quit; leaving the view open")
    return nil
  end
  -- Before the close, while there is still a view to describe.
  pending_capture = M.capture()
  local ours = tab_is_ours()
  M.close({ keep_tab = not ours })
  logger.debug("agents", ours and "agents view closed for the session write" or "agents panes closed, tab left alone")
  return ours and "closed" or "panes"
end

---Take a snapshot back.
---
---Lazily by default: the view reopens and its previously-running agents are
---marked, but no CLI starts until one is selected. N restored agents must not be
---N processes at startup.
---@param data table|nil
---@param restore_opts { open: boolean? }|nil
---@return boolean
function M.restore(data, restore_opts)
  if type(data) ~= "table" then
    return false
  end
  restored = {
    tabnr = tonumber(data.tabnr),
    cwd = type(data.cwd) == "string" and data.cwd or nil,
    sessions = type(data.sessions) == "table" and data.sessions or {},
  }
  logger.debug("agents", "armed the agents view with " .. #restored.sessions .. " previous agent(s)")

  if restore_opts and restore_opts.open and M.is_enabled() then
    M.open()
  end
  return true
end

---Conversations the restored session says were running, if any.
---@return string[]
function M.armed_sessions()
  return (restored and restored.sessions) or {}
end

--------------------------------------------------------------------------------
-- Teardown
--------------------------------------------------------------------------------

---Drop every handle without touching windows (the tab is already gone).
function M.forget()
  M.stop_timers()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  local tab = state.tab
  state.tab = nil
  state.wins = {}
  state.bufs = {}
  -- The notice buffer goes with the tab that showed it; the next `open` makes a
  -- fresh one, with its keys bound from whatever config is in force then.
  state.notice_buf = nil
  state.notice_kind = nil
  state.pending_start = nil
  state.float_nav = {}
  state.await_initial = false
  -- The next `open` places the cursor from scratch; carrying this over would let
  -- an unchanged selection skip that.
  state.cursor_selection = nil
  -- The snapshot describes a layout that no longer exists; carrying it into the
  -- next `open` would restore the previous view's proportions over the fresh
  -- build.
  state.sizes = nil
  state.sizes_locked = false
  state.sizes_at = nil
  model.detach()
  if tab then
    pcall(function()
      require("claudecode.session_state").reclaim_tab(tab)
    end)
  end
end

function M.forget_closed_tabs()
  if state.tab and not vim.api.nvim_tabpage_is_valid(state.tab) then
    M.forget()
  end
end

---Neovim is exiting.
function M.cleanup()
  M.stop_timers()
  pcall(function()
    require("claudecode.agents.transcript").cache_save()
  end)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

---@return table
function M._state()
  return state
end

return M
