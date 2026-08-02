require("tests.busted_setup")

local client_manager = require("claudecode.server.client")

describe("TCP server disconnect handling", function()
  local tcp
  local original_process_data

  before_each(function()
    package.loaded["claudecode.server.tcp"] = nil
    tcp = require("claudecode.server.tcp")
    original_process_data = client_manager.process_data
  end)

  after_each(function()
    client_manager.process_data = original_process_data
  end)

  it("should call on_disconnect and remove client on EOF", function()
    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    assert.spy(callbacks.on_connect).was_called(1)
    local client = callbacks.on_connect.calls[1].vals[1]
    assert.is_table(client)
    assert.is_table(client.tcp_handle)
    assert.is_function(client.tcp_handle._read_cb)

    -- Simulate client abruptly disconnecting (e.g. CLI terminated via Ctrl-C)
    client.tcp_handle._read_cb(nil, nil)

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "EOF")
    expect(server.clients[client.id]).to_be_nil()
  end)

  it("should call on_disconnect and remove client on TCP read error", function()
    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb("boom", nil)

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Client read error: boom")
    expect(server.clients[client.id]).to_be_nil()

    assert.spy(callbacks.on_error).was_called(1)
    assert.spy(callbacks.on_error).was_called_with("Client read error: boom")
  end)

  it("should call on_disconnect when client manager reports an error", function()
    client_manager.process_data = function(cl, data, on_message, on_close, on_error, auth_token)
      on_error(cl, "Protocol error")
    end

    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb(nil, "some data")

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1006, "Client error: Protocol error")
    expect(server.clients[client.id]).to_be_nil()
  end)

  it("should only call on_disconnect once if multiple disconnect paths fire", function()
    client_manager.process_data = function(cl, data, on_message, on_close, on_error, auth_token)
      on_close(cl, 1000, "bye")
    end

    local callbacks = {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }

    local config = { port_range = { min = 10000, max = 10000 } }
    local server, err = tcp.create_server(config, callbacks, nil)
    assert.is_nil(err)
    assert.is_table(server)

    tcp._handle_new_connection(server)

    local client = callbacks.on_connect.calls[1].vals[1]
    client.tcp_handle._read_cb(nil, "data")

    assert.spy(callbacks.on_disconnect).was_called(1)
    assert.spy(callbacks.on_disconnect).was_called_with(client, 1000, "bye")
    expect(server.clients[client.id]).to_be_nil()

    -- Simulate a later EOF after the CLOSE path already removed the client.
    client.tcp_handle._read_cb(nil, nil)
    assert.spy(callbacks.on_disconnect).was_called(1)
  end)
end)

describe("TCP port selection", function()
  local tcp
  local original_new_tcp

  local function callbacks()
    return {
      on_message = spy.new(function() end),
      on_connect = spy.new(function() end),
      on_disconnect = spy.new(function() end),
      on_error = spy.new(function() end),
    }
  end

  --- Pretend the first `busy` ports we try are already served by another process:
  --- bind succeeds (libuv sets SO_REUSEADDR) and only listen reports EADDRINUSE.
  local function taken_ports(busy)
    local attempts = 0
    vim.loop.new_tcp = function()
      local handle = original_new_tcp()
      handle.listen = function(_, _, _)
        attempts = attempts + 1
        if attempts <= busy then
          return nil, "EADDRINUSE: address already in use"
        end
        return true
      end
      return handle
    end
    return function()
      return attempts
    end
  end

  before_each(function()
    package.loaded["claudecode.server.tcp"] = nil
    tcp = require("claudecode.server.tcp")
    original_new_tcp = vim.loop.new_tcp
  end)

  after_each(function()
    vim.loop.new_tcp = original_new_tcp
  end)

  it("treats a port it can bind but not listen on as taken", function()
    taken_ports(1)
    expect(tcp._port_is_free(10000)).to_be_false()
    expect(tcp._port_is_free(10001)).to_be_true()
  end)

  it("moves to the next port instead of failing the whole start", function()
    local attempts = taken_ports(3)
    local server, err = tcp.create_server({ port_range = { min = 10000, max = 10010 } }, callbacks(), nil)
    assert.is_nil(err)
    assert.is_table(server)
    expect(attempts()).to_be(4)
    expect(server.port >= 10000 and server.port <= 10010).to_be_true()
  end)

  it("reports the last error when no port in the range is free", function()
    taken_ports(math.huge)
    local server, err = tcp.create_server({ port_range = { min = 10000, max = 10002 } }, callbacks(), nil)
    assert.is_nil(server)
    assert.is_string(err)
    assert.is_truthy(err:find("No free port", 1, true))
    assert.is_truthy(err:find("EADDRINUSE", 1, true))
  end)
end)
