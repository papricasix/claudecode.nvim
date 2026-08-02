---@brief [[
--- Per-tab Claude CLI session identity, and the seam session managers use to
--- persist it.
---
--- Each tab's Claude is launched with `--session-id <uuid>` so the conversation
--- has a stable name we chose, instead of one we would have to discover. That id
--- is what makes "restore my tabs, each with its chat" possible: on a later
--- Neovim start the tab is handed the id back and Claude launches with
--- `--resume <uuid>`.
---
--- This module deliberately performs no file I/O of its own. It exposes
--- `capture()`/`restore()` over a plain, versioned Lua table so whatever already
--- persists the user's Neovim session carries the Claude ids too:
---   * `session_persistence = "global"` - we mirror the payload into
---     `vim.g.CLAUDECODE_SESSION`, which `:mksession` writes when 'sessionoptions'
---     contains "globals" (plain mksession, persistence.nvim, mini.sessions).
---   * `session_persistence = "external"` - we store nothing; a host drives us
---     (auto-session's `save_extra_data`/`restore_extra_data`, or the shipped
---     resession extension at `lua/resession/extensions/claudecode.lua`).
---
--- Tabs are keyed by tab *number* (their left-to-right position), not by tabpage
--- handle: handles are not stable across a restart, and `:mksession` cannot save
--- tab-local variables, so position is the only identity a restored session
--- reproduces.
---@brief ]]
---@module 'claudecode.session_state'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

--- Bumped only on an incompatible payload change; unknown versions are ignored
--- rather than guessed at, so an old Neovim never mis-reads a new session file.
local PAYLOAD_VERSION = 1

--- Uppercase and String-valued, the two conditions `:mksession` puts on a global
--- for 'sessionoptions'+=globals to carry it.
local GLOBAL_VAR = "CLAUDECODE_SESSION"

--- Flags that already decide the conversation. If the user (or `terminal_cmd`)
--- passes one of these we keep our hands off the command entirely.
local CONFLICTING_FLAGS = {
  ["-r"] = true,
  ["--resume"] = true,
  ["-c"] = true,
  ["--continue"] = true,
  ["--session-id"] = true,
  ["--fork-session"] = true,
  ["--from-pr"] = true,
}

---@class ClaudeCodeSessionRecord
---@field session_id string The UUID passed to the CLI for this tab.
---@field cwd string|nil Directory Claude was launched in (resume is scoped to it).
---@field resumed boolean|nil Whether this id came back from a restored session.
---@field fallback string|nil Last id of this tab's that the CLI wrote a transcript
--- for, kept so an id that never becomes a conversation cannot cost the tab the
--- one it had.

--- Live sessions: [tabpage handle] = ClaudeCodeSessionRecord
local records = {}

--- Ids handed back by a restored Neovim session, not yet claimed by a launch:
--- [tabpage handle] = ClaudeCodeSessionRecord
local pending = {}

--- "off" | "global" | "external"
local mode = "off"

--------------------------------------------------------------------------------
-- Setup / state
--------------------------------------------------------------------------------

---@param full_config table|nil The full plugin config.
function M.setup(full_config)
  local value = full_config and full_config.session_persistence
  mode = (value == "global" or value == "external") and value or "off"
  M.sync_global()
end

---@return boolean enabled Whether session ids are tracked at all.
function M.is_enabled()
  return mode ~= "off"
end

---@return string mode One of "off", "global", "external".
function M.get_mode()
  return mode
end

---Session record for a tab, if it has one (live first, then a pending restore).
---@param tab_id number|nil
---@return ClaudeCodeSessionRecord|nil
function M.get(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  return records[tab_id] or pending[tab_id]
end

---Forget a tab's conversation, so nothing resumes it.
---
---Wired to the Claude process ending while Neovim is still running: that is the
---user closing the chat, and a closed chat should not come back — not when the
---terminal is reopened in this Neovim, and not from a restored session. Neovim
---quitting is *not* this case; it is told apart by ordering, see the `TermClose`
---watcher in `init.lua`.
---@param tab_id number|nil Defaults to the current tabpage.
---@return boolean forgot Whether the tab had anything to forget.
function M.forget(tab_id)
  tab_id = tab_id or vim.api.nvim_get_current_tabpage()
  if not records[tab_id] and not pending[tab_id] then
    return false
  end
  logger.debug("session", "forgetting the conversation for tab " .. tostring(tab_id) .. " (Claude was closed)")
  records[tab_id] = nil
  pending[tab_id] = nil
  M.sync_global()
  return true
end

---Drop bookkeeping for tabs that no longer exist (wired to TabClosed).
function M.forget_closed_tabs()
  local changed = false
  for _, store in ipairs({ records, pending }) do
    for tab_id in pairs(store) do
      if not vim.api.nvim_tabpage_is_valid(tab_id) then
        store[tab_id] = nil
        changed = true
      end
    end
  end
  if changed then
    M.sync_global()
  end
end

---Test/reload helper: forget everything.
function M.reset()
  records = {}
  pending = {}
end

--------------------------------------------------------------------------------
-- Session ids
--------------------------------------------------------------------------------

---@return string uuid A random RFC 4122 version 4 UUID.
local function uuid4()
  local bytes = { utils.random_bytes(16):byte(1, 16) }
  -- Version 4 in the high nibble of byte 7, variant 10xx in the top bits of 9.
  bytes[7] = bytes[7] % 16 + 64
  bytes[9] = bytes[9] % 64 + 128
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format("%02x", bytes[i])
  end
  return table.concat(hex, "", 1, 4)
    .. "-"
    .. table.concat(hex, "", 5, 6)
    .. "-"
    .. table.concat(hex, "", 7, 8)
    .. "-"
    .. table.concat(hex, "", 9, 10)
    .. "-"
    .. table.concat(hex, "", 11, 16)
end

---@return string dir The Claude CLI's config directory.
local function claude_config_dir()
  local override = os.getenv("CLAUDE_CONFIG_DIR")
  if override and override ~= "" then
    return vim.fn.expand(override)
  end
  return vim.fn.expand("~/.claude")
end

---Whether the CLI has a transcript for this session id. `--resume` on an id with
---no transcript (a Claude that was launched but never talked to) fails, so this
---gates every resume we build.
---
---Globs across all project directories rather than deriving the directory name
---from the cwd: the CLI's path-to-slug rule is undocumented, while session ids
---are unique on their own.
---@param session_id string
---@return boolean|nil exists nil when it cannot be determined (assume yes).
local function transcript_exists(session_id)
  local ok, result = pcall(function()
    local projects = claude_config_dir() .. "/projects"
    if vim.fn.isdirectory(projects) ~= 1 then
      return nil
    end
    local hits = vim.fn.glob(projects .. "/*/" .. session_id .. ".jsonl", true, true)
    return type(hits) == "table" and #hits > 0
  end)
  if not ok then
    return nil
  end
  return result
end

---The id worth handing to a session manager: one the CLI has actually written a
---transcript for.
---
---An id we minted is only a *name* until the user sends their first message —
---the CLI creates no transcript before that, and `--resume` on such an id fails.
---Persisting it anyway is what made restores rot: opening a tab's terminal and
---not talking in it replaced the tab's real conversation with an id that could
---never come back, so the next session resumed some tabs and started the rest
---fresh, over and over. So a record also carries the last id of its tab that did
---exist, and an unproven id falls back to it rather than overwriting it.
---@param record ClaudeCodeSessionRecord|nil
---@return string|nil id nil when the tab has nothing resumable.
local function persistable_id(record)
  if type(record) ~= "table" or type(record.session_id) ~= "string" or record.session_id == "" then
    return nil
  end
  -- `~= false` so an undeterminable check (no projects dir yet, a glob error)
  -- keeps the id rather than discarding a conversation over a missing answer.
  if transcript_exists(record.session_id) ~= false then
    return record.session_id
  end
  if type(record.fallback) == "string" and record.fallback ~= "" and transcript_exists(record.fallback) ~= false then
    return record.fallback
  end
  return nil
end

---Whether a command line already picks a conversation itself.
---@param cmd_string string|nil
---@return boolean
local function has_session_flag(cmd_string)
  if type(cmd_string) ~= "string" or cmd_string == "" then
    return false
  end
  for _, token in ipairs(utils.shell_split(cmd_string)) do
    if CONFLICTING_FLAGS[token:match("^([^=]+)=") or token] then
      return true
    end
  end
  return false
end

---Extra `claude` arguments naming this tab's conversation.
---
---Idempotent per tab: every terminal toggle rebuilds the command, so a tab keeps
---the id it was given rather than minting a new one each time.
---@param cmd_string string|nil The command built so far (checked for conflicts).
---@param resolved_cwd string|nil The directory the terminal will spawn in.
---@return string args Empty when disabled or when the command already decides.
function M.launch_args(cmd_string, resolved_cwd)
  if not M.is_enabled() or has_session_flag(cmd_string) then
    return ""
  end

  local ok_tab, tab_id = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_tab then
    return ""
  end
  local cwd = resolved_cwd
  if not cwd or cwd == "" then
    local ok_cwd, current = pcall(vim.fn.getcwd)
    cwd = ok_cwd and current or nil
  end

  local previous = records[tab_id]
  local record = previous
  if not record then
    record = M._claim_pending(tab_id, cwd)
  end
  if not record then
    local ok_uuid, id = pcall(uuid4)
    if not ok_uuid then
      logger.error("session", "could not generate a session id: " .. tostring(id))
      return ""
    end
    -- Brand new and therefore not resumable yet; keep whatever this tab last had
    -- so a Claude that is opened and never talked to costs nothing.
    record = { session_id = id, cwd = cwd, fallback = persistable_id(previous) }
  end

  records[tab_id] = record
  M.sync_global()

  if record.resumed or transcript_exists(record.session_id) then
    return "--resume " .. record.session_id
  end
  return "--session-id " .. record.session_id
end

---Turn a restored id for this tab into a live record, if it still applies.
---@param tab_id number
---@param cwd string|nil The directory the terminal is about to spawn in.
---@return ClaudeCodeSessionRecord|nil
---@private
function M._claim_pending(tab_id, cwd)
  local entry = pending[tab_id]
  if not entry then
    return nil
  end
  pending[tab_id] = nil

  -- A conversation lives in the directory it was started in; if this tab now
  -- points somewhere else, the restored id belongs to a different project.
  if entry.cwd and cwd and entry.cwd ~= cwd then
    logger.debug("session", "not resuming " .. entry.session_id .. ": cwd is now " .. cwd)
    return nil
  end
  if transcript_exists(entry.session_id) == false then
    logger.debug("session", "not resuming " .. entry.session_id .. ": no transcript on disk")
    return nil
  end

  logger.debug("session", "resuming " .. entry.session_id .. " in tab " .. tostring(tab_id))
  return { session_id = entry.session_id, cwd = cwd or entry.cwd, resumed = true }
end

---Record the id the CLI actually reports (from the launch hook). Authoritative:
---it corrects our guess after `/clear`, a compaction, or a manual `--resume`.
---@param tab_id number|nil
---@param session_id string|nil
---@param cwd string|nil
function M.note_session_id(tab_id, session_id, cwd)
  if not M.is_enabled() or type(session_id) ~= "string" or session_id == "" then
    return
  end
  tab_id = tonumber(tab_id)
  if not tab_id or tab_id == 0 or not vim.api.nvim_tabpage_is_valid(tab_id) then
    return
  end

  local record = records[tab_id]
  if record and record.session_id == session_id then
    return
  end
  pending[tab_id] = nil
  records[tab_id] = {
    session_id = session_id,
    cwd = (type(cwd) == "string" and cwd ~= "" and cwd) or (record and record.cwd) or nil,
    resumed = record and record.resumed or nil,
    -- The tab just moved to a different conversation (/clear, a manual resume);
    -- the one it leaves stays the fallback until this one has a transcript.
    fallback = persistable_id(record),
  }
  logger.debug("session", "tab " .. tostring(tab_id) .. " is running session " .. session_id)
  M.sync_global()
end

--------------------------------------------------------------------------------
-- Persistence seam
--------------------------------------------------------------------------------

---Snapshot the per-tab session ids for a session manager to store.
---Safe to call at any time; returns nil when there is nothing worth saving.
---@return table|nil payload `{ version = 1, tabs = { ["<tab number>"] = {...} } }`
function M.capture()
  if not M.is_enabled() then
    return nil
  end

  local tabs = {}
  local any = false
  for _, tab_id in ipairs(vim.api.nvim_list_tabpages()) do
    -- Pending entries are included so quitting before ever opening Claude in a
    -- restored tab does not silently drop that tab's conversation.
    local record = records[tab_id] or pending[tab_id]
    -- Only ids the CLI has a transcript for: see `persistable_id`. A tab whose
    -- Claude never became a conversation is left out entirely, so it opens fresh
    -- next time instead of being armed with an id that cannot be resumed.
    local id = persistable_id(record)
    if id then
      tabs[tostring(vim.api.nvim_tabpage_get_number(tab_id))] = {
        session_id = id,
        cwd = record.cwd,
      }
      any = true
    end
  end
  if not any then
    return nil
  end
  return { version = PAYLOAD_VERSION, tabs = tabs }
end

---Apply a snapshot from `capture()` to the tabs that exist right now.
---
---Call it after the tabs are back (auto-session's `restore_extra_data`,
---resession's `on_post_load`, `SessionLoadPost`). Nothing is launched: each tab
---is armed, and Claude resumes when its terminal is next opened -- unless
---`opts.open` asks for the terminals immediately.
---@param data table|string|nil Payload (or its JSON encoding) from `capture()`.
---@param opts { open: boolean? }|nil
---@return boolean applied Whether any tab was armed.
function M.restore(data, opts)
  opts = opts or {}
  if not M.is_enabled() then
    logger.debug("session", "ignoring restore: session_persistence is off")
    return false
  end
  if type(data) == "string" then
    data = M.decode(data)
  end
  if type(data) ~= "table" or type(data.tabs) ~= "table" then
    return false
  end
  if data.version ~= PAYLOAD_VERSION then
    logger.warn("session", "ignoring session data written by a different version: " .. tostring(data.version))
    return false
  end

  local applied = 0
  for _, tab_id in ipairs(vim.api.nvim_list_tabpages()) do
    local entry = data.tabs[tostring(vim.api.nvim_tabpage_get_number(tab_id))]
    -- Never clobber a tab that already has a Claude of its own: loading a session
    -- on top of live work must not retarget it.
    if
      type(entry) == "table"
      and type(entry.session_id) == "string"
      and entry.session_id ~= ""
      and not records[tab_id]
    then
      pending[tab_id] = {
        session_id = entry.session_id,
        cwd = type(entry.cwd) == "string" and entry.cwd or nil,
      }
      applied = applied + 1
    end
  end

  if applied > 0 then
    logger.debug("session", "armed " .. applied .. " tab(s) to resume their Claude session")
    M.sync_global()
  end
  if opts.open then
    M.open_pending()
  end
  return applied > 0
end

---`capture()` as a JSON string, for hosts that carry a single scalar.
---@return string|nil
function M.encode()
  local payload = M.capture()
  if not payload then
    return nil
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  return ok and encoded or nil
end

---@param raw string|nil
---@return table|nil
function M.decode(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

---How many tabs hold a restored session id that no launch has claimed yet — i.e.
---how many conversations `open_pending()` would resume.
---@return number
function M.pending_count()
  local n = 0
  for tab_id in pairs(pending) do
    if vim.api.nvim_tabpage_is_valid(tab_id) then
      n = n + 1
    end
  end
  return n
end

---Open the Claude terminal in every tab holding an unclaimed restored id, which
---is what actually resumes those conversations. Focus and the current tab are
---left where they were.
---@return number opened
function M.open_pending()
  local targets = {}
  for tab_id in pairs(pending) do
    if vim.api.nvim_tabpage_is_valid(tab_id) then
      targets[#targets + 1] = tab_id
    end
  end
  if #targets == 0 then
    return 0
  end
  table.sort(targets)

  local terminal_ok, terminal = pcall(require, "claudecode.terminal")
  if not terminal_ok then
    return 0
  end

  local original_tab = vim.api.nvim_get_current_tabpage()
  local original_win = vim.api.nvim_get_current_win()
  local opened = 0
  for _, tab_id in ipairs(targets) do
    local ok = pcall(function()
      vim.api.nvim_set_current_tabpage(tab_id)
      terminal.ensure_visible()
    end)
    if ok then
      opened = opened + 1
    else
      logger.warn("session", "failed to open the Claude terminal in tab " .. tostring(tab_id))
    end
  end
  pcall(vim.api.nvim_set_current_tabpage, original_tab)
  pcall(vim.api.nvim_set_current_win, original_win)
  return opened
end

--------------------------------------------------------------------------------
-- "global" mode: ride whatever saves g: variables
--------------------------------------------------------------------------------

---Mirror the current snapshot into `g:CLAUDECODE_SESSION`. Kept in sync on every
---change so any session manager sees fresh data whenever it happens to save.
function M.sync_global()
  if mode ~= "global" then
    return
  end
  pcall(function()
    vim.g[GLOBAL_VAR] = M.encode()
  end)
end

---Apply the snapshot a restored `g:CLAUDECODE_SESSION` brought back.
---@param opts { open: boolean? }|nil
---@return boolean applied
function M.restore_from_global(opts)
  if mode ~= "global" then
    return false
  end
  local ok, raw = pcall(function()
    return vim.g[GLOBAL_VAR]
  end)
  if not ok or type(raw) ~= "string" or raw == "" then
    return false
  end
  return M.restore(raw, opts)
end

return M
