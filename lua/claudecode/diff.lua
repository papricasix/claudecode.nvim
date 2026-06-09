--- Diff module for Claude Code Neovim integration.
-- Provides native Neovim diff functionality with MCP-compliant blocking operations and state management.
local M = {}

local logger = require("claudecode.logger")

---Tell the live-cursor feature to dismiss its ride-along preview before we build
---a review diff for `file_path`. Done first thing in diff setup so the preview
---window is gone before window discovery runs (it must not become the diff
---target) and so an already-open preview can't keep fighting the diff for the
---same screen. Best-effort and decoupled — a missing/older live_cursor is fine.
---@param file_path string
local function dismiss_live_cursor_preview(file_path)
  local ok, live_cursor = pcall(require, "claudecode.live_cursor")
  if ok and live_cursor and type(live_cursor.on_diff_opened) == "function" then
    pcall(live_cursor.on_diff_opened, file_path)
  end
end

---Split proposed file contents into buffer lines, stripping CRLF/CR so a Windows
---(`\r\n`) file does not diff as entirely changed: Neovim loads the on-disk
---original with `fileformat=dos` (no trailing `\r`), but a scratch buffer keeps a
---literal `\r` from a plain `\n` split and renders it as `^M`, making every line
---differ. We strip the `\r` here and report the detected line ending so accept
---(`_resolve_diff_as_saved`) can rejoin with the same separator and preserve it.
---@param contents string The raw proposed file contents from Claude.
---@return string[] lines Buffer lines with no trailing carriage returns.
---@return string fileformat "dos" if CRLF was detected, else "unix".
local function content_to_lines(contents)
  local lines = vim.split(contents, "\n", { plain = true })
  -- Drop the spurious empty final element a trailing newline produces.
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  local fileformat = "unix"
  for i = 1, #lines do
    if lines[i]:sub(-1) == "\r" then
      fileformat = "dos"
      lines[i] = lines[i]:sub(1, -2)
    end
  end
  return lines, fileformat
end

-- Exposed for testing the CRLF normalization.
M._content_to_lines = content_to_lines

-- Window options for terminal display (internal type, not exposed in public API)
---@class WindowOptions
---@field number boolean Show line numbers
---@field relativenumber boolean Show relative line numbers
---@field signcolumn string Sign column display mode
---@field statuscolumn string Status column format
---@field foldcolumn string Fold column width
---@field cursorline boolean Highlight cursor line
---@field cursorcolumn boolean Highlight cursor column
---@field colorcolumn string Columns to highlight
---@field cursorlineopt string Cursor line options
---@field spell boolean Enable spell checking
---@field list boolean Show invisible characters
---@field wrap boolean Wrap long lines
---@field linebreak boolean Break lines at word boundaries
---@field breakindent boolean Indent wrapped lines
---@field showbreak string String to show at line breaks
---@field scrolloff number Lines to keep above/below cursor
---@field sidescrolloff number Columns to keep left/right of cursor

---@type ClaudeCodeConfig
local config

---@type number
local autocmd_group

---Get or create the autocmd group for diff operations
---@return number autocmd_group The autocmd group ID
local function get_autocmd_group()
  if not autocmd_group then
    autocmd_group = vim.api.nvim_create_augroup("ClaudeCodeMCPDiff", { clear = true })
  end
  return autocmd_group
end

---Resolve the tab that owns the currently active Claude Code WebSocket message.
---The server sets `_G._claudecode_active_tab_id` on every incoming message; we
---fall back to the user's current tab when no owner is known (e.g. tests).
---@return integer owning_tab Tabpage handle of the owning Claude instance
local function get_owning_tab()
  local target = _G._claudecode_active_tab_id
  if target and vim.api.nvim_tabpage_is_valid(target) then
    return target
  end
  return vim.api.nvim_get_current_tabpage()
end

---Run `fn` in the context of the tab that owns the active Claude message.
---Internally uses `nvim_win_call` so that all vim ex-commands and "current
---tab/window" lookups inside `fn` see the owning tab — without permanently
---moving the user away from whichever tab they are looking at. After `fn`
---returns, the user's view is restored.
---
---This is the canonical entry point for any diff/UI work triggered by a
---Claude tool call. Use it instead of reading `_G._claudecode_active_tab_id`
---directly so future code paths route correctly by default.
---@generic T
---@param fn fun(owning_tab: integer): T
---@return T result Value returned by `fn`
local function in_owning_tab(fn)
  local tab = get_owning_tab()
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  if #wins == 0 then
    return fn(vim.api.nvim_get_current_tabpage())
  end
  return vim.api.nvim_win_call(wins[1], function()
    return fn(tab)
  end)
end

---Switch to the tab that owns the active Claude Code WebSocket message.
---Returns whether a switch happened.
---
---Prefer `in_owning_tab(fn)` for new code — it scopes work to the owning tab
---without yanking the user across tabs. This destructive variant is kept for
---the legacy `_open_native_diff` path which still needs it.
---@return boolean switched
local function switch_to_owning_tab_if_needed()
  local target = _G._claudecode_active_tab_id
  if not target or not vim.api.nvim_tabpage_is_valid(target) then
    return false
  end
  if vim.api.nvim_get_current_tabpage() == target then
    return false
  end
  vim.api.nvim_set_current_tabpage(target)
  return true
end

---Find a suitable main editor window to open diffs in.
---Excludes terminals, sidebars, and floating windows.
---@param windows number[]? List of window IDs to search; defaults to all windows
---@return number? win_id Window ID of the main editor window, or nil if not found
local function find_main_editor_window(windows)
  windows = windows or vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
    local win_config = vim.api.nvim_win_get_config(win)

    local is_suitable = true

    -- Skip floating windows
    if win_config.relative and win_config.relative ~= "" then
      is_suitable = false
    end

    if is_suitable and (buftype == "terminal" or buftype == "prompt") then
      is_suitable = false
    end

    -- Skip the live-cursor "ride-along" preview split: opening a diff into it
    -- makes the two features fight over the same window (see live_cursor.lua).
    if is_suitable then
      local ok_pv, is_preview = pcall(function()
        return vim.w[win].claudecode_live_preview
      end)
      if ok_pv and is_preview then
        is_suitable = false
      end
    end

    if
      is_suitable
      and (
        filetype == "neo-tree"
        or filetype == "neo-tree-popup"
        or filetype == "NvimTree"
        or filetype == "oil"
        or filetype == "minifiles"
        or filetype == "netrw"
        or filetype == "aerial"
        or filetype == "tagbar"
        or filetype == "snacks_picker_list"
        or filetype == "snacks_layout_box"
      )
    then
      is_suitable = false
    end

    if is_suitable then
      return win
    end
  end

  return nil
end

-- Exposed for testing the sidebar/explorer exclusion logic.
M._find_main_editor_window = find_main_editor_window

---Find the Claude Code terminal window to keep focus there.
---Uses the terminal provider to get the active terminal buffer, then finds its window.
---@return number? win_id Window ID of the Claude Code terminal window, or nil if not found
local function find_claudecode_terminal_window()
  local terminal_ok, terminal_module = pcall(require, "claudecode.terminal")
  if not terminal_ok then
    return nil
  end

  local terminal_bufnr = terminal_module.get_active_terminal_bufnr()
  if not terminal_bufnr then
    return nil
  end

  -- Find the window containing this buffer.
  -- Prefer a normal split window, but fall back to a floating terminal window (e.g. Snacks position="float").
  local floating_fallback = nil

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == terminal_bufnr then
      local win_config = vim.api.nvim_win_get_config(win)
      local is_floating = win_config.relative and win_config.relative ~= ""

      if is_floating then
        floating_fallback = floating_fallback or win
      else
        return win
      end
    end
  end

  return floating_fallback
end

---Find the main editor window in the same tab as the Claude Code terminal.
---Falls back to a global search when no terminal is visible or it is floating.
---@return number? win_id Window ID, or nil if not found
local function find_window_adjacent_to_terminal()
  local terminal_win = find_claudecode_terminal_window()
  if terminal_win then
    local wc = vim.api.nvim_win_get_config(terminal_win)
    local is_floating = wc.relative and wc.relative ~= ""
    if not is_floating then
      -- Search only within the terminal's tab to avoid switching tabs
      local tab_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(terminal_win))
      local candidates = {}
      for _, w in ipairs(tab_wins) do
        if w ~= terminal_win then
          candidates[#candidates + 1] = w
        end
      end
      local win = find_main_editor_window(candidates)
      if win then
        return win
      end
    end
  end
  return find_main_editor_window()
end

---Create a split based on configured layout
local function create_split()
  if config and config.diff_opts and config.diff_opts.layout == "horizontal" then
    -- Ensure the new window is created below the current one regardless of user 'splitbelow' setting
    vim.cmd("belowright split")
  else
    -- Ensure the new window is created to the right of the current one regardless of user 'splitright' setting
    vim.cmd("rightbelow vsplit")
  end
end

---Capture window-local options from a window
---@param win_id number Window ID to capture options from
---@return WindowOptions options Window options
local function capture_window_options(win_id)
  local options = {}

  -- Display options
  options.number = vim.api.nvim_get_option_value("number", { win = win_id })
  options.relativenumber = vim.api.nvim_get_option_value("relativenumber", { win = win_id })
  options.signcolumn = vim.api.nvim_get_option_value("signcolumn", { win = win_id })
  options.statuscolumn = vim.api.nvim_get_option_value("statuscolumn", { win = win_id })
  options.foldcolumn = vim.api.nvim_get_option_value("foldcolumn", { win = win_id })

  -- Visual options
  options.cursorline = vim.api.nvim_get_option_value("cursorline", { win = win_id })
  options.cursorcolumn = vim.api.nvim_get_option_value("cursorcolumn", { win = win_id })
  options.colorcolumn = vim.api.nvim_get_option_value("colorcolumn", { win = win_id })
  options.cursorlineopt = vim.api.nvim_get_option_value("cursorlineopt", { win = win_id })

  -- Text options
  options.spell = vim.api.nvim_get_option_value("spell", { win = win_id })
  options.list = vim.api.nvim_get_option_value("list", { win = win_id })
  options.wrap = vim.api.nvim_get_option_value("wrap", { win = win_id })
  options.linebreak = vim.api.nvim_get_option_value("linebreak", { win = win_id })
  options.breakindent = vim.api.nvim_get_option_value("breakindent", { win = win_id })
  options.showbreak = vim.api.nvim_get_option_value("showbreak", { win = win_id })

  -- Scroll options
  options.scrolloff = vim.api.nvim_get_option_value("scrolloff", { win = win_id })
  options.sidescrolloff = vim.api.nvim_get_option_value("sidescrolloff", { win = win_id })

  return options
end

---Apply window-local options to a window
---@param win_id number Window ID to apply options to
---@param options WindowOptions Window options to apply
local function apply_window_options(win_id, options)
  for opt_name, opt_value in pairs(options) do
    pcall(vim.api.nvim_set_option_value, opt_name, opt_value, { win = win_id })
  end
end

---Get default terminal window options
---@return WindowOptions Default options for terminal windows
local function get_default_terminal_options()
  return {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    cursorline = false,
    cursorcolumn = false,
    colorcolumn = "",
    cursorlineopt = "both",
    spell = false,
    list = false,
    wrap = true,
    linebreak = false,
    breakindent = false,
    showbreak = "",
    scrolloff = 0,
    sidescrolloff = 0,
  }
end

---Display existing Claude Code terminal in new tab
---@return number original_tab The original tab number
---@return number? terminal_win Terminal window in new tab
---@return boolean had_terminal_in_original True if terminal was visible in original tab
---@return number? new_tab The handle of the newly created tab
local function display_terminal_in_new_tab()
  local original_tab = vim.api.nvim_get_current_tabpage()

  -- Get existing terminal buffer
  local terminal_ok, terminal_module = pcall(require, "claudecode.terminal")
  if not terminal_ok then
    vim.cmd("tabnew")
    local new_tab = vim.api.nvim_get_current_tabpage()
    return original_tab, nil, false, new_tab
  end

  local terminal_bufnr = terminal_module.get_active_terminal_bufnr()
  if not terminal_bufnr or not vim.api.nvim_buf_is_valid(terminal_bufnr) then
    vim.cmd("tabnew")
    local new_tab = vim.api.nvim_get_current_tabpage()
    return original_tab, nil, false, new_tab
  end

  local existing_terminal_win = find_claudecode_terminal_window()
  local had_terminal_in_original = existing_terminal_win ~= nil
  local terminal_options
  if existing_terminal_win then
    terminal_options = capture_window_options(existing_terminal_win)
  else
    terminal_options = get_default_terminal_options()
  end

  vim.cmd("tabnew")
  local new_tab = vim.api.nvim_get_current_tabpage()

  -- Mark the initial, unnamed buffer in the new tab as ephemeral to avoid leaks
  -- When this buffer gets hidden (replaced or tab closed), wipe it automatically.
  local initial_buf = vim.api.nvim_get_current_buf()
  local name_ok, initial_name = pcall(vim.api.nvim_buf_get_name, initial_buf)
  local mod_ok, initial_modified = pcall(vim.api.nvim_buf_get_option, initial_buf, "modified")
  local linecount_ok, initial_linecount = pcall(function()
    return vim.api.nvim_buf_line_count(initial_buf)
  end)
  if name_ok and mod_ok and linecount_ok then
    if (initial_name == nil or initial_name == "") and initial_modified == false and initial_linecount <= 1 then
      pcall(vim.api.nvim_buf_set_option, initial_buf, "bufhidden", "wipe")
    end
  end

  local terminal_config = config.terminal or {}
  local split_side = terminal_config.split_side or "right"
  local split_width = terminal_config.split_width_percentage or 0.30

  -- Optionally hide the Claude terminal in the new tab for more review space
  local hide_in_new_tab = false
  if config and config.diff_opts and type(config.diff_opts.hide_terminal_in_new_tab) == "boolean" then
    hide_in_new_tab = config.diff_opts.hide_terminal_in_new_tab
  end

  if hide_in_new_tab or not terminal_bufnr or not vim.api.nvim_buf_is_valid(terminal_bufnr) then
    -- Do not create a terminal split in the new tab
    return original_tab, nil, had_terminal_in_original, new_tab
  end

  vim.cmd("vsplit")

  local terminal_win = vim.api.nvim_get_current_win()

  if split_side == "left" then
    vim.cmd("wincmd H")
  else
    vim.cmd("wincmd L")
  end

  vim.api.nvim_win_set_buf(terminal_win, terminal_bufnr)

  apply_window_options(terminal_win, terminal_options)

  -- Set up autocmd to enter terminal mode when focusing this terminal window
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = terminal_bufnr,
    group = get_autocmd_group(),
    callback = function()
      -- Only enter insert mode if we're in a terminal buffer and in normal mode
      if vim.bo.buftype == "terminal" and vim.fn.mode() == "n" then
        vim.cmd("startinsert")
      end
    end,
    desc = "Auto-enter terminal mode when focusing Claude Code terminal",
  })

  local total_width = vim.o.columns
  local terminal_width = math.floor(total_width * split_width)
  vim.api.nvim_win_set_width(terminal_win, terminal_width)

  vim.cmd("wincmd " .. (split_side == "right" and "h" or "l"))

  return original_tab, terminal_win, had_terminal_in_original, new_tab
end

---Check if a buffer has unsaved changes (is dirty).
---@param file_path string The file path to check
---@return boolean true if the buffer is dirty, false otherwise
---@return string? error message if file is not open
local function is_buffer_dirty(file_path)
  local bufnr = vim.fn.bufnr(file_path)

  if bufnr == -1 then
    return false, "File not currently open in buffer"
  end

  local is_dirty = vim.api.nvim_buf_get_option(bufnr, "modified")
  return is_dirty, nil
end

---Setup the diff module
---@param user_config ClaudeCodeConfig The configuration passed from init.lua
function M.setup(user_config)
  -- Store the configuration for later use
  config = user_config
end

---Toggle the configured diff provider between "native" and "unified".
---Affects subsequent diffs only; any currently open diff keeps its view.
---"auto" is resolved first, then flipped.
---@return string new_provider The provider that will be used for the next diff
function M.toggle_provider()
  if not (config and config.diff_opts) then
    vim.notify("ClaudeCode: diff config not initialized", vim.log.levels.WARN)
    return "native"
  end
  local current = M._resolve_provider()
  local next_provider = current == "unified" and "native" or "unified"
  if next_provider == "unified" then
    local ok = pcall(require, "unified.diff")
    if not ok then
      vim.notify("ClaudeCode: unified.nvim is not installed; staying on native", vim.log.levels.WARN)
      config.diff_opts.provider = "native"
      return "native"
    end
  end
  config.diff_opts.provider = next_provider
  vim.notify("ClaudeCode: diff provider set to '" .. next_provider .. "'", vim.log.levels.INFO)
  return next_provider
end

---Resolve the configured diff provider to a concrete implementation.
---"auto" picks "unified" if unified.nvim is loadable, else "native".
---@return "native"|"unified"
function M._resolve_provider()
  local choice = "auto"
  if config and config.diff_opts and type(config.diff_opts.provider) == "string" then
    choice = config.diff_opts.provider
  end
  if choice == "native" then
    return "native"
  end
  local ok = pcall(require, "unified.diff")
  if choice == "unified" then
    if not ok then
      error({
        code = -32000,
        message = "unified.nvim not available",
        data = "diff_opts.provider = 'unified' requires unified.nvim to be installed",
      })
    end
    return "unified"
  end
  return ok and "unified" or "native"
end

---Open a diff view between two files
---@param old_file_path string Path to the original file
---@param new_file_path string Path to the new file (used for naming)
---@param new_file_contents string Contents of the new file
---@param tab_name string Name for the diff tab/view
---@return table Result with provider, tab_name, and success status
function M.open_diff(old_file_path, new_file_path, new_file_contents, tab_name)
  return M._open_native_diff(old_file_path, new_file_path, new_file_contents, tab_name)
end

---Create a temporary file with content
---@param content string The content to write
---@param filename string Base filename for the temporary file
---@return string? path, string? error The temporary file path and error message
local function create_temp_file(content, filename)
  local base_dir_cache = vim.fn.stdpath("cache") .. "/claudecode_diffs"
  local mkdir_ok_cache, mkdir_err_cache = pcall(vim.fn.mkdir, base_dir_cache, "p")

  local final_base_dir
  if mkdir_ok_cache then
    final_base_dir = base_dir_cache
  else
    local base_dir_temp = vim.fn.stdpath("cache") .. "/claudecode_diffs_fallback"
    local mkdir_ok_temp, mkdir_err_temp = pcall(vim.fn.mkdir, base_dir_temp, "p")
    if not mkdir_ok_temp then
      local err_to_report = mkdir_err_temp or mkdir_err_cache or "unknown error creating base temp dir"
      return nil, "Failed to create base temporary directory: " .. tostring(err_to_report)
    end
    final_base_dir = base_dir_temp
  end

  local session_id_base = vim.fn.fnamemodify(vim.fn.tempname(), ":t")
    .. "_"
    .. tostring(os.time())
    .. "_"
    .. tostring(math.random(1000, 9999))
  local session_id = session_id_base:gsub("[^A-Za-z0-9_-]", "")
  if session_id == "" then -- Fallback if all characters were problematic, ensuring a directory can be made.
    session_id = "claudecode_session"
  end

  local tmp_session_dir = final_base_dir .. "/" .. session_id
  local mkdir_session_ok, mkdir_session_err = pcall(vim.fn.mkdir, tmp_session_dir, "p")
  if not mkdir_session_ok then
    return nil, "Failed to create temporary session directory: " .. tostring(mkdir_session_err)
  end

  local tmp_file = tmp_session_dir .. "/" .. filename
  -- Binary mode: on Windows, text mode would translate \n to \r\n on write,
  -- turning CRLF content into \r\r\n and corrupting the diff.
  local file = io.open(tmp_file, "wb")
  if not file then
    return nil, "Failed to create temporary file: " .. tmp_file
  end

  file:write(content)
  file:close()

  return tmp_file, nil
end

---Clean up temporary files and directories
---@param tmp_file string Path to the temporary file to clean up
local function cleanup_temp_file(tmp_file)
  if tmp_file and vim.fn.filereadable(tmp_file) == 1 then
    local tmp_dir = vim.fn.fnamemodify(tmp_file, ":h")
    if vim.fs and type(vim.fs.remove) == "function" then
      local ok_file, err_file = pcall(vim.fs.remove, tmp_file)
      if not ok_file then
        vim.notify(
          "ClaudeCode: Error removing temp file " .. tmp_file .. ": " .. tostring(err_file),
          vim.log.levels.WARN
        )
      end

      local ok_dir, err_dir = pcall(vim.fs.remove, tmp_dir)
      if not ok_dir then
        vim.notify(
          "ClaudeCode: Error removing temp directory " .. tmp_dir .. ": " .. tostring(err_dir),
          vim.log.levels.INFO
        )
      end
    else
      local reason = "vim.fs.remove is not a function"
      if not vim.fs then
        reason = "vim.fs is nil"
      end
      vim.notify(
        "ClaudeCode: Cannot perform standard cleanup: "
          .. reason
          .. ". Affected file: "
          .. tmp_file
          .. ". Please check your Neovim setup or report this issue.",
        vim.log.levels.ERROR
      )
      -- Fallback to os.remove for the file.
      local os_ok, os_err = pcall(os.remove, tmp_file)
      if not os_ok then
        vim.notify(
          "ClaudeCode: Fallback os.remove also failed for file " .. tmp_file .. ": " .. tostring(os_err),
          vim.log.levels.ERROR
        )
      end
    end
  end
end

---Detect filetype from a path or existing buffer (best-effort)
---@param path string The file path to detect filetype from
---@param buf number? Optional buffer number to check for filetype
---@return string? filetype The detected filetype or nil
local function detect_filetype(path, buf)
  -- 1) Try Neovim's builtin matcher if available (>=0.10)
  if vim.filetype and type(vim.filetype.match) == "function" then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then
      return ft
    end
  end

  -- 2) Try reading from existing buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local ft = vim.api.nvim_buf_get_option(buf, "filetype")
    if ft and ft ~= "" then
      return ft
    end
  end

  -- 3) Fallback to simple extension mapping
  local ext = path:match("%.([%w_%-]+)$") or ""
  local simple_map = {
    lua = "lua",
    ts = "typescript",
    js = "javascript",
    jsx = "javascriptreact",
    tsx = "typescriptreact",
    py = "python",
    go = "go",
    rs = "rust",
    c = "c",
    h = "c",
    cpp = "cpp",
    hpp = "cpp",
    md = "markdown",
    sh = "sh",
    zsh = "zsh",
    bash = "bash",
    json = "json",
    yaml = "yaml",
    yml = "yaml",
    toml = "toml",
  }
  return simple_map[ext]
end

---Decide whether to reuse the target window or split for the original file
---@param target_win NvimWin
---@param old_file_path string
---@param is_new_file boolean
---@param terminal_win_in_new_tab NvimWin|nil
---@param force_reuse boolean? Always reuse the target window (pre-diff buffer saved by caller)
---@return DiffWindowChoice
local function choose_original_window(target_win, old_file_path, is_new_file, terminal_win_in_new_tab, force_reuse)
  local in_new_tab = terminal_win_in_new_tab ~= nil
  local current_buf = vim.api.nvim_win_get_buf(target_win)
  local current_buf_path = vim.api.nvim_buf_get_name(current_buf)
  local is_empty_buffer = current_buf_path == "" and vim.api.nvim_buf_get_option(current_buf, "modified") == false

  if in_new_tab then
    return {
      decision = "reuse",
      original_win = target_win,
      reused_buf = current_buf,
      in_new_tab = true,
    }
  end

  -- Always reuse the target window so the diff opens in-place next to the terminal.
  -- The caller is responsible for saving pre_diff_buffer and restoring it on cleanup.
  if force_reuse then
    return { decision = "reuse", original_win = target_win, reused_buf = nil, in_new_tab = false }
  end

  if is_new_file then
    if is_empty_buffer then
      return { decision = "reuse", original_win = target_win, reused_buf = current_buf, in_new_tab = false }
    else
      return { decision = "split", original_win = target_win, reused_buf = nil, in_new_tab = false }
    end
  end

  if current_buf_path == old_file_path then
    return { decision = "reuse", original_win = target_win, reused_buf = current_buf, in_new_tab = false }
  elseif is_empty_buffer then
    return { decision = "reuse", original_win = target_win, reused_buf = current_buf, in_new_tab = false }
  else
    return { decision = "split", original_win = target_win, reused_buf = nil, in_new_tab = false }
  end
end

---Ensure the original window displays the proper buffer for the diff
---@param original_win NvimWin
---@param old_file_path string
---@param is_new_file boolean
---@param existing_buffer NvimBuf|nil
---@return NvimBuf original_buf
local function load_original_buffer(original_win, old_file_path, is_new_file, existing_buffer)
  if is_new_file then
    local empty_buffer = vim.api.nvim_create_buf(false, true)
    if not empty_buffer or empty_buffer == 0 then
      local error_msg = "Failed to create empty buffer for new file diff"
      logger.error("diff", error_msg)
      error({ code = -32000, message = "Buffer creation failed", data = error_msg })
    end

    local ok, err = pcall(function()
      vim.api.nvim_buf_set_name(empty_buffer, old_file_path .. " (NEW FILE)")
      vim.api.nvim_buf_set_lines(empty_buffer, 0, -1, false, {})
      vim.api.nvim_buf_set_option(empty_buffer, "buftype", "nofile")
      vim.api.nvim_buf_set_option(empty_buffer, "modifiable", false)
      vim.api.nvim_buf_set_option(empty_buffer, "readonly", true)
    end)

    if not ok then
      pcall(vim.api.nvim_buf_delete, empty_buffer, { force = true })
      local error_msg = "Failed to configure empty buffer: " .. tostring(err)
      logger.error("diff", error_msg)
      error({ code = -32000, message = "Buffer configuration failed", data = error_msg })
    end

    vim.api.nvim_win_set_buf(original_win, empty_buffer)
    return empty_buffer
  end

  if existing_buffer and vim.api.nvim_buf_is_valid(existing_buffer) then
    vim.api.nvim_win_set_buf(original_win, existing_buffer)
    return existing_buffer
  end

  vim.api.nvim_set_current_win(original_win)
  vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
  return vim.api.nvim_win_get_buf(original_win)
end

---Create the proposed side split, set diff, filetype, context, and terminal focus/width
---@param original_win NvimWin
---@param original_buf NvimBuf
---@param new_buf NvimBuf
---@param old_file_path string
---@param tab_name string
---@param terminal_win_in_new_tab NvimWin|nil
---@param target_win_for_meta NvimWin
---@return NvimWin new_win
local function setup_new_buffer(
  original_win,
  original_buf,
  new_buf,
  old_file_path,
  tab_name,
  terminal_win_in_new_tab,
  target_win_for_meta
)
  vim.api.nvim_set_current_win(original_win)
  vim.cmd("diffthis")

  create_split()
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, new_buf)

  local original_ft = detect_filetype(old_file_path, original_buf)
  if original_ft and original_ft ~= "" then
    vim.api.nvim_set_option_value("filetype", original_ft, { buf = new_buf })
  end
  vim.cmd("diffthis")

  vim.cmd("wincmd =")

  vim.api.nvim_set_current_win(new_win)

  vim.b[new_buf].claudecode_diff_tab_name = tab_name
  vim.b[new_buf].claudecode_diff_new_win = new_win
  vim.b[new_buf].claudecode_diff_target_win = target_win_for_meta

  if config and config.diff_opts and config.diff_opts.keep_terminal_focus then
    vim.schedule(function()
      if terminal_win_in_new_tab and vim.api.nvim_win_is_valid(terminal_win_in_new_tab) then
        local tnt_tab = vim.api.nvim_win_get_tabpage(terminal_win_in_new_tab)
        if tnt_tab == vim.api.nvim_get_current_tabpage() then
          vim.api.nvim_set_current_win(terminal_win_in_new_tab)
          vim.cmd("startinsert")
        end
        return
      end

      local terminal_win = find_claudecode_terminal_window()
      if terminal_win then
        local term_tab = vim.api.nvim_win_get_tabpage(terminal_win)
        if term_tab == vim.api.nvim_get_current_tabpage() then
          vim.api.nvim_set_current_win(terminal_win)
          vim.cmd("startinsert")
        end
      end
    end)
  end

  if terminal_win_in_new_tab and vim.api.nvim_win_is_valid(terminal_win_in_new_tab) then
    local terminal_config = config.terminal or {}
    local split_width = terminal_config.split_width_percentage or 0.30
    local total_width = vim.o.columns
    local terminal_width = math.floor(total_width * split_width)
    vim.api.nvim_win_set_width(terminal_win_in_new_tab, terminal_width)
  else
    local terminal_win = find_claudecode_terminal_window()
    if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
      local current_tab = vim.api.nvim_get_current_tabpage()
      local term_tab = nil
      pcall(function()
        term_tab = vim.api.nvim_win_get_tabpage(terminal_win)
      end)
      if term_tab == current_tab then
        local win_config = vim.api.nvim_win_get_config(terminal_win)
        local is_floating = win_config.relative and win_config.relative ~= ""

        -- Only resize split terminals. Floating terminals control their own sizing.
        if not is_floating then
          local terminal_config = config.terminal or {}
          local split_width = terminal_config.split_width_percentage or 0.30
          local total_width = vim.o.columns
          local terminal_width = math.floor(total_width * split_width)
          pcall(vim.api.nvim_win_set_width, terminal_win, terminal_width)
        end
      end
    end
  end

  return new_win
end

---Open diff using native Neovim functionality
---@param old_file_path string Path to the original file
---@param new_file_path string Path to the new file (used for naming)
---@param new_file_contents string Contents of the new file
---@param tab_name string Name for the diff tab/view
---@return table res Result with provider, tab_name, and success status
function M._open_native_diff(old_file_path, new_file_path, new_file_contents, tab_name)
  local _user_tab = vim.api.nvim_get_current_tabpage()
  local _switched = switch_to_owning_tab_if_needed()
  local new_filename = vim.fn.fnamemodify(new_file_path, ":t") .. ".new"
  local tmp_file, err = create_temp_file(new_file_contents, new_filename)
  if not tmp_file then
    if _switched and vim.api.nvim_tabpage_is_valid(_user_tab) then
      vim.api.nvim_set_current_tabpage(_user_tab)
    end
    return { provider = "native", tab_name = tab_name, success = false, error = err, temp_file = nil }
  end

  local target_win = find_main_editor_window()

  if target_win then
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("wincmd t")
    vim.cmd("wincmd l")
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" then
      create_split()
    end
  end

  vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
  vim.cmd("diffthis")
  create_split()
  vim.cmd("edit " .. vim.fn.fnameescape(tmp_file))
  vim.api.nvim_buf_set_name(0, new_file_path .. " (New)")

  -- Propagate filetype to the proposed buffer for proper syntax highlighting (#20)
  local proposed_buf = vim.api.nvim_get_current_buf()
  local old_filetype = detect_filetype(old_file_path)
  if old_filetype and old_filetype ~= "" then
    vim.api.nvim_set_option_value("filetype", old_filetype, { buf = proposed_buf })
  end

  vim.cmd("wincmd =")

  local new_buf = proposed_buf
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = new_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = new_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = new_buf })

  vim.cmd("diffthis")

  local cleanup_group = vim.api.nvim_create_augroup("ClaudeCodeDiffCleanup", { clear = false })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = cleanup_group,
    buffer = new_buf,
    callback = function()
      cleanup_temp_file(tmp_file)
    end,
    once = true,
  })

  if _switched and vim.api.nvim_tabpage_is_valid(_user_tab) then
    vim.api.nvim_set_current_tabpage(_user_tab)
  end
  return {
    provider = "native",
    tab_name = tab_name,
    success = true,
    temp_file = tmp_file,
  }
end

---@type table<string, table>
local active_diffs = {}

---Register diff state for tracking
---@param tab_name string Unique identifier for the diff
---@param diff_data table Diff state data
function M._register_diff_state(tab_name, diff_data)
  active_diffs[tab_name] = diff_data
end

---Resolve diff as saved (user accepted changes)
---@param tab_name string The diff identifier
---@param buffer_id number The buffer that was saved
function M._resolve_diff_as_saved(tab_name, buffer_id)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  logger.debug("diff", "Accepting diff for", tab_name)

  -- Get content from buffer. Rejoin with the buffer's own line ending so a CRLF
  -- (fileformat=dos) file is written back with CRLF intact rather than silently
  -- converted to LF on accept (we stripped the \r when building the buffer).
  local content_lines = vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false)
  local ok_ff, ff = pcall(vim.api.nvim_buf_get_option, buffer_id, "fileformat")
  local newline = (ok_ff and ff == "dos") and "\r\n" or "\n"
  local final_content = table.concat(content_lines, newline)
  -- Add trailing newline if the buffer has one
  if #content_lines > 0 and vim.api.nvim_buf_get_option(buffer_id, "eol") then
    final_content = final_content .. newline
  end

  -- Do not modify windows/tabs here; wait for explicit close_tab tool call to clean up UI

  -- Create MCP-compliant response
  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = final_content },
    },
  }

  diff_data.status = "saved"
  diff_data.result_content = result

  -- Resume the coroutine with the result (for deferred response system)
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  else
    logger.debug("diff", "No resolution callback found for saved diff", tab_name)
  end

  -- NOTE: Diff state cleanup is handled exclusively by the close_tab tool call
  logger.debug("diff", "Diff saved; awaiting close_tab for cleanup")
end

---Reload file buffers after external changes
---@param file_path string Path to the file that was externally modified
---@param original_cursor_pos table? Original cursor position to restore {row, col}
local function reload_file_buffers(file_path, original_cursor_pos)
  local reloaded_count = 0
  -- Find and reload any open buffers for this file
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)

      -- Simple string match - if buffer name matches the file path
      if buf_name == file_path then
        -- Check if buffer is modified - only reload unmodified buffers for safety
        local modified = vim.api.nvim_buf_get_option(buf, "modified")
        if not modified then
          -- Try to find a window displaying this buffer for proper context
          local win_id = nil
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
              win_id = win
              break
            end
          end

          if win_id then
            vim.api.nvim_win_call(win_id, function()
              vim.cmd("edit")
              -- Restore original cursor position if we have it
              if original_cursor_pos then
                pcall(vim.api.nvim_win_set_cursor, win_id, original_cursor_pos)
              end
            end)
          else
            vim.api.nvim_buf_call(buf, function()
              vim.cmd("edit")
            end)
          end

          reloaded_count = reloaded_count + 1
        end
      end
    end
  end
end

---Resolve diff as rejected (user closed/rejected)
---@param tab_name string The diff identifier
function M._resolve_diff_as_rejected(tab_name)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  -- Create MCP-compliant response
  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = tab_name },
    },
  }

  diff_data.status = "rejected"
  diff_data.result_content = result

  -- Resume the coroutine with the result (for deferred response system)
  if diff_data.resolution_callback then
    diff_data.resolution_callback(result)
  end

  -- For new-file diffs in the current tab, when configured to keep the empty placeholder,
  -- we eagerly clean up the diff UI and state. This preserves any reused empty buffer.
  local keep_behavior = nil
  if config and config.diff_opts then
    keep_behavior = config.diff_opts.on_new_file_reject
  end
  if diff_data.is_new_file and keep_behavior == "keep_empty" and not diff_data.created_new_tab then
    M._cleanup_diff_state(tab_name, "diff rejected (keep_empty)")
  end
end

---Register autocmds for a specific diff
---@param tab_name string The diff identifier
---@param new_buffer number New file buffer ID
---@return table List of autocmd IDs
local function register_diff_autocmds(tab_name, new_buffer)
  local autocmd_ids = {}

  -- Handle :w command to accept diff changes (replaces both BufWritePost and BufWriteCmd)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      M._resolve_diff_as_saved(tab_name, new_buffer)
      -- Prevent actual file write since we're handling it through MCP
      return true
    end,
  })

  -- Buffer deletion monitoring for rejection (multiple events to catch all deletion methods)

  -- BufDelete: When buffer is deleted with :bdelete, :bwipeout, etc.
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufDelete", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufUnload: When buffer is unloaded (covers more scenarios)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufUnload", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufWipeout: When buffer is wiped out completely
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- Note: We intentionally do NOT monitor old_buffer for deletion
  -- because it's the actual file buffer and shouldn't trigger diff rejection

  return autocmd_ids
end

---Create diff view from a specific window
---@param target_window NvimWin|nil The window to use as base for the diff
---@param old_file_path string Path to the original file
---@param new_buffer NvimBuf New file buffer ID
---@param tab_name string The diff identifier
---@param is_new_file boolean Whether this is a new file (doesn't exist yet)
---@param terminal_win_in_new_tab NvimWin|nil Terminal window in new tab if created
---@param existing_buffer NvimBuf|nil Existing buffer for the file if already loaded
---@param force_reuse boolean? Always reuse target_window instead of splitting
---@return DiffLayoutInfo layout Info about the created diff layout
function M._create_diff_view_from_window(
  target_window,
  old_file_path,
  new_buffer,
  tab_name,
  is_new_file,
  terminal_win_in_new_tab,
  existing_buffer,
  force_reuse
)
  local original_buffer_created_by_plugin = false
  local target_window_created_by_plugin = false

  -- If no target window provided, create a new window in suitable location
  if not target_window then
    if terminal_win_in_new_tab then
      -- We're already in the main area after display_terminal_in_new_tab
      target_window = vim.api.nvim_get_current_win()
    else
      -- Try to create a new window in the main area
      vim.cmd("wincmd t") -- Go to top-left
      vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

      local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
      local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
      local filetype = vim.api.nvim_buf_get_option(buf, "filetype")

      if
        buftype == "terminal"
        or buftype == "prompt"
        or filetype == "neo-tree"
        or filetype == "snacks_picker_list"
        or filetype == "snacks_layout_box"
      then
        create_split()
      end

      target_window = vim.api.nvim_get_current_win()
    end
  else
    vim.api.nvim_set_current_win(target_window)
  end

  -- Decide window placement for the original file
  local choice = choose_original_window(target_window, old_file_path, is_new_file, terminal_win_in_new_tab, force_reuse)

  local original_window
  if choice.decision == "split" then
    vim.api.nvim_set_current_win(target_window)
    create_split()
    original_window = vim.api.nvim_get_current_win()
    target_window_created_by_plugin = true
  else
    original_window = choice.original_win
  end

  -- For new files, prefer reusing an existing empty buffer in the chosen window
  local original_buffer
  if is_new_file and choice.reused_buf and vim.api.nvim_buf_is_valid(choice.reused_buf) then
    original_buffer = choice.reused_buf
    original_buffer_created_by_plugin = false
  else
    if is_new_file then
      original_buffer_created_by_plugin = true
    end
    -- Load the original-side buffer into the chosen window
    original_buffer = load_original_buffer(original_window, old_file_path, is_new_file, existing_buffer)
  end

  -- Set up the proposed buffer and finalize the diff layout
  local new_win = setup_new_buffer(
    original_window,
    original_buffer,
    new_buffer,
    old_file_path,
    tab_name,
    terminal_win_in_new_tab,
    target_window
  )

  return {
    new_window = new_win,
    target_window = original_window,
    target_window_created_by_plugin = target_window_created_by_plugin,
    original_buffer = original_buffer,
    original_buffer_created_by_plugin = original_buffer_created_by_plugin,
  }
end

---Clean up diff state and resources
---@param tab_name string The diff identifier
---@param reason string Reason for cleanup
function M._cleanup_diff_state(tab_name, reason)
  local diff_data = active_diffs[tab_name]
  if not diff_data then
    return
  end

  -- Clean up autocmds
  for _, autocmd_id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end

  -- Clean up new tab if we created one (do this first to avoid double cleanup)
  if diff_data.created_new_tab then
    -- Always switch to the original tab first (if valid)
    if diff_data.original_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.original_tab_number) then
      pcall(vim.api.nvim_set_current_tabpage, diff_data.original_tab_number)
    end

    -- Prefer closing the specific new tab we created, if we tracked its handle/number
    if diff_data.new_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.new_tab_number) then
      -- Prefer closing by switching to the new tab then executing :tabclose
      pcall(vim.api.nvim_set_current_tabpage, diff_data.new_tab_number)
      pcall(vim.cmd, "tabclose")
      -- Restore original tab focus if still valid
      if diff_data.original_tab_number and vim.api.nvim_tabpage_is_valid(diff_data.original_tab_number) then
        pcall(vim.api.nvim_set_current_tabpage, diff_data.original_tab_number)
      end
    else
      -- Fallback: close the previously current tab if it's still around and not the original
      local current_tab = vim.api.nvim_get_current_tabpage()
      if vim.api.nvim_tabpage_is_valid(current_tab) and current_tab ~= diff_data.original_tab_number then
        pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(current_tab))
      end
    end

    -- Optionally ensure the Claude terminal remains visible in the original tab
    local terminal_ok, terminal_module = pcall(require, "claudecode.terminal")
    if terminal_ok and diff_data.had_terminal_in_original then
      pcall(terminal_module.ensure_visible)
      -- And restore its configured width if it is visible.
      -- (We intentionally do not resize floating terminals.)
      local terminal_win = find_claudecode_terminal_window()
      if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
        local win_config = vim.api.nvim_win_get_config(terminal_win)
        local is_floating = win_config.relative and win_config.relative ~= ""

        if not is_floating then
          local terminal_config = config.terminal or {}
          local split_width = terminal_config.split_width_percentage or 0.30
          local total_width = vim.o.columns
          local terminal_width = math.floor(total_width * split_width)
          pcall(vim.api.nvim_win_set_width, terminal_win, terminal_width)
        end
      end
    end
  else
    -- Close new diff window if still open (only if not in a new tab)
    if diff_data.new_window and vim.api.nvim_win_is_valid(diff_data.new_window) then
      pcall(vim.api.nvim_win_close, diff_data.new_window, true)
    end

    -- Close the fallback window we created when no editor window existed (issue #231); it's reused
    -- as the original pane, so target_window_created_by_plugin below doesn't cover it.
    if diff_data.fallback_window and vim.api.nvim_win_is_valid(diff_data.fallback_window) then
      pcall(vim.api.nvim_win_close, diff_data.fallback_window, false)
    end

    -- If we created an extra window/split for the diff, close it. Otherwise just disable diff mode.
    if diff_data.target_window and vim.api.nvim_win_is_valid(diff_data.target_window) then
      if diff_data.target_window_created_by_plugin then
        -- Try a non-forced close first to avoid dropping any user edits in that window.
        pcall(vim.api.nvim_win_close, diff_data.target_window, false)
      end

      -- If the target window is still around, ensure diff mode is off.
      if diff_data.target_window and vim.api.nvim_win_is_valid(diff_data.target_window) then
        vim.api.nvim_win_call(diff_data.target_window, function()
          vim.cmd("diffoff")
        end)
      end
    end

    -- Restore the buffer that was in the target window before the diff opened
    if
      not diff_data.target_window_created_by_plugin
      and diff_data.target_window
      and vim.api.nvim_win_is_valid(diff_data.target_window)
      and diff_data.pre_diff_buffer
      and vim.api.nvim_buf_is_valid(diff_data.pre_diff_buffer)
      and diff_data.pre_diff_buffer ~= vim.api.nvim_win_get_buf(diff_data.target_window)
    then
      pcall(vim.api.nvim_win_set_buf, diff_data.target_window, diff_data.pre_diff_buffer)
    end

    -- After closing the diff in the same tab, restore terminal width and focus.
    -- (We intentionally do not resize floating terminals.)
    local terminal_win = find_claudecode_terminal_window()
    if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
      local win_config = vim.api.nvim_win_get_config(terminal_win)
      local is_floating = win_config.relative and win_config.relative ~= ""

      if not is_floating then
        local terminal_config = config.terminal or {}
        local split_width = terminal_config.split_width_percentage or 0.30
        local total_width = vim.o.columns
        local terminal_width = math.floor(total_width * split_width)
        pcall(vim.api.nvim_win_set_width, terminal_win, terminal_width)
      end

      vim.schedule(function()
        if vim.api.nvim_win_is_valid(terminal_win) then
          local term_tab = vim.api.nvim_win_get_tabpage(terminal_win)
          if term_tab == vim.api.nvim_get_current_tabpage() then
            vim.api.nvim_set_current_win(terminal_win)
            if vim.bo.buftype == "terminal" then
              vim.cmd("startinsert")
            end
          end
        end
      end)
    end
  end

  -- ALWAYS clean up buffers regardless of tab mode (fixes buffer leak)
  -- Clean up the new buffer (proposed changes)
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    pcall(vim.api.nvim_buf_delete, diff_data.new_buffer, { force = true })
  end

  -- Clean up the original buffer only if it was created by the plugin for a new file
  if
    diff_data.is_new_file
    and diff_data.original_buffer
    and vim.api.nvim_buf_is_valid(diff_data.original_buffer)
    and diff_data.original_buffer_created_by_plugin
  then
    pcall(vim.api.nvim_buf_delete, diff_data.original_buffer, { force = true })
  end

  -- Remove from active diffs
  active_diffs[tab_name] = nil

  logger.debug("diff", "Cleaned up diff for", tab_name)
end

---Clean up all active diffs
---@param reason string Reason for cleanup
function M._cleanup_all_active_diffs(reason)
  for tab_name, _ in pairs(active_diffs) do
    M._cleanup_diff_state(tab_name, reason)
  end
end

---Read a file's contents from disk; returns empty string if the file is missing.
---@param path string
---@return string contents
local function read_file_contents_or_empty(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local data = f:read("*a") or ""
  f:close()
  return data
end

---Lazily initialize unified.nvim's diff namespace/highlights/signs.
---Safe to call multiple times — unified.config.setup is idempotent and merges
---over current values.
local function ensure_unified_initialized()
  local cfg_ok, unified_config = pcall(require, "unified.config")
  if cfg_ok and unified_config and unified_config.ns_id then
    return
  end
  pcall(function()
    require("unified").setup({ file_tree = { enabled = false } })
  end)
end

---Set up the blocking diff using unified.nvim's inline renderer.
---Single buffer containing the proposed content, inline +/- marks for the diff
---against the on-disk original. open_in_new_tab is intentionally ignored here.
---@param params table Parameters for the diff
---@param resolution_callback function Callback to call when diff resolves
function M._setup_blocking_diff_unified(params, resolution_callback)
  local tab_name = params.tab_name
  logger.debug("diff", "Setting up unified diff for:", params.old_file_path)

  dismiss_live_cursor_preview(params.old_file_path)

  local setup_success, setup_error = pcall(function()
    ensure_unified_initialized()
    local unified_diff = require("unified.diff")

    local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
    local is_new_file = not old_file_exists

    if old_file_exists and is_buffer_dirty(params.old_file_path) then
      error({
        code = -32000,
        message = "Cannot create diff: file has unsaved changes",
        data = "Please save (:w) or discard (:e!) changes to " .. params.old_file_path .. " before creating diff",
      })
    end

    -- Normalize the on-disk original's line endings too, so a CRLF file diffs
    -- cleanly against the (CRLF-stripped) proposed buffer instead of as a
    -- wholesale replacement.
    local old_text = is_new_file and "" or (read_file_contents_or_empty(params.old_file_path):gsub("\r\n", "\n"))

    -- All window discovery, buffer placement, and cursor positioning must
    -- happen in the tab that owns the active Claude message — otherwise the
    -- diff lands in whichever tab the user is currently looking at. The
    -- helpers below all read "current tab" implicitly, so we wrap the work in
    -- `in_owning_tab` which sets the owning tab as current for the duration.
    local target_window, pre_diff_buffer, new_buffer, original_cursor_pos, autocmd_ids
    local owning_tab = in_owning_tab(function(tab)
      target_window = find_window_adjacent_to_terminal()
      if not target_window then
        target_window = find_main_editor_window()
      end
      if not target_window then
        error({
          code = -32000,
          message = "No suitable editor window found",
          data = "Could not find a window to display the unified diff",
        })
      end

      pre_diff_buffer = vim.api.nvim_win_get_buf(target_window)

      new_buffer = vim.api.nvim_create_buf(false, true)
      if new_buffer == 0 then
        error({
          code = -32000,
          message = "Buffer creation failed",
          data = "Could not create proposed-changes buffer",
        })
      end

      local unique_name = is_new_file and (tab_name .. " (NEW FILE - proposed)") or (tab_name .. " (proposed)")
      pcall(vim.api.nvim_buf_set_name, new_buffer, unique_name)

      local lines, fileformat = content_to_lines(params.new_file_contents)
      vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, lines)

      vim.api.nvim_buf_set_option(new_buffer, "buftype", "acwrite")
      vim.api.nvim_buf_set_option(new_buffer, "bufhidden", "hide")
      vim.api.nvim_buf_set_option(new_buffer, "swapfile", false)
      vim.api.nvim_buf_set_option(new_buffer, "modifiable", true)
      vim.api.nvim_buf_set_option(new_buffer, "fileformat", fileformat)
      vim.api.nvim_buf_set_option(new_buffer, "modified", false)

      local ft = detect_filetype(params.old_file_path, nil)
      if ft and ft ~= "" then
        vim.api.nvim_set_option_value("filetype", ft, { buf = new_buffer })
      end

      original_cursor_pos = vim.api.nvim_win_get_cursor(target_window)
      vim.api.nvim_win_set_buf(target_window, new_buffer)

      unified_diff.show_against_text(new_buffer, old_text)

      local first_hunk_line = (vim.b[new_buffer].unified_hunks or {})[1]
      if first_hunk_line and vim.api.nvim_win_is_valid(target_window) then
        local line_count = vim.api.nvim_buf_line_count(new_buffer)
        local row = math.max(1, math.min(first_hunk_line, line_count))
        pcall(vim.api.nvim_win_set_cursor, target_window, { row, 0 })
        pcall(vim.api.nvim_win_call, target_window, function()
          vim.cmd("normal! zz")
        end)
      end

      vim.b[new_buffer].claudecode_diff_tab_name = tab_name
      vim.b[new_buffer].claudecode_diff_new_win = target_window
      vim.b[new_buffer].claudecode_diff_target_win = target_window

      autocmd_ids = register_diff_autocmds(tab_name, new_buffer)

      local refresh_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = get_autocmd_group(),
        buffer = new_buffer,
        callback = function()
          pcall(unified_diff.show_against_text, new_buffer, old_text)
        end,
      })
      autocmd_ids[#autocmd_ids + 1] = refresh_id

      return tab
    end)

    -- Focus shift runs on the next event loop tick. By then we are no longer
    -- inside in_owning_tab, so unconditionally setting target_window as
    -- current would yank the user to the owning tab. Only follow focus when
    -- the owning tab is already the user's current tab.
    if not (config and config.diff_opts and config.diff_opts.keep_terminal_focus) then
      vim.schedule(function()
        if not (vim.api.nvim_win_is_valid(target_window) and vim.api.nvim_win_get_buf(target_window) == new_buffer) then
          return
        end
        local win_tab = vim.api.nvim_win_get_tabpage(target_window)
        if win_tab == vim.api.nvim_get_current_tabpage() then
          vim.api.nvim_set_current_win(target_window)
        end
      end)
    end

    M._register_diff_state(tab_name, {
      old_file_path = params.old_file_path,
      new_file_path = params.new_file_path,
      new_file_contents = params.new_file_contents,
      new_buffer = new_buffer,
      new_window = nil, -- no separate diff window; we reused target_window
      target_window = target_window,
      target_window_created_by_plugin = false,
      pre_diff_buffer = pre_diff_buffer,
      original_buffer = nil,
      original_buffer_created_by_plugin = false,
      original_cursor_pos = original_cursor_pos,
      original_tab_number = owning_tab,
      created_new_tab = false,
      new_tab_number = nil,
      had_terminal_in_original = false,
      terminal_win_in_new_tab = nil,
      autocmd_ids = autocmd_ids,
      created_at = vim.fn.localtime(),
      status = "pending",
      resolution_callback = resolution_callback,
      result_content = nil,
      is_new_file = is_new_file,
      provider = "unified",
    })
  end)

  if not setup_success then
    local error_msg
    if type(setup_error) == "table" and setup_error.message then
      error_msg = "Failed to setup diff operation: " .. setup_error.message
      if setup_error.data then
        error_msg = error_msg .. " (" .. setup_error.data .. ")"
      end
    else
      error_msg = "Failed to setup diff operation: " .. tostring(setup_error)
    end

    if active_diffs[tab_name] then
      M._cleanup_diff_state(tab_name, "setup failed")
    end

    error({
      code = -32000,
      message = "Diff setup failed",
      data = error_msg,
    })
  end
end

---Set up blocking diff operation with simpler approach
---@param params table Parameters for the diff
---@param resolution_callback function Callback to call when diff resolves
function M._setup_blocking_diff(params, resolution_callback)
  local tab_name = params.tab_name
  logger.debug("diff", "Setting up diff for:", params.old_file_path)

  dismiss_live_cursor_preview(params.old_file_path)

  -- Determine target tab from the active Claude instance without switching the current tab.
  -- Falls back to current tab when no active-tab hint is available.
  local raw_active = _G._claudecode_active_tab_id
  local target_tab = get_owning_tab()
  logger.debug(
    "diff",
    "target tab resolution - raw _claudecode_active_tab_id:",
    tostring(raw_active),
    "resolved target_tab:",
    tostring(target_tab),
    "user_current_tab:",
    tostring(vim.api.nvim_get_current_tabpage()),
    "all tabs:",
    vim.inspect(vim.api.nvim_list_tabpages())
  )

  -- Hoisted so the error handler can clean them up if setup fails before the diff state is
  -- registered: otherwise the terminal-only fallback split and the proposed buffer are stranded
  -- (the state-based cleanup is gated on a registered diff). Issue #231.
  local fallback_window = nil
  local new_buffer = nil

  -- Wrap the setup in error handling to ensure cleanup on failure
  local setup_success, setup_error = pcall(function()
    local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
    local is_new_file = not old_file_exists

    if old_file_exists then
      local is_dirty = is_buffer_dirty(params.old_file_path)
      if is_dirty then
        error({
          code = -32000,
          message = "Cannot create diff: file has unsaved changes",
          data = "Please save (:w) or discard (:e!) changes to " .. params.old_file_path .. " before creating diff",
        })
      end
    end

    local original_tab_number = target_tab
    local created_new_tab = false
    local terminal_win_in_new_tab = nil
    local existing_buffer = nil
    local target_window = nil
    -- Track new tab handle and original terminal visibility for robust cleanup
    local new_tab_handle = nil
    local had_terminal_in_original = false

    if config and config.diff_opts and config.diff_opts.open_in_new_tab then
      original_tab_number, terminal_win_in_new_tab, had_terminal_in_original, new_tab_handle =
        display_terminal_in_new_tab()
      created_new_tab = true

      -- In new tab, no existing windows to use, so target_window will be created
      target_window = nil
      existing_buffer = nil
      -- Track extra metadata about terminal/tab for robust cleanup
      M._last_had_terminal_in_original = had_terminal_in_original -- for debugging
      M._last_new_tab_number = new_tab_handle -- for debugging
    end

    -- Only look for existing windows if we're NOT in a new tab
    if not created_new_tab then
      -- Search for existing buffer and target window directly in target_tab
      -- without switching the current tab.
      if old_file_exists then
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
            local buf_name = vim.api.nvim_buf_get_name(buf)
            if buf_name == params.old_file_path then
              existing_buffer = buf
              break
            end
          end
        end

        if existing_buffer then
          -- Find the window showing this buffer inside target_tab
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(target_tab)) do
            if vim.api.nvim_win_get_buf(win) == existing_buffer then
              target_window = win
              break
            end
          end
        end
      end

      if not target_window then
        -- Find the best main editor window in target_tab directly
        target_window = find_main_editor_window(vim.api.nvim_tabpage_list_wins(target_tab))
      end
    end
    -- If created_new_tab is true, target_window stays nil and will be created in the new tab.
    -- Otherwise, if no editor window is suitable (e.g. the Claude terminal is the only window --
    -- issue #231), create one by splitting the current window instead of erroring out, mirroring
    -- the fallback in lua/claudecode/tools/open_file.lua.
    if not target_window and not created_new_tab then
      create_split()
      local scratch_buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
      if scratch_buf ~= 0 then
        -- wipe it once it leaves the window so it isn't leaked when the diff reuses it (new file)
        -- or :edit replaces it with the real file (existing file)
        vim.api.nvim_buf_set_option(scratch_buf, "bufhidden", "wipe")
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), scratch_buf)
      end
      target_window = vim.api.nvim_get_current_win()
      -- Track it so _cleanup_diff_state closes it; the reused scratch buffer means it won't be
      -- flagged target_window_created_by_plugin.
      fallback_window = target_window
    end

    new_buffer = vim.api.nvim_create_buf(false, true) -- unlisted, scratch (hoisted above the pcall)
    if new_buffer == 0 then
      error({
        code = -32000,
        message = "Buffer creation failed",
        data = "Could not create new content buffer",
      })
    end

    local new_unique_name = is_new_file and (tab_name .. " (NEW FILE - proposed)") or (tab_name .. " (proposed)")
    vim.api.nvim_buf_set_name(new_buffer, new_unique_name)
    local lines, fileformat = content_to_lines(params.new_file_contents)
    vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, lines)

    vim.api.nvim_buf_set_option(new_buffer, "buftype", "acwrite") -- Allows saving but stays as scratch-like
    vim.api.nvim_buf_set_option(new_buffer, "modifiable", true)
    vim.api.nvim_buf_set_option(new_buffer, "fileformat", fileformat)

    -- Save the buffer currently in the target window so we can restore it after the diff closes
    local pre_diff_buffer = nil
    if not created_new_tab and target_window and vim.api.nvim_win_is_valid(target_window) then
      pre_diff_buffer = vim.api.nvim_win_get_buf(target_window)
    end

    -- For the non-new-tab path use nvim_win_call so that all vim window operations
    -- (diffthis, vsplit, wincmd) run in the context of the target tab without
    -- permanently changing the user's current tab/window.
    -- Use target_window as the entry point when available; otherwise fall back to
    -- any window in target_tab (e.g. the Claude terminal) and let
    -- _create_diff_view_from_window create a split next to it.
    local diff_info
    if not created_new_tab then
      local entry_win = target_window
      if not entry_win then
        local all_tab_wins = vim.api.nvim_tabpage_list_wins(target_tab)
        entry_win = all_tab_wins[1]
      end
      if not entry_win then
        error({
          code = -32000,
          message = "No suitable editor window found",
          data = "Could not find any window in the target tab to display the diff",
        })
      end
      vim.api.nvim_win_call(entry_win, function()
        diff_info = M._create_diff_view_from_window(
          target_window, -- may be nil; _create_diff_view_from_window will create a split
          params.old_file_path,
          new_buffer,
          tab_name,
          is_new_file,
          terminal_win_in_new_tab,
          existing_buffer,
          target_window ~= nil -- force_reuse only when we found a real target window
        )
      end)

      -- Diagnostic: capture which tab the diff actually landed in vs. the intended target.
      logger.debug(
        "diff",
        "post-create tabs - target_tab:",
        tostring(target_tab),
        "user_current_tab:",
        tostring(vim.api.nvim_get_current_tabpage()),
        "new_window:",
        tostring(diff_info and diff_info.new_window),
        "new_window_tab:",
        diff_info and diff_info.new_window and tostring(vim.api.nvim_win_get_tabpage(diff_info.new_window)) or "nil"
      )

      -- nvim_win_call restores focus to wherever the user was. If the diff opened in the
      -- user's active tab, focus the proposed ("theirs") window so they can review it
      -- immediately. For background tabs, leave focus unchanged.
      --
      -- Tab guard: only follow focus to new_window if it is genuinely in the user's tab.
      -- If new_window ended up in a different tab (a routing bug elsewhere), we must not
      -- yank the user across tabs by setting current win.
      if not (config and config.diff_opts and config.diff_opts.keep_terminal_focus) then
        if diff_info and diff_info.new_window then
          vim.schedule(function()
            if vim.api.nvim_win_is_valid(diff_info.new_window) then
              local new_win_tab = vim.api.nvim_win_get_tabpage(diff_info.new_window)
              if new_win_tab == vim.api.nvim_get_current_tabpage() then
                vim.api.nvim_set_current_win(diff_info.new_window)
              end
            end
          end)
        end
      end
    else
      -- new-tab path: we already switched to the new tab via display_terminal_in_new_tab
      diff_info = M._create_diff_view_from_window(
        target_window,
        params.old_file_path,
        new_buffer,
        tab_name,
        is_new_file,
        terminal_win_in_new_tab,
        existing_buffer,
        not created_new_tab
      )
    end

    local autocmd_ids = register_diff_autocmds(tab_name, new_buffer)

    local original_cursor_pos = nil
    if diff_info.target_window and vim.api.nvim_win_is_valid(diff_info.target_window) then
      original_cursor_pos = vim.api.nvim_win_get_cursor(diff_info.target_window)
    end

    M._register_diff_state(tab_name, {
      old_file_path = params.old_file_path,
      new_file_path = params.new_file_path,
      new_file_contents = params.new_file_contents,
      new_buffer = new_buffer,
      new_window = diff_info.new_window,
      target_window = diff_info.target_window,
      target_window_created_by_plugin = diff_info.target_window_created_by_plugin,
      pre_diff_buffer = pre_diff_buffer,
      fallback_window = fallback_window,
      original_buffer = diff_info.original_buffer,
      original_buffer_created_by_plugin = diff_info.original_buffer_created_by_plugin,
      original_cursor_pos = original_cursor_pos,
      original_tab_number = original_tab_number,
      created_new_tab = created_new_tab,
      new_tab_number = new_tab_handle,
      had_terminal_in_original = had_terminal_in_original,
      terminal_win_in_new_tab = terminal_win_in_new_tab,
      autocmd_ids = autocmd_ids,
      created_at = vim.fn.localtime(),
      status = "pending",
      resolution_callback = resolution_callback,
      result_content = nil,
      is_new_file = is_new_file,
      client_id = params.client_id,
    })
  end) -- End of pcall

  -- Handle setup errors
  if not setup_success then
    local error_msg
    if type(setup_error) == "table" and setup_error.message then
      -- Handle structured error objects
      error_msg = "Failed to setup diff operation: " .. setup_error.message
      if setup_error.data then
        error_msg = error_msg .. " (" .. setup_error.data .. ")"
      end
    else
      -- Handle string errors or other types
      error_msg = "Failed to setup diff operation: " .. tostring(setup_error)
    end

    -- Clean up any partial state that might have been created
    if active_diffs[tab_name] then
      M._cleanup_diff_state(tab_name, "setup failed")
    else
      -- Errored before the diff state was registered, so the state-based cleanup can't run. Close
      -- the fallback split we may have created (its bufhidden=wipe scratch self-cleans) and delete
      -- the proposed buffer; neither is owned by a registered diff.
      if fallback_window and vim.api.nvim_win_is_valid(fallback_window) then
        pcall(vim.api.nvim_win_close, fallback_window, true)
      end
      if new_buffer and vim.api.nvim_buf_is_valid(new_buffer) then
        pcall(vim.api.nvim_buf_delete, new_buffer, { force = true })
      end
    end

    -- Re-throw the error for MCP compliance
    error({
      code = -32000,
      message = "Diff setup failed",
      data = error_msg,
    })
  end
end

---Blocking diff operation for MCP compliance
---@param old_file_path string Path to the original file
---@param new_file_path string Path to the new file (used for naming)
---@param new_file_contents string Contents of the new file
---@param tab_name string Name for the diff tab/view
---@param client_id string|nil Id of the MCP client opening the diff (so it can be cleaned up if that client disconnects)
---@return table response MCP-compliant response with content array
function M.open_diff_blocking(old_file_path, new_file_path, new_file_contents, tab_name, client_id)
  -- Check for existing diff with same tab_name
  if active_diffs[tab_name] then
    local existing_diff = active_diffs[tab_name]
    -- Resolve the existing diff as rejected before replacing, but only if it was still pending.
    if existing_diff.status == "pending" then
      M._resolve_diff_as_rejected(tab_name)
    end
    -- Always clean up any leftover UI/state so we don't leak windows when reusing tab_names.
    M._cleanup_diff_state(tab_name, "replaced by new diff")
  end

  -- Set up blocking diff operation
  local co, is_main = coroutine.running()
  if not co or is_main then
    error({
      code = -32000,
      message = "Internal server error",
      data = "openDiff must run in coroutine context",
    })
  end

  logger.debug("diff", "Starting diff setup for", tab_name)

  local provider_ok, provider = pcall(M._resolve_provider)
  if not provider_ok then
    error(provider)
  end
  local setup_fn = provider == "unified" and M._setup_blocking_diff_unified or M._setup_blocking_diff
  logger.debug("diff", "Using diff provider:", provider)

  local success, err = pcall(setup_fn, {
    old_file_path = old_file_path,
    new_file_path = new_file_path,
    new_file_contents = new_file_contents,
    tab_name = tab_name,
    client_id = client_id,
  }, function(result)
    -- Resume the coroutine with the result
    local resume_success, resume_result = coroutine.resume(co, result)
    if resume_success then
      -- Use the global response sender to avoid module reloading issues
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key](resume_result)
        _G.claude_deferred_responses[co_key] = nil
      else
        logger.error("diff", "No global response sender found for coroutine:", co_key)
      end
    else
      logger.error("diff", "Coroutine failed:", tostring(resume_result))
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key]({
          error = {
            code = -32603,
            message = "Internal error",
            data = "Coroutine failed: " .. tostring(resume_result),
          },
        })
        _G.claude_deferred_responses[co_key] = nil
      end
    end
  end)

  if not success then
    local error_msg
    if type(err) == "table" and err.message then
      error_msg = err.message
      if err.data then
        error_msg = error_msg .. " - " .. err.data
      end
    else
      error_msg = tostring(err)
    end
    logger.error("diff", "Diff setup failed for", '"' .. tab_name .. '"', "error:", error_msg)
    -- If the error is already structured, propagate it directly
    if type(err) == "table" and err.code then
      error(err)
    else
      error({
        code = -32000,
        message = "Error setting up diff",
        data = tostring(err),
      })
    end
  end

  -- Yield and wait indefinitely for user interaction - the resolve functions will resume us
  local user_action_result = coroutine.yield()
  -- Return the result directly - this will be sent by the deferred response system
  return user_action_result
end

-- Set up global autocmds for shutdown handling
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = get_autocmd_group(),
  callback = function()
    M._cleanup_all_active_diffs("shutdown")
  end,
})

---Close diff by tab name (used by close_tab tool)
---@param tab_name string The diff identifier
---@return boolean success True if diff was found and closed
function M.close_diff_by_tab_name(tab_name)
  local diff_data = active_diffs[tab_name]
  if not diff_data then
    return false
  end

  -- If the diff was already saved, reload file buffers and clean up
  if diff_data.status == "saved" then
    -- Claude Code CLI has written the file, reload any open buffers
    if diff_data.old_file_path then
      -- Add a small delay to ensure Claude CLI has finished writing the file
      vim.defer_fn(function()
        M.reload_file_buffers_manual(diff_data.old_file_path, diff_data.original_cursor_pos)
      end, 100) -- 100ms delay
    end
    M._cleanup_diff_state(tab_name, "diff tab closed after save")
    return true
  end

  -- If the diff was already rejected, just clean up now
  if diff_data.status == "rejected" then
    M._cleanup_diff_state(tab_name, "diff tab closed after reject")
    return true
  end

  -- If still pending, treat as rejection and clean up
  if diff_data.status == "pending" then
    -- Mark as rejected and then clean up UI state now that we received explicit close request
    M._resolve_diff_as_rejected(tab_name)
    M._cleanup_diff_state(tab_name, "diff tab closed after reject")
    return true
  end

  return false
end

---Close every active diff matching an optional filter.
---Reuses close_diff_by_tab_name, which resolves still-pending diffs as rejected
---(resuming their coroutine) before tearing down the UI.
---@param filter_fn (fun(diff_data: table): boolean)|nil Only close diffs for which this returns true (nil = all)
---@param reason string Human-readable reason (for logging)
---@return number count Number of diffs closed
local function close_active_diffs(filter_fn, reason)
  local count = 0
  -- Snapshot the tab names first: close_diff_by_tab_name nils out entries as it
  -- goes, and mutating a table while iterating it with pairs() is undefined.
  local tab_names = {}
  for tab_name, diff_data in pairs(active_diffs) do
    if not filter_fn or filter_fn(diff_data) then
      tab_names[#tab_names + 1] = tab_name
    end
  end
  for _, tab_name in ipairs(tab_names) do
    if M.close_diff_by_tab_name(tab_name) then
      count = count + 1
    end
  end
  if count > 0 then
    logger.debug("diff", "Closed", count, "active diff(s):", reason)
  end
  return count
end

---Close all active diffs, resolving any still pending as rejected.
---Closes diffs in ANY state (including saved), so its only caller is the
---closeAllDiffTabs tool, where Claude is the connected client and has written
---accepted files. Automatic cleanup and the :ClaudeCodeCloseAllDiffs command
---deliberately use close_pending_diffs / close_diffs_for_client instead, to
---leave already-saved diffs alone -- see close_pending_diffs for why.
---@param reason string Human-readable reason (for logging)
---@return number count Number of diffs closed
function M.close_all_diffs(reason)
  return close_active_diffs(nil, reason or "close all diffs")
end

-- Automatic teardown (client disconnect, server stop) must only touch *pending*
-- diffs. A diff with status == "saved" has been :w'd by the user -- its edits
-- live only in the proposed buffer until Claude writes them to disk -- so closing
-- it would run close_diff_by_tab_name's saved-branch, wiping the proposed buffer
-- and reloading the file from unchanged disk, silently destroying the edits if
-- Claude died before writing. Pending diffs carry no such accepted content.

---Close every still-pending diff (e.g. on server stop, which bypasses
---on_disconnect). Leaves saved/rejected diffs for client-driven finalization.
---@param reason string Human-readable reason (for logging)
---@return number count Number of diffs closed
function M.close_pending_diffs(reason)
  return close_active_diffs(function(diff_data)
    return diff_data.status == "pending"
  end, reason or "close pending diffs")
end

---Close the still-pending diffs opened by a specific MCP client, used when that
---client disconnects so its orphaned diff windows don't linger (e.g. the Claude
---session that opened them exited or moved to remote control).
---@param client_id string The id of the client whose diffs should be closed
---@param reason string Human-readable reason (for logging)
---@return number count Number of diffs closed
function M.close_diffs_for_client(client_id, reason)
  if not client_id then
    return 0
  end
  return close_active_diffs(function(diff_data)
    return diff_data.client_id == client_id and diff_data.status == "pending"
  end, reason or ("client " .. tostring(client_id)))
end

---Test helper function (only for testing)
---@return table active_diffs The active diffs table
function M._get_active_diffs()
  return active_diffs
end

-- Shared helpers reused by the live-cursor feature (lua/claudecode/live_cursor.lua)
-- so it doesn't re-implement (and drift from) window discovery, filetype
-- detection, and unified.nvim initialization.
M.find_main_editor_window = find_main_editor_window
M.detect_filetype = detect_filetype
M.ensure_unified_initialized = ensure_unified_initialized

---Whether a review diff is currently open (pending) for the given file.
---Used by the live-cursor feature to avoid duplicating what the diff already shows.
---@param file_path string Absolute path to check.
---@return boolean
function M.is_live_for_file(file_path)
  for _, d in pairs(active_diffs) do
    if (d.new_file_path == file_path or d.old_file_path == file_path) and d.status == "pending" then
      return true
    end
  end
  return false
end

---Manual buffer reload function for testing/debugging
---@param file_path string Path to the file to reload
---@param original_cursor_pos table? Original cursor position {row, col}
---@return nil
function M.reload_file_buffers_manual(file_path, original_cursor_pos)
  return reload_file_buffers(file_path, original_cursor_pos)
end

---Accept the current diff (user command version)
---This function reads the diff context from buffer variables
function M.accept_current_diff()
  local current_buffer = vim.api.nvim_get_current_buf()
  local tab_name = vim.b[current_buffer].claudecode_diff_tab_name

  if not tab_name then
    vim.notify("No active diff found in current buffer", vim.log.levels.WARN)
    return
  end

  M._resolve_diff_as_saved(tab_name, current_buffer)
end

---Deny/reject the current diff (user command version)
---This function reads the diff context from buffer variables
function M.deny_current_diff()
  local current_buffer = vim.api.nvim_get_current_buf()
  local tab_name = vim.b[current_buffer].claudecode_diff_tab_name

  if not tab_name then
    vim.notify("No active diff found in current buffer", vim.log.levels.WARN)
    return
  end

  -- Do not close windows/tabs here; just mark as rejected.
  M._resolve_diff_as_rejected(tab_name)
end

return M
---@alias NvimWin integer
---@alias NvimBuf integer

---@alias DiffWindowDecision "reuse"|"split"

---@class DiffLayoutInfo
---@field new_window NvimWin
---@field target_window NvimWin
---@field target_window_created_by_plugin boolean
---@field original_buffer NvimBuf
---@field original_buffer_created_by_plugin boolean

---@class DiffWindowChoice
---@field decision DiffWindowDecision
---@field original_win NvimWin
---@field reused_buf NvimBuf|nil
---@field in_new_tab boolean
