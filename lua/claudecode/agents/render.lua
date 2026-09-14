---@brief [[
--- Drawing for the agents view's three sidebars.
---
--- Each pane is a read-only scratch buffer whose lines are rebuilt wholesale and
--- coloured with extmarks. Extmarks rather than string padding because the counts
--- and the status dot need their own highlights, and rather than a syntax file
--- because these lines have no grammar — they are records, and the renderer
--- already knows which byte range is which field.
---
--- Alongside the lines, each render records what each row *is* (`payload_at`), so
--- a keymap can act on the thing under the cursor without re-parsing the text it
--- just drew.
---@brief ]]
---@module 'claudecode.agents.render'

local fade = require("claudecode.agents.fade")
local tools = require("claudecode.agents.tools")
local utils = require("claudecode.utils")

local M = {}

local NS = "claudecode_agents"
local ns_id = nil

--- Every pane line starts with a blank cell.
---
--- Two reasons, and the second is the one that made it non-negotiable. It gives
--- the lists breathing room from the window edge — and it puts *whitespace under
--- a resting cursor*. A word-highlight plugin (mini.cursorword, vim-illuminate,
--- local-highlight) paints every other occurrence of the word the cursor is on,
--- and with the cursor parked in column 1 of a list that meant every row sharing
--- a timestamp or a status letter lit up as you moved down it. Those plugins all
--- stand down over whitespace, so a gutter turns the behaviour off for all of
--- them at once, including ones we have never heard of. `create_buf` also sets
--- mini.cursorword's own opt-out, which is the exact fix for the one we know.
---
--- The Changes pane already began with a blank cell (the status letter is
--- padded), so only Sessions and Activity gained one.
local GUTTER = " "

--- What sits in the gutter of the selected session instead of the blank cell.
--- One cell wide, so no column moves; punctuation, so the word-highlight plugins
--- the gutter exists to appease still stand down over it. The line highlight
--- alone was not enough to say which row is selected — the list re-sorts as
--- agents work, and `cursorline` paints a line the same way, so two rows can look
--- alike. A glyph in column 0 says it without depending on colour at all.
local SELECTED_MARK = "❯"

--- Agents config subtable.
---@type table|nil
local config = nil

--- [bufnr] = { [lnum] = payload }
local payloads = {}

--- [bufnr] = { lines, marks, tick } — what the last paint put there, so a repaint
--- that would change nothing can be skipped.
local painted = {}

local DEFAULT_HIGHLIGHTS = {
  title = "ClaudeCodeAgentsTitle",
  time = "ClaudeCodeAgentsTime",
  added = "ClaudeCodeAgentsAdded",
  removed = "ClaudeCodeAgentsRemoved",
  selected = "ClaudeCodeAgentsSelected",
  path = "ClaudeCodeAgentsPath",
  kind = "ClaudeCodeAgentsKind",
  stopped = "ClaudeCodeAgentsStopped",
  deleted = "ClaudeCodeAgentsDeleted",
  failed = "ClaudeCodeAgentsFailed",
  float = "ClaudeCodeAgentsFloat",
  normal = "ClaudeCodeAgentsNormal",
  normal_nc = "ClaudeCodeAgentsNormalNC",
  header = "ClaudeCodeAgentsHelpHeader",
  key = "ClaudeCodeAgentsKey",
  match = "ClaudeCodeAgentsMatch",
}

local HIGHLIGHT_LINKS = {
  ClaudeCodeAgentsTitle = "Normal",
  ClaudeCodeAgentsTime = "Comment",
  ClaudeCodeAgentsAdded = "DiffAdd",
  ClaudeCodeAgentsRemoved = "DiffDelete",
  ClaudeCodeAgentsSelected = "CursorLine",
  ClaudeCodeAgentsPath = "Directory",
  -- The `read`/`edit` column is metadata like the clock beside it, not content,
  -- so it follows the clock's group. Left unhighlighted it fell through to
  -- `Normal` — the brightest thing in the pane, and the one span the fade could
  -- not reach, so a settled row still had a white label on it.
  ClaudeCodeAgentsKind = "Comment",
  -- The bullet of a session that is not running. `status` has no group for it —
  -- a tabline draws nothing at all for a tab with no Claude — but here those
  -- sessions are rows on screen, and they are the ones that should read quietest.
  ClaudeCodeAgentsStopped = "Comment",
  -- A changed file that is no longer on disk. Its row stays — the session did
  -- that work, and the counts still add up to the session's own — but it is
  -- the quietest thing in the pane, with the `D` beside it saying why.
  ClaudeCodeAgentsDeleted = "Comment",
  -- A tool call the CLI marked `is_error`. The one thing in the pane that is not
  -- a neutral record of work, so it borrows the editor's own error colour.
  ClaudeCodeAgentsFailed = "DiagnosticError",
  ClaudeCodeAgentsFloat = "FloatBorder",
  ClaudeCodeAgentsHelpHeader = "Title",
  ClaudeCodeAgentsKey = "Special",
  -- What the search picker lights up inside a result. `Search` rather than
  -- `IncSearch`: these are the matches, not the one being stepped onto.
  ClaudeCodeAgentsMatch = "Search",
}

---Where the panes take their background from.
---
---snacks paints its windows `Normal:SnacksNormal`, and `SnacksNormal` links to
---`NormalFloat`. Following the snacks group when it exists means a colorscheme
---that restyles snacks restyles these panes too; falling back to `NormalFloat`
---is not a downgrade, since that is what the snacks group resolves to anyway.
---@return string normal
---@return string normal_nc
local function backdrop_links()
  -- `snacks.win` defines the groups when it loads, and it does not load until
  -- snacks opens a window — which may be long after this runs, or never. Asking
  -- for it settles the question now instead of leaving the answer to timing.
  pcall(require, "snacks.win")

  local ok, exists = pcall(vim.fn.hlexists, "SnacksNormal")
  if ok and exists == 1 then
    local ok_nc, exists_nc = pcall(vim.fn.hlexists, "SnacksNormalNC")
    return "SnacksNormal", (ok_nc and exists_nc == 1) and "SnacksNormalNC" or "SnacksNormal"
  end
  return "NormalFloat", "NormalFloat"
end

--- Markers for what an agent did to a file. Kept narrow enough not to shift the
--- columns after them.
local KIND_LABEL = { read = "read", add = "added", edit = "edit", delete = "del" }

--- What a tool call's row says about how it went, drawn at the right edge. A call
--- that simply worked says nothing: most of them do, and a pane of ticks is a pane
--- with no signal in it. Which leaves the three that are worth a glance — it is
--- still running, it failed, or the user stopped it.
local STATUS_MARK = {
  running = { text = "…", hl = "time" },
  error = { text = "✗", hl = "failed" },
  -- Stopped by the user, either way: a turn they cancelled, or a call they said
  -- no to. Quiet rather than red — the agent did nothing wrong in either case.
  interrupted = { text = "⊘", hl = "stopped" },
  rejected = { text = "⊘", hl = "stopped" },
}

---@param name string Key in the highlights config.
---@return string group
local function hl(name)
  local configured = config and config.highlights and config.highlights[name]
  return configured or DEFAULT_HIGHLIGHTS[name]
end

---The group a named element is drawn in, honouring `agents.highlights`. Exposed
---so the help window paints with the same rules the panes do.
---@param name string
---@return string group
function M.highlight(name)
  return hl(name)
end

---The `winhighlight` the terminal pane wears.
---
---Applied to the centre pane alone: the conversation gets the raised background
---snacks gives its own terminals, while the sidebars keep the editor's `Normal`
---so they read as part of the editor rather than as more floating surfaces.
---@return string
function M.terminal_winhighlight()
  return table.concat({
    "Normal:" .. hl("normal"),
    "NormalNC:" .. hl("normal_nc"),
    -- Otherwise the filler below the last line of terminal output keeps the
    -- editor background and the pane looks half-painted.
    "EndOfBuffer:" .. hl("normal"),
  }, ",")
end

---@param full_config table|nil The whole plugin config.
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
  fade.setup(full_config)

  -- Resolved at setup rather than declared statically: which group the panes
  -- follow depends on whether snacks is loaded.
  local normal_link, normal_nc_link = backdrop_links()
  HIGHLIGHT_LINKS.ClaudeCodeAgentsNormal = normal_link
  HIGHLIGHT_LINKS.ClaudeCodeAgentsNormalNC = normal_nc_link

  -- Only define a group the user has not pointed elsewhere, and only as a
  -- default link, so a colorscheme keeps the last word.
  for group, link in pairs(HIGHLIGHT_LINKS) do
    local overridden = false
    for name, default_group in pairs(DEFAULT_HIGHLIGHTS) do
      if default_group == group and hl(name) ~= group then
        overridden = true
      end
    end
    if not overridden then
      pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
    end
  end

  if not ns_id then
    local ok, id = pcall(vim.api.nvim_create_namespace, NS)
    ns_id = ok and id or nil
  end
end

---@return integer|nil
function M.namespace()
  if not ns_id then
    local ok, id = pcall(vim.api.nvim_create_namespace, NS)
    ns_id = ok and id or nil
  end
  return ns_id
end

--------------------------------------------------------------------------------
-- Buffers
--------------------------------------------------------------------------------

---Create a read-only scratch buffer for one pane.
---@param kind "sessions"|"feed"|"changes"|"subagents"|"center"
---@return integer|nil bufnr
function M.create_buf(kind)
  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    return nil
  end
  pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
  pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
  pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
  pcall(vim.api.nvim_buf_set_option, buf, "undolevels", -1) -- see `M.paint`
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-" .. kind, { buf = buf })
  pcall(vim.api.nvim_buf_set_name, buf, "Claude agents: " .. kind)
  -- mini.cursorword's documented per-buffer opt-out. These lines are records,
  -- not prose: two rows sharing a timestamp or a status letter are not two uses
  -- of the same identifier, and painting them as such is noise. The gutter above
  -- covers the plugins that have no such switch.
  pcall(function()
    vim.b[buf].minicursorword_disable = true
  end)
  return buf
end

---Push `right` to the right-hand edge of a line, and say where it landed.
---
---Padding is measured in display cells and the column handed back is in bytes,
---which is what an extmark wants. Both panes need this and only one of them used
---to measure in cells — the other counted bytes, so the `+· -·` placeholder (a
---multibyte `·`) pushed its own highlights out of place.
---@param line string
---@param width integer Pane width in cells.
---@param right string
---@return string line
---@return integer at Byte column `right` starts at.
local function right_align(line, width, right)
  local pad = width - vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(right)
  if pad < 1 then
    pad = 1
  end
  line = line .. string.rep(" ", pad) .. right
  return line, #line - #right
end

---Mark a run of spans laid out from byte column `at`.
---@param marks table[]
---@param lnum integer 0-based row.
---@param at integer Byte column the run starts at.
---@param spans { offset: integer, len: integer, hl: string }[]
local function push_spans(marks, lnum, at, spans)
  for _, span in ipairs(spans) do
    marks[#marks + 1] = {
      row = lnum,
      col = at + span.offset,
      end_col = at + span.offset + span.len,
      hl = span.hl,
    }
  end
end

---@param buf integer
---@return integer|nil
local function changedtick(buf)
  local ok, tick = pcall(vim.api.nvim_buf_get_changedtick, buf)
  return ok and tick or nil
end

local MARK_FIELDS = { "row", "col", "end_col", "hl", "line_hl", "priority" }

---@param a string[]
---@param b string[]|nil
local function same_lines(a, b)
  b = b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---@param a table[]
---@param b table[]|nil
local function same_marks(a, b)
  b = b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    for _, field in ipairs(MARK_FIELDS) do
      if a[i][field] ~= b[i][field] then
        return false
      end
    end
  end
  return true
end

---@param marks table[]|nil
---@return table[]
local function copy_marks(marks)
  local out = {}
  for i, mark in ipairs(marks or {}) do
    local copy = {}
    for _, field in ipairs(MARK_FIELDS) do
      copy[field] = mark[field]
    end
    out[i] = copy
  end
  return out
end

---Replace a buffer's contents and marks in one pass.
---
---Exported because every pane-like buffer in the view needs exactly this — the
---centre pane's notice and the `?` help window included, both of which grew
---their own slightly different copy.
---@param buf integer
---@param lines string[]
---@param marks { row: integer, col: integer, end_col: integer, hl: string }[]
---
---**Undo is switched off on every buffer painted here.** Neovim closes an undo
---block only after a typed command, never in a timer or RPC callback, so every
---paint of a polled pane was appended to one block that `undolevels` (a count of
---blocks) never trimmed: a full copy of the replaced lines per paint, held until
---the buffer was deleted — gigabytes over a multi-day session. Set here rather
---than only in `create_buf` because the notice, help, sort menu and search list
---buffers are made elsewhere.
---
---A paint that would leave lines and marks exactly as they are is skipped (most
---polls change nothing). The buffer's `changedtick` guards the skip, so a
---buffer something else wrote to is still repainted.
---@param rows table<integer, table>|nil 1-based line -> payload
function M.paint(buf, lines, marks, rows)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  payloads[buf] = rows
  local tick = changedtick(buf)
  local last = painted[buf]
  if last and last.tick == tick and same_lines(last.lines, lines) and same_marks(last.marks, marks) then
    return
  end

  pcall(vim.api.nvim_buf_set_option, buf, "undolevels", -1)
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", true)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_option, buf, "modifiable", false)

  local ns = M.namespace()
  if ns then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    for _, mark in ipairs(marks or {}) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        line_hl_group = mark.line_hl,
        priority = mark.priority or 150,
      })
    end
  end
  -- Copies, not the caller's tables: a caller that mutated and repainted the same
  -- table would otherwise always compare equal to itself.
  local kept = {}
  for i, line in ipairs(lines or {}) do
    kept[i] = line
  end
  painted[buf] = { lines = kept, marks = copy_marks(marks), tick = changedtick(buf) }
end

local paint = M.paint

---What the row under a cursor line refers to.
---@param buf integer
---@param lnum integer 1-based.
---@return table|nil
function M.payload_at(buf, lnum)
  local rows = payloads[buf]
  return rows and rows[lnum] or nil
end

---Forget a buffer's row map (the pane was torn down).
---@param buf integer
function M.forget(buf)
  payloads[buf] = nil
  painted[buf] = nil
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

---A compact age, in the style of the session list in the screenshot.
---@param ts number Epoch seconds; 0 when unknown.
---@param now number|nil Epoch seconds to measure from.
---@return string
function M.rel_time(ts, now)
  if type(ts) ~= "number" or ts <= 0 then
    return ""
  end
  now = now or os.time()
  local delta = now - ts
  if delta < 0 then
    delta = 0
  end
  if delta < 45 then
    return "now"
  elseif delta < 3600 then
    return math.floor(delta / 60) .. "m"
  elseif delta < 86400 then
    return math.floor(delta / 3600) .. "h"
  elseif delta < 86400 * 30 then
    return math.floor(delta / 86400) .. "d"
  end
  return math.floor(delta / (86400 * 30)) .. "mo"
end

--- Fitting text and paths into a width lives in `utils`: the float titles in
--- `claudecode.float` and `claudecode.diff` need the same rules, and core modules
--- cannot reach into an opt-in feature for them. Re-exported here because this is
--- where the panes read them from, and every one of these is about drawing.
M.truncate = utils.truncate
M.shorten_path = utils.shorten_path
M.relative_path = utils.relative_path

---Right-align `text` in a field `width` display cells wide.
---@param text string
---@param width integer
---@return string
local function lpad(text, width)
  local pad = width - vim.fn.strdisplaywidth(text)
  if pad <= 0 then
    return text
  end
  return string.rep(" ", pad) .. text
end

---`+N -M`, right-aligned into a fixed field, with the marks to colour each half.
---
---A count that has just moved is drawn at full strength and ramps back to its
---resting colour (`fade.count_group`, which derives both from the theme's own
---diff hue), so a number changing while you are looking somewhere else still
---announces itself. `ages.*` is nil for a count that has never changed under our
---eyes, which is every count on the first draw — and that is the resting look,
---not the absence of one.
---@param added integer|nil
---@param removed integer|nil
---@param ages { added: number?, removed: number? }|nil
---@return string text
---@return { offset: integer, len: integer, hl: string }[] spans Offsets within `text`.
local function counts_text(added, removed, ages)
  local spans = {}
  ages = ages or {}
  -- The placeholder occupies the same field as a real pair, so a list that is
  -- still filling in does not shuffle its columns as each row lands.
  local unknown = added == nil and removed == nil
  local plus = unknown and "+·" or ("+" .. tostring(added or 0))
  local minus = unknown and "-·" or ("-" .. tostring(removed or 0))
  -- Padded by display width rather than string.format's %Ns, which counts bytes:
  -- the placeholder's `·` is multibyte, and byte padding would leave it short by
  -- a cell and knock the column out of line.
  local text = lpad(plus, 6) .. " " .. lpad(minus, 5)
  if unknown then
    return text, spans
  end
  local plus_at = text:find("+", 1, true)
  local minus_at = text:find("-", plus_at or 1, true)
  -- One call for both states: `count_group` derives the block's colours from the
  -- theme's own added/removed hue and returns the group for how long ago the
  -- count moved — the peak right after, its resting colours once the ramp is done.
  if plus_at then
    spans[#spans + 1] = { offset = plus_at - 1, len = #plus, hl = fade.count_group(hl("added"), "added", ages.added) }
  end
  if minus_at then
    spans[#spans + 1] =
      { offset = minus_at - 1, len = #minus, hl = fade.count_group(hl("removed"), "removed", ages.removed) }
  end
  return text, spans
end

--------------------------------------------------------------------------------
-- Panes
--------------------------------------------------------------------------------

---Draw the session list.
---@param buf integer
---@param rows table[] `{ session_id, title, last_ts, added, removed, state, icon, hl, selected, live }`
---@param opts { width: integer?, now: number? }|nil
function M.sessions(buf, rows, opts)
  opts = opts or {}
  local width = opts.width or 32
  local lines, marks, payload_map = {}, {}, {}

  if #rows == 0 then
    paint(buf, { "  no sessions for this project" }, {}, {})
    return
  end

  for index, row in ipairs(rows) do
    local icon = row.icon or ""
    local counts, spans = counts_text(row.added, row.removed, {
      added = row.added_age_ms,
      removed = row.removed_age_ms,
    })
    -- A restored session says this agent was running last time. It is not running
    -- now — nothing starts until you pick it — so the age is replaced by a mark
    -- that says "this one was live", which is the useful thing to know.
    local age = row.armed and "was" or M.rel_time(row.last_ts, opts.now)
    -- The right-hand block is a fixed field so the counts of every row start in
    -- the same column, however long the age reads ("now" against "2d").
    local age_field = string.format("%4s", age)
    local right = age_field .. " " .. counts

    -- Padding is measured in display cells on both sides: the title may hold
    -- multibyte characters whose byte length says nothing about their width.
    local gutter = row.selected and SELECTED_MARK or GUTTER
    local left_prefix = gutter .. (icon == "" and "" or (icon .. " "))
    local prefix_width = vim.fn.strdisplaywidth(left_prefix)
    local right_width = vim.fn.strdisplaywidth(right)
    local title = M.truncate(row.title or row.session_id or "?", math.max(8, width - prefix_width - right_width - 1))

    local line, age_at = right_align(left_prefix .. title, width, right)

    local lnum = index - 1
    lines[#lines + 1] = line
    payload_map[index] = { session_id = row.session_id, kind = "session" }

    if row.selected then
      marks[#marks + 1] = { row = lnum, col = 0, end_col = #gutter, hl = hl("title") }
    end
    -- Byte offsets from `gutter`, not `GUTTER`: the selected row's marker is
    -- multibyte, and one cell wide is not one byte wide.
    if icon ~= "" and row.hl then
      marks[#marks + 1] = { row = lnum, col = #gutter, end_col = #gutter + #icon, hl = row.hl }
    end
    marks[#marks + 1] = { row = lnum, col = #left_prefix, end_col = #left_prefix + #title, hl = hl("title") }
    marks[#marks + 1] = { row = lnum, col = age_at, end_col = age_at + #age_field, hl = hl("time") }
    local counts_at = #line - #counts
    push_spans(marks, lnum, counts_at, spans)
    if row.selected then
      -- Our own highlight rather than 'cursorline', so the selection stays
      -- visible while the cursor is in another pane.
      --
      -- **A character range, and it stops where the counts start.** The obvious
      -- spelling is `line_hl_group`, and it was — but a line highlight composes
      -- *over* the background of every character highlight on its line, whatever
      -- the priorities say. So the selected row's `+N`/`-N` lost the coloured
      -- blocks that are the whole point of them and came out in the selection
      -- colour, which is also the one row where you most want to read them.
      -- Ending the band at the counts leaves those blocks to paint themselves;
      -- everything to their left is covered exactly as before, since
      -- `right_align` has already padded the line to the full pane width and
      -- there is no past-the-end region for a line highlight to add.
      --
      -- Priority 100, below the spans above: those set a foreground and no
      -- background, so the composed cell takes their colour on this background
      -- rather than either replacing the other.
      local band_end = #counts > 0 and counts_at or #line
      marks[#marks + 1] = { row = lnum, col = 0, end_col = band_end, hl = hl("selected"), priority = 100 }
    end
  end

  paint(buf, lines, marks, payload_map)
end

---Draw the activity feed, oldest first.
---@param buf integer
---@param events table[] `{ ts, kind, path, added, removed }`
---@param opts { cwd: string?, width: integer? }|nil
function M.feed(buf, events, opts)
  opts = opts or {}
  local width = opts.width or 32
  -- Positional rather than a field on each event: the events are the transcript's
  -- own stored tables, cached to disk, so the view's idea of "how long has this
  -- been on screen" does not belong on one.
  local ages = opts.ages or {}
  local lines, marks, payload_map = {}, {}, {}

  if #events == 0 then
    paint(buf, { "  no activity yet" }, {}, {})
    return
  end

  for index, event in ipairs(events) do
    local is_tool = event.kind == "tool"
    -- A tool call's column is the tool's own name — `bash`, `grep`, `agent` —
    -- which is what a glance at the pane is asking; the label beside it says what
    -- that call was for.
    local label = is_tool and tools.short(event.tool) or (KIND_LABEL[event.kind] or event.kind or "?")
    local clock = event.ts and event.ts > 0 and os.date("%H:%M", event.ts) or "--:--"
    local head = string.format("%s%s %-5s ", GUTTER, clock, label)

    -- The marker takes its cells out of the text, not out of the pane: a row that
    -- reads to the edge and then grows a `…` would reflow the whole column.
    local mark = is_tool and STATUS_MARK[event.status] or nil
    local room = math.max(8, width - #head - 1 - (mark and (vim.fn.strdisplaywidth(mark.text) + 1) or 0))
    local name
    if is_tool then
      -- Cut from the end: a label is a sentence, and its first words are the ones
      -- that identify it. A path is the opposite, hence `shorten_path` below.
      name = M.truncate(event.label or event.tool or "", room)
    else
      name = M.shorten_path(M.relative_path(event.path, opts.cwd), room)
    end
    local line = head .. name

    local lnum = index - 1
    local mark_at
    if mark then
      line, mark_at = right_align(line, width, mark.text)
    end
    lines[#lines + 1] = line
    if is_tool then
      -- What the call was, not where it was: `<CR>` reads the command and its
      -- output back out of the transcript by this id.
      payload_map[index] = {
        kind = "tool",
        tool = event.tool,
        tool_id = event.tool_id,
        label = event.label,
        status = event.status,
      }
    else
      -- The event's own kind and read window travel with the row: opening a read
      -- shows the lines that read covered, not the whole session's changes.
      payload_map[index] = {
        kind = "file",
        path = event.path,
        event_kind = event.kind,
        start_line = event.start_line,
        num_lines = event.num_lines,
      }
    end

    -- A row arrives at full colour and settles into the quieter resting one, so
    -- what the agent is doing *now* stands out from what it has already done —
    -- which is the whole question this pane answers.
    local age = ages[index]
    marks[#marks + 1] = { row = lnum, col = #GUTTER, end_col = #GUTTER + #clock, hl = fade.dim_group(hl("time"), age) }
    -- Every span of the row is marked, or the unmarked one keeps `Normal` and
    -- stays bright while the rest of the row fades around it.
    local label_at = #GUTTER + #clock + 1
    marks[#marks + 1] = {
      row = lnum,
      col = label_at,
      end_col = label_at + #label,
      hl = fade.dim_group(hl("kind"), age),
    }
    -- A tool call's text is what it was for, which is prose rather than a path;
    -- drawn in the pane's own foreground so the two kinds of row are told apart
    -- by more than their column.
    local text_group = is_tool and hl("title") or hl("path")
    marks[#marks + 1] = { row = lnum, col = #head, end_col = #head + #name, hl = fade.dim_group(text_group, age) }
    if mark and mark_at then
      -- The marker does not fade with the row: "this is still running" and "this
      -- failed" are true now, however long ago the row arrived.
      marks[#marks + 1] = { row = lnum, col = mark_at, end_col = mark_at + #mark.text, hl = hl(mark.hl) }
    end
  end

  paint(buf, lines, marks, payload_map)
end

---Draw the files the selected agent touched.
---@param buf integer
---@param entries table[] `{ path, status, added, removed, deleted }`
---@param opts { cwd: string?, width: integer? }|nil
function M.changes(buf, entries, opts)
  opts = opts or {}
  local width = opts.width or 28
  local lines, marks, payload_map = {}, {}, {}

  if #entries == 0 then
    paint(buf, { "  no files changed" }, {}, {})
    return
  end

  for index, entry in ipairs(entries) do
    local status = entry.status or " "
    -- The head already opens with a blank cell, so this pane needs no gutter of
    -- its own; see GUTTER.
    local counts, spans = counts_text(entry.added, entry.removed, {
      added = entry.added_age_ms,
      removed = entry.removed_age_ms,
    })
    local path = M.relative_path(entry.path, opts.cwd)
    local head = string.format(" %s ", status)
    local name = M.shorten_path(path, math.max(8, width - #head - vim.fn.strdisplaywidth(counts) - 1))
    local line, counts_at = right_align(head .. name, width, counts)

    local lnum = index - 1
    lines[#lines + 1] = line
    payload_map[index] = { kind = "file", path = entry.path, event_kind = entry.kind }

    if entry.deleted then
      -- Dimmed whole, counts included: their coloured blocks and flashes are for
      -- work that is still in the tree. The letter keeps the pane's own colour,
      -- so the one thing left standing out on the row is the `D`.
      marks[#marks + 1] = { row = lnum, col = #head, end_col = #line, hl = hl("deleted") }
    else
      marks[#marks + 1] = { row = lnum, col = #head, end_col = #head + #name, hl = hl("path") }
      push_spans(marks, lnum, counts_at, spans)
    end
  end

  paint(buf, lines, marks, payload_map)
end

--- How a subagent's run stands, as a glyph and the highlight it is drawn in.
--- `hl` names a key of `agents.highlights`; running borrows `status`'s busy group.
local SUBAGENT_MARK = {
  running = { text = "●" },
  done = { text = "✓", hl = "time" },
  failed = { text = "✗", hl = "failed" },
  stopped = { text = "⊘", hl = "stopped" },
}

---Draw the selected session's subagents as a tree.
---
---One row per run: the tree's connectors, a state glyph, its name, and at the
---right edge what it cost and how long it ran. A run that has ended is drawn
---quietly — the working ones are what the pane is glanced at for.
---
---The name is the agent type or, with `label = "description"`, what the run was
---sent to do (falling back to the type when it has none). Either is cut with an
---ellipsis to whatever the tree and the numbers leave: a description is a
---sentence and the pane is a sidebar, and a name running under the numbers would
---push them past the window edge, where Neovim cuts without saying so.
---@param buf integer
---@param rows ClaudeCodeSubagentRow[]
---@param opts { width: integer?, label: "type"|"description"|nil }|nil
function M.subagents(buf, rows, opts)
  opts = opts or {}
  local width = opts.width or 28
  local lines, marks, payload_map = {}, {}, {}

  if #rows == 0 then
    paint(buf, { "  no subagents" }, {}, {})
    return
  end

  local subagents = require("claudecode.agents.subagents")
  local busy_group = nil
  pcall(function()
    local _, group = require("claudecode.status").icon_for_state("busy")
    busy_group = group
  end)

  for index, row in ipairs(rows) do
    local mark = SUBAGENT_MARK[row.state] or SUBAGENT_MARK.stopped
    local ended = row.state ~= "running"
    -- Fixed fields, so every row's numbers line up however deep the tree goes.
    local right = lpad(subagents.format_tokens(row.tokens), 5)
      .. " "
      .. lpad(subagents.format_runtime(row.runtime_s), 7)
    local head = GUTTER .. row.prefix .. mark.text .. " "
    local room = math.max(1, width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(right) - 1)
    local text = row.agent_type or "agent"
    if opts.label == "description" and type(row.description) == "string" then
      -- One line, whatever the launching call wrote.
      local described = row.description:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
      if described ~= "" then
        text = described
      end
    end
    local name = M.truncate(text, room)
    local line, right_at = right_align(head .. name, width, right)

    local lnum = index - 1
    lines[#lines + 1] = line
    payload_map[index] = { kind = "subagent", agent_id = row.id, description = row.description }

    local prefix_at = #GUTTER
    local mark_at = prefix_at + #row.prefix
    if #row.prefix > 0 then
      marks[#marks + 1] = { row = lnum, col = prefix_at, end_col = mark_at, hl = hl("time") }
    end
    local mark_group = mark.hl and hl(mark.hl) or busy_group
    if mark_group then
      marks[#marks + 1] = { row = lnum, col = mark_at, end_col = mark_at + #mark.text, hl = mark_group }
    end
    marks[#marks + 1] = {
      row = lnum,
      col = #head,
      end_col = #head + #name,
      hl = ended and hl("stopped") or hl("title"),
    }
    marks[#marks + 1] = { row = lnum, col = right_at, end_col = #line, hl = hl("time") }
  end

  paint(buf, lines, marks, payload_map)
end

---Test/reload helper.
function M.reset()
  payloads = {}
  painted = {}
end

return M
