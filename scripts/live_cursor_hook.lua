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

local server = os.getenv("CLAUDECODE_NVIM_SERVER")
if not server or server == "" then
  os.exit(0)
end

local data = io.read("*a")
if not data or data == "" then
  os.exit(0)
end

-- The tabpage this Claude was launched in (0 = unknown). Strip to digits so it
-- is always a safe integer.
local tab = tonumber((os.getenv("CLAUDECODE_NVIM_TAB") or ""):match("%d+") or "0") or 0

-- TCP addresses look like `127.0.0.1:6789`; everything else (a Unix socket path
-- or a Windows named pipe `\\.\pipe\nvim...`) is a "pipe" connection.
local kind = server:match("^%d[%d%.]*:%d+$") and "tcp" or "pipe"

local ok, chan = pcall(vim.fn.sockconnect, kind, server, { rpc = true })
if not ok or type(chan) ~= "number" or chan == 0 then
  os.exit(0)
end

-- Synchronous request so the message is delivered before this short-lived
-- process exits. The remote `ingest` schedules its work and returns immediately.
pcall(
  vim.rpcrequest,
  chan,
  "nvim_exec_lua",
  [[
    local json, source_tab = ...
    return require("claudecode.live_cursor").ingest(json, source_tab)
  ]],
  { data, tab }
)

os.exit(0)
