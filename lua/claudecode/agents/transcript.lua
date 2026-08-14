---@brief [[
--- Reads the Claude CLI's own transcript store, which is the only place a past
--- conversation exists at all: `<CLAUDE_CONFIG_DIR|~/.claude>/projects/<slug>/<id>.jsonl`.
---
--- Agents mode needs three things out of it — a session's title, how many lines it
--- added and removed, and which files it touched — and needs them to stay accurate
--- while an agent is still working. The CLI records all three itself: every Edit and
--- Write tool result carries a `structuredPatch` (unified-diff hunks), and the file
--- is appended to live. So the counts here are not our own accounting of what we
--- watched happen; they are the CLI's record of what it did, which is what makes
--- them right even for a session that ran in another editor.
---
--- Entry shapes we care about, all on `type:"user"` lines except the titles:
---
---   {"type":"agent-name","agentName":"agents-mode-ui"}           -- user's rename
---   {"type":"ai-title","aiTitle":"Fix session restoration"}      -- last one wins
---   toolUseResult {filePath,oldString,newString,structuredPatch} -- Edit
---   toolUseResult {content,filePath,structuredPatch,type}        -- Write
---   toolUseResult {file={content,filePath,...},type="text"}      -- Read
---   toolUseResult {stdout,stderr,interrupted,...}                -- Bash (skipped)
---
--- Two things make this cheap enough to run on every tool call:
---
--- *Prefiltering.* Transcripts are large but mostly irrelevant — one 490KB file here
--- is 86 lines with a single 188KB line, and only 9 lines carry a `structuredPatch`.
--- Testing for the substrings before handing a line to `vim.json.decode` skips ~99%
--- of the bytes and every Bash result.
---
--- *Incrementality.* The log is append-only, so a byte offset is enough state to
--- re-read only what was added. `offset` is advanced only to the end of the last
--- *complete* line, so a scan that lands mid-line simply re-reads that line next
--- time — no partial-line state to carry, and the offset stays safe to persist.
--- Append-only is not guaranteed forever (compaction rewrites the file), so the
--- cache key is `(size, mtime, ino)` and a shrink or an inode change forces a full
--- reparse.
---
--- Nothing here blocks: reads go through `uv.fs_*` callbacks in bounded chunks, so
--- the editor stays responsive even on a 5MB transcript. Callers get their rows as
--- each session finishes rather than waiting for the slowest one.
---@brief ]]
---@module 'claudecode.agents.transcript'

local logger = require("claudecode.logger")
local tools = require("claudecode.agents.tools")

local uv = vim.uv or vim.loop

local M = {}

--- Bytes read per chunk. Each chunk is parsed in one go, so this bounds how long
--- the editor can be blocked by a single slice of work. Injectable so a spec can
--- exercise the multi-chunk paths without building megabyte fixtures.
M._chunk_size = 256 * 1024

--- How many activity events to keep per session. Trimming happens at twice this,
--- so the cost is amortized rather than a table shift per event.
local DEFAULT_EVENT_LIMIT = 500

--- What Claude Code writes into the conversation when the user cancels a turn.
--- Shared with `status`, which classifies it, and documented there: it is the
--- only report of an interrupt the CLI makes, since no hook fires for one.
--- `for tool use` is appended when a tool was running, hence the prefix match.
M.INTERRUPT_MARKER = "[Request interrupted by user"

--- What the CLI writes as the result of a call the user declined. An `is_error`
--- like any other as far as the JSON goes, but the agent did nothing wrong, so
--- the pane says so differently.
local REJECTION_MARKER = "The user doesn't want to proceed with this tool use"

--- Live summaries: [path] = ClaudeCodeAgentsSummary.
local cache = {}

--- In-flight scans: [path] = { cancelled, rerun, waiters }.
local inflight = {}

--- Agents config subtable (see config.lua defaults).
---@type table|nil
local config = nil

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

---@class ClaudeCodeAgentsEvent
---@field ts number Epoch seconds (0 when the entry carried no timestamp).
---@field kind "read"|"add"|"edit"|"tool" What the agent did. `tool` is a call that touched no file.
---@field path string|nil Absolute path as the CLI recorded it; nil on a `tool` event.
---@field added integer
---@field removed integer
---@field start_line integer|nil First line of a read (the CLI records the window it read).
---@field num_lines integer|nil How many lines that read covered.
---@field tool string|nil `tool` events: the tool's own name, e.g. `Bash`.
---@field label string|nil `tool` events: one line naming what the call was for.
---@field tool_id string|nil `tool` events: the `toolu_…` id its result is joined by.
---@field status "running"|"done"|"error"|"interrupted"|"rejected"|nil `tool` events; see `resolve_tool`.

---@class ClaudeCodeAgentsFileHistory What one session did to one file.
---@field path string The file.
---@field hunks table[] Every `structuredPatch` hunk for it, oldest edit first.
---@field created boolean The session created the file (its first touch was a write with no patch).
---@field reads { start_line: integer, num_lines: integer, ts: number }[]
---@field content string|nil Content of the last `Write`, when the session wrote the whole file.
---@field last_ts number

---@class ClaudeCodeAgentsFile
---@field added integer
---@field removed integer
---@field kind "read"|"add"|"edit" Last thing that happened to it.
---@field last_ts number

---@class ClaudeCodeAgentsSummary
---@field id string Session uuid (the file's basename).
---@field path string Absolute path of the transcript.
---@field name string|nil The name the user renamed the session to (`agent-name`).
---@field title string|nil The CLI's own generated `ai-title`.
---@field first_prompt string|nil Fallback title: the first user message.
---@field cwd string|nil Directory the session ran in.
---@field git_branch string|nil
---@field added integer
---@field removed integer
---@field files table<string, ClaudeCodeAgentsFile>
---@field order string[] Touched paths in first-touch order.
---@field events ClaudeCodeAgentsEvent[] Oldest first; trimmed to the event limit.
---@field pending table<string, ClaudeCodeAgentsEvent> Tool events whose result has not been folded yet, by tool_use id.
---@field last_ts number Epoch seconds of the last entry carrying a timestamp.
---@field interrupted_ts number|nil Set when the CLI recorded a user interrupt; see INTERRUPT_MARKER.
---@field size integer Bytes of the file when last folded.
---@field mtime integer
---@field ino integer|nil
---@field offset integer Bytes consumed, always a line boundary.
---@field skipped integer Lines that decoded but matched no known shape.
---@field partial boolean|nil Counts came from the warm cache; no fold state yet.

--------------------------------------------------------------------------------
-- I/O seam
--------------------------------------------------------------------------------

--- Injectable I/O so specs can drive the parser without a real event loop or
--- filesystem. Production implementations use libuv directly.
M._io = {
  ---@param path string
  ---@return { size: integer, mtime: integer, ino: integer|nil }|nil
  stat = function(path)
    local st = uv and uv.fs_stat(path)
    if not st then
      return nil
    end
    return {
      size = st.size,
      mtime = type(st.mtime) == "table" and st.mtime.sec or st.mtime,
      ino = st.ino,
    }
  end,

  ---@param dir string
  ---@return string[]|nil names Entry names, or nil when the directory is unreadable.
  scandir = function(dir)
    local handle = uv and uv.fs_scandir(dir)
    if not handle then
      return nil
    end
    local names = {}
    while true do
      local name = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      names[#names + 1] = name
    end
    return names
  end,

  ---Remove a file, or a directory and everything under it.
  ---@param path string
  ---@return boolean ok
  remove = function(path)
    -- `vim.fn.delete` takes both a file and a tree, which is what this needs: a
    -- session is a `.jsonl` plus an optional directory of tool results.
    return vim.fn.delete(path, "rf") == 0
  end,

  ---Read `len` bytes from `offset`, calling back with the data (never blocking).
  ---@param path string
  ---@param offset integer
  ---@param len integer
  ---@param cb fun(data: string|nil, err: string|nil)
  read = function(path, offset, len, cb)
    if not uv then
      cb(nil, "no libuv")
      return
    end
    uv.fs_open(path, "r", 438, function(open_err, fd)
      if open_err or not fd then
        cb(nil, open_err or "open failed")
        return
      end
      uv.fs_read(fd, len, offset, function(read_err, data)
        uv.fs_close(fd, function() end)
        if read_err then
          cb(nil, read_err)
          return
        end
        cb(data or "", nil)
      end)
    end)
  end,

  ---Read the first `len` bytes of a file, blocking.
  ---
  ---The one place that needs this is `_dir_matches_cwd`, which runs only when the
  ---slug did not name a directory — a rare path where a bounded synchronous read
  ---is cheaper than making the whole lookup asynchronous. It has to be
  ---synchronous: the probe answers `project_dir`, whose callers use the result in
  ---the same tick.
  ---@param path string
  ---@param len integer
  ---@return string|nil
  read_sync = function(path, len)
    if not uv then
      return nil
    end
    local fd = uv.fs_open(path, "r", 438)
    if not fd then
      return nil
    end
    local data = uv.fs_read(fd, len, 0)
    uv.fs_close(fd)
    return data
  end,
}

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

---@return string dir The Claude CLI's config directory.
function M.config_dir()
  return require("claudecode.utils").claude_config_dir()
end

--- Where the CLI cuts a slug and appends a hash instead. Read out of the shipped
--- binary (2.1.222) rather than guessed: `if (t.length <= 200) return t; return
--- t.slice(0, 200) + "-" + hash`.
local SLUG_MAX = 200

---Call `fn` with each UTF-16 code unit of a UTF-8 string.
---
---Both halves of the slug rule are JavaScript operating on a JS string, and a JS
---string is a sequence of UTF-16 code units: `replace(/[^a-zA-Z0-9]/g, "-")`
---without the `u` flag substitutes one dash *per unit*, and `charCodeAt` in the
---hash reads one unit at a time. Iterating Lua's bytes instead would give a
---two-byte `ö` two dashes where the CLI gives it one — so a project path with a
---non-ASCII character would resolve to a directory that does not exist.
---@param str string
---@param fn fun(unit: integer)
local function each_utf16_unit(str, fn)
  local i, n = 1, #str
  while i <= n do
    local byte = str:byte(i)
    local cp, len
    if byte < 0x80 then
      cp, len = byte, 1
    elseif byte < 0xC0 then
      cp, len = byte, 1 -- stray continuation byte: pass it through as itself
    elseif byte < 0xE0 then
      cp, len = byte - 0xC0, 2
    elseif byte < 0xF0 then
      cp, len = byte - 0xE0, 3
    else
      cp, len = byte - 0xF0, 4
    end

    for k = 1, len - 1 do
      local cont = str:byte(i + k)
      if not cont or cont < 0x80 or cont > 0xBF then
        cp, len = byte, 1 -- malformed sequence: treat the lead byte as the value
        break
      end
      cp = cp * 64 + (cont - 0x80)
    end

    if cp > 0xFFFF then
      -- Outside the BMP, JS sees a surrogate pair: two units, two dashes.
      local rest = cp - 0x10000
      fn(0xD800 + math.floor(rest / 0x400))
      fn(0xDC00 + rest % 0x400)
    else
      fn(cp)
    end
    i = i + len
  end
end

---@param n integer
---@return string
local function to_base36(n)
  if n == 0 then
    return "0"
  end
  local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  local out = {}
  while n > 0 do
    local rest = n % 36
    out[#out + 1] = digits:sub(rest + 1, rest + 1)
    n = math.floor(n / 36)
  end
  return string.reverse(table.concat(out))
end

---The CLI's directory name for a project: the absolute path with every
---non-alphanumeric character replaced by a dash (`/a/b.c` -> `-a-b-c`), and, when
---that runs past 200 characters, cut there with a hash of the whole path appended
---so two long paths sharing a prefix stay apart.
---
---The rule is undocumented. Both halves are the CLI's own, transcribed from the
---binary: the hash is `h = h * 31 + unit` over the path's UTF-16 code units, kept
---to a signed 32-bit int, then `Math.abs(h).toString(36)`. `project_dir` verifies
---the result rather than trusting it, so a change to the rule costs a slower
---lookup rather than an empty session list.
---@param abs_path string
---@return string
function M.slugify(abs_path)
  local chars, hash = {}, 0
  each_utf16_unit(abs_path, function(unit)
    local alnum = (unit >= 48 and unit <= 57) or (unit >= 65 and unit <= 90) or (unit >= 97 and unit <= 122)
    chars[#chars + 1] = alnum and string.char(unit) or "-"
    -- Wrapping at 2^32 each step is the same arithmetic as JS's `|0` per step,
    -- and keeps the running value inside a double's exact integer range.
    hash = (hash * 31 + unit) % 0x100000000
  end)

  local slug = table.concat(chars)
  if #slug <= SLUG_MAX then
    return slug
  end
  if hash >= 0x80000000 then
    hash = hash - 0x100000000
  end
  return slug:sub(1, SLUG_MAX) .. "-" .. to_base36(math.abs(hash))
end

---Strip a trailing separator, without eating a path that is only a root.
---
---`fnamemodify(cwd, ":p")` appends one, and the CLI slugifies a path that has
---none: on Windows that difference is the whole feature, since `D:\Git\proj\`
---slugifies to `D--Git-proj-` and the CLI's directory is `D--Git-proj`.
---@param path string
---@return string
function M._trim_separator(path)
  local trimmed = path:gsub("[/\\]+$", "")
  if trimmed == "" or trimmed:match("^%a:$") then
    return path
  end
  return trimmed
end

---Locate the transcript directory for a project.
---
---Tries the slug first — for the path as given and, if that misses, for its
---realpath, since the CLI resolves symlinks before slugifying and Neovim's cwd
---does not — and falls back to scanning every project directory for a transcript
---whose entries name this cwd, so a change to the CLI's naming rule costs a
---slower lookup rather than an empty session list.
---@param cwd string
---@return string|nil dir
function M.project_dir(cwd)
  local root = M.config_dir() .. "/projects"
  if vim.fn.isdirectory(root) ~= 1 then
    return nil
  end

  local target = M._trim_separator(vim.fn.fnamemodify(cwd, ":p"))
  local targets = { target }
  local real = uv and uv.fs_realpath and uv.fs_realpath(target)
  if type(real) == "string" then
    real = M._trim_separator(real)
    if real ~= target then
      targets[#targets + 1] = real
    end
  end

  for _, candidate in ipairs(targets) do
    local guess = root .. "/" .. M.slugify(candidate)
    if vim.fn.isdirectory(guess) == 1 then
      return guess
    end
  end

  local names = M._io.scandir(root)
  if not names then
    return nil
  end
  for _, name in ipairs(names) do
    local dir = root .. "/" .. name
    if vim.fn.isdirectory(dir) == 1 then
      for _, candidate in ipairs(targets) do
        if M._dir_matches_cwd(dir, candidate) then
          return dir
        end
      end
    end
  end
  return nil
end

---Where a conversation's transcript will live, whether or not it exists yet.
---
---`project_dir` answers only for a directory that is already there, and the one
---conversation that has to be named before it exists is the new one — in a
---project the CLI may never have run in at all, where that directory is created
---by the very session being named. So the slug rule is applied directly when the
---lookup comes up empty. A guess that turns out wrong costs one `stat` that
---fails, and the next enumeration replaces it with the path on disk.
---@param cwd string
---@param session_id string
---@return string path
function M.session_path(cwd, session_id)
  local dir = M.project_dir(cwd)
  if not dir then
    local target = M._trim_separator(vim.fn.fnamemodify(cwd, ":p"))
    local real = uv and uv.fs_realpath and uv.fs_realpath(target)
    if type(real) == "string" then
      target = M._trim_separator(real)
    end
    dir = M.config_dir() .. "/projects/" .. M.slugify(target)
  end
  return dir .. "/" .. session_id .. ".jsonl"
end

---Whether any transcript in `dir` reports `target` as its cwd. Reads only the
---head of one file, since every message entry carries the same cwd.
---
---Blocking, through `read_sync`: this is the answer `project_dir` returns, and an
---earlier version asked the asynchronous reader and treated "has not answered
---yet" as "no match" — which the real reader never does answer in time, so the
---fallback could not fire at all and a slug miss was always an empty session
---list.
---@param dir string
---@param target string
---@return boolean
function M._dir_matches_cwd(dir, target)
  -- The transcript is JSON, so a Windows path is written with its separators
  -- escaped (`D:\\Git\\proj`); the cwd we are matching has them raw.
  local needles = { '"cwd":"' .. target .. '"' }
  local escaped = target:gsub("\\", "\\\\")
  if escaped ~= target then
    needles[#needles + 1] = '"cwd":"' .. escaped .. '"'
  end

  -- Windows spells one directory more than one way (`D:\Git` / `d:\git`), and the
  -- CLI recorded whichever its own shell handed it.
  local fold = require("claudecode.utils").is_windows()
  if fold then
    for index, needle in ipairs(needles) do
      needles[index] = needle:lower()
    end
  end

  local read_sync = M._io.read_sync
  if type(read_sync) ~= "function" then
    return false
  end

  local names = M._io.scandir(dir) or {}
  for _, name in ipairs(names) do
    if name:sub(-6) == ".jsonl" then
      -- Match the raw bytes rather than decoding: this runs once per candidate
      -- directory and only needs a yes/no.
      local data = read_sync(dir .. "/" .. name, 64 * 1024)
      if type(data) == "string" then
        if fold then
          data = data:lower()
        end
        for _, needle in ipairs(needles) do
          if data:find(needle, 1, true) then
            return true
          end
        end
      end
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Parsing helpers
--------------------------------------------------------------------------------

---Convert an ISO-8601 UTC timestamp to epoch seconds.
---
---Computed rather than handed to `os.time`, which interprets its fields as local
---time and would shift every event by the machine's offset.
---@param iso string|nil
---@return number epoch 0 when unparseable.
function M._iso_to_epoch(iso)
  if type(iso) ~= "string" then
    return 0
  end
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return 0
  end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  -- Days from civil (Howard Hinnant's algorithm): era-based, no lookup tables.
  local yy = y - (mo <= 2 and 1 or 0)
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end

---Count added and removed lines across `structuredPatch` hunks.
---@param hunks table|nil
---@return integer added, integer removed
function M._count_patch(hunks)
  local added, removed = 0, 0
  if type(hunks) ~= "table" then
    return added, removed
  end
  for _, hunk in ipairs(hunks) do
    local lines = type(hunk) == "table" and hunk.lines
    if type(lines) == "table" then
      for _, line in ipairs(lines) do
        if type(line) == "string" then
          local first = line:byte(1)
          if first == 43 then -- '+'
            added = added + 1
          elseif first == 45 then -- '-'
            removed = removed + 1
          end
        end
      end
    end
  end
  return added, removed
end

---@param text string|nil
---@return integer count Lines in `text`, counting a missing trailing newline.
local function count_lines(text)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  local _, newlines = text:gsub("\n", "")
  return text:sub(-1) == "\n" and newlines or newlines + 1
end

---@param sum ClaudeCodeAgentsSummary
---@param event ClaudeCodeAgentsEvent
local function push_event(sum, event)
  sum.events[#sum.events + 1] = event
  local limit = (config and config.feed_limit) or DEFAULT_EVENT_LIMIT
  -- Trim at twice the limit so this is a rare rebuild rather than a shift per event.
  if #sum.events > limit * 2 then
    local keep = {}
    for i = #sum.events - limit + 1, #sum.events do
      keep[#keep + 1] = sum.events[i]
    end
    sum.events = keep
  end
end

---@param sum ClaudeCodeAgentsSummary
---@param path string
---@param kind "read"|"add"|"edit"
---@param added integer
---@param removed integer
---@param ts number
local function touch_file(sum, path, kind, added, removed, ts)
  local entry = sum.files[path]
  if not entry then
    entry = { added = 0, removed = 0, kind = kind, last_ts = ts }
    sum.files[path] = entry
    sum.order[#sum.order + 1] = path
  end
  entry.added = entry.added + added
  entry.removed = entry.removed + removed
  entry.last_ts = ts
  -- A read after an edit must not downgrade the file to "read": the marker is
  -- about what the session did to it, and an edit is the stronger claim.
  if kind ~= "read" or entry.kind == "read" then
    entry.kind = kind
  end
end

---Whether the Activity pane wants rows for tool calls at all.
---
---Read per line rather than captured once: `setup` can replace the config while a
---scan is in flight, and folding half a transcript one way and half the other
---would leave a session's feed half populated.
---@return boolean
local function tools_wanted()
  return not config or config.feed_tools ~= false
end

---Fold the tool calls an assistant entry made.
---
---A call and its result are two entries, joined by the `toolu_…` id: the call
---carries what was run, the result what came back. The row is built from the call,
---so it appears the moment the agent starts a command rather than when it
---finishes — which is the question the pane answers, and the reason a `Bash` that
---has not returned yet can be shown as still running at all.
---
---File tools are skipped: their results already produce rows, and a second one for
---the call would say the same thing twice.
---@param sum ClaudeCodeAgentsSummary
---@param entry table Decoded transcript line.
---@return boolean handled
local function fold_tool_use(sum, entry)
  local message = entry.message
  local content = type(message) == "table" and message.content or nil
  if type(content) ~= "table" then
    return false
  end
  local ts = M._iso_to_epoch(entry.timestamp)
  if ts > sum.last_ts then
    sum.last_ts = ts
  end

  local handled = false
  for _, block in ipairs(content) do
    if
      type(block) == "table"
      and block.type == "tool_use"
      and type(block.name) == "string"
      and not tools.FILE_TOOLS[block.name]
    then
      handled = true
      local event = {
        ts = ts,
        kind = "tool",
        tool = block.name,
        label = tools.label(block.name, block.input),
        tool_id = type(block.id) == "string" and block.id or nil,
        -- Nothing has come back yet, by construction: the result is a later line.
        status = "running",
        added = 0,
        removed = 0,
      }
      push_event(sum, event)
      if event.tool_id then
        sum.pending[event.tool_id] = event
      end
    end
  end
  return handled
end

---Mark the call a result belongs to as finished, from the raw line alone.
---
---Read by substring rather than decoded, which is the whole reason a `Bash` result
---can be folded at all: these lines carry the command's entire output — up to the
---CLI's own cap — and handing one to `vim.json.decode` on every scan is exactly
---what the prefilter exists to avoid. What is needed here is three bits, and each
---is a fixed string.
---
---**Failure is `is_error`, not stderr.** Measured across this project's store, one
---session has 3 `is_error` results out of 340 and 55 with something on stderr —
---the usual `git`/`rg` progress and warnings from commands that succeeded. Calling
---those failures would paint most of the pane red and mean nothing. `is_error` is
---the CLI's own verdict and covers what a reader means by failed: a non-zero exit
---(`Error: Exit code 1…`), a patch that did not apply, a blocked command.
---
---**A refusal is not a failure**, and it is common enough to tell apart: 32 of the
---379 `is_error` results across this store are the user declining the call. Those
---are the one thing in the pane the agent did not do wrong.
---@param sum ClaudeCodeAgentsSummary
---@param line string
local function resolve_tool(sum, line)
  local at = line:find('"tool_use_id":"', 1, true)
  if not at then
    return
  end
  local id = line:match('^"tool_use_id":"([^"]+)"', at)
  local event = id and sum.pending[id]
  if not event then
    return
  end
  sum.pending[id] = nil
  if not line:find('"is_error":true', 1, true) then
    -- `"interrupted":true` is on the Bash result shape, and is worth nothing:
    -- across 25 real transcripts here it is `false` every single time. A turn the
    -- user stopped is reported by the interrupt marker instead, which is what
    -- `_fold_line` resolves the calls still outstanding from.
    event.status = "done"
  elseif line:find(REJECTION_MARKER, 1, true) then
    event.status = "rejected"
  else
    event.status = "error"
  end
end

---Fold one decoded `toolUseResult` entry into the summary.
---@param sum ClaudeCodeAgentsSummary
---@param entry table Decoded transcript line.
---@return boolean handled
local function fold_result(sum, entry)
  local result = entry.toolUseResult
  if type(result) ~= "table" then
    return false
  end
  local ts = M._iso_to_epoch(entry.timestamp)
  if ts > sum.last_ts then
    sum.last_ts = ts
  end

  -- Read: the file object carries the path; the content is ignored. The window it
  -- read is not — that is what lets the view highlight the lines the agent looked
  -- at, the way the live cursor does while it happens.
  if type(result.file) == "table" and type(result.file.filePath) == "string" then
    touch_file(sum, result.file.filePath, "read", 0, 0, ts)
    push_event(sum, {
      ts = ts,
      kind = "read",
      path = result.file.filePath,
      added = 0,
      removed = 0,
      start_line = tonumber(result.file.startLine),
      num_lines = tonumber(result.file.numLines),
    })
    return true
  end

  if type(result.filePath) ~= "string" then
    return false
  end

  local added, removed = M._count_patch(result.structuredPatch)
  -- A Write that creates a file records an empty patch — there is no "before" to
  -- diff against — so the whole content is the addition. Without this every new
  -- file an agent writes would read as +0.
  local created = result.type == "create"
  if added == 0 and removed == 0 and type(result.content) == "string" then
    added = count_lines(result.content)
    created = true
  end

  local kind = created and "add" or "edit"
  touch_file(sum, result.filePath, kind, added, removed, ts)
  sum.added = sum.added + added
  sum.removed = sum.removed + removed
  push_event(sum, { ts = ts, kind = kind, path = result.filePath, added = added, removed = removed })
  return true
end

--- A real marker entry is tiny (647 bytes, measured on the one real interrupt in
--- this repo's store). The gate is a cost bound, not the test: it keeps the
--- promise that a huge Bash result is never handed to the decoder.
local INTERRUPT_LINE_LIMIT = 4096

--- The marker text itself is short; anything longer that merely begins with it is
--- not the CLI's entry.
local INTERRUPT_TEXT_LIMIT = 80

---Whether a line is the CLI's own record that the user cancelled a turn.
---
---A substring match is **not enough**, and the false positive is not theoretical:
---`toolUseResult` entries are `type:"user"` too, so any conversation whose tool
---output quotes the marker — a transcript of writing this code does — matched
---both `"type":"user"` and the marker and read as cancelled. So the entry is
---decoded and checked structurally: the CLI writes the marker as the *whole*
---message content, where a quoting tool result has it buried in a longer text.
---@param line string
---@return boolean
function M._is_interrupt_line(line)
  if #line > INTERRUPT_LINE_LIMIT or not line:find(M.INTERRUPT_MARKER, 1, true) then
    return false
  end
  local ok, entry = pcall(vim.json.decode, line)
  if not ok or type(entry) ~= "table" or entry.type ~= "user" then
    return false
  end

  local function is_marker(text)
    return type(text) == "string"
      and #text <= INTERRUPT_TEXT_LIMIT
      and text:sub(1, #M.INTERRUPT_MARKER) == M.INTERRUPT_MARKER
  end

  local content = type(entry.message) == "table" and entry.message.content or nil
  if type(content) == "string" then
    return is_marker(content)
  end
  if type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "table" and is_marker(block.text) then
        return true
      end
    end
  end
  return false
end

---Fold one raw line. Prefilters on substrings so most lines are never decoded.
---@param sum ClaudeCodeAgentsSummary
---@param line string
function M._fold_line(sum, line)
  if #line == 0 then
    return
  end

  -- When the session was last *alive*, from any entry that carries a timestamp
  -- rather than only the tool results we decode. Two reasons this cannot be left
  -- to the events: a conversation that only ran Bash produces no events at all
  -- and would date from 1970 (measured — one real session here), and the CLI
  -- appends untimestamped bookkeeping (`last-prompt`) days after the last
  -- message, so the file's mtime is not the answer either (7 days out on one
  -- transcript here, 30 hours on another). Matched, not decoded: this is a scan
  -- over bytes already in hand, and stays clear of the JSON decoder the
  -- prefilter exists to avoid.
  local at = line:find('"timestamp":"', 1, true)
  if at then
    local ts = M._iso_to_epoch(line:sub(at + 13, at + 40))
    if ts > sum.last_ts then
      sum.last_ts = ts
    end
  end

  -- The user cancelled a turn with `<Esc>`. This marker is the **only** report
  -- of that there is: measured against the real CLI (2.1.221) by driving an
  -- interactive session through a pty with a hook registered on every event
  -- Claude Code defines, an interrupt fires none of them — not `Stop`, not the
  -- `StopFailure` the binary also carries — so a conversation that was
  -- interrupted stayed `busy` for ever and its row span on. The CLI writes this
  -- into the conversation as a real `user` entry instead, which is a signal from
  -- Claude rather than a guess about a keypress; `for tool use` is appended when
  -- a tool was running, hence the prefix. Matched, not decoded, like the
  -- timestamp above.
  if M._is_interrupt_line(line) then
    -- `last_ts` was updated from this very line a few lines above, so this is
    -- the marker's own timestamp. **A real epoch, not a counter**: the consumer
    -- compares it against when the conversation's current turn started, and an
    -- interrupt that predates that turn says nothing about it. A synthetic
    -- "newer than the last one" value would break that comparison.
    sum.interrupted_ts = sum.last_ts
    -- Every call still waiting for a result was cut off by this: the turn ended
    -- and nothing will answer them now. Without this an interrupted `Bash` keeps
    -- its "still running" marker for the rest of the conversation — which is the
    -- one thing in the pane that would be a lie rather than merely stale.
    for id, event in pairs(sum.pending) do
      event.status = "interrupted"
      sum.pending[id] = nil
    end
    return
  end

  if line:find('"aiTitle"', 1, true) then
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and type(entry.aiTitle) == "string" then
      sum.title = entry.aiTitle -- repeated through the file; the last one is current
    end
    return
  end

  -- Renaming a session writes its own entry, and only sometimes also rewrites the
  -- generated `aiTitle` (4 of 22 renamed transcripts here did) — so the user's name
  -- has to be read on its own or most renames stay invisible. Repeated like the
  -- title, and a session can be renamed more than once, so the last one is current.
  if line:find('"agentName"', 1, true) then
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and type(entry.agentName) == "string" and entry.agentName ~= "" then
      sum.name = entry.agentName
    end
    return
  end

  -- The tool calls themselves, which is where a shell command, a search or a
  -- subagent launch is recorded — none of them produce a `filePath`, so before
  -- this the pane could not see them at all. Prefiltered like everything else, and
  -- cheap in a way worth stating: measured on this project's largest transcript
  -- (11.9MB, 2628 lines), 451 lines carry a `tool_use` block, 1.26MB in total,
  -- 20ms to decode all of them once.
  if tools_wanted() and line:find('"type":"tool_use"', 1, true) then
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" then
      pcall(fold_tool_use, sum, entry)
    end
    return
  end

  -- Bash results carry neither a patch nor a `file` object, which is what keeps
  -- their (often huge) stdout out of the decoder.
  if line:find('"toolUseResult"', 1, true) then
    -- Which call this answers, and how it went: three substring tests on a line
    -- that is never decoded (see `resolve_tool`).
    if tools_wanted() then
      resolve_tool(sum, line)
    end
    if line:find('"structuredPatch"', 1, true) or line:find('"file":', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == "table" then
        if not fold_result(sum, entry) then
          sum.skipped = sum.skipped + 1
        end
      else
        sum.skipped = sum.skipped + 1
      end
    end
    return
  end

  -- The first user message is the fallback title, and the cheapest place to learn
  -- the session's cwd and branch. Only tested until both are known.
  if (not sum.first_prompt or not sum.cwd) and line:find('"type":"user"', 1, true) then
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
      return
    end
    if not sum.cwd and type(entry.cwd) == "string" then
      sum.cwd = entry.cwd
      sum.git_branch = type(entry.gitBranch) == "string" and entry.gitBranch or nil
    end
    if not sum.first_prompt then
      local content = entry.message and entry.message.content
      local text
      if type(content) == "string" then
        text = content
      elseif type(content) == "table" and type(content[1]) == "table" then
        text = content[1].text
      end
      if type(text) == "string" and text ~= "" and not text:find("^<") then
        sum.first_prompt = text:gsub("%s+", " "):sub(1, 200)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Summaries
--------------------------------------------------------------------------------

---@param path string
---@return ClaudeCodeAgentsSummary
local function new_summary(path)
  return {
    -- Matched rather than `fnamemodify(path, ":t:r")` so a Windows separator is
    -- handled too; the id is the file's basename minus the .jsonl suffix.
    id = path:match("([^/\\]+)%.jsonl$") or path,
    path = path,
    added = 0,
    removed = 0,
    files = {},
    order = {},
    events = {},
    pending = {},
    last_ts = 0,
    size = 0,
    mtime = 0,
    offset = 0,
    skipped = 0,
  }
end

---Whether `sum` is still a valid basis for an incremental read of `st`.
---@param sum ClaudeCodeAgentsSummary|nil
---@param st table
---@return boolean
local function can_extend(sum, st)
  if not sum or sum.partial then
    return false
  end
  -- A shrink means the file was rewritten; a new inode means it was replaced.
  -- Either way the offset points into different content than we folded.
  if st.size < sum.size then
    return false
  end
  if sum.ino and st.ino and sum.ino ~= st.ino then
    return false
  end
  return true
end

---Read and fold from `sum.offset` to the end of the file, one chunk at a time.
---@param sum ClaudeCodeAgentsSummary
---@param st table
---@param job table
---@param done fun()
local function fold_chunks(sum, st, job, done)
  local function step()
    if job.cancelled then
      done()
      return
    end
    if sum.offset >= st.size then
      done()
      return
    end
    local want = math.min(M._chunk_size, st.size - sum.offset)
    M._io.read(sum.path, sum.offset, want, function(data, err)
      if job.cancelled then
        done()
        return
      end
      if not data or data == "" then
        if err then
          logger.debug("agents", "read failed for", sum.path, tostring(err))
        end
        done()
        return
      end

      local consumed = 0
      local start = 1
      while true do
        local nl = data:find("\n", start, true)
        if not nl then
          break
        end
        local ok, fold_err = pcall(M._fold_line, sum, data:sub(start, nl - 1))
        if not ok then
          sum.skipped = sum.skipped + 1
          logger.debug("agents", "fold error in", sum.path, tostring(fold_err))
        end
        consumed = nl
        start = nl + 1
      end

      if consumed == 0 then
        -- No line boundary in a whole chunk: the line is longer than CHUNK, so
        -- pull the rest of it in one read rather than spinning on the same bytes.
        local rest = st.size - sum.offset
        if rest <= want then
          done()
          return
        end
        M._io.read(sum.path, sum.offset, rest, function(all)
          if job.cancelled or not all then
            done()
            return
          end
          local last = 0
          local from = 1
          while true do
            local nl = all:find("\n", from, true)
            if not nl then
              break
            end
            pcall(M._fold_line, sum, all:sub(from, nl - 1))
            last = nl
            from = nl + 1
          end
          sum.offset = sum.offset + last
          done()
        end)
        return
      end

      sum.offset = sum.offset + consumed
      -- Each chunk returns through the event loop, so the editor gets a turn
      -- between slices no matter how large the transcript is.
      step()
    end)
  end
  step()
end

---Fold a transcript up to date, calling back with its summary.
---
---Returns the cached summary in the same tick when nothing changed. Concurrent
---calls for one path share a single scan; a call arriving mid-scan queues a rerun
---so a burst of tool events cannot pile up reads.
---@param path string
---@param cb fun(summary: ClaudeCodeAgentsSummary|nil)
function M.summary(path, cb)
  local st = M._io.stat(path)
  if not st then
    cache[path] = nil
    cb(nil)
    return
  end

  local sum = cache[path]
  if sum and not sum.partial and sum.size == st.size and sum.mtime == st.mtime then
    cb(sum)
    return
  end

  local job = inflight[path]
  if job then
    job.rerun = true
    job.waiters[#job.waiters + 1] = cb
    return
  end

  job = { waiters = { cb } }
  inflight[path] = job

  if not can_extend(sum, st) then
    sum = new_summary(path)
    cache[path] = sum
  end

  local function finish()
    sum.size = st.size
    sum.mtime = st.mtime
    sum.ino = st.ino
    sum.partial = nil
    inflight[path] = nil
    local waiters = job.waiters
    if job.rerun and not job.cancelled then
      -- The file grew while we were reading it; fold the remainder before
      -- answering, so no caller is ever handed knowingly stale counts.
      M.summary(path, function(fresh)
        for _, waiter in ipairs(waiters) do
          pcall(waiter, fresh)
        end
      end)
      return
    end
    for _, waiter in ipairs(waiters) do
      pcall(waiter, sum)
    end
  end

  fold_chunks(sum, st, job, finish)
end

---Enumerate a project's transcripts, newest first.
---
---Stat-only and therefore synchronous: no file is opened, so this is a handful of
---syscalls even for a project with a hundred sessions. Rows carry whatever the
---cache already knows, so a caller can paint real numbers before any fold runs.
---@param cwd string
---@return { id: string, path: string, size: integer, mtime: integer, summary: ClaudeCodeAgentsSummary|nil }[]
function M.list(cwd)
  local dir = M.project_dir(cwd)
  if not dir then
    return {}
  end
  local names = M._io.scandir(dir) or {}
  local rows = {}
  for _, name in ipairs(names) do
    if name:sub(-6) == ".jsonl" then
      local path = dir .. "/" .. name
      local st = M._io.stat(path)
      if st then
        rows[#rows + 1] = {
          id = name:sub(1, -7),
          path = path,
          size = st.size,
          mtime = st.mtime,
          summary = cache[path],
        }
      end
    end
  end
  table.sort(rows, function(a, b)
    return a.mtime > b.mtime
  end)
  return rows
end

---The cached summary for a path, if one has been folded.
---@param path string
---@return ClaudeCodeAgentsSummary|nil
function M.get(path)
  return cache[path]
end

---Activity events for a session, oldest first.
---@param path string
---@return ClaudeCodeAgentsEvent[]
function M.events(path)
  local sum = cache[path]
  return sum and sum.events or {}
end

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

--- Lines above this are not searched. A transcript's bulk is tool output — one
--- real 490KB file here is a single 188KB line — and tool results are not what a
--- search of the conversation means, so the cap is a promise that a keystroke
--- never hands the decoder a file's worth of Bash output.
local SEARCH_LINE_LIMIT = 256 * 1024

--- How much of a matching line a result row shows, in bytes.
local SNIPPET_WIDTH = 88

local ELLIPSIS = "…"

---Compile a query into something that can be run against a string.
---
---Smartcase, and **literal**: the query is matched verbatim, so a `.` or a `-` in
---a path behaves the way it looks. Case-insensitivity is compiled into a Lua
---pattern (`[aA]`) rather than done by lowering the haystack, because the haystack
---here is every line of every transcript and a lowered copy of each is an
---allocation per line for nothing.
---@param query string
---@return { query: string, plain: boolean, find: fun(hay: string, init: integer|nil): integer|nil, integer|nil }|nil
function M.compile_query(query)
  if type(query) ~= "string" or query == "" then
    return nil
  end
  -- The user typing a capital is the user asking for case to matter.
  local plain = query:find("%u") ~= nil
  local pattern = nil
  if not plain then
    pattern = query:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%a", function(char)
      return "[" .. char:lower() .. char:upper() .. "]"
    end)
  end
  return {
    query = query,
    plain = plain,
    find = function(hay, init)
      if plain then
        return hay:find(query, init, true)
      end
      return hay:find(pattern, init)
    end,
  }
end

---Back up `at` to the start of the UTF-8 sequence it lands in.
---@param text string
---@param at integer 1-based byte index.
---@return integer
local function utf8_floor(text, at)
  while at > 1 and at <= #text do
    local byte = text:byte(at)
    if not byte or byte < 0x80 or byte >= 0xC0 then
      break
    end
    at = at - 1
  end
  return at
end

---Drop a trailing partial UTF-8 sequence, so a windowed snippet is still text.
---@param text string
---@return string
local function utf8_trim_tail(text)
  local at = #text
  local scanned = 0
  while at > 0 and scanned < 4 do
    local byte = text:byte(at)
    if byte < 0x80 then
      return text
    end
    if byte >= 0xC0 then
      local need = (byte >= 0xF0 and 4) or (byte >= 0xE0 and 3) or 2
      if #text - at + 1 >= need then
        return text
      end
      return text:sub(1, at - 1)
    end
    at = at - 1
    scanned = scanned + 1
  end
  return text
end

---The one line of `text` a match falls on, windowed to a readable width.
---
---A message is a document; a result row is a line. So the match is shown in its
---own line of that document, with the rest of it cut away — from the *inside* when
---the line is long, since the whole point is to show the words around the match.
---@param text string
---@param s integer 1-based byte start of the match.
---@param e integer 1-based byte end of the match, inclusive.
---@param width integer|nil
---@return string snippet
---@return integer col 0-based byte offset of the match within the snippet.
---@return integer len Byte length of the match within the snippet.
function M._snippet(text, s, e, width)
  width = width or SNIPPET_WIDTH

  local at = 0
  while true do
    local nl = text:find("\n", at + 1, true)
    if not nl or nl >= s then
      break
    end
    at = nl
  end
  local line_start = at + 1
  local nl_after = text:find("\n", e, true)
  local line_end = nl_after and (nl_after - 1) or #text

  local line = text:sub(line_start, line_end):gsub("[\t\r]", " ")
  local rel_s = s - line_start + 1
  local rel_e = e - line_start + 1

  local lead = #(line:match("^%s*") or "")
  if lead > 0 and lead < rel_s then
    line = line:sub(lead + 1)
    rel_s, rel_e = rel_s - lead, rel_e - lead
  end

  if #line <= width then
    return line, rel_s - 1, rel_e - rel_s + 1
  end

  -- A third of the window ahead of the match, so there is context on both sides
  -- of it rather than the match sitting on the left edge.
  local from = math.max(1, rel_s - math.floor(width / 3))
  from = utf8_floor(line, from)
  local piece = utf8_trim_tail(line:sub(from, from + width - 1))
  local prefix = from > 1 and ELLIPSIS or ""
  local suffix = (from + #piece - 1) < #line and ELLIPSIS or ""
  local col = #prefix + (rel_s - from)
  local len = rel_e - rel_s + 1
  -- A match cut off by the window is highlighted only as far as the snippet goes.
  len = math.max(0, math.min(len, #prefix + #piece - col))
  return prefix .. piece .. suffix, col, len
end

--- The `tool_use` input fields worth reading first, in this order. Everything
--- else a tool takes is read after them, alphabetically — `pairs` order is not
--- stable, and a result list that reorders itself between identical queries is
--- worse than one that is occasionally in a dull order.
local TOOL_FIELDS = { "command", "prompt", "description", "new_string", "old_string", "content", "pattern", "query" }

--- Fields skipped in a `tool_use` input: the file a call names is reported by its
--- `toolUseResult` as a `file` match, which is the canonical one. Reading both
--- would spend a session's whole cap saying the same path twice.
local TOOL_SKIP = { file_path = true, path = true, notebook_path = true, filePath = true }

---The string fields of a tool call, in a stable, useful order.
---@param input table
---@return string[]
function M._tool_fields(input)
  local seen, order = {}, {}
  for _, field in ipairs(TOOL_FIELDS) do
    if type(input[field]) == "string" and not TOOL_SKIP[field] then
      seen[field] = true
      order[#order + 1] = field
    end
  end
  local rest = {}
  for field, value in pairs(input) do
    if type(value) == "string" and not seen[field] and not TOOL_SKIP[field] then
      rest[#rest + 1] = field
    end
  end
  table.sort(rest)
  for _, field in ipairs(rest) do
    order[#order + 1] = field
  end
  return order
end

--- What a session's few rows are spent on, best first. A conversation is looked
--- for by what was **said** in it; the file it touched is the next strongest
--- claim, then what it ran, and last what it was reasoning about.
---
--- This is a global order, not a per-entry one, and it has to be: measured on
--- this project's real store, "windows" matches 26 thinking lines and 6 message
--- lines, so whichever came first in the file would otherwise take every row and
--- the sentence the user actually wrote would never be shown.
M.SEARCH_KINDS = { "message", "file", "tool", "thinking" }

---An empty per-kind bag of matches.
---@return table<string, table[]>
local function new_bag()
  local bag = {}
  for _, kind in ipairs(M.SEARCH_KINDS) do
    bag[kind] = {}
  end
  return bag
end

---Whether a scan can stop: nothing later in the file could improve this answer.
---
---Either the top tiers are full — no lower-tier match would be shown anyway — or
---enough of anything has been found that reading on is not worth it. Without the
---second bound a thinking-heavy transcript would always be read to the end.
---@param bag table<string, table[]>
---@param limit integer
---@return boolean
local function bag_done(bag, limit)
  if #bag.message + #bag.file >= limit then
    return true
  end
  local total = 0
  for _, kind in ipairs(M.SEARCH_KINDS) do
    total = total + #bag[kind]
  end
  return total >= limit * 3
end

---The rows a bag is worth, best tier first.
---@param bag table<string, table[]>
---@param limit integer
---@return table[]
local function bag_matches(bag, limit)
  local out = {}
  for _, kind in ipairs(M.SEARCH_KINDS) do
    for _, match in ipairs(bag[kind]) do
      if #out >= limit then
        return out
      end
      out[#out + 1] = match
    end
  end
  return out
end

---@param bag table<string, table[]>
---@param match table
---@param limit integer
local function keep(bag, match, limit)
  local bucket = bag[match.kind]
  -- More than `limit` of one kind can never be shown, so they are not kept.
  if bucket and #bucket < limit then
    bucket[#bucket + 1] = match
  end
end

---@param entry table Decoded transcript line.
---@param matcher table From `compile_query`.
---@param bag table<string, table[]> Matches so far, by kind.
---@param limit integer
local function search_entry(entry, matcher, bag, limit)
  local ts = M._iso_to_epoch(entry.timestamp)

  -- A tool result is not the conversation, so its output is not searched — but the
  -- file it names is: "which session touched lockfile.lua" is the same question the
  -- Changes pane answers, and this is the entry that answers it.
  local result = entry.toolUseResult
  if type(result) == "table" then
    local path = result.filePath
    if type(path) ~= "string" and type(result.file) == "table" then
      path = result.file.filePath
    end
    if type(path) == "string" then
      local s, e = matcher.find(path)
      if s then
        keep(bag, { kind = "file", text = path, col = s - 1, len = e - s + 1, ts = ts }, limit)
      end
    end
    return
  end

  local role = entry.type
  if role ~= "user" and role ~= "assistant" then
    return
  end
  local content = type(entry.message) == "table" and entry.message.content or nil

  -- What the turn said, what it did, and what it was reasoning about. Which of
  -- those is worth a row is decided once, over the whole file, by the tier order
  -- above — not here, where only this entry is in view.
  local candidates = {}
  local function candidate(kind, text, tool, field)
    candidates[#candidates + 1] = { kind = kind, text = text, tool = tool, field = field }
  end

  if type(content) == "string" then
    candidate("message", content)
  elseif type(content) == "table" then
    for _, block in ipairs(content) do
      if type(block) == "table" then
        if block.type == "text" and type(block.text) == "string" then
          candidate("message", block.text)
        elseif block.type == "thinking" and type(block.thinking) == "string" then
          candidate("thinking", block.thinking)
        elseif block.type == "tool_use" and type(block.input) == "table" then
          for _, field in ipairs(M._tool_fields(block.input)) do
            candidate("tool", block.input[field], block.name, field)
          end
        end
      end
    end
  end

  for _, item in ipairs(candidates) do
    local s, e = matcher.find(item.text)
    if s then
      local snippet, col, len = M._snippet(item.text, s, e)
      keep(bag, {
        kind = item.kind,
        role = role,
        tool = item.tool,
        field = item.field,
        text = snippet,
        col = col,
        len = len,
        ts = ts,
      }, limit)
    end
  end
end

---Search one transcript, calling back with up to `limit` matches.
---
---Cancellable and chunked, like every other read here: the caller cancels the
---whole run on the next keystroke, and a cancelled scan answers nobody.
---
---The prefilter runs against the **raw JSON line**, which is what makes this cheap
---enough to run per keystroke with no index — a line that does not contain the
---query at all is never decoded. The cost is JSON's own escaping: a query
---containing a quote, a backslash or a newline is spelled differently in the file
---than it is in the message, so it will not be found. Ordinary words, paths and
---identifiers — what a search of a conversation is actually made of — are spelled
---the same either way.
---@param path string Transcript path.
---@param matcher table From `compile_query`.
---@param opts { limit: integer|nil }|nil
---@param cb fun(matches: table[])
---@return { cancel: fun() } job
function M.search(path, matcher, opts, cb)
  opts = opts or {}
  local limit = opts.limit or 3
  local job = { cancelled = false }
  job.cancel = function()
    job.cancelled = true
  end

  local bag = new_bag()
  local function answer()
    if job.cancelled then
      return
    end
    -- Through the scheduler for `file_history`'s reason: these callbacks land in a
    -- libuv fast context, and what the caller does with matches is paint a window.
    vim.schedule(function()
      if not job.cancelled then
        cb(bag_matches(bag, limit))
      end
    end)
  end

  if type(path) ~= "string" or not matcher then
    answer()
    return job
  end
  local st = M._io.stat(path)
  if not st then
    answer()
    return job
  end

  local function scan_line(line)
    if #line == 0 or #line > SEARCH_LINE_LIMIT or not matcher.find(line) then
      return
    end
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" then
      pcall(search_entry, entry, matcher, bag, limit)
    end
  end

  local offset = 0
  local function step()
    if job.cancelled then
      return
    end
    -- Enough found: the rest of the file cannot change what this row says.
    if offset >= st.size or bag_done(bag, limit) then
      answer()
      return
    end
    local want = math.min(M._chunk_size, st.size - offset)
    M._io.read(path, offset, want, function(data)
      if job.cancelled then
        return
      end
      if not data or data == "" then
        answer()
        return
      end
      local consumed, start = 0, 1
      while true do
        local nl = data:find("\n", start, true)
        if not nl then
          break
        end
        scan_line(data:sub(start, nl - 1))
        consumed, start = nl, nl + 1
      end
      if consumed == 0 then
        -- No line boundary in a whole chunk, so this line is longer than one —
        -- which puts it past `SEARCH_LINE_LIMIT` by definition. `fold_chunks`
        -- pulls such a line in whole because it has something to fold; here there
        -- is nothing to look at, so walk over it a slice at a time instead of
        -- holding a quarter-megabyte of Bash output to throw away.
        if st.size - offset <= want then
          answer()
          return
        end
        offset = offset + want
        step()
        return
      end
      offset = offset + consumed
      step()
    end)
  end
  step()

  return job
end

--------------------------------------------------------------------------------
-- One file's history within one session
--------------------------------------------------------------------------------

--- Per-file histories, keyed `<transcript>\0<file>` and stamped with the
--- transcript's `(size, mtime)` so a stale one is never handed out.
local history_cache = {}

---@param transcript_path string
---@param file_path string
---@return string
local function history_key(transcript_path, file_path)
  return transcript_path .. "\0" .. file_path
end

---Fold one decoded entry into a file history, if it is about that file.
---@param hist ClaudeCodeAgentsFileHistory
---@param entry table
local function fold_history(hist, entry)
  local result = entry.toolUseResult
  if type(result) ~= "table" then
    return
  end
  local ts = M._iso_to_epoch(entry.timestamp)

  local file = result.file
  if type(file) == "table" and file.filePath == hist.path then
    local start_line = tonumber(file.startLine)
    if start_line then
      hist.reads[#hist.reads + 1] = {
        start_line = start_line,
        num_lines = tonumber(file.numLines) or 1,
        ts = ts,
      }
    end
    if ts > hist.last_ts then
      hist.last_ts = ts
    end
    return
  end

  if result.filePath ~= hist.path then
    return
  end

  local hunks = type(result.structuredPatch) == "table" and result.structuredPatch or {}
  -- A write with no patch is a file that did not exist: there was no "before" to
  -- diff against, so the baseline for this session is the empty file.
  if #hunks == 0 and type(result.content) == "string" and #hist.hunks == 0 then
    hist.created = true
  end
  for _, hunk in ipairs(hunks) do
    if type(hunk) == "table" and type(hunk.lines) == "table" then
      hist.hunks[#hist.hunks + 1] = hunk
    end
  end
  if type(result.content) == "string" then
    hist.content = result.content
  end
  if ts > hist.last_ts then
    hist.last_ts = ts
  end
end

---Everything one session did to one file: its patches, the windows it read, and
---whether it created the file.
---
---Read on demand rather than folded into the summary, because the patches are the
---bulk of a transcript and the summary is both held in memory for every session
---and mirrored to the warm cache — carrying them there would cost megabytes to
---answer a question only asked when someone opens a file. A whole-transcript scan
---per open is affordable for the same reason folding is: the prefilter (here, the
---file's own name) keeps `vim.json.decode` off ~99% of the bytes.
---
---Unlike `summary`, the callback is always handed back through `vim.schedule`.
---The reads land in a libuv callback — a *fast event context*, where `vim.fn` and
---the buffer API are errors, not slow paths (`E5560`) — and what a caller does with
---a file's history is open a window on it. Scheduling here rather than at every
---call site puts that where the asynchrony is.
---@param transcript_path string
---@param file_path string
---@param cb fun(history: ClaudeCodeAgentsFileHistory|nil)
function M.file_history(transcript_path, file_path, cb)
  local function answer(history)
    vim.schedule(function()
      cb(history)
    end)
  end

  if type(transcript_path) ~= "string" or type(file_path) ~= "string" or file_path == "" then
    answer(nil)
    return
  end
  local st = M._io.stat(transcript_path)
  if not st then
    answer(nil)
    return
  end

  local key = history_key(transcript_path, file_path)
  local cached = history_cache[key]
  if cached and cached.size == st.size and cached.mtime == st.mtime then
    answer(cached.history)
    return
  end

  ---@type ClaudeCodeAgentsFileHistory
  local hist = { path = file_path, hunks = {}, created = false, reads = {}, last_ts = 0 }
  -- The basename appears in every entry naming this file (the CLI records absolute
  -- paths), and in few others. Matching on it rather than the whole path also
  -- sidesteps JSON's escaping of a Windows separator.
  local needle = file_path:match("([^/\\]+)$") or file_path

  local offset = 0
  local function step()
    if offset >= st.size then
      history_cache[key] = { size = st.size, mtime = st.mtime, history = hist }
      answer(hist)
      return
    end
    local want = math.min(M._chunk_size, st.size - offset)
    M._io.read(transcript_path, offset, want, function(data)
      if not data or data == "" then
        answer(hist)
        return
      end
      local consumed, start = 0, 1
      while true do
        local nl = data:find("\n", start, true)
        if not nl then
          break
        end
        local line = data:sub(start, nl - 1)
        if line:find('"toolUseResult"', 1, true) and line:find(needle, 1, true) then
          local ok, entry = pcall(vim.json.decode, line)
          if ok and type(entry) == "table" then
            pcall(fold_history, hist, entry)
          end
        end
        consumed, start = nl, nl + 1
      end
      if consumed == 0 then
        -- A line longer than a chunk: pull the remainder in one read rather than
        -- spinning on the same bytes (the same case `fold_chunks` handles).
        M._io.read(transcript_path, offset, st.size - offset, function(all)
          if all then
            local from = 1
            while true do
              local nl = all:find("\n", from, true)
              if not nl then
                break
              end
              local line = all:sub(from, nl - 1)
              if line:find('"toolUseResult"', 1, true) and line:find(needle, 1, true) then
                local ok, entry = pcall(vim.json.decode, line)
                if ok and type(entry) == "table" then
                  pcall(fold_history, hist, entry)
                end
              end
              from = nl + 1
            end
          end
          history_cache[key] = { size = st.size, mtime = st.mtime, history = hist }
          answer(hist)
        end)
        return
      end
      offset = offset + consumed
      step()
    end)
  end
  step()
end

--------------------------------------------------------------------------------
-- One tool call within one session
--------------------------------------------------------------------------------

---@class ClaudeCodeAgentsToolCall
---@field tool string|nil Tool name, as the call recorded it.
---@field input table|nil What the call was given (a `Bash`'s command, say).
---@field result any The decoded `toolUseResult`, or nil when none has landed yet.
---@field ts number Epoch seconds of the call.

---Everything the transcript holds about one tool call, read on demand.
---
---The Activity row carries only what it draws — the tool, a one-line label and the
---call's id — because a row is folded for every call an agent makes and the
---payloads are the bulk of a transcript: a session's commands and their output ran
---to 116KB in one measured here, and `Task` prompts and MCP results are larger
---still. Holding those for every session in the list, to answer a question asked
---once per `<CR>`, is what `file_history` already declines to do for patches.
---
---So the two lines are found again when they are wanted. The id is the prefilter
---and it is an exceptionally good one: exactly two lines in the file contain it,
---so the scan decodes two lines however large the transcript is.
---
---Answered through `vim.schedule` for `file_history`'s reason: the reads land in a
---libuv fast context, and what a caller does with a tool call is open a window.
---@param transcript_path string
---@param tool_id string The `toolu_…` id joining the call to its result.
---@param cb fun(call: ClaudeCodeAgentsToolCall|nil)
function M.tool_call(transcript_path, tool_id, cb)
  local function answer(call)
    vim.schedule(function()
      cb(call)
    end)
  end

  if type(transcript_path) ~= "string" or type(tool_id) ~= "string" or tool_id == "" then
    answer(nil)
    return
  end
  local st = M._io.stat(transcript_path)
  if not st then
    answer(nil)
    return
  end

  ---@type ClaudeCodeAgentsToolCall
  local call = { ts = 0 }
  local found_use = false

  ---@param line string
  local function fold(line)
    if not line:find(tool_id, 1, true) then
      return
    end
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
      return
    end
    local content = type(entry.message) == "table" and entry.message.content or nil
    if type(content) == "table" then
      for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "tool_use" and block.id == tool_id then
          found_use = true
          call.tool = type(block.name) == "string" and block.name or nil
          call.input = type(block.input) == "table" and block.input or nil
          call.ts = M._iso_to_epoch(entry.timestamp)
        elseif type(block) == "table" and block.tool_use_id == tool_id then
          -- The result entry. `toolUseResult` is the decoded, tool-shaped copy the
          -- CLI writes beside the raw block; the block's own `content` is the
          -- fallback for an entry that has none (a rejected call, say).
          if entry.toolUseResult ~= nil then
            call.result = entry.toolUseResult
          elseif block.content ~= nil then
            call.result = block.content
          end
        end
      end
    end
  end

  local offset = 0
  local function step()
    if offset >= st.size then
      answer(found_use and call or nil)
      return
    end
    local want = math.min(M._chunk_size, st.size - offset)
    M._io.read(transcript_path, offset, want, function(data)
      if not data or data == "" then
        answer(found_use and call or nil)
        return
      end
      local consumed, start = 0, 1
      while true do
        local nl = data:find("\n", start, true)
        if not nl then
          break
        end
        fold(data:sub(start, nl - 1))
        consumed, start = nl, nl + 1
      end
      if consumed == 0 then
        -- A line longer than one chunk — a big result is exactly that — so the
        -- rest is pulled in one read rather than spinning on the same bytes.
        M._io.read(transcript_path, offset, st.size - offset, function(all)
          if all then
            local from = 1
            while true do
              local nl = all:find("\n", from, true)
              if not nl then
                break
              end
              fold(all:sub(from, nl - 1))
              from = nl + 1
            end
          end
          answer(found_use and call or nil)
        end)
        return
      end
      offset = offset + consumed
      step()
    end)
  end
  step()
end

---Drop a path's cached fold, cancelling any scan in flight.
---@param path string
function M.invalidate(path)
  local job = inflight[path]
  if job then
    job.cancelled = true
    inflight[path] = nil
  end
  cache[path] = nil
  for key in pairs(history_cache) do
    if key:sub(1, #path + 1) == path .. "\0" then
      history_cache[key] = nil
    end
  end
end

---Delete a conversation from the CLI's store. Irreversible: the transcript *is*
---the conversation, and `--resume` has nothing to read once it is gone.
---
---The CLI also parks some tool results in a directory named after the session
---beside the transcript (`<dir>/<id>/tool-results/`), so removing only the
---`.jsonl` would strand that for a conversation that no longer exists. Most
---sessions have no such directory, which is why its removal is not checked.
---@param path string Transcript path.
---@return boolean ok
---@return string|nil err
function M.delete(path)
  M.invalidate(path)
  if not M._io.remove(path) then
    return false, "could not delete " .. path
  end
  local sidecar = path:gsub("%.jsonl$", "")
  if sidecar ~= path then
    M._io.remove(sidecar)
  end
  return true, nil
end

---Cancel every in-flight scan without discarding what has been folded. Called
---when the view closes, so a large backfill stops costing anything.
function M.cancel_all()
  for path, job in pairs(inflight) do
    job.cancelled = true
    inflight[path] = nil
  end
end

function M.reset()
  M.cancel_all()
  cache = {}
  history_cache = {}
end

--------------------------------------------------------------------------------
-- Warm cache
--------------------------------------------------------------------------------

--- Bumped when a persisted field changes meaning, since an entry written by an
--- older version is not wrong-looking, only wrong: version 1's `last_ts` came
--- from tool events alone, so a cache from it would sort the list by something
--- other than what the list now claims to sort by, until every row re-folded.
--- An entry from another version is dropped, costing one cold fold.
local CACHE_VERSION = 2

---@return string path
function M.cache_path()
  return vim.fn.stdpath("cache") .. "/claudecode/agents.json"
end

---Load previously computed counts so the first paint shows real numbers.
---
---Only the display essentials are persisted — not fold state — so a loaded entry
---is marked `partial` and re-folds from scratch the first time anything needs its
---events. Losing this file costs nothing but that first paint's warmth.
function M.cache_load()
  local path = M.cache_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(decoded) ~= "table" or type(decoded.entries) ~= "table" then
    return
  end
  if decoded.version ~= CACHE_VERSION then
    return
  end
  for file, rec in pairs(decoded.entries) do
    if type(rec) == "table" and not cache[file] then
      local sum = new_summary(file)
      sum.name = rec.name
      sum.title = rec.title
      sum.first_prompt = rec.first_prompt
      sum.cwd = rec.cwd
      sum.added = tonumber(rec.added) or 0
      sum.removed = tonumber(rec.removed) or 0
      sum.last_ts = tonumber(rec.last_ts) or 0
      sum.size = tonumber(rec.size) or 0
      sum.mtime = tonumber(rec.mtime) or 0
      sum.ino = rec.ino
      sum.files = type(rec.files) == "table" and rec.files or {}
      sum.order = type(rec.order) == "table" and rec.order or {}
      sum.partial = true
      cache[file] = sum
    end
  end
end

---Persist the display essentials of every folded session.
function M.cache_save()
  local path = M.cache_path()
  local entries = {}
  for file, sum in pairs(cache) do
    if sum.size > 0 then
      entries[file] = {
        name = sum.name,
        title = sum.title,
        first_prompt = sum.first_prompt,
        cwd = sum.cwd,
        added = sum.added,
        removed = sum.removed,
        last_ts = sum.last_ts,
        size = sum.size,
        mtime = sum.mtime,
        ino = sum.ino,
        files = sum.files,
        order = sum.order,
      }
    end
  end
  pcall(function()
    vim.fn.mkdir(path:match("^(.*)[/\\][^/\\]*$") or ".", "p")
    local encoded = vim.json.encode({ version = CACHE_VERSION, entries = entries })
    vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
  end)
end

---@param full_config table|nil The whole plugin config; the `agents` block is read.
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
end

return M
