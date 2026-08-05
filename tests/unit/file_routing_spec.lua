-- luacheck: globals expect
require("tests.busted_setup")

--- Where a file goes, for the three callers that have to put one somewhere.
---
--- Until this seam existed only the diff provider knew the rules; `openFile` and
--- a clicked terminal link each had their own ladder ending in a `vsplit`, and in
--- a tab that owns its layout that fallback fired every time and split whichever
--- pane happened to be current.
describe("file routing", function()
  local diff, float

  local function base_config(overrides)
    return vim.tbl_deep_extend("force", {
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
    }, overrides or {})
  end

  ---A tab that owns its layout, with an ordinary tab to fall back to.
  local function owning_tab(tab, origin)
    vim._tabs[tab] = true
    vim.api.nvim_tabpage_set_var(tab, "claudecode_layout_owner", {
      forbids_split = true,
      host = "float",
      float_module = "claudecode.agents.float",
      origin = origin,
    })
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    for _, name in ipairs({ "claudecode.diff", "claudecode.float", "claudecode.agents.float" }) do
      package.loaded[name] = nil
    end
    diff = require("claudecode.diff")
    float = require("claudecode.float")
    diff.setup(base_config())
    float.setup(base_config())
    float.reset()
  end)

  describe("in a tab that owns its layout", function()
    it("floats an agent's openFile rather than splitting a pane", function()
      owning_tab(3, 1)
      local win, kind = diff.resolve_target_window({
        tab = 3,
        purpose = "open",
        file_path = "/proj/plan.md",
        session_id = "aaaabbbb",
      })
      expect(kind).to_be("float")
      expect(win).not_to_be_nil()
      expect(float.count()).to_be(1)
      expect(vim.w[win].claudecode_agents_float).to_be_true()
    end)

    it("titles the float with the file and the conversation", function()
      owning_tab(3, 1)
      diff.resolve_target_window({
        tab = 3,
        purpose = "open",
        file_path = "/proj/plan.md",
        session_id = "aaaabbbbcccc",
      })
      local title = float.list()[1].title
      expect(title:find("plan.md", 1, true)).not_to_be_nil()
      -- Only the first 8 characters, which is what tells two agents apart.
      expect(title:find("aaaabbbb", 1, true)).not_to_be_nil()
    end)

    it("records what a float is for, so a plan dismissal spares a pending diff", function()
      owning_tab(3, 1)
      diff.resolve_target_window({ tab = 3, purpose = "open", file_path = "/proj/plan.md", session_id = "s1" })
      diff.resolve_target_window({ tab = 3, purpose = "diff", file_path = "/proj/a.lua", session_id = "s1" })

      expect(float.close_all("s1", "open")).to_be(1)
      expect(float.count()).to_be(1)
      expect(float.list()[1].purpose).to_be("diff")
    end)

    it("sends a clicked path to the tab the view was opened from", function()
      -- A click is the user's action, not the agent's: it goes somewhere they can
      -- work in, and focusing it takes them there.
      owning_tab(3, 1)
      vim._mock.add_window(2001, 1)
      vim._win_tab[2001] = 1
      vim._tab_windows[1] = { 2001 }

      local win, kind = diff.resolve_target_window({ tab = 3, purpose = "click", file_path = "/proj/a.lua" })
      expect(kind).to_be("window")
      expect(win).to_be(2001)
      expect(float.count()).to_be(0)
    end)

    it("falls back to a float when the origin tab has gone", function()
      owning_tab(3, 999)
      local win, kind = diff.resolve_target_window({ tab = 3, purpose = "click", file_path = "/proj/a.lua" })
      expect(kind).to_be("float")
      expect(win).not_to_be_nil()
    end)

    it("never answers with a window a split would have to make", function()
      -- The whole point: no suitable editor window exists in such a tab, and the
      -- old ladders responded by splitting one of the panes.
      owning_tab(3, nil)
      local _, kind = diff.resolve_target_window({ tab = 3, purpose = "open" })
      expect(kind).to_be("float")
    end)
  end)

  describe("in an ordinary tab", function()
    it("uses the caller's own candidates when it supplies them", function()
      -- `openFile` filters out `nofile` windows, which a diff legitimately may
      -- reuse; picking by screen geometry instead would silently widen that.
      vim._mock.add_window(2002, 1)
      local win, kind = diff.resolve_target_window({
        tab = 1,
        purpose = "open",
        candidates = { 2002 },
      })
      expect(kind).to_be("window")
      expect(win).to_be(2002)
      expect(float.count()).to_be(0)
    end)

    it("opens no float at all", function()
      local _, kind = diff.resolve_target_window({ tab = 1, purpose = "open", candidates = {} })
      expect(kind).to_be_nil()
      expect(float.count()).to_be(0)
    end)
  end)
end)
