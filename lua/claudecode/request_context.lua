---@brief [[
--- Who asked? — the identity of the Claude instance whose message is being
--- handled right now.
---
--- Every WebSocket server instance sets this before dispatching a message and the
--- tool handlers read it synchronously while servicing that message. It replaces
--- the `_G._claudecode_active_tab_id` global, which could only say *which tab*.
--- That was enough while a tab held exactly one Claude, but agents mode runs
--- several in one tab, and "open this diff" then has to know which agent asked —
--- to label its float, and to keep one agent's `closeAllDiffTabs` from tearing
--- down another's.
---
--- The value is set per message rather than per connection because a handler may
--- yield (`openDiff` blocks on the user accepting or rejecting) and resume long
--- after another instance has handled something else. Anything needed after a
--- yield must therefore be captured *before* it, not read back from here.
---@brief ]]
---@module 'claudecode.request_context'

local M = {}

---@class ClaudeCodeRequestContext
---@field instance_id string|nil Registry key of the owning instance.
---@field tab integer|nil Tabpage the owning Claude was launched in.
---@field session_id string|nil Conversation id, when the owner is an agent.
---@field kind "tab"|"agent"|nil

---@type ClaudeCodeRequestContext|nil
local current = nil

---Record the owner of the message about to be handled.
---@param ctx ClaudeCodeRequestContext|nil
function M.set(ctx)
  current = ctx
end

---@return ClaudeCodeRequestContext|nil
function M.get()
  return current
end

function M.clear()
  current = nil
end

---Tabpage of the Claude that sent the message being handled.
---@return integer|nil tab nil when no owner is known (tests, legacy paths).
function M.tab()
  local ctx = current
  if not ctx or not ctx.tab then
    return nil
  end
  if not vim.api.nvim_tabpage_is_valid(ctx.tab) then
    return nil
  end
  return ctx.tab
end

---Conversation id of the Claude that sent the message being handled.
---@return string|nil
function M.session_id()
  return current and current.session_id or nil
end

---Registry key of the instance that sent the message being handled.
---
---Capture this before any handler that blocks on the user: it identifies *who
---asked*, and by the time a blocking handler resumes the context belongs to
---whoever asked most recently.
---@return string|nil
function M.get_instance_id()
  return current and current.instance_id or nil
end

return M
