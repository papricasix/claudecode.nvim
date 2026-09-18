---@brief [[
--- A one-line text prompt in a small float, for the few things in agents mode
--- that take a word from the user — naming a checkpoint, so far.
---
--- Built the way the search box is: our own window over a real buffer, so every
--- editing key works and the look matches the rest of the view, rather than
--- `vim.ui.input`, whose appearance is whatever the user's UI plugin makes of it
--- and whose fallback is the command line. The answer arrives through the
--- callback exactly once: `<CR>` hands back the text (empty allowed — clearing a
--- name is an answer), `<Esc>` and any other way of closing the window hand back
--- nil. The callback runs outside the closing keymap, so it may open windows.
---@brief ]]
---@module 'claudecode.agents.input'

local render = require("claudecode.agents.render")
local utils = require("claudecode.utils")

local M = {}

---@class ClaudeCodeAgentsInputOpts
---@field title string|nil Shown on the border.
---@field default string|nil Text the prompt opens with, cursor at its end.
---@field width integer|nil Inner width in cells; sized to the title and text otherwise.

--- The open prompt, so a second ask replaces the first rather than stacking.
---@type { win: integer, buf: integer }|nil
local open = nil

---Ask for a line of text.
---@param opts ClaudeCodeAgentsInputOpts
---@param cb fun(text: string|nil)
---@return boolean shown false when no window could be opened (the callback is then answered nil).
function M.ask(opts, cb)
  opts = opts or {}
  if open then
    pcall(vim.api.nvim_win_close, open.win, true)
    open = nil
  end

  local buf = vim.api.nvim_create_buf(false, true)
  if not buf or buf == 0 then
    cb(nil)
    return false
  end
  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "bufhidden", "wipe", { buf = buf })
  pcall(vim.api.nvim_set_option_value, "filetype", "claudecode-agents-input", { buf = buf })
  local default = type(opts.default) == "string" and opts.default or ""
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { default })

  local columns = vim.o.columns or 80
  local lines = vim.o.lines or 24
  local title = opts.title and (" " .. opts.title .. " ") or nil
  local width = opts.width
    or math.max(30, vim.fn.strdisplaywidth(default) + 10, title and (vim.fn.strdisplaywidth(title) + 4) or 0)
  width = math.min(width, math.max(10, columns - 4))

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(0, math.floor((lines - 3) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    zindex = 61,
  })
  if not ok_win or not win then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    cb(nil)
    return false
  end
  open = { win = win, buf = buf }
  utils.set_win_option(win, "wrap", false)
  utils.set_win_option(win, "winhighlight", "FloatBorder:" .. render.highlight("float"))

  -- Answer once. Closing answers nil, so an accepted answer has to be recorded
  -- before the window goes.
  local answered = false
  local function answer(text)
    if answered then
      return
    end
    answered = true
    if open and open.win == win then
      open = nil
    end
    vim.schedule(function()
      cb(text)
    end)
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local function map(lhs, fn, desc)
    for _, mode in ipairs({ "i", "n" }) do
      pcall(vim.keymap.set, mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  map("<CR>", function()
    local text = (vim.api.nvim_buf_get_lines(buf, 0, 1, false) or {})[1] or ""
    answer(text)
    close()
  end, "Claude agents: accept")
  for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
    map(lhs, function()
      answer(nil)
      close()
    end, "Claude agents: cancel")
  end
  pcall(vim.api.nvim_create_autocmd, "WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      answer(nil)
    end,
  })

  -- Typing is what the window is for: open in insert mode, at the end of what is
  -- already there.
  pcall(vim.api.nvim_win_set_cursor, win, { 1, #default })
  pcall(vim.cmd, "startinsert!")
  return true
end

---Whether a prompt is on screen.
---@return boolean
function M.is_open()
  return open ~= nil and vim.api.nvim_win_is_valid(open.win)
end

---Test/reload helper.
function M.reset()
  if open then
    pcall(vim.api.nvim_win_close, open.win, true)
  end
  open = nil
end

return M
