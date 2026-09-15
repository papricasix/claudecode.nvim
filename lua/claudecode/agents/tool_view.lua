---@brief [[
--- What `<CR>` on an Activity row for a tool call shows: the call itself and what
--- came back from it.
---
--- The row is deliberately thin — a tool, a one-line label, how the call went —
--- because one is folded for every call an agent makes and a session makes
--- hundreds. The command that ran and the output it produced are read back out of
--- the transcript here, when someone asks for them, by the `toolu_…` id the row
--- carries. Exactly two lines in the file contain that id, so the scan decodes two
--- lines however large the transcript is.
---
--- The output is a command's real output, escape codes and all, so it goes through
--- `agents/ansi.lua` on the way into the buffer: the colours `git`, `rg` and a test
--- runner write are most of what makes their output scannable, and a buffer shows
--- them as `^[[32m` litter otherwise.
---@brief ]]
---@module 'claudecode.agents.tool_view'

local ansi = require("claudecode.agents.ansi")
local float = require("claudecode.agents.float")
local logger = require("claudecode.logger")
local tools = require("claudecode.agents.tools")
local transcript = require("claudecode.agents.transcript")

local M = {}

local ns = vim.api.nvim_create_namespace("claudecode_agents_tool_view")

--- How the float's title says a call did not simply succeed. A call that worked
--- says nothing, for the reason the row's marker does not: most of them worked.
local STATUS_TITLE = {
  running = "(running)",
  error = "(failed)",
  interrupted = "(interrupted)",
  rejected = "(rejected)",
}

--- Longest label kept in the title. The border is as wide as the float and the
--- rest of the title (the tool, the status) has to survive.
local TITLE_LABEL_LIMIT = 60

---@param tool string|nil
---@param label string|nil
---@param status string|nil
---@return string
local function title_for(tool, label, status)
  local parts = { tools.short(tool) }
  if type(label) == "string" and label ~= "" then
    local text = label
    if #text > TITLE_LABEL_LIMIT then
      text = text:sub(1, TITLE_LABEL_LIMIT - 1) .. "…"
    end
    parts[#parts + 1] = text
  end
  local suffix = STATUS_TITLE[status or ""]
  if suffix then
    parts[#parts + 1] = suffix
  end
  return table.concat(parts, "  ")
end

---Put a rendered body in a float.
---@param session_id string|nil
---@param body { lines: string[], filetype: string|nil, ansi: boolean|nil }
---@param title string
---@param name string Buffer name.
---@param reuse integer|nil
---@return integer|nil win
local function show(session_id, body, title, name, reuse)
  local lines = body.lines
  local marks = nil
  -- Only when there is something to parse: the pass rewrites every line, and most
  -- output has no escape in it at all.
  if body.ansi and ansi.has_escapes(lines) then
    lines, marks = ansi.parse(lines)
  end

  local buf = float.scratch(lines, name)
  if not buf then
    return nil
  end
  if body.filetype then
    pcall(vim.api.nvim_set_option_value, "filetype", body.filetype, { buf = buf })
  end

  local win = float.create(session_id, { title = title, buf = buf, reuse = reuse, purpose = "open" })
  if not win then
    return nil
  end
  if marks then
    for _, mark in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, mark.col, {
        end_col = mark.end_col,
        hl_group = mark.hl,
        -- Below a diff's own marks, and below the live cursor's read highlight:
        -- nothing else paints in this buffer, but a float can be reused by one
        -- that does.
        priority = 100,
      })
    end
  end
  float.bind_close(win)
  return win
end

--- How often a "still running" float looks again for the command's output file,
--- and for how long.
M.RETRY_MS = 500
M.RETRY_FOR_S = 30 * 60

--- Injectable: specs drive the retry by hand.
M._new_timer = function()
  return vim.loop and vim.loop.new_timer and vim.loop.new_timer() or nil
end

---Follow a shell command still running in the foreground, when its output file can
---be told apart from the others (`subagents.foreground_output`): its output is
---streaming there, under an id the transcript does not name until it returns.
---@param opts table `M.open`'s options.
---@param call ClaudeCodeAgentsToolCall
---@param tool string
---@param reuse integer|nil
---@param done fun(win: integer|nil)|nil
---@return boolean followed
local function follow_foreground(opts, call, tool, reuse, done)
  local shell_view = require("claudecode.agents.shell_view")
  local session_path = shell_view.session_path(opts.transcript)
  local output_path =
    require("claudecode.agents.subagents").foreground_output(session_path, opts.tool_id, call.at or call.ts)
  if not output_path then
    return false
  end
  local input = type(call.input) == "table" and call.input or {}
  shell_view.open({
    session_id = opts.session_id,
    transcript = opts.transcript,
    tool_id = opts.tool_id,
    command = type(input.command) == "string" and input.command or nil,
    reuse = reuse,
    row_for = opts.row_for,
    on_handoff = opts.on_handoff,
    foreground = {
      output_path = output_path,
      started = call.ts,
      tool = tool,
      description = type(input.description) == "string" and input.description or nil,
    },
  }, done)
  return true
end

---Keep a "still running" float looking for its command's output.
---
---The call is written about a second before the command is spawned and its file
---created, so a float opened in between finds nothing. It looks again until the
---file turns up (and becomes the live view, in the same window), the result lands
---(and the float shows it), or nothing shows the float any more.
---@param opts table `M.open`'s options.
---@param call ClaudeCodeAgentsToolCall
---@param tool string
---@param win integer
local function wait_for_output(opts, call, tool, win)
  local timer = M._new_timer()
  if not timer then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local deadline = os.time() + M.RETRY_FOR_S
  local function stop()
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
  local subagents = require("claudecode.agents.subagents")
  local session_path = require("claudecode.agents.shell_view").session_path(opts.transcript)
  timer:start(
    M.RETRY_MS,
    M.RETRY_MS,
    vim.schedule_wrap(function()
      local shown = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
      if not shown or os.time() > deadline then
        return stop()
      end
      subagents.refresh(session_path)
      local sum = transcript.get(opts.transcript)
      if sum and sum.task_calls and sum.task_calls[opts.tool_id] == nil then
        -- Returned while waiting: show the finished call in place.
        stop()
        return M.open(vim.tbl_extend("force", opts, { reuse = win, status = nil }), opts.on_handoff)
      end
      if follow_foreground(opts, call, tool, win, opts.on_handoff) then
        stop()
      end
    end)
  )
end

---Show one tool call: what was run, and what came back.
---
---A shell command that went to the background came back with nothing but the
---place its output is going, so it is shown as that shell instead — its output
---read from there, and followed while it runs (`shell_view`). A monitor likewise.
---@param opts { session_id: string?, transcript: string?, tool_id: string?, tool: string?,
---             label: string?, status: string?, reuse: integer?,
---             row_for: (fun(id: string): ClaudeCodeSubagentRow|nil)?,
---             on_handoff: (fun(win: integer|nil))? }
---             `on_handoff` is called when a running foreground command's float swaps
---             to the finished call in the same window.
---@param done fun(win: integer|nil)|nil Called once the float is up (the read is async).
function M.open(opts, done)
  opts = opts or {}
  local function finish(win)
    if done then
      done(win)
    end
  end

  local tool_id = opts.tool_id
  if type(tool_id) ~= "string" or tool_id == "" or type(opts.transcript) ~= "string" then
    -- A row folded before the id was recorded, or a session with no transcript
    -- yet. Nothing to read: say so rather than opening an empty frame.
    logger.debug("agents", "tool_view: no transcript or tool id for", opts.tool or "?")
    return finish(nil)
  end

  transcript.tool_call(opts.transcript, tool_id, function(call)
    if not call then
      vim.notify("ClaudeCode: that tool call is no longer in the transcript", vim.log.levels.WARN)
      return finish(nil)
    end

    local tool = call.tool or opts.tool
    local running_shell = call.result == nil and transcript.SHELL_TOOLS[tool]
    if running_shell and follow_foreground(opts, call, tool, opts.reuse, done) then
      return
    end
    local result = type(call.result) == "table" and call.result or {}
    -- A workflow launch is the run itself, shown as the run.
    if
      tool == transcript.WORKFLOW_TOOL
      and result.taskType == "local_workflow"
      and type(result.taskId) == "string"
      and opts.transcript
    then
      return require("claudecode.agents.workflow_view").open({
        session_id = opts.session_id,
        session_path = require("claudecode.agents.shell_view").session_path(opts.transcript),
        task_id = result.taskId,
        reuse = opts.reuse,
        row_for = opts.row_for,
      }, done)
    end
    local task_id = nil
    if transcript.SHELL_TOOLS[tool] then
      task_id = result.backgroundTaskId
    elseif tool == transcript.MONITOR_TOOL then
      task_id = result.taskId
    end
    if type(task_id) == "string" and task_id ~= "" then
      local input = type(call.input) == "table" and call.input or {}
      return require("claudecode.agents.shell_view").open({
        session_id = opts.session_id,
        transcript = opts.transcript,
        task_id = task_id,
        tool_id = tool_id,
        -- Already read here; saves the shell view reading the transcript again.
        command = type(input.command) == "string" and input.command or nil,
        reuse = opts.reuse,
        row_for = opts.row_for,
      }, done)
    end
    local body = tools.body(tool, call.input, call.result)
    -- The row's status is what the pane folded; a result that has landed since is
    -- the newer answer, and the title should not still say "running".
    local status = opts.status
    if status == "running" and call.result ~= nil then
      status = nil
    end
    local title = title_for(tool, opts.label or tools.label(tool, call.input), status)
    local win = show(opts.session_id, body, title, "claudecode://tool/" .. tool_id, opts.reuse)
    if win and running_shell then
      wait_for_output(opts, call, tool, win)
    end
    return finish(win)
  end)
end

return M
