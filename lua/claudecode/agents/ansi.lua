---@brief [[
--- Turning a command's raw output into something a buffer can show.
---
--- What the CLI stores in `toolUseResult.stdout` is exactly what the command wrote,
--- escape codes and all — `git`, `rg`, `eza`, `cargo` and every test runner colour
--- their output, and Claude runs them with a pty often enough that the codes are
--- there. Dropped into a buffer verbatim those read as `^[[32m` litter; stripped,
--- the output loses the one thing that made it scannable.
---
--- So the codes are parsed out and re-applied as extmarks. Colours come from the
--- user's own `g:terminal_color_0..15` where the code names one of the sixteen, so
--- a float matches the terminal two panes over; 256-colour and 24-bit codes are
--- resolved to their own hex. Anything that is not a colour or an attribute — a
--- cursor move, an erase, an OSC title — is removed rather than rendered: this is
--- a buffer, not a terminal, and there is nothing for those to act on.
---
--- Highlight groups are created once per distinct appearance and re-applied on
--- `ColorScheme`, since `g:terminal_color_*` is a scheme's to set.
---@brief ]]
---@module 'claudecode.agents.ansi'

local M = {}

--- The xterm defaults, used for a slot the colourscheme leaves unset.
local FALLBACK_16 = {
  "#000000",
  "#cc0000",
  "#4e9a06",
  "#c4a000",
  "#3465a4",
  "#75507b",
  "#06989a",
  "#d3d7cf",
  "#555753",
  "#ef2929",
  "#8ae234",
  "#fce94f",
  "#729fcf",
  "#ad7fa8",
  "#34e2e2",
  "#eeeeec",
}

--- The 6-level cube's channel values, and the greyscale ramp's step, both from the
--- xterm 256-colour table.
local CUBE = { 0, 95, 135, 175, 215, 255 }

--- Groups defined so far: [name] = the `nvim_set_hl` table it was defined with.
--- Kept so a `ColorScheme` can re-apply them; a buffer already on screen holds the
--- group name, not the colour.
local defined = {}

local group_autocmd = false

---@param index integer 0-15
---@return string hex
local function base16(index)
  local user = vim.g["terminal_color_" .. index]
  if type(user) == "string" and user:match("^#%x%x%x%x%x%x$") then
    return user
  end
  return FALLBACK_16[index + 1]
end

---Resolve a 256-colour index to hex.
---@param index integer
---@return string|nil
function M.xterm_hex(index)
  if type(index) ~= "number" or index < 0 or index > 255 then
    return nil
  end
  if index < 16 then
    return base16(index)
  end
  if index < 232 then
    local value = index - 16
    local r = CUBE[math.floor(value / 36) % 6 + 1]
    local g = CUBE[math.floor(value / 6) % 6 + 1]
    local b = CUBE[value % 6 + 1]
    return string.format("#%02x%02x%02x", r, g, b)
  end
  local level = 8 + (index - 232) * 10
  return string.format("#%02x%02x%02x", level, level, level)
end

---Make sure `ColorScheme` re-applies everything defined here.
local function watch_colorscheme()
  if group_autocmd then
    return
  end
  group_autocmd = true
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("ClaudeCodeAgentsAnsi", { clear = true }),
    callback = function()
      for name, spec in pairs(defined) do
        -- The slots may have moved with the scheme, so the colour is recomputed
        -- from the code the group was built for rather than re-applied as it was.
        local rebuilt = vim.deepcopy(spec.attrs)
        if spec.fg_index then
          rebuilt.fg = base16(spec.fg_index)
        end
        if spec.bg_index then
          rebuilt.bg = base16(spec.bg_index)
        end
        pcall(vim.api.nvim_set_hl, 0, name, rebuilt)
      end
    end,
  })
end

---The highlight group for one appearance, defining it the first time it is asked for.
---@param state table Current SGR state.
---@return string|nil group nil when the state is the terminal's default.
local function group_for(state)
  local parts = {}
  local attrs = {}
  if state.fg then
    attrs.fg = state.fg
    parts[#parts + 1] = "f" .. state.fg:gsub("#", "")
  end
  if state.bg then
    attrs.bg = state.bg
    parts[#parts + 1] = "b" .. state.bg:gsub("#", "")
  end
  for _, attr in ipairs({ "bold", "italic", "underline", "strikethrough" }) do
    if state[attr] then
      attrs[attr] = true
      parts[#parts + 1] = attr:sub(1, 2)
    end
  end
  if #parts == 0 then
    return nil
  end

  local name = "ClaudeCodeAnsi_" .. table.concat(parts, "_")
  if not defined[name] then
    defined[name] = { attrs = attrs, fg_index = state.fg_index, bg_index = state.bg_index }
    pcall(vim.api.nvim_set_hl, 0, name, attrs)
    watch_colorscheme()
  end
  return name
end

---Apply one SGR parameter run to `state`.
---@param state table
---@param params integer[]
local function apply_sgr(state, params)
  local index = 1
  while index <= #params do
    local code = params[index]
    if code == 0 then
      for key in pairs(state) do
        state[key] = nil
      end
    elseif code == 1 then
      state.bold = true
    elseif code == 3 then
      state.italic = true
    elseif code == 4 then
      state.underline = true
    elseif code == 9 then
      state.strikethrough = true
    elseif code == 22 then
      state.bold = nil
    elseif code == 23 then
      state.italic = nil
    elseif code == 24 then
      state.underline = nil
    elseif code == 29 then
      state.strikethrough = nil
    elseif code >= 30 and code <= 37 then
      state.fg_index = code - 30
      state.fg = base16(state.fg_index)
    elseif code >= 90 and code <= 97 then
      state.fg_index = code - 90 + 8
      state.fg = base16(state.fg_index)
    elseif code >= 40 and code <= 47 then
      state.bg_index = code - 40
      state.bg = base16(state.bg_index)
    elseif code >= 100 and code <= 107 then
      state.bg_index = code - 100 + 8
      state.bg = base16(state.bg_index)
    elseif code == 39 then
      state.fg, state.fg_index = nil, nil
    elseif code == 49 then
      state.bg, state.bg_index = nil, nil
    elseif code == 38 or code == 48 then
      -- Extended colour: `38;5;N` (256) or `38;2;R;G;B` (24-bit). Both consume
      -- the parameters that follow, so the cursor moves past them.
      local mode = params[index + 1]
      local hex, consumed
      if mode == 5 then
        hex, consumed = M.xterm_hex(params[index + 2]), 2
      elseif mode == 2 then
        local r, g, b = params[index + 2], params[index + 3], params[index + 4]
        if r and g and b then
          hex = string.format("#%02x%02x%02x", r % 256, g % 256, b % 256)
        end
        consumed = 4
      end
      index = index + (consumed or 1)
      if code == 38 then
        state.fg, state.fg_index = hex, nil
      else
        state.bg, state.bg_index = hex, nil
      end
    end
    index = index + 1
  end
end

---@param text string A `;`-separated SGR parameter list, possibly empty.
---@return integer[]
local function parse_params(text)
  local params = {}
  if text == "" then
    -- `ESC[m` is `ESC[0m`: a reset.
    return { 0 }
  end
  -- Split by hand rather than with `gmatch("[^;]*")`, which yields an extra empty
  -- match at the end of the string — read as a trailing `0`, that reset the state
  -- immediately after every colour it had just set, and nothing was ever
  -- highlighted. An empty field *between* separators really is a `0`, though,
  -- which is why the pieces are not simply filtered out.
  local start = 1
  while true do
    local sep = text:find(";", start, true)
    if not sep then
      params[#params + 1] = tonumber(text:sub(start)) or 0
      break
    end
    params[#params + 1] = tonumber(text:sub(start, sep - 1)) or 0
    start = sep + 1
  end
  return params
end

---Strip the escape codes from `lines`, returning the text and how to colour it.
---
---SGR state carries across lines, the way it does in a terminal: a command that
---opens a colour and writes several lines before closing it is common.
---@param lines string[]
---@return string[] clean
---@return { row: integer, col: integer, end_col: integer, hl: string }[] marks 0-based rows and byte columns.
function M.parse(lines)
  local clean, marks = {}, {}
  local state = {}

  for row, raw in ipairs(lines) do
    local out = {}
    local length = 0
    local run_start, run_group = 0, group_for(state)
    local index = 1

    local function close_run()
      if run_group and length > run_start then
        marks[#marks + 1] = { row = row - 1, col = run_start, end_col = length, hl = run_group }
      end
    end

    while index <= #raw do
      local esc = raw:find("\27", index, true)
      if not esc then
        local chunk = raw:sub(index)
        out[#out + 1] = chunk
        length = length + #chunk
        break
      end
      if esc > index then
        local chunk = raw:sub(index, esc - 1)
        out[#out + 1] = chunk
        length = length + #chunk
      end

      local params, final = raw:match("^\27%[([%d;?]*)(%a)", esc)
      if params and final == "m" then
        close_run()
        apply_sgr(state, parse_params((params:gsub("%?", ""))))
        run_start, run_group = length, group_for(state)
        index = esc + 2 + #params + 1
      elseif params then
        -- A cursor move, an erase, a mode set: nothing for a buffer to do.
        index = esc + 2 + #params + 1
      else
        -- OSC (`\27]…\7` or `\27]…\27\\`) and anything else: drop to the end of
        -- the sequence rather than leaving a stray escape in the text.
        local osc_end = raw:find("\7", esc, true)
        local st_end = raw:find("\27\\", esc, true)
        if osc_end and (not st_end or osc_end < st_end) then
          index = osc_end + 1
        elseif st_end then
          index = st_end + 2
        else
          index = esc + 2
        end
      end
    end

    close_run()
    clean[row] = table.concat(out)
  end

  return clean, marks
end

---Whether any line carries an escape code at all.
---@param lines string[]
---@return boolean
function M.has_escapes(lines)
  for _, line in ipairs(lines) do
    if line:find("\27", 1, true) then
      return true
    end
  end
  return false
end

---Test/reload helper: forget every group this module defined.
function M.reset()
  defined = {}
end

return M
