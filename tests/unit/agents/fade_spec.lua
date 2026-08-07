-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.fade", function()
  local fade

  --- 24-bit RGB, the way `nvim_get_hl` reports and `nvim_set_hl` takes it.
  local GREEN_BLOCK = 0x005523 -- a DiffAdd-style background with no foreground
  local PINK_TEXT = 0xffc0b9 -- a DiffDelete-style foreground with no background
  local CYAN = 0x8cf8f7
  local BG = 0x14161b

  local function hl(name)
    return (vim._highlights or {})[name] or {}
  end

  local function define(groups)
    for name, spec in pairs(groups) do
      vim.api.nvim_set_hl(0, name, spec)
    end
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    vim._highlights = {}
    vim.o.termguicolors = true
    package.loaded["claudecode.agents.fade"] = nil
    fade = require("claudecode.agents.fade")
    fade.setup({ agents = { enabled = true } })
    define({
      Normal = { fg = 0xe0e2ea, bg = BG },
      DiffAdd = { bg = GREEN_BLOCK },
      DiffDelete = { fg = PINK_TEXT },
      Directory = { fg = CYAN },
      -- A link, so the resolution the panes actually rely on is exercised.
      AgentsPath = { link = "Directory" },
    })
  end)

  after_each(function()
    vim.o.termguicolors = nil
  end)

  describe("step_at", function()
    it("holds at full strength, then walks one step per interval", function()
      expect(fade.step_at(0, 3000, 4, 120)).to_be(0)
      expect(fade.step_at(2999, 3000, 4, 120)).to_be(0)
      expect(fade.step_at(3000, 3000, 4, 120)).to_be(1)
      expect(fade.step_at(3119, 3000, 4, 120)).to_be(1)
      expect(fade.step_at(3120, 3000, 4, 120)).to_be(2)
      expect(fade.step_at(3360, 3000, 4, 120)).to_be(4)
    end)

    it("never walks past the resting step", function()
      expect(fade.step_at(99999, 3000, 4, 120)).to_be(4)
      -- A backfilled row is stamped with an infinite age rather than a number,
      -- so it can never read as fresh however the clock behaves.
      expect(fade.step_at(math.huge, 3000, 4, 120)).to_be(4)
    end)

    it("treats an unknown age as already rested", function()
      expect(fade.step_at(nil, 3000, 4, 120)).to_be(4)
    end)
  end)

  describe("the applied config", function()
    it("does not shadow these defaults from config.lua", function()
      -- `fade.opts()` merges the applied config over its own table, so a second
      -- copy of these values in `config.defaults` silently wins and the module's
      -- own become dead code. That happened: two rounds of retuning the timings
      -- changed nothing visible, because the copies kept overriding them. One
      -- source of truth, asserted through the path the plugin actually takes.
      package.loaded["claudecode.config"] = nil
      local applied = require("claudecode.config").apply({})
      require("claudecode.agents.fade").setup(applied)
      local o = require("claudecode.agents.fade").opts()
      expect(o.hold_ms).to_be(3000)
      expect(o.steps).to_be(25)
      expect(o.flash_ms).to_be(3000)
      expect(o.boost).to_be(0.5)
    end)
  end)

  describe("dim_group", function()
    ---How much colour a value carries: the spread between its channels. A colour
    ---going *paler* loses chroma however its channels climb, which is the
    ---difference between "more blue" and "whiter".
    local function chroma(n)
      local r, g, b = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
      return math.max(r, g, b) - math.min(r, g, b)
    end

    ---Largest per-channel gap. Packed RGB subtracts across channel boundaries,
    ---so `math.abs(a - b)` says nothing about how close two colours look.
    local function apart(a, b)
      local function ch(n)
        return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
      end
      local ar, ag, ab = ch(a)
      local br, bg, bb = ch(b)
      return math.max(math.abs(ar - br), math.abs(ag - bg), math.abs(ab - bb))
    end

    ---WCAG contrast, which is what "legible on this pane" actually means. Packed
    ---RGB compares as an integer and channel sums weight blue like green; neither
    ---says whether a colour got easier to read.
    local function contrast(a, b)
      local function lum(n)
        local function channel(v)
          v = v / 255
          return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
        end
        return 0.2126 * channel(math.floor(n / 65536) % 256)
          + 0.7152 * channel(math.floor(n / 256) % 256)
          + 0.0722 * channel(n % 256)
      end
      local la, lb = lum(a), lum(b)
      if la < lb then
        la, lb = lb, la
      end
      return (la + 0.05) / (lb + 0.05)
    end

    it("marks a fresh row without paling it or making it harder to read", function()
      -- Without the lift, "fresh" means only "not yet dimmed" — and two of the
      -- three columns draw in `Comment`, a muted grey, so a new row announced
      -- itself hardly at all.
      --
      -- The lift used to scale the channels towards their peak, which for a
      -- colour already near it only added white: measured on tokyonight-moon,
      -- `Directory` `#82aaff` came back `#a1bfff`, a pale wash of the scheme's
      -- own blue rather than the blue. So it is intensity and weight now, and
      -- neither is allowed to cost legibility.
      local lit = fade.dim_group("AgentsPath", 0)
      expect(lit ~= "AgentsPath").to_be_true()
      local spec = hl(lit)
      expect(spec.bold).to_be_true()
      expect(chroma(spec.fg)).to_be_at_least(chroma(CYAN))
      expect(contrast(spec.fg, BG)).to_be_at_least(contrast(CYAN, BG))

      -- Still lifted at the end of the hold, and dropping — weight included — once
      -- past it, so the row settles in one movement rather than two.
      expect(fade.dim_group("AgentsPath", 2999)).to_be(lit)
      local fading = fade.dim_group("AgentsPath", 3000)
      expect(fading ~= lit).to_be_true()
      expect(hl(fading).bold).to_be_nil()
    end)

    it("lifts a muted colour by making it more coloured, not by washing it out", function()
      -- Where the lift still has room to work: a `Comment`-ish grey-blue has most
      -- of its saturation left, and that is what a fresh row should spend. It may
      -- not spend legibility doing it — a blue carries a fourteenth of green's
      -- luminance, so saturating alone drops the contrast (measured: 3.11 to
      -- 2.88), which the lightness walk-back exists to give back.
      local MUTED = 0x636da6
      define({ AgentsMuted = { fg = MUTED } })
      local spec = hl(fade.dim_group("AgentsMuted", 0))
      expect(chroma(spec.fg) > chroma(MUTED)).to_be_true()
      expect(contrast(spec.fg, BG)).to_be_at_least(contrast(MUTED, BG))
    end)

    it("starts at the group's own colour and walks down to the quiet one", function()
      -- One continuous ramp rather than a hold at the base with a fade bolted
      -- after it. The lit end is the base colour itself here — a saturated cyan
      -- has nowhere left to be lifted to, which is what the weight covers — so
      -- the ramp begins where the scheme put it and leaves from there.
      local o = fade.opts()
      expect(apart(hl(fade.dim_group("AgentsPath", 0)).fg, CYAN) <= 4).to_be_true()
      local rested_fg = hl(fade.dim_group("AgentsPath", 60000)).fg
      expect(rested_fg < CYAN).to_be_true()
      expect(rested_fg > BG).to_be_true()
      -- And every step in between is somewhere on that line.
      for step = 1, o.steps do
        local fg = hl(fade.dim_group("AgentsPath", o.hold_ms + (step - 1) * o.step_ms)).fg
        expect(fg <= CYAN).to_be_true()
        expect(fg >= rested_fg).to_be_true()
      end
    end)

    it("can have the weight turned off on its own", function()
      fade.setup({ agents = { fade = { bold = false } } })
      local lit = fade.dim_group("AgentsPath", 0)
      expect(hl(lit).bold).to_be_nil()
      -- The colour half of the lift is untouched by it.
      expect(lit ~= "AgentsPath").to_be_true()
    end)

    it("with the lift off, behaves exactly as it did before", function()
      fade.setup({ agents = { fade = { boost = 0 } } })
      expect(fade.dim_group("AgentsPath", 0)).to_be("AgentsPath")
      expect(fade.dim_group("AgentsPath", 2999)).to_be("AgentsPath")
    end)

    it("blends an aged row towards the pane background", function()
      local rested = fade.dim_group("AgentsPath", 60000)
      expect(rested ~= "AgentsPath").to_be_true()
      local fg = hl(rested).fg
      expect(type(fg)).to_be("number")
      -- Strictly between the row's own colour and the background it sits on.
      expect(fg < CYAN).to_be_true()
      expect(fg > BG).to_be_true()
    end)

    it("darkens monotonically along the ramp", function()
      local previous = hl(fade.dim_group("AgentsPath", 0)).fg -- the lifted colour
      local hold = fade.opts().hold_ms
      for step = 1, 4 do
        local group = fade.dim_group("AgentsPath", hold + (step - 1) * 120)
        local fg = hl(group).fg
        expect(fg < previous).to_be_true()
        previous = fg
      end
    end)

    it("reuses one group per step rather than redefining a shared one", function()
      -- Redefining is global: it would repaint every other use of the group.
      local first = fade.dim_group("AgentsPath", 60000)
      local again = fade.dim_group("AgentsPath", 60000)
      expect(first).to_be(again)
      expect(fade.dim_group("Directory", 60000) ~= first).to_be_true()
    end)

    it("stands down without truecolour, where a derived colour means nothing", function()
      vim.o.termguicolors = false
      expect(fade.dim_group("AgentsPath", 60000)).to_be("AgentsPath")
    end)

    it("stands down when disabled", function()
      fade.setup({ agents = { fade = { enabled = false } } })
      expect(fade.dim_group("AgentsPath", 60000)).to_be("AgentsPath")
    end)
  end)

  describe("count_group", function()
    ---Which channel a colour is mostly made of, so "is green" is assertable.
    local function dominant(n)
      local r, g, b = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
      if r >= g and r >= b then
        return "r"
      end
      return g >= b and "g" or "b"
    end

    local function contrast(a, b)
      local function lum(n)
        local function channel(v)
          v = v / 255
          return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
        end
        return 0.2126 * channel(math.floor(n / 65536) % 256)
          + 0.7152 * channel(math.floor(n / 256) % 256)
          + 0.0722 * channel(n % 256)
      end
      local la, lb = lum(a), lum(b)
      if la < lb then
        la, lb = lb, la
      end
      return (la + 0.05) / (lb + 0.05)
    end

    it("draws the number in the theme's own added colour, not in Normal's white", function()
      -- The shape most colorschemes ship: a block with no foreground, so the
      -- number fell through to `Normal` and a `+12` came out white on green —
      -- "highlighted text", not "twelve lines were added". A diff never looks
      -- like that.
      define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { bg = GREEN_BLOCK } })
      local group = fade.count_group("AgentsAdd", "added")
      expect(group ~= "AgentsAdd").to_be_true()
      local spec = hl(group)
      expect(spec.bg).to_be(GREEN_BLOCK)
      expect(dominant(spec.fg)).to_be("g")
      expect(contrast(spec.fg, GREEN_BLOCK)).to_be_at_least(4.5)
    end)

    it("replaces a foreground that is really a white or a grey", function()
      -- Neovim's own `DiffAdd` is `#eef1f8` on green. HSL calls that saturation
      -- 0.42 — saturation runs away at the light end — so the test is the spread
      -- between the channels, which is four percent. No colour was chosen there.
      define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { fg = 0xeef1f8, bg = GREEN_BLOCK } })
      local spec = hl(fade.count_group("AgentsAdd", "added"))
      expect(spec.fg ~= 0xeef1f8).to_be_true()
      expect(dominant(spec.fg)).to_be("g")
    end)

    it("keeps a foreground the theme actually chose, and makes it legible", function()
      -- kanagawa paints `DiffDelete` red on salmon: it means that, and it is not
      -- second-guessed — but it measures 1.99:1, which no number can be read at.
      local SALMON, RED = 0xd9a594, 0xd7474b
      define({ AgentsDel = { fg = RED, bg = SALMON } })
      local spec = hl(fade.count_group("AgentsDel", "removed"))
      expect(dominant(spec.fg)).to_be("r")
      expect(contrast(spec.fg, SALMON)).to_be_at_least(4.5)
      -- Darker, because the block is the light half of the pair.
      expect(spec.fg < RED).to_be_true()
    end)

    it("falls back to the block's own hue when the theme names no colour", function()
      -- Literally "more green than its background", and nothing invented: this is
      -- the last resort, after the group's own foreground and `Added`/`Removed`.
      vim._highlights.Added = nil
      define({ AgentsAdd = { bg = GREEN_BLOCK } })
      local spec = hl(fade.count_group("AgentsAdd", "added"))
      expect(dominant(spec.fg)).to_be("g")
      expect(contrast(spec.fg, GREEN_BLOCK)).to_be_at_least(4.5)
    end)

    it("leaves a group with no block alone", function()
      -- No background is invented for it: the count is text there, and text is
      -- already drawn in whatever colour the theme gave the group.
      expect(fade.count_group("DiffDelete", "removed")).to_be("DiffDelete")
    end)

    it("stands down without truecolour", function()
      vim.o.termguicolors = false
      expect(fade.count_group("DiffAdd", "added")).to_be("DiffAdd")
    end)
  end)

  describe("flash_group", function()
    it("ignores a count that has never changed", function()
      expect(fade.flash_group("DiffAdd", nil)).to_be("DiffAdd")
    end)

    ---Rough brightness, for asserting *which way* a colour moved. Packed RGB
    ---compares as an integer, which says nothing about how light a colour looks.
    local function lum(n)
      return math.floor(n / 65536) % 256 + math.floor(n / 256) % 256 + n % 256
    end

    ---How much colour a value carries: the spread between its channels. A grey
    ---is 0 however bright it is, and a colour going *paler* loses chroma even
    ---as its brightness climbs — which is the difference this effect turns on.
    local function chroma(n)
      local r = math.floor(n / 65536) % 256
      local g = math.floor(n / 256) % 256
      local b = n % 256
      return math.max(r, g, b) - math.min(r, g, b)
    end

    ---Which channel a colour is mostly made of, so "still green" is assertable.
    local function dominant(n)
      local r = math.floor(n / 65536) % 256
      local g = math.floor(n / 256) % 256
      local b = n % 256
      if r >= g and r >= b then
        return "r"
      end
      return g >= b and "g" or "b"
    end

    it("turns a changed count's block more green, not whiter", function()
      -- The point of the effect: `+N` announces itself by being *more* of the
      -- colour it already is. A brightened block would carry less colour, not
      -- more, and a block already near peak could only go pale.
      local spec = hl(fade.flash_group("DiffAdd", 0))
      expect(chroma(spec.bg) > chroma(GREEN_BLOCK)).to_be_true()
      expect(dominant(spec.bg)).to_be("g")
    end)

    it("lights the text in the block's own hue, one notch up", function()
      -- Same colour, lighter — the pair reads as one thing. Giving them the
      -- same colour once painted #04de5d on #005523, green on green, so a count
      -- that had just changed was less legible than one at rest.
      local spec = hl(fade.flash_group("DiffAdd", 0))
      expect(spec.fg ~= spec.bg).to_be_true()
      expect(lum(spec.fg) > lum(spec.bg)).to_be_true()
      expect(dominant(spec.fg)).to_be(dominant(spec.bg))
    end)

    it("walks both halves back to the group's own colours", function()
      -- A separate base group, because the derived ones are cached per
      -- (base, step). This is the shape most colorschemes ship: white on green.
      local WHITE = 0xeef1f8
      define({ DiffAddText = { fg = WHITE, bg = GREEN_BLOCK } })
      local lit = hl(fade.flash_group("DiffAddText", 0))
      local mid = hl(fade.flash_group("DiffAddText", 2000))

      -- The block saturates, then sinks back towards its own colour.
      expect(chroma(lit.bg) > chroma(GREEN_BLOCK)).to_be_true()
      expect(chroma(mid.bg) < chroma(lit.bg)).to_be_true()
      expect(chroma(mid.bg) > chroma(GREEN_BLOCK)).to_be_true()

      -- The text starts as a lighter version of the *block*, not as the group's
      -- own foreground, and is on its way there by the middle of the ramp.
      expect(lit.fg ~= WHITE).to_be_true()
      expect(mid.fg ~= lit.fg).to_be_true()
      expect(chroma(mid.fg) < chroma(lit.fg)).to_be_true() -- draining towards white

      -- And the end of the ramp is the base group itself, both halves included.
      expect(fade.flash_group("DiffAddText", 3000)).to_be("DiffAddText")
    end)

    it("is back to the base group exactly at flash_ms", function()
      expect(fade.flash_group("DiffAdd", 2999) ~= "DiffAdd").to_be_true()
      expect(fade.flash_group("DiffAdd", 3000)).to_be("DiffAdd")
      expect(fade.flash_group("DiffAdd", 20000)).to_be("DiffAdd")
    end)

    it("saturates a foreground-only count instead of blocking it out", function()
      -- A scheme whose DiffDelete is a foreground and nothing else: using that
      -- foreground as a background too paints the number in its own colour and
      -- it vanishes. It must stay a foreground, and it must actually change —
      -- a pale pink already at peak brightness cannot be scaled up, but it has
      -- plenty of room to become red.
      local lit = fade.flash_group("DiffDelete", 0)
      expect(lit ~= "DiffDelete").to_be_true()
      local spec = hl(lit)
      expect(spec.bg).to_be_nil()
      expect(chroma(spec.fg) > chroma(PINK_TEXT)).to_be_true()
      expect(dominant(spec.fg)).to_be("r")
    end)

    it("brightens a grey count, having no hue to intensify", function()
      -- Saturating a grey would invent a hue out of nowhere — hue 0 is red, so
      -- a neutral count would flash pink. Brightness is the only direction left.
      local GREY = 0x808080
      define({ AgentsGrey = { fg = GREY } })
      local spec = hl(fade.flash_group("AgentsGrey", 0))
      expect(lum(spec.fg) > lum(GREY)).to_be_true()
      expect(chroma(spec.fg) <= 2).to_be_true()
    end)

    it("stands down without truecolour", function()
      vim.o.termguicolors = false
      expect(fade.flash_group("DiffAdd", 0)).to_be("DiffAdd")
    end)
  end)

  describe("configuration", function()
    it("takes the user's timings", function()
      fade.setup({ agents = { fade = { hold_ms = 500, steps = 2, step_ms = 50 } } })
      -- The hold boundary moves with the setting: lifted up to it, fading after.
      local lifted = fade.dim_group("AgentsPath", 499)
      expect(fade.dim_group("AgentsPath", 0)).to_be(lifted)
      expect(fade.dim_group("AgentsPath", 500) ~= lifted).to_be_true()
      local o = fade.opts()
      expect(o.hold_ms).to_be(500)
      expect(o.steps).to_be(2)
      -- Unmentioned fields keep their defaults.
      expect(o.flash_ms).to_be(3000)
    end)

    it("spans the durations the defaults promise", function()
      -- An Activity row: 3s lifted, then ~3s fading. A changed count: lit, then
      -- ~3s fading with no flat hold — `flash_ms` is one step longer than the
      -- ramp, so almost all of it is spent moving. Asserted as durations rather
      -- than as step counts, because the durations are the thing that was asked
      -- for: a future change to `steps` must keep them or say why.
      local o = fade.opts()
      expect(o.hold_ms).to_be(3000)
      expect((o.steps - 1) * o.step_ms).to_be(2880) -- the ramp, ~3s
      expect(o.flash_ms).to_be(3000)
      expect(o.flash_ms - (o.steps - 1) * o.step_ms).to_be(120) -- one step of hold

      -- And the ramp really is sampled that finely: no two adjacent steps of a
      -- 3s fade may be the same colour, or it reads as a slideshow.
      expect(fade.step_at(o.hold_ms - 1, o.hold_ms, o.steps, o.step_ms)).to_be(0)
      expect(fade.step_at(o.hold_ms, o.hold_ms, o.steps, o.step_ms)).to_be(1)
      local rested_at = o.hold_ms + (o.steps - 1) * o.step_ms
      expect(fade.step_at(rested_at, o.hold_ms, o.steps, o.step_ms)).to_be(o.steps)
      expect(fade.step_at(rested_at - o.step_ms, o.hold_ms, o.steps, o.step_ms)).to_be(o.steps - 1)
    end)

    it("can be switched off wholesale", function()
      fade.setup({ agents = { fade = false } })
      expect(fade.enabled()).to_be(false)
      expect(fade.dim_group("AgentsPath", 60000)).to_be("AgentsPath")
      expect(fade.flash_group("DiffAdd", 0)).to_be("DiffAdd")
    end)
  end)
end)
