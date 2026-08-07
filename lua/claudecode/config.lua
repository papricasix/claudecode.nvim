---@brief [[
--- Manages configuration for the Claude Code Neovim integration.
--- Provides default settings, validation, and application of user-defined configurations.
---@brief ]]
---@module 'claudecode.config'

local M = {}

---@type ClaudeCodeConfig
M.defaults = {
  port_range = { min = 10000, max = 65535 },
  auto_start = true,
  terminal_cmd = nil,
  env = {}, -- Custom environment variables for Claude terminal
  log_level = "info",
  track_selection = true,
  -- When true, focus Claude terminal after a successful send while connected
  focus_after_send = false,
  visual_demotion_delay_ms = 50, -- Milliseconds to wait before demoting a visual selection
  connection_wait_delay = 600, -- Milliseconds to wait after connection before sending queued @ mentions
  connection_timeout = 10000, -- Maximum time to wait for Claude Code to connect (milliseconds)
  queue_timeout = 5000, -- Maximum time to keep @ mentions in queue (milliseconds)
  diff_opts = {
    provider = "auto", -- "auto" (use unified.nvim if installed, else native), "native", or "unified"
    -- "vertical" / "horizontal" split, or "float" to open the diff in a floating
    -- window. Agents mode uses a float regardless, since none of its panes is an
    -- editor window a diff could take over.
    layout = "vertical",
    open_in_new_tab = false, -- Open diff in a new tab (false = use current tab). Ignored by the unified provider.
    keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens (including floating terminals)
    hide_terminal_in_new_tab = false, -- If true and opening in a new tab, do not show Claude terminal there
    on_new_file_reject = "keep_empty", -- "keep_empty" leaves an empty buffer; "close_window" closes the placeholder split
  },
  -- Geometry for every floating window Claude opens for a file or a diff:
  -- `diff_opts.layout = "float"`, and agents mode, which floats regardless since
  -- none of its panes is an editor window a diff could take over. `agents.float`
  -- overrides this for agent-opened floats; nothing else needs to.
  float = {
    width = 0.7, -- fraction of the screen
    height = 0.7,
    border = "rounded", -- any 'winborder'-style value nvim_open_win accepts
    cascade_offset = 2, -- rows/columns each stacked float is offset by
  },
  live_cursor = {
    enabled = false, -- master switch (opt-in)
    mode = nil, -- REQUIRED when enabled: "preview" (reserved split) or "open" (current window)
    layout = "horizontal", -- "vertical" or "horizontal" split for the preview window (preview mode only)
    split_size_percentage = 0.5, -- preview split size as a fraction of the screen (0..1): height for horizontal, width for vertical
    highlight = "ClaudeCodeLiveCursor", -- highlight group; defaults to a link to Visual
    clear_delay_ms = 4000, -- auto-clear the highlight after this much inactivity (0 disables)
    diff_suppress_ms = 250, -- wait window to detect an openDiff before painting an edit
    -- Visual markers so you can tell a split is a live preview (preview mode only):
    preview_winbar = true, -- show a colored winbar label at the top of the preview window
    preview_divider = true, -- tint the preview window's split divider (WinSeparator)
    preview_label = "● Claude live preview", -- winbar brand text (the file name and read/write action are appended)
    preview_align = "center", -- winbar alignment: "center" or "left"
    preview_highlight = "ClaudeCodeLivePreview", -- highlight group for the marker; defaults to a link to DiagnosticOk (green)
  },
  plan = {
    enabled = false, -- opt-in: render Claude's plan-mode plan in an editor split
    layout = "vertical", -- "vertical" or "horizontal" split for the plan window
    split_size_percentage = 0.5, -- plan split size as a fraction of the screen (0..1)
    focus = true, -- move focus into the plan window when it opens
    close_on_resolve = true, -- close the plan window when the plan is accepted/rejected
    clear_delay_ms = 0, -- inactivity backstop close (0 = rely on the resolve signals)
    label = "● Claude plan", -- winbar brand text for the plan window
    highlight = "ClaudeCodePlan", -- winbar highlight group; defaults to a link to DiagnosticInfo
  },
  -- Per-tab Claude activity ("busy" / "waiting" for you / "idle"), published for
  -- tablines, statuslines and other plugins (see claudecode.status). Opt-in: it
  -- widens the injected hook set to every tool call.
  status = {
    enabled = false,
    -- A glyph per state, or a list of frames to animate that state:
    --   icons = { busy = require("claudecode.status").SPINNER }
    -- animates a working tab with the CLI's own spinner.
    icons = { busy = "●", waiting = "◆", done = "●", idle = "○", none = "" },
    spinner_ms = 120, -- frame interval for animated icons (0 disables animation)
    highlights = {
      busy = "ClaudeCodeStatusBusy", -- defaults to a link to DiagnosticInfo
      waiting = "ClaudeCodeStatusWaiting", -- defaults to a link to DiagnosticWarn
      done = "ClaudeCodeStatusDone", -- finished but unread; defaults to a link to DiagnosticOk
      idle = "ClaudeCodeStatusIdle", -- defaults to a link to Comment
    },
    auto_redraw = true, -- redraw the tabline/statusline whenever a tab's state changes
  },
  -- Agents mode: a dedicated tabpage running several Claudes side by side, with
  -- the project's past sessions on the right, the selected agent's activity below
  -- them, and the files it touched on the left (see claudecode.agents_view).
  -- Opt-in: it can widen the injected hook set the way `status` does.
  agents = {
    enabled = false,
    -- What drives live updates:
    --   "hooks" - Claude Code's own lifecycle hooks (sub-second, one headless
    --             nvim per tool call per running agent)
    --   "poll"  - watch each transcript's mtime while the view is visible
    --             (nearly free; status lags by up to poll_ms)
    --   "auto"  - hooks when `status.enabled` (you already pay for them), else poll
    source = "auto",
    poll_ms = 500,
    layout = {
      left_width = 0.23, -- Changes pane, as a fraction of the screen
      right_width = 0.23, -- Sessions/Activity pane, as a fraction of the screen (0.54 left for the terminal)
      sessions_height = 0.55, -- Sessions share of the right column (it is the pane you steer from)
    },
    sessions = {
      limit = 30, -- most recent transcripts to list
      include_empty = true, -- list conversations that never changed a file (false hides them once known)
      -- The order the list opens in: "recent" | "name" | "changes" | "status"
      -- ("title" and "added" are the old names for "name" and "changes"). The
      -- list is then **frozen** — rows keep their places instead of shuffling as
      -- agents work — and `gs` re-sorts it, for as long as the view is open.
      sort = "recent",
      foreign = true, -- also list Claudes running in your other tabs
    },
    feed_limit = 500, -- activity events kept per session
    refresh_ms = 150, -- coalescing window for redraws
    list_refresh_ms = 2000, -- how often the session list is re-enumerated
    git = true, -- annotate the Changes pane with git status letters
    git_refresh_ms = 1500,
    -- Deliberately unset: the animation's pace is `status.spinner_ms`, since it
    -- is one spinner however many places show it. Set this only to make the
    -- agents view run at a different rate from the tabline.
    spinner_ms = nil,
    -- New Activity rows arrive at full colour and settle; changed +N/-N light up
    -- and drop back. Sampled by the spinner's frame tick, so `auto_redraw =
    -- false` or `spinner_ms = 0` means a span reaches its resting colour on the
    -- next redraw rather than travelling there.
    -- `fade` is deliberately **absent here**, with its defaults owned by
    -- `agents/fade.lua` alone. Spelling them out in both places is not
    -- redundancy, it is a silent override: `fade.opts()` merges the applied
    -- config over its own table, so every key present here wins and the module's
    -- own defaults become dead code. That is exactly what happened — two rounds
    -- of retuning the timings changed nothing the user could see, because these
    -- copies kept overriding them. See the README for the shape and the
    -- validator below for the accepted ranges.
    fold_batch = 2, -- transcripts folded per tick while filling the list
    follow_cursor = false, -- selecting follows the cursor in the sessions pane
    restore_panes = true, -- rebuild a sidebar the user closed
    kill_on_close = false, -- stop running agents when the view closes
    focus = "center", -- "center" | "sessions": where the cursor lands on open
    resume_mode = "resume", -- "resume" | "fork" (--fork-session) for an existing conversation
    float = {
      width = 0.7,
      height = 0.7,
      border = "rounded",
      cascade_offset = 2, -- rows/columns each stacked float is offset by
    },
    keymaps = {
      select = "<CR>",
      new = "a",
      stop = "x", -- stop the running agent (keeps the conversation)
      delete = "dd", -- delete the conversation from disk, after a confirmation
      refresh = "r", -- re-read the sessions, and re-sort the list
      sort = "gs", -- choose what the list is ordered by (it does not re-sort itself)
      close = "q",
      open = "<CR>", -- open the file under the cursor (Activity / Changes panes)
      git_diff = ".", -- diff that file against git HEAD instead of against the session
      goto_file = "gf", -- open the file itself, on disk, in a new tab
      help = "?", -- show the keys that reach the pane you are in
      next_pane = "<Tab>",
      focus_term = "i",
      -- Cycle the selected session from anywhere in the tab, the agent's terminal
      -- included (bound there in terminal mode too). Set to false to leave the
      -- keys to Claude.
      next_session = "<C-n>",
      prev_session = "<C-p>",
    },
    highlights = {
      title = "ClaudeCodeAgentsTitle", -- defaults to a link to Normal
      time = "ClaudeCodeAgentsTime", -- defaults to a link to Comment
      added = "ClaudeCodeAgentsAdded", -- defaults to a link to DiffAdd
      removed = "ClaudeCodeAgentsRemoved", -- defaults to a link to DiffDelete
      selected = "ClaudeCodeAgentsSelected", -- defaults to a link to CursorLine
      path = "ClaudeCodeAgentsPath", -- defaults to a link to Directory
      float = "ClaudeCodeAgentsFloat", -- defaults to a link to FloatBorder
      -- Terminal pane background: follows SnacksNormal when snacks is loaded,
      -- else NormalFloat. The sidebars keep the editor's own Normal.
      normal = "ClaudeCodeAgentsNormal",
      normal_nc = "ClaudeCodeAgentsNormalNC",
    },
    auto_redraw = true,
  },
  -- Per-tab Claude conversations survive a Neovim restart, riding whatever
  -- already persists your Neovim session (see claudecode.session_state):
  --   "off"      - do not track session ids (default)
  --   "global"   - mirror them into g:CLAUDECODE_SESSION (needs 'sessionoptions'
  --                to contain "globals"); restored on SessionLoadPost
  --   "external" - track them, store nothing: a session manager calls
  --                session_state.capture()/restore() itself
  session_persistence = "off",
  terminal_links = {
    enabled = true, -- open file paths clicked in the Claude terminal in the editor (VS Code parity)
    click = true, -- intercept plain <LeftMouse> on a file:// link (non-links pass through to Claude)
    key = "gf", -- normal-mode keymap on the terminal buffer to open the path under the cursor ("" disables)
    mouse_motion = true, -- enable 'mousemoveevent' so mouse motion reaches Claude and its own link hover works
  },
  -- `value` is passed verbatim to `claude --model`. These short aliases resolve
  -- to the latest model on the Anthropic API, so labels stay version-free to
  -- avoid going stale on every release.
  models = {
    { name = "Claude Opus (Latest)", value = "opus" },
    { name = "Claude Opus (Latest, 1M context)", value = "opus[1m]" },
    { name = "Claude Sonnet (Latest)", value = "sonnet" },
    { name = "Claude Sonnet (Latest, 1M context)", value = "sonnet[1m]" },
    { name = "Claude Haiku (Latest)", value = "haiku" },
    { name = "Claude Fable (Latest)", value = "fable" },
    { name = "Default (account recommended)", value = "default" },
  },
  terminal = nil, -- Will be lazy-loaded to avoid circular dependency
}

---Validate a float geometry table.
---
---Shared, because there are two of them and they must accept exactly the same
---shape: the top-level `float` block, and `agents.float`, which overrides it for
---agent-opened floats. Two hand-written copies of one key list is how the
---`agents.highlights` lists drifted from their defaults.
---@param float table|nil nil skips every check.
---@param label string Prefix for the error message.
function M.validate_float(float, label)
  if float == nil then
    return
  end
  assert(type(float) == "table", label .. " must be a table")
  local function check(field, ok, msg)
    if float[field] ~= nil then
      assert(ok(float[field]), label .. "." .. field .. " " .. msg)
    end
  end
  local function is_fraction(v)
    return type(v) == "number" and v > 0 and v < 1
  end
  check("width", is_fraction, "must be a number between 0 and 1")
  check("height", is_fraction, "must be a number between 0 and 1")
  check("border", function(v)
    return type(v) == "string" or type(v) == "table"
  end, "must be a string or a table")
  check("cascade_offset", function(v)
    return type(v) == "number" and v >= 0
  end, "must be a non-negative number")
end

---Validates the provided configuration table.
---Throws an error if any validation fails.
---@param config table The configuration table to validate.
---@return boolean true if the configuration is valid.
function M.validate(config)
  assert(
    type(config.port_range) == "table"
      and type(config.port_range.min) == "number"
      and type(config.port_range.max) == "number"
      and config.port_range.min > 0
      and config.port_range.max <= 65535
      and config.port_range.min <= config.port_range.max,
    "Invalid port range"
  )

  assert(type(config.auto_start) == "boolean", "auto_start must be a boolean")

  assert(config.terminal_cmd == nil or type(config.terminal_cmd) == "string", "terminal_cmd must be nil or a string")

  -- Validate terminal config
  assert(type(config.terminal) == "table", "terminal must be a table")

  -- Validate provider_opts if present
  if config.terminal.provider_opts then
    assert(type(config.terminal.provider_opts) == "table", "terminal.provider_opts must be a table")

    -- Validate external_terminal_cmd in provider_opts
    if config.terminal.provider_opts.external_terminal_cmd then
      local cmd_type = type(config.terminal.provider_opts.external_terminal_cmd)
      assert(
        cmd_type == "string" or cmd_type == "function",
        "terminal.provider_opts.external_terminal_cmd must be a string or function"
      )
      -- Only validate %s placeholder for strings
      if cmd_type == "string" and config.terminal.provider_opts.external_terminal_cmd ~= "" then
        assert(
          config.terminal.provider_opts.external_terminal_cmd:find("%%s"),
          "terminal.provider_opts.external_terminal_cmd must contain '%s' placeholder for the Claude command"
        )
      end
    end
  end

  local valid_log_levels = { "trace", "debug", "info", "warn", "error" }
  local is_valid_log_level = false
  for _, level in ipairs(valid_log_levels) do
    if config.log_level == level then
      is_valid_log_level = true
      break
    end
  end
  assert(is_valid_log_level, "log_level must be one of: " .. table.concat(valid_log_levels, ", "))

  assert(type(config.track_selection) == "boolean", "track_selection must be a boolean")
  -- Allow absence in direct validate() calls; apply() supplies default
  if config.focus_after_send ~= nil then
    assert(type(config.focus_after_send) == "boolean", "focus_after_send must be a boolean")
  end

  assert(
    type(config.visual_demotion_delay_ms) == "number" and config.visual_demotion_delay_ms >= 0,
    "visual_demotion_delay_ms must be a non-negative number"
  )

  assert(
    type(config.connection_wait_delay) == "number" and config.connection_wait_delay >= 0,
    "connection_wait_delay must be a non-negative number"
  )

  assert(
    type(config.connection_timeout) == "number" and config.connection_timeout > 0,
    "connection_timeout must be a positive number"
  )

  assert(type(config.queue_timeout) == "number" and config.queue_timeout > 0, "queue_timeout must be a positive number")

  assert(type(config.diff_opts) == "table", "diff_opts must be a table")
  if config.diff_opts.provider ~= nil then
    local p = config.diff_opts.provider
    assert(
      type(p) == "string" and (p == "auto" or p == "native" or p == "unified"),
      "diff_opts.provider must be 'auto', 'native', or 'unified'"
    )
  end
  -- New diff options (optional validation to allow backward compatibility)
  if config.diff_opts.layout ~= nil then
    assert(
      config.diff_opts.layout == "vertical"
        or config.diff_opts.layout == "horizontal"
        or config.diff_opts.layout == "float",
      "diff_opts.layout must be 'vertical', 'horizontal' or 'float'"
    )
  end
  if config.diff_opts.open_in_new_tab ~= nil then
    assert(type(config.diff_opts.open_in_new_tab) == "boolean", "diff_opts.open_in_new_tab must be a boolean")
  end
  if config.diff_opts.keep_terminal_focus ~= nil then
    assert(type(config.diff_opts.keep_terminal_focus) == "boolean", "diff_opts.keep_terminal_focus must be a boolean")
  end
  if config.diff_opts.hide_terminal_in_new_tab ~= nil then
    assert(
      type(config.diff_opts.hide_terminal_in_new_tab) == "boolean",
      "diff_opts.hide_terminal_in_new_tab must be a boolean"
    )
  end
  if config.diff_opts.on_new_file_reject ~= nil then
    assert(
      type(config.diff_opts.on_new_file_reject) == "string"
        and (
          config.diff_opts.on_new_file_reject == "keep_empty" or config.diff_opts.on_new_file_reject == "close_window"
        ),
      "diff_opts.on_new_file_reject must be 'keep_empty' or 'close_window'"
    )
  end

  M.validate_float(config.float, "float")

  -- Legacy diff options (accept if present to avoid breaking old configs)
  if config.diff_opts.auto_close_on_accept ~= nil then
    assert(type(config.diff_opts.auto_close_on_accept) == "boolean", "diff_opts.auto_close_on_accept must be a boolean")
  end
  if config.diff_opts.show_diff_stats ~= nil then
    assert(type(config.diff_opts.show_diff_stats) == "boolean", "diff_opts.show_diff_stats must be a boolean")
  end
  if config.diff_opts.vertical_split ~= nil then
    assert(type(config.diff_opts.vertical_split) == "boolean", "diff_opts.vertical_split must be a boolean")
  end
  if config.diff_opts.open_in_current_tab ~= nil then
    assert(type(config.diff_opts.open_in_current_tab) == "boolean", "diff_opts.open_in_current_tab must be a boolean")
  end

  -- Validate live_cursor (optional; apply() supplies defaults)
  if config.live_cursor ~= nil then
    local lc = config.live_cursor
    assert(type(lc) == "table", "live_cursor must be a table")

    local function check(field, ok, msg)
      if lc[field] ~= nil then
        assert(ok(lc[field]), "live_cursor." .. field .. " " .. msg)
      end
    end
    local function is_bool(v)
      return type(v) == "boolean"
    end
    local function is_nonempty_string(v)
      return type(v) == "string" and v ~= ""
    end
    local function is_nonneg(v)
      return type(v) == "number" and v >= 0
    end

    check("enabled", is_bool, "must be a boolean")
    check("mode", function(v)
      return v == "preview" or v == "open"
    end, "must be 'preview' or 'open'")
    check("layout", function(v)
      return v == "vertical" or v == "horizontal"
    end, "must be 'vertical' or 'horizontal'")
    check("split_size_percentage", function(v)
      return type(v) == "number" and v > 0 and v <= 1
    end, "must be a number between 0 and 1")
    check("highlight", is_nonempty_string, "must be a non-empty string")
    check("preview_winbar", is_bool, "must be a boolean")
    check("preview_divider", is_bool, "must be a boolean")
    check("preview_label", function(v)
      return type(v) == "string"
    end, "must be a string")
    check("preview_align", function(v)
      return v == "center" or v == "left"
    end, "must be 'center' or 'left'")
    check("preview_highlight", is_nonempty_string, "must be a non-empty string")
    check("clear_delay_ms", is_nonneg, "must be a non-negative number")
    check("diff_suppress_ms", is_nonneg, "must be a non-negative number")

    if lc.enabled == true then
      assert(
        lc.mode == "preview" or lc.mode == "open",
        "live_cursor.mode is required when live_cursor.enabled is true (set it to 'preview' or 'open')"
      )
    end
  end

  -- Validate plan (optional; apply() supplies defaults)
  if config.plan ~= nil then
    local p = config.plan
    assert(type(p) == "table", "plan must be a table")

    local function check(field, ok, msg)
      if p[field] ~= nil then
        assert(ok(p[field]), "plan." .. field .. " " .. msg)
      end
    end

    check("enabled", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
    check("layout", function(v)
      return v == "vertical" or v == "horizontal"
    end, "must be 'vertical' or 'horizontal'")
    check("split_size_percentage", function(v)
      return type(v) == "number" and v > 0 and v <= 1
    end, "must be a number between 0 and 1")
    check("focus", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
    check("close_on_resolve", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
    check("clear_delay_ms", function(v)
      return type(v) == "number" and v >= 0
    end, "must be a non-negative number")
    check("label", function(v)
      return type(v) == "string"
    end, "must be a string")
    check("highlight", function(v)
      return type(v) == "string" and v ~= ""
    end, "must be a non-empty string")
  end

  -- Validate terminal_links (optional; apply() supplies defaults)
  if config.terminal_links ~= nil then
    local tl = config.terminal_links
    assert(type(tl) == "table", "terminal_links must be a table")

    local function check(field, ok, msg)
      if tl[field] ~= nil then
        assert(ok(tl[field]), "terminal_links." .. field .. " " .. msg)
      end
    end

    check("enabled", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
    check("click", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
    check("key", function(v)
      return type(v) == "string"
    end, "must be a string")
    check("mouse_motion", function(v)
      return type(v) == "boolean"
    end, "must be a boolean")
  end

  -- Validate agents (optional; apply() supplies defaults)
  if config.agents ~= nil then
    local ag = config.agents
    assert(type(ag) == "table", "agents must be a table")

    local function is_boolean(v)
      return type(v) == "boolean"
    end
    local function is_fraction(v)
      return type(v) == "number" and v > 0 and v < 1
    end
    local function is_positive(v)
      return type(v) == "number" and v > 0
    end
    ---A keymap is a string, or false to leave the key unbound.
    local function is_keymap(v)
      return type(v) == "string" or v == false
    end
    ---@param allowed string[]
    local function one_of(allowed)
      return function(v)
        if type(v) ~= "string" then
          return false
        end
        for _, candidate in ipairs(allowed) do
          if v == candidate then
            return true
          end
        end
        return false
      end
    end

    ---@param tbl table|nil Subtable being checked (nil skips every field).
    ---@param label string Prefix for the error message.
    local function checker(tbl, label)
      return function(field, ok, msg)
        if tbl ~= nil and tbl[field] ~= nil then
          assert(ok(tbl[field]), label .. "." .. field .. " " .. msg)
        end
      end
    end

    local check = checker(ag, "agents")
    check("enabled", is_boolean, "must be a boolean")
    check("source", one_of({ "hooks", "poll", "auto" }), 'must be "hooks", "poll" or "auto"')
    check("poll_ms", is_positive, "must be a positive number")
    check("feed_limit", is_positive, "must be a positive number")
    check("refresh_ms", is_positive, "must be a positive number")
    check("list_refresh_ms", is_positive, "must be a positive number")
    check("git", is_boolean, "must be a boolean")
    check("git_refresh_ms", is_positive, "must be a positive number")
    check("spinner_ms", function(v)
      return type(v) == "number" and v >= 0
    end, "must be a non-negative number")
    check("fold_batch", is_positive, "must be a positive number")
    check("follow_cursor", is_boolean, "must be a boolean")
    check("restore_panes", is_boolean, "must be a boolean")
    check("kill_on_close", is_boolean, "must be a boolean")
    check("focus", one_of({ "center", "sessions" }), 'must be "center" or "sessions"')
    check("resume_mode", one_of({ "resume", "fork" }), 'must be "resume" or "fork"')
    check("auto_redraw", is_boolean, "must be a boolean")

    if ag.layout ~= nil then
      assert(type(ag.layout) == "table", "agents.layout must be a table")
      local check_layout = checker(ag.layout, "agents.layout")
      check_layout("left_width", is_fraction, "must be a number between 0 and 1")
      check_layout("right_width", is_fraction, "must be a number between 0 and 1")
      check_layout("sessions_height", is_fraction, "must be a number between 0 and 1")
    end

    if ag.fade ~= nil and ag.fade ~= false then
      assert(type(ag.fade) == "table", "agents.fade must be a table, or false to disable it")
      local check_fade = checker(ag.fade, "agents.fade")
      check_fade("enabled", is_boolean, "must be a boolean")
      check_fade("bold", is_boolean, "must be a boolean")
      for _, field in ipairs({ "hold_ms", "step_ms", "flash_ms" }) do
        check_fade(field, function(v)
          return type(v) == "number" and v >= 0
        end, "must be a non-negative number")
      end
      check_fade("steps", function(v)
        return type(v) == "number" and v >= 0
      end, "must be a non-negative number")
      -- Inclusive, unlike the layout fractions: 0 is "do not dim / do not
      -- brighten", which is a meaningful setting here rather than a degenerate
      -- pane width.
      local function is_unit(v)
        return type(v) == "number" and v >= 0 and v <= 1
      end
      check_fade("boost", is_unit, "must be a number from 0 to 1")
      check_fade("dim", is_unit, "must be a number from 0 to 1")
      check_fade("flash_level", is_unit, "must be a number from 0 to 1")
      check_fade("flash_text_lift", is_unit, "must be a number from 0 to 1")
    end

    if ag.sessions ~= nil then
      assert(type(ag.sessions) == "table", "agents.sessions must be a table")
      local check_sessions = checker(ag.sessions, "agents.sessions")
      check_sessions("limit", is_positive, "must be a positive number")
      check_sessions("include_empty", is_boolean, "must be a boolean")
      -- "added" and "title" are what "changes" and "name" were called before the
      -- sort menu existed, and still accepted: a config that names one is not
      -- wrong, only older.
      check_sessions(
        "sort",
        one_of({ "recent", "name", "changes", "status", "added", "title" }),
        'must be "recent", "name", "changes" or "status"'
      )
      check_sessions("foreign", is_boolean, "must be a boolean")
    end

    M.validate_float(ag.float, "agents.float")

    if ag.keymaps ~= nil then
      assert(type(ag.keymaps) == "table", "agents.keymaps must be a table")
      local fields = {
        "select",
        "new",
        "stop",
        "delete",
        "refresh",
        "sort",
        "close",
        "open",
        "git_diff",
        "goto_file",
        "help",
        "next_pane",
        "focus_term",
        "next_session",
        "prev_session",
      }
      for _, field in ipairs(fields) do
        checker(ag.keymaps, "agents.keymaps")(field, is_keymap, "must be a string or false")
      end
    end

    if ag.highlights ~= nil then
      assert(type(ag.highlights) == "table", "agents.highlights must be a table")
      local highlight_fields =
        { "title", "time", "added", "removed", "selected", "path", "float", "normal", "normal_nc", "header", "key" }
      for _, field in ipairs(highlight_fields) do
        checker(ag.highlights, "agents.highlights")(field, function(v)
          return type(v) == "string"
        end, "must be a string")
      end
    end
  end

  -- Validate status (optional; apply() supplies defaults)
  if config.status ~= nil then
    local st = config.status
    assert(type(st) == "table", "status must be a table")
    if st.enabled ~= nil then
      assert(type(st.enabled) == "boolean", "status.enabled must be a boolean")
    end
    if st.auto_redraw ~= nil then
      assert(type(st.auto_redraw) == "boolean", "status.auto_redraw must be a boolean")
    end
    if st.spinner_ms ~= nil then
      assert(type(st.spinner_ms) == "number" and st.spinner_ms >= 0, "status.spinner_ms must be a non-negative number")
    end
    for _, field in ipairs({ "icons", "highlights" }) do
      if st[field] ~= nil then
        assert(type(st[field]) == "table", "status." .. field .. " must be a table")
        for key, value in pairs(st[field]) do
          assert(
            key == "busy" or key == "waiting" or key == "done" or key == "idle" or key == "none",
            "status." .. field .. " keys must be 'busy', 'waiting', 'done', 'idle' or 'none'"
          )
          -- Icons may also be a list of frames to animate; highlights may not.
          if field == "icons" and type(value) == "table" then
            for _, frame in ipairs(value) do
              assert(type(frame) == "string", "status.icons." .. key .. " frames must be strings")
            end
            assert(#value > 0, "status.icons." .. key .. " must not be an empty frame list")
          else
            assert(
              type(value) == "string",
              "status."
                .. field
                .. "."
                .. key
                .. " must be a string"
                .. (field == "icons" and " or a list of frames" or "")
            )
          end
        end
      end
    end
  end

  -- Validate session_persistence (optional; apply() supplies the default)
  if config.session_persistence ~= nil then
    local sp = config.session_persistence
    assert(
      sp == "off" or sp == "global" or sp == "external",
      "session_persistence must be one of 'off', 'global', 'external'"
    )
  end

  -- Validate env
  assert(type(config.env) == "table", "env must be a table")
  for key, value in pairs(config.env) do
    assert(type(key) == "string", "env keys must be strings")
    assert(type(value) == "string", "env values must be strings")
  end

  -- Validate models
  assert(type(config.models) == "table", "models must be a table")
  assert(#config.models > 0, "models must not be empty")

  for i, model in ipairs(config.models) do
    assert(type(model) == "table", "models[" .. i .. "] must be a table")
    assert(type(model.name) == "string" and model.name ~= "", "models[" .. i .. "].name must be a non-empty string")
    assert(type(model.value) == "string" and model.value ~= "", "models[" .. i .. "].value must be a non-empty string")
  end

  return true
end

---Applies user configuration on top of default settings and validates the result.
---@param user_config table|nil The user-provided configuration table.
---@return ClaudeCodeConfig config The final, validated configuration table.
function M.apply(user_config)
  local config = vim.deepcopy(M.defaults)

  -- Lazy-load terminal defaults to avoid circular dependency
  if config.terminal == nil then
    local terminal_ok, terminal_module = pcall(require, "claudecode.terminal")
    if terminal_ok and terminal_module.defaults then
      config.terminal = terminal_module.defaults
    end
  end

  if user_config then
    -- Use vim.tbl_deep_extend if available, otherwise simple merge
    if vim.tbl_deep_extend then
      config = vim.tbl_deep_extend("force", config, user_config)
    else
      -- Simple fallback for testing environment
      for k, v in pairs(user_config) do
        config[k] = v
      end
    end
  end

  -- Backward compatibility: map legacy diff options to new fields if provided
  if config.diff_opts then
    local d = config.diff_opts
    -- Map vertical_split -> layout (legacy option takes precedence)
    if type(d.vertical_split) == "boolean" then
      d.layout = d.vertical_split and "vertical" or "horizontal"
    end
    -- Map open_in_current_tab -> open_in_new_tab (legacy option takes precedence)
    if type(d.open_in_current_tab) == "boolean" then
      d.open_in_new_tab = not d.open_in_current_tab
    end
  end

  M.validate(config)

  return config
end

return M
