---@brief [[
--- The agents view's view-model: what the panes should say, with no window or
--- buffer API in sight.
---
--- It joins four sources that each know only part of the answer — the transcript
--- store (titles, counts, touched files, activity), this Neovim's agent registry
--- (which conversations are actually running here), `status` (what the tab-hosted
--- Claudes are doing), and git (what the working tree looks like) — and folds
--- them into rows the renderer can draw.
---
--- Per-agent state is keyed by conversation id rather than tabpage. `status` keys
--- by tab because a tab used to mean one Claude; here several share a tab, so the
--- tab has no single state and the conversation is the only thing that does. The
--- classification rules are still `status`'s, via `status.classify`, so a busy
--- agent and a busy tab mean the same thing.
---
--- Refreshes are coalesced: hook events only set dirty flags, and one timer turns
--- a burst of them into a single redraw.
---@brief ]]
---@module 'claudecode.agents.model'

local transcript = require("claudecode.agents.transcript")

local M = {}

--- Agents config subtable.
---@type table|nil
local config = nil

---When each thing on screen was first seen.
---
---Keyed by the event table itself rather than by its contents: the transcript
---hands out its own stored tables, so identity is exact and free — no key to
---build, and no two reads of the same file in the same second colliding. Weak
---keys so the store trimming its oldest events drops these with them.
---@return table
local function new_seen()
  return setmetatable({}, { __mode = "k" })
end

---A fresh model state.
---
---A factory rather than a table literal plus a hand-rolled rebuild in `reset()`:
---the two copies drifted the moment they existed, and every field the rebuild
---forgot is a nil index waiting to happen — `stamp_feed` indexes `state.seen` on
---every draw of the Activity pane.
---@return table
local function new_state()
  return {
    tab = nil, ---@type integer|nil Tabpage hosting the view.
    cwd = nil, ---@type string|nil Project the view is showing.
    selected = nil, ---@type string|nil Conversation id.
    rows = {}, ---@type table[] Session rows, newest first.
    by_id = {}, ---@type table<string, table> Conversation id -> row.
    status = {}, ---@type table<string, table> Conversation id -> { state, tool, message, since }
    git = {}, ---@type table<string, string> Path -> status letter.
    dirty = {},
    armed = false,
    ---@type table<string, fun()> Keyed by name, so re-registering replaces rather
    --- than stacking: a second `setup()` used to leave two identical listeners and
    --- redraw the whole view twice per change, for ever.
    listeners = {},
    -- So the renderer can draw a fresh row differently from a settled one.
    -- Milliseconds on a monotonic clock; see `now_ms`.
    seen = new_seen(),
    counts = {}, ---@type table<string, table> Row key -> { added, removed, added_at, removed_at }
    -- Interrupt markers already acted on, `[session_id] = ts`. Keyed by
    -- conversation and **not** stored on the row: `refresh_list` replaces every
    -- row table on a 2s timer, so a row-held flag is forgotten and the same old
    -- marker fires for ever.
    interrupted = {},
    -- Set when the selection changes: the events that arrive next are a backfill
    -- of history, not news, and must not all light up at once.
    feed_baseline = true,
    -- The order the session list is *already* showing, as conversation ids. The
    -- list is not re-sorted on every rebuild; see `apply_order`.
    order = {},
    -- `{ key, desc }` once asked for; nil until then, so the first ask takes
    -- `agents.sessions.sort`. Lives and dies with the open view.
    sort = nil,
  }
end

local state = new_state()

--- Injectable for the same reason `_scheduler` is: the vim mock has no clock
--- that advances, so a spec that wants to watch something age needs to drive it.
M._now_ms = function()
  local ok, now = pcall(function()
    return vim.loop.now()
  end)
  if ok and type(now) == "number" and now > 0 then
    return now
  end
  return os.time() * 1000
end

---@param fn fun(): number
function M._set_clock(fn)
  M._now_ms = fn
end

---@return number
local function now_ms()
  return M._now_ms()
end

---Forget what has been seen, so nothing that arrives next reads as new.
---
---Called wherever the *subject* changes rather than its contents: a different
---session's history is not activity, and the same path under a different session
---is a different set of counts.
---
---Two things deliberately survive it, because they do not belong to the
---selection. **The session rows' count baselines** (`session\0<id>`) describe the
---whole list, which does not change when you look at a different row — wiping
---them meant the first change to any session after a selection change was seen
---for the "first" time and so never flashed. And **`interrupted`**, which is
---keyed by conversation: clearing it lets a marker that has already been acted on
---fire again, which is the bug section 11 of the journal exists to record.
local function reset_seen()
  state.seen = new_seen()
  local kept = {}
  for key, value in pairs(state.counts) do
    if key:sub(1, 8) == "session\0" then
      kept[key] = value
    end
  end
  state.counts = kept
  state.feed_baseline = true
end

---End a `busy` the user stopped by hand.
---
---Claude Code reports an interrupt through **no hook at all** — measured against
---the real CLI — so the transcript's own `[Request interrupted by user]` entry
---is the only thing that can end one, and without it a cancelled conversation
---spins until its next prompt. Every path that takes a fresh summary calls this,
---since which of them sees the marker first is a matter of what is selected.
---
---Two things here are load-bearing, and the first version had neither:
---
---*What has been acted on is remembered per conversation, not on the row.*
---`refresh_list` builds brand-new row tables every time it runs — on a 2s timer
---— so a flag stored there was gone by the next pass and every refresh re-fired
---the interrupt. Reported as an agent's spinner freezing whenever its counts
---updated: a tool finishing re-reads the transcript, the stale marker fired
---again, and `busy` was knocked back to `idle` until the next hook event.
---
---*A marker only ends the turn it belongs to.* The transcript keeps every
---interrupt the conversation ever had, so the marker being present says nothing
---on its own; it has to be newer than the moment the running turn started.
---@param session_id string|nil
---@param summary table|nil
local function note_transcript_interrupt(session_id, summary)
  local ts = summary and summary.interrupted_ts
  if type(session_id) ~= "string" or type(ts) ~= "number" or ts <= 0 then
    return
  end
  if state.interrupted[session_id] == ts then
    return
  end
  state.interrupted[session_id] = ts

  local entry = state.status[session_id]
  if entry and entry.state == "busy" and ts < (entry.since or 0) then
    -- An interrupt from an earlier turn. The one running now is still running.
    return
  end
  M.note_interrupt(session_id)
end

---How long each Activity event has been on screen, positionally.
---
---The first batch after a selection change is history being backfilled, not news
---— it must not light the whole pane up at once. An empty batch does not count
---as that first one: the transcript may still be reading, and the events that
---follow it *are* the backfill.
---
---A backfilled row is aged from **its own timestamp**, not declared infinitely
---old. Declaring it old was the first version and it made the pane read as
---permanently dim: switching session and back re-backfills everything, so an
---edit from a second ago went fully grey the moment you looked away and
---returned. What is recent is recent however you arrived at it.
---@param events table[] Newest first, as the pane shows them.
---@return table[]
local function stamp_feed(events)
  local now = now_ms()
  local wall = os.time()
  local baseline = state.feed_baseline and #events > 0
  if baseline then
    state.feed_baseline = false
  end
  -- Ages travel *beside* the events rather than on a copy of them. The events are
  -- the transcript's own stored tables, cached to disk, so writing a field onto
  -- one would leak a view concern into the store — which is why this used to
  -- allocate a table per row on every frame instead.
  local out = {}
  for index, event in ipairs(events) do
    local seen = state.seen[event]
    if seen == nil then
      if not baseline then
        seen = now
      else
        -- `ts` is epoch seconds; `now` is a monotonic millisecond clock, so the
        -- elapsed time is measured in the first and then subtracted from the
        -- second. An event with no usable timestamp keeps the old behaviour and
        -- reads as ancient, which is the safe way to be wrong.
        local ts = tonumber(event.ts) or 0
        seen = ts > 0 and (now - math.max(0, (wall - ts) * 1000)) or 0
      end
      state.seen[event] = seen
    end
    -- `seen == 0` means "was already here", which must never read as fresh.
    out[index] = seen == 0 and math.huge or (now - seen)
  end
  return out
end

---Note a count moving, and say how long ago it did.
---
---A value seen for the first time never counts as a change: opening the view
---would otherwise flash every number in it. Only a value that *moved* from one
---we already showed is news.
---@param key string Identity of the row the counts belong to.
---@param added integer|nil
---@param removed integer|nil
---@return number|nil added_age_ms
---@return number|nil removed_age_ms
local function stamp_counts(key, added, removed)
  local now = now_ms()
  local prev = state.counts[key]
  if not prev then
    state.counts[key] = { added = added, removed = removed }
    return nil, nil
  end
  if added ~= nil and prev.added ~= nil and added ~= prev.added then
    prev.added_at = now
  end
  if removed ~= nil and prev.removed ~= nil and removed ~= prev.removed then
    prev.removed_at = now
  end
  if added ~= nil then
    prev.added = added
  end
  if removed ~= nil then
    prev.removed = removed
  end
  return prev.added_at and (now - prev.added_at) or nil, prev.removed_at and (now - prev.removed_at) or nil
end

--- Injectable so specs can run the coalescing logic without a real timer (the
--- vim mock runs `defer_fn` immediately, which would defeat the point).
M._scheduler = function(fn, delay)
  vim.defer_fn(fn, delay)
end

---@param fn fun(fn: function, delay: number)
function M._set_scheduler(fn)
  M._scheduler = fn
end

--- Conversations a restored Neovim session says were running. They are marked in
--- the list but nothing starts until one is chosen, so N restored agents are not
--- N processes at startup.
local armed = {}

---@param ids string[]|nil
function M.set_armed(ids)
  armed = {}
  for _, id in ipairs(ids or {}) do
    armed[id] = true
  end
end

---@param full_config table|nil
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
  transcript.setup(full_config)
end

---@return table
local function opts()
  return config or {}
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---Point the model at a project, in the tab hosting the view.
---@param tab integer
---@param cwd string
function M.attach(tab, cwd)
  state.tab = tab
  state.cwd = cwd
  state.rows = {}
  state.by_id = {}
  state.dirty = { list = true, transcript = true, git = true }
  reset_seen()
  transcript.cache_load()
  M.refresh_list()
end

---Stop tracking, leaving the folded transcripts cached for the next open.
function M.detach()
  transcript.cancel_all()
  transcript.cache_save()
  state.tab = nil
  state.cwd = nil
  state.selected = nil
  state.rows = {}
  state.by_id = {}
  state.armed = false
  -- Keyed by conversation and never pruned otherwise, so a long Neovim session
  -- with the view closed accumulated one entry per Claude it ever saw.
  state.status = {}
  -- A sort chosen with `gs` lasts as long as the view is open. The next open
  -- starts from `agents.sessions.sort` again, which is the one thing about the
  -- order that is written down.
  state.order = {}
  state.sort = nil
end

---@return string|nil
function M.cwd()
  return state.cwd
end

---Subscribe to "the model changed"; the view redraws from this.
---
---Named, so a second `claudecode.setup()` — a config reload, a re-sourced
---plugin spec — replaces the listener rather than stacking another copy of it
---and redrawing the whole view twice per change from then on.
---@param name string
---@param fn fun()
function M.on_change(name, fn)
  state.listeners[name] = fn
end

local function notify_change()
  for _, fn in pairs(state.listeners) do
    pcall(fn)
  end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- What a conversation is called before it has said anything. Every other title
--- comes out of the transcript, and this is the row that has none yet; the id
--- prefix `rows()` otherwise falls back to names nothing a user would recognise.
local NEW_SESSION_TITLE = "New session"

---What to call a session in the list. A name the user gave it beats the CLI's
---generated title — renaming is the user saying the generated one was wrong —
---and the first prompt stands in until either exists.
---@param summary ClaudeCodeAgentsSummary|nil
---@return string|nil
local function display_title(summary)
  if not summary then
    return nil
  end
  return summary.name or summary.title or summary.first_prompt
end

---Take a freshly folded summary onto a row.
---
---One place, because three hand-written copies disagreed about what a fold
---refreshes: a background agent's row updated its counts but never its title or
---its position in the list, so a session renamed while another was selected kept
---showing its old name until the view was reopened.
---@param row table
---@param summary ClaudeCodeAgentsSummary
local function apply_summary(row, summary)
  row.title = display_title(summary) or row.title
  row.cwd = summary.cwd or row.cwd
  row.added = summary.added
  row.removed = summary.removed
  if summary.last_ts and summary.last_ts > 0 then
    row.last_ts = summary.last_ts
  end
  note_transcript_interrupt(row.session_id, summary)
  row.folded = true
end

---Every conversation running in a tab of its own, indexed by session id.
---
---`status.all()` allocates a copy of every entry, so asking it per row — twice
---per row, since `is_live` also falls through to it — rebuilt that table once
---for every session in the list on every frame. Built once and passed down.
---@return table<string, { state: string, tab: integer }>
local function foreign_index()
  local out = {}
  local ok, status = pcall(require, "claudecode.status")
  if not ok or not status.all then
    return out
  end
  for tab, entry in pairs(status.all()) do
    if entry.session_id and tab ~= state.tab then
      out[entry.session_id] = { state = entry.state, tab = tab }
    end
  end
  return out
end

---@param row table
---@param foreign table<string, table>|nil Prebuilt index; built on demand if absent.
---@return boolean
local function is_live(row, foreign)
  local registry = require("claudecode.agents.registry")
  if registry.is_live(row.session_id) then
    return true
  end
  if not opts().sessions or opts().sessions.foreign ~= false then
    -- A Claude started the normal way in another tab: it belongs to this project
    -- just as much, and calling it idle because we did not launch it would be a
    -- lie the user can see.
    foreign = foreign or foreign_index()
    return foreign[row.session_id] ~= nil
  end
  return false
end

---The state of a conversation running outside the agents view, if any.
---@param session_id string
---@return string|nil state
---@return integer|nil tab
function M.foreign_state(session_id)
  local entry = foreign_index()[session_id]
  if not entry then
    return nil
  end
  return entry.state, entry.tab
end

---Re-enumerate the project's transcripts and rebuild the rows.
---
---Stat-only, so it is cheap enough to run on a timer; the folding that fills in
---titles and counts happens separately and asynchronously.
function M.refresh_list()
  if not state.cwd then
    return
  end
  local listed = transcript.list(state.cwd)
  local limit = (opts().sessions and opts().sessions.limit) or 30

  local rows, by_id = {}, {}
  for index, entry in ipairs(listed) do
    if index > limit then
      break
    end
    local summary = entry.summary
    -- Kept across the rebuild so a title never goes backwards: a transcript that
    -- has just appeared is listed before it is folded, and dropping to the id
    -- prefix in between is a visible flicker on the row the user is watching —
    -- the one they just started. `apply_summary` keeps it the same way.
    local previous = state.by_id[entry.id]
    local row = {
      session_id = entry.id,
      path = entry.path,
      title = display_title(summary) or (previous and previous.title) or nil,
      cwd = summary and summary.cwd or state.cwd,
      -- Kept even for a partial summary: `rows()` gates on `folded`, so a count
      -- from a half-read transcript is carried but not shown.
      added = summary and summary.added or nil,
      removed = summary and summary.removed or nil,
      last_ts = (summary and summary.last_ts and summary.last_ts > 0) and summary.last_ts or entry.mtime,
      folded = summary ~= nil and not summary.partial,
    }
    rows[#rows + 1] = row
    by_id[row.session_id] = row
  end

  -- A conversation we are running that the enumeration cannot see yet.
  --
  -- The CLI writes the transcript on the first message, so a brand new agent is
  -- in no listing for as long as the user takes to type into it — and a list is
  -- the only way back to a conversation, so moving the selection off it once lost
  -- it entirely: still running, still holding a port and a terminal buffer, and
  -- unreachable. The registry knows everything a row needs about it (its id, the
  -- directory it runs in, and that it is running), so it is listed from there
  -- until the enumeration takes over.
  local registry = require("claudecode.agents.registry")
  for _, session_id in ipairs(registry.live_ids()) do
    if not by_id[session_id] then
      local term = registry.get(session_id)
      local row = {
        session_id = session_id,
        -- Where the CLI is about to write it. Nothing depends on the file being
        -- there — a fold simply finds nothing — but naming it now is what lets
        -- the panes fill in the moment it appears, rather than on the next scan.
        path = transcript.session_path((term and term.cwd) or state.cwd, session_id),
        title = NEW_SESSION_TITLE,
        cwd = (term and term.cwd) or state.cwd,
        -- It has changed nothing yet, and that is a fact rather than a gap: the
        -- unknown-count placeholder would claim its counts are still being read.
        added = 0,
        removed = 0,
        last_ts = os.time(),
        folded = true,
      }
      rows[#rows + 1] = row
      by_id[session_id] = row
    end
  end

  state.rows = rows
  state.by_id = by_id

  if state.selected and not by_id[state.selected] then
    state.selected = nil
  end
  M.fold_pending()
  notify_change()
end

---Fold a few unfolded transcripts per call, newest first.
---
---A mature project has a hundred of these and folding them all up front would
---stall the open. The list paints immediately from whatever the cache knows, and
---this fills in the rest a slice at a time.
function M.fold_pending()
  local batch = opts().fold_batch or 2
  local selected = state.selected

  -- The selected session always folds first: its feed and file list are on screen.
  if selected and state.by_id[selected] and not state.by_id[selected].folded then
    M.fold_row(state.by_id[selected])
    batch = batch - 1
  end

  for _, row in ipairs(state.rows) do
    if batch <= 0 then
      break
    end
    if not row.folded and not row.folding then
      M.fold_row(row)
      batch = batch - 1
    end
  end
end

---Keep folding until every row has its counts, a batch at a time.
---
---Without this the list stops after the first batch and the remaining sessions
---keep their placeholder counts and no title until something else happens to
---re-enumerate — which is why the list only appeared to fill in when a session
---was opened. Self-terminating: it stops scheduling once nothing is left.
local function schedule_fold()
  if state.fold_armed then
    return
  end
  for _, row in ipairs(state.rows) do
    if not row.folded and not row.folding and not row.fold_failed then
      state.fold_armed = true
      M._scheduler(function()
        state.fold_armed = false
        M.fold_pending()
      end, 10)
      return
    end
  end
end

---@param row table
function M.fold_row(row)
  if not row or row.folding then
    return
  end
  row.folding = true
  transcript.summary(row.path, function(summary)
    row.folding = false
    if not summary then
      -- Nothing to read (the file went away mid-scan). Remember, so the drain
      -- below does not come back to it forever.
      row.fold_failed = true
      schedule_fold()
      return
    end
    apply_summary(row, summary)
    notify_change()
    schedule_fold()
  end)
end

---Session rows for the renderer, decorated with live state and icons.
--------------------------------------------------------------------------------
-- Order
--------------------------------------------------------------------------------

--- What `gs` offers, in menu order.
---
--- `accel` is the single key that picks one, `desc` the direction the criterion
--- starts in, and `down`/`up` name that direction in the words of the thing being
--- sorted: "newest first" says what descending does to a timestamp without the
--- reader having to work it out, and it is not the same answer as "Z → A".
---@type { key: string, accel: string, label: string, desc: boolean, down: string, up: string }[]
M.SORTS = {
  { key = "recent", accel = "r", label = "Recent activity", desc = true, down = "newest first", up = "oldest first" },
  { key = "name", accel = "n", label = "Name", desc = false, down = "Z → A", up = "A → Z" },
  { key = "changes", accel = "c", label = "Changes", desc = true, down = "most first", up = "fewest first" },
  { key = "status", accel = "s", label = "Status", desc = true, down = "busy first", up = "idle first" },
}

--- `agents.sessions.sort` predates the menu and named two of these differently.
local SORT_ALIASES = { added = "changes", title = "name" }

--- Descending status order: what is asking you something outranks what is
--- working, which outranks what has finished and not been read.
local STATUS_RANK = { busy = 5, waiting = 4, done = 3, idle = 2, none = 1 }

---@param key string|nil
---@return table spec Falls back to the first criterion rather than to nothing.
function M.sort_spec(key)
  for _, spec in ipairs(M.SORTS) do
    if spec.key == key then
      return spec
    end
  end
  return M.SORTS[1]
end

---The active criterion, taken from `agents.sessions.sort` the first time it is
---asked for in an open view's lifetime.
---@return { key: string, desc: boolean }
local function sort_mode()
  if not state.sort then
    local configured = (opts().sessions and opts().sessions.sort) or "recent"
    local spec = M.sort_spec(SORT_ALIASES[configured] or configured)
    state.sort = { key = spec.key, desc = spec.desc }
  end
  return state.sort
end

---@param row table
---@param key string
---@return number|string
local function sort_value(row, key)
  if key == "name" then
    return (row.title or ""):lower()
  elseif key == "changes" then
    return (row.added or 0) + (row.removed or 0)
  elseif key == "status" then
    return STATUS_RANK[row.state] or 0
  end
  return row.last_ts or 0
end

---Does `a` belong above `b`?
---
---Ties fall through to the newest first and then to the id, so a criterion that
---leaves rows equal — a list of sessions that have all changed nothing, sorted
---by changes — still produces one order rather than whatever `table.sort` made
---of it that time.
---@param a table
---@param b table
---@param mode { key: string, desc: boolean }
---@return boolean
local function before(a, b, mode)
  local av, bv = sort_value(a, mode.key), sort_value(b, mode.key)
  if av ~= bv then
    if mode.desc then
      return av > bv
    end
    return av < bv
  end
  local at, bt = a.last_ts or 0, b.last_ts or 0
  if at ~= bt then
    return at > bt
  end
  return (a.session_id or "") < (b.session_id or "")
end

---Put the rows back in the order the list is already showing them in.
---
---This used to be a `table.sort` on every rebuild, and every criterion worth
---sorting by moves on its own: a background agent finishing one tool call bumps
---its `last_ts` and its counts, so with several sessions running the rows shuffle
---continuously under a stationary cursor and the one you were reaching for is
---somewhere else by the time you get there. The cursor is already anchored to its
---conversation rather than to its line, which stops the *selection* being wrong,
---but it cannot make a moving list readable.
---
---So the order is frozen: rows keep the places they were given, and only `gs` or
---an explicit refresh recomputes them. A session that appears afterwards is
---**sorted in once** — put where the active criterion says it goes at the moment
---it arrives — and pinned from then on. Appending instead would file every new
---agent at the bottom of a list sorted by recency, which is the one place it does
---not belong.
---
---`state.order` is rebuilt from the rows that are actually present, so a deleted
---conversation drops out of it here rather than needing its own cleanup.
---@param rows table[]
---@return table[]
local function apply_order(rows)
  local mode = sort_mode()
  local rank = {}
  for index, id in ipairs(state.order) do
    rank[id] = index
  end

  local known, fresh = {}, {}
  for _, row in ipairs(rows) do
    if rank[row.session_id] then
      known[#known + 1] = row
    else
      fresh[#fresh + 1] = row
    end
  end
  table.sort(known, function(a, b)
    return rank[a.session_id] < rank[b.session_id]
  end)
  -- Sorted among themselves first, so that inserting them one at a time leaves
  -- them in the right order relative to each other as well as to the frozen rows.
  table.sort(fresh, function(a, b)
    return before(a, b, mode)
  end)

  for _, row in ipairs(fresh) do
    local at = #known + 1
    for index = 1, #known do
      if before(row, known[index], mode) then
        at = index
        break
      end
    end
    table.insert(known, at, row)
  end

  state.order = {}
  for index, row in ipairs(known) do
    state.order[index] = row.session_id
  end
  return known
end

---The criterion the list is ordered by, as a copy.
---@return { key: string, desc: boolean }
function M.sort_mode()
  local mode = sort_mode()
  return { key = mode.key, desc = mode.desc }
end

---Sort the list again from the rows' current values, and freeze it there.
---
---What `r` does on top of re-reading the directory: an explicit refresh is the
---one moment a jumping list is what you asked for.
function M.resort()
  state.order = {}
  notify_change()
end

---Order by `key`, reversing it when it is already the active criterion — the
---menu has one entry per criterion, and picking it again is how you turn it
---round.
---@param key string
---@param desc boolean|nil Explicit direction. Omitted means "flip if this is
---            already the criterion, otherwise its own natural direction".
---@return { key: string, desc: boolean }
function M.set_sort(key, desc)
  local spec = M.sort_spec(SORT_ALIASES[key] or key)
  local mode = sort_mode()
  if desc == nil then
    if mode.key == spec.key then
      desc = not mode.desc
    else
      desc = spec.desc
    end
  end
  state.sort = { key = spec.key, desc = desc == true }
  state.order = {}
  notify_change()
  return M.sort_mode()
end

---@return table[]
function M.rows()
  local ok_status, status = pcall(require, "claudecode.status")
  -- Listing a conversation that edited nothing is the default: asking a question
  -- and reading the answer is still a session, and it is still resumable.
  local include_empty = not (opts().sessions and opts().sessions.include_empty == false)
  local foreign = foreign_index()
  local out = {}

  for _, row in ipairs(state.rows) do
    local live = is_live(row, foreign)
    local touched = (row.added or 0) > 0 or (row.removed or 0) > 0
    -- `not row.folded` keeps a session listed while its counts are still being
    -- read. That is only sound because empty sessions are listed by default: with
    -- `include_empty = false` a row does disappear once it is known to have
    -- changed nothing, which is exactly what that setting asks for.
    if include_empty or touched or live or not row.folded then
      local entry = state.status[row.session_id]
      -- Our own record of the conversation first; a Claude running in another tab
      -- next; "it is up but we have heard nothing from it" last.
      local session_state = (entry and entry.state)
        or (foreign[row.session_id] and foreign[row.session_id].state)
        or (live and "idle" or "none")

      local icon, group
      if ok_status and status.icon_for_state then
        icon, group = status.icon_for_state(session_state)
      end
      -- `status` draws nothing for a tab with no Claude, but a session list still
      -- needs a bullet in that column or the titles lose their left edge.
      if icon == "" then
        icon = nil
      end

      -- Two different things wear the same hollow bullet here, and `status`'s dim
      -- was on the wrong one. Dimming `idle` is right in a tabline, where a tab
      -- with no Claude draws nothing at all; in this list the stopped
      -- conversations are rows on screen too, and they came out at full strength
      -- while a live agent waiting for work was the faint one. So the dim marks
      -- "not running" and a running agent keeps the pane's own colour.
      if not live and (session_state == "none" or session_state == "idle") then
        group = require("claudecode.agents.render").highlight("stopped")
      elseif live and session_state == "idle" then
        group = nil
      end

      local added = row.folded and row.added or nil
      local removed = row.folded and row.removed or nil
      local added_age, removed_age = stamp_counts("session\0" .. row.session_id, added, removed)

      out[#out + 1] = {
        session_id = row.session_id,
        title = row.title or row.session_id:sub(1, 8),
        armed = armed[row.session_id] == true and not live,
        last_ts = row.last_ts,
        added = added,
        removed = removed,
        added_age_ms = added_age,
        removed_age_ms = removed_age,
        state = session_state,
        live = live,
        icon = icon or (live and "●" or "○"),
        hl = group,
        selected = state.selected == row.session_id,
      }
    end
  end

  return apply_order(out)
end

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

---@return string|nil
function M.selected()
  return state.selected
end

---@param session_id string|nil
function M.select(session_id)
  if state.selected == session_id then
    return
  end
  state.selected = session_id
  -- Arriving at a conversation is reading it: an answer that finished while you
  -- were looking elsewhere stops being unread here.
  if session_id then
    M.mark_read(session_id)
  end
  state.dirty.transcript = true
  state.dirty.git = true
  -- A different conversation's history arriving in the panes is not activity.
  reset_seen()
  local row = session_id and state.by_id[session_id]
  if row and not row.folded then
    M.fold_row(row)
  end
  notify_change()
end

---@param session_id string
---@return table|nil
function M.row(session_id)
  return state.by_id[session_id]
end

---Delete several conversations, and drop them from the list.
---
---The caller confirms; this only refuses what it can see is unsafe. A running
---agent is left alone because its CLI still has the file open — the view offers
---stopping it first.
---
---One re-enumeration for the whole batch, not one per transcript: the list is
---derived from a directory listing, so deleting a visual range of thirty rows
---would otherwise stat the store thirty times to arrive at the same answer.
---@param session_ids string[]
---@return string[] deleted The ids that are now gone.
---@return { session_id: string, err: string }[] failed
function M.delete_sessions(session_ids)
  local deleted, failed = {}, {}

  for _, session_id in ipairs(session_ids or {}) do
    local row = state.by_id[session_id]
    local err = nil
    if not row then
      err = "no such session"
    elseif is_live(row) then
      err = "the agent is still running"
    else
      local ok, delete_err = transcript.delete(row.path)
      if not ok then
        err = delete_err or "could not delete the transcript"
      end
    end

    if err then
      failed[#failed + 1] = { session_id = session_id, err = err }
    else
      deleted[#deleted + 1] = session_id
      if state.selected == session_id then
        state.selected = nil
        state.dirty.transcript = true
        state.dirty.git = true
      end
    end
  end

  if #deleted > 0 then
    -- Re-enumerating is what actually removes the rows: the list is derived from
    -- what is on disk, so dropping them here as well would only risk disagreeing.
    M.refresh_list()
  end
  return deleted, failed
end

---Delete one conversation.
---@param session_id string
---@return boolean ok
---@return string|nil err
function M.delete_session(session_id)
  local deleted, failed = M.delete_sessions({ session_id })
  if #deleted == 1 then
    return true, nil
  end
  return false, failed[1] and failed[1].err or "could not delete the session"
end

---Where a conversation's transcript lives — the only place its history exists.
---@param session_id string|nil Defaults to the selected session.
---@return string|nil path
function M.transcript_path(session_id)
  local row = state.by_id[session_id or state.selected or ""]
  return row and row.path or nil
end

---Activity events of the selected session, **newest first**.
---
---The store keeps them oldest-first, which is how they happened; the pane shows
---them the other way up, which is how they are read. What an agent is doing now
---is the question the pane answers, and appending puts that answer at the bottom
---edge — scrolled out of sight the moment the session has any history.
---`visible` is how many rows the pane can actually show. Everything past that is
---unreachable — the pane is drawn newest-first and a wholesale repaint resets any
---scroll — so building and stamping them is work thrown away on every frame. On
---real data that is ~240 rows down to ~40. `feed_limit` still bounds what the
---store keeps; this bounds what is drawn from it.
---@param visible integer|nil Rows the pane can show. Unbounded when omitted.
---@return table[] events The transcript's own tables, newest first.
---@return number[] ages Milliseconds each has been on screen, by position.
function M.feed(visible)
  local row = state.selected and state.by_id[state.selected]
  if not row then
    return {}, {}
  end
  local events = transcript.events(row.path)
  local limit = opts().feed_limit or 500
  if type(visible) == "number" and visible > 0 and visible < limit then
    limit = visible
  end
  local first = math.max(1, #events - limit + 1)
  local out = {}
  for index = #events, first, -1 do
    out[#out + 1] = events[index]
  end
  return out, stamp_feed(out)
end

---Files the selected session touched, with git's letter where we have one.
---
---The counts come from the transcript rather than git so this pane and the
---session row can never disagree; git only says what the file looks like on disk
---now, which is the part the transcript cannot know.
---@return table[]
function M.changes()
  local row = state.selected and state.by_id[state.selected]
  if not row then
    return {}
  end
  local summary = transcript.get(row.path)
  if not summary then
    return {}
  end

  local entries = {}
  for _, path in ipairs(summary.order or {}) do
    local file = summary.files[path]
    if file and file.kind ~= "read" then
      -- Keyed by session as well as path: the same file under a different
      -- conversation is a different set of counts, and comparing across the two
      -- would flash the whole pane on every selection change.
      local added_age, removed_age = stamp_counts("file\0" .. row.session_id .. "\0" .. path, file.added, file.removed)
      entries[#entries + 1] = {
        path = path,
        added = file.added,
        removed = file.removed,
        added_age_ms = added_age,
        removed_age_ms = removed_age,
        kind = file.kind,
        -- Keyed the way `git.parse_status` keys it: git answers with `/`
        -- separators whatever the platform, and this path is the CLI's own.
        status = state.git[require("claudecode.utils").path_key(path)] or (file.kind == "add" and "A" or "M"),
      }
    end
  end
  return entries
end

---@return string|nil cwd The directory the selected session ran in.
function M.selected_cwd()
  local row = state.selected and state.by_id[state.selected]
  return (row and row.cwd) or state.cwd
end

--------------------------------------------------------------------------------
-- Live updates
--------------------------------------------------------------------------------

--- Tools whose completion can change what is on disk.
local WRITING_TOOLS = { Edit = true, Write = true, MultiEdit = true, NotebookEdit = true }

---Where a finished turn lands: `idle` when the user was looking at that
---conversation as the answer arrived, `done` — finished but unread — when it
---landed somewhere they were not.
---
---The per-conversation analogue of the tab-level rule in `status`, and it takes
---all three of the same conditions: the session has to be the selected one (every
---pane follows the selection, so that is the only conversation on screen), the
---view's own tab has to be the current one, and Neovim has to have focus. Testing
---only the selection was wrong in the direction that matters — the agent you are
---waiting on is usually the selected one, and its answer arriving while you work
---in another tab is exactly the case the unread dot exists for.
---@param session_id string
---@param status table The `claudecode.status` module.
---@return ClaudeCodeStatusState
local function finished_state(session_id, status)
  if state.selected ~= session_id then
    return "done"
  end
  if status.is_focused and not status.is_focused() then
    return "done"
  end
  if state.tab then
    local ok, current = pcall(vim.api.nvim_get_current_tabpage)
    if not ok or current ~= state.tab then
      return "done"
    end
  end
  return "idle"
end

---Fold one Claude Code hook event into per-conversation state.
---@param event table Decoded hook payload.
function M.note(event)
  if type(event) ~= "table" then
    return
  end
  -- Not attached: nothing on screen is derived from this, `_flush` would early
  -- return anyway, and `state.status` is keyed by conversation and never pruned
  -- — so a long session with the view closed grew one entry per Claude it ever
  -- saw and classified every tool call of every agent for nothing.
  if not state.cwd then
    return
  end
  local session_id = type(event.session_id) == "string" and event.session_id or nil
  if not session_id then
    return
  end

  local ok, status = pcall(require, "claudecode.status")
  if ok and status.classify then
    local classified, info = status.classify(event, { finished = finished_state(session_id, status) })
    if classified then
      local previous = state.status[session_id]
      if not previous or previous.state ~= classified then
        state.status[session_id] = {
          state = classified,
          tool = info.tool,
          message = info.message,
          since = os.time(),
        }
      else
        previous.tool = info.tool
        previous.message = info.message
      end
    end
  end

  local ehn = event.hook_event_name
  local tool = event.tool_name
  if ehn == "PostToolUse" then
    -- PostToolUse, not Pre: the transcript's record of a tool is written when the
    -- tool returns.
    state.dirty.transcript = true
    if WRITING_TOOLS[tool] then
      state.dirty.git = true
    end
  elseif ehn == "Stop" or ehn == "SessionStart" or ehn == "SessionEnd" then
    state.dirty.transcript = true
    state.dirty.list = true
  end

  M.request_refresh()
end

---Note that the user interrupted one agent's turn.
---
---The per-conversation counterpart of `status.note_interrupt`, and it exists for
---the same measured reason: pressing `<Esc>` mid-turn fires no Claude Code hook
---at all, so a conversation stays `busy` until its next prompt and its row spins
---for ever. Only a `busy` conversation can be interrupted; anything else ignores
---the key, and a wrong guess is corrected by the next event.
---@param session_id string
---@return boolean noted
function M.note_interrupt(session_id)
  local entry = type(session_id) == "string" and state.status[session_id]
  if not entry or entry.state ~= "busy" then
    return false
  end
  entry.state = "idle"
  entry.tool = nil
  entry.message = nil
  entry.since = os.time()
  M.request_refresh()
  return true
end

---Mark a conversation's finished answer as read, which turns `done` into `idle`.
---
---The per-conversation counterpart of `status.mark_read`, and the other half of
---the `finished` rule in `note`: a turn that ends while its session is the one on
---screen lands in `idle` at once, and one that ends anywhere else lands in `done`
---— "finished, and you have not seen it" — until you come to it. Here, coming to
---it *is* selecting it: `<CR>` on the row, or cycling onto it with `<C-n>`/
---`<C-p>`, at which point every pane shows that conversation. Without this the
---filled dot never cleared, since nothing else in the view ever revisits a status
---entry. `waiting` is deliberately untouched, as in `status`: looking at a
---question is not answering it.
---@param session_id string
---@return boolean marked Whether a conversation actually went from `done` to `idle`.
function M.mark_read(session_id)
  local entry = type(session_id) == "string" and state.status[session_id]
  if not entry or entry.state ~= "done" then
    return false
  end
  entry.state = "idle"
  entry.tool = nil
  entry.message = nil
  entry.since = os.time()
  M.request_refresh()
  return true
end

---A running agent moved onto a different conversation (`/clear`, or a resume from
---inside the CLI).
---
---Only the state this module keeps *about a conversation* needs moving, and the
---honest move for the one being left is to forget it: it is not running any more,
---and whatever it was last doing — mid-tool, waiting on a permission prompt — it
---is not doing now. Dropping the entry lands its row on "not running" straight
---away rather than leaving a stale spinner on it until the `SessionEnd` for it
---arrives (a separate hook process, so its order against the `SessionStart` that
---brought us here is not guaranteed). The new conversation's own state comes from
---the same event, through `note`.
---@param previous string The id it was running until now.
---@param session_id string The id it reports now.
---@return boolean selected Whether the selection was pointing at the old id.
function M.note_session_change(previous, session_id)
  if type(previous) ~= "string" or type(session_id) ~= "string" then
    return false
  end
  state.status[previous] = nil
  -- A marker that has already been acted on belongs to the turn it ended, and
  -- that conversation is over; keeping it would only pin memory to an id nothing
  -- will report again.
  state.interrupted[previous] = nil
  state.dirty.list = true
  state.dirty.transcript = true
  return state.selected == previous
end

---@param session_id string
---@return table|nil
function M.status_of(session_id)
  return state.status[session_id]
end

---Ask for a redraw, at most one per `refresh_ms`.
function M.request_refresh()
  if state.armed then
    return
  end
  state.armed = true
  M._scheduler(function()
    state.armed = false
    M._flush()
  end, opts().refresh_ms or 150)
end

---Act on whatever went dirty since the last pass.
function M._flush()
  if not state.cwd then
    return
  end
  local dirty = state.dirty
  state.dirty = {}

  if dirty.list then
    M.refresh_list()
  end

  if dirty.transcript then
    local row = state.selected and state.by_id[state.selected]
    if row then
      transcript.summary(row.path, function(summary)
        if summary then
          apply_summary(row, summary)
          notify_change()
        end
      end)
    end
    -- A running agent's counts must move even while another session is selected.
    for _, other in ipairs(state.rows) do
      if other ~= row and is_live(other) then
        transcript.summary(other.path, function(summary)
          if summary then
            apply_summary(other, summary)
          end
        end)
      end
    end
  end

  if dirty.git and opts().git ~= false then
    M.refresh_git()
  end

  notify_change()
end

---Ask git for the status of the selected session's files.
---@param force boolean|nil Skip the rate gate (a manual refresh).
function M.refresh_git(force)
  if opts().git == false or not state.cwd then
    return
  end
  local now = os.time() * 1000
  local gate = opts().git_refresh_ms or 1500
  if not force and state.git_at and (now - state.git_at) < gate then
    return
  end
  state.git_at = now

  local entries = M.changes()
  if #entries == 0 then
    return
  end
  local paths = {}
  for _, entry in ipairs(entries) do
    paths[#paths + 1] = entry.path
  end

  local ok, git = pcall(require, "claudecode.agents.git")
  if not ok then
    return
  end
  git.status(state.cwd, paths, function(result)
    state.git = result or {}
    notify_change()
  end)
end

---The periodic tick: watch the transcripts, and re-enumerate the project.
---
---Re-enumeration is what notices a conversation started somewhere else — another
---tab, another editor, a bare terminal — and it is rate-limited separately from
---the content watch, since it is a directory scan rather than a read.
---@param tick_opts { list_only: boolean? }|nil When hooks already report content
---       changes, only the enumeration is wanted.
function M.poll(tick_opts)
  if not state.cwd then
    return
  end
  if not (tick_opts and tick_opts.list_only) then
    state.dirty.transcript = true
  end

  local now = (vim.loop and vim.loop.now()) or 0
  local gate = opts().list_refresh_ms or 2000
  if not state.list_at or (now - state.list_at) >= gate then
    state.list_at = now
    state.dirty.list = true
  end

  if next(state.dirty) then
    M.request_refresh()
  end
end

---Test/reload helper.
function M.reset()
  state = new_state()
end

---@return table
function M._state()
  return state
end

return M
