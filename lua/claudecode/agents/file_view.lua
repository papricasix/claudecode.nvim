---@brief [[
--- What opening a file from the Changes or Activity pane shows.
---
--- Opening it plain answers "what does this file look like", which is not the
--- question either pane asks. The Changes pane is a list of what the agent changed,
--- so `<CR>` on a row shows *that change* — the same inline unified diff the live
--- cursor renders while an edit happens, only cumulative: today's file against what
--- the session started from (`agents/patch.lua` reconstructs that by undoing the
--- session's own hunks). An Activity row is one tool call, so `<CR>` on a read
--- highlights the lines that read covered, exactly as the live cursor does.
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
  return win
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
---@param opts { session_id: string?, transcript: string?, path: string, line: integer?,
---             read: { start_line: integer, num_lines: integer }?, prefer: "diff"|"read"?,
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

  transcript.file_history(opts.transcript, path, function(history)
    local hunks = (history and history.hunks) or {}
    local created = history and history.created

    if #hunks == 0 and not created then
      -- The session only read this file: show it with every window it read marked.
      local reads = (history and history.reads) or {}
      local win = open_read(opts.session_id, path, title_for("(read)"), reads, opts.line, opts.reuse)
      return finish(win or float.open_file(opts.session_id, path, opts.line, opts.reuse, title_for(nil)))
    end

    local lines = read_lines(path)
    if not lines then
      -- Gone from disk: the patches are all that is left of it, and they are enough.
      logger.debug("agents", "file_view: no file on disk for", path, "- showing its patches")
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(deleted)"), opts.reuse))
    end

    if not unified_available() then
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(session changes)"), opts.reuse))
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

    local note = nil
    if skipped > 0 then
      -- Say it rather than quietly showing a partial diff: the rest of the session's
      -- work is not missing, it was overwritten after the session ran.
      note = string.format("(%d/%d changes still present)", applied, applied + skipped)
    end

    local win = open_inline_diff(opts.session_id, path, lines, before, title_for(note), opts.reuse)
    if not win then
      return finish(open_patch_text(opts.session_id, path, hunks, title_for("(session changes)"), opts.reuse))
    end
    return finish(win)
  end)
end

return M
