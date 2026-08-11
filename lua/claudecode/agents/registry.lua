---@brief [[
--- Several Claude terminals inside one tabpage, keyed by conversation.
---
--- The terminal providers (`terminal/native.lua`, `terminal/snacks.lua`) each hold
--- exactly one instance per tabpage — a shape baked into their whole contract,
--- down to `get_active_bufnr()` returning a single buffer. Agents mode needs N in
--- one tab, so it keeps its own registry rather than bending that one.
---
--- Hiding an agent is just "its buffer is in no window". `bufhidden = "hide"` is
--- what makes that safe: without it Neovim would wipe the buffer the moment it
--- left the screen and take the running CLI with it. So switching between agents
--- is a buffer swap, and the agent you switch away from keeps working, keeps its
--- scrollback, and is exactly where you left it when you come back.
---
--- The command itself is not rebuilt here — `terminal.build_launch` produces the
--- same command, environment and hook injection every other launch path gets, so
--- an agent is a normal Claude in every respect except where its terminal lives.
--- Each agent is handed its own server instance, so its diffs, file opens and
--- @ mentions are its own rather than the tab's.
---@brief ]]
---@module 'claudecode.agents.registry'

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

local M = {}

---The agents config subtable.
---
---Read on demand rather than stored at setup: this module has no `setup` of its
---own, and the only thing it needs from the config is asked for once per launch.
---@return table
local function agents_opts()
  local ok, claudecode = pcall(require, "claudecode")
  local config = ok and claudecode.state and claudecode.state.config
  return (type(config) == "table" and type(config.agents) == "table") and config.agents or {}
end

---@class ClaudeCodeAgentTerminal
---@field session_id string Conversation this terminal is running *now*.
---@field agent_key string Identity of the launch, stable across /clear.
---@field retired table<string, boolean>|nil Conversations it has already left.
---@field bufnr integer Terminal buffer; stays loaded while hidden.
---@field jobid integer
---@field tab integer Tabpage hosting the agents view.
---@field cwd string|nil
---@field instance table|nil The server instance this agent talks to.
---@field resumed boolean Whether it was started with --resume.
---@field started_at number
---@field exited boolean
---@field exit_code integer|nil

--- [session id] = ClaudeCodeAgentTerminal
local terminals = {}

--- [agent key] = ClaudeCodeAgentTerminal
---
--- The second index exists because the first one moves. A conversation id names
--- the chat, not the process: `/clear` ends the conversation the CLI was having
--- and starts another one under a fresh id in the *same* terminal (measured
--- against 2.1.226 — `SessionEnd(reason="clear")` then `SessionStart(source=
--- "clear")` with a new id), and `--fork-session` does the same at launch. So a
--- launch needs a name of its own to be addressed by, and the hook carries it
--- back in `CLAUDECODE_AGENT_ID`.
local by_agent = {}

--- Distinguishes two launches that name the same conversation — a cleared agent
--- keeps its key while the id it was launched with becomes startable again.
local launch_seq = 0

--- Injectable so specs can drive launches without spawning a process.
M._spawn = function(cmd, opts)
  return vim.fn.termopen(cmd, opts)
end

---A directory the CLI can actually be started in, or nil.
---
---A conversation records the directory it ran in, and that directory can be
---gone: renaming or moving a project leaves every one of its transcripts naming
---a path that no longer exists. `termopen` refuses such a cwd outright (`E475:
---expected valid directory`), which is the whole of the reported failure —
---sessions that read perfectly well in every pane could not be started, because
---the launch was told to enter a directory the user had moved months ago. The
---launch is worth more than the recorded path, so an unusable one is dropped
---for the caller's fallback: the directory the view is attached to, which for a
---moved project is where those transcripts now live anyway.
---@param cwd string|nil
---@return string|nil
function M._usable_cwd(cwd)
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end
  local expanded = vim.fn.expand(cwd)
  if vim.fn.isdirectory(expanded) == 0 then
    return nil
  end
  return cwd
end

---@param session_id string
---@return ClaudeCodeAgentTerminal|nil
function M.get(session_id)
  return terminals[session_id]
end

---Whether a conversation has a live process here.
---@param session_id string
---@return boolean
function M.is_live(session_id)
  local term = terminals[session_id]
  return term ~= nil and not term.exited and vim.api.nvim_buf_is_valid(term.bufnr)
end

---Every conversation this registry is running.
---@return string[]
function M.live_ids()
  local ids = {}
  for session_id in pairs(terminals) do
    if M.is_live(session_id) then
      ids[#ids + 1] = session_id
    end
  end
  table.sort(ids)
  return ids
end

---Which conversation a terminal buffer belongs to.
---Used by the `TermClose` watcher, which is handed a buffer and nothing else.
---@param bufnr integer
---@return string|nil
function M.session_for_buf(bufnr)
  for session_id, term in pairs(terminals) do
    if term.bufnr == bufnr then
      return session_id
    end
  end
  return nil
end

---Show an already-running agent in a window, without restarting it.
---@param session_id string
---@param win integer
---@return boolean shown False when there is nothing running for that conversation.
function M.show(session_id, win)
  local term = terminals[session_id]
  if not term or not vim.api.nvim_buf_is_valid(term.bufnr) then
    return false
  end
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ok = pcall(vim.api.nvim_win_set_buf, win, term.bufnr)
  return ok
end

---Start a Claude for one conversation in the given window.
---
---@param session_id string Conversation id to name (or resume) this agent with.
---@param opts { win: integer, tab: integer?, cwd: string?, resume: boolean?, focus: boolean? }
---@return ClaudeCodeAgentTerminal|nil term
---@return string|nil error
function M.launch(session_id, opts)
  if type(session_id) ~= "string" or session_id == "" then
    return nil, "session_id is required"
  end
  opts = opts or {}
  if not opts.win or not vim.api.nvim_win_is_valid(opts.win) then
    return nil, "a valid window is required"
  end

  local existing = terminals[session_id]
  if existing and not existing.exited and vim.api.nvim_buf_is_valid(existing.bufnr) then
    M.show(session_id, opts.win)
    return existing, nil
  end

  local tab = opts.tab or vim.api.nvim_get_current_tabpage()
  local claudecode = require("claudecode")
  local instance, inst_err = claudecode.start_agent_instance(session_id, tab)
  if not instance then
    -- Without a server of its own the CLI would scan lock files and attach to
    -- some other editor, sending this agent's diffs and file opens there.
    return nil, "could not start a server for this agent: " .. tostring(inst_err)
  end

  local cwd = M._usable_cwd(opts.cwd)
  if opts.cwd and not cwd then
    logger.warn("agents", "the directory this conversation ran in is gone, starting elsewhere:", opts.cwd)
  end

  local terminal = require("claudecode.terminal")
  -- The CLI decides which conversation to open from these flags; passing them
  -- explicitly is also what makes session_state stand down for this launch.
  -- `--fork-session` resumes the conversation into a *new* one, leaving the
  -- original transcript untouched — which is what a user who set
  -- `resume_mode = "fork"` asked for. Without consulting it the setting was
  -- documented, validated and inert.
  local resume_flag = (agents_opts().resume_mode == "fork") and "--fork-session " or "--resume "
  local flag = opts.resume and (resume_flag .. session_id) or ("--session-id " .. session_id)
  local ok_cmd, cmd_string, env_table, effective = pcall(terminal.build_launch, flag, {
    cwd = cwd,
    instance = instance,
  })
  if not ok_cmd then
    claudecode.stop_agent_instance(session_id)
    return nil, "could not build the Claude command: " .. tostring(cmd_string)
  end

  -- Name this launch to the hook. Every event the CLI reports carries the
  -- conversation it is *currently* having, which is the one thing that changes
  -- under us; the key does not, so it is what tells us which of several agents
  -- the report belongs to. Inherited by the hook process the same way
  -- CLAUDECODE_NVIM_SERVER is — the CLI spawns hooks as children.
  launch_seq = launch_seq + 1
  local agent_key = string.format("%d:%s", launch_seq, session_id)
  env_table = env_table or {}
  env_table.CLAUDECODE_AGENT_ID = agent_key

  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    claudecode.stop_agent_instance(session_id)
    return nil, "could not create a terminal buffer"
  end

  local previous_buf = vim.api.nvim_win_get_buf(opts.win)
  local ok_attach = pcall(vim.api.nvim_win_set_buf, opts.win, buf)
  if not ok_attach then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    claudecode.stop_agent_instance(session_id)
    return nil, "could not attach the terminal buffer to the window"
  end

  local jobid
  local ok_spawn, spawn_err = pcall(vim.api.nvim_win_call, opts.win, function()
    jobid = M._spawn(utils.parse_command(cmd_string), {
      env = env_table,
      cwd = M._usable_cwd(effective and effective.cwd) or cwd,
      on_exit = function(job_id, code)
        vim.schedule(function()
          M._on_exit(session_id, job_id, code)
        end)
      end,
    })
  end)

  if not ok_spawn or not jobid or jobid == 0 then
    pcall(vim.api.nvim_win_set_buf, opts.win, previous_buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    claudecode.stop_agent_instance(session_id)
    -- Say *why*. `termopen` reports a missing command, an unreadable directory
    -- and a bad shell quite differently, and swallowing all of them into one
    -- sentence left the user with nothing to act on.
    local reason = (not ok_spawn) and tostring(spawn_err) or nil
    return nil, "could not start the Claude process" .. (reason and (": " .. reason) or "")
  end

  -- The one option that makes a hidden agent survive: without it Neovim wipes the
  -- buffer as soon as it leaves the window, killing the process with it.
  pcall(function()
    vim.bo[buf].bufhidden = "hide"
  end)
  -- The TermClose watcher is handed only a buffer, and by then the terminal may be
  -- in no window at all, so both the tab and the conversation are stamped now.
  pcall(function()
    vim.b[buf].claudecode_tab = tab
    vim.b[buf].claudecode_agent_session = session_id
  end)

  -- Shift+Enter inserts a newline rather than submitting, matching the snacks
  -- provider. Agents mode places its own terminals (the providers hold one per
  -- tabpage), so a keymap that arrives with the provider has to be applied here
  -- or an agent's terminal would behave differently from every other Claude.
  pcall(vim.keymap.set, "t", "<S-CR>", terminal.send_newline, { buffer = buf, desc = "New line" })

  local term = {
    session_id = session_id,
    agent_key = agent_key,
    bufnr = buf,
    jobid = jobid,
    tab = tab,
    cwd = M._usable_cwd(effective and effective.cwd) or cwd,
    instance = instance,
    resumed = opts.resume == true,
    started_at = vim.loop and vim.loop.now() or 0,
    exited = false,
  }
  terminals[session_id] = term
  by_agent[agent_key] = term

  if opts.focus then
    pcall(vim.api.nvim_set_current_win, opts.win)
    pcall(vim.cmd, "startinsert")
  end

  logger.debug("agents", "launched agent", session_id, "on port", tostring(instance.port))
  return term, nil
end

---Follow a running agent onto a different conversation.
---
---`/clear` (and `/resume` from inside the CLI, and `--fork-session` at launch)
---leaves the terminal, the process and the server exactly where they are and
---changes only which conversation is being had. Everything here is keyed by
---conversation, so without this the registry goes on describing a chat the CLI
---has abandoned: the old row keeps its running bullet, the new conversation
---turns up as a row that looks stopped — the reported symptom — and selecting it
---would `--resume` a transcript the running CLI is already writing to.
---
---The rename reaches the three things that name a conversation: this index, the
---agent's own server instance (so its diffs and file opens are still tagged with
---the chat that asked for them) and any float already on screen (so an ending
---agent still takes its own windows with it).
---
---An agent never drifts back onto a conversation it has already left. The two
---events that describe a `/clear` — `SessionEnd` for the old chat, `SessionStart`
---for the new one — are separate hook processes and the injection runs them
---async, so the CLI's order is not the order they reach us; without the retired
---set a late `SessionEnd` would point the agent back at the conversation it had
---just abandoned. `reclaim` is how the exception gets through: a `SessionStart`
---is the CLI stating which conversation it is having *now*, so `/resume`-ing back
---to an earlier one in the same terminal is followed rather than refused.
---@param agent_key string|nil The launch's `CLAUDECODE_AGENT_ID`.
---@param session_id string|nil The conversation it reports now.
---@param opts { reclaim: boolean? }|nil
---@return string|nil previous The id it was running until now, if this changed anything.
function M.rekey(agent_key, session_id, opts)
  if type(agent_key) ~= "string" or agent_key == "" then
    return nil
  end
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  local term = by_agent[agent_key]
  if not term or term.exited then
    return nil
  end
  local previous = term.session_id
  if previous == session_id then
    return nil
  end
  term.retired = term.retired or {}
  if term.retired[session_id] and not (opts and opts.reclaim) then
    return nil
  end
  term.retired[previous] = true
  term.retired[session_id] = nil

  terminals[previous] = nil
  terminals[session_id] = term
  term.session_id = session_id
  if vim.api.nvim_buf_is_valid(term.bufnr) then
    pcall(function()
      vim.b[term.bufnr].claudecode_agent_session = session_id
    end)
  end
  pcall(function()
    require("claudecode").rekey_agent_instance(term.instance, session_id)
  end)
  pcall(function()
    require("claudecode.float").retag(previous, session_id)
  end)

  logger.debug("agents", "agent", agent_key, "moved from", previous, "to", session_id)
  return previous
end

---Record that an agent's process ended.
---@param session_id string
---@param job_id integer|nil
---@param code integer|nil
function M._on_exit(session_id, job_id, code)
  local term = terminals[session_id]
  if not term or (job_id and term.jobid ~= job_id) then
    return
  end
  term.exited = true
  term.exit_code = code
  -- An agent that ended cannot answer a diff, so leaving its floats up would
  -- offer the user a decision nobody is waiting for.
  pcall(function()
    require("claudecode.agents.float").close_all(session_id)
  end)
  -- The server outlives nothing: an agent that ended has no client, and leaving
  -- its port and lock file behind would advertise an editor that cannot answer.
  pcall(function()
    require("claudecode").stop_agent_instance(session_id)
  end)
  logger.debug("agents", "agent", session_id, "exited with", tostring(code))
end

---Stop one agent and forget it.
---@param session_id string
---@return boolean stopped
function M.stop(session_id)
  local term = terminals[session_id]
  if not term then
    return false
  end
  if term.jobid and not term.exited then
    pcall(vim.fn.jobstop, term.jobid)
  end
  pcall(function()
    require("claudecode").stop_agent_instance(session_id)
  end)
  if vim.api.nvim_buf_is_valid(term.bufnr) then
    pcall(vim.api.nvim_buf_delete, term.bufnr, { force = true })
  end
  terminals[session_id] = nil
  if term.agent_key then
    by_agent[term.agent_key] = nil
  end
  return true
end

---Stop every agent hosted by a tab.
---@param tab integer
---@return integer stopped
function M.cleanup_tab(tab)
  local doomed = {}
  for session_id, term in pairs(terminals) do
    if term.tab == tab then
      doomed[#doomed + 1] = session_id
    end
  end
  for _, session_id in ipairs(doomed) do
    M.stop(session_id)
  end
  return #doomed
end

---Stop everything (Neovim is exiting, or a test is resetting).
function M.reset()
  for session_id in pairs(terminals) do
    M.stop(session_id)
  end
  terminals = {}
  by_agent = {}
end

return M
