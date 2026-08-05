--- Tests for issue #248: closing diffs that are orphaned when their owning
--- client disconnects (or via the manual "close all diffs" path).
require("tests.busted_setup")
local diff = require("claudecode.diff")

describe("issue #248: closing orphaned diffs", function()
  local file_a = "/tmp/issue248_a.txt"
  local file_b = "/tmp/issue248_b.txt"

  before_each(function()
    for _, path in ipairs({ file_a, file_b }) do
      local f = io.open(path, "w")
      f:write("line 1\nline 2\n")
      f:close()
    end
  end)

  after_each(function()
    os.remove(file_a)
    os.remove(file_b)
    diff._cleanup_all_active_diffs("test_cleanup")
  end)

  -- Open a pending diff for a given file/tab/client and return a handle whose
  -- `.result` is populated once the diff's coroutine resolves.
  local function open_pending(file, tab_name, client_id)
    local handle = { result = nil }
    handle.co = coroutine.create(function()
      handle.result = diff.open_diff_blocking(file, file, "line 1\nline 2\nnew line\n", tab_name, client_id)
    end)
    local ok, err = coroutine.resume(handle.co)
    assert.is_true(ok, "diff coroutine should start: " .. tostring(err))
    assert.equal("suspended", coroutine.status(handle.co), "diff should be pending")
    return handle
  end

  it("records the owning client_id on the diff state", function()
    open_pending(file_a, "tab-A", "clientA")
    local active = diff._get_active_diffs()
    assert.is_table(active["tab-A"])
    assert.equal("clientA", active["tab-A"].client_id)
  end)

  it("close_diffs_for_client rejects + removes only that client's diffs", function()
    local a = open_pending(file_a, "tab-A", "clientA")
    local b = open_pending(file_b, "tab-B", "clientB")

    local closed = diff.close_diffs_for_client("clientA", "test disconnect")

    assert.equal(1, closed)
    -- clientA's diff resolved as rejected and removed from the registry
    assert.equal("dead", coroutine.status(a.co))
    assert.is_table(a.result)
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.is_nil(diff._get_active_diffs()["tab-A"])
    -- clientB's diff is untouched
    assert.equal("suspended", coroutine.status(b.co))
    assert.is_table(diff._get_active_diffs()["tab-B"])
  end)

  it("close_diffs_for_client with an unknown client closes nothing", function()
    open_pending(file_a, "tab-A", "clientA")
    assert.equal(0, diff.close_diffs_for_client("nobody", "test"))
    assert.is_table(diff._get_active_diffs()["tab-A"])
  end)

  it("close_diffs_for_client(nil) is a no-op", function()
    open_pending(file_a, "tab-A", "clientA")
    assert.equal(0, diff.close_diffs_for_client(nil, "test"))
    assert.is_table(diff._get_active_diffs()["tab-A"])
  end)

  it("close_all_diffs rejects every diff and drains active_diffs", function()
    local a = open_pending(file_a, "tab-A", "clientA")
    local b = open_pending(file_b, "tab-B", "clientB")

    local closed = diff.close_all_diffs("test all")

    assert.equal(2, closed)
    assert.equal("dead", coroutine.status(a.co))
    assert.equal("dead", coroutine.status(b.co))
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.equal("DIFF_REJECTED", b.result.content[1].text)
    -- registry fully drained (this is the secondary closeAllDiffTabs bug)
    assert.is_nil(next(diff._get_active_diffs()))
  end)

  -- Multi-tab regression: every per-tab Claude server shares this one
  -- active_diffs table, and Claude Code sends closeAllDiffTabs around each edit.
  -- close_all_diffs (the tool's backend) must only close diffs owned by the tab
  -- that issued the call -- otherwise the foreground Claude's routine
  -- closeAllDiffTabs rejects a *background* tab's still-pending diff, which that
  -- Claude receives as a spurious tool rejection and stops.
  it("close_all_diffs only closes diffs owned by the calling tab", function()
    vim._tabs[101] = true
    vim._tabs[102] = true

    require("claudecode.request_context").set({ tab = 101, instance_id = "tab:" .. tostring(101), kind = "tab" })
    local a = open_pending(file_a, "tab-101", "client101")
    require("claudecode.request_context").set({ tab = 102, instance_id = "tab:" .. tostring(102), kind = "tab" })
    local b = open_pending(file_b, "tab-102", "client102")

    assert.equal(101, diff._get_active_diffs()["tab-101"].original_tab_number)
    assert.equal(102, diff._get_active_diffs()["tab-102"].original_tab_number)

    -- closeAllDiffTabs arrives from tab 101's Claude (its server set the active id).
    require("claudecode.request_context").set({ tab = 101, instance_id = "tab:" .. tostring(101), kind = "tab" })
    local closed = diff.close_all_diffs("closeAllDiffTabs from tab 101")

    -- The calling tab's diff is closed/rejected...
    assert.equal(1, closed)
    assert.equal("dead", coroutine.status(a.co))
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.is_nil(diff._get_active_diffs()["tab-101"])
    -- ...but the background tab's pending diff is untouched.
    assert.equal("suspended", coroutine.status(b.co))
    assert.is_table(diff._get_active_diffs()["tab-102"])
    assert.is_nil(b.result)

    require("claudecode.request_context").clear()
    vim._tabs[101] = nil
    vim._tabs[102] = nil
  end)

  -- Agents mode runs several Claudes in ONE tab, so tab scoping is no longer fine
  -- enough: without instance scoping, one agent's routine closeAllDiffTabs would
  -- reject a sibling agent's pending diff and that agent would stop, believing the
  -- user declined its edit -- the same spurious-rejection bug, one level down.
  it("close_all_diffs only closes diffs owned by the calling agent in a shared tab", function()
    local ctx = require("claudecode.request_context")
    vim._tabs[201] = true

    ctx.set({ tab = 201, instance_id = "agent:aaa", session_id = "aaa", kind = "agent" })
    local a = open_pending(file_a, "agent-a", "clientA")
    ctx.set({ tab = 201, instance_id = "agent:bbb", session_id = "bbb", kind = "agent" })
    local b = open_pending(file_b, "agent-b", "clientB")

    local active = diff._get_active_diffs()
    -- Both diffs live in the same tab; only the instance tells them apart.
    assert.equal(201, active["agent-a"].original_tab_number)
    assert.equal(201, active["agent-b"].original_tab_number)
    assert.equal("agent:aaa", active["agent-a"].owner_instance_id)
    assert.equal("agent:bbb", active["agent-b"].owner_instance_id)

    ctx.set({ tab = 201, instance_id = "agent:aaa", session_id = "aaa", kind = "agent" })
    local closed = diff.close_all_diffs("closeAllDiffTabs from agent aaa")

    assert.equal(1, closed)
    assert.equal("dead", coroutine.status(a.co))
    assert.equal("DIFF_REJECTED", a.result.content[1].text)
    assert.is_nil(diff._get_active_diffs()["agent-a"])
    -- The sibling agent's diff is untouched and still awaiting the user.
    assert.equal("suspended", coroutine.status(b.co))
    assert.is_table(diff._get_active_diffs()["agent-b"])
    assert.is_nil(b.result)

    ctx.clear()
    vim._tabs[201] = nil
  end)

  -- A status="saved" diff still holds the user's :w'd edits only in its proposed
  -- buffer (until Claude writes the file). Auto-cleanup must NOT close it, or those
  -- edits are silently destroyed if Claude died before writing. Pending diffs only.
  it("close_diffs_for_client leaves SAVED diffs alone (preserves the user's edits)", function()
    open_pending(file_a, "tab-A", "clientA")
    local saved_buf = diff._get_active_diffs()["tab-A"].new_buffer
    diff._resolve_diff_as_saved("tab-A", saved_buf) -- user accepted: status -> saved
    assert.equal("saved", diff._get_active_diffs()["tab-A"].status)

    local closed = diff.close_diffs_for_client("clientA", "disconnect")

    assert.equal(0, closed)
    assert.is_table(diff._get_active_diffs()["tab-A"])
    assert.equal("saved", diff._get_active_diffs()["tab-A"].status)
  end)

  it("close_pending_diffs closes pending diffs but leaves saved ones", function()
    local a = open_pending(file_a, "tab-A", "clientA") -- stays pending
    open_pending(file_b, "tab-B", "clientB")
    local saved_buf = diff._get_active_diffs()["tab-B"].new_buffer
    diff._resolve_diff_as_saved("tab-B", saved_buf) -- tab-B -> saved

    local closed = diff.close_pending_diffs("server stopping")

    assert.equal(1, closed)
    assert.equal("dead", coroutine.status(a.co))
    assert.is_nil(diff._get_active_diffs()["tab-A"]) -- pending closed
    assert.is_table(diff._get_active_diffs()["tab-B"]) -- saved preserved
    assert.equal("saved", diff._get_active_diffs()["tab-B"].status)
  end)
end)
