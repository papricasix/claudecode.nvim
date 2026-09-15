-- luacheck: globals expect
-- Claude reads http_proxy/all_proxy with proxy-from-env semantics, so without a
-- loopback exclusion it sends its own ws://127.0.0.1:<port> IDE connection through
-- the proxy and the handshake never arrives (upstream issue #70).
require("tests.busted_setup")

describe("terminal no_proxy handling", function()
  local terminal

  before_each(function()
    package.loaded["claudecode.terminal"] = nil
    terminal = require("claudecode.terminal")
  end)

  after_each(function()
    package.loaded["claudecode.terminal"] = nil
  end)

  local function entries(value)
    local list = {}
    for entry in value:gmatch("[^,]+") do
      list[#list + 1] = entry
    end
    return list
  end

  local function contains(value, needle)
    for _, entry in ipairs(entries(value)) do
      if entry == needle then
        return true
      end
    end
    return false
  end

  it("adds the loopback hosts when nothing was set", function()
    local value = terminal._no_proxy_with_loopback(nil, nil)

    expect(contains(value, "localhost")).to_be_true()
    expect(contains(value, "127.0.0.1")).to_be_true()
    expect(contains(value, "::1")).to_be_true()
  end)

  it("keeps existing entries ahead of the loopback hosts", function()
    local value = terminal._no_proxy_with_loopback("example.com, .internal", nil)

    expect(entries(value)[1]).to_be("example.com")
    expect(entries(value)[2]).to_be(".internal")
    expect(contains(value, "127.0.0.1")).to_be_true()
  end)

  it("de-duplicates across sources without dropping later ones", function()
    -- A nil in the middle must not truncate the list, hence select() over {...}.
    local value = terminal._no_proxy_with_loopback("localhost", nil, "example.com", "localhost")
    local list = entries(value)

    local seen = 0
    for _, entry in ipairs(list) do
      if entry == "localhost" then
        seen = seen + 1
      end
    end
    expect(seen).to_be(1)
    expect(contains(value, "example.com")).to_be_true()
  end)
end)
