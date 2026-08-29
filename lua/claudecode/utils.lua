---Shared utility functions for claudecode.nvim
---@module 'claudecode.utils'

local M = {}

---Set a window-local option **without touching the user's global value**.
---
---This is not a stylistic preference, it is the only correct way to configure a
---window we made. `vim.wo[win].wrap = false` and `nvim_set_option_value(…, {win =
---w})` both behave like `:set` rather than `:setlocal` **when `w` is the current
---window** — they write the global value too, and every window opened afterwards
---inherits it. Measured: opening the agents view (whose panes are configured
---while each is current, and which turn `wrap`, `number`, `list` and `spell` off
---because they draw fixed-width list rows) left the user's global `wrap=false
---number=false list=false`, so every file they opened for the rest of the session
---wore a list pane's settings. A float did the same, one option at a time.
---
---`scope = "local"` is the fix, and it is safe on a window that is not current
---too, so this is used for every window option this plugin sets on its own
---windows.
---@param win integer
---@param name string
---@param value any
---@return boolean ok
function M.set_win_option(win, name, value)
  return (pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" }))
end

---Normalizes focus parameter to default to true for backward compatibility
---@param focus boolean? The focus parameter
---@return boolean valid Whether the focus parameter is valid
function M.normalize_focus(focus)
  if focus == nil then
    return true
  else
    return focus
  end
end

---Read n random bytes from a cryptographically secure source.
---Tries libuv's OS CSPRNG first, then falls back to /dev/urandom.
---Never falls back to math.random: a weak token is worse than a startup error.
---@param n number The number of random bytes to read
---@return string bytes A string of exactly n random bytes
function M.random_bytes(n)
  -- Prefer libuv's uv_random (OS CSPRNG). Use vim.loop.random (available on
  -- Neovim 0.8+) rather than vim.uv.random (only aliased on 0.10+).
  if vim.loop and vim.loop.random then
    local ok, bytes = pcall(vim.loop.random, n)
    if ok and type(bytes) == "string" and #bytes == n then
      return bytes
    end
  end

  -- Fallback: read directly from the kernel CSPRNG.
  local file = io.open("/dev/urandom", "rb")
  if file then
    local bytes = file:read(n)
    file:close()
    if type(bytes) == "string" and #bytes == n then
      return bytes
    end
  end

  error("Failed to obtain " .. n .. " bytes of secure random data (no vim.loop.random or readable /dev/urandom)")
end

---Split a command string into an argument vector using POSIX shell word rules.
---
---Honors single quotes, double quotes, and backslash escapes so terminal
---providers can spawn Claude directly (without a shell) while preserving quoted
---arguments such as `--message='hello world'`. Spawning without a shell also
---avoids glob expansion of bracketed model aliases like `opus[1m]` (e.g. zsh
---aborts an unmatched glob with "no matches found", so Claude never launches).
---@param cmd string The command string to split.
---@return string[] argv The parsed argument vector.
function M.shell_split(cmd)
  local argv = {}
  local current = nil -- nil = between words; string (incl. "") = building a word
  local i = 1
  local n = #cmd
  while i <= n do
    local c = cmd:sub(i, i)
    if c == " " or c == "\t" then
      if current ~= nil then
        argv[#argv + 1] = current
        current = nil
      end
    elseif c == "'" then
      -- Single quotes: everything up to the next single quote is literal.
      current = current or ""
      local close = cmd:find("'", i + 1, true)
      if close then
        current = current .. cmd:sub(i + 1, close - 1)
        i = close
      else
        current = current .. cmd:sub(i + 1)
        i = n
      end
    elseif c == '"' then
      -- Double quotes: backslash escapes only " \ $ `.
      current = current or ""
      i = i + 1
      while i <= n do
        local d = cmd:sub(i, i)
        if d == '"' then
          break
        elseif d == "\\" and i < n then
          local nextc = cmd:sub(i + 1, i + 1)
          if nextc == '"' or nextc == "\\" or nextc == "$" or nextc == "`" then
            current = current .. nextc
            i = i + 1
          else
            current = current .. d
          end
        else
          current = current .. d
        end
        i = i + 1
      end
    elseif c == "\\" and i < n then
      current = (current or "") .. cmd:sub(i + 1, i + 1)
      i = i + 1
    else
      current = (current or "") .. c
    end
    i = i + 1
  end
  if current ~= nil then
    argv[#argv + 1] = current
  end
  return argv
end

---Expand a leading `~` or `~/` in a single argument to the user's home
---directory, matching shell tilde expansion at the start of a word. Embedded
---tildes (e.g. `--path=~/x`) and the `~user` form are intentionally left
---untouched, exactly as a shell would treat a non-word-initial tilde.
---@param arg string
---@return string
function M.expand_tilde(arg)
  if arg:sub(1, 1) ~= "~" then
    return arg
  end
  local home = os.getenv("HOME")
  if not home or home == "" then
    return arg
  end
  if arg == "~" then
    return home
  elseif arg:sub(1, 2) == "~/" then
    return home .. arg:sub(2)
  end
  return arg
end

---Parse a command string into an argv list the way a shell would for our
---purposes: split into words honoring quotes/escapes (see `shell_split`), then
---expand a leading tilde in each word. Terminal providers use this to spawn
---Claude directly (no shell) while still preserving quoted arguments and the
---documented `terminal_cmd = "~/.claude/local/claude"` local-install path.
---Globbing and variable expansion are deliberately NOT performed -- avoiding the
---shell is what keeps bracketed aliases like `opus[1m]` intact.
---@param cmd string
---@return string[] argv
function M.parse_command(cmd)
  local argv = M.shell_split(cmd)
  for i = 1, #argv do
    argv[i] = M.expand_tilde(argv[i])
  end
  return argv
end

---Whether this Neovim runs on native Windows (not WSL, which is Linux).
---@return boolean
function M.is_windows()
  if vim and vim.fn and vim.fn.has then
    return vim.fn.has("win32") == 1
  end
  -- Outside Neovim (a spec loading this module bare), the interpreter's own
  -- directory separator is the answer.
  return package.config:sub(1, 1) == "\\"
end

---A path in one comparable form: `/` separators, no trailing separator.
---
---Windows hands the same directory back in more than one shape — `vim.fn.getcwd()`
---gives `D:\Git\proj`, git reports `lua/x.lua`, and the CLI writes whichever its
---own runtime produced — so any code that compares two paths, or uses one as a
---table key, has to agree on a spelling first. Comparison only: the result is not
---a path to hand to the filesystem, since it drops the separator the platform
---actually uses.
---@param path string
---@return string
function M.normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  local out = path:gsub("\\", "/"):gsub("/+", "/")
  -- Keep a root: `/` and `D:/` are directories, `` and `D:` are not.
  if #out > 1 and out:sub(-1) == "/" and not out:match("^%a:/$") then
    out = out:sub(1, -2)
  end
  return out
end

---A path as a table key. `normalize_path`, case-folded on Windows, where the two
---spellings of a drive letter name one file.
---@param path string
---@return string
function M.path_key(path)
  local out = M.normalize_path(path)
  if M.is_windows() then
    out = out:lower()
  end
  return out
end

---Truncate to a display width, marking the cut.
---@param text string
---@param width integer
---@return string
function M.truncate(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  -- Cut by display cells, not bytes: a multibyte title would otherwise be sliced
  -- mid-character and render as a replacement glyph.
  local out = vim.fn.strcharpart(text, 0, width - 1)
  while vim.fn.strdisplaywidth(out) > width - 1 and #out > 0 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

---Cut a filename to a width while keeping its extension.
---
---A plain tail-cut drops the extension first, which is the half of a filename
---that says what kind of thing it is; `render.lua` and `render.md` are two files
---and `render…` is neither. The extension is dropped only when keeping it would
---leave no room for the name in front of it.
---@param name string
---@param width integer
---@return string
local function fit_name(name, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(name) <= width then
    return name
  end
  local stem, ext = name:match("^(.+)(%.[^./]+)$")
  if stem then
    local room = width - vim.fn.strdisplaywidth(ext)
    -- Two cells: one character of the name and the cut mark. Below that the
    -- extension is all you would see, which names no file.
    if room >= 2 then
      return M.truncate(stem, room) .. ext
    end
  end
  return M.truncate(name, width)
end

---Split a path into segments, keeping a leading `/` on the first one, and report
---the separator it was written with.
---
---Both separators are split on, and a Windows drive is kept with the segment that
---follows it (`D:\Git\proj` -> `D:\Git`, `proj`): `D:` on its own is not the
---coarse "where in the project" answer `shorten_path` picks a first segment for.
---A path split on `/` alone left a Windows path as one segment, which sent it to
---the tail cut this whole function exists to avoid.
---@param path string
---@return string[] segments, string separator
local function path_segments(path)
  local segments = {}
  for segment in path:gmatch("[^/\\]+") do
    segments[#segments + 1] = segment
  end
  local separator = path:find("\\", 1, true) and not path:find("/", 1, true) and "\\" or "/"
  if segments[1] then
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
      segments[1] = path:sub(1, 1) .. segments[1]
    elseif segments[1]:match("^%a:$") and segments[2] then
      segments[1] = segments[1] .. separator .. segments[2]
      table.remove(segments, 2)
    end
  end
  return segments, separator
end

---Fit a path into a width from the inside out, so the filename always survives.
---
---`M.truncate` cuts the tail, which on a path throws away the one part you were
---reading it for: a narrow pane turned `lua/claudecode/agents/render.lua` into
---`lua/claudecod…`, so every file in a directory looked alike. This drops
---*interior* directories instead, and only as many as the width demands, in the
---order they are worth least:
---
---  1. the whole path, if it fits;
---  2. `first/…/parent/name` — where in the project, and which module;
---  3. `first/…/name` — where in the project;
---  4. `…/name` — the name, said to be part of a path;
---  5. `name`;
---  6. `name` cut, extension kept (`fit_name`).
---
---The first folder outranks the parent because it is the coarser answer: in a
---list of files from one session, `lua/…/init.lua` and `tests/…/init.lua` are
---told apart by it, while their parents are often the same word.
---@param path string
---@param width integer Display cells.
---@return string
function M.shorten_path(path, width)
  if type(path) ~= "string" or path == "" or width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end

  local segments, sep = path_segments(path)
  local count = #segments
  if count <= 1 then
    return fit_name(path, width)
  end

  local name = segments[count]
  local first, parent = segments[1], segments[count - 1]

  local candidates = {}
  -- Only when the ellipsis actually stands for something: with three segments
  -- `first/…/parent/name` would spell the whole path with a cut mark in it.
  if count >= 4 then
    candidates[#candidates + 1] = first .. sep .. "…" .. sep .. parent .. sep .. name
  end
  if count >= 3 then
    candidates[#candidates + 1] = first .. sep .. "…" .. sep .. name
  end
  candidates[#candidates + 1] = "…" .. sep .. name
  candidates[#candidates + 1] = name

  for _, candidate in ipairs(candidates) do
    if vim.fn.strdisplaywidth(candidate) <= width then
      return candidate
    end
  end
  return fit_name(name, width)
end

---A path shown relative to a directory it is under.
---
---Compared in normalized form, since the two spellings need not match: on Windows
---the session's cwd is `D:\Git\proj` while the same directory can reach us as
---`D:/Git/proj`. What is returned is a slice of the original, so the path keeps
---the separators it was written with.
---@param path string
---@param root string|nil
---@return string
function M.relative_path(path, root)
  if type(path) ~= "string" then
    return ""
  end
  if type(root) == "string" and root ~= "" then
    local prefix = M.path_key(root) .. "/"
    local key = M.path_key(path)
    if key:sub(1, #prefix) == prefix then
      -- Normalizing rewrites separators and case in place, so an offset into the
      -- key is the same offset into the path — unless it also collapsed a
      -- doubled separator, in which case the key's own remainder is the answer.
      return #key == #path and path:sub(#prefix + 1) or key:sub(#prefix + 1)
    end
  end
  return path
end

---How a float's border title names a file.
---
---The tail alone does not say *where*: a project has several `init.lua`, and a
---float is opened over work you may not have on screen. The path is shown
---relative to the directory it belongs to — the prefix every file in a project
---shares says nothing — and `~`-shortened when it is outside that directory,
---which is exactly the case where being elsewhere is the point.
---
---Fitted here rather than left to the border: Neovim cuts a title that does not
---fit at its *right* edge, which is the filename. `shorten_path` drops interior
---directories instead, so `lua/…/agents/file_view.lua` still names it.
---@param path string
---@param root string|nil Directory the path is shown relative to.
---@param note string|nil Parenthesised aside, e.g. `"(vs HEAD)"`.
---@param width integer Display cells the title has to fit into.
---@return string
function M.path_title(path, root, note, width)
  local suffix = (type(note) == "string" and note ~= "") and ("  " .. note) or ""
  if type(path) ~= "string" or path == "" then
    return (suffix:gsub("^%s+", ""))
  end
  local text = M.relative_path(path, root)
  if text == path then
    text = vim.fn.fnamemodify(path, ":~")
  end
  return M.shorten_path(text, width - vim.fn.strdisplaywidth(suffix)) .. suffix
end

---Where the Claude CLI keeps its state.
---
---One rule, because three features read it — the lock files it discovers editors
---through (`lockfile`), the transcript store a conversation lives in
---(`agents.transcript`), and the check for whether a session id can be resumed
---(`session_state`). Three copies of it meant a change to the rule — a Windows
---case, an XDG fallback — would silently leave those features disagreeing about
---where the CLI's state is, and the disagreement shows up as "the session exists
---but cannot be restored".
---@return string dir
function M.claude_config_dir()
  local override = os.getenv("CLAUDE_CONFIG_DIR")
  if override and override ~= "" then
    return vim.fn.expand(override)
  end
  return vim.fn.expand("~/.claude")
end

return M
