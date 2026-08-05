---@brief [[
--- A yes/no dialog for the one thing in agents mode that cannot be undone.
---
--- `vim.fn.confirm` blocks the editor on a message line and reads a keypress with
--- no window at all, which is the wrong weight for "this deletes a conversation
--- permanently" — the question deserves to be read. So when snacks.nvim is
--- present the question opens as a small centred float, and `vim.fn.confirm`
--- stays as the fallback, since this plugin has no hard dependencies.
---
--- The answer always arrives through the callback, exactly once: cancelling,
--- pressing `q`, or closing the window some other way all count as "no". The
--- callback is deferred out of the closing window's own keymap so it is free to
--- open windows of its own.
---@brief ]]
---@module 'claudecode.agents.confirm'

local M = {}

---@class ClaudeCodeAgentsConfirmOpts
---@field title string|nil Window title, shown on the border.
---@field message string|string[] The question.
---@field confirm string|nil Label for the confirming key (default "confirm").
---@field cancel string|nil Label for the cancelling key (default "cancel").

--- Keys that answer, and how. Bound in the float and echoed in its footer line.
local YES = { "y", "Y", "<CR>" }
local NO = { "n", "N", "q", "<Esc>" }

---@param message string|string[]
---@return string[]
local function to_lines(message)
  if type(message) == "table" then
    return vim.deepcopy(message)
  end
  return vim.split(tostring(message), "\n", { plain = true })
end

---@param opts ClaudeCodeAgentsConfirmOpts
---@return string
local function footer_line(opts)
  return ("  [y] %s    [n] %s"):format(opts.confirm or "confirm", opts.cancel or "cancel")
end

---Try the snacks float. Returns false when snacks is not installed, so the
---caller can fall back rather than losing the question.
---@param opts ClaudeCodeAgentsConfirmOpts
---@param cb fun(ok: boolean)
---@return boolean shown
function M._snacks(opts, cb)
  local ok_win, snacks_win = pcall(require, "snacks.win")
  if not ok_win or type(snacks_win) ~= "table" then
    return false
  end

  local lines = to_lines(opts.message)
  lines[#lines + 1] = ""
  lines[#lines + 1] = footer_line(opts)

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(width + 2, vim.fn.strdisplaywidth(opts.title or "") + 4)

  -- Answer once. Every key closes the window, and closing it answers, so without
  -- this a "no" would follow every "yes".
  local answered = false
  local function answer(value)
    if answered then
      return
    end
    answered = true
    -- Out of the keymap, so the callback may open windows of its own.
    vim.schedule(function()
      cb(value)
    end)
  end

  local keys = {}
  for _, lhs in ipairs(YES) do
    keys[lhs] = function(self)
      answer(true)
      self:close()
    end
  end
  for _, lhs in ipairs(NO) do
    keys[lhs] = function(self)
      answer(false)
      self:close()
    end
  end

  local built = snacks_win({
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = "center",
    border = "rounded",
    width = width,
    height = #lines,
    enter = true,
    backdrop = 60,
    zindex = 60,
    text = lines,
    wo = { wrap = false, cursorline = false },
    bo = { filetype = "claudecode-confirm", modifiable = false },
    keys = keys,
    on_close = function()
      answer(false)
    end,
  })
  return built ~= nil
end

---Ask, and answer through `cb`. Never blocks the caller.
---@param opts ClaudeCodeAgentsConfirmOpts
---@param cb fun(ok: boolean)
function M.ask(opts, cb)
  local ok_shown, shown = pcall(M._snacks, opts, cb)
  if ok_shown and shown then
    return
  end
  local lines = to_lines(opts.message)
  if opts.title then
    table.insert(lines, 1, opts.title)
  end
  -- Default to the cancelling choice: `vim.fn.confirm` answers with it on <Esc>
  -- and on an interrupted prompt, and this is the deleting path.
  local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Yes\n&No", 2)
  cb(choice == 1)
end

return M
