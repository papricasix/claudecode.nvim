-- luacheck: globals expect
require("tests.busted_setup")

describe("terminal_links", function()
  local tl

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.terminal_links"] = nil
    tl = require("claudecode.terminal_links")
  end)

  --------------------------------------------------------------------------------
  -- _url_to_path (pure)
  --------------------------------------------------------------------------------
  describe("_url_to_path", function()
    it("strips file:// from an absolute path", function()
      expect(tl._url_to_path("file:///Users/me/proj/README.md")).to_be("/Users/me/proj/README.md")
    end)

    it("strips an (unusual) host component", function()
      expect(tl._url_to_path("file://localhost/etc/hosts")).to_be("/etc/hosts")
    end)

    it("percent-decodes the path", function()
      expect(tl._url_to_path("file:///tmp/my%20file.lua")).to_be("/tmp/my file.lua")
    end)

    it("drops a #fragment", function()
      expect(tl._url_to_path("file:///a/b.lua#L10")).to_be("/a/b.lua")
    end)

    it("keeps a bare relative name (Claude's cwd-file form) instead of eating it as a host", function()
      expect(tl._url_to_path("file://logger.lua")).to_be("logger.lua")
      expect(tl._url_to_path("file://./logger.lua")).to_be("./logger.lua")
    end)
  end)

  --------------------------------------------------------------------------------
  -- _parse_token (pure text fallback)
  --------------------------------------------------------------------------------
  describe("_parse_token", function()
    it("returns a plain relative path", function()
      local p, l = tl._parse_token("see lua/foo/bar.lua here", 8) -- on 'foo'
      expect(p).to_be("lua/foo/bar.lua")
      expect(l).to_be(nil)
    end)

    it("splits a trailing :line", function()
      local p, l = tl._parse_token("edit src/app.ts:42 now", 6)
      expect(p).to_be("src/app.ts")
      expect(l).to_be(42)
    end)

    it("returns the same token regardless of click position within it", function()
      local line = "x lua/init.lua:9 y"
      for _, col in ipairs({ 2, 8, 14, 15 }) do -- across the token incl. the :9
        local p = tl._parse_token(line, col)
        expect(p).to_be("lua/init.lua")
      end
    end)

    it("strips trailing punctuation but keeps the line number", function()
      local p, l = tl._parse_token("at foo.lua:3.", 4)
      expect(p).to_be("foo.lua")
      expect(l).to_be(3)
    end)

    it("does not split a Windows drive letter", function()
      local p, l = tl._parse_token("C:thing", 0)
      expect(p).to_be("C:thing")
      expect(l).to_be(nil)
    end)

    it("returns nil on whitespace / empty / out of range", function()
      expect(tl._parse_token("", 0)).to_be(nil)
      expect(tl._parse_token("   ", 1)).to_be(nil)
    end)
  end)

  --------------------------------------------------------------------------------
  -- OSC 8 capture + click lookup
  --------------------------------------------------------------------------------
  describe("OSC 8 capture and lookup", function()
    local BUF = 17
    local opened

    local function base_config(overrides)
      return {
        port_range = { min = 10000, max = 65535 },
        auto_start = false,
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = {},
        env = {},
        models = { { name = "Test", value = "test" } },
        terminal = { provider = "native" },
        terminal_links = vim.tbl_extend(
          "force",
          { enabled = true, click = true, key = "gf", mouse_motion = false },
          overrides or {}
        ),
      }
    end

    before_each(function()
      -- A Claude terminal buffer: row 2 a tool header shown by basename, row 3 a relative
      -- path with a :line, row 4 one visual row of a wrapped (long) path.
      vim._mock.add_buffer(BUF, "term://~/proj//123:claude", {
        "first line",
        "  Update(README.md)",
        "  Read(src/app.ts:42)",
        "  bbbbbbbbbbbbbbbbbb",
      })
      vim.bo = setmetatable({}, {
        __index = function()
          return { buftype = "terminal" }
        end,
      })
      opened = nil
      tl._resolve = function(p)
        return p
      end
      tl._open_in_editor = function(p, l)
        opened = { path = p, line = l }
      end

      tl.setup(base_config())
      tl.attach(BUF)
    end)

    -- Feed the "open" half of an OSC 8 sequence (the part carrying the URL); coordinates are
    -- irrelevant to capture now, so a close isn't needed.
    local function record(url)
      tl._on_term_request(BUF, { buf = BUF, data = { sequence = "\27]8;id=abc;" .. url, cursor = { 1, 0 } } })
    end

    it("records the file path of each captured file:// link", function()
      record("file:///Users/me/proj/README.md")
      expect(tl._paths(BUF)[1]).to_be("/Users/me/proj/README.md")
    end)

    it("opens the captured absolute path from the basename token under the cursor", function()
      record("file:///Users/me/proj/README.md")
      local consumed = tl._open_at(BUF, 2, 12) -- on "README.md" in "  Update(README.md)"
      expect(consumed).to_be_true()
      expect(opened.path).to_be("/Users/me/proj/README.md")
    end)

    it("resolves a relative-path token and its :line", function()
      record("file:///Users/me/proj/src/app.ts")
      tl._open_at(BUF, 3, 10) -- on "src/app.ts:42"
      expect(opened.path).to_be("/Users/me/proj/src/app.ts")
      expect(opened.line).to_be(42)
    end)

    it("is row-independent: the link need not be on the row where it was captured", function()
      record("file:///Users/me/proj/README.md")
      -- click row 2 even though capture carried an unrelated cursor row
      local consumed = tl._open_at(BUF, 2, 12)
      expect(consumed).to_be_true()
    end)

    it("does not open a bare word that matches no captured path", function()
      record("file:///Users/me/proj/README.md")
      local consumed = tl._open_at(BUF, 2, 4) -- on "Update"
      expect(consumed).to_be_false()
      expect(opened).to_be(nil)
    end)

    it("ignores non-file:// links", function()
      record("https://example.com")
      local consumed = tl._open_at(BUF, 2, 12) -- "README.md", nothing captured for it
      expect(consumed).to_be_false()
    end)

    it("the newest captured path wins for a duplicated basename", function()
      record("file:///old/README.md")
      record("file:///new/README.md")
      tl._open_at(BUF, 2, 12)
      expect(opened.path).to_be("/new/README.md")
    end)

    it("matches a long chunk of a wrapped path by substring", function()
      record("file:///tmp/" .. ("b"):rep(40) .. "/wrapped.txt")
      local consumed = tl._open_at(BUF, 4, 10) -- on the "bbbb..." chunk row
      expect(consumed).to_be_true()
      expect(opened.path).to_be("/tmp/" .. ("b"):rep(40) .. "/wrapped.txt")
    end)
  end)

  --------------------------------------------------------------------------------
  -- config validation
  --------------------------------------------------------------------------------
  describe("config validation", function()
    local config

    local function base_config(terminal_links)
      return {
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = {},
        env = {},
        models = { { name = "Test Model", value = "test" } },
        terminal = { provider = "native" },
        terminal_links = terminal_links,
      }
    end

    before_each(function()
      package.loaded["claudecode.config"] = nil
      config = require("claudecode.config")
    end)

    it("accepts a fully specified terminal_links block", function()
      expect(pcall(config.validate, base_config({ enabled = true, click = false, key = "gf" }))).to_be_true()
    end)

    it("rejects a non-boolean enabled", function()
      expect(pcall(config.validate, base_config({ enabled = "yes" }))).to_be_false()
    end)

    it("rejects a non-string key", function()
      expect(pcall(config.validate, base_config({ key = 42 }))).to_be_false()
    end)
  end)
end)
