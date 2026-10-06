---@brief [[
--- Flags: a mark on a conversation that says "I still have to deal with this".
---
--- The list already has two states that sound like it and are not. `done` means
--- an answer arrived unread, and it is gone the moment the row is selected —
--- looking is not dealing. `waiting` lasts only while the CLI has a prompt on
--- screen. A flag is the one that survives being read: it stays on the row until
--- the conversation is answered, or until it is taken off by hand.
---
--- There are two kinds, told apart by whether the flag carries a note:
---
---   * a **bare** flag means "this needs a reply", and the next thing the user
---     says to the conversation ends it (`settle`). What counts as saying
---     something is the transcript's business — see `last_reply_ts` there.
---   * a flag **with a note** means whatever the note says — "review before
---     merging" — and nothing but the user removes it. A follow-up prompt is not
---     the review.
---
--- Kept per conversation and on disk, like checkpoints and for the same reason:
--- "I must come back to this" is a fact about the conversation, and it has to
--- outlive the view and Neovim or it is no reminder at all.
---
--- Unlike the checkpoint store, this one is **read again before every change**
--- and whenever the file moves underneath. One file holds every project's flags,
--- and a second Neovim on another project is the ordinary case: writing back a
--- copy read at startup would silently drop whatever the other one flagged since,
--- which is the one failure a reminder cannot have.
---@brief ]]
---@module 'claudecode.agents.flags'

local uv = vim.uv or vim.loop

local M = {}

--- Bumped when a persisted field changes meaning.
local STORE_VERSION = 1

---@class ClaudeCodeAgentsFlag
---@field at number Epoch seconds the flag started waiting for a reply.
---@field note string|nil What it is for. A flag with a note stays until removed.

--- `[session_id] = flag`. Empty until the store is read.
---@type table<string, ClaudeCodeAgentsFlag>
local flags = {}
local loaded = false
--- What the file looked like when it was last read or written, so a change made
--- by another Neovim can be told from our own.
---@type string|nil
local stamp = nil

--- Where the store lives, once that has been asked on the main loop (`M.path`).
---@type string|nil
local store_path = nil

---@param dir string
local function mkdir_p(dir)
  if dir == "" or uv.fs_stat(dir) then
    return
  end
  local parent = dir:match("^(.*)[/\\][^/\\]+$")
  if parent and parent ~= dir then
    mkdir_p(parent)
  end
  uv.fs_mkdir(dir, 493) -- 0755
end

---@param path string
---@param data string
---@return boolean written
local function write_file(path, data)
  local fd = uv.fs_open(path, "w", 420) -- 0644
  if not fd then
    return false
  end
  local written = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  return written == #data
end

--- The filesystem, as a seam for specs.
---
--- **libuv calls only, and that is load-bearing.** `settle` runs wherever a
--- transcript fold finishes, and a fold finishes in the callback of an
--- `uv.fs_read` — a fast context, where every `vim.fn` call raises `E5560`. The
--- first version read and wrote with `readfile`/`writefile`: the read threw
--- after the copy in memory had been emptied for it, the error was swallowed by
--- the fold's `pcall`, and a replied-to flag left the row while staying on disk
--- — with every *other* flag gone from memory too. Measured in a real Neovim;
--- the specs' fake filesystem has no fast context to fail in.
M._io = {
  ---@param path string
  ---@return string|nil data nil when the file cannot be read.
  read = function(path)
    local fd = uv and uv.fs_open and uv.fs_open(path, "r", 438)
    if not fd then
      return nil
    end
    local st = uv.fs_fstat(fd)
    local data = st and uv.fs_read(fd, st.size, 0) or nil
    uv.fs_close(fd)
    return data
  end,
  ---Replace the file in one step: a reader in another Neovim sees the old store
  ---or the new one, never the half of one that a truncate-then-write leaves.
  ---The temporary file is named for this process, so two editors writing at
  ---once do not write into each other's.
  ---@param path string
  ---@param data string
  ---@return boolean written
  write = function(path, data)
    if not (uv and uv.fs_open) then
      return false
    end
    mkdir_p(path:match("^(.*)[/\\][^/\\]*$") or "")
    local tmp = string.format("%s.%d.tmp", path, uv.os_getpid())
    if write_file(tmp, data) and uv.fs_rename(tmp, path) then
      return true
    end
    uv.fs_unlink(tmp)
    return write_file(path, data)
  end,
  ---@param path string
  ---@return string|nil stamp Size and mtime as one comparable value; nil when there is no file.
  stat = function(path)
    local st = uv and uv.fs_stat and uv.fs_stat(path)
    if not st then
      return nil
    end
    local mtime = st.mtime or {}
    return string.format("%d:%d.%d", st.size or 0, mtime.sec or 0, mtime.nsec or 0)
  end,
}

---Where the store lives.
---
---Resolved on first use and kept: `stdpath` is a `vim.fn` call, which a fast
---context may not make (see `_io`). The first use is the session list's own
---refresh, on the main loop and before any fold can finish; should a fold ever
---get here first, it is told there is no store yet rather than left to raise.
---@return string|nil path nil only when first asked from a fast context.
function M.path()
  if not store_path and not (vim.in_fast_event and vim.in_fast_event()) then
    store_path = vim.fn.stdpath("cache") .. "/claudecode/agents-flags.json"
  end
  return store_path
end

---What the store looks like on disk right now; nil when there is no file (or no
---path to look at yet).
---@return string|nil
local function disk_stamp()
  local path = M.path()
  return path and M._io.stat(path) or nil
end

---A note as it is kept: one line, no space around it, nil when nothing is left.
---@param note any
---@return string|nil
local function clean(note)
  if type(note) ~= "string" then
    return nil
  end
  local text = note:gsub("%s+", " ")
  text = text:gsub("^ ", "")
  text = text:gsub(" $", "")
  return text ~= "" and text or nil
end

---Read the store from disk into memory. A missing, corrupt or foreign file is an
---empty store.
---
---What is in memory is replaced only once the read has answered: a file that is
---there and cannot be read (too many open files, a permission glitch) keeps
---what was known, where emptying first and failing second would have the next
---change write an empty store over every flag.
---@return boolean read false when the file exists and could not be read.
local function read_store()
  local path = M.path()
  if not path then
    return false
  end
  -- Taken before the read: a write landing in between then shows as a change the
  -- next time anyone asks, rather than being stamped as already seen.
  local seen = M._io.stat(path)
  local data = M._io.read(path)
  if data == nil and seen ~= nil then
    return false
  end

  local fresh = {}
  local ok, decoded = pcall(vim.json.decode, data or "")
  if ok and type(decoded) == "table" and type(decoded.sessions) == "table" and decoded.version == STORE_VERSION then
    for id, record in pairs(decoded.sessions) do
      if type(id) == "string" and type(record) == "table" and type(record.at) == "number" and record.at > 0 then
        fresh[id] = { at = record.at, note = clean(record.note) }
      end
    end
  end
  flags, stamp, loaded = fresh, seen, true
  return true
end

local function load()
  if not loaded then
    read_store()
  end
end

local function save()
  local sessions = {}
  for id, flag in pairs(flags) do
    sessions[id] = { at = flag.at, note = flag.note }
  end
  local ok, encoded = pcall(vim.json.encode, { version = STORE_VERSION, sessions = sessions })
  local path = M.path()
  if ok and path and M._io.write(path, encoded) ~= false then
    stamp = M._io.stat(path)
  end
end

---Apply one change to the store as it is on disk *now*, and write it back.
---@param change fun(): boolean changed Whether anything is different; nothing is written otherwise.
---@return boolean changed false also when the store could not be read, in which case nothing is written over it.
local function mutate(change)
  if not read_store() or not change() then
    return false
  end
  save()
  return true
end

---@param flag ClaudeCodeAgentsFlag|nil
---@return ClaudeCodeAgentsFlag|nil
local function copy(flag)
  return flag and { at = flag.at, note = flag.note } or nil
end

---Take in what another Neovim wrote since the store was last read.
---
---One stat, so it is cheap enough for the list's own refresh tick; the file is
---only read again when it actually moved.
---@return boolean changed Whether the store was read again.
function M.refresh()
  if loaded and disk_stamp() == stamp then
    return false
  end
  return read_store()
end

---The flag on a conversation, as a copy; nil when it has none.
---@param session_id string|nil
---@return ClaudeCodeAgentsFlag|nil
function M.get(session_id)
  load()
  return copy(flags[session_id or ""])
end

---Every flag, by conversation id. A copy.
---@return table<string, ClaudeCodeAgentsFlag>
function M.all()
  load()
  local out = {}
  for id, flag in pairs(flags) do
    out[id] = copy(flag)
  end
  return out
end

---Whether a reply would take this conversation's flag off: it has one, and the
---flag carries no note.
---@param session_id string|nil
---@return boolean
function M.pending(session_id)
  load()
  local flag = flags[session_id or ""]
  return flag ~= nil and flag.note == nil
end

---Flag a conversation, or change what its flag says.
---
---With a note the flag stays until it is removed. Without one it waits for a
---reply, and the wait starts now — also when a note is being taken *off* a flag
---that had one: whatever was said to the conversation while the note held it does
---not count against a wait that had not begun.
---@param session_id string
---@param note string|nil
---@param now number|nil Epoch seconds; the clock by default.
---@return ClaudeCodeAgentsFlag|nil flag The flag as it now stands, nil when there was no conversation to put it on.
function M.set(session_id, note, now)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  note = clean(note)
  mutate(function()
    local existing = flags[session_id]
    if existing and existing.note == note then
      return false
    end
    flags[session_id] = { at = (note and existing and existing.at) or now or os.time(), note = note }
    return true
  end)
  return copy(flags[session_id])
end

---Take a conversation's flag off, note and all. Also what deleting the
---conversation does.
---@param session_id string
---@return boolean cleared false when it had none.
function M.clear(session_id)
  load()
  -- Asked for every deleted conversation and most have no flag: not worth a read.
  if type(session_id) ~= "string" or (flags[session_id] == nil and disk_stamp() == stamp) then
    return false
  end
  return mutate(function()
    if flags[session_id] == nil then
      return false
    end
    flags[session_id] = nil
    return true
  end)
end

---Flag an unflagged conversation, unflag a flagged one.
---@param session_id string
---@param now number|nil
---@return ClaudeCodeAgentsFlag|nil flag The new flag, or nil when one was taken off.
function M.toggle(session_id, now)
  load()
  if type(session_id) == "string" and flags[session_id] then
    M.clear(session_id)
    -- Still there when the store could not be read: the caller draws what holds.
    return copy(flags[session_id])
  end
  return M.set(session_id, nil, now)
end

---The user answered a conversation: end the wait, if its flag was waiting.
---
---Strictly later than the flag, because both clocks count whole seconds: a reply
---in the flag's own second was already on screen when the flag went up, and a
---flag kept a moment too long costs one keypress where one dropped too early
---costs the reminder.
---@param session_id string|nil
---@param reply_ts number|nil Epoch seconds of the newest thing the user said to it.
---@return boolean cleared
function M.settle(session_id, reply_ts)
  load()
  local id = session_id or ""
  local flag = flags[id]
  if not flag or flag.note ~= nil or type(reply_ts) ~= "number" or reply_ts <= flag.at then
    return false
  end
  return mutate(function()
    -- Read again inside: another Neovim may have given it a note meanwhile.
    local current = flags[id]
    if not current or current.note ~= nil or reply_ts <= current.at then
      return false
    end
    flags[id] = nil
    return true
  end)
end

---Test/reload helper: forget what was read, so the next call re-reads the store.
function M.reset()
  flags = {}
  loaded = false
  stamp = nil
end

return M
