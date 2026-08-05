---@brief [[
--- The `?` window: which keys reach the pane you are standing in.
---
--- The panes look like a plugin's own UI rather than like buffers, so the keys
--- that work in them are not discoverable the way `:map` makes an editor's keys
--- discoverable — which is why diffview, telescope and the rest all grew one of
--- these. Contents come from `agents_view`'s key table, the same one that binds
--- them, so this can only ever describe keys that exist.
---
--- Rendered into our own scratch buffer, highlighted with extmarks, and then
--- floated: by `snacks.win` when snacks is there (matching the confirm dialog
--- and giving the backdrop and `q`), otherwise by `nvim_open_win`. The buffer is
--- ours either way, so both paths look identical inside the border.
---@brief ]]
---@module 'claudecode.agents.help'

local M = {}

--- The open window, so a second `?` toggles rather than stacking floats.
---@type { win: integer|nil, buf: integer|nil, close: fun()|nil }|nil
local shown = nil

--- Titles for the pane the help was asked from.
local PANE_LABEL = {
  sessions = "Sessions",
  feed = "Activity",
  changes = "Changes",
  center = "Agent",
}

--- Widest key column we will pad to. Past this the description simply follows a
--- space: one long `lhs` should not indent every other line off the window.
local MAX_KEY_WIDTH = 12

local render = require("claudecode.agents.render")

---@param name string
---@return string group
local function hl(name)
  return render.highlight(name)
end

---Lines and their highlights, from the grouped entries.
---@param entries { group: string, keys: { lhs: string, desc: string }[] }[]
---@return string[] lines
---@return { row: integer, col: integer, end_col: integer, hl: string }[] marks
function M.render(entries)
  local width = 0
  for _, group in ipairs(entries) do
    for _, key in ipairs(group.keys) do
      width = math.max(width, vim.fn.strdisplaywidth(key.lhs))
    end
  end
  width = math.min(width, MAX_KEY_WIDTH)

  local lines, marks = {}, {}
  for index, group in ipairs(entries) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = group.group
    marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #group.group, hl = hl("header") }

    for _, key in ipairs(group.keys) do
      local pad = math.max(0, width - vim.fn.strdisplaywidth(key.lhs))
      local lhs = "  " .. key.lhs .. string.rep(" ", pad)
      lines[#lines + 1] = lhs .. "  " .. key.desc
      marks[#marks + 1] = { row = #lines - 1, col = 2, end_col = 2 + #key.lhs, hl = hl("key") }
    end
  end
  return lines, marks
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
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-help", { buf = buf })
  render.paint(buf, lines, marks)
  return buf
end

---Close the open help window, if any.
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
  return math.max(20, math.min(width + 2, math.floor(columns * 0.8))), math.min(#lines, math.floor(rows * 0.8))
end

---@param buf integer
---@param title string
---@param lines string[]
---@return boolean shown
local function open_snacks(buf, title, lines)
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
    wo = { wrap = false, cursorline = false },
    keys = {
      q = "close",
      ["<Esc>"] = "close",
      ["?"] = "close",
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
  return true
end

---@param buf integer
---@param title string
---@param lines string[]
---@return boolean shown
local function open_native(buf, title, lines)
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
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    pcall(vim.keymap.set, "n", lhs, function()
      M.close()
    end, { buffer = buf, nowait = true, silent = true, desc = "Close the Claude agents help" })
  end
  return true
end

---Show the help window. A second call while it is open closes it, so the same
---`?` that summoned it dismisses it.
---@param entries { group: string, keys: { lhs: string, desc: string }[] }[]
---@param pane string|nil Which pane asked, for the title.
---@return boolean shown
function M.open(entries, pane)
  if M.is_open() then
    M.close()
    return false
  end
  shown = nil

  if not entries or #entries == 0 then
    return false
  end

  local lines, marks = M.render(entries)
  local buf = make_buf(lines, marks)
  if not buf then
    return false
  end

  local title = "Claude agents"
  local label = pane and PANE_LABEL[pane]
  if label then
    title = title .. " — " .. label
  end

  if open_snacks(buf, title, lines) then
    return true
  end
  if open_native(buf, title, lines) then
    return true
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return false
end

return M
