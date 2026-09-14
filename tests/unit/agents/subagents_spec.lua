-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.subagents", function()
  local transcript, subagents
  local fs, dirs

  local SESSION = "/store/proj/sess.jsonl"
  local DIR = "/store/proj/sess/subagents"
  local NOW = 1786000000 -- 2026-08-06T07:06:40Z

  local function iso(epoch)
    return os.date("!%Y-%m-%dT%H:%M:%S.000Z", epoch)
  end

  local function put(path, lines, mtime)
    local data = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
    fs[path] = { data = data, mtime = mtime or NOW, ino = 1 }
  end

  ---Register a subagent: its descriptor, and a transcript running from `first` to
  ---`last` whose newest turn reports `tokens`.
  local function agent(id, spec)
    dirs[DIR] = dirs[DIR] or {}
    table.insert(dirs[DIR], "agent-" .. id .. ".meta.json")
    table.insert(dirs[DIR], "agent-" .. id .. ".jsonl")
    put(DIR .. "/agent-" .. id .. ".meta.json", {
      vim.json.encode({
        agentType = spec.type or "general-purpose",
        description = spec.description or id,
        toolUseId = spec.tool_use_id or ("toolu_" .. id),
        parentAgentId = spec.parent,
        spawnDepth = spec.parent and 2 or 1,
        requestShape = spec.shape or "background",
      }),
    }, spec.started or (spec.first or NOW - 60))
    local lines = {
      vim.json.encode({ type = "user", timestamp = iso(spec.first or NOW - 60), agentId = id, isSidechain = true }),
    }
    if spec.tokens then
      lines[#lines + 1] = vim.json.encode({
        type = "assistant",
        timestamp = iso(spec.last or NOW - 1),
        message = {
          role = "assistant",
          content = { { type = "text", text = "working" } },
          usage = {
            input_tokens = 2,
            cache_creation_input_tokens = 100,
            cache_read_input_tokens = spec.tokens - 152,
            output_tokens = 50,
          },
        },
      })
    end
    put(DIR .. "/agent-" .. id .. ".jsonl", lines, spec.last or NOW - 1)
  end

  local function notification(id, ts, fields)
    fields = fields or {}
    return vim.json.encode({
      type = "queue-operation",
      operation = "enqueue",
      timestamp = iso(ts),
      content = table.concat({
        "<task-notification>",
        "<task-id>" .. id .. "</task-id>",
        "<status>" .. (fields.status or "completed") .. "</status>",
        "<summary>Agent finished</summary>",
        "<usage><subagent_tokens>"
          .. (fields.tokens or 1000)
          .. "</subagent_tokens><tool_uses>1</tool_uses><duration_ms>"
          .. (fields.duration_ms or 5000)
          .. "</duration_ms></usage>",
        "</task-notification>",
      }, "\n"),
    })
  end

  local function fold_all()
    subagents.refresh(SESSION)
  end

  local function rows(opts)
    fold_all()
    return subagents.rows(SESSION, vim.tbl_extend("force", { now = NOW }, opts or {}))
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    fs, dirs = {}, {}
    vim.json.decode = _G.json_decode
    package.loaded["claudecode.agents.transcript"] = nil
    package.loaded["claudecode.agents.subagents"] = nil
    transcript = require("claudecode.agents.transcript")
    subagents = require("claudecode.agents.subagents")
    transcript.reset()
    subagents.reset()
    transcript._io = {
      stat = function(path)
        local f = fs[path]
        return f and { size = #f.data, mtime = f.mtime, ino = f.ino } or nil
      end,
      scandir = function(dir)
        return dirs[dir]
      end,
      read = function(path, offset, len, cb)
        local f = fs[path]
        if not f then
          cb(nil, "ENOENT")
          return
        end
        cb(f.data:sub(offset + 1, offset + len), nil)
      end,
      read_sync = function(path, len)
        local f = fs[path]
        return f and f.data:sub(1, len) or nil
      end,
    }
    put(SESSION, {})
  end)

  describe("paths", function()
    it("finds the directory beside the session's transcript", function()
      expect(subagents.dir("/a/b/123.jsonl")).to_be("/a/b/123/subagents")
      expect(subagents.dir("/a/b/notes.txt")).to_be(nil)
    end)
  end)

  describe("the tree", function()
    it("has nothing to show for a session that started none", function()
      expect(#rows()).to_be(0)
    end)

    it("nests a subagent under the one that started it, in the order they started", function()
      agent("root", { first = NOW - 300 })
      agent("late", { first = NOW - 100 })
      agent("child1", { parent = "root", type = "Explore", first = NOW - 250 })
      agent("child2", { parent = "root", type = "Plan", first = NOW - 200 })
      agent("grandchild", { parent = "child1", type = "Explore", first = NOW - 240 })

      local out = rows({ live = true })
      local drawn = {}
      for _, row in ipairs(out) do
        drawn[#drawn + 1] = row.prefix .. row.id
      end
      expect(table.concat(drawn, "|")).to_be("root|├─child1|│ └─grandchild|└─child2|late")
      expect(out[3].depth).to_be(2)
      expect(out[2].agent_type).to_be("Explore")
    end)

    it("draws a subagent whose parent it cannot see from the top", function()
      agent("orphan", { parent = "missing" })
      local out = rows({ live = true })
      expect(#out).to_be(1)
      expect(out[1].prefix).to_be("")
    end)
  end)

  describe("where a run stands", function()
    it("is running, with its live token count, until something records an end", function()
      agent("a", { first = NOW - 90, tokens = 42000 })
      local row = rows({ live = true })[1]
      expect(row.state).to_be("running")
      expect(row.tokens).to_be(42000)
      expect(row.runtime_s).to_be(90)
    end)

    it("takes a background run's end, cost and duration from its notification", function()
      agent("a", { first = NOW - 90, last = NOW - 30, tokens = 42000 })
      put(SESSION, { notification("a", NOW - 29, { tokens = 41500, duration_ms = 61000 }) })
      local row = rows({ live = true })[1]
      expect(row.state).to_be("done")
      expect(row.tokens).to_be(41500)
      expect(row.runtime_s).to_be(61)
    end)

    it("finds a nested run's notification in its parent's transcript", function()
      agent("parent", { first = NOW - 90 })
      agent("child", { parent = "parent", first = NOW - 80, last = NOW - 70 })
      local parent_log = fs[DIR .. "/agent-parent.jsonl"]
      parent_log.data = parent_log.data .. notification("child", NOW - 69, { status = "failed" }) .. "\n"
      local out = rows({ live = true })
      expect(out[2].id).to_be("child")
      expect(out[2].state).to_be("failed")
    end)

    it("is running again once the agent writes past its last notification", function()
      -- Sent another message: the old notification belongs to the earlier stop.
      agent("a", { first = NOW - 90, last = NOW - 5, tokens = 50000 })
      put(SESSION, { notification("a", NOW - 30) })
      expect(rows({ live = true })[1].state).to_be("running")
    end)

    it("takes a foreground run's end from the Agent call's own result", function()
      agent("fg", { shape = "foreground", tool_use_id = "toolu_fg", first = NOW - 50, last = NOW - 10 })
      put(SESSION, {
        vim.json.encode({
          type = "user",
          timestamp = iso(NOW - 9),
          message = { role = "user", content = { { type = "tool_result", tool_use_id = "toolu_fg", content = "ok" } } },
          toolUseResult = { status = "completed", agentId = "fg", totalTokens = 77000, totalDurationMs = 40000 },
        }),
      })
      local row = rows({ live = true })[1]
      expect(row.state).to_be("done")
      expect(row.tokens).to_be(77000)
      expect(row.runtime_s).to_be(40)
    end)

    it("calls a foreground run the user interrupted stopped", function()
      agent("fg", { shape = "foreground", tool_use_id = "toolu_fg", first = NOW - 50, last = NOW - 10 })
      put(SESSION, {
        vim.json.encode({
          type = "assistant",
          timestamp = iso(NOW - 50),
          message = {
            role = "assistant",
            content = { { type = "tool_use", id = "toolu_fg", name = "Agent", input = {} } },
          },
        }),
        vim.json.encode({
          type = "user",
          timestamp = iso(NOW - 8),
          message = { role = "user", content = "[Request interrupted by user for tool use]" },
        }),
      })
      expect(rows({ live = true })[1].state).to_be("stopped")
    end)

    it("calls an unfinished run stopped once nothing could still be running it", function()
      -- The session is not live here and the transcript went quiet long ago: its
      -- CLI exited without notifying anyone.
      agent("a", { first = NOW - 7200, last = NOW - 3600, tokens = 1000 })
      local row = rows({ live = false })[1]
      expect(row.state).to_be("stopped")
      expect(row.runtime_s).to_be(3600)
    end)

    it("trusts a recently written transcript even when the session is not known to be live", function()
      agent("a", { first = NOW - 60, last = NOW - 5 })
      expect(rows({ live = false })[1].state).to_be("running")
    end)
  end)

  describe("formatting", function()
    it("shortens token counts", function()
      expect(subagents.format_tokens(nil)).to_be("·")
      expect(subagents.format_tokens(812)).to_be("812")
      expect(subagents.format_tokens(9127)).to_be("9.1k")
      expect(subagents.format_tokens(9000)).to_be("9k")
      expect(subagents.format_tokens(167410)).to_be("167k")
      expect(subagents.format_tokens(1240000)).to_be("1.2M")
    end)

    it("reads runtimes as a clock", function()
      expect(subagents.format_runtime(nil)).to_be("·")
      expect(subagents.format_runtime(51.9)).to_be("0:51")
      expect(subagents.format_runtime(830.519)).to_be("13:50")
      expect(subagents.format_runtime(3723)).to_be("1:02:03")
    end)
  end)
end)
