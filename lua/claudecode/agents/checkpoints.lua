---@brief [[
--- Checkpoints: lines drawn through a conversation's history, so what an agent
--- does from now on is listed apart from what it did before.
---
--- A checkpoint is a moment (epoch seconds) stamped on one conversation. Every
--- record the panes draw — a file edit, an Activity event, a task — carries the
--- transcript's own timestamp, and the checkpoint sorts each one into an *era*:
--- everything at or before the first checkpoint is era 1, everything after the
--- last is the current one. The Changes pane then lists a file once per era it
--- was edited in, with that era's own counts, and `<CR>` on such a row shows the
--- file as the era left it against the file as the era found it. Activity and
--- Tasks draw a rule where each checkpoint falls.
---
--- Kept per conversation rather than per view, and on disk rather than in memory:
--- a checkpoint says "I have reviewed up to here", which is a fact about the
--- conversation and outlives both the view and Neovim. The store is a small JSON
--- file beside the warm cache; losing it loses only the marks.
---
--- The moment is compared against transcript timestamps, which the CLI writes in
--- whole seconds, so an edit that lands in the same second as the checkpoint
--- counts as before it. That is the honest side to err on: the checkpoint was
--- taken while it was on screen.
---@brief ]]
---@module 'claudecode.agents.checkpoints'

local M = {}

--- Bumped when a persisted field changes meaning.
local STORE_VERSION = 1

--- `[session_id] = { ts, ts, … }`, ascending. Empty until the store is read.
---@type table<string, number[]>
local marks = {}
local loaded = false

--- The filesystem, as a seam for specs.
M._io = {
  ---@param path string
  ---@return string[]|nil lines nil when the file cannot be read.
  read = function(path)
    if vim.fn.filereadable(path) ~= 1 then
      return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
  end,
  ---@param path string
  ---@param lines string[]
  write = function(path, lines)
    pcall(function()
      vim.fn.mkdir(path:match("^(.*)[/\\][^/\\]*$") or ".", "p")
      vim.fn.writefile(lines, path)
    end)
  end,
}

---@return string path
function M.path()
  return vim.fn.stdpath("cache") .. "/claudecode/agents-checkpoints.json"
end

---Read the store once. A missing or unreadable file is an empty store.
local function load()
  if loaded then
    return
  end
  loaded = true
  marks = {}
  local lines = M._io.read(M.path())
  if not lines then
    return
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(lines, "\n"))
  end)
  if not ok or type(decoded) ~= "table" or decoded.version ~= STORE_VERSION or type(decoded.sessions) ~= "table" then
    return
  end
  for id, list in pairs(decoded.sessions) do
    if type(id) == "string" and type(list) == "table" then
      local kept = {}
      for _, ts in ipairs(list) do
        if type(ts) == "number" and ts > 0 then
          kept[#kept + 1] = ts
        end
      end
      table.sort(kept)
      if #kept > 0 then
        marks[id] = kept
      end
    end
  end
end

local function save()
  local sessions = {}
  for id, list in pairs(marks) do
    if #list > 0 then
      sessions[id] = list
    end
  end
  local ok, encoded = pcall(vim.json.encode, { version = STORE_VERSION, sessions = sessions })
  if ok then
    M._io.write(M.path(), vim.split(encoded, "\n", { plain = true }))
  end
end

---The checkpoints on a conversation, oldest first. A copy: callers keep it
---across a repaint, and the store may change underneath.
---@param session_id string|nil
---@return number[]
function M.list(session_id)
  load()
  local out = {}
  for _, ts in ipairs((session_id and marks[session_id]) or {}) do
    out[#out + 1] = ts
  end
  return out
end

---Stamp a checkpoint on a conversation.
---
---Refused when one already sits at that second: two marks with nothing between
---them would draw an empty era, and the second press was a repeat, not a request.
---@param session_id string
---@param ts number|nil Epoch seconds; now by default.
---@return number|nil ts The checkpoint, or nil when nothing was added.
---@return integer count How many the conversation now has.
function M.add(session_id, ts)
  load()
  ts = ts or os.time()
  local list = marks[session_id] or {}
  for _, existing in ipairs(list) do
    if existing == ts then
      return nil, #list
    end
  end
  list[#list + 1] = ts
  table.sort(list)
  marks[session_id] = list
  save()
  return ts, #list
end

---Remove a conversation's newest checkpoint, merging its era into the next.
---@param session_id string
---@return number|nil ts The checkpoint dropped, or nil when there was none.
---@return integer count How many are left.
function M.drop(session_id)
  load()
  local list = marks[session_id]
  if not list or #list == 0 then
    return nil, 0
  end
  local ts = table.remove(list)
  if #list == 0 then
    marks[session_id] = nil
  end
  save()
  return ts, #list
end

---Forget every checkpoint on a conversation — it was deleted.
---@param session_id string
function M.forget(session_id)
  load()
  if marks[session_id] then
    marks[session_id] = nil
    save()
  end
end

---Which era a moment falls in: 1 for anything at or before the first checkpoint,
---`#list + 1` for anything after the last.
---@param list number[] Ascending.
---@param ts number|nil Epoch seconds; nothing known reads as the oldest era.
---@return integer era
function M.era(list, ts)
  ts = tonumber(ts) or 0
  for index, mark in ipairs(list) do
    if ts <= mark then
      return index
    end
  end
  return #list + 1
end

---The checkpoints an era lies between: nil where it is open-ended.
---@param list number[] Ascending.
---@param era integer
---@return number|nil from Exclusive.
---@return number|nil to Inclusive.
function M.bounds(list, era)
  return list[era - 1], list[era]
end

---A checkpoint's moment, as the panes name it: the clock alone on the day it was
---taken, the date as well from the next day on. `%H:%M` because that is what the
---Activity column beside it shows.
---@param ts number
---@param now number|nil Epoch seconds, for "today".
---@return string
function M.label(ts, now)
  now = now or os.time()
  local day = os.date("%Y-%m-%d", ts)
  if day == os.date("%Y-%m-%d", now) then
    return os.date("%H:%M", ts) --[[@as string]]
  end
  return os.date("%b %d %H:%M", ts) --[[@as string]]
end

---How a float names an era: `until 14:32`, `since 14:32`, `12:00 – 14:32`.
---@param list number[] Ascending.
---@param era integer
---@param now number|nil
---@return string
function M.era_note(list, era, now)
  local from, to = M.bounds(list, era)
  if from and to then
    return M.label(from, now) .. " – " .. M.label(to, now)
  elseif to then
    return "until " .. M.label(to, now)
  elseif from then
    return "since " .. M.label(from, now)
  end
  return ""
end

---Test/reload helper: forget what was read, so the next call re-reads the store.
function M.reset()
  marks = {}
  loaded = false
end

return M
