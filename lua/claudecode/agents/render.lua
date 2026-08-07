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

local DEFAULT_HIGHLIGHTS = {
  title = "ClaudeCodeAgentsTitle",
  time = "ClaudeCodeAgentsTime",
  added = "ClaudeCodeAgentsAdded",
  removed = "ClaudeCodeAgentsRemoved",
  selected = "ClaudeCodeAgentsSelected",
  path = "ClaudeCodeAgentsPath",
  kind = "ClaudeCodeAgentsKind",
  float = "ClaudeCodeAgentsFloat",
  normal = "ClaudeCodeAgentsNormal",
  normal_nc = "ClaudeCodeAgentsNormalNC",
  header = "ClaudeCodeAgentsHelpHeader",
  key = "ClaudeCodeAgentsKey",
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
  ClaudeCodeAgentsFloat = "FloatBorder",
  ClaudeCodeAgentsHelpHeader = "Title",
  ClaudeCodeAgentsKey = "Special",
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
---@param kind "sessions"|"feed"|"changes"
---@return integer|nil bufnr
function M.create_buf(kind)
  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    return nil
  end
  pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
  pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
  pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
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

---Replace a buffer's contents and marks in one pass.
---
---Exported because every pane-like buffer in the view needs exactly this — the
---centre pane's notice and the `?` help window included, both of which grew
---their own slightly different copy.
---@param buf integer
---@param lines string[]
---@param marks { row: integer, col: integer, end_col: integer, hl: string }[]
---@param rows table<integer, table>|nil 1-based line -> payload
function M.paint(buf, lines, marks, rows)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
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
  payloads[buf] = rows
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

---Truncate to a display width, marking the cut.
---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- Cut by display cells, not bytes: a multibyte title would otherwise be sliced
  -- mid-character and render as a replacement glyph.
  local out = vim.fn.strcharpart(text, 0, width - 1)
  while vim.fn.strdisplaywidth(out) > width - 1 and #out > 0 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

---Cut a filename to a width while keeping its extension.
---
---A plain tail-cut drops the extension first, which is the half of a filename
---that says what kind of thing it is; `render.lua` and `render.md` are two files
---and `render…` is neither. The extension is dropped only when keeping it would
---leave no room for the name in front of it.
---@param name string
---@param width integer
---@return string
local function fit_name(name, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(name) <= width then
    return name
  end
  local stem, ext = name:match("^(.+)(%.[^./]+)$")
  if stem then
    local room = width - vim.fn.strdisplaywidth(ext)
    -- Two cells: one character of the name and the cut mark. Below that the
    -- extension is all you would see, which names no file.
    if room >= 2 then
      return M.truncate(stem, room) .. ext
    end
  end
  return M.truncate(name, width)
end

---Split a path into segments, keeping a leading `/` on the first one, and report
---the separator it was written with.
---
---Both separators are split on, and a Windows drive is kept with the segment that
---follows it (`D:\Git\proj` -> `D:\Git`, `proj`): `D:` on its own is not the
---coarse "where in the project" answer `shorten_path` picks a first segment for.
---A path split on `/` alone left a Windows path as one segment, which sent it to
---the tail cut this whole function exists to avoid.
---@param path string
---@return string[] segments, string separator
local function path_segments(path)
  local segments = {}
  for segment in path:gmatch("[^/\\]+") do
    segments[#segments + 1] = segment
  end
  local separator = path:find("\\", 1, true) and not path:find("/", 1, true) and "\\" or "/"
  if segments[1] then
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
      segments[1] = path:sub(1, 1) .. segments[1]
    elseif segments[1]:match("^%a:$") and segments[2] then
      segments[1] = segments[1] .. separator .. segments[2]
      table.remove(segments, 2)
    end
  end
  return segments, separator
end

---Fit a path into a width from the inside out, so the filename always survives.
---
---`M.truncate` cuts the tail, which on a path throws away the one part you were
---reading it for: a narrow pane turned `lua/claudecode/agents/render.lua` into
---`lua/claudecod…`, so every file in a directory looked alike. This drops
---*interior* directories instead, and only as many as the width demands, in the
---order they are worth least:
---
---  1. the whole path, if it fits;
---  2. `first/…/parent/name` — where in the project, and which module;
---  3. `first/…/name` — where in the project;
---  4. `…/name` — the name, said to be part of a path;
---  5. `name`;
---  6. `name` cut, extension kept (`fit_name`).
---
---The first folder outranks the parent because it is the coarser answer: in a
---list of files from one session, `lua/…/init.lua` and `tests/…/init.lua` are
---told apart by it, while their parents are often the same word.
---@param path string
---@param width integer Display cells.
---@return string
function M.shorten_path(path, width)
  if type(path) ~= "string" or path == "" or width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end

  local segments, sep = path_segments(path)
  local count = #segments
  if count <= 1 then
    return fit_name(path, width)
  end

  local name = segments[count]
  local first, parent = segments[1], segments[count - 1]

  local candidates = {}
  -- Only when the ellipsis actually stands for something: with three segments
  -- `first/…/parent/name` would spell the whole path with a cut mark in it.
  if count >= 4 then
    candidates[#candidates + 1] = first .. sep .. "…" .. sep .. parent .. sep .. name
  end
  if count >= 3 then
    candidates[#candidates + 1] = first .. sep .. "…" .. sep .. name
  end
  candidates[#candidates + 1] = "…" .. sep .. name
  candidates[#candidates + 1] = name

  for _, candidate in ipairs(candidates) do
    if vim.fn.strdisplaywidth(candidate) <= width then
      return candidate
    end
  end
  return fit_name(name, width)
end

---A path shown relative to the directory the session ran in.
---
---Compared in normalized form, since the two spellings need not match: on Windows
---the session's cwd is `D:\Git\proj` while the same directory can reach us as
---`D:/Git/proj`. What is returned is a slice of the original, so the path keeps
---the separators it was written with.
---@param path string
---@param root string|nil
---@return string
function M.relative_path(path, root)
  if type(path) ~= "string" then
    return ""
  end
  if type(root) == "string" and root ~= "" then
    local utils = require("claudecode.utils")
    local prefix = utils.path_key(root) .. "/"
    local key = utils.path_key(path)
    if key:sub(1, #prefix) == prefix then
      -- Normalizing rewrites separators and case in place, so an offset into the
      -- key is the same offset into the path — unless it also collapsed a
      -- doubled separator, in which case the key's own remainder is the answer.
      return #key == #path and path:sub(#prefix + 1) or key:sub(#prefix + 1)
    end
  end
  return path
end

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
---A count that has just moved is drawn lit and ramps back to its resting colour
---(`fade.flash_group`), so a number changing while you are looking somewhere
---else still announces itself. `*_age_ms` is nil for a count that has never
---changed under our eyes, which is every count on the first draw.
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
  -- `count_group` is the resting look — the number in the block's own colour, the
  -- way a diff draws one — and the flash ramps back to *that* rather than to the
  -- raw group, so a count that has just moved settles onto the colour it had.
  if plus_at then
    local group = fade.count_group(hl("added"), "added")
    spans[#spans + 1] = { offset = plus_at - 1, len = #plus, hl = fade.flash_group(group, ages.added) }
  end
  if minus_at then
    local group = fade.count_group(hl("removed"), "removed")
    spans[#spans + 1] = { offset = minus_at - 1, len = #minus, hl = fade.flash_group(group, ages.removed) }
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
    local label = KIND_LABEL[event.kind] or event.kind or "?"
    local clock = event.ts and event.ts > 0 and os.date("%H:%M", event.ts) or "--:--"
    local path = M.relative_path(event.path, opts.cwd)
    local head = string.format("%s%s %-5s ", GUTTER, clock, label)
    local name = M.shorten_path(path, math.max(8, width - #head - 1))
    local line = head .. name

    local lnum = index - 1
    lines[#lines + 1] = line
    -- The event's own kind and read window travel with the row: opening a read
    -- shows the lines that read covered, not the whole session's changes.
    payload_map[index] = {
      kind = "file",
      path = event.path,
      event_kind = event.kind,
      start_line = event.start_line,
      num_lines = event.num_lines,
    }

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
    marks[#marks + 1] = { row = lnum, col = #head, end_col = #head + #name, hl = fade.dim_group(hl("path"), age) }
  end

  paint(buf, lines, marks, payload_map)
end

---Draw the files the selected agent touched.
---@param buf integer
---@param entries table[] `{ path, status, added, removed }`
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

    marks[#marks + 1] = { row = lnum, col = #head, end_col = #head + #name, hl = hl("path") }
    push_spans(marks, lnum, counts_at, spans)
  end

  paint(buf, lines, marks, payload_map)
end

---Test/reload helper.
function M.reset()
  payloads = {}
end

return M
