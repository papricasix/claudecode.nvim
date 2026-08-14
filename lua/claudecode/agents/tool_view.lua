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

---Show one tool call: what was run, and what came back.
---@param opts { session_id: string?, transcript: string?, tool_id: string?, tool: string?,
---             label: string?, status: string?, reuse: integer? }
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
    local body = tools.body(tool, call.input, call.result)
    -- The row's status is what the pane folded; a result that has landed since is
    -- the newer answer, and the title should not still say "running".
    local status = opts.status
    if status == "running" and call.result ~= nil then
      status = nil
    end
    local title = title_for(tool, opts.label or tools.label(tool, call.input), status)
    local win = show(opts.session_id, body, title, "claudecode://tool/" .. tool_id, opts.reuse)
    return finish(win)
  end)
end

return M
