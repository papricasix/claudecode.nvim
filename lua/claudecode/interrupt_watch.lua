---@brief [[
--- Noticing that the user cancelled a turn with `<Esc>`.
---
--- **There is no hook for this.** Verified against the real CLI (2.1.221) by
--- driving an interactive session through a pty with a hook registered on every
--- event Claude Code defines: submitting a prompt fires `UserPromptSubmit`, and
--- the interrupt fires *nothing* — not `Stop`, not the `StopFailure` the binary
--- also carries. So a cancelled tab stayed `busy` for ever and its spinner kept
--- animating, which means a repeating `redrawtabline` of the whole UI, until the
--- next prompt.
---
--- What the CLI *does* do is write `[Request interrupted by user]` into the
--- conversation as a real `user` entry. The transcript is therefore the only
--- place a cancel is reported, and reading it is the only way to see one.
--- (Reading the keypress instead was built, verified through a pty, and thrown
--- away: `<Esc>` means a dozen other things in Claude's TUI, and during a turn
--- with no tool calls there is no later event to correct a wrong guess with, so
--- a tab could read idle for minutes while Claude worked.)
---
--- The agents view already gets this for free — it folds transcripts anyway — so
--- this module exists for the configuration the bug was actually reported in: a
--- plain per-tab Claude with `agents` disabled, where nothing reads a transcript
--- at all.
---
--- Three things keep the cost proportional to what it fixes:
---
--- *The clock only runs while a tab is `busy`.* That is the only state an
--- interrupt can end, and it is exactly when the spinner is already burning a
--- repeating full-UI redraw. Idle Neovim does nothing.
---
--- *Only the bytes appended since the turn started are read.* `arm` records the
--- file's size at the moment the tab goes busy, so a tick is a `stat` plus, at
--- most, whatever the CLI has written since. It also removes the staleness
--- problem the agents side had to solve with timestamps: a transcript keeps
--- every interrupt the conversation ever had, and starting at end-of-file means
--- the only markers we can see belong to the turn we are watching.
---
--- *The marker test is `transcript._is_interrupt_line`, not a substring match.*
--- That function is where the false-positive lesson lives: `toolUseResult`
--- entries are `type:"user"` too, so a conversation whose tool output quotes the
--- marker — a transcript of writing this code does — matched a naive test and
--- read as cancelled.
---@brief ]]
---@module 'claudecode.interrupt_watch'

local M = {}

--- How often a busy tab's transcript is checked. Not configurable: it is the
--- latency of noticing a keypress that reports itself nowhere, and there is
--- nothing a user could sensibly tune it against. Injectable for specs.
M._interval_ms = 500

--- Most bytes read in one tick. A turn can append megabytes of tool output, and
--- the marker is always the *last* thing written, so on a large jump the middle
--- is skipped rather than read: missing a marker buried behind 256KB of output
--- written inside half a second costs the pre-existing behaviour (the spinner
--- runs until the next event), while reading it costs every user every tick.
local MAX_READ = 256 * 1024

--- How many ticks to wait before looking again for a transcript we could not
--- find. A tab goes busy on `UserPromptSubmit`, by which point the CLI has
--- written the user's message, so a miss is rare — but a glob is a directory
--- scan and must not run every 500ms on the strength of one.
local RESOLVE_RETRY_TICKS = 20

--- [session_id] = absolute path, or `false` for "looked, not there".
local paths = {}

--- [session_id] = { offset, misses }
local watched = {}

local timer = nil

---@return table|nil
local function transcript()
  local ok, mod = pcall(require, "claudecode.agents.transcript")
  return ok and mod or nil
end

---@return table|nil
local function status()
  local ok, mod = pcall(require, "claudecode.status")
  return ok and mod or nil
end

---The transcript for a conversation, wherever the CLI put it.
---
---Session ids are unique across the whole store, so the project directory does
---not have to be worked out — which sidesteps the CLI's undocumented path-to-slug
---rule entirely. Same trick `session_state.transcript_exists` uses.
---@param session_id string
---@return string|nil
function M._resolve(session_id)
  local cached = paths[session_id]
  if cached ~= nil then
    return cached or nil
  end
  local ok, found = pcall(function()
    local projects = require("claudecode.utils").claude_config_dir() .. "/projects"
    if vim.fn.isdirectory(projects) ~= 1 then
      return nil
    end
    local hits = vim.fn.glob(projects .. "/*/" .. session_id .. ".jsonl", true, true)
    return (type(hits) == "table" and hits[1]) or nil
  end)
  local path = (ok and type(found) == "string") and found or nil
  paths[session_id] = path or false
  return path
end

---Start watching a conversation from where its transcript currently ends.
---
---Called on the transition *into* `busy`, which is what makes the marker check
---unambiguous: everything already in the file belongs to an earlier turn.
---@param session_id string|nil
function M.arm(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return
  end
  local path = M._resolve(session_id)
  local size = 0
  if path then
    local t = transcript()
    local st = t and t._io.stat(path)
    size = (st and st.size) or 0
  end
  watched[session_id] = { offset = size, misses = 0 }
end

---Scan whatever one conversation has appended since it was armed.
---@param session_id string
---@param tab integer
local function scan(session_id, tab)
  local state = watched[session_id]
  if not state then
    M.arm(session_id)
    return
  end

  local path = M._resolve(session_id)
  if not path then
    -- Not written yet (or gone). Look again, but not on every tick.
    state.misses = (state.misses or 0) + 1
    if state.misses >= RESOLVE_RETRY_TICKS then
      state.misses = 0
      paths[session_id] = nil
    end
    return
  end

  local t = transcript()
  if not t then
    return
  end
  local st = t._io.stat(path)
  if not st then
    return
  end
  if st.size < state.offset then
    -- Compacted or replaced. Nothing before this point is ours to read.
    state.offset = st.size
    return
  end
  if st.size == state.offset then
    return
  end

  local from = state.offset
  if st.size - from > MAX_READ then
    from = st.size - MAX_READ
  end
  local len = st.size - from
  state.offset = st.size

  t._io.read(path, from, len, function(data)
    if type(data) ~= "string" or data == "" then
      return
    end
    local hit = false
    -- The last chunk has no trailing newline when the CLI is mid-write; it is
    -- skipped rather than tested, and re-read next tick because `offset` only
    -- ever moves to what the file already held.
    for line in data:gmatch("([^\n]*)\n") do
      if line ~= "" and t._is_interrupt_line(line) then
        hit = true
      end
    end
    if not hit then
      return
    end
    vim.schedule(function()
      local st_mod = status()
      if st_mod and st_mod.note_interrupt then
        st_mod.note_interrupt(tab)
      end
    end)
  end)
end

---One pass over every busy tab. Exposed so a spec can drive it without a timer.
function M._tick()
  local st = status()
  if not st or not st.all then
    return
  end
  local any = false
  for tab, entry in pairs(st.all()) do
    if entry.state == "busy" and type(entry.session_id) == "string" then
      any = true
      scan(entry.session_id, tab)
    end
  end
  if not any then
    M.stop()
  end
end

---Whether any tab is in the one state an interrupt can end.
---@return boolean
local function anyone_busy()
  local st = status()
  if not st or not st.all then
    return false
  end
  for _, entry in pairs(st.all()) do
    if entry.state == "busy" and type(entry.session_id) == "string" then
      return true
    end
  end
  return false
end

function M.stop()
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
    timer:close()
  end)
  timer = nil
end

---Match the clock to what is on screen. Called from `status.apply`, which is the
---one place a tab's state changes.
function M.sync()
  local st = status()
  if not st or not st.is_enabled or not st.is_enabled() then
    M.stop()
    return
  end
  if not anyone_busy() then
    M.stop()
    return
  end
  if timer then
    return
  end
  local ok, created = pcall(function()
    return vim.loop.new_timer()
  end)
  if not ok or not created then
    return
  end
  timer = created
  local interval = M._interval_ms
  pcall(function()
    created:start(interval, interval, function()
      vim.schedule(function()
        M._tick()
      end)
    end)
  end)
end

---@return boolean running
function M._is_running()
  return timer ~= nil
end

---Test/reload helper.
function M.reset()
  M.stop()
  paths = {}
  watched = {}
end

return M
