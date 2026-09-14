-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.subagent_view", function()
  local view

  local function assistant(blocks)
    return vim.json.encode({ type = "assistant", message = { role = "assistant", content = blocks } })
  end

  local function user(content, extra)
    local entry = { type = "user", message = { role = "user", content = content } }
    for key, value in pairs(extra or {}) do
      entry[key] = value
    end
    return vim.json.encode(entry)
  end

  local function result(id, content, tool_use_result, is_error)
    return user(
      { { type = "tool_result", tool_use_id = id, content = content, is_error = is_error } },
      { toolUseResult = tool_use_result }
    )
  end

  local function fold(lines)
    local doc = view.new_doc()
    for _, line in ipairs(lines) do
      view.fold_line(doc, line)
    end
    return doc
  end

  local function ctx(extra)
    return vim.tbl_extend("force", {
      row = {
        id = "a",
        agent_type = "general-purpose",
        description = "Find the bug",
        state = "done",
        tokens = 49000,
        runtime_s = 7,
      },
      children = {},
      by_id = {},
      cwd = "/proj",
    }, extra or {})
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    vim.json.decode = _G.json_decode
    package.loaded["claudecode.agents.subagent_view"] = nil
    view = require("claudecode.agents.subagent_view")
  end)

  describe("folding", function()
    it("reads the prompt, what was said, the reasoning and the calls in order", function()
      local doc = fold({
        user("Find the bug in parser.lua"),
        vim.json.encode({ type = "attachment" }),
        assistant({ { type = "thinking", thinking = "Look at the parser first." } }),
        assistant({ { type = "tool_use", id = "t1", name = "Read", input = { file_path = "/proj/parser.lua" } } }),
        result("t1", "irrelevant", { type = "text", file = { filePath = "/proj/parser.lua", numLines = 42 } }),
        assistant({ { type = "text", text = "The bug is on line 3." } }),
      })
      local kinds = {}
      for _, item in ipairs(doc.items) do
        kinds[#kinds + 1] = item.kind
      end
      expect(table.concat(kinds, ",")).to_be("prompt,thinking,tool,text")
      expect(doc.items[3].path).to_be("/proj/parser.lua")
      expect(doc.results.t1.summary).to_be("42 lines")
    end)

    it("tells a later message from the harness speaking as the user", function()
      local doc = fold({
        user("Do the thing"),
        user("[Your previous response had no visible output]"),
        user("Also check the tests"),
        user("[Request interrupted by user for tool use]"),
      })
      expect(doc.items[2].kind).to_be("system")
      expect(doc.items[3].kind).to_be("message")
      expect(doc.items[4].kind).to_be("interrupt")
    end)

    it("reads a finished child from its notification", function()
      local note = table.concat({
        "<task-notification>",
        "<task-id>child1</task-id>",
        "<status>completed</status>",
        '<summary>Agent "Test subagent" finished</summary>',
        "<usage><subagent_tokens>9127</subagent_tokens><duration_ms>1053</duration_ms></usage>",
        "</task-notification>",
      }, "\n")
      local doc = fold({ user("go"), user(note) })
      expect(doc.items[2].kind).to_be("note")
      expect(doc.items[2].id).to_be("child1")
      expect(doc.items[2].tokens).to_be(9127)
    end)

    it("summarises a result too large to decode from its raw text", function()
      local big = result("t9", string.rep("x", 300 * 1024), { stdout = "" }, true)
      local doc = fold({ big })
      expect(doc.results.t9.status).to_be("error")
      expect(doc.results.t9.summary).to_be("large output")
    end)
  end)

  describe("summaries", function()
    it("says how a call went in a word or two", function()
      local function summary(content, tool_use_result, is_error)
        return view.summarize_result({ content = content, is_error = is_error }, tool_use_result).summary
      end
      expect(summary("", { stdout = "a\nb\nc\n", stderr = "" })).to_be("3 lines")
      expect(summary("", { stdout = "" })).to_be("no output")
      expect(summary("", {
        filePath = "/p/x.lua",
        structuredPatch = { { lines = { "+a", "+b", "-c", " d" } } },
      })).to_be("+2 -1")
      expect(summary("", { totalTokens = 77000, totalDurationMs = 4000 })).to_be("77k tokens")
      expect(summary("", { status = "async_launched", agentId = "x" })).to_be("started in the background")
      expect(summary("Exit code 1\nboom", nil, true)).to_be("Exit code 1")
      expect(view.summarize_result({
        content = "The user doesn't want to proceed with this tool use.",
        is_error = true,
      }).status).to_be("rejected")
    end)
  end)

  describe("rendering", function()
    it("heads the page with the whole purpose and what the run is", function()
      local lines = view.render(fold({ user("go") }), ctx())
      expect(lines[1]).to_be("# Find the bug")
      expect(lines[2]).to_be("`general-purpose` · ✓ done · 49k tokens · 0:07")
    end)

    it("folds the reasoning away and keeps tool calls one per line", function()
      local doc = fold({
        user("go"),
        assistant({ { type = "thinking", thinking = "one\ntwo" } }),
        assistant({
          { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls", description = "List files" } },
        }),
        assistant({ { type = "tool_use", id = "t2", name = "Read", input = { file_path = "/proj/lua/x.lua" } } }),
        result("t1", "", { stdout = "a\nb\n" }),
      })
      local lines, _, _, folds = view.render(doc, ctx())
      local text = table.concat(lines, "\n")
      expect(text:find("_thinking_\none\ntwo", 1, true) ~= nil).to_be_true()
      expect(#folds).to_be(1)
      expect(lines[folds[1][1]]).to_be("_thinking_")
      expect(text:find("- ✓ `bash` List files · 2 lines\n- ⊘ `read` lua/x.lua", 1, true) ~= nil).to_be_true()
    end)

    it("marks a call still waiting as running while the run is", function()
      local doc = fold({
        user("go"),
        assistant({ { type = "tool_use", id = "t1", name = "Bash", input = { command = "sleep 9" } } }),
      })
      local running = ctx({ row = { id = "a", agent_type = "Explore", state = "running" } })
      local text = table.concat(view.render(doc, running), "\n")
      expect(text:find("- … `bash` sleep 9", 1, true) ~= nil).to_be_true()
    end)

    it("links a started subagent to its own transcript", function()
      local doc = fold({
        user("go"),
        assistant({
          {
            type = "tool_use",
            id = "t1",
            name = "Agent",
            input = { description = "Probe", subagent_type = "Explore" },
          },
        }),
      })
      local child = { id = "child1", agent_type = "Explore", state = "done", tokens = 9127, runtime_s = 1 }
      local lines, _, links = view.render(doc, ctx({ children = { t1 = child }, by_id = { child1 = child } }))
      local at
      for index, line in ipairs(lines) do
        if line:find("`agent`", 1, true) then
          at = index
        end
      end
      expect(lines[at]).to_be("- ✓ `agent` Probe  (Explore) · 9.1k tokens · 0:01")
      expect(links[at]).to_be("child1")
    end)

    it("cuts a long command to one line with an ellipsis", function()
      local doc = fold({
        user("go"),
        assistant({ { type = "tool_use", id = "t1", name = "Bash", input = { command = string.rep("x", 300) } } }),
      })
      local lines = view.render(doc, ctx())
      local line = lines[#lines]
      expect(line:find("…", 1, true) ~= nil).to_be_true()
      expect(vim.fn.strdisplaywidth(line) < 130).to_be_true()
    end)
  end)
end)
