---@brief [[
--- The `gs` window: what the session list is ordered by.
---
--- The list does not re-sort itself (see `model.apply_order`), which makes the
--- order stable enough to navigate but also makes the criterion invisible state
--- — nothing on screen says why a row is where it is. This is where that state
--- is shown and changed, and it is the only thing that shows it, which is why it
--- names the direction in the words of the criterion ("newest first", not "↓").
---
--- Same construction as the help window: our own scratch buffer, rendered and
--- highlighted here, floated by `snacks.win` when snacks is there and by
--- `nvim_open_win` otherwise, so both paths look identical inside the border.
--- One keystroke picks — `r`, `n`, `c`, `s` — with `<CR>` on the cursor line for
--- anyone who would rather look first.
---@brief ]]
---@module 'claudecode.agents.sort_menu'

local M = {}

--- The open window, so a second `gs` toggles rather than stacking floats.
---@type { win: integer|nil, buf: integer|nil, close: fun()|nil }|nil
local shown = nil

local FOOTER = "pick the active one again to reverse it"

--- Same glyph the sessions pane marks its selected row with.
local ACTIVE_MARK = "❯"

local render = require("claudecode.agents.render")

---@param name string
---@return string group
local function hl(name)
  return render.highlight(name)
end

---How a criterion's current direction reads.
---@param spec table An entry of `model.SORTS`.
---@param desc boolean
---@return string
function M.direction_label(spec, desc)
  return desc and spec.down or spec.up
end

---Lines, highlights, and which line offers which criterion.
---@param items table[] Entries of `model.SORTS`.
---@param active { key: string, desc: boolean }
---@return string[] lines
---@return table[] marks
---@return table<integer, string> by_line 1-based line -> criterion key
function M.render(items, active)
  local width = 0
  for _, spec in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(spec.label))
  end

  local lines, marks, by_line = {}, {}, {}
  for _, spec in ipairs(items) do
    local is_active = spec.key == active.key
    local mark = is_active and (ACTIVE_MARK .. " ") or "  "
    -- Padded only where something follows it: the direction is on the active row
    -- alone, so padding every row would be trailing whitespace on three of four.
    local pad = is_active and string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(spec.label))) or ""
    local line = mark .. spec.accel .. "  " .. spec.label .. pad
    local label_at = #mark + #spec.accel + 2

    if is_active then
      line = line .. "   " .. M.direction_label(spec, active.desc)
    end
    lines[#lines + 1] = line
    by_line[#lines] = spec.key

    if is_active then
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #ACTIVE_MARK, hl = hl("selected") }
    end
    marks[#marks + 1] = { row = #lines - 1, col = #mark, end_col = #mark + #spec.accel, hl = hl("key") }
    marks[#marks + 1] = {
      row = #lines - 1,
      col = label_at,
      end_col = label_at + #spec.label,
      hl = hl(is_active and "header" or "title"),
    }
    if is_active then
      marks[#marks + 1] = { row = #lines - 1, col = label_at + #spec.label + #pad, end_col = #line, hl = hl("time") }
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  " .. FOOTER
  marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], hl = hl("time") }
  return lines, marks, by_line
end

---@param lines string[]
---@param marks table[]
---@return integer|nil buf
local function make_buf(lines, marks)
  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    return nil
  end
  pcall(vim.api.nvim_buf_set_option, buf, "buftype", "nofile")
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-sort", { buf = buf })
  render.paint(buf, lines, marks)
  return buf
end

---Close the open menu, if any.
function M.close()
  local open = shown
  shown = nil
  if not open then
    return
  end
  if open.close then
    pcall(open.close)
  elseif open.win and vim.api.nvim_win_is_valid(open.win) then
    pcall(vim.api.nvim_win_close, open.win, true)
  end
  if open.buf and vim.api.nvim_buf_is_valid(open.buf) then
    pcall(vim.api.nvim_buf_delete, open.buf, { force = true })
  end
end

---@return boolean
function M.is_open()
  return shown ~= nil and shown.win ~= nil and vim.api.nvim_win_is_valid(shown.win)
end

---@param lines string[]
---@return integer width, integer height
local function dimensions(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local columns = vim.o.columns or 80
  local rows = vim.o.lines or 24
  return math.max(24, math.min(width + 2, math.floor(columns * 0.8))), math.min(#lines, math.floor(rows * 0.8))
end

---Which row the cursor should start on: the criterion already active.
---@param items table[]
---@param active { key: string }
---@return integer
local function active_line(items, active)
  for index, spec in ipairs(items) do
    if spec.key == active.key then
      return index
    end
  end
  return 1
end

---@param buf integer
---@param title string
---@param lines string[]
---@param lnum integer
---@return boolean shown
local function open_snacks(buf, title, lines, lnum)
  local ok, snacks_win = pcall(require, "snacks.win")
  if not ok or type(snacks_win) ~= "table" then
    return false
  end
  local width, height = dimensions(lines)
  local win = snacks_win({
    buf = buf,
    title = " " .. title .. " ",
    title_pos = "center",
    border = "rounded",
    width = width,
    height = height,
    enter = true,
    backdrop = 60,
    zindex = 60,
    wo = { wrap = false, cursorline = true },
    keys = {
      q = "close",
      ["<Esc>"] = "close",
    },
    on_close = function()
      shown = nil
    end,
  })
  if not win then
    return false
  end
  shown = {
    win = win.win,
    -- snacks owns the buffer's lifetime once it is handed over.
    buf = nil,
    close = function()
      win:close()
    end,
  }
  pcall(vim.api.nvim_win_set_cursor, win.win, { lnum, 0 })
  return true
end

---@param buf integer
---@param title string
---@param lines string[]
---@param lnum integer
---@return boolean shown
local function open_native(buf, title, lines, lnum)
  local width, height = dimensions(lines)
  local columns = vim.o.columns or 80
  local rows = vim.o.lines or 24
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((rows - height) / 2) - 1),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    zindex = 60,
  })
  if not ok or not win then
    return false
  end
  shown = { win = win, buf = buf }
  pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = win })
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    pcall(vim.keymap.set, "n", lhs, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true, desc = "Close the Claude agents sort menu" })
  end
  return true
end

---Show the menu. A second call while it is open closes it, so the same `gs` that
---summoned it dismisses it.
---@param items table[] Entries of `model.SORTS`.
---@param active { key: string, desc: boolean }
---@param on_pick fun(key: string) Called at most once, after the menu is closed.
---@return boolean shown
function M.open(items, active, on_pick)
  if M.is_open() then
    M.close()
    return false
  end
  shown = nil

  if not items or #items == 0 then
    return false
  end

  local lines, marks, by_line = M.render(items, active)
  local buf = make_buf(lines, marks)
  if not buf then
    return false
  end

  -- Answered exactly once, whichever way the window goes away: a keymap on the
  -- buffer outlives the close it triggers, and `<CR>` on a criterion is the same
  -- answer as its accelerator.
  local answered = false
  local function pick(key)
    if answered or not key then
      return
    end
    answered = true
    M.close()
    -- Out of the closing keymap, for the reason `confirm` defers its callback:
    -- the window is still going away underneath us, and what happens next opens
    -- windows of its own.
    vim.schedule(function()
      pcall(on_pick, key)
    end)
  end

  for _, spec in ipairs(items) do
    pcall(vim.keymap.set, "n", spec.accel, function()
      pick(spec.key)
    end, { buffer = buf, nowait = true, silent = true, desc = "Claude agents: sort by " .. spec.label })
  end
  pcall(vim.keymap.set, "n", "<CR>", function()
    local win = shown and shown.win
    local lnum = 1
    if win and vim.api.nvim_win_is_valid(win) then
      lnum = vim.api.nvim_win_get_cursor(win)[1]
    end
    pick(by_line[lnum])
  end, { buffer = buf, nowait = true, silent = true, desc = "Claude agents: sort by the criterion under the cursor" })

  local lnum = active_line(items, active)
  if open_snacks(buf, "Sort sessions", lines, lnum) then
    return true
  end
  if open_native(buf, "Sort sessions", lines, lnum) then
    return true
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return false
end

return M
