-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.tools", function()
  local tools

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.tools"] = nil
    tools = require("claudecode.agents.tools")
  end)

  describe("the kind column", function()
    it("names the tool, within the five cells the column has", function()
      expect(tools.short("Bash")).to_be("bash")
      expect(tools.short("WebFetch")).to_be("fetch")
      expect(tools.short("Task")).to_be("agent")
      for _, name in ipairs({ "Bash", "Grep", "Glob", "WebFetch", "WebSearch", "Task", "TodoWrite", "ExitPlanMode" }) do
        expect(#tools.short(name) <= 5).to_be_true()
      end
    end)

    it("shortens an unknown tool rather than widening the column", function()
      expect(tools.short("SomethingVeryLong")).to_be("somet")
      expect(tools.short(nil)).to_be("tool")
    end)

    it("names an MCP tool by its server", function()
      expect(tools.short("mcp__godot__send_debug_command")).to_be("godot")
    end)
  end)

  describe("what a row says a call was for", function()
    it("prefers Claude's own description of a command over the command", function()
      -- The command is one `<CR>` away and is routinely far too long to read
      -- sideways in a sidebar.
      local label = tools.label("Bash", { command = "git log --oneline | wc -l", description = "Count commits" })
      expect(label).to_be("Count commits")
    end)

    it("falls back to the command when there is no description", function()
      expect(tools.label("Bash", { command = "ls -la" })).to_be("ls -la")
    end)

    it("flattens a multi-line command onto one line", function()
      expect(tools.label("Bash", { command = "cd /tmp\nls\n" })).to_be("cd /tmp ls")
    end)

    it("names a search by its pattern and where it looked", function()
      expect(tools.label("Grep", { pattern = "push_event", path = "lua" })).to_be("push_event  in lua")
      expect(tools.label("Glob", { pattern = "**/*.lua" })).to_be("**/*.lua")
    end)

    it("drops a URL's scheme, which is the same eight cells on every row", function()
      expect(tools.label("WebFetch", { url = "https://neovim.io/doc/api.html" })).to_be("neovim.io/doc/api.html")
    end)

    it("counts a todo write, and says what is in progress", function()
      local label = tools.label("TodoWrite", {
        todos = {
          { status = "completed", content = "one" },
          { status = "in_progress", activeForm = "Wiring the pane" },
          { status = "pending", content = "three" },
        },
      })
      expect(label).to_be("Wiring the pane  (1/3 done)")
    end)

    it("names a plan by its first heading", function()
      expect(tools.label("ExitPlanMode", { plan = "# Agents Mode\n\nSome prose" })).to_be("plan: Agents Mode")
    end)

    it("says how many questions were asked, not just the first", function()
      local label = tools.label("AskUserQuestion", {
        questions = { { question = "Which scope?" }, { question = "Which key?" } },
      })
      expect(label).to_be("Which scope?  (+1 more)")
    end)

    it("reads an unknown tool's input by field order rather than giving up", function()
      -- An MCP server's input is whatever that server defines, so there is no
      -- rule to write; a row naming the tool alone would say nothing.
      expect(tools.label("mcp__x__y", { command = "graphics.potato" })).to_be("graphics.potato")
      expect(tools.label("Whatever", { description = "does a thing", other = "x" })).to_be("does a thing")
    end)

    it("never comes back empty", function()
      expect(tools.label("Whatever", {})).to_be("Whatever")
      expect(tools.label("mcp__srv__do_thing", {})).to_be("do_thing")
      expect(tools.label(nil, nil)).to_be("tool")
    end)
  end)

  describe("what the float shows", function()
    it("puts the command above its output, and names the stream it came out of", function()
      local body = tools.body("Bash", { command = "ls" }, { stdout = "a.lua\nb.lua\n", stderr = "" })
      expect(body.lines[1]).to_be("$ ls")
      expect(body.lines[2]).to_be("")
      expect(body.lines[3]:find("stdout", 1, true) ~= nil).to_be_true()
      expect(body.lines[4]).to_be("a.lua")
      expect(body.lines[5]).to_be("b.lua")
      expect(body.ansi).to_be_true()
    end)

    it("names both streams the same way", function()
      -- Neither heading is an error report; they are the two streams, and which
      -- one a line came out of is part of reading the output.
      local body = tools.body("Bash", { command = "x" }, { stdout = "out", stderr = "err" })
      local text = table.concat(body.lines, "\n")
      local out_at, err_at = text:find("stdout", 1, true), text:find("stderr", 1, true)
      expect(out_at ~= nil).to_be_true()
      expect(err_at ~= nil).to_be_true()
      expect(out_at < err_at).to_be_true()
    end)

    it("continues a multi-line command under its own prompt", function()
      local body = tools.body("Bash", { command = "cd /tmp\nls" }, { stdout = "x" })
      expect(body.lines[1]).to_be("$ cd /tmp")
      expect(body.lines[2]).to_be("  ls")
    end)

    it("keeps stderr as a named section rather than merging it", function()
      -- A command that succeeded may still have written there, so this is the
      -- other stream, not an error report.
      local body = tools.body("Bash", { command = "git status" }, { stdout = "ok", stderr = "warning: x" })
      local text = table.concat(body.lines, "\n")
      expect(text:find("stderr", 1, true) ~= nil).to_be_true()
      expect(text:find("warning: x", 1, true) ~= nil).to_be_true()
    end)

    it("says so when a command printed nothing", function()
      local body = tools.body("Bash", { command = "true" }, { stdout = "", stderr = "" })
      expect(body.lines[#body.lines]).to_be("(no output)")
    end)

    it("says a call is still running when no result has landed", function()
      local body = tools.body("Bash", { command = "sleep 30" }, nil)
      expect(body.lines[1]).to_be("$ sleep 30")
      expect(body.lines[#body.lines]:find("still running", 1, true) ~= nil).to_be_true()
    end)

    it("shows a rejected or errored call's message as written", function()
      -- Every tool answers with a bare string when it fails or is declined.
      local body = tools.body("ExitPlanMode", {}, "Error: The user doesn't want to proceed")
      expect(body.lines[1]).to_be("Error: The user doesn't want to proceed")
    end)

    it("shows a subagent's reply as the document it is", function()
      local body = tools.body("Task", { description = "Audit" }, {
        content = { { type = "text", text = "# Findings\n\nNothing broken." } },
      })
      expect(body.lines[1]).to_be("# Findings")
      expect(body.filetype).to_be("markdown")
    end)

    it("lists matched files one per line rather than as JSON", function()
      local body = tools.body("Glob", { pattern = "*.lua" }, { filenames = { "a.lua", "b.lua" }, numFiles = 2 })
      expect(body.lines).to_be_table()
      expect(body.lines[1]).to_be("a.lua")
      expect(body.lines[2]).to_be("b.lua")
    end)

    it("renders a todo write as its todos", function()
      local body = tools.body("TodoWrite", {}, {
        newTodos = { { status = "completed", content = "one" }, { status = "pending", content = "two" } },
      })
      expect(body.lines[1]).to_be("[x] one")
      expect(body.lines[2]).to_be("[ ] two")
    end)

    it("pretty-prints anything it does not recognize", function()
      local body = tools.body("Unknown", {}, { b = 1, a = "x" })
      expect(body.filetype).to_be("json")
      expect(body.lines[1]).to_be("{")
    end)
  end)

  describe("pretty JSON", function()
    it("is valid JSON, commas and all", function()
      -- A reader copies this out of the float; output that merely looks like JSON
      -- has to be repaired by hand before it can be used.
      local text = table.concat(tools.pretty_json({ a = "x", nested = { flag = true, list = { 1, 2 } } }), "\n")
      local ok, decoded = pcall(_G.json_decode, text)
      expect(ok).to_be_true()
      expect(decoded.a).to_be("x")
      expect(decoded.nested.list[2]).to_be(2)
    end)

    it("sorts keys, so the same result reads the same way twice", function()
      local first = table.concat(tools.pretty_json({ z = 1, a = 2 }), "\n")
      local second = table.concat(tools.pretty_json({ a = 2, z = 1 }), "\n")
      expect(first).to_be(second)
    end)

    it("spells an empty table and an empty list", function()
      expect(table.concat(tools.pretty_json({}), "")).to_be("[]")
      expect(table.concat(tools.pretty_json({ items = {} }), "\n"):find("%[%]") ~= nil).to_be_true()
    end)
  end)

  describe("file tools", function()
    it("are left to the rows they already have", function()
      -- Their results carry a path and a patch, which is what a file row and the
      -- Changes pane are made of; a second row would say the same thing twice.
      for _, name in ipairs({ "Read", "Edit", "Write", "MultiEdit", "NotebookEdit" }) do
        expect(tools.FILE_TOOLS[name]).to_be_true()
      end
      expect(tools.FILE_TOOLS.Bash).to_be_nil()
    end)
  end)
end)
