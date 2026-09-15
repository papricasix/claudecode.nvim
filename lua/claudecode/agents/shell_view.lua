---@brief [[
--- What `<CR>` on a background shell shows: the command, how it stands, and its
--- output — followed live while it runs.
---
--- The transcript never holds a background shell's output. The CLI streams it into
--- a file of its own and says where in the call's result ("Output is being written
--- to: …/tasks/<id>.output"), which is what `transcript.lua` records; the float
--- tails that file. It is the same file the agent itself reads to check on the
--- command, so the float shows exactly what the agent can see.
---
--- The file is raw terminal output, so it goes through three things on the way in:
---
--- * **Carriage returns.** A progress bar redraws its line with `\r`; only what
---   follows the last one in a line is what a terminal would be showing.
--- * **Escape codes**, through `agents/ansi.lua`, with the colour state carried
---   from one read to the next.
--- * **An unfinished last line**, drawn as it stands and replaced when the rest of
---   it arrives.
---
--- The file can be large (the CLI allows 5GB), so the first read starts
--- TAIL_BYTES from the end, and a follow that grows the buffer past MAX_LINES drops
--- the oldest. The rule above the output says whenever something was left out.
---
--- The output file does not always outlive the command: the temp directory can be
--- swept, and the CLI removes some itself. The float then says so, and still shows
--- the command and how it ended.
---@brief ]]
---@module 'claudecode.agents.shell_view'

local ansi = require("claudecode.agents.ansi")
local float = require("claudecode.agents.float")
local subagents = require("claudecode.agents.subagents")
local tools = require("claudecode.agents.tools")
local transcript = require("claudecode.agents.transcript")
local utils = require("claudecode.utils")

local M = {}

local ns_head = vim.api.nvim_create_namespace("claudecode_agents_shell_view_head")
local ns_out = vim.api.nvim_create_namespace("claudecode_agents_shell_view_output")

--- How often an open float looks for more output.
M.FOLLOW_MS = 500

--- The first read starts this far from the end of the file.
M.TAIL_BYTES = 1024 * 1024

--- Output lines kept in the buffer; past MAX_LINES + TRIM_SLACK the oldest go.
M.MAX_LINES = 10000
local TRIM_SLACK = 1000

local STATE_GLYPH = { running = "●", done = "✓", failed = "✗", stopped = "⊘" }
local STATE_HL = { done = "time", failed = "failed", stopped = "stopped" }

--------------------------------------------------------------------------------
-- Pure pieces
--------------------------------------------------------------------------------

---The session transcript a transcript belongs to: itself, or for a subagent's
---(`<session>/subagents/agent-<id>.jsonl`) the session's beside that directory.
---@param path string|nil
---@return string|nil
function M.session_path(path)
  if type(path) ~= "string" then
    return nil
  end
  local base = path:match("^(.*)[/\\]subagents[/\\]agent%-[^/\\]+%.jsonl$")
  return base and (base .. ".jsonl") or path
end

---What a terminal would be showing of one line: the text after its last carriage
---return. A CRLF line ending is not a redraw, so a trailing `\r` is dropped first.
---@param raw string
---@return string
function M.collapse_cr(raw)
  raw = raw:gsub("\r+$", "")
  return raw:match("([^\r]*)$") or raw
end

---How much of a line the CLI wrote rather than the command: the `[stderr] ` a
---monitor's file prefixes stderr with, or the whole closing line.
---@param line string
---@return integer|nil end_col
function M.harness_span(line)
  if line:sub(1, 9) == "[stderr] " then
    return 8
  end
  if line:match("^%[exited with code %-?%d+%]$") or line == "[killed]" then
    return #line
  end
  return nil
end

---A reader of streamed output.
---@return { carry: string, sgr: table, skip_partial: boolean }
function M.new_stream()
  return { carry = "", sgr = {}, skip_partial = false }
end

---Feed the stream what was read, getting back what to draw.
---
---`lines` is every line that is now complete, followed by the unfinished one when
---there is one; `complete` says how many are the former. The unfinished line is
---parsed from a copy of the colour state, since it will be parsed again once the
---rest of it arrives.
---@param stream table From `new_stream`.
---@param data string
---@return { lines: string[], marks: table[], complete: integer }
function M.feed(stream, data)
  local text = stream.carry .. data
  local pieces = {}
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if not nl then
      break
    end
    pieces[#pieces + 1] = text:sub(start, nl - 1)
    start = nl + 1
  end
  stream.carry = text:sub(start)

  -- A read that began mid-file starts mid-line; that fragment is not shown.
  if stream.skip_partial and #pieces > 0 then
    table.remove(pieces, 1)
    stream.skip_partial = false
  end

  for index, piece in ipairs(pieces) do
    pieces[index] = M.collapse_cr(piece)
  end
  local lines, marks = ansi.parse(pieces, stream.sgr)
  local complete = #lines

  if stream.carry ~= "" and not stream.skip_partial then
    local sgr = {}
    for key, value in pairs(stream.sgr) do
      sgr[key] = value
    end
    local tail, tail_marks = ansi.parse({ M.collapse_cr(stream.carry) }, sgr)
    lines[#lines + 1] = tail[1]
    for _, mark in ipairs(tail_marks) do
      mark.row = complete
      marks[#marks + 1] = mark
    end
  end
  return { lines = lines, marks = marks, complete = complete }
end

---`1.2 MB`, `512 KB`.
---@param bytes number
---@return string
local function format_bytes(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MB"):format(bytes / (1024 * 1024))
  end
  return ("%d KB"):format(math.max(1, math.floor(bytes / 1024 + 0.5)))
end

---How a shell stands, in words: `● running · 0:42`, `✗ exit 144 · 0:13`.
---@param row ClaudeCodeSubagentRow|nil
---@return string text
---@return string|nil glyph
function M.status_text(row)
  if not row or not row.state then
    return "", nil
  end
  local glyph = STATE_GLYPH[row.state] or "⊘"
  local word
  if row.state == "running" then
    word = row.task_type == "monitor" and "watching" or "running"
  elseif row.exit_code then
    word = "exit " .. row.exit_code
  elseif row.state == "stopped" then
    word = row.how == "expired" and "expired" or "stopped"
  else
    word = row.state
  end
  local parts = { glyph .. " " .. word }
  if row.runtime_s then
    parts[#parts + 1] = subagents.format_runtime(row.runtime_s)
  end
  if row.task_type == "monitor" and row.events then
    parts[#parts + 1] = row.events == 1 and "1 event" or (row.events .. " events")
  end
  if row.by_user then
    parts[#parts + 1] = "sent to the background with Ctrl+B"
  end
  return table.concat(parts, " · "), glyph
end

---The rule above the output, carrying whatever has to be said about it.
---@param view table
---@return string
function M.rule_text(view)
  local notes = {}
  if view.missing then
    notes[#notes + 1] = view.output_path and "no longer on disk" or "the CLI did not say where it went"
  end
  if (view.skipped_bytes or 0) > 0 then
    notes[#notes + 1] = "first " .. format_bytes(view.skipped_bytes) .. " not shown"
  end
  if (view.dropped or 0) > 0 then
    notes[#notes + 1] = view.dropped .. " earlier lines not shown"
  end
  if view.row and view.row.state == "running" and not view.missing and view.done == 0 and not view.has_tail then
    notes[#notes + 1] = "nothing yet"
  end
  local label = "output"
  if #notes > 0 then
    label = label .. " · " .. table.concat(notes, " · ")
  end
  return tools.rule(label)
end

---The float's border title: what the shell is for, and how it stands.
---@param row ClaudeCodeSubagentRow|nil
---@return string
function M.title(row)
  row = row or {}
  local name = row.description or row.command or (row.task_type == "monitor" and "monitor" or "background shell")
  name = name:gsub("%s+", " ")
  local status = M.status_text(row)
  local budget = math.max(10, float.title_width())
  local room = budget - (status ~= "" and (vim.fn.strdisplaywidth(status) + 2) or 0)
  local mark = row.task_type == "monitor" and "~ " or "$ "
  local text = mark .. utils.truncate(name, math.max(8, room - 2))
  return status ~= "" and (text .. "  " .. status) or text
end

--------------------------------------------------------------------------------
-- The float
--------------------------------------------------------------------------------

--- Open viewers, by buffer.
local views = {}

---This shell's row, as the pane knows it or as the files say.
---@param view table
---@return ClaudeCodeSubagentRow|nil
local function lookup_row(view)
  local from_pane = view.opts.row_for and view.opts.row_for(view.task_id)
  if from_pane then
    return from_pane
  end
  for _, row in ipairs(subagents.rows(view.session_path, { live = nil })) do
    if row.kind == "shell" and row.id == view.task_id then
      return row
    end
  end
  return nil
end

---@param buf integer
---@param fn fun()
local function with_modifiable(buf, fn)
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
  pcall(fn)
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
end

---Rewrite the status line and the rule when what they say has changed.
---@param buf integer
---@param view table
local function paint_head(buf, view)
  local status, glyph = M.status_text(view.row)
  local rule = M.rule_text(view)
  if status == view.status_shown and rule == view.rule_shown then
    return
  end
  view.status_shown, view.rule_shown = status, rule
  with_modifiable(buf, function()
    vim.api.nvim_buf_set_lines(buf, view.status_row, view.status_row + 2, false, { status, rule })
  end)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns_head, view.status_row, view.status_row + 2)
  local render = require("claudecode.agents.render")
  local group = view.row and STATE_HL[view.row.state]
  if glyph and group then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_head, view.status_row, 0, {
      end_col = #glyph,
      hl_group = render.highlight(group),
    })
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_head, view.status_row + 1, 0, {
    end_col = #rule,
    hl_group = render.highlight("time"),
  })

  local title = M.title(view.row)
  if title ~= view.title and vim.fn.has("nvim-0.9") == 1 then
    view.title = title
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      pcall(vim.api.nvim_win_set_config, win, { title = " " .. title .. " ", title_pos = "center" })
    end
  end
end

---Draw what a read produced, replacing the unfinished line drawn last time.
---@param buf integer
---@param view table
---@param drawn { lines: string[], marks: table[], complete: integer }
local function paint_output(buf, view, drawn)
  local wins = vim.fn.win_findbuf(buf)
  local before = vim.api.nvim_buf_line_count(buf)
  local follow = {}
  for _, win in ipairs(wins) do
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
    follow[win] = ok and pos[1] >= before
  end

  local start = view.head_rows + view.done
  with_modifiable(buf, function()
    vim.api.nvim_buf_set_lines(buf, start, -1, false, drawn.lines)
  end)
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns_out, start, -1)
  for _, mark in ipairs(drawn.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns_out, start + mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
      priority = 100,
    })
  end
  -- What the CLI itself writes into the file — a monitor's `[stderr] ` prefix, the
  -- closing `[exited with code N]` / `[killed]` — is drawn quietly.
  local quiet = require("claudecode.agents.render").highlight("time")
  for index, line in ipairs(drawn.lines) do
    local span = M.harness_span(line)
    if span then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_out, start + index - 1, 0, {
        end_col = span,
        hl_group = quiet,
        priority = 90,
      })
    end
  end
  view.done = view.done + drawn.complete
  view.has_tail = #drawn.lines > drawn.complete

  -- Keep the buffer bounded for a command that never stops talking.
  if view.done > M.MAX_LINES + TRIM_SLACK then
    local excess = view.done - M.MAX_LINES
    with_modifiable(buf, function()
      vim.api.nvim_buf_set_lines(buf, view.head_rows, view.head_rows + excess, false, {})
    end)
    view.done = view.done - excess
    view.dropped = (view.dropped or 0) + excess
  end

  if not view.filetype_set and view.done > 0 then
    view.filetype_set = true
    local sample = vim.api.nvim_buf_get_lines(buf, view.head_rows, view.head_rows + 40, false)
    local ft = tools.detect_filetype(view.command, sample)
    if ft then
      pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
    end
  end

  local count = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(wins) do
    if follow[win] then
      pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
    end
  end
end

---Read whatever the output file gained since the last read, then repaint.
---@param buf integer
---@param done fun(grew: boolean)|nil
local function pull(buf, done)
  local view = views[buf]
  if not view or view.reading then
    return
  end
  local function finish(grew)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) and views[buf] == view then
        paint_head(buf, view)
      end
      if done then
        done(grew)
      end
    end)
  end

  local st = view.output_path and transcript._io.stat(view.output_path) or nil
  view.missing = st == nil
  if not st then
    return finish(false)
  end
  if st.size < view.offset then
    -- Truncated or replaced under us: start again from what is there now.
    view.offset, view.stream, view.done, view.dropped = 0, M.new_stream(), 0, 0
    view.skipped_bytes = 0
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        with_modifiable(buf, function()
          vim.api.nvim_buf_set_lines(buf, view.head_rows, -1, false, {})
        end)
      end
    end)
  end
  if view.offset == 0 and st.size > M.TAIL_BYTES then
    view.offset = st.size - M.TAIL_BYTES
    view.skipped_bytes = view.offset
    view.stream.skip_partial = true
  end
  if st.size == view.offset then
    return finish(false)
  end

  view.reading = true
  local size = st.size
  local function step()
    if view.offset >= size then
      view.reading = false
      return finish(true)
    end
    local want = math.min(transcript._chunk_size, size - view.offset)
    transcript._io.read(view.output_path, view.offset, want, function(data)
      -- Drawn on the main loop: the read answers in libuv's fast context.
      vim.schedule(function()
        if not data or data == "" or views[buf] ~= view or not vim.api.nvim_buf_is_valid(buf) then
          view.reading = false
          if done then
            done(false)
          end
          return
        end
        view.offset = view.offset + #data
        paint_output(buf, view, M.feed(view.stream, data))
        step()
      end)
    end)
  end
  step()
end

---@param view table
local function stop_timer(view)
  local timer = view and view.timer
  if timer then
    view.timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
end

---@param buf integer
local function forget(buf)
  local view = views[buf]
  views[buf] = nil
  stop_timer(view)
end

--- Injectable: specs drive the follow tick by hand.
M._new_timer = function()
  return vim.loop and vim.loop.new_timer and vim.loop.new_timer() or nil
end

---Build the float once the command is known.
---@param opts table
---@param command string|nil The whole command, when the transcript still had it.
---@param done fun(win: integer|nil)
local function show(opts, command, done)
  local session_path = M.session_path(opts.transcript)
  local view = {
    opts = opts,
    task_id = opts.task_id,
    session_path = session_path,
    offset = 0,
    stream = M.new_stream(),
    done = 0,
    dropped = 0,
    skipped_bytes = 0,
  }
  view.row = lookup_row(view)
  local row = view.row or {}
  view.command = command or row.command
  view.output_path = row.output_path

  local head = tools.command_lines(row.agent_type or "Bash", { command = view.command })
  if #head == 0 then
    head = { "$ " .. (view.command or "?") }
  end
  if row.description then
    table.insert(head, 1, "# " .. row.description:gsub("%s+", " "))
  end
  head[#head + 1] = ""
  view.status_row = #head
  head[#head + 1] = "" -- status, painted by paint_head
  head[#head + 1] = "" -- rule
  view.head_rows = #head

  local buf = float.scratch(head, "claudecode://shell/" .. tostring(opts.task_id))
  if not buf then
    return done(nil)
  end
  pcall(vim.api.nvim_set_option_value, "undolevels", -1, { buf = buf })
  views[buf] = view

  view.title = M.title(view.row)
  local win = float.create(opts.session_id, { title = view.title, buf = buf, reuse = opts.reuse, purpose = "open" })
  if not win then
    forget(buf)
    return done(nil)
  end
  float.bind_close(win)
  paint_head(buf, view)

  pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      forget(buf)
    end,
  })

  -- Land at the end: the newest output is what a running command is opened for,
  -- and a cursor on the last line is what keeps the float following it.
  pull(buf, function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end)

  local timer = M._new_timer()
  if timer then
    view.timer = timer
    timer:start(
      M.FOLLOW_MS,
      M.FOLLOW_MS,
      vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(buf) or views[buf] ~= view then
          forget(buf)
          return
        end
        if #vim.fn.win_findbuf(buf) == 0 then
          return
        end
        -- The notification that ends the shell lands in a transcript the pane only
        -- keeps folded for the session it has selected.
        subagents.refresh(view.session_path)
        view.row = lookup_row(view) or view.row
        view.output_path = view.output_path or (view.row and view.row.output_path)
        pull(buf, function(grew)
          -- Ended, and a tick later the file still has nothing more (the last
          -- write can land after the notification): nothing left to follow.
          -- Only an end the CLI recorded counts: a shell read as stopped because it
          -- went quiet may yet write again.
          if not grew and view.row and view.row.ended and views[buf] == view then
            if view.settled then
              stop_timer(view)
            else
              view.settled = true
            end
          end
        end)
      end)
    )
  end
  return done(win)
end

---Open (or swap into `opts.reuse`) one background shell.
---@param opts { session_id: string?, transcript: string, task_id: string, tool_id: string?, reuse: integer?,
---             command: string?, row_for: (fun(id: string): ClaudeCodeSubagentRow|nil)? }
---             `transcript` is the one that launched the shell (the session's, or a subagent's);
---             `command` the whole command, when the caller has already read it.
---@param done fun(win: integer|nil)|nil
function M.open(opts, done)
  local function finish(win)
    if done then
      done(win)
    end
  end
  if type(opts) ~= "table" or type(opts.task_id) ~= "string" or type(opts.transcript) ~= "string" then
    return finish(nil)
  end
  if opts.command then
    return show(opts, opts.command, finish)
  end
  -- The whole command lives only in the call; the row carries one cut line of it.
  if type(opts.tool_id) == "string" and opts.tool_id ~= "" then
    transcript.tool_call(opts.transcript, opts.tool_id, function(call)
      local input = call and call.input
      local command = type(input) == "table" and type(input.command) == "string" and input.command or nil
      show(opts, command, finish)
    end)
    return
  end
  show(opts, nil, finish)
end

---Test/reload helper.
function M.reset()
  for buf in pairs(views) do
    forget(buf)
  end
  views = {}
end

---@return table
function M._views()
  return views
end

return M
