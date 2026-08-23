---@brief [[
--- Searching this project's conversations: the `gf` picker in the sessions pane.
---
--- The session list answers "what has run here"; it cannot answer "which of these
--- was the one about the websocket handshake". The transcripts hold that, so this
--- reads them — the message text, the paths the session touched, and the title —
--- and offers the sessions whose text matches. Choosing one selects it and puts
--- you in it.
---
--- Two windows rather than one: the query is a buffer you type into, and the
--- results are a buffer we paint. A single buffer cannot be both, and the input
--- has to stay a real Neovim buffer so every editing key the user knows still
--- works in it. The cursor never leaves the input; `<C-n>`/`<C-p>` drive the
--- list's cursor from there, which is why the list window is never entered.
---
--- **No index and no cache.** Every query past the debounce re-reads the store
--- through `transcript.search`, which is cheap because the prefilter runs on the
--- raw JSON line — most lines are never decoded — and because a scan stops at the
--- match cap for that session. The run is cancelled on the next keystroke, so a
--- query typed a character at a time costs one scan, not one per character.
---
--- Scans run `CONCURRENCY` at a time but results are stored **by session
--- position**, so the list is in the sessions pane's own order however the reads
--- finish. A session that arrives late appears in its place rather than at the
--- bottom, and the cursor is anchored to its session across those repaints for the
--- reason the sessions pane anchors its own: a row that moves under the cursor is
--- a row you act on by accident.
---
--- **The search is not bounded by the list.** The sessions pane shows a window of
--- recent work; the conversation you are looking for is very often the one that
--- fell out of it, which is why you are searching rather than reading. So `<Tab>`
--- cycles what is read: the rows on screen, every conversation this project has
--- ever had, or every conversation on this machine. It opens on the project,
--- because "somewhere in this project" is what the question almost always means,
--- and the choice lasts as long as the view does.
---
--- Order follows that: the sessions already on screen keep the pane's own order at
--- the top, and everything reached past it follows newest first.
---@brief ]]
---@module 'claudecode.agents.search'

local M = {}

local render = require("claudecode.agents.render")
local transcript = require("claudecode.agents.transcript")
local utils = require("claudecode.utils")

--- Transcripts read at once. Reads are latency-bound, so a few in flight is much
--- faster than one at a time; more than a few only queues syscalls.
local CONCURRENCY = 4

local DEFAULT_DEBOUNCE_MS = 150
local DEFAULT_LIMIT = 3

--- What the role of a matching line is called in the list.
local ROLE_LABEL = { user = "you", assistant = "claude" }

---What a match is labelled with: who said it, or what it was part of.
---
---A tool call is labelled with the tool, lowercased to sit with the other labels
---rather than shout over them — `bash`, `edit`, `write` read as a column of
---metadata, `Bash` reads as a heading.
---@param match table
---@return string
function M.label(match)
  if match.kind == "file" then
    return "file"
  end
  if match.kind == "tool" then
    return type(match.tool) == "string" and match.tool:lower() or "tool"
  end
  if match.kind == "thinking" then
    return "think"
  end
  return ROLE_LABEL[match.role] or ""
end

--- The open picker.
---@type table|nil
local shown = nil

--- How much of the store a scan reads, in `<Tab>` order.
---
--- `visible` is the rows the sessions pane is showing, which is the cheapest scan
--- and the only one that cannot answer "which conversation was that" for work
--- older than the pane's window. `disk` reaches every project the CLI has ever run
--- in; a hit there names a conversation from another directory, which is resumed
--- in the directory it ran in rather than in this one.
---@type { key: string, label: string }[]
M.SCOPES = {
  { key = "visible", label = "listed" },
  { key = "project", label = "project" },
  { key = "disk", label = "everywhere" },
}

local DEFAULT_SCOPE = "project"

--- Sessions drawn at once. A `disk` scan can match in hundreds of conversations,
--- and a list nobody can read to the end of is not worth the repaint — the answer
--- to "too many" is a better query, which the count in the border asks for.
local MAX_LISTED = 60

--- The query survives the picker, but not the view: reopening with `gf` starts
--- from what you last searched for, pre-selected, so refining after a look at a
--- session costs nothing. The scope is remembered the same way and for the same
--- reason — a second `gf` is usually the same search, widened.
local last_query = ""
local last_scope = DEFAULT_SCOPE

---@return string
function M.last_query()
  return last_query
end

---@return string
function M.last_scope()
  return last_scope
end

---Forget the remembered query and scope. Called when the view closes, so the next
---open starts clean rather than with a search from a previous sitting.
function M.reset()
  last_query = ""
  last_scope = DEFAULT_SCOPE
end

---@param name string
---@return string
local function hl(name)
  return render.highlight(name)
end

--------------------------------------------------------------------------------
-- What gets read
--------------------------------------------------------------------------------

---What a conversation the pane is not showing is called, before anything is read.
---
---The warm cache often knows already — every session the view has folded is in it
---— and the id prefix is what the sessions pane itself falls back to.
---@param entry table
---@return string
local function offlist_title(entry)
  local sum = entry.summary or transcript.get(entry.path)
  local title = sum and (sum.name or sum.title or sum.first_prompt)
  if type(title) == "string" and title ~= "" then
    return title
  end
  return entry.id:sub(1, 8)
end

---The sessions a scope reads, in the order the list shows them.
---
---The pane's rows first, in the pane's own order — those are the ones the user has
---just been looking at, and a search that reshuffles them reads as a different
---list. Everything reached past them follows by recency, which is the only order
---available for a conversation nothing on screen has an opinion about.
---@param opts table The picker's options: `sessions` (the pane's rows) and `cwd`.
---@param scope string
---@return table[]
function M.sessions_for(opts, scope)
  local visible = opts.sessions or {}
  local out, seen = {}, {}
  for _, session in ipairs(visible) do
    out[#out + 1] = session
    seen[session.session_id] = true
  end
  if scope == "visible" then
    return out
  end

  local cwd = opts.cwd
  local project_dir = cwd and transcript.project_dir(cwd) or nil
  if cwd then
    for _, entry in ipairs(transcript.list(cwd)) do
      if not seen[entry.id] then
        seen[entry.id] = true
        out[#out + 1] = {
          session_id = entry.id,
          title = offlist_title(entry),
          path = entry.path,
          cwd = cwd,
        }
      end
    end
  end

  if scope == "disk" then
    for _, entry in ipairs(transcript.list_all()) do
      if not seen[entry.id] then
        seen[entry.id] = true
        out[#out + 1] = {
          session_id = entry.id,
          title = offlist_title(entry),
          path = entry.path,
          -- Read from the transcript only if this one turns out to matter: the
          -- directory is what a hit is resumed in, and a `disk` scan enumerates
          -- far more conversations than it ever lists.
          foreign = entry.dir ~= project_dir,
        }
      end
    end
  end

  return out
end

---The directory a foreign session ran in, and how it reads in a list.
---
---Both are read on demand and kept on the session: `cwd_of` opens the file, and a
---repaint must not do that for every row it draws.
---@param session table
---@return string|nil cwd
---@return string|nil label
local function foreign_project(session)
  if session.project_label ~= nil then
    return session.cwd, session.project_label or nil
  end
  local cwd = session.cwd or (session.path and transcript.cwd_of(session.path))
  session.cwd = cwd
  session.project_label = cwd and vim.fn.fnamemodify(cwd, ":t") or false
  return cwd, session.project_label or nil
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

---Stop every scan in flight.
---@param state table
local function cancel_scans(state)
  for _, job in ipairs(state.jobs) do
    pcall(job.cancel)
  end
  state.jobs = {}
end

--- How often the list repaints while a scan streams into it. One repaint per
--- transcript is right for the thirty a pane shows and wrong for the several
--- hundred a `disk` scan reads — the paint is the whole list, so the cost is
--- quadratic in what is on screen. Coalescing is invisible at this rate and turns
--- that back into a fixed frame budget.
local REDRAW_MS = 60

---@param state table
local function stop_redraw_timer(state)
  if state.redraw_timer then
    pcall(function()
      state.redraw_timer:stop()
      state.redraw_timer:close()
    end)
    state.redraw_timer = nil
  end
end

---Repaint soon, and only once however many results land in the meantime.
---@param state table
local function request_redraw(state)
  if state.redraw_timer then
    return
  end
  local timer = vim.loop and vim.loop.new_timer()
  if not timer then
    M.redraw()
    return
  end
  state.redraw_timer = timer
  timer:start(
    REDRAW_MS,
    0,
    vim.schedule_wrap(function()
      if shown ~= state then
        return
      end
      stop_redraw_timer(state)
      M.redraw()
    end)
  )
end

---Run `query` against the session list, calling `on_update` as results land.
---@param state table
local function start_scan(state)
  cancel_scans(state)
  state.results = {}
  state.scanned = 0
  state.done = true

  local matcher = transcript.compile_query(state.query)
  state.matcher = matcher
  if not matcher then
    M.redraw()
    return
  end

  state.done = false
  -- The generation is what makes a cancelled scan silent: `transcript.search`
  -- drops a cancelled job's callback, but a callback already scheduled when the
  -- next query starts would otherwise paint into the new run's results.
  state.generation = state.generation + 1
  local generation = state.generation

  local sessions = state.sessions
  for index, session in ipairs(sessions) do
    -- The title is in hand, so it is matched here rather than read for. A session
    -- whose *name* matches is listed even when nothing in the conversation does.
    local s, e = matcher.find(session.title or "")
    if s then
      state.results[index] = { title = { col = s - 1, len = e - s + 1 }, matches = {} }
    end
  end

  local next_index = 1
  local running = 0

  local function pump()
    while running < CONCURRENCY and next_index <= #sessions do
      local index = next_index
      next_index = index + 1
      local session = sessions[index]
      if session.path then
        running = running + 1
        local job = transcript.search(session.path, matcher, { limit = state.limit }, function(matches)
          if state.generation ~= generation then
            return
          end
          running = running - 1
          state.scanned = state.scanned + 1
          if #matches > 0 then
            local entry = state.results[index] or { matches = {} }
            entry.matches = matches
            state.results[index] = entry
          end
          request_redraw(state)
          pump()
        end)
        state.jobs[#state.jobs + 1] = job
      else
        -- A conversation the CLI has not written a transcript for yet (a brand new
        -- agent). There is nothing to read; its title has already been matched.
        state.scanned = state.scanned + 1
      end
    end
    if running == 0 and next_index > #sessions then
      state.done = true
      -- The last paint is immediate: "no matches" arriving a frame late reads as
      -- the picker having stopped answering.
      stop_redraw_timer(state)
      M.redraw()
    end
  end

  pump()
  M.redraw()
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

---Lines, highlights and per-line payloads for the current results.
---@param state table
---@return string[] lines
---@return table[] marks
---@return table<integer, table> rows
function M.render(state)
  local lines, marks, rows = {}, {}, {}

  local function push(text, spans, payload)
    lines[#lines + 1] = text
    rows[#lines] = payload
    for _, span in ipairs(spans or {}) do
      if span.hl and span.to > span.from then
        marks[#marks + 1] = { row = #lines - 1, col = span.from, end_col = span.to, hl = span.hl }
      end
    end
  end

  if not state.matcher then
    local invite = " type to search " .. M.scope_blurb(state.scope) .. "   <Tab> widens"
    push(invite, { { from = 1, to = #invite, hl = hl("time") } }, nil)
    return lines, marks, rows
  end

  local listed, skipped = 0, 0
  for index, session in ipairs(state.sessions) do
    local result = state.results[index]
    if result and listed >= MAX_LISTED then
      skipped = skipped + 1
    elseif result then
      listed = listed + 1
      local title = session.title or ""
      local icon = session.icon or "○"
      local prefix = " " .. icon .. " "
      local spans = {
        { from = 1, to = 1 + #icon, hl = session.hl },
        { from = #prefix, to = #prefix + #title, hl = hl("title") },
      }
      if result.title then
        spans[#spans + 1] = {
          from = #prefix + result.title.col,
          to = #prefix + result.title.col + result.title.len,
          hl = hl("match"),
        }
      end
      local line = prefix .. title
      -- A conversation from another project is one you can still resume, but only
      -- where it ran — so the row says where that is rather than leaving the user
      -- to find out by opening it.
      if session.foreign then
        local _, label = foreign_project(session)
        if label then
          local note = "  · " .. label
          spans[#spans + 1] = { from = #line, to = #line + #note, hl = hl("time") }
          line = line .. note
        end
      end
      push(line, spans, { session_id = session.session_id, index = index })

      for _, match in ipairs(result.matches) do
        local label = M.label(match)
        local indent = "     "
        local gap = string.rep(" ", math.max(1, 8 - #label))
        local text = match.text or ""
        local at = #indent + #label + #gap
        push(indent .. label .. gap .. text, {
          { from = #indent, to = #indent + #label, hl = hl(match.kind == "file" and "path" or "kind") },
          { from = at + match.col, to = at + match.col + match.len, hl = hl("match") },
        }, { session_id = session.session_id, index = index })
      end
    end
  end

  if skipped > 0 then
    local text = "  " .. skipped .. " more conversations match — narrow the search"
    push(text, { { from = 0, to = #text, hl = hl("time") } }, nil)
  end

  if #lines == 0 then
    local text = state.done and " no conversation here mentions that" or " searching…"
    push(text, { { from = 1, to = #text, hl = hl("time") } }, nil)
  end
  return lines, marks, rows
end

---How a scope reads in a sentence.
---@param scope string|nil
---@return string
function M.scope_blurb(scope)
  if scope == "visible" then
    return "the conversations listed"
  end
  if scope == "disk" then
    return "every conversation on this machine"
  end
  return "this project's conversations"
end

---How a scope reads in the border, where there is room for one word.
---@param scope string|nil
---@return string
local function scope_label(scope)
  for _, spec in ipairs(M.SCOPES) do
    if spec.key == (scope or DEFAULT_SCOPE) then
      return spec.label
    end
  end
  return DEFAULT_SCOPE
end

---What the list's border says: which scope is being read, how far the scan has
---got, and what it found.
---@param state table
---@return string
local function status_title(state)
  local scope = scope_label(state.scope)
  if not state.matcher then
    return " " .. scope .. " · " .. tostring(#state.sessions) .. " conversations "
  end
  local sessions, matches = 0, 0
  for _, result in pairs(state.results) do
    sessions = sessions + 1
    matches = matches + #result.matches + (result.title and 1 or 0)
  end
  local found = sessions == 0 and "nothing yet" or (sessions .. " sessions · " .. matches .. " matches")
  if state.done then
    return " " .. scope .. " · " .. (sessions == 0 and "no matches" or found) .. " "
  end
  return " " .. scope .. " · " .. found .. " · " .. state.scanned .. "/" .. #state.sessions .. " "
end

---@param state table
local function apply_title(state)
  if not (state.list_win and vim.api.nvim_win_is_valid(state.list_win)) then
    return
  end
  local config = vim.deepcopy(state.list_config)
  config.title = status_title(state)
  pcall(vim.api.nvim_win_set_config, state.list_win, config)
end

---Put the list's cursor back on the session it was on, or on the first row.
---@param state table
local function place_cursor(state)
  if not (state.list_win and vim.api.nvim_win_is_valid(state.list_win)) then
    return
  end
  local rows = state.rows or {}
  local target = nil
  if state.cursor_session then
    for lnum, payload in pairs(rows) do
      if payload and payload.session_id == state.cursor_session and (not target or lnum < target) then
        target = lnum
      end
    end
  end
  if not target then
    for lnum = 1, state.line_count do
      if rows[lnum] then
        target = lnum
        break
      end
    end
  end
  if not target then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, state.list_win, { target, 0 })
  local payload = rows[target]
  M.preview(payload and payload.session_id, payload and payload.index)
end

---Repaint the list from the current results.
function M.redraw()
  local state = shown
  if not state or not (state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf)) then
    return
  end
  local lines, marks, rows = M.render(state)
  state.rows = rows
  state.line_count = #lines
  render.paint(state.list_buf, lines, marks, rows)
  apply_title(state)
  place_cursor(state)
end

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

---What the caller needs to know about a session it has no row for: where its
---transcript is, and which directory it ran in.
---@param state table
---@param index integer|nil
---@return table|nil
local function session_info(state, index)
  local session = index and state.sessions[index]
  if not session then
    return nil
  end
  local cwd = session.cwd
  if session.foreign then
    cwd = foreign_project(session) or cwd
  end
  return {
    path = session.path,
    cwd = cwd or state.opts.cwd,
    title = session.title,
    foreign = session.foreign == true,
  }
end

---Preview a session, at most once per session: the panes follow the highlighted
---row, and every repaint would otherwise re-select the same conversation.
---@param session_id string|nil
---@param index integer|nil Where it is in the scanned list, for its path and cwd.
function M.preview(session_id, index)
  local state = shown
  if not state or not session_id or state.previewed == session_id then
    return
  end
  state.previewed = session_id
  state.cursor_session = session_id
  if state.opts.on_preview then
    pcall(state.opts.on_preview, session_id, session_info(state, index))
  end
end

---Read the store more widely, or less: the rows on screen, the whole project, or
---every project. The scan restarts against the new set, and the choice is what the
---next `gf` opens with.
---@param delta integer
function M.cycle_scope(delta)
  local state = shown
  if not state then
    return
  end
  local at = 1
  for index, spec in ipairs(M.SCOPES) do
    if spec.key == state.scope then
      at = index
    end
  end
  at = ((at - 1 + (delta or 1)) % #M.SCOPES) + 1
  state.scope = M.SCOPES[at].key
  last_scope = state.scope
  state.sessions = M.sessions_for(state.opts, state.scope)
  if state.matcher then
    start_scan(state)
  else
    M.redraw()
  end
end

---Move the list's cursor, and preview what it lands on.
---@param delta integer
function M.move(delta)
  local state = shown
  if not state or not (state.list_win and vim.api.nvim_win_is_valid(state.list_win)) then
    return
  end
  local rows = state.rows or {}
  local lnum = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local at = lnum
  for _ = 1, state.line_count do
    at = at + delta
    if at < 1 then
      at = state.line_count
    elseif at > state.line_count then
      at = 1
    end
    if rows[at] then
      pcall(vim.api.nvim_win_set_cursor, state.list_win, { at, 0 })
      M.preview(rows[at].session_id, rows[at].index)
      return
    end
  end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---@param state table
local function stop_timer(state)
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
    state.timer = nil
  end
end

---Leave the insert mode the picker put us in.
---
---The query is a buffer you type into, so opening the picker means `startinsert`
---— and **closing a window does not end insert mode**. Focus fell back to the
---sessions pane still in insert, on a buffer nothing can be typed into. Verified
---through a pty, since a headless `-l` Neovim never enters insert to begin with:
---`in picker: i` / `after esc: i`.
---
---Guarded rather than unconditional, because the two ways out of the picker land
---in different places. `<CR>` goes on to focus an agent's terminal, and the
---click-away path has already moved the cursor by the time this runs — dropping a
---terminal out of insert because a float closed is the bug this is the mirror of
---(see `float.lua`, which restores that mode for the same reason).
function M._leave_insert()
  if not tostring(vim.fn.mode()):find("^i") then
    return false
  end
  local ok, buftype = pcall(vim.api.nvim_get_option_value, "buftype", { buf = 0 })
  if ok and buftype == "terminal" then
    return false
  end
  pcall(vim.cmd, "stopinsert")
  return true
end

---Close the picker. Answers `on_cancel` unless a choice was made.
---@param committed boolean|nil
function M.close(committed)
  local state = shown
  shown = nil
  if not state then
    return
  end
  stop_timer(state)
  stop_redraw_timer(state)
  cancel_scans(state)
  -- Whatever is in the input when it goes away is what `gf` reopens with.
  last_query = state.query or ""
  M._leave_insert()

  for _, win in ipairs({ state.input_win, state.list_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.input_buf, state.list_buf }) do
    if buf then
      -- The payload table is keyed by buffer number, which Neovim reuses; a dead
      -- buffer left in it would hand its rows to whatever buffer is created next.
      render.forget(buf)
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end

  if not committed and state.opts.on_cancel then
    pcall(state.opts.on_cancel)
  end
end

---@return boolean
function M.is_open()
  return shown ~= nil and shown.input_win ~= nil and vim.api.nvim_win_is_valid(shown.input_win)
end

---Choose the row under the list's cursor.
function M.accept()
  local state = shown
  if not state then
    return
  end
  local rows = state.rows or {}
  local lnum = state.list_win
      and vim.api.nvim_win_is_valid(state.list_win)
      and vim.api.nvim_win_get_cursor(state.list_win)[1]
    or 1
  local payload = rows[lnum]
  local session_id = payload and payload.session_id
  local info = session_info(state, payload and payload.index)
  local on_accept = state.opts.on_accept
  M.close(true)
  if session_id and on_accept then
    -- Out of the closing keymap, like the sort menu and the confirm dialog: the
    -- windows are still going away, and accepting opens windows of its own.
    vim.schedule(function()
      pcall(on_accept, session_id, info)
    end)
  end
end

---The query changed: restart the scan once typing settles.
local function on_change()
  local state = shown
  if not state or not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then
    return
  end
  local line = (vim.api.nvim_buf_get_lines(state.input_buf, 0, 1, false) or {})[1] or ""
  if line == state.query then
    return
  end
  state.query = line
  -- A new query means a new list, so nothing is highlighted until it has results.
  state.cursor_session = nil
  stop_timer(state)
  local timer = vim.loop and vim.loop.new_timer()
  if not timer then
    start_scan(state)
    return
  end
  state.timer = timer
  timer:start(
    state.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if shown == state then
        stop_timer(state)
        start_scan(state)
      end
    end)
  )
end

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

---@param win integer
local function float_highlight(win)
  utils.set_win_option(win, "winhighlight", "FloatBorder:" .. hl("float"))
end

---@param state table
---@return boolean ok
local function open_windows(state)
  local columns = vim.o.columns or 80
  local rows = vim.o.lines or 24
  local width = math.max(40, math.min(math.floor(columns * 0.7), columns - 8))
  -- Tall: a session takes a header plus up to `max_per_session` match lines, so
  -- fifteen rows showed three conversations. The fraction is what binds on a
  -- normal terminal; the cap only keeps it off the very edges of a tall one.
  local height = math.max(5, math.min(40, math.floor(rows * 0.65)))
  -- Input (1 line + 2 border) above the list (height + 2 border), centred as one
  -- block so the pair reads as a single window with a rule through it.
  local total = 3 + height + 2
  local row = math.max(0, math.floor((rows - total) / 2))
  local col = math.max(0, math.floor((columns - width) / 2))

  state.input_buf = vim.api.nvim_create_buf(false, true)
  state.list_buf = vim.api.nvim_create_buf(false, true)
  if not state.input_buf or not state.list_buf then
    return false
  end
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = state.input_buf })
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = state.list_buf })
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-search", { buf = state.input_buf })
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-search", { buf = state.list_buf })
  pcall(vim.api.nvim_buf_set_lines, state.input_buf, 0, -1, false, { state.query })

  state.list_config = {
    relative = "editor",
    width = width,
    height = height,
    row = row + 3,
    col = col,
    style = "minimal",
    border = "rounded",
    title = "",
    title_pos = "right",
    zindex = 60,
    focusable = false,
  }
  local ok_list, list_win = pcall(vim.api.nvim_open_win, state.list_buf, false, state.list_config)
  if not ok_list or not list_win then
    return false
  end
  state.list_win = list_win
  utils.set_win_option(list_win, "cursorline", true)
  utils.set_win_option(list_win, "wrap", false)
  float_highlight(list_win)

  local ok_input, input_win = pcall(vim.api.nvim_open_win, state.input_buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Search conversations ",
    title_pos = "center",
    zindex = 61,
  })
  if not ok_input or not input_win then
    return false
  end
  state.input_win = input_win
  utils.set_win_option(input_win, "wrap", false)
  float_highlight(input_win)
  return true
end

---@param state table
local function bind_keys(state)
  local buf = state.input_buf
  local function map(modes, lhs, fn, desc)
    pcall(vim.keymap.set, modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  -- `<C-j>`/`<C-k>` alongside `<C-n>`/`<C-p>`: the view's own cycling keys are
  -- the n/p pair, and the j/k pair is the one the hands reach for in a list.
  for _, lhs in ipairs({ "<C-n>", "<C-j>", "<Down>" }) do
    map({ "i", "n" }, lhs, function()
      M.move(1)
    end, "Claude agents: next search result")
  end
  for _, lhs in ipairs({ "<C-p>", "<C-k>", "<Up>" }) do
    map({ "i", "n" }, lhs, function()
      M.move(-1)
    end, "Claude agents: previous search result")
  end
  map({ "i", "n" }, "<CR>", function()
    M.accept()
  end, "Claude agents: open the highlighted conversation")
  map({ "i", "n" }, "<Tab>", function()
    M.cycle_scope(1)
  end, "Claude agents: search more of the store (listed / project / everywhere)")
  map({ "i", "n" }, "<S-Tab>", function()
    M.cycle_scope(-1)
  end, "Claude agents: search less of the store")
  for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
    map({ "i", "n" }, lhs, function()
      M.close(false)
    end, "Claude agents: cancel the search")
  end
end

---@param state table
local function bind_autocmds(state)
  local group = vim.api.nvim_create_augroup("ClaudeCodeAgentsSearch", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = state.input_buf,
    callback = on_change,
  })
  -- Leaving the input is leaving the picker: the list is not focusable, so there
  -- is nowhere inside it to go. Cancelling rather than committing is what makes
  -- clicking away the same answer as `<Esc>`.
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = state.input_buf,
    callback = function()
      vim.schedule(function()
        if shown == state and vim.api.nvim_get_current_win() ~= state.input_win then
          M.close(false)
        end
      end)
    end,
  })
end

---Open the picker.
---
---A second `gf` while it is open closes it, so the key that summoned it dismisses
---it — the same rule the sort menu and the help window follow.
---@param opts { sessions: table[], cwd: string|nil, scope: string|nil, limit: integer|nil, debounce_ms: integer|nil, query: string|nil, on_preview: fun(session_id: string, info: table|nil)|nil, on_accept: fun(session_id: string, info: table|nil)|nil, on_cancel: fun()|nil }
---@return boolean shown
function M.open(opts)
  if M.is_open() then
    M.close(false)
    return false
  end
  if type(opts) ~= "table" or type(opts.sessions) ~= "table" then
    return false
  end

  local scope = opts.scope or last_scope
  local state = {
    opts = opts,
    scope = scope,
    sessions = M.sessions_for(opts, scope),
    query = opts.query or "",
    limit = opts.limit or DEFAULT_LIMIT,
    debounce_ms = opts.debounce_ms or DEFAULT_DEBOUNCE_MS,
    results = {},
    rows = {},
    jobs = {},
    generation = 0,
    scanned = 0,
    line_count = 0,
    done = true,
  }

  last_scope = scope
  shown = state
  if not open_windows(state) then
    M.close(true)
    return false
  end
  bind_keys(state)
  bind_autocmds(state)

  -- `startinsert!` rather than `startinsert`: past the end of the remembered
  -- query, so typing continues it and `<C-u>` clears it. The scan for it starts
  -- at once rather than on the first keystroke, so reopening a remembered query
  -- shows the results it closed with.
  vim.cmd("startinsert!")
  if state.query ~= "" then
    start_scan(state)
  else
    M.redraw()
  end
  return true
end

return M
