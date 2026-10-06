---@brief [[
--- What the working tree looks like right now, for the files an agent touched.
---
--- Only the status letter comes from here. The +N/-N in the Changes pane is the
--- transcript's, so that pane and the session row can never contradict each other
--- — they are two views of one number. Git answers the different question the
--- transcript cannot: whether the file is still modified, was newly added, has
--- been deleted, or was never tracked at all.
---
--- Queries are restricted to the paths actually being shown, so a large repository
--- is never walked, and they are single-flight per root: a burst of edits costs one
--- extra query at the end rather than one per event.
---
--- Deliberately not `--porcelain -z`: `jobstart` hands stdout back as a list of
--- lines split on newlines, and NUL bytes arrive as `\n`, which destroys the exact
--- framing `-z` exists to provide. Newline-delimited output with quoted paths is
--- the format that survives the transport.
---
--- Reading a file's committed content (`file_at_head`, the `.` key) also speaks
--- svn: in an svn working copy it is `BASE`, since nothing else here asks svn
--- anything.
---@brief ]]
---@module 'claudecode.agents.git'

local logger = require("claudecode.logger")

local uv = vim.uv or vim.loop

local M = {}

--- [root] = { dirty: boolean, paths: string[], waiters: fun[] }
--- Presence *is* "a query is out": the entry is removed the moment one lands.
local inflight = {}

---Run a git command, calling back with its raw stdout.
---
---`vim.system` is the modern API but only exists on 0.10+, and this plugin
---supports 0.8, so both paths live behind one contract. Raw text rather than
---lines, because the two callers want different things from it: `run` drops
---blank lines (right for status output), while reading a file out of `HEAD`
---must keep every one of them.
---@param argv string[]
---@param cwd string|nil
---@param cb fun(text: string|nil, code: integer) nil when the process would not start.
local function spawn(argv, cwd, cb)
  if vim.system then
    local ok = pcall(function()
      vim.system(argv, { cwd = cwd, text = true }, function(result)
        vim.schedule(function()
          cb(tostring(result.stdout or ""), result.code or 0)
        end)
      end)
    end)
    if ok then
      return
    end
  end

  local out = {}
  local ok_job, job = pcall(vim.fn.jobstart, argv, {
    cwd = cwd,
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        out[#out + 1] = line
      end
    end,
    on_exit = function(_, code)
      cb(table.concat(out, "\n"), code or 0)
    end,
  })
  -- A command that is not installed can also come back as a job id of -1 rather
  -- than an error, and then `on_exit` never runs.
  if not ok_job or type(job) ~= "number" or job <= 0 then
    cb(nil, -1)
  end
end

--- Overridable for tests: reading a file out of a repository must not start a process.
M._spawn = spawn

---Run a git command, calling back with its non-empty stdout lines.
---@param argv string[]
---@param cwd string|nil
---@param cb fun(lines: string[]|nil, code: integer)
function M.run(argv, cwd, cb)
  spawn(argv, cwd, function(text, code)
    if type(text) ~= "string" then
      cb(nil, code)
      return
    end
    local lines = {}
    for line in text:gmatch("[^\n]+") do
      lines[#lines + 1] = line
    end
    cb(lines, code)
  end)
end

--- Overridable for tests: exercising the parsing must not start a process.
M._runner = M.run

---@param fn fun(argv: string[], cwd: string|nil, cb: fun(lines: string[]|nil, code: integer))
function M._set_runner(fn)
  M._runner = fn or M.run
end

---@class ClaudeCodeAgentsHeadInfo What a committed-content read was asked of.
---@field vcs "git"|"svn"
---@field rev "HEAD"|"BASE" The revision read, as the float names it.
---@field unversioned boolean|nil No working copy holds the file.
---@field failed boolean|nil The command could not be started (not installed, say).

---The directory holding `path`, as `fnamemodify(path, ":h")` answers it — either
---separator, and a root keeps its own (`/a` is in `/`, `D:\a` in `D:\`).
---
---Spelled out rather than asked of `vim.fn`: the walk below is reached from
---`model.refresh_git`, which the transcript fold calls from its read callback —
---a fast context, where a `vim.fn` call is not something to depend on.
---@param path string
---@return string dir
local function parent_dir(path)
  local head = path:match("^(.*)[/\\][^/\\]*$")
  if head == nil then
    return "."
  end
  if head == "" or head:match("^%a:$") then
    return path:sub(1, #head + 1)
  end
  return head
end
M._parent_dir = parent_dir

---The working copy a file belongs to: the nearest directory above it holding a
---`.git` (a directory, or the file a worktree or submodule has) or a `.svn`.
---
---Walked by hand with a stat per candidate, so a deleted file whose directory is
---gone too is still found, and `.git` wins when one directory holds both.
---@param path string Absolute path of the file.
---@return "git"|"svn"|nil kind
---@return string|nil root The directory holding the marker.
function M._working_copy(path)
  local dir = parent_dir(path)
  while uv and type(dir) == "string" and dir ~= "" do
    for _, kind in ipairs({ "git", "svn" }) do
      if uv.fs_stat(dir .. "/." .. kind) then
        return kind, dir
      end
    end
    local parent = parent_dir(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil, nil
end

---A file's committed content: `HEAD` in git, `BASE` in svn.
---
---Git runs against the file's own directory and asks for `HEAD:./<name>`, so the
---repo root never has to be found: git resolves a `./` path against the working
---directory it was given. svn's `BASE` is the revision the working copy last
---updated the file to, which is what `svn diff` compares against; the trailing
---`@` stops an `@` in the file's name being read as a peg revision.
---
---A non-zero exit inside a working copy means the file was never committed — it
---is new, which is a diff against nothing rather than a failure. Outside one (no
---marker found, and git, still asked in case `GIT_DIR` names a repository, says
---no) the file is not versioned at all.
---
---Deliberately not routed through `M.run`: that one drops empty lines, which is
---right for status output and wrong for file content, where a blank line is a
---line.
---@param path string Absolute path of the file.
---@param cb fun(lines: string[]|nil, info: ClaudeCodeAgentsHeadInfo) nil when not committed.
function M._show_head(path, cb)
  local kind, root = M._working_copy(path)
  ---@type ClaudeCodeAgentsHeadInfo
  local info = { vcs = kind or "git", rev = kind == "svn" and "BASE" or "HEAD" }

  local argv
  if kind == "svn" then
    argv = { "svn", "cat", "-r", "BASE", path .. "@" }
  else
    local dir = vim.fn.fnamemodify(path, ":h")
    argv = { "git", "-C", dir, "show", "HEAD:./" .. vim.fn.fnamemodify(path, ":t") }
  end

  -- From the working copy's root, which exists even when the file's directory
  -- was deleted along with it.
  M._spawn(argv, root, function(text, code)
    if type(text) ~= "string" then
      info.failed = true
      cb(nil, info)
      return
    end
    if code ~= 0 then
      info.unversioned = kind == nil or nil
      cb(nil, info)
      return
    end
    local lines = vim.split(text, "\n", { plain = true })
    -- A file ends with a newline, which split turns into a trailing empty
    -- element that is not a line of the file.
    if lines[#lines] == "" then
      table.remove(lines)
    end
    cb(lines, info)
  end)
end

--- Overridable for tests, like `_runner`: reading a file out of HEAD must not
--- need a repository.
M._head_reader = M._show_head

---@param fn fun(path: string, cb: fun(lines: string[]|nil, info: ClaudeCodeAgentsHeadInfo|nil))|nil
function M._set_head_reader(fn)
  M._head_reader = fn or M._show_head
end

---@param path string Absolute path of the file.
---@param cb fun(lines: string[]|nil, info: ClaudeCodeAgentsHeadInfo|nil) See `_show_head`.
function M.file_at_head(path, cb)
  return M._head_reader(path, cb)
end

---Strip git's quoting from a path.
---@param path string
---@return string
local function unquote(path)
  if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
    path = path:sub(2, -2):gsub('\\"', '"'):gsub("\\\\", "\\")
  end
  return path
end

---The single letter to show for a porcelain status pair.
---
---Index and worktree each get a column; the one that is not a space is what the
---file's state actually is, and the index wins when both are set (a staged add
---that was then modified is still an add).
---@param xy string Two-character status field.
---@return string
local function letter_for(xy)
  if xy == "??" then
    return "?"
  end
  local index, worktree = xy:sub(1, 1), xy:sub(2, 2)
  if index ~= " " and index ~= "" then
    return index
  end
  if worktree ~= " " and worktree ~= "" then
    return worktree
  end
  return " "
end

---Whether a path is already absolute: rooted, or on a Windows drive.
---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" or path:match("^%a:[/\\]") ~= nil
end

---Parse `git status --porcelain=v1` output into path -> letter.
---
---Keyed by `utils.path_key`, because the caller looks these up with the paths the
---CLI recorded and the two spellings need not match: git always answers with `/`
---separators, while a transcript written on Windows carries `D:\Git\proj\x.lua`.
---On POSIX the key is the path unchanged.
---@param lines string[]|nil
---@param root string|nil Prefix to make paths absolute again.
---@return table<string, string>
function M.parse_status(lines, root)
  local utils = require("claudecode.utils")
  local out = {}
  for _, line in ipairs(lines or {}) do
    -- "XY <path>", or "XY <old> -> <new>" for a rename.
    local xy, rest = line:match("^(..)%s(.+)$")
    if xy and rest then
      local letter = letter_for(xy)
      local _, new_path = rest:match("^(.-)%s+%->%s+(.+)$")
      -- A rename is reported as old -> new; the file that exists now is the new
      -- one, and that is the path the caller is showing.
      local path = unquote(new_path or rest)
      if root and root ~= "" and not is_absolute(path) then
        path = utils.normalize_path(root) .. "/" .. path
      end
      out[utils.path_key(path)] = letter
    end
  end
  return out
end

---Status letters for a set of paths.
---
---Paths not mentioned in the output are absent from the result rather than marked
---clean: "git said nothing about it" and "git says it is unchanged" are the same
---answer here, and the caller already has its own fallback.
---@param root string Repository root.
---@param paths string[] Absolute paths to ask about.
---@param cb fun(status: table<string, string>)
function M.status(root, paths, cb)
  if type(root) ~= "string" or root == "" or type(paths) ~= "table" or #paths == 0 then
    cb({})
    return
  end

  local job = inflight[root]
  if job then
    -- Another query is out. Remember that we want a fresh one and answer with it
    -- when it lands, so a burst of edits costs one extra query, not one each.
    job.dirty = true
    job.paths = paths
    job.waiters[#job.waiters + 1] = cb
    return
  end

  job = { dirty = false, paths = paths, waiters = { cb } }
  inflight[root] = job

  local argv = {
    "git",
    "-C",
    root,
    "-c",
    "core.quotepath=false",
    "status",
    "--porcelain=v1",
    "--untracked-files=all",
    "--",
  }
  for _, path in ipairs(paths) do
    argv[#argv + 1] = path
  end

  M._runner(argv, root, function(lines, code)
    local result = {}
    if code == 0 then
      result = M.parse_status(lines, root)
    else
      logger.debug("agents", "git status exited with", tostring(code))
    end

    local waiters = job.waiters
    local wanted_again = job.dirty
    local next_paths = job.paths
    inflight[root] = nil

    for _, waiter in ipairs(waiters) do
      pcall(waiter, result)
    end

    if wanted_again then
      M.status(root, next_paths, function() end)
    end
  end)
end

--- `[directory] = root`, or `false` when no git working copy holds it. A
--- directory does not change repository, so the walk up from it is made once.
---@type table<string, string|false>
local roots = {}

---The git working copy a file belongs to, remembered per directory.
---@param path string Absolute path of the file.
---@return string|nil root
function M.root_of(path)
  local dir = parent_dir(path)
  local known = roots[dir]
  if known == nil then
    local kind, root = M._working_copy(path)
    known = (kind == "git" and root) or false
    roots[dir] = known
  end
  return known or nil
end

---Forget which working copy each directory is in. What a manual refresh does:
---a `git init` is the one thing that changes the answer.
function M.forget_roots()
  roots = {}
end

---Status letters for paths that need not share a working copy.
---
---`status` asks one repository, and a path outside it is answered with silence:
---measured, `git -C <project> status -- <project>/.claude/worktrees/x/a.txt`
---prints nothing for a file that `git -C <the worktree>` reports ` M`. A
---conversation in a worktree has every one of its files there (and so does one
---that touched a submodule or a nested repository), so each path is asked of the
---working copy it belongs to and the answers are merged. One query per working
---copy, which for an ordinary conversation is still one.
---@param paths string[] Absolute paths to ask about.
---@param fallback string|nil Where to ask about a path no working copy claims — git may still answer there (a `GIT_DIR` repository has no marker).
---@param cb fun(status: table<string, string>)
function M.status_all(paths, fallback, cb)
  local groups, order = {}, {}
  for _, path in ipairs(type(paths) == "table" and paths or {}) do
    local root = M.root_of(path) or fallback
    if type(root) == "string" and root ~= "" then
      if not groups[root] then
        groups[root] = {}
        order[#order + 1] = root
      end
      groups[root][#groups[root] + 1] = path
    end
  end
  if #order == 0 then
    cb({})
    return
  end

  local merged, waiting = {}, #order
  for _, root in ipairs(order) do
    M.status(root, groups[root], function(result)
      for key, letter in pairs(result or {}) do
        merged[key] = letter
      end
      waiting = waiting - 1
      if waiting == 0 then
        cb(merged)
      end
    end)
  end
end

---Test/reload helper.
function M.reset()
  inflight = {}
  roots = {}
  M._runner = M.run
end

return M
