---@brief [[
--- What the Activity pane knows about a tool call that touched no file.
---
--- Reads, edits and writes already have rows: the transcript records a path and a
--- patch for each, and the pane says what happened to the file. Everything else an
--- agent does — the shell commands, the searches, the subagents it launched — is in
--- the same transcript and was invisible, which is the half of "what is this agent
--- doing" that a `+12 -3` cannot answer.
---
--- Two shapes have to be summarized, and neither is uniform across tools:
---
--- *The call.* Only `Bash` and `Task` carry a `description`, so every other tool
--- needs its own rule for what names the row — a `Grep`'s pattern, a `WebFetch`'s
--- URL, a `TodoWrite`'s todo count. `M.label` is that table of rules, with a
--- generic field-order fallback for tools that do not exist yet (an MCP server's,
--- most likely) so an unknown one still gets a readable row rather than its name
--- alone.
---
--- *The result.* `Bash` gives `{stdout, stderr}`, `Grep` a string or a file list,
--- `Task` the subagent's content blocks, `TodoWrite` an array of todos — and a
--- rejected or errored call gives a bare string, whatever the tool. `M.body`
--- renders each as what it is, and pretty-prints the JSON of anything it does not
--- recognize, which is always better than showing nothing.
---
--- Nothing here reads the transcript or opens a window: it is the knowledge, and
--- `agents/transcript.lua` and `agents/tool_view.lua` are the two callers.
---@brief ]]
---@module 'claudecode.agents.tools'

local M = {}

--- Tools whose work the panes already describe: their results carry a `filePath`
--- and a patch, which is what a file row and the Changes pane are made of. A row
--- for the call as well would say the same thing twice.
M.FILE_TOOLS = {
  Read = true,
  Edit = true,
  MultiEdit = true,
  Write = true,
  NotebookEdit = true,
  NotebookRead = true,
}

--- The kind column is five cells wide (`added` is the longest file label), so a
--- tool's name is shortened to fit rather than the column widened for the one MCP
--- tool with a long name. Unlisted tools fall back to their first five characters,
--- lowercased — `Bash` is `bash` whether it is listed or not, and a tool we have
--- never heard of still reads as itself.
M.SHORT = {
  Bash = "bash",
  BashOutput = "bash",
  KillShell = "bash",
  Grep = "grep",
  Glob = "glob",
  WebFetch = "fetch",
  WebSearch = "web",
  Task = "agent",
  Agent = "agent",
  TodoWrite = "todo",
  TaskCreate = "task",
  TaskUpdate = "task",
  TaskGet = "task",
  TaskList = "task",
  ExitPlanMode = "plan",
  ToolSearch = "tools",
  AskUserQuestion = "ask",
  Skill = "skill",
  SlashCommand = "cmd",
}

--- Fields a tool's input is summarized from when it has no rule of its own, most
--- specific first. An MCP tool is the common case: its input is whatever its
--- server defines, and one of these names it far more often than not.
local FALLBACK_FIELDS = {
  "description",
  "query",
  "pattern",
  "command",
  "prompt",
  "url",
  "title",
  "subject",
  "name",
  "path",
  "skill",
}

--- How much of a summary is worth keeping. The pane shortens it again to the
--- width it actually has; this only stops a whole prompt travelling with an event.
local LABEL_LIMIT = 200

---One line, whitespace collapsed, cut to the label limit.
---@param text any
---@return string|nil
local function oneline(text)
  if type(text) ~= "string" then
    return nil
  end
  local flat = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if flat == "" then
    return nil
  end
  return flat:sub(1, LABEL_LIMIT)
end

---The first of `fields` that `input` has a non-empty string in.
---@param input table
---@param fields string[]
---@return string|nil
local function first_of(input, fields)
  for _, field in ipairs(fields) do
    local text = oneline(input[field])
    if text then
      return text
    end
  end
  return nil
end

---An MCP tool's `server__tool` spelled for a five-cell column and a row label.
---@param name string
---@return string|nil server
---@return string|nil tool
local function mcp_parts(name)
  local server, tool = name:match("^mcp__([^_]+.-)__(.+)$")
  if server then
    return server, tool
  end
  return nil, nil
end

---The kind column's text for a tool call.
---@param name string|nil
---@return string
function M.short(name)
  if type(name) ~= "string" or name == "" then
    return "tool"
  end
  if M.SHORT[name] then
    return M.SHORT[name]
  end
  local server = mcp_parts(name)
  if server then
    return server:sub(1, 5):lower()
  end
  return name:sub(1, 5):lower()
end

--- Per-tool summaries. Each is handed the call's input and returns the row's
--- text, or nil to fall through to the generic fields above.
---@type table<string, fun(input: table): string|nil>
local LABELS = {
  Bash = function(input)
    -- The description is Claude's own one-line account of the call, which is what
    -- the row is for; the command itself is one `<CR>` away and often far too long
    -- to read sideways.
    return oneline(input.description) or oneline(input.command)
  end,
  Grep = function(input)
    local pattern = oneline(input.pattern)
    if not pattern then
      return nil
    end
    local where = oneline(input.path) or oneline(input.glob)
    return where and (pattern .. "  in " .. where) or pattern
  end,
  Glob = function(input)
    local pattern = oneline(input.pattern)
    local where = oneline(input.path)
    if pattern and where then
      return pattern .. "  in " .. where
    end
    return pattern or where
  end,
  WebFetch = function(input)
    local url = oneline(input.url)
    if not url then
      return nil
    end
    -- The host and path, without the scheme: the row is narrow and `https://` is
    -- the same eight cells on every one of them.
    return (url:gsub("^%a+://", ""))
  end,
  WebSearch = function(input)
    return oneline(input.query)
  end,
  TodoWrite = function(input)
    local todos = input.todos
    if type(todos) ~= "table" then
      return nil
    end
    local doing
    local done = 0
    for _, todo in ipairs(todos) do
      if type(todo) == "table" then
        if todo.status == "in_progress" then
          doing = oneline(todo.activeForm) or oneline(todo.content) or doing
        elseif todo.status == "completed" then
          done = done + 1
        end
      end
    end
    local counts = string.format("%d/%d done", done, #todos)
    return doing and (doing .. "  (" .. counts .. ")") or counts
  end,
  ExitPlanMode = function(input)
    -- The plan itself is the payload and is a whole document; its first heading is
    -- what names it.
    local plan = type(input.plan) == "string" and input.plan or ""
    local heading = plan:match("^#+%s*([^\n]+)") or plan:match("^([^\n]+)")
    return oneline(heading) and ("plan: " .. oneline(heading)) or "presented a plan"
  end,
  AskUserQuestion = function(input)
    local questions = input.questions
    if type(questions) ~= "table" or type(questions[1]) ~= "table" then
      return nil
    end
    local first = oneline(questions[1].question) or oneline(questions[1].header)
    if #questions > 1 then
      return string.format("%s  (+%d more)", first or "asked", #questions - 1)
    end
    return first
  end,
  Skill = function(input)
    local skill = oneline(input.skill)
    local args = oneline(input.args)
    if skill and args then
      return skill .. "  " .. args
    end
    return skill or args
  end,
  Task = function(input)
    local what = oneline(input.description) or oneline(input.prompt)
    local kind = oneline(input.subagent_type)
    if what and kind then
      return what .. "  (" .. kind .. ")"
    end
    return what or kind
  end,
}
LABELS.Agent = LABELS.Task

---One line naming what a tool call was for.
---@param name string|nil Tool name as the CLI recorded it.
---@param input table|nil The call's input.
---@return string label Never empty: the tool's own name is the last resort.
function M.label(name, input)
  local tool = type(name) == "string" and name or "tool"
  if type(input) ~= "table" then
    return tool
  end
  local rule = LABELS[tool]
  local text = rule and rule(input) or nil
  if not text then
    text = first_of(input, FALLBACK_FIELDS)
  end
  if not text then
    -- Nothing named: an MCP tool reads as its own tool name rather than as its
    -- server, which the kind column already says.
    local _, mcp_tool = mcp_parts(tool)
    text = mcp_tool or tool
  end
  return text
end

--------------------------------------------------------------------------------
-- Rendering a result
--------------------------------------------------------------------------------

---Split text into buffer lines, tolerating CRLF and a trailing newline.
---@param text string
---@return string[]
local function split_lines(text)
  local lines = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

---@param into string[]
---@param from string[]
local function extend(into, from)
  for _, item in ipairs(from) do
    into[#into + 1] = item
  end
end

---Whether a decoded JSON value is an array rather than an object.
---
---Counted rather than asked of `vim.islist`, which the plugin does not use
---anywhere else and the spec harness does not provide.
---@param value any
---@return boolean
local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count == #value
end

---A JSON string literal.
---@param text string
---@return string
local function quote(text)
  local escaped = text:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r")
  return '"' .. escaped .. '"'
end

---Pretty-print a decoded JSON value as buffer lines.
---
---`vim.json.encode` has no indent option and `vim.inspect` prints Lua rather than
---JSON, so a result nothing recognizes would otherwise be one unreadable line.
---Keys are sorted, so the same result reads the same way twice.
---@param value any
---@param indent string|nil
---@param out string[]|nil
---@param prefix string|nil Text the first line opens with (a key, say).
---@return string[]
function M.pretty_json(value, indent, out, prefix)
  indent = indent or ""
  out = out or {}
  prefix = prefix or ""

  if value == nil or value == vim.NIL then
    out[#out + 1] = indent .. prefix .. "null"
  elseif type(value) ~= "table" then
    local text = type(value) == "string" and quote(value) or tostring(value)
    out[#out + 1] = indent .. prefix .. text
  elseif is_array(value) then
    if #value == 0 then
      out[#out + 1] = indent .. prefix .. "[]"
      return out
    end
    out[#out + 1] = indent .. prefix .. "["
    for index, item in ipairs(value) do
      M.pretty_json(item, indent .. "  ", out)
      -- The separator goes on whatever line the child ended on, which for a
      -- nested object or array is its closing brace rather than the line just
      -- written. Without this the output looks like JSON but is not, and a reader
      -- who copies it out of the float has to repair it.
      if index < #value then
        out[#out] = out[#out] .. ","
      end
    end
    out[#out + 1] = indent .. "]"
  else
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = tostring(key)
    end
    if #keys == 0 then
      out[#out + 1] = indent .. prefix .. "{}"
      return out
    end
    table.sort(keys)
    out[#out + 1] = indent .. prefix .. "{"
    for index, key in ipairs(keys) do
      M.pretty_json(value[key], indent .. "  ", out, quote(key) .. ": ")
      if index < #keys then
        out[#out] = out[#out] .. ","
      end
    end
    out[#out + 1] = indent .. "}"
  end
  return out
end

---Text blocks of a content array (`[{type="text",text=…}]`), which is how the
---Task tool and every MCP server answer.
---@param content any
---@return string[]|nil
local function content_lines(content)
  if type(content) ~= "table" then
    return nil
  end
  local lines = {}
  for _, block in ipairs(content) do
    if type(block) == "table" and type(block.text) == "string" then
      extend(lines, split_lines(block.text))
    elseif type(block) == "string" then
      extend(lines, split_lines(block))
    end
  end
  return #lines > 0 and lines or nil
end

---A separator naming a section of the float.
---@param label string
---@return string
local function rule(label)
  return "── " .. label .. " " .. string.rep("─", math.max(0, 40 - #label))
end

---@param input table|nil
---@return string[]
local function bash_command_lines(input)
  local command = type(input) == "table" and input.command or nil
  if type(command) ~= "string" or command == "" then
    return {}
  end
  local lines = {}
  for index, line in ipairs(split_lines(command)) do
    lines[#lines + 1] = (index == 1 and "$ " or "  ") .. line
  end
  return lines
end

--- Per-tool bodies. Each returns the float's lines, and may name a filetype for
--- them or ask for the ANSI pass. Falling through to nil means "pretty JSON".
---@type table<string, fun(input: table, result: any): { lines: string[], filetype: string?, ansi: boolean? }|nil>
local BODIES = {
  Bash = function(input, result)
    local lines = bash_command_lines(input)
    if type(result) ~= "table" then
      return nil
    end
    local stdout = type(result.stdout) == "string" and split_lines(result.stdout) or {}
    local stderr = type(result.stderr) == "string" and split_lines(result.stderr) or {}
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    if #stdout == 0 and #stderr == 0 then
      lines[#lines + 1] = result.interrupted and "(interrupted)" or "(no output)"
      return { lines = lines, ansi = true }
    end
    -- Both streams are named, and neither heading is an error report: a command
    -- that succeeded may still have written to stderr, and which stream a line
    -- came out of is part of reading the output. Naming only one of them left the
    -- reader to infer where the unlabelled block above came from.
    if #stdout > 0 then
      lines[#lines + 1] = rule("stdout")
      extend(lines, stdout)
    end
    if #stderr > 0 then
      if #stdout > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = rule("stderr")
      extend(lines, stderr)
    end
    return { lines = lines, ansi = true }
  end,
  TodoWrite = function(_, result)
    local todos = type(result) == "table" and (result.newTodos or result.todos) or nil
    if type(todos) ~= "table" then
      return nil
    end
    local marks = { completed = "[x]", in_progress = "[~]", pending = "[ ]" }
    local lines = {}
    for _, todo in ipairs(todos) do
      if type(todo) == "table" then
        local text = todo.content or todo.activeForm or ""
        lines[#lines + 1] = (marks[todo.status] or "[ ]") .. " " .. tostring(text)
      end
    end
    return #lines > 0 and { lines = lines, filetype = "markdown" } or nil
  end,
}

---What a float shows for one tool call.
---@param name string|nil Tool name.
---@param input table|nil The call's input.
---@param result any The decoded `toolUseResult`, or nil when it has not landed yet.
---@return { lines: string[], filetype: string|nil, ansi: boolean|nil }
function M.body(name, input, result)
  local tool = type(name) == "string" and name or "tool"

  if result == nil then
    local lines = tool == "Bash" and bash_command_lines(input) or {}
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "(still running — no result in the transcript yet)"
    return { lines = lines, filetype = nil, ansi = nil }
  end

  local rule_fn = BODIES[tool]
  if rule_fn then
    local rendered = rule_fn(input, result)
    if rendered then
      return { lines = rendered.lines, filetype = rendered.filetype, ansi = rendered.ansi }
    end
  end

  -- A rejected or errored call answers with a bare string, whatever the tool ran;
  -- so does `Grep` in its default mode. Shown as it is written.
  if type(result) == "string" then
    local lines = tool == "Bash" and bash_command_lines(input) or {}
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    extend(lines, split_lines(result))
    return { lines = lines, filetype = nil, ansi = true }
  end

  -- Content blocks: every MCP server answers this way, and so does `Task` — the
  -- subagent's reply, which is what the parent conversation actually received.
  local blocks = content_lines(result) or (type(result) == "table" and content_lines(result.content))
  if blocks then
    return { lines = blocks, filetype = "markdown", ansi = nil }
  end

  -- A file list (`Grep` in `files_with_matches` mode, `Glob`) is a list, not a
  -- document: shown one per line rather than as JSON.
  if type(result) == "table" and is_array(result.filenames) then
    local lines = vim.deepcopy(result.filenames)
    if #lines == 0 then
      lines = { "(no matches)" }
    end
    return { lines = lines, filetype = nil, ansi = nil }
  end

  return { lines = M.pretty_json(result), filetype = "json", ansi = nil }
end

return M
