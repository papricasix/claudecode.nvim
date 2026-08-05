---@brief [[
--- The agents view's floats: `claudecode.float` with this feature's geometry.
---
--- The window machinery — the cascade, the tags, `q`/`<Tab>`, the stack every
--- open float lives in — is shared with `diff_opts.layout = "float"` and lives in
--- `claudecode.float`. One stack, so a diff float and an agent's float cascade
--- past each other instead of landing on top of one another.
---
--- What is left here is the part that is actually about agents: which
--- conversation a float belongs to (so `close_all` can take an ended agent's
--- floats with it), the `agents.float` geometry overriding the global one, and
--- the `agents.highlights.float` border.
---@brief ]]
---@module 'claudecode.agents.float'

local base = require("claudecode.float")

local M = {}

--- Agents config subtable.
---@type table|nil
local config = nil

---@param full_config table|nil
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
  -- The shared module needs the top-level `float` block whether or not agents
  -- mode is on; setting it up from here as well means a config reload reaches it
  -- through either path.
  base.setup(full_config)
end

---@return table|nil
local function float_opts()
  return config and config.float or nil
end

---@return string
local function border_hl()
  return (config and config.highlights and config.highlights.float) or "ClaudeCodeAgentsFloat"
end

--- What marks a float as this feature's, on top of the shared tags.
local TAGS = { claudecode_agents_float = true }

---Open a float for one conversation.
---@param session_id string|nil Conversation this float belongs to.
---@param opts { title: string?, buf: integer?, reuse: integer?, purpose: string? }|nil
---@return integer|nil win
---@return integer|nil buf
function M.create(session_id, opts)
  opts = opts or {}
  return M.create_for({
    session_id = session_id,
    title = opts.title,
    buf = opts.buf,
    reuse = opts.reuse,
    purpose = opts.purpose,
  })
end

---Open a float from a table, which is what `diff.open_float` calls through.
---
---The routing seam knows only the module name a tab put on its layout
---descriptor, so this is the adapter onto this wrapper's own signature — the
---seam never learns that agents mode exists.
---@param opts { session_id: string?, title: string?, purpose: string?, buf: integer?, reuse: integer? }
---@return integer|nil win
---@return integer|nil buf
function M.create_for(opts)
  opts = opts or {}
  return base.create({
    session_id = opts.session_id,
    title = opts.title,
    buf = opts.buf,
    reuse = opts.reuse,
    purpose = opts.purpose,
    float_opts = float_opts(),
    border_hl = border_hl(),
    tags = TAGS,
  })
end

---Show a file in a float.
---@param session_id string|nil
---@param path string
---@param line integer|nil
---@param reuse integer|nil Float to swap this into, rather than stacking a new one.
---@return integer|nil win
function M.open_file(session_id, path, line, reuse)
  return base.open_file({
    session_id = session_id,
    path = path,
    line = line,
    reuse = reuse,
    float_opts = float_opts(),
    border_hl = border_hl(),
    tags = TAGS,
  })
end

M.jump_to = base.jump_to
M.bind_close = base.bind_close
M.close = base.close
M.close_all = base.close_all
M.close_every = base.close_every
M.focus_next = base.focus_next
M.list = base.list
M.count = base.count
M.reset = base.reset

return M
