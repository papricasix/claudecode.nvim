-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.search", function()
  local transcript, search

  -- Same in-memory store the transcript spec uses: the scanner reaches the
  -- filesystem only through `_io`, and the fake never defers, so every scan
  -- answers inside the call that started it.
  local fs, reads

  local function install_io()
    transcript._io = {
      stat = function(path)
        local f = fs[path]
        return f and { size = #f.data, mtime = f.mtime or 1, ino = f.ino or 1 } or nil
      end,
      scandir = function()
        return nil
      end,
      remove = function()
        return true
      end,
      read = function(path, offset, len, cb)
        local f = fs[path]
        if not f then
          cb(nil, "ENOENT")
          return
        end
        reads[#reads + 1] = { offset = offset, len = len }
        cb(f.data:sub(offset + 1, offset + len), nil)
      end,
      read_sync = function(path, len)
        local f = fs[path]
        return f and f.data:sub(1, len) or nil
      end,
    }
  end

  local function put(path, lines)
    fs[path] = { data = table.concat(lines, "\n") .. "\n", mtime = 1, ino = 1 }
  end

  local function said(role, text, ts)
    return vim.json.encode({
      type = role,
      timestamp = ts or "2026-08-02T20:19:59.000Z",
      message = { role = role, content = { { type = "text", text = text } } },
    })
  end

  local function said_plain(role, text)
    return vim.json.encode({
      type = role,
      timestamp = "2026-08-02T20:19:59.000Z",
      message = { role = role, content = text },
    })
  end

  local function bash_line(stdout)
    return vim.json.encode({
      type = "user",
      timestamp = "2026-08-02T20:22:00.000Z",
      toolUseResult = { stdout = stdout, stderr = "", interrupted = false },
    })
  end

  local function tool_use(name, input)
    return vim.json.encode({
      type = "assistant",
      timestamp = "2026-08-02T20:24:00.000Z",
      message = { role = "assistant", content = { { type = "tool_use", name = name, input = input } } },
    })
  end

  local function edit_line(file)
    return vim.json.encode({
      type = "user",
      timestamp = "2026-08-02T20:23:00.000Z",
      toolUseResult = { filePath = file, structuredPatch = {} },
    })
  end

  ---Scan a transcript and hand back the matches (the fake `_io` never defers).
  local function scan(path, query, limit)
    local matcher = transcript.compile_query(query)
    local out, called = nil, false
    transcript.search(path, matcher, { limit = limit or 3 }, function(matches)
      out, called = matches, true
    end)
    assert.is_true(called, "search() did not answer synchronously")
    return out
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    fs, reads = {}, {}

    -- The mock's decoder is a stub; the busted setup ships a real one.
    local real_decode = _G.json_decode
    vim.json.decode = function(str)
      return real_decode(str)
    end

    package.loaded["claudecode.agents.transcript"] = nil
    package.loaded["claudecode.agents.search"] = nil
    transcript = require("claudecode.agents.transcript")
    search = require("claudecode.agents.search")
    install_io()
  end)

  describe("compile_query", function()
    it("refuses an empty query", function()
      assert.is_nil(transcript.compile_query(""))
      assert.is_nil(transcript.compile_query(nil))
    end)

    it("ignores case until the query uses some", function()
      local lower = transcript.compile_query("handshake")
      assert.is_not_nil(lower.find("The HANDSHAKE failed"))
      assert.is_not_nil(lower.find("the handshake failed"))

      local upper = transcript.compile_query("Handshake")
      assert.is_nil(upper.find("the handshake failed"))
      assert.is_not_nil(upper.find("the Handshake failed"))
    end)

    it("matches literally, so punctuation is not a pattern", function()
      local dotted = transcript.compile_query("init.lua")
      assert.is_not_nil(dotted.find("lua/claudecode/init.lua"))
      -- `.` as a pattern would match the `t` here; as a literal it must not.
      assert.is_nil(dotted.find("initXlua"))

      local dashed = transcript.compile_query("a-b")
      assert.is_not_nil(dashed.find("an a-b pair"))
    end)

    it("reports where the match is", function()
      local matcher = transcript.compile_query("token")
      local s, e = matcher.find("auth token here")
      assert.are_equal(6, s)
      assert.are_equal(10, e)
    end)
  end)

  describe("_snippet", function()
    it("shows the line the match is on, not the whole message", function()
      local text = "first line\nthe auth token lives here\nthird line"
      local s = text:find("token")
      local snippet, col, len = transcript._snippet(text, s, s + 4)
      assert.are_equal("the auth token lives here", snippet)
      assert.are_equal("token", snippet:sub(col + 1, col + len))
    end)

    it("drops the indent a line carries", function()
      local text = "        indented mention of token"
      local s = text:find("token")
      local snippet, col, len = transcript._snippet(text, s, s + 4)
      assert.are_equal("indented mention of token", snippet)
      assert.are_equal("token", snippet:sub(col + 1, col + len))
    end)

    it("cuts a long line around the match, keeping the offset right", function()
      local text = string.rep("x", 400) .. " token " .. string.rep("y", 400)
      local s = text:find("token")
      local snippet, col, len = transcript._snippet(text, s, s + 4, 40)
      assert.is_true(#snippet <= 40 + 8, "snippet was not windowed: " .. #snippet)
      assert.are_equal("token", snippet:sub(col + 1, col + len))
      assert.is_not_nil(snippet:find("…", 1, true))
    end)

    it("never cuts a UTF-8 sequence in half", function()
      local text = string.rep("ö", 200) .. " token " .. string.rep("ü", 200)
      local s = text:find("token")
      local snippet = transcript._snippet(text, s, s + 4, 40)
      assert.are_equal(vim.fn.strchars and snippet or snippet, snippet)
      -- Every byte is either ASCII, a lead byte, or a continuation that follows
      -- one: a half sequence would break this walk.
      local i, ok = 1, true
      while i <= #snippet do
        local byte = snippet:byte(i)
        local need = (byte < 0x80 and 1) or (byte >= 0xF0 and 4) or (byte >= 0xE0 and 3) or (byte >= 0xC0 and 2) or 0
        if need == 0 or i + need - 1 > #snippet then
          ok = false
          break
        end
        i = i + need
      end
      assert.is_true(ok, "snippet held a partial UTF-8 sequence")
    end)
  end)

  describe("search", function()
    it("finds what was said, on both sides of the conversation", function()
      put("/s/a.jsonl", {
        said("user", "please fix the websocket handshake"),
        said("assistant", "the handshake now sends the auth header"),
      })
      local matches = scan("/s/a.jsonl", "handshake")
      assert.are_equal(2, #matches)
      assert.are_equal("user", matches[1].role)
      assert.are_equal("assistant", matches[2].role)
      assert.are_equal("message", matches[1].kind)
    end)

    it("reads a message whose content is a plain string", function()
      put("/s/a.jsonl", { said_plain("user", "about the lockfile") })
      assert.are_equal(1, #scan("/s/a.jsonl", "lockfile"))
    end)

    it("does not search tool output", function()
      put("/s/a.jsonl", { bash_line("handshake handshake handshake") })
      assert.are_equal(0, #scan("/s/a.jsonl", "handshake"))
    end)

    it("does search the paths a session touched", function()
      put("/s/a.jsonl", { edit_line("/proj/lua/claudecode/lockfile.lua") })
      local matches = scan("/s/a.jsonl", "lockfile")
      assert.are_equal(1, #matches)
      assert.are_equal("file", matches[1].kind)
      assert.are_equal("/proj/lua/claudecode/lockfile.lua", matches[1].text)
    end)

    it("searches what a turn was thinking", function()
      put("/s/a.jsonl", {
        vim.json.encode({
          type = "assistant",
          timestamp = "2026-08-02T20:19:59.000Z",
          message = {
            role = "assistant",
            content = { { type = "thinking", thinking = "the handshake must send the header", signature = "x" } },
          },
        }),
      })
      local matches = scan("/s/a.jsonl", "handshake")
      assert.are_equal(1, #matches)
      assert.are_equal("thinking", matches[1].kind)
    end)

    it("searches what a tool was called with", function()
      put("/s/a.jsonl", { tool_use("Bash", { command = "git commit -m 'fix the handshake'" }) })
      local matches = scan("/s/a.jsonl", "handshake")
      assert.are_equal(1, #matches)
      assert.are_equal("tool", matches[1].kind)
      assert.are_equal("Bash", matches[1].tool)
      assert.are_equal("command", matches[1].field)
    end)

    it("does not repeat a path the tool result already reports", function()
      put("/s/a.jsonl", {
        tool_use("Read", { file_path = "/proj/lockfile.lua" }),
        edit_line("/proj/lockfile.lua"),
      })
      local matches = scan("/s/a.jsonl", "lockfile")
      assert.are_equal(1, #matches)
      assert.are_equal("file", matches[1].kind)
    end)

    it("gives what was said first claim on a small cap", function()
      -- One entry carrying all three, and room for two: the message and the tool
      -- call, not the reasoning.
      put("/s/a.jsonl", {
        vim.json.encode({
          type = "assistant",
          timestamp = "2026-08-02T20:19:59.000Z",
          message = {
            role = "assistant",
            content = {
              { type = "thinking", thinking = "token, thinking about it" },
              { type = "tool_use", name = "Bash", input = { command = "grep token" } },
              { type = "text", text = "the token is in the lock file" },
            },
          },
        }),
      })
      local matches = scan("/s/a.jsonl", "token", 2)
      assert.are_equal(2, #matches)
      assert.are_equal("message", matches[1].kind)
      assert.are_equal("tool", matches[2].kind)
    end)

    it("ranks across the whole file, not within an entry", function()
      -- The real shape of the problem, measured on this project's own store:
      -- "windows" matches 26 thinking lines and 6 message lines. Reasoning comes
      -- first here, and must still not take the row the sentence deserves.
      local lines = {}
      for index = 1, 10 do
        lines[index] = vim.json.encode({
          type = "assistant",
          timestamp = "2026-08-02T20:19:5" .. (index % 10) .. ".000Z",
          message = { role = "assistant", content = { { type = "thinking", thinking = "token " .. index } } },
        })
      end
      lines[#lines + 1] = said("user", "the token goes in the lock file")
      put("/s/a.jsonl", lines)

      local matches = scan("/s/a.jsonl", "token", 3)
      assert.are_equal("message", matches[1].kind)
      assert.are_equal("thinking", matches[2].kind)
    end)

    it("puts a path above a tool call above reasoning", function()
      put("/s/a.jsonl", {
        vim.json.encode({
          type = "assistant",
          timestamp = "2026-08-02T20:19:59.000Z",
          message = { role = "assistant", content = { { type = "thinking", thinking = "about token" } } },
        }),
        tool_use("Bash", { command = "grep token" }),
        edit_line("/proj/token.lua"),
      })
      local matches = scan("/s/a.jsonl", "token", 3)
      assert.are_same({ "file", "tool", "thinking" }, { matches[1].kind, matches[2].kind, matches[3].kind })
    end)

    it("reads a tool's fields in a stable order", function()
      local order = transcript._tool_fields({ zebra = "z", command = "c", alpha = "a", file_path = "/x", count = 3 })
      assert.are_same({ "command", "alpha", "zebra" }, order)
    end)

    it("stops at the limit rather than reading the rest of the file", function()
      local lines = {}
      for index = 1, 20 do
        lines[index] = said("user", "mention " .. index .. " of token")
      end
      local matches = scan("/s/a.jsonl", "token", 2)
      assert.are_equal(0, #matches) -- nothing written yet
      put("/s/a.jsonl", lines)
      matches = scan("/s/a.jsonl", "token", 2)
      assert.are_equal(2, #matches)
    end)

    it("answers nothing for a missing transcript", function()
      assert.are_equal(0, #scan("/s/gone.jsonl", "token"))
    end)

    it("stays silent once cancelled", function()
      put("/s/a.jsonl", { said("user", "token") })
      local matcher = transcript.compile_query("token")

      -- The fake I/O answers inline everywhere else, which leaves no moment for a
      -- cancel to land in. So this one read is held: a scan is in flight, the
      -- next keystroke cancels it, and only then does the chunk come back.
      local plain_read = transcript._io.read
      local pending = nil
      transcript._io.read = function(path, offset, len, cb)
        pending = function()
          plain_read(path, offset, len, cb)
        end
      end

      local called = false
      local job = transcript.search("/s/a.jsonl", matcher, { limit = 3 }, function()
        called = true
      end)
      transcript._io.read = plain_read
      job.cancel()
      assert.is_not_nil(pending, "the scan never read anything")
      pending()
      assert.is_false(called, "a cancelled scan answered anyway")
    end)

    it("skips a line too large to be conversation", function()
      put("/s/a.jsonl", {
        vim.json.encode({
          type = "assistant",
          timestamp = "2026-08-02T20:19:59.000Z",
          message = { role = "assistant", content = { { type = "text", text = string.rep("token ", 60000) } } },
        }),
      })
      assert.are_equal(0, #scan("/s/a.jsonl", "token"))
    end)
  end)

  describe("closing", function()
    -- Closing a window does not end insert mode, so the picker's own
    -- `startinsert` outlived it and landed in the sessions pane. Confirmed
    -- through a pty (a headless `-l` Neovim never enters insert at all):
    -- `in picker: i` / `after esc: i`, and `after esc: n` once this ran.
    local commands, mode, buftype
    local saved

    before_each(function()
      commands, mode, buftype = {}, "n", "nofile"
      -- Restored afterwards: these are the shared mock's own functions, and every
      -- spec after this one in the run would otherwise inherit the stubs.
      saved = { mode = vim.fn.mode, cmd = vim.cmd, option = vim.api.nvim_get_option_value }
      vim.fn.mode = function()
        return mode
      end
      vim.cmd = function(cmd)
        commands[#commands + 1] = cmd
      end
      vim.api.nvim_get_option_value = function(name)
        return name == "buftype" and buftype or nil
      end
    end)

    after_each(function()
      vim.fn.mode = saved.mode
      vim.cmd = saved.cmd
      vim.api.nvim_get_option_value = saved.option
    end)

    it("leaves the insert mode it started", function()
      mode = "i"
      assert.is_true(search._leave_insert())
      assert.are_same({ "stopinsert" }, commands)
    end)

    it("leaves normal mode alone", function()
      assert.is_false(search._leave_insert())
      assert.are_same({}, commands)
    end)

    it("never drops a terminal out of insert", function()
      -- The mirror of the bug: `<CR>` goes on to focus an agent's terminal, and
      -- the click-away path has already moved the cursor by the time this runs.
      mode = "i"
      buftype = "terminal"
      assert.is_false(search._leave_insert())
      assert.are_same({}, commands)
    end)
  end)

  describe("render", function()
    local function state(overrides)
      local base = {
        matcher = transcript.compile_query("token"),
        sessions = {
          { session_id = "one", title = "auth token work", icon = "●" },
          { session_id = "two", title = "unrelated", icon = "○" },
        },
        results = {},
        done = true,
      }
      for key, value in pairs(overrides or {}) do
        -- `false` clears a field: `matcher = nil` in a table literal is no key at
        -- all, so it could not say "there is no query" here.
        base[key] = value ~= false and value or nil
      end
      return base
    end

    it("says so when nothing matched", function()
      local lines = search.render(state())
      assert.are_equal(1, #lines)
      assert.is_not_nil(lines[1]:find("no conversation", 1, true))
    end)

    it("lists a session per match, with the row's session on every line", function()
      local st = state({
        results = {
          [2] = {
            matches = {
              { kind = "message", role = "user", text = "the token again", col = 4, len = 5 },
              { kind = "file", text = "/proj/token.lua", col = 6, len = 5 },
            },
          },
        },
      })
      local lines, _, rows = search.render(st)
      assert.are_equal(3, #lines)
      assert.is_not_nil(lines[1]:find("unrelated", 1, true))
      assert.are_equal("two", rows[1].session_id)
      assert.are_equal("two", rows[2].session_id)
      assert.are_equal("two", rows[3].session_id)
      assert.is_not_nil(lines[2]:find("you", 1, true))
      assert.is_not_nil(lines[3]:find("file", 1, true))
    end)

    it("lists a session whose title matches even with nothing in the body", function()
      local st = state({ results = { [1] = { title = { col = 5, len = 5 }, matches = {} } } })
      local lines, marks = search.render(st)
      assert.are_equal(1, #lines)
      assert.is_not_nil(lines[1]:find("auth token work", 1, true))
      local lit = false
      for _, mark in ipairs(marks) do
        if mark.hl == require("claudecode.agents.render").highlight("match") then
          lit = true
          assert.are_equal("token", lines[1]:sub(mark.col + 1, mark.end_col))
        end
      end
      assert.is_true(lit, "the matching part of the title was not highlighted")
    end)

    it("labels a match with what it was part of", function()
      assert.are_equal("you", search.label({ kind = "message", role = "user" }))
      assert.are_equal("claude", search.label({ kind = "message", role = "assistant" }))
      assert.are_equal("file", search.label({ kind = "file" }))
      assert.are_equal("think", search.label({ kind = "thinking" }))
      assert.are_equal("bash", search.label({ kind = "tool", tool = "Bash" }))
    end)

    it("waits before claiming there is nothing", function()
      local lines = search.render(state({ done = false }))
      assert.is_not_nil(lines[1]:find("searching", 1, true))
    end)

    it("invites a query when there is none", function()
      local lines = search.render(state({ matcher = false, done = false }))
      assert.is_not_nil(lines[1]:find("type to search", 1, true))
    end)
  end)
end)
