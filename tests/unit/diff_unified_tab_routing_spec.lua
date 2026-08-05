require("tests.busted_setup")

-- Regression test: with multiple Claude instances (one per tab), an `openDiff`
-- coming from a Claude server running in a background tab must route the diff
-- to that tab's editor window — not to whichever tab the user happens to be
-- looking at. The unified provider previously bypassed tab routing entirely.

describe("Unified diff routes to the owning Claude tab", function()
  local diff

  local test_old_file = "/tmp/claudecode_unified_routing_old.txt"
  local test_new_file = "/tmp/claudecode_unified_routing_new.txt"
  local tab_name = "unified-routing-spec"

  local owner_tab = 2 -- Claude's tab (background)
  local user_tab = 3 -- Tab the user is currently viewing

  local owner_editor_win = 2000
  local owner_terminal_win = 2001
  local user_editor_win = 3000
  local owner_terminal_buf

  local unified_show_against_text_calls

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end

    -- Build a two-tab world: owner_tab has the Claude terminal + an editor
    -- window, user_tab is unrelated.
    vim._tabs = { [owner_tab] = true, [user_tab] = true }
    vim._current_tabpage = user_tab

    local owner_editor_buf = vim.api.nvim_create_buf(true, false)
    vim._windows[owner_editor_win] = { buf = owner_editor_buf, width = 80 }
    vim._win_tab[owner_editor_win] = owner_tab

    owner_terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(owner_terminal_buf, "buftype", "terminal")
    vim._windows[owner_terminal_win] = { buf = owner_terminal_buf, width = 80 }
    vim._win_tab[owner_terminal_win] = owner_tab

    vim._tab_windows[owner_tab] = { owner_editor_win, owner_terminal_win }

    local user_editor_buf = vim.api.nvim_create_buf(true, false)
    vim._windows[user_editor_win] = { buf = user_editor_buf, width = 80 }
    vim._win_tab[user_editor_win] = user_tab
    vim._tab_windows[user_tab] = { user_editor_win }

    vim._current_window = user_editor_win
    vim._next_winid = 4000

    -- Signal that the in-flight tool call originated from owner_tab's server.
    require("claudecode.request_context").set({
      tab = owner_tab,
      instance_id = "tab:" .. tostring(owner_tab),
      kind = "tab",
    })

    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    diff.setup({
      terminal = { split_side = "right", split_width_percentage = 0.30 },
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
        provider = "unified",
      },
    })

    -- Terminal provider returns the buffer belonging to the owner tab. The
    -- routing logic should still place the diff in that tab even though the
    -- user is currently looking at user_tab.
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return owner_terminal_buf
      end,
      ensure_visible = function() end,
    }

    -- Stub the unified.nvim plugin so _setup_blocking_diff_unified can run
    -- without the real dependency installed in CI.
    unified_show_against_text_calls = {}
    package.loaded["unified"] = {
      setup = function() end,
    }
    package.loaded["unified.config"] = { ns_id = 1 }
    package.loaded["unified.diff"] = {
      show_against_text = function(buf, text)
        table.insert(unified_show_against_text_calls, { buf = buf, text = text })
      end,
    }

    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\n")
    f:close()

    diff._cleanup_all_active_diffs("test_setup")
  end)

  after_each(function()
    require("claudecode.request_context").clear()
    os.remove(test_old_file)
    os.remove(test_new_file)

    package.loaded["claudecode.terminal"] = nil
    package.loaded["unified"] = nil
    package.loaded["unified.config"] = nil
    package.loaded["unified.diff"] = nil

    if diff then
      diff._cleanup_all_active_diffs("test_teardown")
    end
  end)

  it("places the diff window in the owning tab, not the user's current tab", function()
    local co = coroutine.create(function()
      diff.open_diff_blocking(test_old_file, test_new_file, "updated content\n", tab_name)
    end)

    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))

    -- The proposed content must have been rendered against the buffer that
    -- now lives in the owner tab's editor window.
    assert.equal(1, #unified_show_against_text_calls)
    local proposed_buf = unified_show_against_text_calls[1].buf
    assert.equal(proposed_buf, vim.api.nvim_win_get_buf(owner_editor_win))

    -- User's tab/window are not yanked away from where they were.
    assert.equal(user_tab, vim.api.nvim_get_current_tabpage())

    -- Active diff state should remember the owning tab.
    local active = diff._get_active_diffs()[tab_name]
    assert.is_not_nil(active)
    assert.equal(owner_tab, active.original_tab_number)
    assert.equal("unified", active.provider)
    assert.equal(owner_editor_win, active.target_window)

    vim.schedule(function()
      diff._resolve_diff_as_rejected(tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)

  it("closes the float it opened when the diff resolves", function()
    -- The float is the diff's own window. Leaving it behind put an empty frame
    -- on screen after an accept: cleanup restored the displaced buffer into it,
    -- so the change vanished and the border stayed.
    diff.setup({
      terminal = { split_side = "right", split_width_percentage = 0.30 },
      diff_opts = { layout = "float", provider = "unified" },
      agents = { enabled = true },
    })

    -- The real float modules, not stubs: the window is opened through the agents
    -- wrapper (this is the agents tab) and closed through the shared stack they
    -- both share, so a stub on one side would no longer see the other.
    local float = require("claudecode.float")
    float.reset()

    local co = coroutine.create(function()
      diff.open_diff_blocking(test_old_file, test_new_file, "updated content\n", tab_name)
    end)
    assert.is_true((coroutine.resume(co)))

    local active = diff._get_active_diffs()[tab_name]
    assert.is_not_nil(active)
    assert.is_not_nil(active.float_window)
    assert.equal(active.float_window, active.target_window)
    assert.equal(1, float.count())

    diff._cleanup_diff_state(tab_name, "spec")
    assert.is_false(vim.api.nvim_win_is_valid(active.float_window))
    assert.equal(0, float.count())
  end)

  it("falls back to the user's tab when no owning tab is set", function()
    require("claudecode.request_context").clear()

    local co = coroutine.create(function()
      diff.open_diff_blocking(test_old_file, test_new_file, "updated content\n", tab_name)
    end)

    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))

    -- Without an active tab hint, the diff lands in the user's current tab.
    local active = diff._get_active_diffs()[tab_name]
    assert.is_not_nil(active)
    assert.equal(user_tab, active.original_tab_number)

    vim.schedule(function()
      diff._resolve_diff_as_rejected(tab_name)
    end)
    vim.wait(100, function()
      return coroutine.status(co) == "dead"
    end)
  end)
end)
