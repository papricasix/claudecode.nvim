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

  describe("background shells", function()
    local TASKS = "/tmp/claude-501/-proj/sess/tasks"

    local function shell_call(id, ts, input)
      return vim.json.encode({
        type = "assistant",
        timestamp = iso(ts),
        message = { role = "assistant", content = { { type = "tool_use", id = id, name = "Bash", input = input } } },
      })
    end

    local function shell_result(id, ts, task_id, extra)
      local text = task_id
          and ("Command running in background with ID: " .. task_id .. ". Output is being written to: " .. TASKS .. "/" .. task_id .. ".output. You will be notified when it completes.")
        or "hello"
      local result =
        { stdout = task_id and "" or "hello", stderr = "", interrupted = false, backgroundTaskId = task_id }
      for key, value in pairs(extra or {}) do
        result[key] = value
      end
      return vim.json.encode({
        type = "user",
        timestamp = iso(ts),
        message = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = text } } },
        toolUseResult = result,
      })
    end

    local function shell_note(task_id, tool_id, ts, status, summary)
      return vim.json.encode({
        type = "queue-operation",
        operation = "enqueue",
        timestamp = iso(ts),
        content = table.concat({
          "<task-notification>",
          "<task-id>" .. task_id .. "</task-id>",
          "<tool-use-id>" .. tool_id .. "</tool-use-id>",
          "<output-file>" .. TASKS .. "/" .. task_id .. ".output</output-file>",
          "<status>" .. status .. "</status>",
          "<summary>" .. summary .. "</summary>",
          "</task-notification>",
        }, "\n"),
      })
    end

    it("lists a command sent to the background, with where its output goes", function()
      put(SESSION, {
        shell_call(
          "toolu_bg",
          NOW - 100,
          { command = "make   build", description = "Build it", run_in_background = true }
        ),
        shell_result("toolu_bg", NOW - 99, "b1"),
      })
      fs[TASKS .. "/b1.output"] = { data = "compiling\n", mtime = NOW - 2, ino = 9 }
      local out = rows({ live = true })
      expect(#out).to_be(1)
      expect(out[1].kind).to_be("shell")
      expect(out[1].id).to_be("b1")
      expect(out[1].description).to_be("Build it")
      expect(out[1].command).to_be("make build")
      expect(out[1].tool_id).to_be("toolu_bg")
      expect(out[1].state).to_be("running")
      expect(out[1].runtime_s).to_be(99)
      expect(out[1].output_path).to_be(TASKS .. "/b1.output")
      expect(out[1].transcript).to_be(SESSION)
    end)

    it("leaves out a command that ran in the foreground", function()
      put(SESSION, {
        shell_call("toolu_fg", NOW - 100, { command = "ls" }),
        shell_result("toolu_fg", NOW - 99, nil),
      })
      expect(#rows({ live = true })).to_be(0)
    end)

    it("takes the end and the exit code from its notification", function()
      put(SESSION, {
        shell_call("toolu_ok", NOW - 100, { command = "true", run_in_background = true }),
        shell_result("toolu_ok", NOW - 100, "bok"),
        shell_call("toolu_bad", NOW - 90, { command = "false", run_in_background = true }),
        shell_result("toolu_bad", NOW - 90, "bbad"),
        shell_call("toolu_kill", NOW - 80, { command = "sleep 99", run_in_background = true }),
        shell_result("toolu_kill", NOW - 80, "bkill"),
        shell_note("bok", "toolu_ok", NOW - 40, "completed", 'Background command "true" completed (exit code 0)'),
        shell_note("bbad", "toolu_bad", NOW - 80, "failed", 'Background command "false" failed with exit code 144'),
        shell_note("bkill", "toolu_kill", NOW - 20, "killed", 'Background command "sleep 99" was stopped'),
      })
      local by_id = {}
      for _, row in ipairs(rows({ live = true })) do
        by_id[row.id] = row
      end
      expect(by_id.bok.state).to_be("done")
      expect(by_id.bok.exit_code).to_be(0)
      expect(by_id.bok.runtime_s).to_be(60)
      expect(by_id.bok.ended).to_be(true)
      expect(by_id.bbad.state).to_be("failed")
      expect(by_id.bbad.exit_code).to_be(144)
      expect(by_id.bkill.state).to_be("stopped")
    end)

    it("nests a subagent's shells under it, in start order with its own subagents", function()
      agent("worker", { first = NOW - 300 })
      agent("helper", { parent = "worker", first = NOW - 200 })
      local log = fs[DIR .. "/agent-worker.jsonl"]
      log.data = log.data
        .. shell_call("toolu_s", NOW - 250, { command = "npm test", run_in_background = true })
        .. "\n"
        .. shell_result("toolu_s", NOW - 250, "bsub")
        .. "\n"
      local out = rows({ live = true })
      local drawn = {}
      for _, row in ipairs(out) do
        drawn[#drawn + 1] = row.prefix .. row.id
      end
      expect(table.concat(drawn, "|")).to_be("worker|├─bsub|└─helper")
      expect(out[2].transcript).to_be(DIR .. "/agent-worker.jsonl")
    end)

    it("records a command sent to the background with Ctrl+B", function()
      put(SESSION, {
        shell_call("toolu_b", NOW - 100, { command = "cargo build" }),
        shell_result("toolu_b", NOW - 60, "bctl", { backgroundedByUser = true }),
      })
      fs[TASKS .. "/bctl.output"] = { data = "", mtime = NOW, ino = 9 }
      local row = rows({ live = true })[1]
      expect(row.id).to_be("bctl")
      expect(row.by_user).to_be(true)
      expect(row.runtime_s).to_be(60)
    end)

    it("is not running once its output file is gone, even in a live session", function()
      put(SESSION, {
        shell_call("toolu_bg", NOW - 100, { command = "sleep 1", run_in_background = true }),
        shell_result("toolu_bg", NOW - 99, "bgone"),
      })
      expect(rows({ live = true })[1].state).to_be("stopped")
    end)

    it("reads a quiet shell in a session not known to be live as stopped", function()
      put(SESSION, {
        shell_call("toolu_bg", NOW - 7200, { command = "watch", run_in_background = true }),
        shell_result("toolu_bg", NOW - 7200, "bquiet"),
      })
      fs[TASKS .. "/bquiet.output"] = { data = "", mtime = NOW - 3600, ino = 9 }
      expect(rows({ live = false })[1].state).to_be("stopped")
      fs[TASKS .. "/bquiet.output"].mtime = NOW - 5
      expect(rows({ live = false })[1].state).to_be("running")
    end)

    it("calls a shell stopped with TaskStop stopped, though no notification comes", function()
      put(SESSION, {
        shell_call("toolu_bg", NOW - 100, { command = "sleep 300", run_in_background = true }),
        shell_result("toolu_bg", NOW - 100, "bstop"),
        vim.json.encode({
          type = "user",
          timestamp = iso(NOW - 90),
          message = { role = "user", content = { { type = "tool_result", tool_use_id = "toolu_s", content = "ok" } } },
          toolUseResult = {
            message = "Successfully stopped task: bstop (sleep 300)",
            task_id = "bstop",
            task_type = "local_bash",
          },
        }),
      })
      fs[TASKS .. "/bstop.output"] = { data = "", mtime = NOW, ino = 9 }
      local row = rows({ live = true })[1]
      expect(row.state).to_be("stopped")
      expect(row.how).to_be("killed")
      expect(row.runtime_s).to_be(10)
      expect(row.ended).to_be(true)
    end)

    it("reads how a task ended from the line the CLI closes its output with", function()
      put(SESSION, {
        shell_call("toolu_a", NOW - 100, { command = "a", run_in_background = true }),
        shell_result("toolu_a", NOW - 100, "bexit"),
        shell_call("toolu_k", NOW - 100, { command = "k", run_in_background = true }),
        shell_result("toolu_k", NOW - 100, "bkilled"),
      })
      transcript._io.read_tail_sync = function(path, len)
        local f = fs[path]
        return f and f.data:sub(-len) or nil
      end
      fs[TASKS .. "/bexit.output"] = { data = "out\n\n[exited with code 7]\n", mtime = NOW - 50, ino = 9 }
      fs[TASKS .. "/bkilled.output"] = { data = "out\n\n[killed]\n", mtime = NOW - 40, ino = 10 }
      local by_id = {}
      for _, row in ipairs(rows({ live = true })) do
        by_id[row.id] = row
      end
      expect(by_id.bexit.state).to_be("failed")
      expect(by_id.bexit.exit_code).to_be(7)
      expect(by_id.bexit.runtime_s).to_be(50)
      expect(by_id.bkilled.state).to_be("stopped")
      expect(by_id.bkilled.ended).to_be(true)
    end)

    describe("monitors", function()
      local function monitor_call(id, ts, input)
        return vim.json.encode({
          type = "assistant",
          timestamp = iso(ts),
          message = {
            role = "assistant",
            content = { { type = "tool_use", id = id, name = "Monitor", input = input } },
          },
        })
      end

      local function monitor_result(id, ts, task_id)
        return vim.json.encode({
          type = "user",
          timestamp = iso(ts),
          message = {
            role = "user",
            content = {
              { type = "tool_result", tool_use_id = id, content = "Monitor started (task " .. task_id .. ")" },
            },
          },
          toolUseResult = { taskId = task_id, timeoutMs = 60000, persistent = false },
        })
      end

      local function event(task_id, ts, text, queued)
        local body = table.concat({
          "<task-notification>",
          "<task-id>" .. task_id .. "</task-id>",
          '<summary>Monitor event: "x"</summary>',
          "<event>" .. text .. "</event>",
          "</task-notification>",
        }, "\n")
        if queued == false then
          return vim.json.encode({ type = "user", timestamp = iso(ts), message = { role = "user", content = body } })
        end
        return vim.json.encode({ type = "queue-operation", operation = "enqueue", timestamp = iso(ts), content = body })
      end

      it("lists a monitor, counts its events, and does not end it on one", function()
        put(SESSION, {
          shell_call("toolu_bg", NOW - 200, { command = "make", run_in_background = true }),
          shell_result("toolu_bg", NOW - 200, "bshell"),
          monitor_call(
            "toolu_m",
            NOW - 100,
            { command = "tail -f log | grep ERROR", description = "errors in log", timeout_ms = 60000 }
          ),
          monitor_result("toolu_m", NOW - 100, "bmon"),
          event("bmon", NOW - 80, "ERROR one"),
          event("bmon", NOW - 80, "ERROR one", false), -- the delivered copy is not a second event
          event("bmon", NOW - 60, "ERROR two"),
        })
        -- The monitor's result names no output path; the shell's does, and it is the same directory.
        fs[TASKS .. "/bmon.output"] = { data = "ERROR one\n", mtime = NOW - 1, ino = 11 }
        local out = rows({ live = true })
        local mon = out[2]
        expect(mon.id).to_be("bmon")
        expect(mon.task_type).to_be("monitor")
        expect(mon.description).to_be("errors in log")
        expect(mon.command).to_be("tail -f log | grep ERROR")
        expect(mon.events).to_be(2)
        expect(mon.state).to_be("running")
        expect(mon.output_path).to_be(TASKS .. "/bmon.output")
        expect(out[1].task_type).to_be("shell")
      end)

      it("calls a monitor that expired stopped, and one whose script failed failed", function()
        put(SESSION, {
          monitor_call("toolu_e", NOW - 100, { command = "sleep 100", description = "e" }),
          monitor_result("toolu_e", NOW - 100, "bexp"),
          event(
            "bexp",
            NOW - 40,
            "[Monitor expired after 1m with 0 events delivered. Re-arm it if you still need the watch.]"
          ),
          monitor_call("toolu_f", NOW - 100, { command = "false", description = "f" }),
          monitor_result("toolu_f", NOW - 100, "bfail"),
          shell_note("bfail", "toolu_f", NOW - 90, "failed", 'Monitor "f" script failed (exit 2)'),
        })
        local by_id = {}
        for _, row in ipairs(rows({ live = true })) do
          by_id[row.id] = row
        end
        expect(by_id.bexp.state).to_be("stopped")
        expect(by_id.bexp.how).to_be("expired")
        expect(by_id.bexp.events).to_be(0)
        expect(by_id.bexp.runtime_s).to_be(60)
        expect(by_id.bfail.state).to_be("failed")
        expect(by_id.bfail.exit_code).to_be(2)
      end)

      it("keeps a recorded end over the stopped a resumed CLI writes for it", function()
        local resumed = function(task_id, tool_id, ts)
          return shell_note(
            task_id,
            tool_id,
            ts,
            "stopped",
            "Background shell command didn't finish before the previous session ended"
          )
        end
        put(SESSION, {
          monitor_call("toolu_e", NOW - 100, { command = "sleep 100", description = "e" }),
          monitor_result("toolu_e", NOW - 100, "bexp"),
          event(
            "bexp",
            NOW - 95,
            "[Monitor expired after 5s with 1 event delivered. Re-arm it if you still need the watch.]"
          ),
          resumed("bexp", "toolu_e", NOW - 10),
          shell_call("toolu_q", NOW - 100, { command = "watch", run_in_background = true }),
          shell_result("toolu_q", NOW - 100, "bquiet"),
          resumed("bquiet", "toolu_q", NOW - 10),
        })
        fs[TASKS .. "/bquiet.output"] = { data = "x\n", mtime = NOW - 70, ino = 12 }
        local by_id = {}
        for _, row in ipairs(rows({ live = true })) do
          by_id[row.id] = row
        end
        expect(by_id.bexp.how).to_be("expired")
        expect(by_id.bexp.runtime_s).to_be(5)
        -- Nothing else recorded its end: the resume's word stands, dated by the file.
        expect(by_id.bquiet.state).to_be("stopped")
        expect(by_id.bquiet.how).to_be("orphaned")
        expect(by_id.bquiet.runtime_s).to_be(30)
      end)

      describe("workflow runs", function()
        local BASE = "/store/proj/sess"
        local RUN = BASE .. "/subagents/workflows/wf_1"

        local function launch(ts)
          return {
            vim.json.encode({
              type = "assistant",
              timestamp = iso(ts),
              message = {
                role = "assistant",
                content = { { type = "tool_use", id = "toolu_wf", name = "Workflow", input = { script = "…" } } },
              },
            }),
            vim.json.encode({
              type = "user",
              timestamp = iso(ts),
              message = {
                role = "user",
                content = {
                  { type = "tool_result", tool_use_id = "toolu_wf", content = "Workflow launched in background." },
                },
              },
              toolUseResult = {
                status = "async_launched",
                taskId = "wtask",
                taskType = "local_workflow",
                workflowName = "review-changes",
                runId = "wf_1",
                summary = "Review the diff",
                transcriptDir = RUN,
              },
            }),
          }
        end

        local function run_agent(id, label, phase, ts)
          dirs[RUN] = dirs[RUN] or {}
          table.insert(dirs[RUN], "agent-" .. id .. ".meta.json")
          put(RUN .. "/agent-" .. id .. ".meta.json", {
            vim.json.encode({ agentType = "workflow-subagent", description = label, workflowPhase = phase }),
          }, ts)
          put(RUN .. "/agent-" .. id .. ".jsonl", {
            vim.json.encode({ type = "user", timestamp = iso(ts), agentId = id }),
          }, ts)
        end

        it("lists a running run with its agents under it, from the journal", function()
          put(SESSION, launch(NOW - 60))
          run_agent("a1", "find bugs", "Review", NOW - 50)
          run_agent("a2", "verify", "Verify", NOW - 40)
          put(RUN .. "/journal.jsonl", {
            '{"type":"launched"}',
            '{"type":"started","agentId":"a1","label":"find bugs","phase":"Review"}',
            '{"type":"result","agentId":"a1","result":"ok"}',
            '{"type":"started","agentId":"a2","label":"verify","phase":"Verify"}',
          }, NOW - 5)
          local out = rows({ live = true })
          local drawn = {}
          for _, row in ipairs(out) do
            drawn[#drawn + 1] = row.prefix .. row.id .. ":" .. row.state
          end
          expect(table.concat(drawn, "|")).to_be("wtask:running|├─a1:done|└─a2:running")
          expect(out[1].kind).to_be("workflow")
          expect(out[1].agent_type).to_be("review-changes")
          expect(out[1].description).to_be("Review the diff")
          expect(out[1].agents).to_be(2)
          expect(out[2].description).to_be("find bugs")
          expect(out[2].phase).to_be("Review")
          expect(out[2].workflow).to_be("wtask")
          expect(out[2].path).to_be(RUN .. "/agent-a1.jsonl")
        end)

        it("takes the end from the run record, and calls an agent it cut off stopped", function()
          put(SESSION, launch(NOW - 60))
          run_agent("a1", "count", "Count", NOW - 50)
          put(RUN .. "/journal.jsonl", {
            '{"type":"started","agentId":"a1","label":"count","phase":"Count"}',
          }, NOW - 40)
          put(BASE .. "/workflows/wf_1.json", {
            vim.json.encode({
              status = "killed",
              durationMs = 29000,
              totalTokens = 62531,
              workflowProgress = {
                { type = "workflow_agent", agentId = "a1", state = "progress", tokens = 62531 },
              },
            }),
          }, NOW - 30)
          local out = rows({ live = true })
          expect(out[1].state).to_be("stopped")
          expect(out[1].runtime_s).to_be(29)
          expect(out[1].tokens).to_be(62531)
          expect(out[2].state).to_be("stopped")
          expect(out[2].tokens).to_be(62531)
        end)

        it("prefers the notification's figures, and reads a stop with no record from TaskStop", function()
          local lines = launch(NOW - 60)
          lines[#lines + 1] = vim.json.encode({
            type = "queue-operation",
            operation = "enqueue",
            timestamp = iso(NOW - 10),
            content = '<task-notification>\n<task-id>wtask</task-id>\n<status>failed</status>\n<summary>Dynamic workflow "x" failed: boom</summary>\n<usage><subagent_tokens>900</subagent_tokens><duration_ms>12000</duration_ms></usage>\n</task-notification>',
          })
          put(SESSION, lines)
          local row = rows({ live = true })[1]
          expect(row.state).to_be("failed")
          expect(row.tokens).to_be(900)
          expect(row.runtime_s).to_be(12)

          local stopped = launch(NOW - 60)
          stopped[#stopped + 1] = vim.json.encode({
            type = "user",
            timestamp = iso(NOW - 20),
            message = { role = "user", content = { { type = "tool_result", tool_use_id = "toolu_s", content = "ok" } } },
            toolUseResult = {
              message = "Successfully stopped task: wtask (x)",
              task_id = "wtask",
              task_type = "local_workflow",
            },
          })
          put(SESSION, stopped)
          transcript.reset()
          row = rows({ live = true })[1]
          expect(row.state).to_be("stopped")
          expect(row.how).to_be("killed")
        end)
      end)

      it("names a WebSocket monitor by its URL", function()
        put(SESSION, {
          monitor_call("toolu_w", NOW - 10, { ws = { url = "wss://events.example/stream" }, description = "deploys" }),
          monitor_result("toolu_w", NOW - 10, "bws"),
        })
        expect(rows({ live = true })[1].command).to_be("wss://events.example/stream")
      end)
    end)

    it("unescapes a Windows output path", function()
      put(SESSION, {
        vim.json.encode({
          type = "assistant",
          timestamp = iso(NOW - 10),
          message = {
            role = "assistant",
            content = { { type = "tool_use", id = "toolu_w", name = "PowerShell", input = { command = "dir" } } },
          },
        }),
        -- As the CLI writes it: the separators JSON-escaped, doubled on disk.
        '{"type":"user","timestamp":"'
          .. iso(NOW - 9)
          .. '","message":{"content":[{"tool_use_id":"toolu_w","type":"tool_result","content":"Command running in background with ID: bw. Output is being written to: C:\\\\Users\\\\me\\\\tasks\\\\bw.output. You will be notified"}]},"toolUseResult":{"stdout":"","backgroundTaskId":"bw"}}',
      })
      local row = rows({ live = true })[1]
      expect(row.output_path).to_be("C:\\Users\\me\\tasks\\bw.output")
      expect(row.agent_type).to_be("PowerShell")
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
