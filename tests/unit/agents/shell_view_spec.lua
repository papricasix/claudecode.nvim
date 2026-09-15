-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.shell_view", function()
  local view

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.shell_view"] = nil
    package.loaded["claudecode.agents.ansi"] = nil
    view = require("claudecode.agents.shell_view")
  end)

  describe("paths", function()
    it("finds the session a subagent's transcript belongs to", function()
      expect(view.session_path("/p/sess/subagents/agent-a1.jsonl")).to_be("/p/sess.jsonl")
      expect(view.session_path("D:\\p\\sess\\subagents\\agent-a1.jsonl")).to_be("D:\\p\\sess.jsonl")
      expect(view.session_path("/p/sess.jsonl")).to_be("/p/sess.jsonl")
    end)
  end)

  describe("reading streamed output", function()
    it("keeps what follows a line's last carriage return, as a terminal shows it", function()
      expect(view.collapse_cr("10%\r50%\r100%")).to_be("100%")
      expect(view.collapse_cr("done\r")).to_be("done")
      expect(view.collapse_cr("plain")).to_be("plain")
    end)

    it("draws an unfinished line and replaces it once the rest arrives", function()
      local stream = view.new_stream()
      local first = view.feed(stream, "one\ntw")
      expect(first.complete).to_be(1)
      expect(table.concat(first.lines, "|")).to_be("one|tw")

      local second = view.feed(stream, "o\nthree\n")
      expect(second.complete).to_be(2)
      expect(table.concat(second.lines, "|")).to_be("two|three")
      expect(stream.carry).to_be("")
    end)

    it("carries colour from one read to the next", function()
      local stream = view.new_stream()
      view.feed(stream, "\27[32mgreen\n")
      local next_read = view.feed(stream, "still green\n\27[0mplain\n")
      expect(next_read.lines[1]).to_be("still green")
      expect(#next_read.marks).to_be(1)
      expect(next_read.marks[1].row).to_be(0)
      expect(next_read.marks[1].end_col).to_be(#"still green")
    end)

    it("drops the fragment a read that starts mid-file begins with", function()
      local stream = view.new_stream()
      stream.skip_partial = true
      local drawn = view.feed(stream, "ment of a line\nwhole\npart")
      expect(table.concat(drawn.lines, "|")).to_be("whole|part")
      expect(drawn.complete).to_be(1)
    end)
  end)

  describe("what the float says", function()
    it("words how a shell stands", function()
      expect((view.status_text({ state = "running", runtime_s = 42 }))).to_be("● running · 0:42")
      expect((view.status_text({ state = "failed", exit_code = 144, runtime_s = 13 }))).to_be("✗ exit 144 · 0:13")
      expect((view.status_text({ state = "done", exit_code = 0, runtime_s = 70 }))).to_be("✓ exit 0 · 1:10")
      expect((view.status_text({ state = "stopped" }))).to_be("⊘ stopped")
      local text = view.status_text({ state = "running", by_user = true })
      expect(text:find("Ctrl+B", 1, true) ~= nil).to_be_true()
    end)

    it("words a monitor as watching, with its events, and an expired one as expired", function()
      expect((view.status_text({ task_type = "monitor", state = "running", runtime_s = 14, events = 7 }))).to_be(
        "● watching · 0:14 · 7 events"
      )
      expect((view.status_text({ task_type = "monitor", state = "stopped", how = "expired", events = 1 }))).to_be(
        "⊘ expired · 1 event"
      )
      expect(view.title({ task_type = "monitor", description = "errors" }):sub(1, 2)).to_be("~ ")
    end)

    it("knows what the CLI wrote into the output rather than the command", function()
      expect(view.harness_span("[stderr] warn")).to_be(8)
      expect(view.harness_span("[exited with code 3]")).to_be(#"[exited with code 3]")
      expect(view.harness_span("[killed]")).to_be(8)
      expect(view.harness_span("plain [killed]")).to_be(nil)
    end)

    it("says on the rule what the output leaves out", function()
      local base = { done = 0, dropped = 0, skipped_bytes = 0 }
      expect(view.rule_text(base):find("output", 1, true) ~= nil).to_be_true()
      expect(view.rule_text(base):find("·", 1, true)).to_be(nil)

      local gone = vim.tbl_extend("force", base, { missing = true, output_path = "/x.output" })
      expect(view.rule_text(gone):find("no longer on disk", 1, true) ~= nil).to_be_true()
      local unknown = vim.tbl_extend("force", base, { missing = true })
      expect(view.rule_text(unknown):find("did not say", 1, true) ~= nil).to_be_true()

      local cut = vim.tbl_extend("force", base, { skipped_bytes = 3 * 1024 * 1024, dropped = 1200 })
      local rule = view.rule_text(cut)
      expect(rule:find("first 3.0 MB not shown", 1, true) ~= nil).to_be_true()
      expect(rule:find("1200 earlier lines not shown", 1, true) ~= nil).to_be_true()

      local waiting = vim.tbl_extend("force", base, { row = { state = "running" } })
      expect(view.rule_text(waiting):find("nothing yet", 1, true) ~= nil).to_be_true()
    end)
  end)
end)
