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
---@field kind "read"|"add"|"edit" What the agent did to the file.
---@field path string Absolute path as the CLI recorded it.
---@field added integer
---@field removed integer
---@field start_line integer|nil First line of a read (the CLI records the window it read).
---@field num_lines integer|nil How many lines that read covered.

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
}

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

---@return string dir The Claude CLI's config directory.
function M.config_dir()
  return require("claudecode.utils").claude_config_dir()
end

---The CLI's directory name for a project: the absolute path with every
---non-alphanumeric run replaced by a dash (`/a/b.c` -> `-a-b-c`).
---
---The rule is undocumented and inferred, which is why `project_dir` verifies the
---result rather than trusting it.
---@param abs_path string
---@return string
function M.slugify(abs_path)
  return (abs_path:gsub("[^%w]", "-"))
end

---Locate the transcript directory for a project.
---
---Tries the slug first, and falls back to scanning every project directory for a
---transcript whose entries name this cwd — so a change to the CLI's naming rule
---costs a slower lookup rather than an empty session list.
---@param cwd string
---@return string|nil dir
function M.project_dir(cwd)
  local root = M.config_dir() .. "/projects"
  if vim.fn.isdirectory(root) ~= 1 then
    return nil
  end

  local target = vim.fn.fnamemodify(cwd, ":p"):gsub("/$", "")
  local guess = root .. "/" .. M.slugify(target)
  if vim.fn.isdirectory(guess) == 1 then
    return guess
  end

  local names = M._io.scandir(root)
  if not names then
    return nil
  end
  for _, name in ipairs(names) do
    local dir = root .. "/" .. name
    if vim.fn.isdirectory(dir) == 1 and M._dir_matches_cwd(dir, target) then
      return dir
    end
  end
  return nil
end

---Whether any transcript in `dir` reports `target` as its cwd. Reads only the
---head of one file, since every message entry carries the same cwd.
---@param dir string
---@param target string
---@return boolean
function M._dir_matches_cwd(dir, target)
  local names = M._io.scandir(dir) or {}
  for _, name in ipairs(names) do
    if name:sub(-6) == ".jsonl" then
      local found = false
      local done = false
      M._io.read(dir .. "/" .. name, 0, 64 * 1024, function(data)
        done = true
        if not data then
          return
        end
        -- Match the raw bytes rather than decoding: this runs once per candidate
        -- directory and only needs a yes/no.
        local encoded = target:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
        found = data:find('"cwd":"' .. encoded .. '"') ~= nil
      end)
      -- The default reader is async, but this probe only runs on the slug-miss
      -- path; a reader that has not answered synchronously is treated as no match
      -- so a rare fallback never stalls the caller.
      if done and found then
        return true
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

  -- Bash results carry neither a patch nor a `file` object, which is what keeps
  -- their (often huge) stdout out of the decoder.
  if line:find('"toolUseResult"', 1, true) then
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
