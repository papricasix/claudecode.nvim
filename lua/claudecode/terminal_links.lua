---@brief [[
--- Terminal links: click a file path in the Claude terminal to open it in the editor.
---
--- Claude renders file references (the `Read(...)`/`Update(...)`/`Write(...)` headers
--- and inline `path:line` references) as OSC 8 hyperlinks carrying the absolute
--- `file://` URL. Inside Neovim's `:terminal` those links are NOT routed through the
--- MCP connection and Neovim has no built-in "open hyperlink on click" behaviour, so a
--- plain click is forwarded to Claude, which shells out to the OS opener (Finder/etc.).
--- The VS Code extension instead opens the file in the editor; this module does the same.
---
--- How it works (all verified against a live Claude session):
---  1. A `TermRequest` autocmd captures every OSC 8 `file://` URL Claude emits and records
---     the set of linked file paths for the terminal. We deliberately do NOT track screen
---     coordinates: Claude's TUI repaints and scrolls links to buffer rows that no longer
---     match where the OSC 8 fired, so geometry-based lookup misses almost every real click.
---  2. A buffer-local `<LeftMouse>` map intercepts the click before Neovim forwards it to
---     Claude, and `_resolve_click` matches the filename token under the cursor against the
---     captured paths (basename / relative suffix, or a long substring for wrapped names) to
---     recover the exact absolute path. The file opens in the editor window closest to the
---     terminal (`diff.find_window_closest_to_terminal`, the plan view's targeting) and the
---     click is consumed; any other click is re-fed so Claude's own mouse UI keeps working.
---
--- A normal-mode `gf` keymap on the terminal buffer does the same for the path under the
--- cursor, as a keyboard trigger that doesn't depend on mouse delivery. Enabling the feature
--- also turns on `mousemoveevent` so Claude's own hover (link underline) works in `:terminal`.
---@brief ]]
---@module 'claudecode.terminal_links'

local M = {}

local logger = require("claudecode.logger")

--- Cached `claudecode.diff` module — reused only for its editor-window finders.
--- `false` means a load attempt already failed (don't retry every click).
local _diff
local function get_diff()
  if _diff == nil then
    local ok, mod = pcall(require, "claudecode.diff")
    _diff = ok and mod or false
  end
  return _diff or nil
end

--- terminal_links config subtable (see config.lua defaults / validation).
---@type table|nil
local config = nil

--- Per attached terminal buffer: { paths = { "/abs/file", ... }, click = {...} }. `paths`
--- is the set of file paths Claude has linked (most-recent last, unique). Keyed by bufnr;
--- cleared on BufWipeout.
local state = {}

--- Cap on retained captured paths per buffer.
local MAX_PATHS = 2000

local augroup = nil

--- Opt-in diagnostics: when `vim.g.claudecode_tl_debug` is set, echo to `:messages`. A
--- no-op otherwise, so it is safe to leave in. Scheduled because some call sites (autocmd
--- callbacks) run in a fast event context where `nvim_echo` is not allowed.
local function dbg(msg)
  if not vim.g.claudecode_tl_debug then
    return
  end
  vim.schedule(function()
    vim.api.nvim_echo({ { "[claudecode terminal_links] " .. msg, "WarningMsg" } }, true, {})
  end)
end

---@return boolean
function M.is_enabled()
  return config ~= nil and config.enabled == true
end

--- Captured file paths for a buffer (test/debug accessor).
---@param bufnr integer
---@return string[]
function M._paths(bufnr)
  return (state[bufnr] and state[bufnr].paths) or {}
end

--------------------------------------------------------------------------------
-- Setup / teardown
--------------------------------------------------------------------------------

---@param full_config table The full plugin config (expects a `terminal_links` field).
function M.setup(full_config)
  config = (full_config and full_config.terminal_links) or {}
  dbg(
    ("setup enabled=%s click=%s mouse_motion=%s"):format(
      tostring(M.is_enabled()),
      tostring(config.click),
      tostring(config.mouse_motion)
    )
  )
  if not M.is_enabled() then
    return
  end
  if config.mouse_motion ~= false then
    -- Forward mouse-motion events to the Claude TUI (off by default in Neovim) so Claude's
    -- own hover affordance — underlining the file link under the pointer — works inside the
    -- terminal. We don't draw anything ourselves; <MouseMove> is left unmapped so it reaches
    -- Claude.
    vim.o.mousemoveevent = true
  end
  M._install_autocmds()
  -- Attach to a Claude terminal that already exists (the common path is enabling the feature
  -- before launch, where TermOpen handles it, so this scan is best-effort).
  local ok, bufs = pcall(vim.api.nvim_list_bufs)
  if ok and bufs then
    for _, bufnr in ipairs(bufs) do
      if M._is_claude_terminal(bufnr) then
        M.attach(bufnr)
      end
    end
  end
end

function M.cleanup()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  state = {}
end

function M._install_autocmds()
  augroup = vim.api.nvim_create_augroup("ClaudeCodeTerminalLinks", { clear = true })

  -- One global TermRequest autocmd (registering it enables the event for the terminal
  -- emulator). It dispatches by buffer to attached state only, so non-Claude terminals
  -- cost nothing beyond the table lookup.
  vim.api.nvim_create_autocmd("TermRequest", {
    group = augroup,
    callback = function(ev)
      if ev and ev.buf and state[ev.buf] then
        M._on_term_request(ev.buf, ev)
      end
    end,
    desc = "Capture Claude OSC 8 file:// links",
  })

  vim.api.nvim_create_autocmd("TermOpen", {
    group = augroup,
    callback = function(args)
      if args and args.buf then
        local is_claude = M._is_claude_terminal(args.buf)
        dbg(
          ("TermOpen buf=%s is_claude=%s name=%q"):format(
            tostring(args.buf),
            tostring(is_claude),
            tostring(vim.api.nvim_buf_get_name(args.buf))
          )
        )
        if is_claude then
          M.attach(args.buf)
        end
      end
    end,
    desc = "Wire file-path opening into the Claude terminal",
  })
end

--- Whether `bufnr` is a Claude terminal buffer. Uses the same name heuristic as
--- `terminal/native.lua`'s `find_existing_claude_terminal`.
---@param bufnr integer
---@return boolean
function M._is_claude_terminal(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "terminal" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= nil and name:match("claude") ~= nil
end

--------------------------------------------------------------------------------
-- Attach (per terminal buffer)
--------------------------------------------------------------------------------

---@param bufnr integer
function M.attach(bufnr)
  if state[bufnr] then
    return -- already attached
  end
  state[bufnr] = { paths = {}, click = nil }
  dbg(
    ("attach buf=%s click=%s key=%q mouse_motion=%s"):format(
      tostring(bufnr),
      tostring(config.click ~= false),
      tostring(config.key),
      tostring(config.mouse_motion ~= false)
    )
  )

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      state[bufnr] = nil
    end,
    desc = "Drop captured Claude terminal links",
  })

  if config.click ~= false then
    local opts = { buffer = bufnr, silent = true, desc = "Open file path under click (Claude)" }
    -- Defensive on both: any failure must still deliver the original event, never eat it.
    vim.keymap.set({ "t", "n" }, "<LeftMouse>", function()
      local ok, consumed = pcall(M._on_press, bufnr)
      if not (ok and consumed) then
        if not ok then
          logger.debug("terminal_links", "press handler error:", consumed)
        end
        M._passthrough("<LeftMouse>")
      end
    end, opts)
    vim.keymap.set({ "t", "n" }, "<LeftRelease>", function()
      local ok, consumed = pcall(M._on_release, bufnr)
      if not (ok and consumed) then
        M._passthrough("<LeftRelease>")
      end
    end, opts)
  end

  if config.key and config.key ~= "" then
    vim.keymap.set("n", config.key, function()
      local pos = vim.api.nvim_win_get_cursor(0)
      M._open_at(bufnr, pos[1], pos[2])
    end, { buffer = bufnr, silent = true, desc = "Open file path under cursor (Claude)" })
  end

  logger.debug("terminal_links", "attached to terminal buffer", bufnr)
end

--------------------------------------------------------------------------------
-- OSC 8 capture
--------------------------------------------------------------------------------

--- Convert a `file://` URL to a filesystem path: strip scheme + optional host, drop any
--- `#fragment`, percent-decode. Handles absolute (`file:///abs`, `file://host/abs`) and the
--- relative forms Claude emits for cwd files shown by name (`file://name`, `file://./name`)
--- — the latter must NOT have the bare name mistaken for a host and stripped to "".
---@param uri string
---@return string
function M._url_to_path(uri)
  local rest = uri:gsub("^file:", "")
  if rest:sub(1, 2) == "//" then
    rest = rest:sub(3) -- drop the "//" introducing the authority
    if rest:sub(1, 2) ~= "./" then -- "./name" is a relative path, not host + "/name"
      local slash = rest:find("/")
      if slash then
        rest = rest:sub(slash) -- strip the authority/host, keep the leading-'/' path
      end
      -- no '/' at all: a bare relative name (e.g. "logger.lua") — keep it verbatim
    end
  end
  rest = rest:gsub("#.*$", "")
  rest = rest:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return rest
end

---@param bufnr integer
---@param ev table TermRequest autocmd event (ev.data.sequence, ev.data.cursor)
function M._on_term_request(bufnr, ev)
  local data = ev.data
  local seq = data and data.sequence
  if type(seq) ~= "string" then
    return
  end
  -- OSC 8: ESC ] 8 ; <params> ; <uri>   (params may be empty or "id=...").
  local uri = seq:match("^\27%]8;[^;]*;(.*)$")
  if uri == nil then
    return -- not an OSC 8 sequence (e.g. OSC 0 title updates)
  end
  uri = uri:gsub("\27\\$", ""):gsub("\7$", "") -- strip a trailing string terminator if present

  if uri ~= "" then
    dbg(("CAPTURE osc8 uri=%q file=%s"):format(uri, tostring(uri:match("^file:") ~= nil)))
  end
  if uri == "" or not uri:match("^file:") then
    return -- a closing OSC 8, or a non-file link: nothing to record
  end
  local st = state[bufnr]
  if not st then
    return
  end
  local path = M._url_to_path(uri)
  dbg(("CAPTURE uri=%q -> path=%q readable=%s"):format(uri, path, tostring(vim.fn.filereadable(path) == 1)))
  if path == "" then
    return
  end
  -- Record the path (most-recent-wins, unique, capped). We don't track the link's screen
  -- coordinates: Claude's TUI repaints/scrolls links to rows that no longer match where the
  -- OSC 8 fired, so a click is resolved by matching the filename token under the cursor to
  -- this set, not by row geometry. See `_match_captured`.
  local paths = st.paths
  for i = #paths, 1, -1 do
    if paths[i] == path then
      table.remove(paths, i)
    end
  end
  paths[#paths + 1] = path
  if #paths > MAX_PATHS then
    table.remove(paths, 1)
  end
end

--------------------------------------------------------------------------------
-- Click handling
--------------------------------------------------------------------------------
--
-- A mouse click is a gesture: <LeftMouse> (press), optional <LeftDrag>s, then
-- <LeftRelease>. We map press AND release so we can open on RELEASE — opening on the
-- press (even via vim.schedule) races the trailing release, which then lands in the
-- freshly focused editor and starts a stray visual selection. On a link we swallow the
-- whole gesture and open at the end; otherwise we re-feed the original event so Claude
-- (or normal-mode cursor placement) still receives a coherent click.

--- Re-feed `key` so the terminal/Claude still gets it. `noremap` so it can't re-trigger us.
---@param key string e.g. "<LeftMouse>" / "<LeftRelease>"
function M._passthrough(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

--- `<LeftMouse>` press: if it lands on a link, remember it (open happens on release).
---@param bufnr integer
---@return boolean consumed
function M._on_press(bufnr)
  local st = state[bufnr]
  if st then
    st.click = nil
  end
  local m = vim.fn.getmousepos()
  if not m or m.winid == 0 or not m.line or m.line <= 0 then
    dbg(("press: no mouse pos (m=%s)"):format(vim.inspect(m)))
    return false
  end
  -- Only act on presses inside this terminal's window.
  if vim.api.nvim_win_get_buf(m.winid) ~= bufnr then
    dbg(
      ("press: click in winid=%s buf=%s, not our term buf=%s"):format(
        tostring(m.winid),
        tostring(vim.api.nvim_win_get_buf(m.winid)),
        tostring(bufnr)
      )
    )
    return false
  end
  local row, col0 = m.line, math.max(0, m.column - 1) -- getmousepos col is 1-based
  local token = M._parse_token(vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1], col0)
  local path, line = M._resolve_click(bufnr, row, col0)
  dbg(
    ("press: row=%d col0=%d token=%s resolved=%s npaths=%d"):format(
      row,
      col0,
      token and ("%q"):format(token) or "nil",
      path and ("%q"):format(path) or "nil",
      #M._paths(bufnr)
    )
  )
  if not path then
    return false
  end
  if st then
    st.click = { path = path, line = line }
  end
  return true -- swallow the press; open on release
end

--- `<LeftRelease>`: complete a pending link click by opening it (gesture is now over).
---@param bufnr integer
---@return boolean consumed
function M._on_release(bufnr)
  local st = state[bufnr]
  if st and st.click then
    local c = st.click
    st.click = nil
    M._open_in_editor(c.path, c.line)
    return true
  end
  return false
end

--- Find the captured path that the `token` under the cursor refers to. Row-independent:
--- Claude's TUI repaints/scrolls links to buffer rows that no longer match where the OSC 8
--- fired, so we resolve by the filename text under the cursor, not by geometry. Matches, in
--- order, an exact path, a captured path ending in `/<token>` (a displayed basename or
--- relative suffix → its absolute path), or — for a long token only — a captured path that
--- contains it (a chunk of a wrapped, multi-line filename/path). Newest match wins.
---@param bufnr integer
---@param token string
---@return string|nil
function M._match_captured(bufnr, token)
  local st = state[bufnr]
  if not (st and token) or #token < 2 then
    return nil
  end
  local paths, suffix = st.paths, "/" .. token
  for i = #paths, 1, -1 do
    local p = paths[i]
    if p == token or (#p > #suffix and p:sub(-#suffix) == suffix) then
      return p
    end
  end
  if #token >= 8 then -- a wrapped link's visual row is a long chunk of the path
    for i = #paths, 1, -1 do
      if paths[i]:find(token, 1, true) then
        return paths[i]
      end
    end
  end
  return nil
end

--- Resolve the readable file referenced at (row, col0) in the terminal buffer, or nil.
---@param bufnr integer
---@param row integer 1-based buffer row
---@param col0 integer 0-based byte column
---@return string|nil abspath, integer|nil line
function M._resolve_click(bufnr, row, col0)
  local token, line = M._parse_token(vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1], col0)
  if not token then
    return nil
  end
  -- Prefer a captured OSC 8 path (gives the exact absolute file); otherwise accept a
  -- multi-segment path typed in free text, resolved against the cwd. A bare word that
  -- matches nothing captured must not open a file just because something shares its name.
  local path = M._match_captured(bufnr, token)
  if not path and token:find("/") then
    path = token
  end
  if not path then
    return nil
  end
  return M._resolve(path), line
end

--- Resolve and open the file referenced at (row, col0). Used by the `gf` keymap (the
--- click path opens on release via `_on_release`).
---@param bufnr integer
---@param row integer
---@param col0 integer
---@return boolean opened
function M._open_at(bufnr, row, col0)
  local abspath, line = M._resolve_click(bufnr, row, col0)
  if not abspath then
    return false
  end
  M._open_in_editor(abspath, line)
  return true
end

--------------------------------------------------------------------------------
-- Token under the cursor
--------------------------------------------------------------------------------

--- Extract a `path[:line]` token around col0 from the buffer line. Pure helper.
---@param line_text string
---@param col0 integer 0-based byte column
---@return string|nil path, integer|nil line
function M._parse_token(line_text, col0)
  if not line_text or line_text == "" then
    return nil
  end
  local n = #line_text
  local i = math.min(col0 + 1, n) -- 1-based index into the string
  local function is_path_char(c)
    return c ~= nil and c:match("[%w%./:_%-~+@%%]") ~= nil
  end
  if not is_path_char(line_text:sub(i, i)) then
    i = i - 1 -- allow clicking the trailing space just past a token
    if i < 1 or not is_path_char(line_text:sub(i, i)) then
      return nil
    end
  end
  local s = i
  while s > 1 and is_path_char(line_text:sub(s - 1, s - 1)) do
    s = s - 1
  end
  local e = i
  while e < n and is_path_char(line_text:sub(e + 1, e + 1)) do
    e = e + 1
  end
  local token = line_text:sub(s, e):gsub("[%.,;:]+$", "") -- strip trailing punctuation
  if token == "" then
    return nil
  end
  -- Split a trailing :line (but not a Windows drive like C:).
  local p, l = token:match("^(.-):(%d+)$")
  if p and (p:find("[/.]") or #p > 1) then
    return p, tonumber(l)
  end
  return token, nil
end

--------------------------------------------------------------------------------
-- Resolve + open
--------------------------------------------------------------------------------

--- Resolve a (possibly relative or ~-prefixed) path to a readable absolute file.
---@param path string
---@return string|nil
function M._resolve(path)
  local utils = require("claudecode.utils")
  local p = utils.expand_tilde and utils.expand_tilde(path) or path
  if vim.fn.filereadable(p) == 1 then
    return vim.fn.fnamemodify(p, ":p")
  end
  local joined = vim.fs.normalize(vim.fn.getcwd() .. "/" .. p)
  if vim.fn.filereadable(joined) == 1 then
    return joined
  end
  return nil
end

--- Open `abspath` in the editor window closest to the Claude terminal, replacing its
--- buffer (the same targeting the plan view uses). Falls back to a split when only the
--- terminal is visible. Focus moves to the opened file.
---@param abspath string
---@param line integer|nil
function M._open_in_editor(abspath, line)
  -- Defer to the next loop tick: the click handler runs mid mouse-gesture, so switching
  -- windows synchronously leaves the trailing <LeftRelease>/<LeftDrag> to land in the
  -- newly focused editor and start a stray visual selection. Scheduling lets the gesture
  -- finish in the terminal first.
  vim.schedule(function()
    local diff = get_diff()
    local win = diff and (diff.find_window_closest_to_terminal() or diff._find_main_editor_window()) or nil
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("aboveleft vsplit") -- only the terminal (and maybe sidebars) on screen
    end
    vim.cmd("edit " .. vim.fn.fnameescape(abspath))
    if line and line > 0 then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
      pcall(function()
        vim.cmd("normal! zz")
      end)
    end
  end)
end

return M
