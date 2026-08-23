-- luacheck: globals expect
require("tests.busted_setup")

describe("agents_view", function()
  local agents_view

  local function base_config(agents, status)
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
      agents = agents,
      status = status,
    }
  end

  --- Run every autocmd registered for `event`. The mock records them rather than
  --- dispatching, so a spec that wants to see one fire has to call it.
  ---@param event string
  ---@param args table What the callback is handed (`buf`, `match`, ...).
  local function fire_autocmd(event, args)
    for _, group in pairs(vim._autocmds or {}) do
      for _, registered in pairs(group.events or {}) do
        local events = registered.events
        events = type(events) == "table" and events or { events }
        for _, name in ipairs(events) do
          if name == event and registered.opts and registered.opts.callback then
            registered.opts.callback(args)
          end
        end
      end
    end
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    package.loaded["claudecode.agents_view"] = nil
    package.loaded["claudecode.agents.model"] = nil
    package.loaded["claudecode.agents.render"] = nil
    agents_view = require("claudecode.agents_view")
  end)

  describe("config validation", function()
    local config

    before_each(function()
      package.loaded["claudecode.config"] = nil
      config = require("claudecode.config")
    end)

    it("accepts the defaults", function()
      -- Through apply(), which is the only path that produces a complete config:
      -- `defaults.terminal` is nil until apply() lazy-loads it.
      local ok, applied = pcall(config.apply, {})
      expect(ok).to_be_true()
      expect(applied.agents).to_be_table()
    end)

    it("ships disabled", function()
      expect(config.defaults.agents.enabled).to_be(false)
    end)

    it("rejects an unknown source", function()
      local ok = pcall(config.validate, base_config({ source = "telepathy" }))
      expect(ok).to_be(false)
    end)

    it("rejects a width that is not a fraction", function()
      expect((pcall(config.validate, base_config({ layout = { left_width = 42 } })))).to_be(false)
      expect((pcall(config.validate, base_config({ layout = { left_width = 0.25 } })))).to_be_true()
    end)

    it("rejects an unknown sort order", function()
      expect((pcall(config.validate, base_config({ sessions = { sort = "sideways" } })))).to_be(false)
      for _, sort in ipairs({ "recent", "name", "changes", "status" }) do
        expect((pcall(config.validate, base_config({ sessions = { sort = sort } })))).to_be_true()
      end
      -- The names those last two had before the sort menu existed. Still taken:
      -- a config that uses one is older, not wrong.
      expect((pcall(config.validate, base_config({ sessions = { sort = "added" } })))).to_be_true()
      expect((pcall(config.validate, base_config({ sessions = { sort = "title" } })))).to_be_true()
    end)

    it("takes a keymap for the sort menu", function()
      expect(config.defaults.agents.keymaps.sort).to_be("gs")
      expect((pcall(config.validate, base_config({ keymaps = { sort = "S" } })))).to_be_true()
      expect((pcall(config.validate, base_config({ keymaps = { sort = 42 } })))).to_be(false)
    end)

    it("accepts a keymap of false to leave the key unbound", function()
      expect((pcall(config.validate, base_config({ keymaps = { new = false } })))).to_be_true()
      expect((pcall(config.validate, base_config({ keymaps = { new = 42 } })))).to_be(false)
    end)

    it("rejects a non-table block", function()
      expect((pcall(config.validate, base_config("yes please")))).to_be(false)
    end)
  end)

  describe("enablement", function()
    it("is off unless asked for", function()
      agents_view.setup(base_config({ enabled = false }))
      expect(agents_view.is_enabled()).to_be(false)
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.is_enabled()).to_be_true()
    end)

    it("refuses to open while disabled", function()
      agents_view.setup(base_config({ enabled = false }))
      expect(agents_view.open()).to_be(false)
      expect(agents_view.is_open()).to_be(false)
    end)
  end)

  describe("hook appetite", function()
    it("wants hooks when asked for them outright", function()
      agents_view.setup(base_config({ enabled = true, source = "hooks" }))
      expect(agents_view.wants_hooks()).to_be_true()
    end)

    it("does not want hooks when polling", function()
      -- Polling gets the counts, the feed and the file list for free; hooks would
      -- cost a headless Neovim per tool call per running agent.
      agents_view.setup(base_config({ enabled = true, source = "poll" }, { enabled = true }))
      expect(agents_view.wants_hooks()).to_be(false)
    end)

    it("on auto, rides the hooks status already pays for", function()
      local status_config = base_config({ enabled = true, source = "auto" }, { enabled = true })
      require("claudecode.status").setup(status_config)
      agents_view.setup(status_config)
      expect(agents_view.wants_hooks()).to_be_true()
    end)

    it("on auto, polls when nothing else is paying for hooks", function()
      local status_config = base_config({ enabled = true, source = "auto" }, { enabled = false })
      require("claudecode.status").setup(status_config)
      agents_view.setup(status_config)
      expect(agents_view.wants_hooks()).to_be(false)
    end)

    it("wants nothing while disabled", function()
      agents_view.setup(base_config({ enabled = false, source = "hooks" }))
      expect(agents_view.wants_hooks()).to_be(false)
    end)
  end)

  describe("tab identity", function()
    it("claims no tab before it opens", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.is_agents_tab(1)).to_be(false)
      expect(agents_view.is_agents_tab(nil)).to_be(false)
      expect(agents_view.origin_tab()).to_be(nil)
    end)
  end)

  describe("standing down for a session write", function()
    after_each(function()
      vim.v.exiting = nil
      if agents_view.is_open() then
        agents_view.close()
      end
    end)

    it("leaves a view alone when the save is not a quit", function()
      -- A `cd` or a `:AutoSession save` typed mid-work saves too, and neither is
      -- a reason to tear down the view the user is in.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(agents_view.close_for_session()).to_be(nil)
      expect(agents_view.is_open()).to_be_true()
    end)

    it("closes the tab while Neovim is exiting", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local tab = agents_view._state().tab
      vim.v.exiting = 0 -- what VimLeavePre sees; v:null otherwise
      expect(agents_view.close_for_session()).to_be("closed")
      expect(agents_view.is_open()).to_be(false)
      expect(vim.api.nvim_tabpage_is_valid(tab)).to_be(false)
    end)

    it("still describes itself afterwards, once", function()
      -- The session manager asks for the payload *after* :mksession, by which
      -- time there is no view left to look at.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local live = agents_view.capture()
      expect(live).to_be_table()

      expect(agents_view.close_for_session(true)).to_be("closed")
      local saved = agents_view.capture()
      expect(saved).to_be_table()
      expect(saved.tabnr).to_be(live.tabnr)
      expect(saved.cwd).to_be(live.cwd)
      -- Consumed: a later save must not resurrect a view that is genuinely gone.
      expect(agents_view.capture()).to_be(nil)
    end)

    it("keeps a tab that holds something of the user's", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local tab = agents_view._state().tab
      local wins = agents_view._state().wins
      local intruder = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {})

      expect(agents_view.close_for_session(true)).to_be("panes")
      expect(agents_view.is_open()).to_be(false)
      expect(vim.api.nvim_tabpage_is_valid(tab)).to_be_true()
      expect(vim.api.nvim_win_is_valid(intruder)).to_be_true()
      for _, win in pairs(wins) do
        expect(vim.api.nvim_win_is_valid(win)).to_be(false)
      end
    end)

    it("does nothing while the view is closed", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.close_for_session(true)).to_be(nil)
    end)

    it("is reached through session_state.prepare_save, which answers nothing", function()
      -- auto-session reads a `false` from a pre-save hook as "abandon the save".
      package.loaded["claudecode.session_state"] = nil
      local session_state = require("claudecode.session_state")
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()

      expect(session_state.prepare_save()).to_be(nil) -- not a quit: view stays
      expect(agents_view.is_open()).to_be_true()

      expect(session_state.prepare_save({ force = true })).to_be(nil)
      expect(agents_view.is_open()).to_be(false)
    end)
  end)

  describe("naming the tab", function()
    ---@return any
    local function tab_var(tab, name)
      local ok, value = pcall(vim.api.nvim_tabpage_get_var, tab, name)
      return ok and value or nil
    end

    it("leaves the tab unnamed by default", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(tab_var(agents_view._state().tab, "name")).to_be(nil)
      agents_view.close()
    end)

    it("writes the name to the variable the tabline reads", function()
      agents_view.setup(base_config({ enabled = true, tab_name = "agents" }))
      expect(agents_view.open()).to_be_true()
      expect(tab_var(agents_view._state().tab, "name")).to_be("agents")
      agents_view.close()
    end)

    it("takes the variable's name from the config", function()
      -- Every tabline spells it differently; only the user knows which.
      agents_view.setup(base_config({ enabled = true, tab_name = "agents", tab_name_var = "taboo_tab_name" }))
      expect(agents_view.open()).to_be_true()
      local tab = agents_view._state().tab
      expect(tab_var(tab, "taboo_tab_name")).to_be("agents")
      expect(tab_var(tab, "name")).to_be(nil)
      agents_view.close()
    end)

    it("hands the tab to a function, for a tabline that renames by command", function()
      local seen
      agents_view.setup(base_config({
        enabled = true,
        tab_name = function(tab)
          seen = tab
        end,
      }))
      expect(agents_view.open()).to_be_true()
      expect(seen).to_be(agents_view._state().tab)
      agents_view.close()
    end)

    it("survives a function that throws", function()
      agents_view.setup(base_config({
        enabled = true,
        tab_name = function()
          error("no such command")
        end,
      }))
      expect(agents_view.open()).to_be_true()
      agents_view.close()
    end)

    it("rejects a name that is neither a string, a function, nor false", function()
      package.loaded["claudecode.config"] = nil
      local config = require("claudecode.config")
      expect((pcall(config.validate, base_config({ tab_name = "agents" })))).to_be_true()
      expect((pcall(config.validate, base_config({ tab_name = false })))).to_be_true()
      expect((pcall(config.validate, base_config({ tab_name = 42 })))).to_be(false)
      expect((pcall(config.validate, base_config({ tab_name = "" })))).to_be(false)
      expect((pcall(config.validate, base_config({ tab_name_var = "" })))).to_be(false)
      expect((pcall(config.validate, base_config({ tab_name_var = "tab_name" })))).to_be_true()
    end)
  end)

  describe("arriving at the view", function()
    -- The state transition itself is `model.mark_read`'s (see model_spec); what
    -- this pins is *when* the view asks for it. `TabEnter` and `FocusGained` are
    -- the answer an answer that arrived while the user was elsewhere needs —
    -- `model.select` only covers reaching a session with `<CR>` or `<C-n>`.
    local marked

    ---Watch the model the same way the animation-clock specs do: the functions
    ---are looked up on the module table at call time, and the outer `before_each`
    ---drops the module again for the next test.
    local function watch_model()
      marked = {}
      local model = require("claudecode.agents.model")
      model.selected = function()
        return "aaa"
      end
      model.mark_read = function(session_id)
        marked[#marked + 1] = session_id
        return true
      end
    end

    it("clears the unread marker on the conversation it is showing", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      watch_model()

      expect(agents_view.mark_selected_read()).to_be_true()
      expect(#marked).to_be(1)
      expect(marked[1]).to_be("aaa")

      agents_view.close()
    end)

    it("reads nothing while the view is closed or off screen", function()
      agents_view.setup(base_config({ enabled = true }))
      watch_model()
      expect(agents_view.mark_selected_read()).to_be_false()

      expect(agents_view.open()).to_be_true()
      local tab = agents_view._state().tab
      vim._current_tabpage = tab + 1
      expect(agents_view.mark_selected_read()).to_be_false()
      expect(#marked).to_be(0)

      vim._current_tabpage = tab
      agents_view.close()
    end)
  end)

  describe("session cycling", function()
    local rows = { { session_id = "a" }, { session_id = "b" }, { session_id = "c" } }

    it("steps forwards and backwards, wrapping at both ends", function()
      expect(agents_view._next_index(rows, "a", 1)).to_be(2)
      expect(agents_view._next_index(rows, "c", 1)).to_be(1)
      expect(agents_view._next_index(rows, "a", -1)).to_be(3)
      expect(agents_view._next_index(rows, "b", -1)).to_be(1)
    end)

    it("starts at the near end when nothing is selected yet", function()
      expect(agents_view._next_index(rows, nil, 1)).to_be(1)
      expect(agents_view._next_index(rows, nil, -1)).to_be(3)
      -- A selection that is no longer listed behaves the same way.
      expect(agents_view._next_index(rows, "gone", 1)).to_be(1)
    end)

    it("has nowhere to go with an empty list", function()
      expect(agents_view._next_index({}, "a", 1)).to_be(0)
    end)

    it("does nothing while the view is closed", function()
      agents_view.setup(base_config({ enabled = true }))
      expect((pcall(agents_view.cycle_session, 1))).to_be_true()
    end)
  end)

  describe("persistence", function()
    it("has nothing to save while closed", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.capture()).to_be(nil)
    end)

    it("arms the agents a restored session was running", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.restore({ tabnr = 2, cwd = "/proj", sessions = { "aaa", "bbb" } })).to_be_true()
      expect(#agents_view.armed_sessions()).to_be(2)
      expect(agents_view.armed_sessions()[1]).to_be("aaa")
    end)

    it("starts nothing on its own", function()
      -- N restored agents must not be N processes at startup; they are marked in
      -- the list and start when chosen.
      agents_view.setup(base_config({ enabled = true }))
      agents_view.restore({ tabnr = 2, cwd = "/proj", sessions = { "aaa" } })
      expect(agents_view.is_open()).to_be(false)
    end)

    it("ignores a payload that is not one of ours", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.restore(nil)).to_be(false)
      expect(agents_view.restore("nonsense")).to_be(false)
      expect(#agents_view.armed_sessions()).to_be(0)
    end)
  end)

  describe("layout", function()
    it("fixes the sidebars and lets the terminal absorb the rest", function()
      -- The degree of freedom the whole layout depends on. Fix the centre too and
      -- Neovim has no window it may take space from: widening one sidebar shrinks
      -- the other, and healing a pane lost with a dead terminal collapsed Changes
      -- to a single cell.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()

      local wins = agents_view._state().wins
      expect(vim.wo[wins.center].winfixwidth).to_be(false)
      expect(vim.wo[wins.center].winfixheight).to_be(false)
      for _, pane in ipairs({ "sessions", "feed", "changes" }) do
        expect(vim.wo[wins[pane]].winfixwidth).to_be_true()
        expect(vim.wo[wins[pane]].winfixheight).to_be_true()
      end
      agents_view.close()
    end)

    it("puts the pane sizes back after a foreign split disturbs them", function()
      -- A split opened in this tab has to take its rows from somewhere, and
      -- `winfixheight` does not stop Neovim when there is no unfixed window in
      -- the column to take them from. Closing it hands the freed space to
      -- whichever neighbour Neovim picks, which is how Activity kept growing at
      -- Sessions' expense (measured: sessions 27 -> 17, feed 19 -> 29).
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local wins = agents_view._state().wins

      local before = {
        left = vim.api.nvim_win_get_width(wins.changes),
        right = vim.api.nvim_win_get_width(wins.sessions),
        sessions = vim.api.nvim_win_get_height(wins.sessions),
      }

      -- What the split did.
      vim.api.nvim_win_set_height(wins.sessions, 5)
      agents_view.restore_sizes()

      expect(vim.api.nvim_win_get_height(wins.sessions)).to_be(before.sessions)
      expect(vim.api.nvim_win_get_width(wins.changes)).to_be(before.left)
      expect(vim.api.nvim_win_get_width(wins.sessions)).to_be(before.right)
      agents_view.close()
    end)

    it("keeps a size the user set rather than reverting to the configured share", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local wins = agents_view._state().wins

      vim.api.nvim_win_set_height(wins.sessions, 34)
      agents_view.remember_sizes()
      vim.api.nvim_win_set_height(wins.sessions, 5) -- a split takes the rows
      agents_view.restore_sizes()

      expect(vim.api.nvim_win_get_height(wins.sessions)).to_be(34)
      agents_view.close()
    end)

    it("refuses to record sizes while the layout is disturbed", function()
      -- Otherwise the snapshot captures the damage and the restore reinstates it.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local wins = agents_view._state().wins
      local good = vim.api.nvim_win_get_height(wins.sessions)

      local intruder = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {})
      vim.api.nvim_win_set_height(wins.sessions, 5)
      agents_view.remember_sizes() -- five windows in the tab: not a moment to measure
      pcall(vim.api.nvim_win_close, intruder, true)
      agents_view.restore_sizes()

      expect(vim.api.nvim_win_get_height(wins.sessions)).to_be(good)
      agents_view.close()
    end)

    it("repaints the terminal background for every buffer the centre pane shows", function()
      -- Neovim remembers window-local options per (window, buffer) pair, so a
      -- buffer that has never been in the pane arrives with no `winhighlight` at
      -- all: `nvim_win_set_buf` on a window carrying one leaves it blank
      -- (measured). Painting once when the pane was built therefore lasted until
      -- the first agent's terminal replaced the buffer it was built around, and
      -- the conversation sat on the editor's own background from then on.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local center = agents_view._state().wins.center

      local painted = vim.wo[center].winhighlight
      expect(painted:find("Normal:ClaudeCodeAgentsNormal", 1, true)).not_to_be_nil()

      -- What a buffer swap into the pane does to it.
      vim.wo[center].winhighlight = ""
      fire_autocmd("BufWinEnter", { buf = vim.api.nvim_win_get_buf(center) })

      expect(vim.wo[center].winhighlight).to_be(painted)
      agents_view.close()
    end)

    it("keeps what a terminal buffer added to the pane's highlights", function()
      -- `termopen` appends `StatusLine:StatusLineTerm` as the buffer becomes a
      -- terminal. Overwriting rather than merging would restyle the pane's
      -- statusline on every agent switch.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      local center = agents_view._state().wins.center

      vim.wo[center].winhighlight = "StatusLine:StatusLineTerm,Normal:SomethingElse"
      fire_autocmd("BufWinEnter", { buf = vim.api.nvim_win_get_buf(center) })

      local painted = vim.wo[center].winhighlight
      expect(painted:find("Normal:ClaudeCodeAgentsNormal", 1, true)).not_to_be_nil()
      expect(painted:find("StatusLine:StatusLineTerm", 1, true)).not_to_be_nil()
      -- Ours won the group both claimed.
      expect(painted:find("Normal:SomethingElse", 1, true)).to_be_nil()
      agents_view.close()
    end)
  end)

  describe("the animation clock", function()
    local status

    ---Status config whose `busy` icon actually animates.
    ---
    ---The shipped default is a single glyph — the CLI's spinner is **opt-in**
    ---(`icons = { busy = require("claudecode.status").SPINNER }`) — so a view
    ---showing a busy agent does not animate unless the user asked it to, and the
    ---clock is not held. A spec about *holding* the clock has to ask for it, the
    ---same way a user would.
    ---@param overrides table|nil
    local function animated(overrides)
      return vim.tbl_deep_extend(
        "force",
        { enabled = true, icons = { busy = { "⠋", "⠙", "⠹" } } },
        overrides or {}
      )
    end

    ---Give the view something that moves. `model.rows` is looked up on the module
    ---table at call time, so replacing the one function is enough; the outer
    ---before_each drops the module again for the next test.
    local function with_a_busy_agent()
      require("claudecode.agents.model").rows = function()
        return { { session_id = "aaa", title = "working", state = "busy", live = true, icon = "*" } }
      end
    end

    ---And something that does not.
    local function with_a_finished_agent()
      require("claudecode.agents.model").rows = function()
        return { { session_id = "aaa", title = "finished", state = "idle", live = false, icon = "o" } }
      end
    end

    before_each(function()
      package.loaded["claudecode.status"] = nil
      status = require("claudecode.status")
      status.setup(base_config(nil, animated()))
      with_a_busy_agent()
    end)

    it("is asked for rather than owned, so only one timer ever drives it", function()
      -- The frame counter is global on purpose (a busy tab and a busy agent must
      -- show the same glyph), so a second timer over it is a race. This view ran
      -- one, and it leaked: measured, leaving the tab and coming back left it
      -- armed *as well as* status's, doubling `_tick` calls for one animation.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(agents_view._state().spinner_timer).to_be(nil)
      -- `true`, not a rate: the pace is `status.spinner_ms`. See below.
      expect(status._frame_requests()["agents_view"]).to_be_true()
      agents_view.close()
    end)

    it("is released when the view goes off screen, and re-taken on return", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()

      agents_view.stop_timers() -- what leaving the tab does
      expect(status._frame_requests()["agents_view"]).to_be(nil)

      agents_view.sync_timers() -- and what coming back does
      expect(status._frame_requests()["agents_view"]).to_be_true()
      agents_view.close()
    end)

    it("is requested by open() itself, not only by the first TabEnter", function()
      -- `open` armed the poll timer alone, so a freshly opened view did not
      -- animate until you left the tab and came back — which is what made a
      -- round trip look like it changed the animation's speed.
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be_true()
      agents_view.close()
    end)

    it("is let go of when the view closes", function()
      agents_view.setup(base_config({ enabled = true }))
      agents_view.open()
      agents_view.close()
      expect(status._frame_requests()["agents_view"]).to_be(nil)
    end)

    it("runs at the configured pace, not at this view's own default", function()
      -- The reported bug, with the config that produced it: `spinner_ms = 250`
      -- ("calmer than the CLI's own pace") on status and nothing on agents. A
      -- request carrying this view's default overrode it, so opening the agents
      -- tab sped the *tabline* up from 250ms to 120ms — more than double.
      local cfg = base_config({ enabled = true }, animated({ spinner_ms = 250 }))
      status.setup(cfg)
      agents_view.setup(cfg)
      expect(agents_view.open()).to_be_true()

      -- `true` means "keep the clock running", not "run it at my speed".
      expect(status._frame_requests()["agents_view"]).to_be_true()
      expect(status._spinner_interval()).to_be(250)
      agents_view.close()
    end)

    it("still lets a view name a rate of its own when it means to", function()
      local cfg = base_config({ enabled = true, spinner_ms = 60 }, animated({ spinner_ms = 250 }))
      status.setup(cfg)
      agents_view.setup(cfg)
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be(60)
      expect(status._spinner_interval()).to_be(60)
      agents_view.close()
    end)

    it("is let go of when nothing on screen moves", function()
      -- The clock drives a repeating redraw of every tabline and statusline. With
      -- no agent working and no fade running, it was doing that to paint the
      -- identical picture — which on an idle project is all of the time.
      with_a_finished_agent()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be(nil)
      agents_view.close()
    end)

    it("takes it back the moment something starts moving", function()
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be_true()

      with_a_finished_agent()
      agents_view.redraw()
      expect(status._frame_requests()["agents_view"]).to_be(nil)

      with_a_busy_agent()
      agents_view.redraw()
      expect(status._frame_requests()["agents_view"]).to_be_true()
      agents_view.close()
    end)

    it("is held for a fade that is still running, with nothing else moving", function()
      -- A count that just changed walks down a ramp for ~3s. Releasing the clock
      -- because no agent is working would leave it frozen part-way.
      require("claudecode.agents.model").rows = function()
        return {
          { session_id = "aaa", title = "just finished", state = "idle", live = false, icon = "o", added_age_ms = 0 },
        }
      end
      agents_view.setup(base_config({ enabled = true }))
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be_true()
      agents_view.close()
    end)

    it("is never asked for when the user does their own redrawing", function()
      agents_view.setup(base_config({ enabled = true, auto_redraw = false }))
      expect(agents_view.open()).to_be_true()
      expect(status._frame_requests()["agents_view"]).to_be(nil)
      agents_view.close()
    end)
  end)

  describe("choosing a session without starting it", function()
    local selected, live, foreign, shown, launched, rows, notify_change, hidden

    ---What the centre pane is holding, as lines.
    local function center_lines()
      local wins = agents_view._state().wins
      local buf = vim.api.nvim_win_get_buf(wins.center)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    ---Opened per test rather than in `before_each`: what the view does on open
    ---depends on what is live, foreign or listed, and that is what each test sets.
    local function open_view()
      expect(agents_view.open()).to_be_true()
    end

    before_each(function()
      selected, live, foreign, shown, launched, notify_change, hidden = nil, {}, {}, {}, {}, nil, 0
      rows = { { session_id = "aaa", title = "First" }, { session_id = "bbb", title = "Second" } }

      package.loaded["claudecode.agents.registry"] = {
        is_live = function(id)
          return live[id] == true
        end,
        show = function(id)
          shown[#shown + 1] = id
        end,
        launch = function(id)
          launched[#launched + 1] = id
          live[id] = true
          return { bufnr = vim.api.nvim_create_buf(false, true) }
        end,
        cleanup_tab = function() end,
        live_ids = function()
          return {}
        end,
      }
      package.loaded["claudecode.agents.model"] = {
        setup = function() end,
        on_change = function(_, fn)
          notify_change = fn
        end,
        attach = function() end,
        detach = function() end,
        cwd = function()
          return "/proj"
        end,
        selected_cwd = function()
          return "/proj"
        end,
        rows = function()
          return rows
        end,
        row = function(id)
          for _, row in ipairs(rows) do
            if row.session_id == id then
              return { session_id = id, title = row.title, cwd = "/proj" }
            end
          end
          return nil
        end,
        feed = function()
          return {}
        end,
        changes = function()
          return {}
        end,
        select = function(id)
          selected = id
        end,
        selected = function()
          return selected
        end,
        foreign_state = function(id)
          return foreign[id]
        end,
        hidden_count = function()
          return hidden
        end,
        window = function()
          return { key = "2w", label = "Last 2 weeks" }
        end,
        request_refresh = function() end,
        refresh_list = function() end,
        refresh_git = function() end,
        set_armed = function() end,
      }
      package.loaded["claudecode.agents_view"] = nil
      agents_view = require("claudecode.agents_view")
      agents_view.setup(base_config({ enabled = true }))
    end)

    after_each(function()
      agents_view.close()
      for _, name in ipairs({ "registry", "model" }) do
        package.loaded["claudecode.agents." .. name] = nil
      end
      package.loaded["claudecode.agents_view"] = nil
    end)

    it("offers the newest session as soon as the view opens", function()
      -- Otherwise the centre is the blank, *modifiable* buffer `tabnew` left, and
      -- `i` from any pane drops the user into insert mode in a scratch file.
      open_view()
      expect(selected).to_be("aaa")
      expect(agents_view._state().pending_start).to_be("aaa")
      expect(#launched).to_be(0)
      expect(center_lines():find("First", 1, true) ~= nil).to_be_true()
    end)

    it("offers to start the first one when the project has no sessions", function()
      -- The offer bails on an empty list and waits for one to arrive, which in a
      -- project Claude has never run in never happens: the centre kept the "Reading
      -- this project's sessions…" notice for ever.
      rows = {}
      open_view()
      expect(agents_view._state().pending_start).to_be(nil)
      expect(agents_view._state().notice_kind).to_be("empty")
      local text = center_lines()
      expect(text:find("No conversations", 1, true) ~= nil).to_be_true()
      expect(text:find("start a new agent", 1, true) ~= nil).to_be_true()
      expect(#launched).to_be(0)
    end)

    it("says the window is empty rather than the project, when there are older ones", function()
      -- A project whose conversations are all older than the window is not an
      -- empty project, and saying so would send the user looking for work they
      -- still have. The screen names the window and the key that widens it.
      rows = {}
      hidden = 7
      open_view()
      local text = center_lines()
      expect(text:find("last 2 weeks", 1, true) ~= nil).to_be_true()
      expect(text:find("7 older conversations", 1, true) ~= nil).to_be_true()
      expect(text:find("show more of them", 1, true) ~= nil).to_be_true()
    end)

    it("binds the new-agent key on that screen, and nowhere else", function()
      -- `new` is a sessions-pane key otherwise, and the notice buffer is reused:
      -- left bound, it would start a *second* conversation from a screen offering
      -- to resume a particular one.
      local function has_new_key()
        for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(agents_view._state().notice_buf, "n")) do
          if keymap.lhs == "a" then
            return true
          end
        end
        return false
      end

      rows = {}
      open_view()
      expect(has_new_key()).to_be_true()

      rows = { { session_id = "aaa", title = "First" } }
      notify_change()
      expect(agents_view._state().notice_kind).to_be("offer")
      expect(has_new_key()).to_be_false()
    end)

    it("starts a new agent when the terminal is focused in an empty project", function()
      -- Nothing to resume and nothing to read, so "put me in a session" can only
      -- mean starting one.
      rows = {}
      open_view()
      agents_view.focus_terminal()
      expect(#launched).to_be(1)
    end)

    it("goes back to that screen when the last conversation is deleted", function()
      open_view()
      expect(agents_view._state().pending_start).to_be("aaa")
      rows = {}
      notify_change()
      expect(agents_view._state().pending_start).to_be(nil)
      expect(center_lines():find("No conversations", 1, true) ~= nil).to_be_true()
    end)

    it("puts the cursor on a new agent's row the moment it appears", function()
      -- A conversation started here is selected before the CLI has written its
      -- transcript, so for the first few seconds it is in no listing. The cursor
      -- (and with it `cursorline`) stayed on the previously selected session when
      -- the row finally turned up — it only caught up when the list was cycled.
      local render = require("claudecode.agents.render")
      render.sessions = function(buf, drawn)
        local lines = {}
        for _, row in ipairs(drawn) do
          lines[#lines + 1] = row.session_id
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      end
      render.payload_at = function(buf, lnum)
        local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
        return line and line ~= "" and { session_id = line } or nil
      end
      render.feed = function() end
      render.changes = function() end

      open_view()
      local sessions_win = agents_view._state().wins.sessions
      agents_view.redraw()
      expect(vim.api.nvim_win_get_cursor(sessions_win)[1]).to_be(1) -- "aaa"

      -- The new agent: selected, running, but not yet listed.
      selected = "ccc"
      live.ccc = true
      agents_view.redraw()
      expect(vim.api.nvim_win_get_cursor(sessions_win)[1]).to_be(1)

      -- Its first message lands and the row arrives, newest first.
      table.insert(rows, 1, { session_id = "ccc", title = "Third" })
      agents_view.redraw()
      expect(vim.api.nvim_win_get_cursor(sessions_win)[1]).to_be(1)
      expect(vim.api.nvim_buf_get_lines(agents_view._state().bufs.sessions, 0, 1, false)[1]).to_be("ccc")

      -- And a cursor the user moved themselves is still left where they put it.
      vim.api.nvim_win_set_cursor(sessions_win, { 2, 0 })
      agents_view.redraw()
      expect(vim.api.nvim_win_get_cursor(sessions_win)[1]).to_be(2)
    end)

    it("cycles the selection without starting a CLI", function()
      -- The whole point of the counts, the file list and the feed is that you can
      -- read what a session did before deciding to reopen it.
      open_view()
      agents_view.cycle_session(1)
      expect(selected).to_be("bbb")
      expect(#launched).to_be(0)
    end)

    it("says in the centre pane what is selected, and which key starts it", function()
      open_view()
      agents_view.cycle_session(1)
      local text = center_lines()
      expect(text:find("Second", 1, true) ~= nil).to_be_true()
      expect(text:find("not running", 1, true) ~= nil).to_be_true()
      expect(text:find("start it here", 1, true) ~= nil).to_be_true()
    end)

    it("starts the offered session when the terminal is focused", function()
      open_view()
      expect(agents_view._state().pending_start).to_be("aaa")
      agents_view.focus_terminal()
      expect(launched[1]).to_be("aaa")
      expect(agents_view._state().pending_start).to_be(nil)
    end)

    it("offers to jump rather than to start a conversation running elsewhere", function()
      foreign.aaa = "busy"
      open_view()
      expect(center_lines():find("another tab", 1, true) ~= nil).to_be_true()
      expect(#launched).to_be(0)
    end)

    it("shows a live one at once, with nothing left to offer", function()
      live.aaa = true
      open_view()
      expect(shown[1]).to_be("aaa")
      expect(agents_view._state().pending_start).to_be(nil)
      expect(#launched).to_be(0)
    end)

    it("names the conversation once its title has been read", function()
      -- Transcripts fold asynchronously, so the first rows carry the session id
      -- as a placeholder. The offer is made against those, and has to catch up.
      rows[1].title = nil
      open_view()
      expect(center_lines():find("First", 1, true)).to_be(nil)

      rows[1].title = "First"
      notify_change()
      expect(center_lines():find("First", 1, true) ~= nil).to_be_true()
    end)

    it("does not pull a started agent back out of the centre", function()
      open_view()
      agents_view.focus_terminal()
      expect(launched[1]).to_be("aaa")
      local buf = vim.api.nvim_win_get_buf(agents_view._state().wins.center)
      notify_change()
      expect(vim.api.nvim_win_get_buf(agents_view._state().wins.center)).to_be(buf)
    end)

    it("reuses one notice buffer however far you cycle", function()
      -- Otherwise holding the key leaks a scratch buffer per row.
      open_view()
      local first = agents_view._state().notice_buf
      agents_view.cycle_session(1)
      expect(agents_view._state().notice_buf).to_be(first)
      expect(agents_view._state().pending_start).to_be("bbb")
    end)
  end)

  describe("stepping through files from inside a float", function()
    local render, opened, payloads, pending, defer_opens, allow_reuse

    ---A float for the stubbed file_view to hand back — a scratch buffer, which is
    ---the only kind the navigation will bind itself to.
    local function float_win()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
      return vim.api.nvim_open_win(buf, false, { relative = "editor", width = 10, height = 5, row = 1, col = 1 })
    end

    ---What the real `float.create` does with `reuse`: swap the content of the
    ---float that is already open, and only build a new one when it is gone.
    local function answer(opts, done)
      local win = (allow_reuse and opts.reuse and vim.api.nvim_win_is_valid(opts.reuse)) and opts.reuse or float_win()
      if defer_opens then
        pending[#pending + 1] = function()
          done(win)
        end
      else
        done(win)
      end
    end

    ---The `<C-n>`/`<C-p>` handler most recently bound. The vim mock keys keymaps
    ---by mode and lhs alone, so this is the float's binding — the panes bound the
    ---same keys earlier, which is exactly the shadowing the real buffer-local
    ---maps produce inside the float.
    local function press(lhs)
      vim._keymaps.n[lhs].rhs()
    end

    before_each(function()
      opened, pending, defer_opens, allow_reuse = {}, {}, false, true
      payloads = {
        [1] = { path = "/proj/a.lua" },
        [2] = { path = "/proj/b.lua" },
        [3] = {}, -- a row with no file on it: skipped, not landed on
        [4] = { path = "/proj/c.lua" },
      }

      package.loaded["claudecode.agents.model"] = {
        setup = function() end,
        on_change = function() end,
        attach = function() end,
        detach = function() end,
        cwd = function()
          return "/proj"
        end,
        selected_cwd = function()
          return "/proj"
        end,
        selected = function()
          return "aaa"
        end,
        transcript_path = function()
          return "/store/aaa.jsonl"
        end,
        rows = function()
          return {}
        end,
        feed = function()
          return {}
        end,
        changes = function()
          return {}
        end,
        hidden_count = function()
          return 0
        end,
        window = function()
          return { key = "2w", label = "Last 2 weeks" }
        end,
        refresh_list = function() end,
        refresh_git = function() end,
        set_armed = function() end,
      }
      package.loaded["claudecode.agents.file_view"] = {
        open = function(opts, done)
          opened[#opened + 1] = opts.path
          answer(opts, done)
        end,
        open_against_head = function(opts, done)
          opened[#opened + 1] = "HEAD:" .. opts.path
          answer(opts, done)
        end,
      }

      package.loaded["claudecode.agents_view"] = nil
      agents_view = require("claudecode.agents_view")
      agents_view.setup(base_config({
        enabled = true,
        -- Spelled out because `setup` takes the config it is given: a bare
        -- `{ enabled = true }` has no keymaps to bind, in the view or the float.
        keymaps = { next_session = "<C-n>", prev_session = "<C-p>" },
      }))
      expect(agents_view.open()).to_be_true()

      render = require("claudecode.agents.render")
      render.payload_at = function(_, lnum)
        return payloads[lnum]
      end

      local wins = agents_view._state().wins
      -- Four rows to walk: the pane's line count is what bounds the walk, and the
      -- payloads above are what say which of them hold a file.
      vim.api.nvim_buf_set_lines(agents_view._state().bufs.changes, 0, -1, false, { "1", "2", "3", "4" })
      vim.api.nvim_set_current_win(wins.changes)
      vim.api.nvim_win_set_cursor(wins.changes, { 1, 0 })
    end)

    after_each(function()
      agents_view.close()
      for _, name in ipairs({ "model", "file_view", "render" }) do
        package.loaded["claudecode.agents." .. name] = nil
      end
      package.loaded["claudecode.agents_view"] = nil
    end)

    it("opens the row under the cursor", function()
      agents_view.open_under_cursor()
      expect(opened[1]).to_be("/proj/a.lua")
    end)

    it("moves to the next file rather than the next session", function()
      agents_view.open_under_cursor()
      press("<C-n>")
      expect(opened[2]).to_be("/proj/b.lua")
      press("<C-n>")
      expect(opened[3]).to_be("/proj/c.lua") -- the fileless row is skipped
    end)

    it("wraps at both ends", function()
      agents_view.open_under_cursor()
      press("<C-p>")
      expect(opened[2]).to_be("/proj/c.lua")
    end)

    it("keeps the pane's cursor on the row the float is showing", function()
      agents_view.open_under_cursor()
      press("<C-n>")
      local wins = agents_view._state().wins
      expect(vim.api.nvim_win_get_cursor(wins.changes)[1]).to_be(2)
    end)

    it("swaps the content of the float rather than closing and reopening it", function()
      -- The gap between the two is what leaked held keypresses to the pane, where
      -- they cycled the *session*: `file_view.open` is asynchronous, so focus sat
      -- outside any float for as long as the next one took to build.
      local float = require("claudecode.agents.float")
      agents_view.open_under_cursor()
      local before = float.count()
      press("<C-n>")
      press("<C-n>")
      expect(float.count()).to_be(before)
      expect(opened[3]).to_be("/proj/c.lua")
    end)

    it("follows the float when it could not be reused", function()
      -- Only happens when the window is gone, but the stepping state has to move
      -- to the new window or the next key would step a dead one.
      allow_reuse = false
      agents_view.open_under_cursor()
      press("<C-n>")
      press("<C-n>")
      expect(opened[3]).to_be("/proj/c.lua")
    end)

    it("coalesces a held key into one open at a time", function()
      -- Otherwise every repeat starts its own asynchronous transcript read and
      -- they land in whatever order they finish.
      agents_view.open_under_cursor()
      defer_opens = true
      press("<C-n>") -- aim: row 2
      press("<C-n>") -- aim: row 4 (row 3 has no file)
      press("<C-n>") -- aim: row 1, wrapping
      expect(#opened).to_be(2) -- the first row, plus one open in flight
      expect(opened[2]).to_be("/proj/b.lua")

      pending[1]() -- that open lands, and the aim has moved on
      expect(#opened).to_be(3)
      expect(opened[3]).to_be("/proj/a.lua") -- straight to where the key settled
    end)

    it("steps with the same baseline the float was opened with", function()
      agents_view.diff_head_under_cursor()
      expect(opened[1]).to_be("HEAD:/proj/a.lua")
      press("<C-n>")
      expect(opened[2]).to_be("HEAD:/proj/b.lua")
    end)

    describe("a row that is a tool call", function()
      before_each(function()
        payloads[3] = { kind = "tool", tool = "Bash", tool_id = "toolu_3", label = "run it", status = "done" }
        package.loaded["claudecode.agents.tool_view"] = {
          open = function(opts, done)
            opened[#opened + 1] = "TOOL:" .. tostring(opts.tool_id)
            answer(opts, done)
          end,
        }
      end)

      after_each(function()
        package.loaded["claudecode.agents.tool_view"] = nil
      end)

      it("opens the call rather than a file", function()
        vim.api.nvim_win_set_cursor(agents_view._state().wins.changes, { 3, 0 })
        agents_view.open_under_cursor()
        expect(opened[1]).to_be("TOOL:toolu_3")
      end)

      it("is stepped onto like any other row", function()
        -- The float is a view of one row, and a row that is a command has as much
        -- to show as one that is a file.
        agents_view.open_under_cursor()
        press("<C-n>")
        press("<C-n>")
        expect(opened[3]).to_be("TOOL:toolu_3")
      end)

      it("is skipped by a float showing a file against HEAD", function()
        -- `.` asks what is uncommitted in a file, which a command has no answer
        -- to at all — and warning on every repeat of a held key would be noise.
        agents_view.diff_head_under_cursor()
        press("<C-n>")
        press("<C-n>")
        expect(opened[3]).to_be("HEAD:/proj/c.lua")
      end)

      it("says so rather than opening nothing when asked for a file", function()
        local warned = {}
        local logger = require("claudecode.logger")
        local real = logger.warn
        logger.warn = function(_, message)
          warned[#warned + 1] = message
        end
        vim.api.nvim_win_set_cursor(agents_view._state().wins.changes, { 3, 0 })
        agents_view.diff_head_under_cursor()
        agents_view.goto_file_under_cursor()
        logger.warn = real
        expect(#warned).to_be(2)
        expect(warned[1]:find("not a file", 1, true) ~= nil).to_be_true()
        expect(#opened).to_be(0)
      end)
    end)
  end)

  describe("`gf` on a Changes or Activity row", function()
    local render, payload, tmp

    before_each(function()
      tmp = os.tmpname()
      local handle = assert(io.open(tmp, "w"))
      handle:write("one\ntwo\nthree\n")
      handle:close()

      payload = { path = tmp, line = 2 }
      render = require("claudecode.agents.render")
      render.payload_at = function()
        return payload
      end
      vim._last_command = nil
    end)

    after_each(function()
      os.remove(tmp)
      package.loaded["claudecode.agents.render"] = nil
    end)

    it("opens the file itself in a new tab", function()
      -- Not a float: `<CR>` and `.` are for reading what happened to the file,
      -- and this is for working in it.
      expect(agents_view.goto_file_under_cursor()).to_be(nil)
      expect(vim._last_command).to_be("tabnew " .. tmp)
    end)

    it("refuses a file that is no longer on disk", function()
      -- A row records work, and that work may have been a delete. `tabnew` on a
      -- missing path would open an empty buffer that saves a resurrected file.
      payload = { path = tmp .. ".gone" }
      expect(agents_view.open_file_in_tab(payload.path)).to_be(false)
      expect(vim._last_command).to_be(nil)
    end)

    it("does nothing on a row with no file on it", function()
      payload = {}
      agents_view.goto_file_under_cursor()
      expect(vim._last_command).to_be(nil)
    end)
  end)

  describe("the help window's contents", function()
    ---Through `config.apply`, since the help lists whatever `keymaps` resolves
    ---to and a bare table has no defaults to resolve.
    local function setup_with(agents)
      package.loaded["claudecode.config"] = nil
      local applied = require("claudecode.config").apply({ agents = agents })
      agents_view.setup(applied)
    end

    ---@return table<string, string> desc keyed by lhs
    local function keys_for(pane)
      local found = {}
      for _, group in ipairs(agents_view.help_entries(pane)) do
        for _, key in ipairs(group.keys) do
          found[key.lhs] = key.desc
        end
      end
      return found
    end

    it("lists a pane's own keys and the ones that work anywhere", function()
      setup_with({ enabled = true })
      local sessions = keys_for("sessions")
      expect(sessions["dd"]).to_be_string() -- this pane
      expect(sessions["a"]).to_be_string()
      expect(sessions["<C-n>"]).to_be_string() -- and everywhere
      expect(sessions["?"]).to_be_string()
    end)

    it("does not offer a pane keys that never reach it", function()
      setup_with({ enabled = true })
      local changes = keys_for("changes")
      expect(changes["dd"]).to_be(nil)
      expect(changes["a"]).to_be(nil)
      expect(changes["<CR>"]).to_be_string() -- open the file, not select a session
      expect(changes["<Tab>"]).to_be_string()
    end)

    it("offers the file keys only where there is a file", function()
      setup_with({ enabled = true })
      expect(keys_for("changes")["gf"]).to_be_string()
      expect(keys_for("feed")["gf"]).to_be_string()
      -- A session row is not a file, so `gf` is free there and means the other
      -- thing you might go looking for: the conversation itself.
      expect(keys_for("sessions")["gf"]).to_be(
        "Search this project's conversations for what was said in them (<Tab> reaches further)"
      )
    end)

    it("offers the activity filter only where there are two kinds of row", function()
      setup_with({ enabled = true })
      expect(keys_for("feed")["f"]).to_be_string()
      expect(keys_for("changes")["f"]).to_be(nil)
      expect(keys_for("sessions")["f"]).to_be(nil)
    end)

    it("offers the sort menu from every pane that shows the list", function()
      -- Re-ordering the list should not first mean navigating back to it.
      setup_with({ enabled = true })
      expect(keys_for("sessions")["gs"]).to_be_string()
      expect(keys_for("feed")["gs"]).to_be_string()
      expect(keys_for("changes")["gs"]).to_be_string()
      expect(keys_for("center")["gs"]).to_be(nil) -- `gs` belongs to Claude there
    end)

    it("groups them under headings, this pane's first", function()
      setup_with({ enabled = true })
      local groups = agents_view.help_entries("sessions")
      expect(#groups).to_be(2)
      expect(groups[1].group).to_be("Sessions")
      expect(groups[2].group).to_be("Anywhere in the view")
    end)

    it("leaves out a key the user turned off", function()
      -- A help window that lists a key doing nothing is worse than a short one.
      setup_with({ enabled = true, keymaps = { new = false, delete = "" } })
      local sessions = keys_for("sessions")
      expect(sessions["a"]).to_be(nil)
      expect(sessions["dd"]).to_be(nil)
      expect(sessions["x"]).to_be_string()
    end)
  end)

  describe("deleting a session", function()
    local asked, deleted, live, rows

    before_each(function()
      asked, deleted, live = {}, {}, {}
      -- One session per line, so a count or a visual range covers a known set.
      rows = { "aaa", "bbb", "ccc", "ddd" }

      -- The action reads the rows the range covers and asks before doing anything,
      -- so both are stubbed: the question is what it decides, not how it draws.
      package.loaded["claudecode.agents.render"] = {
        setup = function() end,
        payload_at = function(_, lnum)
          local id = rows[lnum]
          return id and { session_id = id } or nil
        end,
      }
      package.loaded["claudecode.agents.registry"] = {
        is_live = function(id)
          return live[id] == true
        end,
      }
      package.loaded["claudecode.agents.model"] = {
        setup = function() end,
        on_change = function() end,
        row = function(id)
          return { session_id = id, title = "Session " .. id, added = 3, removed = 1 }
        end,
        foreign_state = function() end,
        delete_sessions = function(ids)
          for _, id in ipairs(ids) do
            deleted[#deleted + 1] = id
          end
          return ids, {}
        end,
      }
      package.loaded["claudecode.agents.confirm"] = {
        ask = function(opts, cb)
          asked[#asked + 1] = opts
          cb(asked.answer ~= false)
        end,
      }

      package.loaded["claudecode.agents_view"] = nil
      agents_view = require("claudecode.agents_view")
      agents_view.setup(base_config({ enabled = true }))
    end)

    after_each(function()
      for _, name in ipairs({ "render", "registry", "model", "confirm" }) do
        package.loaded["claudecode.agents." .. name] = nil
      end
      package.loaded["claudecode.agents_view"] = nil
    end)

    it("asks first, then deletes", function()
      agents_view.delete_under_cursor()
      expect(#asked).to_be(1)
      expect(asked[1].message).to_be_table()
      expect(deleted[1]).to_be("aaa")
      expect(#deleted).to_be(1)
    end)

    it("deletes nothing when the answer is no", function()
      asked.answer = false
      agents_view.delete_under_cursor()
      expect(#deleted).to_be(0)
    end)

    it("refuses while the agent is running, without asking", function()
      -- The CLI still has the transcript open; the row would come straight back.
      live.aaa = true
      agents_view.delete_under_cursor()
      expect(#asked).to_be(0)
      expect(#deleted).to_be(0)
    end)

    it("takes a count, and asks once for the batch", function()
      agents_view.delete_under_cursor(3)
      expect(#asked).to_be(1)
      expect(asked[1].title).to_be("Delete 3 sessions")
      expect(table.concat(deleted, ",")).to_be("aaa,bbb,ccc")
    end)

    it("deletes every session a range covers", function()
      agents_view.delete_range(2, 4)
      expect(table.concat(deleted, ",")).to_be("bbb,ccc,ddd")
    end)

    it("stops at the end of the list rather than erroring", function()
      -- A count or a selection dragged past the last row is a normal gesture.
      agents_view.delete_range(3, 40)
      expect(table.concat(deleted, ",")).to_be("ccc,ddd")
    end)

    it("leaves a running agent in the middle of a range alone", function()
      -- One busy agent must not veto the whole gesture — the dialog says how many
      -- were skipped, and by which key they can be stopped.
      live.ccc = true
      agents_view.delete_range(1, 4)
      expect(table.concat(deleted, ",")).to_be("aaa,bbb,ddd")
      expect(#asked).to_be(1)
      local said_so = false
      for _, line in ipairs(asked[1].message) do
        if line:match("1 still running") then
          said_so = true
        end
      end
      expect(said_so).to_be_true()
    end)

    it("names only the first few, then counts the rest", function()
      rows = {}
      for index = 1, 12 do
        rows[index] = ("id%02d"):format(index)
      end
      agents_view.delete_range(1, 12)
      expect(#deleted).to_be(12)
      local more = false
      for _, line in ipairs(asked[1].message) do
        if line:match("and 4 more") then
          more = true
        end
      end
      expect(more).to_be_true()
    end)

    it("binds a doubled key under its single form in visual mode", function()
      -- `dd` is the linewise form of `d`; over a selection the range *is* the
      -- selection, so a second press would only extend it.
      expect(agents_view._visual_lhs("dd")).to_be("d")
      expect(agents_view._visual_lhs("X")).to_be("X")
      expect(agents_view._visual_lhs("<C-d>")).to_be("<C-d>")
    end)
  end)

  describe("hook ingestion", function()
    it("ignores events while disabled", function()
      agents_view.setup(base_config({ enabled = false }))
      local ok = pcall(agents_view.note, { hook_event_name = "PostToolUse", tool_name = "Edit", session_id = "x" })
      expect(ok).to_be_true()
    end)
  end)

  describe("an agent that ran /clear", function()
    local rekeyed, changed, selected, refreshed

    before_each(function()
      rekeyed, changed, selected, refreshed = {}, {}, {}, 0

      package.loaded["claudecode.agents.registry"] = {
        -- The launch key is what stays put; the conversation is what moves.
        rekey = function(agent_key, session_id, opts)
          rekeyed[#rekeyed + 1] = { agent_key, session_id, opts and opts.reclaim }
          return agent_key == "1:old" and "old" or nil
        end,
        is_live = function()
          return false
        end,
        live_ids = function()
          return {}
        end,
      }
      package.loaded["claudecode.agents.model"] = {
        setup = function() end,
        on_change = function() end,
        note = function() end,
        note_session_change = function(previous, session_id)
          changed[#changed + 1] = { previous, session_id }
          return previous == "old"
        end,
        refresh_list = function()
          refreshed = refreshed + 1
        end,
        select = function(session_id)
          selected[#selected + 1] = session_id
        end,
        set_armed = function() end,
      }

      package.loaded["claudecode.agents_view"] = nil
      agents_view = require("claudecode.agents_view")
      agents_view.setup(base_config({ enabled = true }))
    end)

    after_each(function()
      package.loaded["claudecode.agents.registry"] = nil
      package.loaded["claudecode.agents.model"] = nil
      package.loaded["claudecode.agents_view"] = nil
    end)

    it("moves the agent onto the conversation the hook reports", function()
      agents_view.note({ hook_event_name = "SessionStart", session_id = "new" }, 1, "1:old")
      expect(#rekeyed).to_be(1)
      expect(rekeyed[1][1]).to_be("1:old")
      expect(rekeyed[1][2]).to_be("new")
      expect(changed[1][1]).to_be("old")
      expect(changed[1][2]).to_be("new")
    end)

    it("lists it at once rather than on the next poll", function()
      -- No transcript exists until the first message, so nothing on disk would
      -- turn the running agent up.
      agents_view.note({ hook_event_name = "SessionStart", session_id = "new" }, 1, "1:old")
      expect(refreshed).to_be(1)
    end)

    it("takes the selection with it when it was on the old conversation", function()
      agents_view.note({ hook_event_name = "SessionStart", session_id = "new" }, 1, "1:old")
      expect(selected[1]).to_be("new")
    end)

    it("only lets a SessionStart claim a conversation the agent already left", function()
      -- Every other event may be a late report from the chat it just abandoned;
      -- the two events describing a /clear arrive in either order.
      agents_view.note({ hook_event_name = "SessionStart", session_id = "new" }, 1, "1:old")
      agents_view.note({ hook_event_name = "SessionEnd", session_id = "old" }, 1, "1:old")
      expect(rekeyed[1][3]).to_be_true()
      expect(rekeyed[2][3]).to_be(false)
    end)

    it("does nothing for a launch it does not know, or one that has not moved", function()
      agents_view.note({ hook_event_name = "SessionStart", session_id = "new" }, 1, "9:other")
      agents_view.note({ hook_event_name = "SessionStart", session_id = "x" }, 1, nil)
      expect(#changed).to_be(0)
      expect(refreshed).to_be(0)
    end)
  end)
end)
