-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.workflow_view", function()
  local view

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents.workflow_view"] = nil
    view = require("claudecode.agents.workflow_view")
  end)

  local run = {
    kind = "workflow",
    id = "w1",
    agent_type = "review-changes",
    description = "Review the diff",
    state = "running",
    tokens = 125000,
    runtime_s = 9,
  }

  it("heads the page with what the run is for and how it stands", function()
    local lines = view.render(run, {}, nil)
    expect(lines[1]).to_be("# Review the diff")
    expect(lines[2]).to_be("`review-changes` · ● running · 0 agents · 125k tokens · 0:09")
    expect(lines[4]).to_be("_no agent has started yet_")
  end)

  it("lists agents under their phases, each a line that opens its transcript", function()
    local alpha =
      { id = "a1", description = "find bugs", phase = "Review", state = "done", tokens = 62000, runtime_s = 1 }
    local beta = { id = "a2", description = "verify", phase = "Verify", state = "running", runtime_s = 3 }
    local lines, marks, links = view.render(run, { alpha, beta }, nil)
    expect(lines[4]).to_be("## Review")
    expect(lines[5]).to_be("- ✓ find bugs · 62k tokens · 0:01")
    expect(lines[7]).to_be("## Verify")
    expect(lines[8]).to_be("- ● verify · 0:03")
    expect(links[5]).to_be(alpha)
    expect(links[8]).to_be(beta)
    expect(marks[1].row).to_be(4)
  end)

  it("adds the result, error and log once the run has ended", function()
    local done = vim.tbl_extend("force", run, { state = "failed" })
    local lines = view.render(done, {}, {
      status = "failed",
      error = "Error: boom\n  at x",
      result = { ok = false },
      logs = { "step one" },
    })
    local text = table.concat(lines, "\n")
    expect(text:find("## Error\n```\nError: boom\n  at x\n```", 1, true) ~= nil).to_be_true()
    expect(text:find('## Result\n```json\n{\n  "ok": false\n}\n```', 1, true) ~= nil).to_be_true()
    expect(text:find("## Log\n> step one", 1, true) ~= nil).to_be_true()
  end)

  it("leaves out the stack trace a stopped run records", function()
    local stopped = vim.tbl_extend("force", run, { state = "stopped" })
    local lines = view.render(stopped, {}, { status = "killed", error = "Error: Workflow aborted\n at S" })
    expect(table.concat(lines, "\n"):find("Workflow aborted", 1, true)).to_be(nil)
  end)
end)
