---@brief [[
--- Time-varying highlight groups for the agents panes.
---
--- Two effects in the view want the same thing: a span that is *briefly*
--- different and then settles back. A new Activity row arrives at full
--- brightness, holds, then fades to something quieter; a changed `+N`/`-N`
--- lights up and drops back. Both are "pick a group by how old this thing is",
--- so both live here.
---
--- The ramp is a set of pre-computed groups, not a per-frame `nvim_set_hl`:
--- redefining a group is global and would repaint every other use of it, and the
--- panes redraw from three separate call sites. So `dim_group`/`flash_group`
--- return the name of a group for the step the caller's age lands on, and the
--- groups themselves are defined once and cached until the colorscheme changes.
---
--- **No timer of its own.** The view already repaints on `status.on_frame`, one
--- tick per `spinner_ms`, for as long as its tab is visible — the ramp is sampled
--- by that. With `auto_redraw = false` or `spinner_ms = 0` there are no ticks, so
--- a span simply arrives at its resting group on the next redraw instead of
--- travelling there. That is the correct degradation: those settings mean "do not
--- repaint on your own", and an animation is a repaint.
---@brief ]]
---@module 'claudecode.agents.fade'

local M = {}

local PREFIX = "ClaudeCodeAgentsFx"

--- Agents config subtable.
---@type table|nil
local config = nil

--- [cache key] = group name, or `false` for "no group could be built, use the
--- base". Cleared on `ColorScheme`, since every colour in it was derived from
--- one.
local groups = {}

--- Set once; the watcher outlives individual `setup` calls.
local watcher = nil

local DEFAULTS = {
  enabled = true,
  -- An Activity row stays lifted this long after it appears, then fades over
  -- `(steps - 1) * step_ms` — 3s and ~3s with these defaults.
  hold_ms = 3000,
  -- Steps in the ramp, and how long each is held. `step_ms` matches the default
  -- `spinner_ms`, which is the clock that samples this: a shorter step would
  -- simply not be drawn. The step count is what sets the ramp's length, and it
  -- has to be high enough that a 3s fade is a fade rather than a slideshow.
  steps = 25,
  step_ms = 120,
  -- How far a *fresh* row is lifted above its own colour. Without this the
  -- effect only ever goes downwards, so "fresh" means no more than "not yet
  -- dimmed" — and two of the three columns draw in `Comment`, which is a muted
  -- grey to begin with, so a new row did not announce itself at all. 0 restores
  -- that older behaviour exactly (see `dim_group`).
  boost = 0.5,
  -- How far a rested row is blended into the pane background. 1.0 would be
  -- invisible.
  dim = 0.55,
  -- A changed count is lit for this long *in total*, ramp included. Set to the
  -- ramp's own length plus a step, so it lights up and then spends essentially
  -- all of its time fading — no flat hold, unlike an Activity row, which holds
  -- before it starts to go.
  flash_ms = 3000,
  -- How far the lit foreground is brightened away from the block's background.
  flash_level = 0.8,
}

--- The merged config, built once per `setup`. `render` asks for it several times
--- per drawn span, and the panes redraw on every frame the spinner clock ticks,
--- so building a fresh table per call was garbage proportional to visible rows.
---@type table|nil
local merged = nil

---@return table
function M.opts()
  if merged then
    return merged
  end
  local user = (config and type(config.fade) == "table") and config.fade or {}
  local out = {}
  for key, value in pairs(DEFAULTS) do
    local given = user[key]
    -- Spelled out rather than `given ~= nil and given or value`: that idiom
    -- collapses a given `false` back to the default, which is exactly the value
    -- `enabled = false` needs to carry.
    if given ~= nil then
      out[key] = given
    else
      out[key] = value
    end
  end
  -- `fade = false` is the whole feature off, which is the same answer as
  -- `fade = { enabled = false }`. Folded in here so `enabled()` has one rule to
  -- read rather than two.
  if config and config.fade == false then
    out.enabled = false
  end
  merged = out
  return out
end

---@return boolean
function M.enabled()
  return M.opts().enabled ~= false
end

---@param full_config table|nil The whole plugin config.
function M.setup(full_config)
  config = (type(full_config) == "table" and type(full_config.agents) == "table") and full_config.agents or nil
  merged = nil
  groups = {}

  if not watcher then
    local ok, id = pcall(vim.api.nvim_create_augroup, "ClaudeCodeAgentsFade", { clear = true })
    if ok then
      watcher = id
      pcall(vim.api.nvim_create_autocmd, "ColorScheme", {
        group = id,
        callback = function()
          -- Every colour here was read out of the old scheme. Keeping them would
          -- fade a row towards a background that is no longer there.
          groups = {}
        end,
        desc = "Rebuild the Claude agents fade colours for the new colorscheme",
      })
    end
  end
end

--------------------------------------------------------------------------------
-- Colour arithmetic
--------------------------------------------------------------------------------

---@param value number
---@return integer
local function clamp(value)
  if value < 0 then
    return 0
  end
  if value > 255 then
    return 255
  end
  return math.floor(value + 0.5)
end

---@param n integer 24-bit RGB.
---@return integer r
---@return integer g
---@return integer b
local function to_rgb(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

---@return integer
local function to_int(r, g, b)
  return clamp(r) * 65536 + clamp(g) * 256 + clamp(b)
end

---Linear blend: `t = 0` is `a`, `t = 1` is `b`.
---@param a integer 24-bit RGB.
---@param b integer 24-bit RGB.
---@param t number
---@return integer
local function blend(a, b, t)
  local ar, ag, ab = to_rgb(a)
  local br, bg, bb = to_rgb(b)
  return to_int(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end

---Raise a colour's brightness while keeping its hue.
---
---Blending towards white would work, but it desaturates: a dark green block
---brightened that way goes pale grey rather than bright green. Scaling every
---channel by what it takes to lift the *largest* one keeps the ratios between
---them, so the colour gets brighter without changing which colour it is.
---
---That has one blind spot, and a real colorscheme walked into it: a colour whose
---largest channel is **already 255** cannot be scaled at all, so a `DiffDelete`
---of `#ffc0b9` came back byte-identical and the flash was invisible. There is
---only one direction left for such a colour, which is towards white — so the
---part of `t` that scaling could not spend is spent that way instead. Weighted
---by the cube of how bright the colour already is, so a dark block keeps its
---saturation and only a near-saturated one pales.
---@param n integer 24-bit RGB.
---@param t number 0 = unchanged, 1 = as bright as this hue goes.
---@return integer
local function brighten(n, t)
  local r, g, b = to_rgb(n)
  local peak = math.max(r, g, b)
  if peak == 0 then
    -- Pure black has no hue to preserve; go up the greys.
    local v = 255 * t
    return to_int(v, v, v)
  end
  local scale = (peak + (255 - peak) * t) / peak
  local out = to_int(r * scale, g * scale, b * scale)
  local headroomless = (peak / 255) ^ 3
  if headroomless > 0.01 then
    out = blend(out, 0xffffff, t * headroomless * 0.5)
  end
  return out
end

--- How far the block behind a flashing count lifts, as a fraction of the lift
--- its text gets. The text goes bright enough to read at a glance; the block
--- moves enough to be seen changing without closing the gap between the two,
--- which is the whole reason the number stays legible while it flashes.
local BLOCK_LIFT = 0.45

---A highlight group's resolved gui colours.
---@param name string
---@return integer|nil fg
---@return integer|nil bg
local function attrs(name)
  if not name or name == "" then
    return nil, nil
  end
  -- `link = false` resolves the chain, which matters: every group the panes draw
  -- with is a link to a colorscheme group by default.
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl.fg, hl.bg
  end
  -- Neovim 0.8 has no `nvim_get_hl`.
  local ok_old, old = pcall(vim.api.nvim_get_hl_by_name, name, true)
  if ok_old and type(old) == "table" then
    return old.foreground, old.background
  end
  return nil, nil
end

---The colour the panes sit on. Sidebars keep the editor's `Normal`.
---@return integer|nil
local function pane_bg()
  local _, bg = attrs("Normal")
  return bg
end

---Whether derived colours mean anything at all here.
---@return boolean
local function truecolor()
  return vim.o.termguicolors == true
end

--------------------------------------------------------------------------------
-- Steps
--------------------------------------------------------------------------------

---Which step of a ramp an age lands on.
---@param age_ms number|nil Milliseconds since the thing appeared or changed.
---@param hold_ms number Full-strength period before the ramp starts.
---@param steps integer
---@param step_ms number
---@return integer step 0 = still at full strength, `steps` = fully rested.
function M.step_at(age_ms, hold_ms, steps, step_ms)
  if type(age_ms) ~= "number" or age_ms < 0 then
    return steps
  end
  if steps <= 0 or step_ms <= 0 then
    return age_ms < hold_ms and 0 or steps
  end
  if age_ms < hold_ms then
    return 0
  end
  local step = math.floor((age_ms - hold_ms) / step_ms) + 1
  if step > steps then
    return steps
  end
  return step
end

---Whether an age is still moving, so the caller knows a repaint is owed.
---@param age_ms number|nil
---@return boolean
function M.animating(age_ms)
  if not M.enabled() or type(age_ms) ~= "number" then
    return false
  end
  local o = M.opts()
  local span = math.max(o.hold_ms, o.flash_ms) + o.steps * o.step_ms
  return age_ms >= 0 and age_ms < span
end

---Define a derived group. Callers look `groups[key]` up first — a group's name
---depends only on `(base, step)`, so once the ramp has been walked once the
---steady state is a table lookup and none of the colour arithmetic runs.
---@param key string
---@param spec table `nvim_set_hl` attributes.
---@return string|nil group
local function define(key, spec)
  local name = PREFIX .. key
  local ok = pcall(vim.api.nvim_set_hl, 0, name, spec)
  groups[key] = ok and name or false
  return ok and name or nil
end

--------------------------------------------------------------------------------
-- The two effects
--------------------------------------------------------------------------------

---An Activity row's group: lifted above its own colour while fresh, then walked
---all the way down into the pane background.
---
---One continuous ramp from `lit` to `rest`, rather than a hold at the base
---colour with a fade bolted after it. That shape falls out of the arithmetic:
---interpolating towards `rest` — which is itself an interpolation of `fg`
---towards the background — passes through the base colour on the way, so a row
---goes bright → normal → quiet without any of those being a special case. And
---with `boost = 0` the two blends collapse to exactly the previous formula
---(`blend(fg, bg, dim * step / steps)`), so turning the lift off restores the
---old behaviour rather than approximating it.
---@param base string The group the row would be drawn in normally.
---@param age_ms number|nil Milliseconds since the row appeared.
---@return string group
function M.dim_group(base, age_ms)
  if not M.enabled() then
    return base
  end
  local o = M.opts()
  local step = M.step_at(age_ms, o.hold_ms, o.steps, o.step_ms)
  local boost = o.boost or 0
  -- Nothing to draw differently: no lift asked for, and not yet fading.
  if step <= 0 and boost <= 0 then
    return base
  end
  if not truecolor() then
    return base
  end

  local key = string.format("Dim_%s_%d", base, step)
  local cached = groups[key]
  if cached ~= nil then
    return cached or base
  end

  local fg = attrs(base)
  local bg = pane_bg()
  if not fg or not bg then
    return base
  end

  local lit = boost > 0 and brighten(fg, boost) or fg
  local rest = blend(fg, bg, o.dim)
  local colour = step <= 0 and lit or blend(lit, rest, step / o.steps)
  return define(key, { fg = colour }) or base
end

---A count's group: lit right after it changed, back to the base once it rests.
---
---**Both halves of a block light up, and both walk back.** The text goes to a far
---brighter version of the block's own colour and the block itself lifts part of
---the way there, so the pair reads as the same colour turned up — then the text
---settles onto the group's own foreground and the block onto its own background.
---
---The two lifts are deliberately unequal. Giving them the same one was the first
---version and it painted `#04de5d` on `#005523`: green on green, measured, so a
---count that had just changed was **less** legible than one at rest — the exact
---opposite of announcing itself, and it read as the colour draining out of the
---number. It is the mirror of the older bug in this same function, where a
---foreground was used as a background and the number vanished into it. The gap
---between the two is what keeps the number readable through the whole flash.
---
---A group with no background is not a block but text, so there the text is what
---brightens, and no background is invented for it.
---@param base string
---@param age_ms number|nil Milliseconds since the count changed; nil = never.
---@return string group
function M.flash_group(base, age_ms)
  if not M.enabled() or type(age_ms) ~= "number" then
    return base
  end
  local o = M.opts()
  -- `flash_ms` is the whole effect, ramp included, so a count is back to normal
  -- one second after it moved rather than a second *plus* the ramp. The resting
  -- step begins one `step_ms` before the ramp's nominal end — step `steps` is
  -- the base group, not a position in the ramp — so the hold is shortened by
  -- `steps - 1`, not `steps`.
  local ramp = math.max(0, o.steps - 1) * o.step_ms
  local hold = math.max(0, o.flash_ms - ramp)
  local step = M.step_at(age_ms, hold, o.steps, o.step_ms)
  if step >= o.steps then
    return base
  end
  if not truecolor() then
    return base
  end

  local key = string.format("Flash_%s_%d", base, step)
  local cached = groups[key]
  if cached ~= nil then
    return cached or base
  end

  local base_fg, base_bg = attrs(base)

  if base_bg then
    local at = step > 0 and (step / o.steps) or 0
    local fg_lit = brighten(base_bg, o.flash_level)
    local bg_lit = brighten(base_bg, o.flash_level * BLOCK_LIFT)
    local bg = at > 0 and blend(bg_lit, base_bg, at) or bg_lit
    -- Where the text lands: the group's own foreground, or the editor's when it
    -- has none — which is what a background-only group shows at rest anyway.
    local rest = base_fg or select(1, attrs("Normal"))
    if not rest then
      return define(key, { bg = bg }) or base
    end
    local fg = at > 0 and blend(fg_lit, rest, at) or fg_lit
    return define(key, { fg = fg, bg = bg }) or base
  end

  if not base_fg then
    return base
  end
  local lit = brighten(base_fg, o.flash_level)
  local fg = step > 0 and blend(lit, base_fg, step / o.steps) or lit
  -- No background is added: the scheme never asked for a block here, and one
  -- appearing and disappearing per change would be worse than the flash is good.
  return define(key, { fg = fg }) or base
end

---Test/reload helper.
function M.reset()
  merged = nil
  groups = {}
end

return M
