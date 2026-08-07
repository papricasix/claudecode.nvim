---@brief [[
--- The agents panes' derived colours.
---
--- Two effects in the view want the same thing: a span that is *briefly*
--- different and then settles back. A new Activity row arrives lifted, holds,
--- then fades to something quieter; a changed `+N`/`-N` lights up and drops
--- back. Both are "pick a group by how old this thing is", so both live here.
---
--- The count blocks' *resting* colours are here too, which is not a time effect
--- at all — they are the other end of the same ramp, derived from the same hue
--- by the same arithmetic, and splitting them across two modules would mean two
--- copies of it. `count_group` answers for both ends and everything between.
---
--- The ramp is a set of pre-computed groups, not a per-frame `nvim_set_hl`:
--- redefining a group is global and would repaint every other use of it, and the
--- panes redraw from three separate call sites. So `dim_group`/`count_group`
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

--- [base\0kind] = a count block's four colours, or `false` for "no hue anywhere,
--- leave the group alone". Cleared with `groups`, and for the same reason.
local palettes = {}

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
  -- A fresh row is drawn bold as well. This is what carries the lift for a
  -- colour that has no room left to be lifted: `Directory` in tokyonight-moon
  -- is `#82aaff`, already saturation 1.00 and lightness 0.75, so *every* colour
  -- move available to it makes it paler rather than more emphatic — which was
  -- the bug this setting answers. Weight is the one axis a saturated colour
  -- still has. Dropped when the ramp starts, so a row un-bolds and begins to
  -- fade in the same moment rather than in two.
  bold = true,
  -- How far a rested row is blended into the pane background. 1.0 would be
  -- invisible.
  dim = 0.55,
  -- A changed count is lit for this long *in total*, ramp included. Set to the
  -- ramp's own length plus a step, so it lights up and then spends essentially
  -- all of its time fading — no flat hold, unlike an Activity row, which holds
  -- before it starts to go.
  flash_ms = 3000,

  -- The count blocks. All six are fractions of *one* colour — the theme's own
  -- added/removed hue at the saturation it ships — so a `+N` and the block
  -- behind it are always the same colour at different strengths. See
  -- `M.count_group`.
  --
  -- The resting number: a quarter of that saturation, dimmed three fifths of
  -- the way towards its own block. Both moves are needed. At equal lightness a
  -- desaturated green and a full one read as the same green, so saturation
  -- alone left rest and peak indistinguishable — and the dim alone would only
  -- darken the same colour. What a count says at rest is "this file, this
  -- much"; the peak is for the moment it changes.
  count_sat = 0.25,
  count_dim = 0.60,
  -- The block: fainter still, and a notch away from the pane in lightness — up
  -- on a dark background, down on a light one — so it reads as a block rather
  -- than as the pane.
  count_bg_sat = 0.22,
  count_bg_lift = 0.10,
  -- The block a count wears for `flash_ms` after it moves. The number itself
  -- goes to the theme's colour undiluted, so this is the whole of the extra
  -- push: well short of full saturation, since a block is a small span of
  -- colour and only has to be seen changing.
  flash_level = 0.50,
  flash_lift = 0.05,
  -- What every one of those has to reach against whatever it sits on. WCAG's
  -- threshold for body text; a `+12` is small and often the only thing being
  -- read on its row. This is also the limit on how quiet `count_dim` can make a
  -- resting number: past a point the legibility walk gives back exactly what
  -- the dim took, and only saturation still separates rest from peak.
  count_contrast = 4.5,
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
  palettes = {}

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
          palettes = {}
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
---of `#ffc0b9` came back byte-identical and the lift was invisible. There is
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

---@param n integer 24-bit RGB.
---@return number h Degrees, 0-360.
---@return number s 0-1.
---@return number l 0-1.
local function to_hsl(n)
  local r, g, b = to_rgb(n)
  r, g, b = r / 255, g / 255, b / 255
  local hi = math.max(r, g, b)
  local lo = math.min(r, g, b)
  local l = (hi + lo) / 2
  local d = hi - lo
  if d <= 0 then
    -- A grey has no hue to report; saturation 0 makes the hue irrelevant anyway.
    return 0, 0, l
  end
  local s = d / (1 - math.abs(2 * l - 1))
  local h
  if hi == r then
    h = ((g - b) / d) % 6
  elseif hi == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h * 60, s, l
end

---@param h number Degrees.
---@param s number 0-1.
---@param l number 0-1.
---@return integer n 24-bit RGB.
local function from_hsl(h, s, l)
  if s < 0 then
    s = 0
  elseif s > 1 then
    s = 1
  end
  if l < 0 then
    l = 0
  elseif l > 1 then
    l = 1
  end
  local c = (1 - math.abs(2 * l - 1)) * s
  local hp = (h % 360) / 60
  local x = c * (1 - math.abs(hp % 2 - 1))
  local r, g, b
  if hp < 1 then
    r, g, b = c, x, 0
  elseif hp < 2 then
    r, g, b = x, c, 0
  elseif hp < 3 then
    r, g, b = 0, c, x
  elseif hp < 4 then
    r, g, b = 0, x, c
  elseif hp < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  local m = l - c / 2
  return to_int((r + m) * 255, (g + m) * 255, (b + m) * 255)
end

--- Below this saturation a colour has no hue worth intensifying.
local GREY_S = 0.02

--- Below this spread between a colour's channels there is no colour there to
--- speak of, whatever HSL says about it. Deliberately *not* `GREY_S`: saturation
--- is measured against the room a lightness leaves, so it runs away at both ends
--- — the near-white `#eef1f8` that Neovim's own `DiffAdd` uses reports s = 0.42
--- while carrying a spread of four percent, and a beige `#a89984` reports 0.14 of
--- spread while looking exactly like grey text. Both have to read as "no colour
--- was chosen here", or the count keeps the drab foreground this all exists to
--- replace. 0.18 sits above both and below the mutest colour a theme picks on
--- purpose (rose-pine's `#56949f`, 0.29).
local HUE_CHROMA = 0.18

---Whether a colour is a colour, rather than a grey, a white or a black.
---@param n integer 24-bit RGB.
---@return boolean
local function has_hue(n)
  local r, g, b = to_rgb(n)
  return (math.max(r, g, b) - math.min(r, g, b)) / 255 >= HUE_CHROMA
end

--- Where a lifted colour's lightness is allowed to sit. Short of the pale end,
--- because past it a colour stops being itself: that is the difference between
--- "more blue" and "whiter".
local LIT_L = 0.62

---WCAG relative luminance.
---@param n integer 24-bit RGB.
---@return number
local function luminance(n)
  local r, g, b = to_rgb(n)
  local function channel(v)
    v = v / 255
    if v <= 0.03928 then
      return v / 12.92
    end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
end

---How legible one colour is on another, as WCAG states it (1 = invisible).
---@param a integer 24-bit RGB.
---@param b integer 24-bit RGB.
---@return number
local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

---Make a colour *more itself*, for the lift a fresh Activity row gets.
---
---Deliberately not `brighten`, which was the first version of this and had the
---blind spot its own docstring describes, now hit for the second time: a colour
---whose largest channel is already near 255 cannot be scaled, so the leftover
---goes towards white. Measured on tokyonight-moon, `Directory` `#82aaff` (h 221,
---s 1.00, l 0.75) came back as `#a1bfff` — a *pale wash* of the theme's blue.
---Contrast against the pane was fine (8.31:1); it simply was not the colour the
---scheme picked, which is what "the fresh row uses off colours" means.
---
---So two moves, in this order of usefulness:
---
---*Saturation towards 1*, which is where a muted base has all its room —
---`Comment` at s 0.27 becomes properly coloured — and which does nothing at all
---to a base already at 1.00.
---
---*Lightness towards a vivid band, and only away from the pane background.* A
---colour darker than the band on a dark pane is lifted into it; one already
---inside it is left exactly where the scheme put it rather than being pushed
---past it into paleness. On a light pane the same rule runs downwards.
---
---A base with room in neither is returned unchanged — and that is the case
---`bold` exists for. See `dim_group`.
---
---Whatever the two moves come to, **the lift never costs legibility**: a fresh
---row is the one a reader is most likely to be reading. Saturation can spend
---contrast, because the eye's idea of bright is not the channels' — a muted
---`#636da6` saturated towards its blue lands on `#4b60d7`, obviously more
---coloured and measurably *harder* to read (3.11:1 down to 2.88:1 on this pane),
---since blue carries barely a fourteenth of luminance. So the result is walked
---back up in lightness, at the hue and saturation it has just gained, until it
---is at least as legible as the colour it came from.
---@param n integer 24-bit RGB.
---@param t number 0 = unchanged, 1 = as much itself as it goes.
---@param bg integer 24-bit RGB of the pane behind it.
---@return integer
local function intensify(n, t, bg)
  local h, s, l = to_hsl(n)
  local _, _, bg_l = to_hsl(bg)
  local up = bg_l < 0.5
  if s <= GREY_S then
    -- No hue to intensify, so brightness is the only axis left — away from the
    -- pane, which on a light one means downwards.
    if not up then
      return from_hsl(h, s, l - l * t * 0.5)
    end
    return brighten(n, t)
  end

  local target = up and math.max(l, LIT_L) or math.min(l, 1 - LIT_L)
  s = s + (1 - s) * t
  l = l + (target - l) * t
  local out = from_hsl(h, s, l)

  local want = contrast(n, bg)
  -- Bounded: 40 steps of 0.02 covers the whole lightness axis, so the loop ends
  -- either at the contrast it wanted or at the end of the road. Run once per
  -- (group, step) — every caller after that takes the cached group name.
  for _ = 1, 40 do
    if contrast(out, bg) >= want then
      break
    end
    local next_l = up and math.min(1, l + 0.02) or math.max(0, l - 0.02)
    if next_l == l then
      break
    end
    l = next_l
    out = from_hsl(h, s, l)
  end
  return out
end

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
---
---**The lift is intensity plus weight, not brightness.** `intensify` makes the
---colour more of what it is and refuses to pale it; for a base that is already
---saturated and light — `Directory` in a dark theme usually is — that leaves it
---untouched, and `bold` is then the whole of the lift. Both are needed, because
---which one carries a given row depends entirely on the colorscheme: a muted
---`Comment` gains most of its lift from the colour, a vivid `Directory` all of
---it from the weight. The weight is held for exactly as long as the colour is
---(`step <= 0`), so the row settles in one movement.
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

  local lit = boost > 0 and intensify(fg, boost, bg) or fg
  local rest = blend(fg, bg, o.dim)
  local colour = step <= 0 and lit or blend(lit, rest, step / o.steps)
  -- `nil` rather than `false`: the group is defined from scratch every time, so
  -- an absent key and an off one are the same thing, and this keeps the rested
  -- steps' specs identical to what they were before the lift existed.
  local bold = (step <= 0 and boost > 0 and o.bold ~= false) or nil
  return define(key, { fg = colour, bold = bold }) or base
end

--------------------------------------------------------------------------------
-- Count blocks
--------------------------------------------------------------------------------

--- Where a count takes its hue from when its own group does not give it one.
--- `Added`/`Removed` first: Neovim ships them, so every colorscheme has an
--- answer, and a theme that styles diffs at all styles these. The `diff*` syntax
--- groups and the gitsigns ones are the same idea spelled by an older convention.
local TEXT_SOURCES = {
  added = { "Added", "diffAdded", "GitSignsAdd" },
  removed = { "Removed", "diffRemoved", "GitSignsDelete" },
}

--- How far the legibility walk may push lightness. Short of both ends, because
--- pure white and pure black are the two colours with no hue left in them — the
--- point is a *green* number, and an unreachable target must not cost the green.
local TEXT_L_MAX, TEXT_L_MIN = 0.92, 0.10

---The theme's own colour for added / removed text, if it has one.
---@param kind "added"|"removed"
---@return integer|nil
local function theme_diff_colour(kind)
  for _, name in ipairs(TEXT_SOURCES[kind] or {}) do
    local fg = attrs(name)
    if fg and has_hue(fg) then
      return fg
    end
  end
  return nil
end

---Move a colour away from the one behind it, at its own hue, until it is legible.
---
---Lightness only: hue and saturation are the theme's answer to "what colour is an
---addition", and this is only answering "can it be read here".
---@param fg integer 24-bit RGB.
---@param bg integer 24-bit RGB.
---@param target number Contrast ratio to reach.
---@return integer
local function readable_on(fg, bg, target)
  local h, s, l = to_hsl(fg)
  local _, _, bg_l = to_hsl(bg)
  local up = bg_l < 0.5
  local out = fg
  for _ = 1, 60 do
    if contrast(out, bg) >= target then
      break
    end
    local next_l = up and math.min(TEXT_L_MAX, l + 0.02) or math.max(TEXT_L_MIN, l - 0.02)
    if next_l == l then
      break
    end
    l = next_l
    out = from_hsl(h, s, l)
  end
  return out
end

---The four colours a count block is drawn from, derived once per (group, kind).
---
---Everything is one hue at four strengths, so see `M.count_group` for why. The
---resting number is dimmed *towards its own block* as well as desaturated: at
---equal lightness a 0.6-saturation green and a full one are the same green to the
---eye, and the peak has to be visibly a step up from rest or the flash says
---nothing.
---@param base string
---@param kind "added"|"removed"
---@return table|nil `{ rest_fg, rest_bg, peak_fg, peak_bg }`
local function count_palette(base, kind)
  local key = base .. "\0" .. kind
  local cached = palettes[key]
  if cached ~= nil then
    return cached or nil
  end

  local pane = pane_bg()
  local fg, block = attrs(base)
  if not pane then
    palettes[key] = false
    return nil
  end

  local source = (fg and has_hue(fg)) and fg or theme_diff_colour(kind)
  if not source and block and has_hue(block) then
    source = block
  end
  if not source then
    palettes[key] = false
    return nil
  end

  local o = M.opts()
  -- The peak: the theme's colour, made legible on the pane it is read on. Every
  -- other colour here is a held-back version of this one.
  local peak = readable_on(source, pane, o.count_contrast)
  local hue, peak_s, peak_l = to_hsl(peak)
  local _, _, pane_l = to_hsl(pane)
  local dark = pane_l < 0.5
  local bg_l = dark and (pane_l + o.count_bg_lift) or (pane_l - o.count_bg_lift)

  local rest_bg = from_hsl(hue, peak_s * o.count_bg_sat, bg_l)
  local rest_fg = from_hsl(hue, peak_s * o.count_sat, peak_l + (bg_l - peak_l) * o.count_dim)
  local peak_bg = from_hsl(hue, peak_s * o.flash_level, dark and (bg_l + o.flash_lift) or (bg_l - o.flash_lift))

  local palette = {
    rest_bg = rest_bg,
    rest_fg = readable_on(rest_fg, rest_bg, o.count_contrast),
    peak_bg = peak_bg,
    peak_fg = readable_on(peak, peak_bg, o.count_contrast),
  }
  palettes[key] = palette
  return palette
end

---A count block's colours, for how long ago it changed.
---
---**One hue, three saturations.** The theme owns exactly one answer to "what
---colour is an addition", and everything here is that colour held back by
---different amounts: the number at rest is it at `count_sat`, the block behind it
---at `count_bg_sat`, and a count that has just moved goes to the colour itself on
---a block at `flash_level`. So the pair always reads as one colour rather than as
---a number pasted onto a highlight, and "it changed" is the same colour turned up
---rather than a different one.
---
---The hue is taken in the order of how much the theme meant it:
---
---*The group's own foreground*, whenever it is an actual colour. A theme that
---paints `DiffDelete` red on salmon (kanagawa) has said something and is not
---second-guessed — only made legible, below.
---
---*The theme's diff text colour* — `Added` / `Removed`, which Neovim ships, so
---this is not a guess about what a scheme defines. This is the default path: most
---schemes give `DiffAdd` a background and no foreground at all, which is why the
---number used to fall through to `Normal` and a `+12` came out white on green —
---"highlighted text", not twelve added lines.
---
---*The block's own hue*, when even that is neutral. Nothing is invented past
---that: with no hue anywhere, the base group is left exactly as it is.
---
---**The block follows the number, not the theme's own `DiffAdd` background.**
---That background is frequently a different hue from the diff text the same
---scheme ships — tokyonight-moon pairs a green `Added` with a *blue* `#2a4556`
---block — so deriving both from one hue is what keeps green on green. It also
---means the flash intensifies the count's colour rather than the block's, which
---the older version got backwards: on that theme a `+N` flashed blue.
---
---**Nothing here is allowed to be illegible.** Every colour is walked in
---lightness, at its own hue, until it clears `count_contrast` on whatever it sits
---on. That floor is why `count_dim` cannot make a resting number arbitrarily
---quiet: past a point the walk gives back exactly what the dim took, and the
---remaining separation from the peak is saturation. Measured across eight schemes
---— on tokyonight-moon the resting `+N` lands on `#a9c5ae` at 4.61:1 against a
---peak of `#b3f6c0`, a grey-green against the scheme's green.
---@param base string The group the block is drawn in.
---@param kind "added"|"removed"
---@param age_ms number|nil Milliseconds since the count changed; nil = never.
---@return string group
function M.count_group(base, kind, age_ms)
  if not truecolor() then
    return base
  end
  local palette = count_palette(base, kind)
  if not palette then
    return base
  end

  local o = M.opts()
  local step = o.steps
  if M.enabled() and type(age_ms) == "number" then
    -- `flash_ms` is the whole effect, ramp included, so a count is back to its
    -- resting colours three seconds after it moved rather than three seconds
    -- *plus* the ramp. The resting step begins one `step_ms` before the ramp's
    -- nominal end — step `steps` is the resting group, not a position in the ramp
    -- — so the hold is shortened by `steps - 1`, not `steps`.
    local ramp = math.max(0, o.steps - 1) * o.step_ms
    local hold = math.max(0, o.flash_ms - ramp)
    step = M.step_at(age_ms, hold, o.steps, o.step_ms)
  end

  if step >= o.steps then
    local key = string.format("Count_%s_%s", base, kind)
    local cached = groups[key]
    if cached ~= nil then
      return cached or base
    end
    return define(key, { fg = palette.rest_fg, bg = palette.rest_bg }) or base
  end

  local key = string.format("CountF_%s_%s_%d", base, kind, step)
  local cached = groups[key]
  if cached ~= nil then
    return cached or base
  end
  local at = step > 0 and (step / o.steps) or 0
  local fg = at > 0 and blend(palette.peak_fg, palette.rest_fg, at) or palette.peak_fg
  local bg = at > 0 and blend(palette.peak_bg, palette.rest_bg, at) or palette.peak_bg
  return define(key, { fg = fg, bg = bg }) or base
end

---Test/reload helper.
function M.reset()
  merged = nil
  groups = {}
  palettes = {}
end

return M
