---@brief [[
--- What `<CR>` on a workflow run shows: what it is for, how it stands, and its
--- agents, phase by phase — followed live while it runs.
---
--- Everything comes from the run's own files (see `subagents.scan_workflow`): the
--- journal while it runs, the run record once it has ended. Each agent is a line
--- that opens its transcript in the subagent float, stacked on top so `q` comes
--- back here. Once the run has ended the record adds what it returned, the error
--- it failed with, and what the script logged.
---@brief ]]
---@module 'claudecode.agents.workflow_view'

local float = require("claudecode.agents.float")
local subagents = require("claudecode.agents.subagents")
local utils = require("claudecode.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("claudecode_agents_workflow_view")

--- How often an open float re-reads the run.
M.FOLLOW_MS = 1000

--- Longest result kept, in lines; the record keeps the whole of it.
local RESULT_LINES = 40

local STATE_GLYPH = { running = "●", done = "✓", failed = "✗", stopped = "⊘" }
local GLYPH_HL = { ["✗"] = "failed", ["⊘"] = "stopped", ["✓"] = "time" }

---`62k tokens · 0:01`, leaving out what is not known.
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

---How the run stands, in words.
---@param row ClaudeCodeSubagentRow
---@return string
local function state_words(row)
  if row.state == "running" then
    return "running"
  elseif row.how == "orphaned" then
    return "stopped when its session ended"
  end
  return row.state or "?"
end

---Lay a run out as Markdown lines.
---@param row ClaudeCodeSubagentRow The run's own row.
---@param agents ClaudeCodeSubagentRow[] Its agents' rows, in the order they started.
---@param record table|nil The run record, once the run has ended.
---@return string[] lines
---@return table[] marks `{ row, col, end_col, hl }`, 0-based; `hl` names a render highlight.
---@return table<integer, ClaudeCodeSubagentRow> links 1-based line -> the agent it opens.
function M.render(row, agents, record)
  local lines, marks, links = {}, {}, {}
  local function add(line)
    lines[#lines + 1] = line
  end

  add("# " .. ((row.description or row.agent_type or "workflow"):gsub("%s+", " ")))
  local facts = { "`" .. (row.agent_type or "workflow") .. "`" }
  facts[#facts + 1] = (STATE_GLYPH[row.state] or "⊘") .. " " .. state_words(row)
  facts[#facts + 1] = #agents == 1 and "1 agent" or (#agents .. " agents")
  local spent = cost(row.tokens, row.runtime_s)
  if spent ~= "" then
    facts[#facts + 1] = spent
  end
  add(table.concat(facts, " · "))
  local glyph = STATE_GLYPH[row.state]
  if glyph and GLYPH_HL[glyph] then
    -- The glyph opens the second fact, right after the name and its separator.
    local at = #facts[1] + #" · "
    marks[#marks + 1] = { row = #lines - 1, col = at, end_col = at + #glyph, hl = GLYPH_HL[glyph] }
  end

  -- Agents under the phase they ran in, phases in the order they first appear.
  local phases, by_phase = {}, {}
  for _, agent in ipairs(agents) do
    local phase = agent.phase or ""
    if not by_phase[phase] then
      by_phase[phase] = {}
      phases[#phases + 1] = phase
    end
    table.insert(by_phase[phase], agent)
  end
  if #agents == 0 then
    add("")
    add(row.state == "running" and "_no agent has started yet_" or "_no agents ran_")
  end
  for _, phase in ipairs(phases) do
    add("")
    if phase ~= "" then
      add("## " .. phase)
    end
    for _, agent in ipairs(by_phase[phase]) do
      local mark = STATE_GLYPH[agent.state] or "⊘"
      local line = "- " .. mark .. " " .. ((agent.description or agent.id):gsub("%s+", " "))
      local agent_cost = cost(agent.tokens, agent.runtime_s)
      if agent_cost ~= "" then
        line = line .. " · " .. agent_cost
      end
      add(line)
      links[#lines] = agent
      if GLYPH_HL[mark] then
        marks[#marks + 1] = { row = #lines - 1, col = 2, end_col = 2 + #mark, hl = GLYPH_HL[mark] }
      end
    end
  end

  if type(record) == "table" then
    -- A stopped run's error is the abort's own stack trace, which says only what
    -- the status line already does.
    if type(record.error) == "string" and record.error ~= "" and record.status ~= "killed" then
      add("")
      add("## Error")
      add("```")
      for _, piece in ipairs(split(record.error)) do
        add(piece)
      end
      add("```")
    end
    if record.result ~= nil and record.result ~= vim.NIL then
      add("")
      add("## Result")
      add("```json")
      local body = require("claudecode.agents.tools").pretty_json(record.result)
      for index, piece in ipairs(body) do
        if index > RESULT_LINES then
          add(("… %d more lines"):format(#body - RESULT_LINES))
          break
        end
        add(piece)
      end
      add("```")
    end
    if type(record.logs) == "table" and #record.logs > 0 then
      add("")
      add("## Log")
      for _, entry in ipairs(record.logs) do
        if type(entry) == "string" then
          for _, piece in ipairs(split(entry)) do
            add("> " .. piece)
          end
        end
      end
    end
  end
  return lines, marks, links
end

---@param row ClaudeCodeSubagentRow|nil
---@return string
function M.title(row)
  row = row or {}
  local parts = { "» " .. (row.agent_type or "workflow") }
  local glyph = STATE_GLYPH[row.state]
  if glyph then
    parts[#parts + 1] = glyph .. " " .. subagents.format_runtime(row.runtime_s)
  end
  return utils.truncate(table.concat(parts, "  "), math.max(10, float.title_width()))
end

--------------------------------------------------------------------------------
-- The float
--------------------------------------------------------------------------------

local views = {}

---The run's row and its agents', as the pane has them or as the files say.
---@param view table
---@return ClaudeCodeSubagentRow|nil row
---@return ClaudeCodeSubagentRow[] agents
local function gather(view)
  local rows = view.opts.rows and view.opts.rows() or subagents.rows(view.session_path, { live = nil })
  local row, agents = nil, {}
  for _, candidate in ipairs(rows) do
    if candidate.kind == "workflow" and candidate.id == view.task_id then
      row = candidate
    elseif candidate.workflow == view.task_id then
      agents[#agents + 1] = candidate
    end
  end
  return row, agents
end

---@param buf integer
---@param view table
local function paint(buf, view)
  local row, agents = gather(view)
  if not row then
    return
  end
  local task = subagents.find_task(view.session_path, view.task_id)
  local run = task and subagents.scan_workflow(view.session_path, task)
  local lines, marks, links = M.render(row, agents, run and run.record)
  view.links = links
  view.ended = row.ended

  local render = require("claudecode.agents.render")
  local wins = vim.fn.win_findbuf(buf)
  local cursors = {}
  for _, win in ipairs(wins) do
    local ok, pos = pcall(vim.api.nvim_win_get_cursor, win)
    cursors[win] = ok and pos or nil
  end
  local old = view.lines or {}
  local same = #old == #lines
  for index = 1, same and #lines or 0 do
    if old[index] ~= lines[index] then
      same = false
      break
    end
  end
  if not same then
    pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = buf })
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
    view.lines = lines
    for win, pos in pairs(cursors) do
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(pos[1], #lines), pos[2] })
    end
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = render.highlight(mark.hl),
    })
  end

  local title = M.title(row)
  if title ~= view.title and vim.fn.has("nvim-0.9") == 1 then
    view.title = title
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_win_set_config, win, { title = " " .. title .. " ", title_pos = "center" })
    end
  end
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

--- Injectable: specs drive the follow tick by hand.
M._new_timer = function()
  return vim.loop and vim.loop.new_timer and vim.loop.new_timer() or nil
end

---Open (or swap into `opts.reuse`) one workflow run.
---@param opts { session_id: string?, session_path: string, task_id: string, reuse: integer?,
---             rows: (fun(): ClaudeCodeSubagentRow[])?,
---             row_for: (fun(id: string): ClaudeCodeSubagentRow|nil)? }
---             `rows` is the pane's rows, which know whether the session is live.
---@param done fun(win: integer|nil)|nil
function M.open(opts, done)
  local function finish(win)
    if done then
      done(win)
    end
  end
  if type(opts) ~= "table" or type(opts.task_id) ~= "string" or type(opts.session_path) ~= "string" then
    return finish(nil)
  end
  local view = { opts = opts, task_id = opts.task_id, session_path = opts.session_path }
  local row = gather(view)
  if not row then
    return finish(nil)
  end

  local buf = float.scratch({ "" }, "claudecode://workflow/" .. opts.task_id)
  if not buf then
    return finish(nil)
  end
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "undolevels", -1, { buf = buf })
  views[buf] = view

  view.title = M.title(row)
  local win = float.create(opts.session_id, { title = view.title, buf = buf, reuse = opts.reuse, purpose = "open" })
  if not win then
    forget(buf)
    return finish(nil)
  end
  float.bind_close(win)
  paint(buf, view)

  pcall(vim.api.nvim_create_autocmd, "BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      forget(buf)
    end,
  })

  -- An agent line opens that agent's transcript on top; `q` comes back here.
  pcall(vim.keymap.set, "n", "<CR>", function()
    local current = views[buf]
    local agent = current and current.links and current.links[vim.api.nvim_win_get_cursor(0)[1]]
    if not agent then
      return
    end
    require("claudecode.agents.subagent_view").open({
      session_id = opts.session_id,
      session_path = opts.session_path,
      agent_id = agent.id,
      path = agent.path,
      row_for = opts.row_for,
    })
  end, { buffer = buf, nowait = true, silent = true, desc = "Open this agent's transcript" })

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
        local was_ended = view.ended
        subagents.refresh(view.session_path)
        paint(buf, view)
        -- One more pass after the end, for the record written with it.
        if was_ended and view.ended and view.timer then
          view.timer = nil
          pcall(function()
            timer:stop()
            timer:close()
          end)
        end
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

return M
