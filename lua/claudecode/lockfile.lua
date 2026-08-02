---@brief [[
--- Lock file management for Claude Code Neovim integration.
--- This module handles creation, removal and updating of lock files
--- which allow Claude Code CLI to discover the Neovim integration.
---@brief ]]
---@module 'claudecode.lockfile'
local M = {}

---Path to the lock file directory
---@return string lock_dir The path to the lock file directory
local function get_lock_dir()
  local claude_config_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if claude_config_dir and claude_config_dir ~= "" then
    return vim.fn.expand(claude_config_dir .. "/ide")
  else
    return vim.fn.expand("~/.claude/ide")
  end
end

M.lock_dir = get_lock_dir()

---Generate a cryptographically secure authentication token.
---@return string token A 32-character lowercase hex string (128 bits of entropy)
local function generate_auth_token()
  local bytes = require("claudecode.utils").random_bytes(16)

  -- Hex-encode the random bytes into a 32-character lowercase string.
  local token = bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end)

  -- Sanity-check the generated token shape.
  if not token:match("^[0-9a-f]+$") then
    error("Generated invalid auth token format")
  end

  if #token < 16 then
    error("Generated auth token too short: " .. #token .. " (expected at least 16)")
  end

  return token
end

---Generate a new authentication token
---@return string auth_token A newly generated authentication token
function M.generate_auth_token()
  return generate_auth_token()
end

---Create the lock file for a specified WebSocket port
---@param port number The port number for the WebSocket server
---@param auth_token? string Optional pre-generated auth token (generates new one if not provided)
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.create(port, auth_token)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  if port < 1 or port > 65535 then
    return false, "Port number out of valid range (1-65535): " .. tostring(port)
  end

  local ok, err = pcall(function()
    return vim.fn.mkdir(M.lock_dir, "p", tonumber("700", 8))
  end)

  if not ok then
    return false, "Failed to create lock directory: " .. (err or "unknown error")
  end

  -- mkdir's mode argument only applies to newly created directories; a lock dir
  -- left over from an earlier version may still be 0755. Tighten it to 0700.
  -- pcall-wrapped because fs_chmod is unsupported on some non-POSIX platforms.
  pcall(vim.loop.fs_chmod, M.lock_dir, tonumber("700", 8))

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  local workspace_folders = M.get_workspace_folders()
  if not auth_token then
    local auth_success, auth_result = pcall(generate_auth_token)
    if not auth_success then
      return false, "Failed to generate authentication token: " .. (auth_result or "unknown error")
    end
    auth_token = auth_result
  else
    -- Validate provided auth_token
    if type(auth_token) ~= "string" then
      return false, "Authentication token must be a string, got " .. type(auth_token)
    end
    if #auth_token < 10 then
      return false, "Authentication token too short (minimum 10 characters)"
    end
    if #auth_token > 500 then
      return false, "Authentication token too long (maximum 500 characters)"
    end
  end

  -- Prepare lock file content
  local lock_content = {
    pid = vim.fn.getpid(),
    workspaceFolders = workspace_folders,
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  }

  local json
  local ok_json, json_err = pcall(function()
    json = vim.json.encode(lock_content)
    return json
  end)

  if not ok_json or not json then
    return false, "Failed to encode lock file content: " .. (json_err or "unknown error")
  end

  -- Write atomically with restrictive (0600) permissions: write to a temp file
  -- in the same directory, then rename into place. Using "wx" (O_CREAT|O_EXCL)
  -- refuses to follow an existing file or symlink at the temp path.
  -- Include hrtime() so the temp path stays unique even after a crash where the
  -- PID is reused for the same port (otherwise "wx" would fail EEXIST).
  -- string.format keeps hrtime() (a double on LuaJIT) as a plain integer rather
  -- than scientific notation (e.g. 1.75e+15), which would corrupt the path.
  local tmp_path = lock_path .. ".tmp." .. vim.fn.getpid() .. "." .. string.format("%d", vim.loop.hrtime())

  local write_ok, write_err = pcall(function()
    local fd = vim.loop.fs_open(tmp_path, "wx", tonumber("600", 8))
    if not fd then
      error("could not open temp file: " .. tmp_path)
    end

    local close_and_raise = function(message)
      pcall(vim.loop.fs_close, fd)
      error(message)
    end

    -- fs_write may write fewer bytes than requested (quota/disk-full/odd FS),
    -- so loop on the returned count and an offset until all bytes are written.
    -- Otherwise a truncated lock file could be renamed into place.
    local pos = 0
    while pos < #json do
      local ok_write, written = pcall(vim.loop.fs_write, fd, json:sub(pos + 1), pos)
      if not ok_write then
        close_and_raise("could not write temp file: " .. tostring(written))
      end
      if type(written) ~= "number" or written <= 0 then
        close_and_raise("could not write temp file: short write at offset " .. pos .. "/" .. #json)
      end
      pos = pos + written
    end

    -- fs_close returns (nil, err) on libuv failure without raising, so check
    -- both the pcall status and the libuv result before renaming.
    local ok_close, close_result = pcall(vim.loop.fs_close, fd)
    if not ok_close or not close_result then
      error("could not close temp file: " .. tmp_path)
    end
  end)

  if not write_ok then
    pcall(vim.loop.fs_unlink, tmp_path)
    return false, "Failed to write lock file: " .. (write_err or "unknown error")
  end

  local rename_ok, rename_err = os.rename(tmp_path, lock_path)
  if not rename_ok then
    pcall(vim.loop.fs_unlink, tmp_path)
    return false, "Failed to write lock file: " .. (rename_err or "rename failed")
  end

  return true, lock_path, auth_token
end

---Remove the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.remove(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, "Lock file does not exist: " .. lock_path
  end

  local ok, err = pcall(function()
    return os.remove(lock_path)
  end)

  if not ok then
    return false, "Failed to remove lock file: " .. (err or "unknown error")
  end

  return true
end

---Whether a process is still running.
---
---`uv.kill(pid, 0)` sends no signal; it only asks whether the process exists, and
---libuv reports the same errnos on Linux, macOS, and Windows. The distinction
---that matters is `EPERM` — the process is alive but owned by someone else — so
---only an explicit `ESRCH` counts as dead. Anything else (a platform where the
---call is unsupported, an unexpected errno) is treated as alive, because the
---cost of guessing wrong is deleting a lock another editor is still using.
---@param pid number
---@return boolean
local function pid_is_alive(pid)
  local called, ok, err = pcall(vim.loop.kill, pid, 0)
  if not called or ok then
    return true
  end
  return tostring(err or ""):find("ESRCH", 1, true) == nil
end

---The pid recorded in a lock file, if it can be read.
---@param path string
---@return number|nil
local function read_lock_pid(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    return nil
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil
  end
  return tonumber(data.pid)
end

---Delete lock files whose owning process is gone.
---
---A lock is removed on `VimLeavePre`, which a crash or `kill -9` never reaches,
---so dead entries would otherwise pile up forever in a directory the Claude CLI
---scans. That scan only happens when `CLAUDE_CODE_SSE_PORT` is unset (our server
---failed to start), where a dead lock costs the CLI a failed connection.
---
---The directory is shared with every other editor and user, so this is
---deliberately timid: a lock is removed only when its pid is *provably* gone, and
---one we cannot parse is always left alone.
---@return number removed How many lock files were deleted.
function M.cleanup_stale()
  local ok, entries = pcall(vim.fn.glob, M.lock_dir .. "/*.lock", true, true)
  if not ok or type(entries) ~= "table" then
    return 0
  end

  local removed = 0
  for _, path in ipairs(entries) do
    local pid = read_lock_pid(path)
    if pid and not pid_is_alive(pid) then
      if pcall(os.remove, path) then
        removed = removed + 1
      end
    end
  end
  return removed
end

---Update the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.update(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local exists = vim.fn.filereadable(M.lock_dir .. "/" .. port .. ".lock") == 1
  if exists then
    local remove_ok, remove_err = M.remove(port)
    if not remove_ok then
      return false, "Failed to update lock file: " .. remove_err
    end
  end

  return M.create(port)
end

---Read the authentication token from a lock file
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? auth_token The authentication token if successful, or nil if failed
---@return string? error Error message if operation failed
function M.get_auth_token(port)
  if not port or type(port) ~= "number" then
    return false, nil, "Invalid port number"
  end

  local lock_path = M.lock_dir .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, nil, "Lock file does not exist: " .. lock_path
  end

  local file = io.open(lock_path, "r")
  if not file then
    return false, nil, "Failed to open lock file: " .. lock_path
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return false, nil, "Lock file is empty: " .. lock_path
  end

  local ok, lock_data = pcall(vim.json.decode, content)
  if not ok or type(lock_data) ~= "table" then
    return false, nil, "Failed to parse lock file JSON: " .. lock_path
  end

  local auth_token = lock_data.authToken
  if not auth_token or type(auth_token) ~= "string" then
    return false, nil, "No valid auth token found in lock file"
  end

  return true, auth_token, nil
end

---Get active LSP clients using available API
---@return table Array of LSP clients
local function get_lsp_clients()
  if vim.lsp then
    if vim.lsp.get_clients then
      -- Neovim >= 0.11
      return vim.lsp.get_clients()
    elseif vim.lsp.get_active_clients then
      -- Neovim 0.8-0.10
      return vim.lsp.get_active_clients()
    end
  end
  return {}
end

---Get workspace folders for the lock file
---@return table Array of workspace folder paths
function M.get_workspace_folders()
  local folders = {}

  -- Add current working directory
  table.insert(folders, vim.fn.getcwd())

  -- Get LSP workspace folders if available
  local clients = get_lsp_clients()
  for _, client in pairs(clients) do
    if client.config and client.config.workspace_folders then
      for _, ws in ipairs(client.config.workspace_folders) do
        -- Convert URI to path
        local path = ws.uri
        if path:sub(1, 7) == "file://" then
          path = path:sub(8)
        end

        -- Check if already in the list
        local exists = false
        for _, folder in ipairs(folders) do
          if folder == path then
            exists = true
            break
          end
        end

        if not exists then
          table.insert(folders, path)
        end
      end
    end
  end

  return folders
end

return M
