---@brief WebSocket server for Claude Code Neovim integration
local claudecode_main = require("claudecode") -- Added for version access
local logger = require("claudecode.logger")
local tcp_server = require("claudecode.server.tcp")
local tools = require("claudecode.tools.init") -- Added: Require the tools module

local MCP_PROTOCOL_VERSION = "2024-11-05"

local M = {}

-- Add a unique module ID to detect reloading
local module_instance_id = math.random(10000, 99999)
logger.debug("server", "Server module loaded with instance ID:", module_instance_id)

-- Create a fully independent server instance.
-- tab_id is the Neovim tabpage handle this instance belongs to (nil for singleton).
local function create_instance(tab_id)
  local state = {
    server = nil,
    port = nil,
    auth_token = nil,
    handlers = {},
    ping_timer = nil,
    tab_id = tab_id,
  }

  local inst = { state = state }

  function inst.register_handlers()
    state.handlers = {
      ["initialize"] = function(client, params)
        return {
          protocolVersion = MCP_PROTOCOL_VERSION,
          capabilities = {
            logging = vim.empty_dict(),
            prompts = { listChanged = true },
            resources = { subscribe = true, listChanged = true },
            tools = { listChanged = true },
          },
          serverInfo = {
            name = "claudecode-neovim",
            version = claudecode_main.version:string(),
          },
        }
      end,

      ["notifications/initialized"] = function(client, params) end,

      ["prompts/list"] = function(client, params)
        return { prompts = {} }
      end,

      ["tools/list"] = function(client, params)
        return { tools = tools.get_tool_list() }
      end,

      ["tools/call"] = function(client, params)
        logger.debug(
          "server",
          "Received tools/call. Tool: ",
          params and params.name,
          " Arguments: ",
          vim.inspect(params and params.arguments)
        )
        local result_or_error_table = tools.handle_invoke(client, params)

        if result_or_error_table and result_or_error_table._deferred then
          logger.debug("server", "Tool is blocking - setting up deferred response")
          return result_or_error_table
        end

        logger.debug("server", "Response - tools/call", params and params.name .. ":", vim.inspect(result_or_error_table))

        if result_or_error_table.error then
          return nil, result_or_error_table.error
        elseif result_or_error_table.result then
          return result_or_error_table.result, nil
        else
          return nil, {
            code = -32603,
            message = "Internal error",
            data = "Tool handler returned unexpected format",
          }
        end
      end,
    }
  end

  function inst.start(config, auth_token)
    if state.server then
      return false, "Server already running"
    end

    state.auth_token = auth_token

    if auth_token then
      logger.debug("server", "Starting WebSocket server with authentication enabled")
      logger.debug("server", "Auth token length:", #auth_token)
    else
      logger.debug("server", "Starting WebSocket server WITHOUT authentication (insecure)")
    end

    inst.register_handlers()
    tools.setup(inst)

    local callbacks = {
      on_message = function(client, message)
        inst._handle_message(client, message)
      end,
      on_connect = function(client)
        if state.auth_token then
          logger.debug("server", "Authenticated WebSocket client connected:", client.id)
        else
          logger.debug("server", "WebSocket client connected (no auth):", client.id)
        end

        local main_module = require("claudecode")
        if main_module.process_mention_queue_for_tab then
          vim.schedule(function()
            main_module.process_mention_queue_for_tab(state.tab_id, true)
          end)
        end
      end,
      on_disconnect = function(client, code, reason)
        logger.debug(
          "server",
          "WebSocket client disconnected:",
          client.id,
          "(code:",
          code,
          ", reason:",
          (reason or "N/A") .. ")"
        )
      end,
      on_error = function(error_msg)
        logger.error("server", "WebSocket server error:", error_msg)
      end,
    }

    local server_obj, error_msg = tcp_server.create_server(config, callbacks, state.auth_token)
    if not server_obj then
      return false, error_msg or "Unknown server creation error"
    end

    state.server = server_obj
    state.port = server_obj.port
    state.ping_timer = tcp_server.start_ping_timer(server_obj, 30000)

    return true, server_obj.port
  end

  function inst.stop()
    if not state.server then
      return false, "Server not running"
    end

    if state.ping_timer then
      state.ping_timer:stop()
      state.ping_timer:close()
      state.ping_timer = nil
    end

    tcp_server.stop_server(state.server)

    -- CRITICAL: Clear global deferred responses to prevent memory leaks and hanging
    if _G.claude_deferred_responses then
      _G.claude_deferred_responses = {}
    end

    state.server = nil
    state.port = nil
    state.auth_token = nil
    return true
  end

  function inst._handle_message(client, message)
    local success, parsed = pcall(vim.json.decode, message)
    if not success then
      inst.send_response(client, nil, nil, {
        code = -32700,
        message = "Parse error",
        data = "Invalid JSON",
      })
      return
    end

    if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
      inst.send_response(client, parsed.id, nil, {
        code = -32600,
        message = "Invalid Request",
        data = "Not a valid JSON-RPC 2.0 request",
      })
      return
    end

    if parsed.id then
      inst._handle_request(client, parsed)
    else
      inst._handle_notification(client, parsed)
    end
  end

  function inst._handle_request(client, request)
    local method = request.method
    local params = request.params or {}
    local id = request.id

    local handler = state.handlers[method]
    if not handler then
      inst.send_response(client, id, nil, {
        code = -32601,
        message = "Method not found",
        data = "Unknown method: " .. tostring(method),
      })
      return
    end

    local success, result, error_data = pcall(handler, client, params)
    if success then
      if result and result._deferred then
        logger.debug("server", "Handler returned deferred response - storing for later")
        local deferred_info = {
          client = result.client,
          id = id,
          coroutine = result.coroutine,
          method = method,
          params = result.params,
        }
        inst._setup_deferred_response(deferred_info)
        return
      end

      if error_data then
        inst.send_response(client, id, nil, error_data)
      else
        inst.send_response(client, id, result, nil)
      end
    else
      inst.send_response(client, id, nil, {
        code = -32603,
        message = "Internal error",
        data = tostring(result),
      })
    end
  end

  function inst._setup_deferred_response(deferred_info)
    local co = deferred_info.coroutine

    logger.debug("server", "Setting up deferred response for coroutine:", tostring(co))
    logger.debug("server", "Storage happening in module instance:", module_instance_id)

    local response_sender = function(result)
      logger.debug("server", "Deferred response triggered for coroutine:", tostring(co))

      if result and result.content then
        inst.send_response(deferred_info.client, deferred_info.id, result, nil)
      elseif result and result.error then
        inst.send_response(deferred_info.client, deferred_info.id, nil, result.error)
      else
        inst.send_response(deferred_info.client, deferred_info.id, nil, {
          code = -32603,
          message = "Internal error",
          data = "Deferred response completed with unexpected format",
        })
      end
    end

    if not _G.claude_deferred_responses then
      _G.claude_deferred_responses = {}
    end
    _G.claude_deferred_responses[tostring(co)] = response_sender

    logger.debug("server", "Stored response sender in global table for coroutine:", tostring(co))
  end

  function inst._handle_notification(client, notification)
    local method = notification.method
    local params = notification.params or {}
    local handler = state.handlers[method]
    if handler then
      pcall(handler, client, params)
    end
  end

  function inst.send(client, method, params)
    if not state.server then
      return false
    end

    local message = {
      jsonrpc = "2.0",
      method = method,
      params = params or vim.empty_dict(),
    }

    local json_message = vim.json.encode(message)
    tcp_server.send_to_client(state.server, client.id, json_message)
    return true
  end

  function inst.send_response(client, id, result, error_data)
    if not state.server then
      return false
    end

    local response = {
      jsonrpc = "2.0",
      id = id,
    }

    if error_data then
      response.error = error_data
    else
      response.result = result
    end

    local json_response = vim.json.encode(response)
    tcp_server.send_to_client(state.server, client.id, json_response)
    return true
  end

  function inst.broadcast(method, params)
    if not state.server then
      return false
    end

    local message = {
      jsonrpc = "2.0",
      method = method,
      params = params or vim.empty_dict(),
    }

    local json_message = vim.json.encode(message)
    tcp_server.broadcast(state.server, json_message)
    return true
  end

  function inst.get_status()
    if not state.server then
      return { running = false, port = nil, client_count = 0 }
    end

    return {
      running = true,
      port = state.port,
      client_count = tcp_server.get_client_count(state.server),
      clients = tcp_server.get_clients_info(state.server),
    }
  end

  return inst
end

-- Module-level state (kept so that M.state.port is readable for legacy code paths)
M.state = {
  server = nil,
  port = nil,
  auth_token = nil,
  handlers = {},
  ping_timer = nil,
}

-- Module-level singleton; M.state points at its state table
local _singleton = create_instance(nil)
M.state = _singleton.state

-- Delegate module-level methods to singleton for backward compatibility
function M.start(config, auth_token)
  return _singleton.start(config, auth_token)
end
function M.stop()
  return _singleton.stop()
end
function M.broadcast(method, params)
  return _singleton.broadcast(method, params)
end
function M.get_status()
  return _singleton.get_status()
end
function M.send(client, method, params)
  return _singleton.send(client, method, params)
end
function M.send_response(client, id, result, error_data)
  return _singleton.send_response(client, id, result, error_data)
end
function M._handle_message(client, message)
  return _singleton._handle_message(client, message)
end
function M._handle_request(client, request)
  return _singleton._handle_request(client, request)
end
function M._handle_notification(client, notification)
  return _singleton._handle_notification(client, notification)
end
function M._setup_deferred_response(deferred_info)
  return _singleton._setup_deferred_response(deferred_info)
end
function M.register_handlers()
  return _singleton.register_handlers()
end

---Create a new independent server instance for a specific tab.
---@param tab_id number|nil The Neovim tabpage handle this instance belongs to
---@return table instance A self-contained server object with start/stop/broadcast/etc.
function M.new_instance(tab_id)
  return create_instance(tab_id)
end

return M
