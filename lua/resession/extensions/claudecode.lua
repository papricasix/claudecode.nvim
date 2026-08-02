---@brief [[
--- resession.nvim extension: saves each tab's Claude conversation id alongside
--- the session, and re-arms it on load so the tab's Claude resumes where it left
--- off (the terminal itself opens lazily, on the tab's next toggle).
---
--- Enable it with:
---   require("resession").setup({ extensions = { claudecode = {} } })
--- and set `session_persistence = "external"` in the claudecode.nvim config, so
--- the plugin tracks ids but leaves storage to resession.
---@brief ]]
---@module 'resession.extensions.claudecode'

local M = {}

---@param opts table|nil resession's save options (unused).
---@return table data Payload for the session file (empty when nothing to save).
function M.on_save(opts) -- luacheck: ignore 212
  local ok, session_state = pcall(require, "claudecode.session_state")
  if not ok then
    return {}
  end
  return session_state.capture() or {}
end

---@param data table Payload previously returned by `on_save`.
---@param opts table|nil resession's load options (unused).
function M.on_post_load(data, opts) -- luacheck: ignore 212
  local ok, session_state = pcall(require, "claudecode.session_state")
  if not ok then
    return
  end
  session_state.restore(data)
end

return M
