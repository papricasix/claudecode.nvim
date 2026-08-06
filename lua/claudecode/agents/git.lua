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
---@brief ]]
---@module 'claudecode.agents.git'

local logger = require("claudecode.logger")

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
  local ok_job = pcall(function()
    vim.fn.jobstart(argv, {
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
  end)
  if not ok_job then
    cb(nil, -1)
  end
end

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

---A file's content at `HEAD`.
---
---Runs from the file's own directory and asks for `HEAD:./<name>`, so the repo
---root never has to be found: git resolves a `./` path against the working
---directory it was given. A non-zero exit means the file is not in `HEAD` — it
---is new, which is a diff against nothing rather than a failure.
---
---Deliberately not routed through `M.run`: that one drops empty lines, which is
---right for status output and wrong for file content, where a blank line is a
---line.
---@param path string Absolute path of the file.
---@param cb fun(lines: string[]|nil) nil when the file is not in HEAD.
function M._show_head(path, cb)
  local dir = vim.fn.fnamemodify(path, ":h")
  local name = vim.fn.fnamemodify(path, ":t")
  local argv = { "git", "-C", dir, "show", "HEAD:./" .. name }

  ---@param text string|nil
  ---@param code integer
  local function answer(text, code)
    if code ~= 0 or type(text) ~= "string" then
      cb(nil)
      return
    end
    local lines = vim.split(text, "\n", { plain = true })
    -- A file ends with a newline, which split turns into a trailing empty
    -- element that is not a line of the file.
    if lines[#lines] == "" then
      table.remove(lines)
    end
    cb(lines)
  end

  spawn(argv, dir, answer)
end

--- Overridable for tests, like `_runner`: reading a file out of HEAD must not
--- need a repository.
M._head_reader = M._show_head

---@param fn fun(path: string, cb: fun(lines: string[]|nil))|nil
function M._set_head_reader(fn)
  M._head_reader = fn or M._show_head
end

---@param path string Absolute path of the file.
---@param cb fun(lines: string[]|nil)
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

---Test/reload helper.
function M.reset()
  inflight = {}
  M._runner = M.run
end

return M
