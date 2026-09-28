---@brief [[
--- What opening a file from the Changes or Activity pane shows.
---
--- Opening it plain answers "what does this file look like", which is not the
--- question either pane asks. The Changes pane is a list of what the agent changed,
--- so `<CR>` on a row shows *that change* — the same inline unified diff the live
--- cursor renders while an edit happens, only cumulative: today's file against what
--- the session started from (`agents/patch.lua` reconstructs that by undoing the
--- session's own hunks). An Activity row is one tool call, so `<CR>` on a read
--- highlights the lines that read covered, exactly as the live cursor does — and
--- `<CR>` on an edit shows *that edit*: the file as the call left it, against what
--- the call found, with the title saying which of the session's edits to the file
--- it is (`(edit 3 of 7)`). Before this every edit row opened the same cumulative
--- diff, so a file edited five times had five rows that all showed the final state.
---
--- Three things can stand in the way, and each has an answer rather than a failure:
---
--- *The file moved on since.* Hunks that can no longer be located are left out; the
--- diff shows the part of the session's work that is still there, and the float's
--- title says so.
---
--- *Nothing can be located, or the file is gone.* Then the patches themselves are
--- shown as diff text — the CLI's own record, which cannot be stale.
---
--- *unified.nvim is absent.* Inline diffs are its rendering; without it the same
--- patch text is shown instead, so the answer is still a diff rather than a file.
---@brief ]]
---@module 'claudecode.agents.file_view'

local float = require("claudecode.agents.float")
local logger = require("claudecode.logger")
local patch = require("claudecode.agents.patch")
local transcript = require("claudecode.agents.transcript")
local utils = require("claudecode.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("claudecode_agents_file_view")

---How a float's title names the file it is showing (`utils.path_title`), at this
---feature's own float geometry.
---
---The tail alone does not say *where*: a session touches several `init.lua`, and
---a row is a record of work rather than a file you already have open, so the one
---thing the title has to answer is which file this is.
---@param path string
---@param root string|nil Directory the session ran in.
---@param note string|nil Parenthesised aside, e.g. `"(vs HEAD)"`.
---@return string
function M.title(path, root, note)
  return utils.path_title(path, root, note, float.title_width())
end

---@return boolean
local function unified_available()
  return (pcall(require, "unified.diff"))
end

--- Reading the file on disk, as a seam: a spec can hand this module a filesystem
--- without one, the way `transcript._io` does for the transcript store.
M._io = {
  ---@param path string
  ---@return string[]|nil lines nil when the file is gone.
  read_lines = function(path)
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or type(lines) ~= "table" then
      return nil
    end
    return lines
  end,
}

---@param path string
---@return string[]|nil
local function read_lines(path)
  return M._io.read_lines(path)
end

---@param buf integer
---@param path string
local function set_filetype(buf, path)
  local ok, diff = pcall(require, "claudecode.diff")
  local ft = ok and diff.detect_filetype and diff.detect_filetype(path, nil)
  if ft and ft ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
  end
end

--- A scratch buffer holding lines, ready to be put in a float. Shared with the
--- tool view, which builds its buffers exactly the same way.
local scratch = float.scratch

---Open a file in a new tabpage, on `line` and `col` when given.
---
---A row records work, and that work may have been a delete — or the file may
---have moved since. `tabnew` on a path that is not there opens an empty buffer
---whose first `:w` resurrects the file, so a path that is not readable is refused.
---@param path string
---@param line integer|nil
---@param col integer|nil 0-based byte column.
---@return boolean opened
function M.open_in_tab(path, line, col)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return false
  end
  local ok = pcall(vim.cmd, "tabnew " .. vim.fn.fnameescape(path))
  if not ok then
    return false
  end
  if line then
    local ok_count, count = pcall(vim.api.nvim_buf_line_count, 0)
    if ok_count and type(count) == "number" and count > 0 then
      line = math.max(1, math.min(line, count))
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { line, col or 0 })
  end
  return true
end

--------------------------------------------------------------------------------
-- A key that edits opens the file
--
-- Every float here is a reading frame: a scratch buffer holding a version of the
-- file, or a patch of it, that cannot be modified and that `q` throws away. Yet
-- reading a diff is exactly when a line that wants changing turns up, and the hand
-- is on `o` or `ciw` before the head remembers where it is — which answered E21.
-- So a key that would change the text opens the file itself in a new tab, the way
-- `gf` does from a pane, closes the float, puts the cursor where it was and runs
-- the key there: `dd` deletes that line of the file, `o` opens one below it.
--------------------------------------------------------------------------------

--- Keys that change text, by mode.
---
--- An operator is bound alone, with `nowait`, and whatever follows it (the second
--- `d`, the `iw`, a surround plugin's `s"`) stays in typeahead for the replayed key
--- to pick up in the file. Binding `dd` as well would make `d` wait on the
--- timeout, and bound alone without the replay, that second `d` would land in the
--- new tab as an operator waiting for a motion.
---
--- Not undo, redo or `.`: a float has nothing to undo, and repeating the last
--- change in a file that was just opened would repeat whatever was last done
--- somewhere else. Not `gr` either, which Neovim prefixes its LSP keys with.
M.EDIT_KEYS = {
  n = {
    "i",
    "a",
    "I",
    "A",
    "o",
    "O",
    "gi",
    "gI",
    "<Insert>",
    "c",
    "C",
    "s",
    "S",
    "r",
    "R",
    "gR",
    "d",
    "D",
    "x",
    "X",
    "<Del>",
    "p",
    "P",
    "gp",
    "gP",
    "]p",
    "[p",
    "J",
    "gJ",
    "~",
    "g~",
    "gu",
    "gU",
    "g?",
    "<lt>",
    ">",
    "=",
    "!",
    "gq",
    "gw",
    "gc",
    "[<Space>",
    "]<Space>",
    "<C-a>",
    "<C-x>",
  },
  x = {
    "c",
    "C",
    "s",
    "S",
    "r",
    "R",
    "d",
    "D",
    "x",
    "X",
    "<Del>",
    "p",
    "P",
    "J",
    "gJ",
    "~",
    "u",
    "U",
    "g?",
    "<lt>",
    ">",
    "=",
    "!",
    "gq",
    "gw",
    "gc",
    "I",
    "A",
    "<C-a>",
    "<C-x>",
    "g<C-a>",
    "g<C-x>",
  },
}

--- Keys taken even when something is mapped to them, because every mapping anyone
--- gives them is an edit: Neovim's own `gc` and blank-line keys, and every comment
--- plugin's `gc`.
local ALWAYS_TAKEN = { gc = true, ["[<Space>"] = true, ["]<Space>"] = true }

---Whether a key already does something of the user's here.
---
---A mapping is left alone: flash, leap and sneak put a jump on `s`, and a reading
---float is where a jump is wanted most. The cost is a mapping that is itself an
---edit (a yank-ring `p`, a black-hole `x`) answering E21 as before.
---@param buf integer
---@param mode string
---@param lhs string
---@return boolean
local function claimed(buf, mode, lhs)
  if ALWAYS_TAKEN[lhs] then
    return false
  end
  for _, name in ipairs({ "mapleader", "maplocalleader" }) do
    if vim.g[name] == lhs then
      return true
    end
  end
  -- In the float's own buffer: `maparg` also answers with the current buffer's
  -- mappings, and that can be a pane's (the sessions pane's `x` stops an agent).
  local ok, map = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.maparg(lhs, mode, false, true)
  end)
  return ok and type(map) == "table" and next(map) ~= nil
end

---@param total integer
---@param line integer
---@return integer
local function clamp(line, total)
  return math.max(1, math.min(line, math.max(total, 1)))
end

---Where a line of one version of a file is in another.
---
---A line in a stretch both versions share moves by whatever was added or removed
---above it. A line inside a change lands on its counterpart in the other version,
---or where the change left off when there is none.
---@param hunks integer[][] `vim.diff` indices from one version to the other.
---@param row integer 1-based line in the first version.
---@param total integer Lines in the second.
---@return integer
function M._map_line(hunks, row, total)
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local from, from_count, to, to_count = hunk[1], hunk[2], hunk[3], hunk[4]
    if from_count == 0 then
      -- Lines added after `from`.
      if row <= from then
        break
      end
      offset = offset + to_count
    else
      if row < from then
        break
      end
      if row < from + from_count then
        if to_count == 0 then
          return clamp(to + 1, total)
        end
        return clamp(to + math.min(row - from, to_count - 1), total)
      end
      offset = offset + to_count - from_count
    end
  end
  return clamp(row + offset, total)
end

---The line of the new file a line of a patch stands for, and its text when the
---new file has it (a context or added line; nil for a removed line or a header).
---@param lines string[] Diff text.
---@param row integer
---@return integer line
---@return string|nil text
function M._patch_line(lines, row)
  local header = nil
  for i = math.min(row, #lines), 1, -1 do
    if lines[i]:find("^@@ %-") then
      header = i
      break
    end
  end
  if not header then
    -- The file headers above the first hunk: that hunk's start.
    for i = row + 1, #lines do
      if lines[i]:find("^@@ %-") then
        header = i
        break
      end
    end
    if not header then
      return 1, nil
    end
    row = header
  end

  local start, count = lines[header]:match("^@@ %-%d+,?%d* %+(%d+),?(%d*) @@")
  local line = tonumber(start) or 1
  -- An empty new side names the line *before* where the old one was.
  if count == "0" then
    line = line + 1
  end
  local function kept(text)
    local mark = text:sub(1, 1)
    return mark == " " or mark == "+" or text == ""
  end
  for i = header + 1, row - 1 do
    if kept(lines[i]) then
      line = line + 1
    end
  end
  if row ~= header and kept(lines[row]) then
    return line, lines[row]:sub(2)
  end
  return line, nil
end

---The line of `lines` holding `text` that is nearest `near`.
---
---Compared as `patch.shown` has both: the CLI writes every tab in a patch as two
---spaces.
---@param lines string[]
---@param text string
---@param near integer
---@return integer|nil
local function nearest(lines, text, near)
  local wanted = patch.shown(text)
  local best = nil
  for i, line in ipairs(lines) do
    if patch.shown(line) == wanted and (not best or math.abs(i - near) < math.abs(best - near)) then
      best = i
    end
  end
  return best
end

---@param a string[]
---@param b string[]
---@return integer[][]|nil
local function line_hunks(a, b)
  local diff = (vim.text and vim.text.diff) or vim.diff
  if not diff then
    return nil
  end
  local function text_of(lines)
    return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
  end
  local ok, hunks = pcall(diff, text_of(a), text_of(b), { result_type = "indices" })
  if ok and type(hunks) == "table" then
    return hunks
  end
  return nil
end

---Where a position in a float is in the file being edited.
---
---A float showing a version of the file (`kind = "file"`) is mapped through a
---line diff against the file as it is now — the same lines unless the float shows
---the file as a session left it and it has moved on since. A patch (`"patch"`) is
---read for the line of the new file each of its lines stands for, then found by
---its text nearest there, since the patch may be older than the file.
---@param shown string[] What the float shows.
---@param lines string[] The file as it will be edited.
---@param kind "file"|"patch"
---@param row integer 1-based.
---@param col integer 0-based byte column.
---@return { line: integer, col: integer }
function M._disk_position(shown, lines, kind, row, col)
  local total = #lines
  if kind == "patch" then
    local line, text = M._patch_line(shown, row)
    local found = text and nearest(lines, text, line) or nil
    if found and lines[found] == text then
      -- Less the patch's own `+`/` ` column.
      return { line = found, col = math.max(0, col - 1) }
    end
    local at = found or clamp(line, total)
    return { line = at, col = #((lines[at] or ""):match("^%s*")) }
  end

  local hunks = line_hunks(shown, lines)
  if hunks then
    return { line = M._map_line(hunks, row, total), col = col }
  end
  local found = shown[row] and nearest(lines, shown[row], row) or nil
  return { line = found or clamp(row, total), col = col }
end

---The file's lines as the user is about to edit them: its buffer's when one is
---loaded (which may hold changes not yet written), else what is on disk.
---@param path string
---@return string[]|nil
local function lines_to_edit(path)
  local disk = read_lines(path)
  if not disk then
    return nil
  end
  local ok_full, full = pcall(vim.fn.fnamemodify, path, ":p")
  local ok_bufs, bufs = pcall(vim.api.nvim_list_bufs)
  if ok_full and ok_bufs and type(bufs) == "table" then
    for _, buf in ipairs(bufs) do
      local ok_name, name = pcall(vim.api.nvim_buf_get_name, buf)
      if ok_name and name ~= "" and vim.fn.fnamemodify(name, ":p") == full then
        local ok_loaded, loaded = pcall(vim.api.nvim_buf_is_loaded, buf)
        if ok_loaded and loaded then
          local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
          if ok_lines and type(lines) == "table" then
            return lines
          end
        end
        break
      end
    end
  end
  return disk
end

---The register and count typed before a key, spelled so they can be typed again.
---
---A register is left out when it is the one a plain `p` would use anyway, which
---with `'clipboard'` set is not `"`.
---@param count integer|nil
---@param register string|nil
---@return string
function M._key_prefix(count, register)
  local default = '"'
  local clipboard = {}
  for item in tostring(vim.o.clipboard or ""):gmatch("[^,]+") do
    clipboard[item] = true
  end
  if clipboard.unnamedplus then
    default = "+"
  elseif clipboard.unnamed then
    default = "*"
  end
  local prefix = ""
  if type(register) == "string" and register ~= "" and register ~= default then
    prefix = '"' .. register
  end
  count = tonumber(count) or 0
  if count > 0 then
    prefix = prefix .. tostring(count)
  end
  return prefix
end

---@param keys string
---@return string
local function termcodes(keys)
  return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

---Close the float, open the file in a new tab where the cursor was, and type the
---key there.
---
---Both calls to `nvim_feedkeys` insert at the *front* of typeahead (`i`), ahead of
---whatever the user typed after the key and before the float closed: appended, a
---quick `ciw` would reach the file as `iwc`. The key itself is remapped (`m`), so a
---plugin's mapping in the file (`ds` of a surround plugin) still completes; the
---reselection is not, so no mapping of `v` gets in its way.
---@param buf integer The float's buffer.
---@param path string
---@param kind "file"|"patch"
---@param lhs string
---@param visual boolean
local function edit_on_disk(buf, path, kind, lhs, visual)
  local count, register = vim.v.count, vim.v.register
  local lines = lines_to_edit(path)
  if not lines then
    -- Nothing on disk to edit, and a tab on the path would be one `:w` from
    -- resurrecting it.
    logger.debug("agents", "file_view: no file on disk at", path, "- ignoring", lhs)
    return
  end

  -- Everything read before the float closes: its buffer is wiped with it.
  local win = vim.api.nvim_get_current_win()
  local shown = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local to = M._disk_position(shown, lines, kind, cursor[1], cursor[2])
  local selection = nil
  if visual then
    local start = vim.fn.getpos("v")
    selection = {
      mode = vim.fn.mode(),
      from = M._disk_position(shown, lines, kind, start[2], math.max(0, start[3] - 1)),
    }
    pcall(vim.cmd, "normal! \27")
  end

  if vim.w[win].claudecode_float then
    float.close(win)
  end
  local at = selection and selection.from or to
  if not M.open_in_tab(path, at.line, at.col) then
    return
  end

  vim.api.nvim_feedkeys(termcodes(M._key_prefix(count, register) .. lhs), "mi", false)
  if selection then
    local reselect = string.format("<Cmd>call cursor(%d, %d)<CR>", to.line, to.col + 1)
    vim.api.nvim_feedkeys(selection.mode .. termcodes(reselect), "ni", false)
  end
end

---Give a float's buffer the keys that edit the file it shows.
---
---Only on the scratch buffers this module builds: they are wiped with their float,
---so the maps go with them.
---@param win integer|nil
---@param path string
---@param kind "file"|"patch" What the buffer holds; see `_disk_position`.
local function bind_edit_keys(win, path, kind)
  if not win then
    return
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok or not buf then
    return
  end
  local desc = "Edit " .. vim.fn.fnamemodify(path, ":t") .. " in a new tab"
  for mode, keys in pairs(M.EDIT_KEYS) do
    for _, lhs in ipairs(keys) do
      if not claimed(buf, mode, lhs) then
        pcall(vim.keymap.set, mode, lhs, function()
          edit_on_disk(buf, path, kind, lhs, mode == "x")
        end, { buffer = buf, nowait = true, silent = true, desc = desc })
      end
    end
  end
end

---Highlight whole lines, the way the live cursor marks what Claude read — in
---the same group, so `live_cursor.highlight` reaches this view too.
---@param buf integer
---@param ranges { start_line: integer, num_lines: integer }[]
---@return integer|nil first_line
local function paint_reads(buf, ranges)
  if #ranges == 0 then
    return nil
  end
  local ok, live_cursor = pcall(require, "claudecode.live_cursor")
  local hl = (ok and live_cursor.read_highlight and live_cursor.read_highlight()) or "ClaudeCodeLiveCursor"
  local count = vim.api.nvim_buf_line_count(buf)
  local first = nil
  for _, range in ipairs(ranges) do
    local from = math.max(1, math.min(range.start_line or 1, count))
    local to = math.max(from, math.min(from + (range.num_lines or 1) - 1, count))
    first = first or from
    for row = from, to do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row - 1, 0, {
        line_hl_group = hl,
        priority = 200,
      })
    end
  end
  return first
end

---Show a file with the lines a session read marked, and land on the first one.
---
---Both callers of this — an Activity row for one read, and a Changes row for a
---file the session never edited — differ only in where the ranges come from.
---@param session_id string|nil
---@param path string
---@param title string
---@param ranges { start_line: integer, num_lines: integer }[]
---@param line integer|nil Explicit line to land on; the first read otherwise.
---@param reuse integer|nil Float to swap this into, rather than stacking a new one.
---@return integer|nil win
local function open_read(session_id, path, title, ranges, line, reuse)
  local lines = read_lines(path)
  if not lines or #ranges == 0 then
    return nil
  end
  local buf = scratch(lines, "claudecode://read/" .. path)
  if not buf then
    return nil
  end
  set_filetype(buf, path)
  local win = float.create(session_id, { title = title, buf = buf, reuse = reuse })
  if not win then
    return nil
  end
  local first = paint_reads(buf, ranges)
  float.jump_to(win, line or first)
  float.bind_close(win)
  bind_edit_keys(win, path, "file")
  return win
end

---Show the session's patches as diff text.
---@param session_id string|nil
---@param path string
---@param hunks table[]
---@param title string
---@param reuse integer|nil Float to swap this into, rather than stacking a new one.
---@return integer|nil win
local function open_patch_text(session_id, path, hunks, title, reuse)
  local buf = scratch(patch.to_diff_lines(path, hunks), "claudecode://diff/" .. path)
  if not buf then
    return nil
  end
  pcall(vim.api.nvim_set_option_value, "filetype", "diff", { buf = buf })
  local win = float.create(session_id, { title = title, buf = buf, reuse = reuse })
  if not win then
    return nil
  end
  float.bind_close(win)
  bind_edit_keys(win, path, "patch")
  return win
end

---Show today's file with the session's changes rendered inline.
---@param session_id string|nil
---@param path string
---@param lines string[] The file as it is now.
---@param before string[] What the session started from.
---@param title string
---@param reuse integer|nil Float to swap this into, rather than stacking a new one.
---@return integer|nil win
---@return integer|nil buf
local function open_inline_diff(session_id, path, lines, before, title, reuse)
  local buf = scratch(lines, "claudecode://changes/" .. path)
  if not buf then
    return nil
  end
  set_filetype(buf, path)

  local win = float.create(session_id, { title = title, buf = buf, reuse = reuse })
  if not win then
    return nil
  end

  local ok_diff, diff = pcall(require, "claudecode.diff")
  if ok_diff and diff.ensure_unified_initialized then
    pcall(diff.ensure_unified_initialized)
  end
  local unified_diff = require("unified.diff")
  -- unified.nvim diffs against the buffer's text *with* its final newline whenever
  -- 'endofline' is set, which a scratch buffer always has. A baseline without one
  -- differed on its last line, so every diff marked the file's last line changed.
  local base = table.concat(before, "\n")
  local ok_eol, eol = pcall(vim.api.nvim_get_option_value, "endofline", { buf = buf })
  if #before > 0 and (not ok_eol or eol ~= false) then
    base = base .. "\n"
  end
  if not pcall(unified_diff.show_against_text, buf, base) then
    float.close(win)
    return nil
  end

  -- Land on the first change rather than the top of the file: on a long file the
  -- edit is usually nowhere near line 1.
  local hunks = vim.b[buf].unified_hunks or {}
  float.jump_to(win, hunks[1] or 1, true)
  float.bind_close(win)
  bind_edit_keys(win, path, "file")
  return win, buf
end

---Show a plain unified diff as text, for when unified.nvim cannot render one.
---@param session_id string|nil
---@param path string
---@param before string[]
---@param after string[]
---@param title string
---@param reuse integer|nil Float to swap this into, rather than stacking a new one.
---@param rev string What `before` is, for the header: `HEAD`, or svn's `BASE`.
---@return integer|nil win
local function open_text_diff(session_id, path, before, after, title, reuse, rev)
  -- `vim.diff` is a Neovim built-in, so the answer is still a diff on a machine
  -- with no unified.nvim — just not an inline one.
  -- An empty side is empty text, not one blank line: a deleted file would
  -- otherwise read as replaced by a single empty line.
  local function text_of(lines)
    return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
  end
  local ok, text = pcall(vim.diff, text_of(before), text_of(after), {
    result_type = "unified",
    ctxlen = 3,
  })
  if not ok or type(text) ~= "string" or text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  table.insert(lines, 1, "+++ " .. path .. " (working tree)")
  table.insert(lines, 1, "--- " .. path .. " (" .. rev .. ")")
  local buf = scratch(lines, "claudecode://head/" .. path)
  if not buf then
    return nil
  end
  pcall(vim.api.nvim_set_option_value, "filetype", "diff", { buf = buf })
  local win = float.create(session_id, { title = title, buf = buf, reuse = reuse })
  if not win then
    return nil
  end
  float.bind_close(win)
  bind_edit_keys(win, path, "patch")
  return win
end

---Every state the file passed through in the session, from the record alone
---(`patch.reconstruct`), computed once per history — a history is replaced, never
---mutated, when the transcript grows.
---@param history ClaudeCodeAgentsFileHistory
---@return table<integer, string[]>
local function reconstruction(history)
  if not history.reconstruction then
    history.reconstruction = patch.reconstruct(history.steps or {}, history.read_anchor)
  end
  return history.reconstruction
end

---Show a run of consecutive calls as one edit: the file as the last call left
---it, against what the first one found.
---
---One call (an Activity row: `first == last`) or an era's worth of them (a
---Changes row between checkpoints) — the same question either way, "what did
---this span of the session do here", and the same two ways to answer it.
---
---Both sides come from the record when it holds enough to rebuild them
---(`patch.reconstruct`: an `originalFile`, a whole read or a `Write`'s content
---somewhere in the session, and the hunks between), and the title says so —
---`reconstructed` is the file as it stood then, not as it is now.
---
---Without an anchor the moment is rebuilt from today's file instead: every later
---step undone first (`patch.reverse_apply`, newest first), then the span's own for
---the other side, titled `on disk`. A hunk that no longer locates means something
---outside the session has touched those lines since; then the span's own patches
---are shown as diff text, which is the record itself, and the title says why.
---@param opts table `M.open`'s opts.
---@param history ClaudeCodeAgentsFileHistory
---@param first integer Position of the first step in `history.steps`.
---@param last integer Position of the last.
---@param what string How the title names the span: `edit 3 of 7`, `since 14:32`.
---@param title_for fun(note: string|nil): string
---@param whole boolean The span is an era rather than one call: a span that left the file as it found it says so instead of opening an empty diff.
---@return integer|nil win
local function open_range(opts, history, first, last, what, title_for, whole)
  local steps = history.steps
  local path = opts.path
  local own = {}
  for i = first, last do
    for _, hunk in ipairs(steps[i].hunks or {}) do
      own[#own + 1] = hunk
    end
  end

  ---@param reason string|nil
  ---@return integer|nil
  local function patches(reason)
    local note = reason and (what .. ", " .. reason) or what
    if reason then
      logger.debug("agents", "file_view:", what, "of", path, "-", reason, "- showing its patch")
    end
    return open_patch_text(opts.session_id, path, own, title_for("(" .. note .. ")"), opts.reuse)
  end

  ---@param before string[]
  ---@param after string[]
  ---@return boolean unchanged The span left the file as it found it, and said so.
  local function unchanged(before, after)
    if whole and M._same_lines(before, after) then
      local name = vim.fn.fnamemodify(path, ":t")
      vim.notify("ClaudeCode: " .. name .. " was left as it was found (" .. what .. ")", vim.log.levels.INFO)
      return true
    end
    return false
  end

  if not unified_available() then
    return patches(nil)
  end

  local states = reconstruction(history)
  local before, after = states[first - 1], states[last]
  if before and after then
    if unchanged(before, after) then
      return nil
    end
    local title = title_for("(" .. what .. ", reconstructed)")
    local win = open_inline_diff(opts.session_id, path, after, before, title, opts.reuse)
    if win then
      return win
    end
  end

  local lines = read_lines(path)
  if not lines then
    return patches("deleted")
  end
  local later = {}
  for i = last + 1, #steps do
    for _, hunk in ipairs(steps[i].hunks or {}) do
      later[#later + 1] = hunk
    end
  end
  local rebuilt, _, skipped = patch.reverse_apply(lines, later)
  if skipped > 0 then
    return patches("file moved on")
  end
  after = rebuilt

  before = {}
  if not steps[first].created then
    local applied
    before, applied, skipped = patch.reverse_apply(after, own)
    if skipped > 0 or applied == 0 then
      return patches("file moved on")
    end
  end
  if unchanged(before, after) then
    return nil
  end

  local win = open_inline_diff(opts.session_id, path, after, before, title_for("(" .. what .. ", on disk)"), opts.reuse)
  return win or patches(nil)
end

---Show one call's edit: the file as that call left it, against what it found.
---
---An Activity row is one tool call, so its diff is that call's, not the session's;
---the title says which of the session's edits to the file it is.
---@param opts table `M.open`'s opts.
---@param history ClaudeCodeAgentsFileHistory
---@param index integer Position of the step in `history.steps`.
---@param title_for fun(note: string|nil): string
---@return integer|nil win
local function open_step(opts, history, index, title_for)
  local steps = history.steps
  local what = string.format("%s %d of %d", steps[index].kind, index, #steps)
  return open_range(opts, history, index, index, what, title_for, false)
end

---The steps an era covers: those after `from` and up to `to`, either bound open.
---@param steps ClaudeCodeAgentsFileStep[]
---@param era { from: number?, to: number? }
---@return integer|nil first
---@return integer|nil last
local function era_steps(steps, era)
  local first, last = nil, nil
  for index, step in ipairs(steps) do
    local ts = tonumber(step.ts) or 0
    if (not era.from or ts > era.from) and (not era.to or ts <= era.to) then
      first = first or index
      last = index
    end
  end
  return first, last
end

---Whether two files are line-for-line identical.
---
---Compared element-wise rather than by concatenating both into one string each:
---a modified file usually differs early, so this bails long before it has built
---two copies of the whole file — and it is asked once per `.` press and once per
---`<C-n>` step inside a HEAD float, so a held key asks it at key-repeat speed.
---@param a string[]
---@param b string[]
---@return boolean
function M._same_lines(a, b)
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

---Why a file's committed content could not be read at all, as a notification;
---nil when the reader answered (even with "not committed").
---@param name string
---@param info table|nil The reader's second answer; see `git.file_at_head`.
---@return string|nil
local function unreadable_reason(name, info)
  if info and info.failed then
    return "could not run " .. (info.vcs or "git")
  end
  if info and info.unversioned then
    return name .. " is not in a git or svn working copy"
  end
  return nil
end

---Show a file against `HEAD`, rather than against what a session started from.
---
---The session diff answers "what did this agent do here", which is the question
---the panes ask — but the neighbouring one, "what is uncommitted in this file",
---is asked just as often once several agents have been over the same tree, and
---no session's history can answer it. Same float, same inline rendering, a
---different baseline. In an svn working copy the baseline is `BASE`, the
---revision the file was last updated to, and the float says so.
---@param opts { session_id: string?, path: string, line: integer?, cwd: string?, reuse: integer? }
---@param done fun(win: integer|nil)|nil
function M.open_against_head(opts, done)
  local path = opts and opts.path
  local function finish(win)
    if done then
      done(win)
    end
    return win
  end
  if type(path) ~= "string" or path == "" then
    return finish(nil)
  end

  local name = vim.fn.fnamemodify(path, ":t")
  local lines = read_lines(path)
  if not lines then
    -- Deleted: what HEAD holds is what was removed. The inline renderer needs
    -- the file's own buffer, and a buffer on a missing path is one `:w` from
    -- resurrecting it, so this is always shown as diff text.
    require("claudecode.agents.git").file_at_head(path, function(head, info)
      local rev = info and info.rev or "HEAD"
      if not head then
        local reason = unreadable_reason(name, info) or (name .. " is not on disk")
        vim.notify("ClaudeCode: " .. reason, vim.log.levels.WARN)
        return finish(nil)
      end
      local title = M.title(path, opts.cwd, "(deleted since " .. rev .. ")")
      return finish(open_text_diff(opts.session_id, path, head, {}, title, opts.reuse, rev))
    end)
    return
  end

  require("claudecode.agents.git").file_at_head(path, function(head, info)
    local rev = info and info.rev or "HEAD"
    -- Neither a repository nor a command that ran: diffing against nothing would
    -- claim every line is new, which is not what anyone asked.
    local reason = unreadable_reason(name, info)
    if reason then
      vim.notify("ClaudeCode: " .. reason, vim.log.levels.WARN)
      return finish(nil)
    end

    -- Not committed: untracked, or added since. Diffing against nothing reads
    -- every line as an addition, which is what it is.
    local before = head or {}
    local title = M.title(path, opts.cwd, head and ("(vs " .. rev .. ")") or ("(new since " .. rev .. ")"))

    if head and M._same_lines(head, lines) then
      vim.notify("ClaudeCode: " .. name .. " matches " .. rev, vim.log.levels.INFO)
      return finish(nil)
    end

    if unified_available() then
      local win = open_inline_diff(opts.session_id, path, lines, before, title, opts.reuse)
      if win then
        return finish(win)
      end
    end
    return finish(open_text_diff(opts.session_id, path, before, lines, title, opts.reuse, rev))
  end)
end

---Open a file from one of the panes, showing what the session did to it.
---
---`prefer = "step"` with a `tool_id` shows that one call's edit (see `open_step`);
---a call the history holds no step for falls back to the session's whole diff.
---`era` (a Changes row between checkpoints) shows the edits inside that span as
---one diff (`open_range`), titled by the era's `note`; an era the history holds
---no step for falls back the same way.
---@param opts { session_id: string?, transcript: string?, path: string, line: integer?,
---             read: { start_line: integer, num_lines: integer }?, prefer: "diff"|"read"|"step"?,
---             tool_id: string?, era: { from: number?, to: number?, note: string }?,
---             cwd: string?, reuse: integer? }
---@param done fun(win: integer|nil)|nil Called once the float is up (the history read is async).
function M.open(opts, done)
  local path = opts and opts.path
  if type(path) ~= "string" or path == "" then
    if done then
      done(nil)
    end
    return
  end
  ---@param note string|nil
  ---@return string
  local function title_for(note)
    return M.title(path, opts.cwd, note)
  end

  local function finish(win)
    if done then
      done(win)
    end
  end

  -- An Activity row for a read is about that one read: show the file with the
  -- lines it covered marked, and nothing else.
  if opts.prefer == "read" and opts.read then
    -- No explicit line: the read's own first line *is* what this row is about.
    local win = open_read(opts.session_id, path, title_for("(read)"), { opts.read }, nil, opts.reuse)
    if win then
      return finish(win)
    end
  end

  if not opts.transcript then
    return finish(float.open_file(opts.session_id, path, opts.line, opts.reuse, title_for(nil)))
  end

  ---The session's whole work on the file: today's content against what it
  ---started from.
  ---@param history ClaudeCodeAgentsFileHistory|nil
  local function show_history(history)
    local hunks = (history and history.hunks) or {}
    local created = history and history.created

    if #hunks == 0 and not created then
      -- The session only read this file: show it with every window it read marked.
      local reads = (history and history.reads) or {}
      local win = open_read(opts.session_id, path, title_for("(read)"), reads, opts.line, opts.reuse)
      return finish(win or float.open_file(opts.session_id, path, opts.line, opts.reuse, title_for(nil)))
    end

    if not unified_available() then
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(session changes)"), opts.reuse))
    end

    -- From the record alone, when it holds enough: the file as the session found
    -- it against the file as it left it, whatever has happened to it since. The
    -- title says `reconstructed` — this is not today's file.
    local steps = (history and history.steps) or {}
    local states = history and reconstruction(history) or {}
    local start, last = states[0], states[#steps]
    if #steps > 0 and start and last then
      if M._same_lines(start, last) then
        local name = vim.fn.fnamemodify(path, ":t")
        vim.notify("ClaudeCode: the session left " .. name .. " as it found it", vim.log.levels.INFO)
        return finish(nil)
      end
      local title = title_for("(session changes, reconstructed)")
      local win = open_inline_diff(opts.session_id, path, last, start, title, opts.reuse)
      if win then
        return finish(win)
      end
    end

    -- No anchor in the record: undo the session's hunks on today's file instead,
    -- which decays as the file moves on — and the title says `on disk`.
    local lines = read_lines(path)
    if not lines then
      -- Gone from disk: the patches are all that is left of it, and they are enough.
      logger.debug("agents", "file_view: no file on disk for", path, "- showing its patches")
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(deleted)"), opts.reuse))
    end

    -- A file the session created has an empty baseline: every line is an addition.
    local before, applied, skipped
    if created and #hunks == 0 then
      before, applied, skipped = {}, 0, 0
    else
      before, applied, skipped = patch.reverse_apply(lines, hunks)
      if created then
        before = {}
      end
    end

    if applied == 0 and not created then
      -- Nothing the session did is still in this file; showing it against itself
      -- would claim it changed nothing.
      logger.debug("agents", "file_view: no hunk located in", path, "- showing its patches")
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(session changes)"), opts.reuse))
    end

    local note = "(on disk)"
    if skipped > 0 then
      -- Say it rather than quietly showing a partial diff: the rest of the session's
      -- work is not missing, it was overwritten after the session ran.
      note = string.format("(on disk, %d/%d changes still present)", applied, applied + skipped)
    end

    local win = open_inline_diff(opts.session_id, path, lines, before, title_for(note), opts.reuse)
    if not win then
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(session changes)"), opts.reuse))
    end
    return finish(win)
  end

  transcript.file_history(opts.transcript, path, function(history)
    if opts.prefer == "step" and opts.tool_id and history then
      for index, step in ipairs(history.steps or {}) do
        if step.tool_id == opts.tool_id then
          return finish(open_step(opts, history, index, title_for))
        end
      end
    end
    if type(opts.era) == "table" and history then
      local first, last = era_steps(history.steps or {}, opts.era)
      if first and last then
        local what = opts.era.note
        if not what or what == "" then
          what = string.format("edits %d-%d", first, last)
        end
        return finish(open_range(opts, history, first, last, what, title_for, true))
      end
    end
    return show_history(history)
  end)
end

return M
