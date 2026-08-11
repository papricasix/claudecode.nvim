-- claudecode.nvim live-cursor hook (cross-platform).
--
-- Registered as a Claude Code PreToolUse hook (injected per-launch via
-- `claude --settings`) and run as:
--
--   nvim --headless -u NONE -l <this-file>
--
-- Using `nvim` itself as the interpreter means the hook needs no shell, no
-- `mktemp`/`cat`, and no POSIX-only builtins, so it behaves identically on
-- macOS, Linux, and native Windows (the only requirement is an `nvim` on PATH,
-- which the plugin needs anyway).
--
-- Claude pipes the tool-event JSON to us on stdin. We connect to the running
-- Neovim over its RPC socket (handed to us in CLAUDECODE_NVIM_SERVER) and pass
-- the JSON straight through to the plugin, which opens/previews the touched file
-- and highlights the line range Claude is reading or editing.
--
-- No-ops silently when not launched from Neovim or when the socket is gone, so
-- it can never block or break a Claude session.
--
-- DEBUGGING: set CLAUDECODE_HOOK_DEBUG to a writable file path before launching
-- Claude (e.g. via the plugin's `terminal.env`); every run then appends a line
-- explaining what it saw and where it stopped. This is the fastest way to find
-- out why the ride-along is silent on a given platform (Windows especially).

local debug_path = os.getenv("CLAUDECODE_HOOK_DEBUG")
local function dbg(msg)
  if not debug_path or debug_path == "" then
    return
  end
  local f = io.open(debug_path, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
    f:close()
  end
end

local function bail(reason)
  dbg("exit: " .. reason)
  os.exit(0)
end

local server = os.getenv("CLAUDECODE_NVIM_SERVER")
dbg("start; CLAUDECODE_NVIM_SERVER=" .. tostring(server))
if not server or server == "" then
  bail("no CLAUDECODE_NVIM_SERVER in env (was it passed to the Claude process?)")
end

local data = io.read("*a")
if not data or data == "" then
  bail("empty stdin (no tool-event JSON piped in)")
end
dbg("read " .. #data .. " bytes of stdin")

-- The tabpage this Claude was launched in (0 = unknown). Strip to digits so it
-- is always a safe integer.
local tab = tonumber((os.getenv("CLAUDECODE_NVIM_TAB") or ""):match("%d+") or "0") or 0

-- Which agents-mode launch this Claude is (empty for every other launch). The
-- conversation id in the payload names the chat, and `/clear` starts a new one
-- in the same terminal, so this is the only stable name the plugin can key a
-- running agent by.
local agent = os.getenv("CLAUDECODE_AGENT_ID") or ""

-- TCP addresses look like `127.0.0.1:6789`; everything else (a Unix socket path
-- or a Windows named pipe `\\.\pipe\nvim...`) is a "pipe" connection.
local kind = server:match("^%d[%d%.]*:%d+$") and "tcp" or "pipe"
dbg("connecting kind=" .. kind .. " tab=" .. tab)

local ok, chan = pcall(vim.fn.sockconnect, kind, server, { rpc = true })
if not ok or type(chan) ~= "number" or chan == 0 then
  bail("sockconnect failed: " .. tostring(chan))
end
dbg("connected on channel " .. tostring(chan))

-- Synchronous request so the message is delivered before this short-lived
-- process exits. The remote `ingest` schedules its work and returns immediately.
local req_ok, req_err = pcall(
  vim.rpcrequest,
  chan,
  "nvim_exec_lua",
  [[
    local json, source_tab, agent_id = ...
    return require("claudecode.live_cursor").ingest(json, source_tab, agent_id)
  ]],
  { data, tab, agent }
)
if not req_ok then
  bail("rpcrequest failed: " .. tostring(req_err))
end

bail("delivered ok")
