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
