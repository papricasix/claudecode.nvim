---@brief TCP server implementation using vim.loop
local client_manager = require("claudecode.server.client")
local utils = require("claudecode.server.utils")

local M = {}

---@class TCPServer
---@field server table The vim.loop TCP server handle
---@field port number The port the server is listening on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table<string, WebSocketClient> Table of connected clients
---@field on_message function Callback for WebSocket messages
---@field on_connect function Callback for new connections
---@field on_disconnect function Callback for client disconnections
---@field on_error fun(err_msg: string) Callback for errors

--- How many ports to try before giving up. The configured range is tens of
--- thousands wide, so a real machine wins on the first or second attempt; the cap
--- only stops a pathological "everything is taken" case from freezing Neovim.
local MAX_BIND_ATTEMPTS = 50

---Candidate ports from the configured range, in random order.
---@param min_port number
---@param max_port number
---@return number[]
local function shuffled_ports(min_port, max_port)
  if min_port > max_port then
    return {}
  end
  local ports = {}
  for i = min_port, max_port do
    table.insert(ports, i)
  end
  utils.shuffle_array(ports)
  return ports
end

---Whether a port can actually be *served* on.
---
---Binding is not enough to answer that. libuv sets `SO_REUSEADDR` on every TCP
---bind, and on macOS that lets `bind()` succeed against a port another process is
---already listening on — the conflict only surfaces at `listen()`. A bind-only
---probe therefore reports a second Neovim's port as free, and the server then
---dies with EADDRINUSE. So probe with `listen()` as well, then let go.
---@param port number
---@return boolean
function M._port_is_free(port)
  local probe = vim.loop.new_tcp()
  if not probe then
    return false
  end
  local ok = probe:bind("127.0.0.1", port) and probe:listen(128, function() end)
  probe:close()
  return ok and true or false
end

---Find an available port by attempting to bind and listen
---@param min_port number Minimum port to try
---@param max_port number Maximum port to try
---@return number|nil port Available port number, or nil if none found
function M.find_available_port(min_port, max_port)
  for _, port in ipairs(shuffled_ports(min_port, max_port)) do
    if M._port_is_free(port) then
      return port
    end
  end
  return nil
end

---Create and start a TCP server
---
---Binds and listens on the real socket rather than probing first and re-binding:
---the port a probe cleared can be taken by the time we come back for it, and the
---probe cannot see a foreign listener at bind time anyway (see `_port_is_free`).
---A port that fails is simply the wrong port — we move to the next candidate
---instead of aborting the whole start.
---@param config ClaudeCodeConfig Server configuration
---@param callbacks table Callback functions
---@param auth_token string|nil Authentication token for validating connections
---@return TCPServer|nil server The server object, or nil on error
---@return string|nil error Error message if failed
function M.create_server(config, callbacks, auth_token)
  local min_port, max_port = config.port_range.min, config.port_range.max
  local ports = shuffled_ports(min_port, max_port)
  if #ports == 0 then
    return nil, "No available ports in range " .. min_port .. "-" .. max_port
  end

  -- Create server object
  local server = {
    server = nil,
    port = nil,
    auth_token = auth_token,
    clients = {},
    on_message = callbacks.on_message or function() end,
    on_connect = callbacks.on_connect or function() end,
    on_disconnect = callbacks.on_disconnect or function() end,
    on_error = callbacks.on_error or function() end,
  }

  local attempts = math.min(#ports, MAX_BIND_ATTEMPTS)
  local last_err
  for i = 1, attempts do
    local port = ports[i]
    local tcp_server = vim.loop.new_tcp()
    if not tcp_server then
      return nil, "Failed to create TCP server"
    end
    server.server = tcp_server
    server.port = port

    local bind_success, bind_err = tcp_server:bind("127.0.0.1", port)
    if bind_success then
      local listen_success, listen_err = tcp_server:listen(128, function(err)
        if err then
          callbacks.on_error("Listen error: " .. err)
          return
        end

        M._handle_new_connection(server)
      end)
      if listen_success then
        return server, nil
      end
      last_err = "listen on port " .. port .. " failed: " .. (listen_err or "unknown error")
    else
      last_err = "bind to port " .. port .. " failed: " .. (bind_err or "unknown error")
    end

    tcp_server:close()
    server.server = nil
    server.port = nil
    require("claudecode.logger").debug("server", "port " .. port .. " is taken, trying another (" .. last_err .. ")")
  end

  return nil,
    "No free port in range "
      .. min_port
      .. "-"
      .. max_port
      .. " after "
      .. attempts
      .. " attempts (last error: "
      .. tostring(last_err)
      .. ")"
end

---Handle a new client connection
---@param server TCPServer The server object
function M._handle_new_connection(server)
  local client_tcp = vim.loop.new_tcp()
  if not client_tcp then
    server.on_error("Failed to create client TCP handle")
    return
  end

  local accept_success, accept_err = server.server:accept(client_tcp)
  if not accept_success then
    server.on_error("Failed to accept connection: " .. (accept_err or "unknown error"))
    client_tcp:close()
    return
  end

  -- Create WebSocket client wrapper
  local client = client_manager.create_client(client_tcp)
  server.clients[client.id] = client

  -- Set up data handler
  client_tcp:read_start(function(err, data)
    if err then
      local error_msg = "Client read error: " .. err
      server.on_error(error_msg)
      M._disconnect_client(server, client, 1006, error_msg)
      return
    end

    if not data then
      -- EOF - client disconnected
      M._disconnect_client(server, client, 1006, "EOF")
      return
    end

    -- Process incoming data
    client_manager.process_data(client, data, function(cl, message)
      server.on_message(cl, message)
    end, function(cl, code, reason)
      M._disconnect_client(server, cl, code, reason)
    end, function(cl, error_msg)
      server.on_error("Client " .. cl.id .. " error: " .. error_msg)
      M._disconnect_client(server, cl, 1006, "Client error: " .. error_msg)
    end, server.auth_token)
  end)

  -- Notify about new connection
  server.on_connect(client)
end

---Disconnect a client and remove it from the server.
---This ensures `server.on_disconnect` is invoked for every disconnect path
---(EOF, read errors, protocol errors, timeouts), and only once per client.
---@param server TCPServer The server object
---@param client WebSocketClient The client to disconnect
---@param code number|nil WebSocket close code
---@param reason string|nil WebSocket close reason
function M._disconnect_client(server, client, code, reason)
  assert(type(server) == "table", "Expected server to be a table")
  local on_disconnect_type = type(server.on_disconnect)
  local on_disconnect_mt = on_disconnect_type == "table" and getmetatable(server.on_disconnect) or nil
  assert(
    on_disconnect_type == "function" or (on_disconnect_mt ~= nil and type(on_disconnect_mt.__call) == "function"),
    "Expected server.on_disconnect to be callable"
  )
  assert(type(server.clients) == "table", "Expected server.clients to be a table")
  assert(type(client) == "table", "Expected client to be a table")
  assert(type(client.id) == "string", "Expected client.id to be a string")
  if code ~= nil then
    assert(type(code) == "number", "Expected code to be a number")
  end
  if reason ~= nil then
    assert(type(reason) == "string", "Expected reason to be a string")
  end

  -- Idempotency: a client can hit multiple disconnect paths (e.g. CLOSE frame
  -- followed by a TCP EOF). Only notify/remove once.
  if not server.clients[client.id] then
    return
  end

  server.on_disconnect(client, code, reason)
  M._remove_client(server, client)
end

---Remove a client from the server
---@param server TCPServer The server object
---@param client WebSocketClient The client to remove
function M._remove_client(server, client)
  if server.clients[client.id] then
    server.clients[client.id] = nil

    if not client.tcp_handle:is_closing() then
      client.tcp_handle:close()
    end
  end
end

---Send a message to a specific client
---@param server TCPServer The server object
---@param client_id string The client ID
---@param message string The message to send
---@param callback function|nil Optional callback
function M.send_to_client(server, client_id, message, callback)
  local client = server.clients[client_id]
  if not client then
    if callback then
      callback("Client not found: " .. client_id)
    end
    return
  end

  client_manager.send_message(client, message, callback)
end

---Broadcast a message to all connected clients
---@param server TCPServer The server object
---@param message string The message to broadcast
function M.broadcast(server, message)
  for _, client in pairs(server.clients) do
    client_manager.send_message(client, message)
  end
end

---Get the number of connected clients
---@param server TCPServer The server object
---@return number count Number of connected clients
function M.get_client_count(server)
  local count = 0
  for _ in pairs(server.clients) do
    count = count + 1
  end
  return count
end

---Get information about all clients
---@param server TCPServer The server object
---@return table clients Array of client information
function M.get_clients_info(server)
  local clients = {}
  for _, client in pairs(server.clients) do
    table.insert(clients, client_manager.get_client_info(client))
  end
  return clients
end

---Close a specific client connection
---@param server TCPServer The server object
---@param client_id string The client ID
---@param code number|nil Close code
---@param reason string|nil Close reason
function M.close_client(server, client_id, code, reason)
  local client = server.clients[client_id]
  if client then
    client_manager.close_client(client, code, reason)
  end
end

---Stop the TCP server
---@param server TCPServer The server object
function M.stop_server(server)
  -- Close all clients
  for _, client in pairs(server.clients) do
    client_manager.close_client(client, 1001, "Server shutting down")
  end

  -- Clear clients
  server.clients = {}

  -- Close server
  if server.server and not server.server:is_closing() then
    server.server:close()
  end
end

---Start a periodic ping task to keep connections alive
---@param server TCPServer The server object
---@param interval number Ping interval in milliseconds (default: 30000)
---@return table? timer The timer handle, or nil if creation failed
function M.start_ping_timer(server, interval)
  interval = interval or 30000 -- 30 seconds
  local last_run = vim.loop.now()

  local timer = vim.loop.new_timer()
  if not timer then
    server.on_error("Failed to create ping timer")
    return nil
  end

  timer:start(interval, interval, function()
    local now = vim.loop.now()
    local elapsed = now - last_run

    -- Detect potential system sleep: timer interval was significantly exceeded
    -- Allow 50% grace period (e.g., 45s instead of 30s) to account for system load
    local is_wake_from_sleep = elapsed > (interval * 1.5)

    if is_wake_from_sleep then
      -- After system sleep/wake, reset all client pong timestamps to prevent false timeouts
      -- This gives clients a fresh keepalive window since the time jump isn't their fault
      require("claudecode.logger").debug(
        "server",
        string.format(
          "Detected potential wake from sleep (%.1fs elapsed), resetting client keepalive timers",
          elapsed / 1000
        )
      )
      for _, client in pairs(server.clients) do
        if client.state == "connected" then
          client.last_pong = now
        end
      end
    end

    for _, client in pairs(server.clients) do
      if client.state == "connected" then
        -- Check if client is alive (local connections, so use standard timeout)
        if client_manager.is_client_alive(client, interval * 2) then
          client_manager.send_ping(client, "ping")
        else
          -- Client connection timed out - log at INFO level (this is expected behavior)
          local time_since_pong = math.floor((now - client.last_pong) / 1000)
          require("claudecode.logger").info(
            "server",
            string.format("Client %s keepalive timeout (%ds idle), closing connection", client.id, time_since_pong)
          )
          client_manager.close_client(client, 1006, "Connection timeout")
          M._disconnect_client(server, client, 1006, "Connection timeout")
        end
      end
    end

    last_run = now
  end)

  return timer
end

return M
