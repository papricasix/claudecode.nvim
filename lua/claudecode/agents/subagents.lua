---@brief [[
--- The subagents a session started, as a tree: what each one is, what it cost,
--- and how long it ran.
---
--- Nothing here is our own accounting. The CLI writes every subagent a transcript
--- of its own beside the session's, plus a small descriptor written when it starts:
---
---   <session>.jsonl
---   <session>/subagents/agent-<id>.jsonl
---   <session>/subagents/agent-<id>.meta.json   agentType, description,
---                                              toolUseId, parentAgentId,
---                                              spawnDepth, requestShape
---
--- Nested subagents sit in the same flat directory; `parentAgentId` is what makes
--- it a tree. How a run *ended* is recorded by whoever launched it:
---
--- * a **background** run ends with a `<task-notification>` (status, tokens,
---   duration) in the launching transcript — and, for a nested one, queued in the
---   session's transcript as well;
--- * a **foreground** run ends with the `Agent` call's own result, which carries
---   `totalTokens` and `totalDurationMs`.
---
--- `transcript.lua` folds both into every summary, so the answer is the union of
--- the session's summary and each subagent's.
---
--- **Background shells** share the tree, under whoever started them: the session's
--- own at the top, a subagent's beneath it. They are the CLI's other kind of
--- background task and are recorded the same way — the call, a result carrying
--- `backgroundTaskId` and the path its output streams into, and a
--- `<task-notification>` with status and exit code in the launching transcript.
---@brief ]]
---@module 'claudecode.agents.subagents'

local transcript = require("claudecode.agents.transcript")

local M = {}

--- A run with no ending recorded is only called running while something could be
--- running it. When the session is not known to be live here, a transcript that
--- has not been written for this long is taken as abandoned — its CLI exited
--- without notifying anyone, which no record on disk will ever say. Ten minutes
--- is the longest a single tool call is allowed to run, during which a working
--- subagent writes nothing.
M.STALE_S = 10 * 60

--- Descriptors already read, [path] = { size, mtime, meta }. Written once when the
--- run starts, so a stat is enough to know one has not changed.
local meta_cache = {}

--- Transcript sizes last reported, so a refresh only announces what moved.
local seen_size = {}

---The directory a session's subagents live in.
---@param transcript_path string
---@return string|nil
function M.dir(transcript_path)
  if type(transcript_path) ~= "string" then
    return nil
  end
  local base, count = transcript_path:gsub("%.jsonl$", "")
  if count == 0 then
    return nil
  end
  return base .. "/subagents"
end

---@param path string
---@param st table
---@return table|nil
local function read_meta(path, st)
  local hit = meta_cache[path]
  if hit and hit.size == st.size and hit.mtime == st.mtime then
    return hit.meta
  end
  local read_sync = transcript._io.read_sync
  local data = type(read_sync) == "function" and read_sync(path, 64 * 1024) or nil
  local meta = nil
  if type(data) == "string" and data ~= "" then
    local ok, decoded = pcall(vim.json.decode, data)
    meta = ok and type(decoded) == "table" and decoded or nil
  end
  meta_cache[path] = { size = st.size, mtime = st.mtime, meta = meta }
  return meta
end

---@class ClaudeCodeSubagent
---@field id string
---@field agent_type string
---@field description string|nil
---@field tool_use_id string|nil
---@field parent_id string|nil
---@field shape string|nil `background` | `foreground`
---@field path string Its transcript.
---@field started number Epoch seconds the descriptor was written.
---@field mtime number Epoch seconds its transcript was last written (0 when it has none yet).

---Every subagent a session has started, in no particular order.
---
---Stat-only apart from each descriptor's first read, like `transcript.list`.
---@param transcript_path string
---@return ClaudeCodeSubagent[]
function M.scan(transcript_path)
  local out = {}
  -- Checked, not assumed: a spec may hand the model a transcript module with no
  -- filesystem behind it.
  local fs = transcript._io
  local dir = M.dir(transcript_path)
  local names = dir and fs and fs.scandir and fs.scandir(dir)
  if not names then
    return out
  end
  for _, name in ipairs(names) do
    local id = name:match("^agent%-(.+)%.meta%.json$")
    if id then
      local meta_path = dir .. "/" .. name
      local st = fs.stat(meta_path)
      local meta = st and read_meta(meta_path, st)
      if st and meta then
        local path = dir .. "/agent-" .. id .. ".jsonl"
        local log = fs.stat(path)
        out[#out + 1] = {
          id = id,
          agent_type = type(meta.agentType) == "string" and meta.agentType or "agent",
          description = type(meta.description) == "string" and meta.description or nil,
          tool_use_id = type(meta.toolUseId) == "string" and meta.toolUseId or nil,
          parent_id = type(meta.parentAgentId) == "string" and meta.parentAgentId or nil,
          shape = type(meta.requestShape) == "string" and meta.requestShape or nil,
          path = path,
          started = st.mtime or 0,
          mtime = log and log.mtime or 0,
        }
      end
    end
  end
  return out
end

---Fold the session's transcript and every subagent's up to date.
---
---Asynchronous, and cheap when nothing moved: each `transcript.summary` answers
---from its cache after one stat. `on_change` is called once per transcript that
---actually grew, which is what the view repaints on.
---@param transcript_path string
---@param on_change fun()|nil
function M.refresh(transcript_path, on_change)
  if type(transcript_path) ~= "string" then
    return
  end
  local paths = { transcript_path }
  for _, agent in ipairs(M.scan(transcript_path)) do
    paths[#paths + 1] = agent.path
  end
  for _, path in ipairs(paths) do
    transcript.summary(path, function(sum)
      local size = sum and sum.size or nil
      if size ~= seen_size[path] then
        seen_size[path] = size
        if on_change then
          on_change()
        end
      end
    end)
  end
end

---Merge a table of results into `into`, newest per key.
---@param into table
---@param from table|nil
local function merge_newest(into, from)
  for key, value in pairs(from or {}) do
    local previous = into[key]
    if not previous or (value.ts or 0) >= (previous.ts or 0) then
      into[key] = value
    end
  end
end

--- What a notification's status word means for the row.
local ENDED = { completed = "done", killed = "stopped", stopped = "stopped", cancelled = "stopped" }

---@class ClaudeCodeSubagentRow
---@field kind "subagent"|"shell"
---@field id string An agent id, or a shell's task id.
---@field agent_type string For a shell, the tool that ran it (`Bash`, `PowerShell`).
---@field description string|nil
---@field depth integer 0 for a subagent the session started itself.
---@field prefix string Tree connectors drawn before the icon ("", "├─", "│ └─", …).
---@field state "running"|"done"|"failed"|"stopped"
---@field tokens integer|nil
---@field runtime_s number|nil
---@field command string|nil Shells: one line of the command.
---@field tool_id string|nil Shells: the call that started it.
---@field exit_code integer|nil Shells: how it exited, once it has.
---@field output_path string|nil Shells: the file its output streams into.
---@field transcript string|nil Shells: the transcript that launched it.
---@field by_user boolean|nil Shells: sent to the background with Ctrl+B.
---@field ended boolean|nil Shells: the CLI recorded how it ended.

---Where one run stands, from everything that could have recorded its end.
---@param agent ClaudeCodeSubagent
---@param index { notes: table, results: table, calls: table }
---@param opts { live: boolean?, now: number? } `now` is always filled in by `rows`.
---@return string state
---@return integer|nil tokens
---@return number|nil runtime_s
local function classify(agent, index, opts)
  local sum = transcript.get(agent.path)
  local first = (sum and sum.first_ts and sum.first_ts > 0) and sum.first_ts or agent.started
  local last = (sum and sum.last_ts and sum.last_ts > 0) and sum.last_ts or agent.mtime
  local live_tokens = sum and sum.tokens or nil

  local result = agent.tool_use_id and index.results[agent.tool_use_id]
  if result then
    return result.status == "completed" and "done" or "failed",
      result.tokens or live_tokens,
      result.duration_ms and result.duration_ms / 1000 or math.max(0, last - first)
  end

  -- A notification older than the transcript's newest line belongs to an earlier
  -- stop: the agent was sent another message and is working again. Same-second
  -- counts as ended, since the notification is written after the run's last line.
  local note = index.notes[agent.id]
  if note and last <= note.ts then
    return ENDED[note.status] or "failed",
      note.tokens or live_tokens,
      note.duration_ms and note.duration_ms / 1000 or math.max(0, last - first)
  end

  -- A foreground call the user interrupted or declined never gets a result.
  local call = agent.tool_use_id and index.calls[agent.tool_use_id]
  if call and not note and (call.status == "interrupted" or call.status == "rejected") then
    return "stopped", live_tokens, math.max(0, last - first)
  end

  local recent = (opts.now - math.max(agent.mtime or 0, agent.started or 0)) < M.STALE_S
  if opts.live or recent then
    return "running", live_tokens, math.max(0, opts.now - first)
  end
  return "stopped", live_tokens, math.max(0, last - first)
end

--- What a shell's notification status means for its row.
local SHELL_ENDED = { completed = "done", failed = "failed", killed = "stopped", stopped = "stopped" }

---Where one background shell stands.
---
---Its notification is the only record of an end, and a shell notifies exactly
---once. Without one it is running while its output file exists and either the
---session is live or the file is still being written — a shell that prints
---nothing for ten minutes in a session not known to be live here reads stopped,
---the same bargain `classify` makes for a quiet subagent.
---@param shell ClaudeCodeAgentsShell
---@param note ClaudeCodeAgentsTaskResult|nil
---@param opts { live: boolean?, now: number }
---@return string state
---@return number|nil runtime_s
---@return integer|nil exit_code
function M.shell_state(shell, note, opts)
  local started = shell.started_ts or shell.ts or 0
  if note then
    local state = SHELL_ENDED[note.status] or "failed"
    -- `completed` with a non-zero code does not happen, but a code is the harder fact.
    if state == "done" and note.exit_code and note.exit_code ~= 0 then
      state = "failed"
    end
    return state, math.max(0, (note.ts or started) - started), note.exit_code
  end
  -- A running shell always has its output file; one that is gone (the temp
  -- directory was swept, or the CLI cleaned up after itself) is not running,
  -- whatever else is true. Asked first so a live session does not keep a shell
  -- its previous process took with it spinning for ever.
  local written = nil
  local fs = transcript._io
  if shell.output_path and fs and fs.stat then
    local st = fs.stat(shell.output_path)
    if not st then
      return "stopped", nil, nil
    end
    written = st.mtime or 0
  end
  if opts.live or (written and (opts.now - written) < M.STALE_S) then
    return "running", math.max(0, opts.now - started), nil
  end
  return "stopped", math.max(0, math.max(written, started) - started), nil
end

---The session's subagents and background shells as a flattened tree, children
---under their parent in the order they started.
---@param transcript_path string
---@param opts { live: boolean?, now: number? }|nil `live`: the session is running.
---@return ClaudeCodeSubagentRow[]
function M.rows(transcript_path, opts)
  opts = { live = opts and opts.live, now = (opts and opts.now) or os.time() }
  local agents = M.scan(transcript_path)

  local index = { notes = {}, results = {}, calls = {} }
  ---@type { sum: table, parent: string|nil, path: string }[]
  local sources = {}
  local session = transcript.get(transcript_path)
  if session then
    sources[#sources + 1] = { sum = session, path = transcript_path }
  end
  for _, agent in ipairs(agents) do
    local sum = transcript.get(agent.path)
    if sum then
      sources[#sources + 1] = { sum = sum, parent = agent.id, path = agent.path }
    end
  end
  for _, source in ipairs(sources) do
    local sum = source.sum
    merge_newest(index.notes, sum.task_notes)
    merge_newest(index.results, sum.agent_results)
    for id, call in pairs(sum.agent_calls or {}) do
      index.calls[id] = call
    end
  end

  -- Every node of the tree, subagents and shells alike, sorted and walked as one.
  ---@type table[]
  local nodes = {}
  for _, agent in ipairs(agents) do
    nodes[#nodes + 1] = agent
  end
  for _, source in ipairs(sources) do
    for task_id, shell in pairs(source.sum.shells or {}) do
      nodes[#nodes + 1] = {
        kind = "shell",
        id = task_id,
        parent_id = source.parent,
        started = shell.started_ts or shell.ts or 0,
        shell = shell,
        transcript = source.path,
      }
    end
  end
  if #nodes == 0 then
    return {}
  end

  local by_id, children, roots = {}, {}, {}
  for _, agent in ipairs(agents) do
    by_id[agent.id] = agent
  end
  for _, agent in ipairs(nodes) do
    -- A parent we cannot see (its descriptor unreadable) would orphan the whole
    -- branch; it is drawn from the top instead.
    if agent.parent_id and by_id[agent.parent_id] and agent.parent_id ~= agent.id then
      children[agent.parent_id] = children[agent.parent_id] or {}
      table.insert(children[agent.parent_id], agent)
    else
      roots[#roots + 1] = agent
    end
  end

  local function by_start(a, b)
    if a.started ~= b.started then
      return a.started < b.started
    end
    return a.id < b.id
  end

  local out, visited = {}, {}
  ---@param list table[] Subagents, and shell nodes (`kind = "shell"`).
  ---@param depth integer
  ---@param stem string Connectors inherited from the ancestors.
  local function walk(list, depth, stem)
    table.sort(list, by_start)
    for position, agent in ipairs(list) do
      if not visited[agent.id] then
        visited[agent.id] = true
        local last = position == #list
        local prefix = depth == 0 and "" or (stem .. (last and "└─" or "├─"))
        if agent.kind == "shell" then
          local shell = agent.shell
          local note = index.notes[agent.id]
          local state, runtime, exit_code = M.shell_state(shell, note, opts)
          out[#out + 1] = {
            kind = "shell",
            id = agent.id,
            agent_type = shell.tool,
            description = shell.description,
            command = shell.command,
            tool_id = shell.tool_id,
            depth = depth,
            prefix = prefix,
            state = state,
            runtime_s = runtime,
            exit_code = exit_code,
            output_path = shell.output_path or (note and note.output_file) or nil,
            by_user = shell.by_user,
            ended = note ~= nil,
            transcript = agent.transcript,
          }
        else
          local state, tokens, runtime = classify(agent, index, opts)
          out[#out + 1] = {
            kind = "subagent",
            id = agent.id,
            agent_type = agent.agent_type,
            description = agent.description,
            depth = depth,
            prefix = prefix,
            state = state,
            tokens = tokens,
            runtime_s = runtime,
          }
        end
        if children[agent.id] then
          walk(children[agent.id], depth + 1, depth == 0 and "" or (stem .. (last and "  " or "│ ")))
        end
      end
    end
  end
  walk(roots, 0, "")
  return out
end

---`167k`, `9.1k`, `1.2M`: short enough for a narrow pane, precise where it is small.
---@param tokens integer|nil
---@return string
function M.format_tokens(tokens)
  if type(tokens) ~= "number" then
    return "·"
  end
  if tokens < 1000 then
    return tostring(math.floor(tokens))
  elseif tokens < 10000 then
    return (("%.1fk"):format(tokens / 1000):gsub("%.0k$", "k"))
  elseif tokens < 1000000 then
    return ("%dk"):format(math.floor(tokens / 1000 + 0.5))
  end
  return (("%.1fM"):format(tokens / 1000000):gsub("%.0M$", "M"))
end

---`0:51`, `13:50`, `1:02:03`.
---@param seconds number|nil
---@return string
function M.format_runtime(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    return "·"
  end
  local s = math.floor(seconds)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  if h > 0 then
    return ("%d:%02d:%02d"):format(h, m, s % 60)
  end
  return ("%d:%02d"):format(m, s % 60)
end

---Test/reload helper.
function M.reset()
  meta_cache = {}
  seen_size = {}
end

return M
