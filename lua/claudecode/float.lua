---@brief [[
--- Floating windows for the files and diffs Claude asks to show.
---
--- There are two situations where a diff or a file has no editor window to go
--- into, and they are the same problem seen from different sides. In the agents
--- view every window is a pane — a terminal or a sidebar — and all of them are
--- deliberately excluded from being diff targets. With `diff_opts.layout =
--- "float"` the user has simply said they would rather read a diff over their
--- layout than have it split. A float answers both: it appears over whatever is
--- there, it is answerable, and closing it puts everything back.
---
--- Several floats can be open at once — several agents work in parallel, and a
--- burst of diffs arrives faster than you answer them. They **cascade**: each
--- offset from the last, newest on top, its title in the border. Queueing would
--- leave a diff blocked until you happened to work down to it, while the CLI
--- that asked for it waits.
---
--- Every float carries the `claudecode_live_preview` tag, so a second diff never
--- targets the window the first one is showing in.
---
--- This module is feature-neutral on purpose. It was extracted from
--- `agents/float.lua`, which is now a thin wrapper over it — before that,
--- `diff_opts.layout = "float"` silently took its width, height and border from
--- `agents.float`, so a user with `agents = { enabled = false }` was configuring
--- floats through a feature they had turned off, with no knob of their own.
---@brief ]]
---@module 'claudecode.float'

local M = {}

--- The top-level `float` config table.
---@type table|nil
local config = nil

--- Open floats, oldest first:
--- { win, buf, session_id, title, owned_buf, augroup }
local floats = {}

local DEFAULTS = {
  width = 0.7,
  height = 0.7,
  border = "rounded",
  -- Rows/columns each stacked float is offset by, so the one underneath is
  -- visible enough to aim at.
  cascade_offset = 2,
}

---@param full_config table|nil The whole plugin config.
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.float) == "table") and full_config.float or nil
end

---The geometry a float should use.
---@param overrides table|nil A feature's own float table, winning over the global one.
---@return table
function M.opts(overrides)
  local out = {}
  for key, value in pairs(DEFAULTS) do
    out[key] = value
  end
  for _, source in ipairs({ config, overrides }) do
    if type(source) == "table" then
      for key, value in pairs(source) do
        if value ~= nil then
          out[key] = value
        end
      end
    end
  end
  return out
end

---Drop floats whose windows are gone (the user closed one).
local function prune()
  local kept = {}
  for _, entry in ipairs(floats) do
    if entry.win and vim.api.nvim_win_is_valid(entry.win) then
      kept[#kept + 1] = entry
    end
  end
  floats = kept
end

---Geometry for the next float in the stack.
---@param opts table Merged float options.
---@return table config for nvim_open_win
local function next_geometry(opts)
  prune()
  local columns = vim.o.columns
  local lines = vim.o.lines

  local width = math.max(20, math.floor(columns * (opts.width or 0.7)))
  local height = math.max(5, math.floor(lines * (opts.height or 0.7)))
  local offset = (opts.cascade_offset or 2) * #floats

  -- Keep the whole cascade on screen: past a point, stop stepping rather than
  -- walking floats off the bottom-right corner.
  local row = math.floor((lines - height) / 2) + offset
  local col = math.floor((columns - width) / 2) + offset
  row = math.max(0, math.min(row, math.max(0, lines - height - 1)))
  col = math.max(0, math.min(col, math.max(0, columns - width)))

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
  }
end

---@param win integer
---@param entry table Registry row for this float.
---@param buf integer
---@param title string|nil
---@param owned_buf boolean
---@return integer win
---@return integer buf
local function reuse_window(win, entry, buf, title, owned_buf)
  pcall(vim.api.nvim_win_set_buf, win, buf)
  if vim.fn.has("nvim-0.9") == 1 then
    -- `nvim_win_set_config` needs the whole config back, so start from the one
    -- the window already has and change only the title.
    local ok, current = pcall(vim.api.nvim_win_get_config, win)
    if ok and type(current) == "table" and current.relative and current.relative ~= "" then
      current.title = title and (" " .. title .. " ") or nil
      current.title_pos = title and "center" or nil
      pcall(vim.api.nvim_win_set_config, win, current)
    end
  end
  entry.buf = buf
  entry.title = title
  entry.owned_buf = owned_buf
  return win, buf
end

---The window a closing float should hand insert mode back to, or nil.
---
---**The current window is only the answer when it actually holds a terminal.**
---A float is often opened from inside `nvim_win_call`, which makes another
---window current for the duration while leaving the mode alone — so `mode()`
---still says `t` while `nvim_get_current_win()` names a window the user is not
---in. Recording that window meant the restore below never matched the window
---focus came back to, and the terminal stayed in normal mode. A caller that
---knows it is about to spoof the current window passes `term_win` itself.
---@return integer|nil win
function M.terminal_mode_window()
  if vim.fn.mode() ~= "t" then
    return nil
  end
  local win = vim.api.nvim_get_current_win()
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if ok and buf and vim.bo[buf].buftype == "terminal" then
    return win
  end
  return nil
end

---@param win integer|nil A window a caller offered as the one to return to.
---@return integer|nil win nil unless it is a live window showing a terminal.
local function valid_terminal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if ok and buf and vim.bo[buf].buftype == "terminal" then
    return win
  end
  return nil
end

---Put the terminal a float interrupted back into insert mode when it closes.
---
---Answering a diff and dismissing it hands focus back to the Claude terminal the
---float opened over — in normal mode, so carrying on the conversation took a `i`
---the user never asked to press. Armed on `WinClosed` rather than in `M.close`,
---since a float also goes away by `:w`-acceptance, `:q` and the tab closing.
---@param win integer The float.
---@param term_win integer|nil The window that was in terminal-mode when it opened.
local function restore_terminal_mode(win, term_win)
  if not term_win then
    return
  end
  local ok_group, group = pcall(vim.api.nvim_create_augroup, "ClaudeCodeFloatMode" .. win, { clear = true })
  if not ok_group then
    return
  end
  pcall(vim.api.nvim_create_autocmd, "WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      -- Focus has not moved yet inside `WinClosed`, and with floats stacked it
      -- may well land on another one; both questions are only answerable after.
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(term_win) or vim.api.nvim_get_current_win() ~= term_win then
          return
        end
        local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, term_win)
        if ok_buf and vim.bo[buf].buftype == "terminal" then
          pcall(function()
            vim.cmd("startinsert")
          end)
        end
      end)
    end,
    desc = "Return to terminal insert mode when the Claude float closes",
  })
end

---Open a float, ready for a buffer to be placed in it.
---
---`opts.reuse` swaps the content of a float that is already open instead of
---stacking a new one on top. That is what makes stepping through a pane's files
---seamless: closing the old float first hands focus back to the pane for as long
---as the next one takes to build — and since the file history is read
---asynchronously, a held `<C-n>` lands several keypresses in that window, where
---they cycle the *session* instead. Reusing the window means focus never leaves
---the float at all.
---@param opts { session_id: string?, title: string?, buf: integer?, reuse: integer?,
---             float_opts: table?, border_hl: string?, tags: table<string, any>?,
---             purpose: string?, term_win: integer? }|nil
---@return integer|nil win
---@return integer|nil buf
function M.create(opts)
  opts = opts or {}
  -- Read before the float opens: entering it leaves terminal-mode, so by the
  -- time the window exists there is nothing left to notice. A caller that is
  -- inside `nvim_win_call` has to say which window that was; see
  -- `terminal_mode_window`.
  local term_win = valid_terminal_window(opts.term_win) or M.terminal_mode_window()
  local buf = opts.buf
  -- Whether the buffer is ours to put keymaps on; see `bind_close`.
  local owned_buf = false
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    if not buf or buf == 0 then
      return nil, nil
    end
    owned_buf = true
  end

  if opts.reuse and vim.api.nvim_win_is_valid(opts.reuse) then
    for _, entry in ipairs(floats) do
      if entry.win == opts.reuse then
        return reuse_window(opts.reuse, entry, buf, opts.title, owned_buf)
      end
    end
  end

  local win_config = next_geometry(M.opts(opts.float_opts))
  if opts.title and vim.fn.has("nvim-0.9") == 1 then
    win_config.title = " " .. opts.title .. " "
    win_config.title_pos = "center"
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, win_config)
  if not ok or not win then
    return nil, nil
  end

  pcall(function()
    -- Same "not a normal editor window" protocol the agents panes use, so a
    -- second diff never targets this one.
    vim.w[win].claudecode_live_preview = true
    vim.w[win].claudecode_float = true
    for name, value in pairs(opts.tags or {}) do
      vim.w[win][name] = value
    end
    vim.wo[win].winhighlight = "FloatBorder:" .. (opts.border_hl or "FloatBorder")
    vim.wo[win].wrap = false
    -- Almost everything that opens in one of these floats is a diff, and a diff
    -- is read by line — "which line was that" has no answer without the column.
    -- Set on the window rather than left to the user's global `number`, which a
    -- float does not reliably inherit. Absolute, since a diff is navigated by
    -- the numbers the rest of the world uses for that file, not by distance.
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
  end)

  floats[#floats + 1] = {
    win = win,
    buf = buf,
    session_id = opts.session_id,
    title = opts.title,
    owned_buf = owned_buf,
    -- What this float is for. `close_all` filters on it so that dismissing the
    -- file a plan was shown in never takes a *pending diff* down with it: a diff
    -- float is a question waiting for an answer, and closing it is not answering.
    purpose = opts.purpose or "view",
  }
  restore_terminal_mode(win, term_win)
  return win, buf
end

---Put `line` under the cursor and scroll it into view.
---@param win integer
---@param line integer|nil
---@param inline_diff boolean|nil The window shows unified.nvim's inline marks.
function M.jump_to(win, line, inline_diff)
  if not line or line < 1 then
    return
  end
  local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok_buf then
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(line, count)), 0 })
  -- A plain `zz` centres the changed *line span*, but unified.nvim renders
  -- deleted lines as virtual lines hung off those marks, so they scroll off the
  -- top. `center_diff_region` measures those too — and falls back to `zz` itself
  -- when it cannot — so it is a strict superset for a window showing a diff.
  if inline_diff then
    local ok_diff, diff = pcall(require, "claudecode.diff")
    if ok_diff and diff.center_diff_region then
      diff.center_diff_region(win, buf)
      return
    end
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zz")
  end)
end

---Show a file in a float.
---@param opts { session_id: string?, path: string, line: integer?, reuse: integer?,
---             float_opts: table?, border_hl: string?, tags: table<string, any>?,
---             purpose: string? }
---@return integer|nil win
function M.open_file(opts)
  local path = opts and opts.path
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local buf = vim.fn.bufadd(path)
  if not buf or buf == 0 then
    return nil
  end
  pcall(vim.fn.bufload, buf)

  local win = M.create({
    session_id = opts.session_id,
    title = vim.fn.fnamemodify(path, ":t"),
    buf = buf,
    reuse = opts.reuse,
    float_opts = opts.float_opts,
    border_hl = opts.border_hl,
    tags = opts.tags,
    purpose = opts.purpose,
  })
  if not win then
    return nil
  end
  M.jump_to(win, opts.line)
  M.bind_close(win)
  return win
end

---Whether a buffer already carries a normal-mode mapping for `lhs` that we did
---not put there.
---@param buf integer
---@param lhs string
---@return boolean
local function has_foreign_map(buf, lhs)
  local ok, maps = pcall(vim.api.nvim_buf_get_keymap, buf, "n")
  if not ok or type(maps) ~= "table" then
    return false
  end
  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end

---Give a float `q` to close just it and `<Tab>` to reach the one behind it.
---
---Cycling matters because floats cascade: without it, a diff underneath another
---would need the mouse to answer.
---
---**These are buffer-local maps, and a float may hold a real file buffer** —
---`open_file` puts one there, and with `openFile` routed to floats that is the
---common case rather than a rare one. A buffer-local map outlives the window it
---was made for, so without the two rules below every file Claude ever showed you
---would carry a `q` that closes a window, in every window, for the rest of the
---session. So: a mapping somebody else already made is left alone, and ours are
---removed when the float closes.
---@param win integer
function M.bind_close(win)
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return
  end

  local bound = {}
  local wanted = {
    ["q"] = {
      desc = "Close this Claude float",
      run = function()
        M.close(win)
      end,
    },
    ["<Tab>"] = {
      desc = "Focus the next Claude float",
      run = function()
        M.focus_next()
      end,
    },
  }
  for lhs, spec in pairs(wanted) do
    if not has_foreign_map(buf, lhs) then
      local set =
        pcall(vim.keymap.set, "n", lhs, spec.run, { buffer = buf, nowait = true, silent = true, desc = spec.desc })
      if set then
        bound[#bound + 1] = lhs
      end
    end
  end
  if #bound == 0 then
    return
  end

  -- Tied to the window rather than to `M.close`, because a float can also go
  -- away by `:q`, `<C-w>c`, or the whole tab closing — none of which reach us.
  local ok_group, group = pcall(vim.api.nvim_create_augroup, "ClaudeCodeFloatKeys" .. win, { clear = true })
  if not ok_group then
    return
  end
  for _, entry in ipairs(floats) do
    if entry.win == win then
      entry.augroup = group
    end
  end
  pcall(vim.api.nvim_create_autocmd, "WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      for _, lhs in ipairs(bound) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
    desc = "Drop the Claude float's keymaps with the float",
  })
end

---@param win integer|nil
function M.close(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    prune()
    return
  end
  pcall(vim.api.nvim_win_close, win, true)
  prune()
end

---Close the floats a predicate selects.
---@param wanted fun(entry: table): boolean
---@return integer closed
local function close_where(wanted)
  local closed = 0
  for _, entry in ipairs(floats) do
    if wanted(entry) and entry.win and vim.api.nvim_win_is_valid(entry.win) then
      pcall(vim.api.nvim_win_close, entry.win, true)
      closed = closed + 1
    end
  end
  prune()
  return closed
end

---Close a conversation's floats — all of them when its agent ended, or only the
---ones opened for a given purpose.
---@param session_id string
---@param purpose string|nil Restrict to floats opened with this purpose.
---@return integer closed
function M.close_all(session_id, purpose)
  return close_where(function(entry)
    if entry.session_id ~= session_id then
      return false
    end
    return purpose == nil or entry.purpose == purpose
  end)
end

---A conversation was renamed under an open float.
---
---An agent that runs `/clear` keeps its floats — they are windows on work it has
---already done — but the conversation that asked for them now goes by a
---different id, and `close_all` is what takes them down when the agent ends. A
---float left under the old name would outlive its agent.
---@param old_session_id string
---@param session_id string
---@return integer retagged
function M.retag(old_session_id, session_id)
  if type(old_session_id) ~= "string" or type(session_id) ~= "string" then
    return 0
  end
  local moved = 0
  for _, entry in ipairs(floats) do
    if entry.session_id == old_session_id then
      entry.session_id = session_id
      moved = moved + 1
    end
  end
  return moved
end

---Close everything.
---@return integer closed
function M.close_every()
  return close_where(function()
    return true
  end)
end

---Move focus to the next float in the stack, so a diff behind another is
---reachable without the mouse.
---@return integer|nil win
function M.focus_next()
  prune()
  if #floats == 0 then
    return nil
  end
  local current = vim.api.nvim_get_current_win()
  local at = 0
  for index, entry in ipairs(floats) do
    if entry.win == current then
      at = index
      break
    end
  end
  local target = floats[(at % #floats) + 1]
  if target and vim.api.nvim_win_is_valid(target.win) then
    pcall(vim.api.nvim_set_current_win, target.win)
    return target.win
  end
  return nil
end

---@return table[] open floats (a copy; callers cannot corrupt the stack)
function M.list()
  prune()
  local out = {}
  for _, entry in ipairs(floats) do
    out[#out + 1] = {
      win = entry.win,
      buf = entry.buf,
      session_id = entry.session_id,
      title = entry.title,
      owned_buf = entry.owned_buf,
      purpose = entry.purpose,
    }
  end
  return out
end

---@return integer
function M.count()
  prune()
  return #floats
end

---Test/reload helper.
function M.reset()
  for _, entry in ipairs(floats) do
    if entry.augroup then
      pcall(vim.api.nvim_del_augroup_by_id, entry.augroup)
    end
  end
  floats = {}
end

return M
