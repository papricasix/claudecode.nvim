---@brief [[
--- What `<CR>` on a Subagents row shows: the run's whole transcript, rendered.
---
--- The headline is the run itself — what it was sent to do, in full, and its type,
--- state, tokens and runtime — and below it the conversation as Markdown: the prompt
--- it was given, what it said, its reasoning folded away, and one line per tool
--- call with how that call went.
---
--- **Tool output is summarised, never shown.** It is nearly all of a subagent's
--- transcript (two measured here: 1.1MB and 1.7MB, almost entirely results), and
--- the question this float answers is what the run *did*; `<CR>` in the Activity
--- pane is where one call's output is read. A result is reduced to a word or two —
--- `12 lines`, `+3 -1`, `✗ exit 1` — and a line too large to decode is summarised
--- from its raw text.
---
--- A subagent the run started is a line of its own, and `<CR>` on it opens that
--- one in the same float, so a tree of runs is read by walking it.
---
--- While the float is on screen its transcript is followed: appended bytes are
--- folded and only the lines that changed are rewritten, so the reasoning folds a
--- reader opened stay open and a cursor parked at the end follows the run.
---@brief ]]
---@module 'claudecode.agents.subagent_view'

local float = require("claudecode.agents.float")
local subagents = require("claudecode.agents.subagents")
local tools = require("claudecode.agents.tools")
local transcript = require("claudecode.agents.transcript")
local utils = require("claudecode.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("claudecode_agents_subagent_view")

--- Past this a result line is summarised from its raw text instead of decoded.
local DECODE_LIMIT = 256 * 1024

--- How often an open float looks for more of its transcript.
M.FOLLOW_MS = 1000

--- Longest error text kept on a tool line.
local ERROR_TEXT_LIMIT = 80

--- Longest label kept on a tool line.
local TOOL_LABEL_LIMIT = 100

--- What marks a message to the run — its prompt, and anything sent to it later.
local PROMPT_MARK = "›"

local STATE_GLYPH = { running = "●", done = "✓", failed = "✗", stopped = "⊘" }
local STATE_WORD = { running = "running", done = "done", failed = "failed", stopped = "stopped" }

local RESULT_GLYPH = { done = "✓", error = "✗", rejected = "⊘", running = "…", interrupted = "⊘" }
local GLYPH_HL = {
  ["✗"] = "ClaudeCodeAgentsFailed",
  ["⊘"] = "ClaudeCodeAgentsStopped",
  ["…"] = "ClaudeCodeAgentsTime",
  ["✓"] = "ClaudeCodeAgentsTime",
}

--------------------------------------------------------------------------------
-- Folding a transcript into a document
--------------------------------------------------------------------------------

---@return table doc
function M.new_doc()
  return {
    items = {}, ---@type table[] In transcript order.
    results = {}, ---@type table<string, { status: string, summary: string|nil }>
    prompt_seen = false,
  }
end

---@param content any A `tool_result` block's content: a string or text blocks.
---@return string
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "table" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
  end
  return table.concat(parts, "\n")
end

---@param text string
---@return integer
local function count_lines(text)
  if text == "" then
    return 0
  end
  local _, newlines = text:gsub("\n", "")
  return text:sub(-1) == "\n" and newlines or newlines + 1
end

---@param n integer
---@param noun string
---@return string
local function plural(n, noun)
  return ("%d %s%s"):format(n, noun, n == 1 and "" or "s")
end

---A word or two saying how one call went.
---@param block table The `tool_result` block.
---@param result any The entry's `toolUseResult`.
---@return { status: string, summary: string|nil }
function M.summarize_result(block, result)
  local text = content_text(block.content)
  if block.is_error then
    if text:find(transcript.REJECTION_MARKER, 1, true) then
      return { status = "rejected", summary = "declined" }
    end
    local first = (text:gsub("^%s+", "")):match("^([^\n]*)") or ""
    return { status = "error", summary = first ~= "" and utils.truncate(first, ERROR_TEXT_LIMIT) or nil }
  end

  if type(result) == "table" then
    if type(result.structuredPatch) == "table" and type(result.filePath) == "string" then
      local added, removed = transcript._count_patch(result.structuredPatch)
      if added == 0 and removed == 0 and type(result.content) == "string" then
        added = count_lines(result.content)
      end
      return { status = "done", summary = ("+%d -%d"):format(added, removed) }
    end
    if type(result.file) == "table" and tonumber(result.file.numLines) then
      return {
        status = "done",
        summary = plural(tonumber(result.file.numLines), "line"),
        -- The window it read, which the file float marks the way the Activity
        -- pane's read row does.
        read = tonumber(result.file.startLine) and {
          start_line = tonumber(result.file.startLine),
          num_lines = tonumber(result.file.numLines),
        } or nil,
      }
    end
    if tonumber(result.totalTokens) then
      return { status = "done", summary = subagents.format_tokens(tonumber(result.totalTokens)) .. " tokens" }
    end
    if result.status == "async_launched" then
      return { status = "done", summary = "started in the background" }
    end
    if tonumber(result.numFiles) then
      return { status = "done", summary = plural(tonumber(result.numFiles), "file") }
    end
    if type(result.stdout) == "string" then
      local n = count_lines(result.stdout)
      return { status = "done", summary = n == 0 and "no output" or plural(n, "line") }
    end
  end

  local n = count_lines(text)
  return { status = "done", summary = n > 0 and plural(n, "line") or nil }
end

---Summarise a result line too large to decode, from its raw text.
---@param doc table
---@param line string
local function fold_raw_result(doc, line)
  for id in line:gmatch('"tool_use_id":"([^"]+)"') do
    if not doc.results[id] then
      local failed = line:find('"is_error":true', 1, true) ~= nil
      doc.results[id] = { status = failed and "error" or "done", summary = "large output" }
    end
  end
end

---@param doc table
---@param kind string
---@param text string
local function push_text(doc, kind, text)
  if type(text) == "string" and text:find("%S") then
    doc.items[#doc.items + 1] = { kind = kind, text = text }
  end
end

---A user entry's own words: the prompt, a later message, or the harness talking.
---@param doc table
---@param text string
local function fold_user_text(doc, text)
  if not text:find("%S") then
    return
  end
  if text:sub(1, #transcript.INTERRUPT_MARKER) == transcript.INTERRUPT_MARKER then
    doc.items[#doc.items + 1] = { kind = "interrupt" }
    return
  end
  if not doc.prompt_seen then
    doc.prompt_seen = true
    push_text(doc, "prompt", text)
    return
  end
  -- The harness speaks as the user too — a background command finishing, a nudge
  -- after an empty reply. Those are bracketed or tagged; a real message is not.
  if text:match("^%s*[%[<]") then
    local summary = text:match("<summary>([^<]+)</summary>")
    push_text(doc, "system", summary or text:match("^%s*([^\n]*)"))
    return
  end
  push_text(doc, "message", text)
end

---Fold one raw transcript line into the document.
---@param doc table
---@param line string
function M.fold_line(doc, line)
  if #line == 0 then
    return
  end
  if #line > DECODE_LIMIT then
    fold_raw_result(doc, line)
    return
  end
  local ok, entry = pcall(vim.json.decode, line)
  if not ok or type(entry) ~= "table" then
    return
  end
  local message = type(entry.message) == "table" and entry.message or nil

  if entry.type == "assistant" and message and type(message.content) == "table" then
    for _, block in ipairs(message.content) do
      if type(block) == "table" then
        if block.type == "text" then
          push_text(doc, "text", block.text)
        elseif block.type == "thinking" then
          push_text(doc, "thinking", block.thinking)
        elseif block.type == "tool_use" and type(block.name) == "string" then
          local input = type(block.input) == "table" and block.input or {}
          -- File tools are named by the file: their generic label is the tool's own
          -- name again, which says nothing a line already starting `read` does not.
          local path = input.file_path or input.notebook_path
          doc.items[#doc.items + 1] = {
            kind = "tool",
            id = type(block.id) == "string" and block.id or nil,
            name = block.name,
            path = type(path) == "string" and path or nil,
            label = tools.label(block.name, input),
          }
        end
      end
    end
    return
  end

  if entry.type ~= "user" or not message then
    return
  end

  if type(message.content) == "string" then
    local note = transcript._task_notification(line)
    if note then
      doc.items[#doc.items + 1] = {
        kind = "note",
        id = note.id,
        status = note.status,
        tokens = note.tokens,
        duration_ms = note.duration_ms,
        summary = message.content:match("<summary>([^<]+)</summary>"),
      }
      return
    end
    fold_user_text(doc, message.content)
    return
  end

  if type(message.content) == "table" then
    for _, block in ipairs(message.content) do
      if type(block) == "table" then
        if block.type == "tool_result" and type(block.tool_use_id) == "string" then
          doc.results[block.tool_use_id] = M.summarize_result(block, entry.toolUseResult)
        elseif block.type == "text" and type(block.text) == "string" then
          fold_user_text(doc, block.text)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Rendering a document
--------------------------------------------------------------------------------

---@param text string
---@return string[]
local function split(text)
  local out = {}
  for piece in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = piece
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

---`167k tokens · 13:50`, leaving out what is not known.
---@param tokens integer|nil
---@param seconds number|nil
---@return string
local function cost(tokens, seconds)
  local parts = {}
  if tokens then
    parts[#parts + 1] = subagents.format_tokens(tokens) .. " tokens"
  end
  if seconds then
    parts[#parts + 1] = subagents.format_runtime(seconds)
  end
  return table.concat(parts, " · ")
end

---@class ClaudeCodeSubagentViewContext
---@field row ClaudeCodeSubagentRow|nil The run being shown.
---@field children table<string, ClaudeCodeSubagentRow> Runs it started, by the tool_use id that started them.
---@field by_id table<string, ClaudeCodeSubagentRow> Every run of the session, by agent id.
---@field cwd string|nil Where the session ran, which file paths are shown relative to.
---@field back string|nil What `<BS>` returns to, when this run was opened from another's transcript.

---Lay a document out as Markdown lines.
---@param doc table
---@param ctx ClaudeCodeSubagentViewContext
---@return string[] lines
---@return table[] marks `{ row, col, end_col, hl }`, 0-based.
---@return table<integer, string> links 1-based line -> agent id it opens.
---@return { [1]: integer, [2]: integer }[] folds 1-based inclusive ranges, closed by default.
---@return table<integer, table> calls 1-based line -> the tool call on it
---        `{ tool_id, tool, label, path, read, status }`, what `<CR>` opens.
function M.render(doc, ctx)
  local row = ctx.row or {}
  local lines, marks, links, folds, calls = {}, {}, {}, {}, {}
  local function add(line)
    lines[#lines + 1] = line
  end
  local function glyph_mark(glyph, col)
    local hl = GLYPH_HL[glyph]
    if hl then
      marks[#marks + 1] = { row = #lines - 1, col = col, end_col = col + #glyph, hl = hl }
    end
  end

  -- The headline: the run's whole purpose, never cut, then what it is and cost.
  local purpose = (row.description or ""):gsub("%s+", " ")
  add("# " .. (purpose:find("%S") and purpose or (row.agent_type or "subagent")))
  local facts = { "`" .. (row.agent_type or "agent") .. "`" }
  if row.state then
    facts[#facts + 1] = (STATE_GLYPH[row.state] or "") .. " " .. (STATE_WORD[row.state] or row.state)
  end
  local spent = cost(row.tokens, row.runtime_s)
  if spent ~= "" then
    facts[#facts + 1] = spent
  end
  add(table.concat(facts, " · "))
  -- Reached from a parent's transcript: say where `<BS>` goes, since nothing
  -- else on screen says this float has anywhere to go back to.
  if ctx.back then
    add("← `<BS>` back to " .. ctx.back)
  end

  local previous = nil
  for _, item in ipairs(doc.items) do
    local is_list = item.kind == "tool" or item.kind == "note" or item.kind == "interrupt"
    -- One blank line between blocks, none inside a run of tool lines.
    if not (is_list and previous and (previous.kind == "tool" or previous.kind == "note")) then
      add("")
    end

    if item.kind == "prompt" or item.kind == "message" then
      -- Drawn the way Claude Code draws what was said to it: a slim arrow in front,
      -- the whole message on its own raised background.
      local render = require("claudecode.agents.render")
      local band = render.highlight("prompt")
      for index, piece in ipairs(split(item.text)) do
        add((index == 1 and PROMPT_MARK or string.rep(" ", vim.fn.strdisplaywidth(PROMPT_MARK))) .. " " .. piece)
        marks[#marks + 1] = { row = #lines - 1, line_hl = band }
        if index == 1 then
          marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #PROMPT_MARK, hl = render.highlight("time") }
        end
      end
    elseif item.kind == "text" then
      for _, piece in ipairs(split(item.text)) do
        add(piece)
      end
    elseif item.kind == "thinking" then
      local start = #lines + 1
      add("_thinking_")
      for _, piece in ipairs(split(item.text)) do
        add(piece)
      end
      if #lines > start then
        folds[#folds + 1] = { start, #lines }
        -- Its own background, the whole block: what `<Tab>` folds reads as one
        -- piece while it is open.
        local group = require("claudecode.agents.render").highlight("foldable")
        for index = start, #lines do
          marks[#marks + 1] = { row = index - 1, line_hl = group }
        end
      end
    elseif item.kind == "system" then
      add("> " .. item.text)
    elseif item.kind == "interrupt" then
      add("> ⊘ interrupted")
    elseif item.kind == "tool" then
      local child = item.id and ctx.children[item.id] or nil
      local glyph, summary
      if child then
        glyph = STATE_GLYPH[child.state] or "●"
        summary = cost(child.tokens, child.runtime_s)
      else
        local result = item.id and doc.results[item.id] or nil
        local status = result and result.status or "running"
        -- A call still waiting when the run itself has ended never got an answer.
        if not result and row.state and row.state ~= "running" then
          status = "interrupted"
        end
        glyph = RESULT_GLYPH[status] or "…"
        summary = result and result.summary or nil
      end
      -- One line per call: a command with no description is its whole command, and
      -- the full thing is one `<CR>` away in the Activity pane.
      local label = item.path and utils.relative_path(item.path, ctx.cwd) or item.label or ""
      label = utils.truncate(label, TOOL_LABEL_LIMIT)
      local line = "- " .. glyph .. " `" .. tools.short(item.name) .. "` " .. label
      if summary and summary ~= "" then
        line = line .. " · " .. summary
      end
      add(line)
      glyph_mark(glyph, 2)
      if child then
        links[#lines] = child.id
      elseif item.id then
        -- Everything the Activity pane's row for this call would carry, so `<CR>`
        -- can open the same float it opens.
        local result = doc.results[item.id]
        calls[#lines] = {
          tool_id = item.id,
          tool = item.name,
          label = item.label,
          path = item.path,
          read = result and result.read or nil,
          status = result and result.status or nil,
        }
      end
    elseif item.kind == "note" then
      local target = ctx.by_id[item.id]
      local glyph = item.status == "completed" and "✓" or (item.status == "killed" and "⊘" or "✗")
      local name = target and (target.description or target.agent_type) or item.summary or item.id
      local line = "- " .. glyph .. " finished: " .. name
      local spent_child = cost(item.tokens, item.duration_ms and item.duration_ms / 1000 or nil)
      if spent_child ~= "" then
        line = line .. " · " .. spent_child
      end
      add(line)
      glyph_mark(glyph, 2)
      if target then
        links[#lines] = item.id
      end
    end
    previous = item
  end

  return lines, marks, links, folds, calls
end

---The float's border title: type, state and cost, which fit a border; the
---purpose is in the body, where it is never cut.
---@param row ClaudeCodeSubagentRow|nil
---@return string
function M.title(row)
  row = row or {}
  local parts = { row.agent_type or "subagent" }
  local state = row.state and STATE_GLYPH[row.state]
  local spent = cost(row.tokens, row.runtime_s):gsub(" tokens", "")
  if state then
    parts[#parts + 1] = state .. (spent ~= "" and (" " .. spent) or "")
  elseif spent ~= "" then
    parts[#parts + 1] = spent
  end
  return utils.truncate(table.concat(parts, " · "), math.max(10, float.title_width()))
end

--------------------------------------------------------------------------------
-- The float
--------------------------------------------------------------------------------

--- Open viewers, by buffer: { path, session_path, agent_id, doc, offset, carry,
--- links, lines, title, opts, timer, reading }.
local views = {}

---@param session_path string
---@param agent_id string
---@param row_for fun(id: string): ClaudeCodeSubagentRow|nil
---@param history { agent_id: string, lnum: integer }[]|nil The runs this float came through.
---@return ClaudeCodeSubagentViewContext
local function context(session_path, agent_id, row_for, history)
  local rows = subagents.rows(session_path, { live = nil })
  local by_id = {}
  for _, row in ipairs(rows) do
    by_id[row.id] = row
  end
  -- The pane's own answer wins: it knows whether the session is live, which the
  -- rows computed here can only guess at from how recently a file was written.
  if row_for then
    for id in pairs(by_id) do
      by_id[id] = row_for(id) or by_id[id]
    end
  end
  local children = {}
  for _, agent in ipairs(subagents.scan(session_path)) do
    if agent.parent_id == agent_id and agent.tool_use_id and by_id[agent.id] then
      children[agent.tool_use_id] = by_id[agent.id]
    end
  end
  local summary = transcript.get(session_path)
  local back = nil
  local parent = history and history[#history]
  if parent then
    local row = by_id[parent.agent_id]
    back = row and (row.description or row.agent_type) or parent.agent_id
  end
  return {
    row = by_id[agent_id],
    children = children,
    by_id = by_id,
    cwd = summary and summary.cwd or nil,
    back = back,
  }
end

---Rewrite only what changed, so folds above the change survive and a reader's
---place is kept.
---@param buf integer
---@param view table
local function paint(buf, view)
  local ctx = context(view.session_path, view.agent_id, view.opts.row_for, view.opts.history)
  local lines, marks, links, folds, calls = M.render(view.doc, ctx)
  view.links = links
  view.calls = calls
  view.cwd = ctx.cwd

  local old = view.lines or {}
  local first = 1
  while first <= #old and first <= #lines and old[first] == lines[first] do
    first = first + 1
  end
  local changed = first <= #old or first <= #lines

  local wins = vim.fn.win_findbuf(buf)
  local follow = {}
  for _, win in ipairs(wins) do
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
    follow[win] = ok and pos[1] >= #old and #old > 0
  end

  if changed then
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
    local tail = {}
    for index = first, #lines do
      tail[#tail + 1] = lines[index]
    end
    pcall(vim.api.nvim_buf_set_lines, buf, first - 1, -1, false, tail)
    pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    for _, mark in ipairs(marks) do
      if mark.line_hl then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, 0, { line_hl_group = mark.line_hl })
      else
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
      end
    end
    view.lines = lines

    for _, win in ipairs(wins) do
      utils.set_win_option(win, "foldmethod", "manual")
      utils.set_win_option(win, "foldenable", true)
      pcall(vim.api.nvim_win_call, win, function()
        for _, range in ipairs(folds) do
          -- Only folds the rewrite reached; the ones above it are still there,
          -- open or closed as the reader left them.
          if range[2] >= first then
            pcall(vim.cmd, ("silent! %d,%dfold"):format(range[1], range[2]))
          end
        end
      end)
      if follow[win] then
        pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
      end
    end
  end

  local title = M.title(ctx.row)
  if title ~= view.title and vim.fn.has("nvim-0.9") == 1 then
    view.title = title
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_win_set_config, win, { title = " " .. title .. " ", title_pos = "center" })
    end
  end
end

---Read whatever the transcript gained since the last read, then repaint.
---@param buf integer
---@param done fun()|nil
local function pull(buf, done)
  local view = views[buf]
  if not view or view.reading then
    return
  end
  local st = transcript._io.stat(view.path)
  if not st or st.size < view.offset then
    -- Gone, or rewritten under us: start over from what is there now.
    if st and st.size < view.offset then
      view.doc, view.offset, view.carry = M.new_doc(), 0, ""
    elseif not st then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          paint(buf, view)
        end
        if done then
          done()
        end
      end)
      return
    end
  end

  view.reading = true
  local function step()
    if view.offset >= st.size then
      view.reading = false
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and views[buf] == view then
          paint(buf, view)
        end
        if done then
          done()
        end
      end)
      return
    end
    local want = math.min(transcript._chunk_size, st.size - view.offset)
    transcript._io.read(view.path, view.offset, want, function(data)
      -- Folded on the main loop: the read answers in libuv's fast context, where
      -- `vim.fn` (which the summaries' truncation uses) is off limits.
      vim.schedule(function()
        if not data or data == "" or views[buf] ~= view then
          view.reading = false
          if done then
            done()
          end
          return
        end
        view.offset = view.offset + #data
        local text = view.carry .. data
        local start = 1
        while true do
          local nl = text:find("\n", start, true)
          if not nl then
            break
          end
          pcall(M.fold_line, view.doc, text:sub(start, nl - 1))
          start = nl + 1
        end
        -- A line still being written stays behind until the rest of it lands.
        view.carry = text:sub(start)
        step()
      end)
    end)
  end
  step()
end

---@param buf integer
local function forget(buf)
  local view = views[buf]
  views[buf] = nil
  if view and view.timer then
    pcall(function()
      view.timer:stop()
      view.timer:close()
    end)
  end
end

--- The Activity pane's status words, which `tool_view` titles by. A call that
--- worked says nothing there, so `done` has no word.
local TOOL_VIEW_STATUS = { error = "error", rejected = "rejected", interrupted = "interrupted" }

---Open one of a run's tool calls the way the Activity pane opens its row: a file
---tool as what the run did to that file, anything else as the call and its output.
---
---Read out of the run's own transcript, which is the same format the pane reads a
---session from. A new float, stacked over this one, so `q` comes back here.
---@param session_id string|nil
---@param view table The viewer the call was chosen in.
---@param call { tool_id: string, tool: string, label: string?, path: string?, read: table?, status: string? }
function M.open_call(session_id, view, call)
  if tools.FILE_TOOLS[call.tool] and call.path then
    local ok, file_view = pcall(require, "claudecode.agents.file_view")
    if ok then
      local read = call.tool == "Read" and call.read or nil
      file_view.open({
        session_id = session_id,
        transcript = view.path,
        path = call.path,
        read = read,
        prefer = read and "read" or "diff",
        cwd = view.cwd,
      })
    end
    return
  end
  local ok, tool_view = pcall(require, "claudecode.agents.tool_view")
  if ok then
    tool_view.open({
      session_id = session_id,
      transcript = view.path,
      tool_id = call.tool_id,
      tool = call.tool,
      label = call.label,
      status = call.status and TOOL_VIEW_STATUS[call.status] or (call.status == nil and "running" or nil),
    })
  end
end

--- Injectable: specs drive the follow tick by hand.
M._new_timer = function()
  return vim.loop and vim.loop.new_timer and vim.loop.new_timer() or nil
end

---Open (or swap into `opts.reuse`) the transcript of one subagent run.
---@param opts { session_id: string?, session_path: string, agent_id: string, reuse: integer?,
---             row_for: (fun(id: string): ClaudeCodeSubagentRow|nil)?, on_open: (fun(win: integer|nil))?,
---             history: { agent_id: string, lnum: integer }[]?, cursor: integer? }
---             `history` is the chain of runs this float came down through; `cursor`
---             the line to land on.
---@param done fun(win: integer|nil)|nil
function M.open(opts, done)
  local function finish(win)
    if done then
      done(win)
    end
  end
  local dir = subagents.dir(opts.session_path)
  if not dir or type(opts.agent_id) ~= "string" then
    return finish(nil)
  end

  local buf = float.scratch({ "", "  Reading the transcript…" }, "claudecode://subagent/" .. opts.agent_id)
  if not buf then
    return finish(nil)
  end
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "undolevels", -1, { buf = buf })

  local view = {
    path = dir .. "/agent-" .. opts.agent_id .. ".jsonl",
    session_path = opts.session_path,
    agent_id = opts.agent_id,
    doc = M.new_doc(),
    offset = 0,
    carry = "",
    opts = opts,
  }
  views[buf] = view

  local ctx = context(opts.session_path, opts.agent_id, opts.row_for, opts.history)
  view.title = M.title(ctx.row)
  local win = float.create(opts.session_id, { title = view.title, buf = buf, reuse = opts.reuse, purpose = "open" })
  if not win then
    forget(buf)
    return finish(nil)
  end

  -- `<Tab>` opens and closes the block under the cursor. Bound before `bind_close`,
  -- which leaves a key the buffer already maps alone — its own `<Tab>` (next float)
  -- would otherwise win. Off a fold it does nothing: jumping to another float from
  -- a line that merely is not foldable would be a surprise.
  pcall(vim.keymap.set, "n", "<Tab>", function()
    if vim.fn.foldlevel(".") > 0 then
      pcall(vim.cmd, "normal! za")
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "Open or close this block" })
  float.bind_close(win)
  -- The placeholder is replaced wholesale by the first paint.
  view.lines = { "", "  Reading the transcript…" }

  pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      forget(buf)
    end,
  })

  -- A subagent line opens that run here, in the same float; a tool line opens what
  -- the Activity pane opens for that call, in a float of its own on top.
  pcall(vim.keymap.set, "n", "<CR>", function()
    local current = views[buf]
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target = current and current.links and current.links[lnum]
    if not target then
      local call = current and current.calls and current.calls[lnum]
      if call then
        M.open_call(opts.session_id, current, call)
      end
      return
    end
    -- Remember where this run was left, so `<BS>` from the child lands back on
    -- the line that opened it.
    local history = {}
    for index, entry in ipairs(opts.history or {}) do
      history[index] = entry
    end
    history[#history + 1] = { agent_id = opts.agent_id, lnum = lnum }
    M.open({
      session_id = opts.session_id,
      session_path = opts.session_path,
      agent_id = target,
      reuse = vim.api.nvim_get_current_win(),
      row_for = opts.row_for,
      on_open = opts.on_open,
      history = history,
    }, opts.on_open)
  end, { buffer = buf, nowait = true, silent = true, desc = "Open this subagent's transcript" })

  -- Back up the chain this float walked down, one run per press.
  local history = opts.history or {}
  if #history > 0 then
    pcall(vim.keymap.set, "n", "<BS>", function()
      local back = {}
      for index = 1, #history - 1 do
        back[index] = history[index]
      end
      local parent = history[#history]
      M.open({
        session_id = opts.session_id,
        session_path = opts.session_path,
        agent_id = parent.agent_id,
        reuse = vim.api.nvim_get_current_win(),
        row_for = opts.row_for,
        on_open = opts.on_open,
        history = back,
        cursor = parent.lnum,
      }, opts.on_open)
    end, { buffer = buf, nowait = true, silent = true, desc = "Back to the run that opened this one" })
  end

  pull(buf, function()
    if vim.api.nvim_win_is_valid(win) then
      local line = math.max(1, math.min(opts.cursor or 1, vim.api.nvim_buf_line_count(buf)))
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
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
        -- Nothing on screen shows this buffer (the float moved on to another run):
        -- the wipe will come, but there is no one to follow for meanwhile.
        if #vim.fn.win_findbuf(buf) == 0 then
          return
        end
        -- The headline's state, tokens and the children's lines come from the
        -- session's and the runs' own folds. The pane keeps those current only for
        -- the session it has selected, so the float does not rely on it.
        subagents.refresh(view.session_path)
        pull(buf)
      end)
    )
  end
  return finish(win)
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
