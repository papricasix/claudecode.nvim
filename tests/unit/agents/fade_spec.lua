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
    ---How much colour a value carries, so "the block is the fainter half" and
    ---"the peak is louder than rest" are assertable.
    local function chroma(n)
      local r, g, b = math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
      return math.max(r, g, b) - math.min(r, g, b)
    end

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

    it("draws the number and its block from the theme's own added colour", function()
      -- The shape most colorschemes ship: a block with no foreground, so the
      -- number fell through to `Normal` and a `+12` came out white on green —
      -- "highlighted text", not "twelve lines were added". A diff never looks
      -- like that.
      define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { bg = GREEN_BLOCK } })
      local group = fade.count_group("AgentsAdd", "added", nil)
      expect(group ~= "AgentsAdd").to_be_true()
      local spec = hl(group)
      -- Both halves are one hue at two strengths, so both read green...
      expect(dominant(spec.fg)).to_be("g")
      expect(dominant(spec.bg)).to_be("g")
      -- ...the block being the fainter of them...
      expect(chroma(spec.bg) < chroma(spec.fg)).to_be_true()
      -- ...and the number legible on it.
      expect(contrast(spec.fg, spec.bg)).to_be_at_least(4.5)
    end)

    it("derives the block from the number rather than from the theme's own", function()
      -- The theme's `DiffAdd` background is often a different hue from the diff
      -- text the same theme ships — tokyonight-moon pairs a green `Added` with a
      -- blue `#2a4556` block — so the block is rebuilt from the number's hue.
      -- Keeping it was what made a `+N` flash blue on that theme.
      local BLUE_BLOCK = 0x2a4556
      define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { bg = BLUE_BLOCK } })
      local spec = hl(fade.count_group("AgentsAdd", "added", nil))
      expect(spec.bg ~= BLUE_BLOCK).to_be_true()
      expect(dominant(spec.bg)).to_be("g")
    end)

    it("replaces a foreground that is really a white or a grey", function()
      -- Neovim's own `DiffAdd` is `#eef1f8` on green. HSL calls that saturation
      -- 0.42 — saturation runs away at the light end — so the test is the spread
      -- between the channels, which is four percent. No colour was chosen there.
      define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { fg = 0xeef1f8, bg = GREEN_BLOCK } })
      local spec = hl(fade.count_group("AgentsAdd", "added", nil))
      expect(spec.fg ~= 0xeef1f8).to_be_true()
      expect(dominant(spec.fg)).to_be("g")
    end)

    it("keeps a hue the theme actually chose, and makes it legible", function()
      -- kanagawa paints `DiffDelete` red on salmon: it means that, and it is not
      -- second-guessed — but it measures 1.99:1, which no number can be read at.
      local SALMON, RED = 0xd9a594, 0xd7474b
      define({ AgentsDel = { fg = RED, bg = SALMON } })
      local spec = hl(fade.count_group("AgentsDel", "removed", nil))
      expect(dominant(spec.fg)).to_be("r")
      expect(dominant(spec.bg)).to_be("r")
      expect(contrast(spec.fg, spec.bg)).to_be_at_least(4.5)
    end)

    it("falls back to the block's own hue when the theme names no colour", function()
      -- Last resort, after the group's own foreground and `Added`/`Removed`.
      vim._highlights.Added = nil
      define({ AgentsAdd = { bg = GREEN_BLOCK } })
      local spec = hl(fade.count_group("AgentsAdd", "added", nil))
      expect(dominant(spec.fg)).to_be("g")
      expect(contrast(spec.fg, spec.bg)).to_be_at_least(4.5)
    end)

    it("builds a block for a group that has none, so + and - match", function()
      -- Some schemes give `DiffDelete` a foreground and no background at all. The
      -- block follows the number now, so there is one to build it from, and a
      -- `-3` is a block like the `+12` beside it rather than bare text.
      define({ Removed = { fg = 0xffc0b9 }, AgentsBare = { fg = 0xffc0b9 } })
      local spec = hl(fade.count_group("AgentsBare", "removed", nil))
      expect(spec.bg).to_be_truthy()
      expect(dominant(spec.bg)).to_be("r")
    end)

    it("leaves a group alone when nothing anywhere has a hue", function()
      vim._highlights.Removed = nil
      define({ AgentsGreyBlock = { fg = 0x9a9a9a, bg = 0x303030 } })
      expect(fade.count_group("AgentsGreyBlock", "removed", nil)).to_be("AgentsGreyBlock")
    end)

    it("stands down without truecolour", function()
      vim.o.termguicolors = false
      expect(fade.count_group("DiffAdd", "added", nil)).to_be("DiffAdd")
    end)

    describe("the flash", function()
      before_each(function()
        define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { bg = GREEN_BLOCK } })
      end)

      it("goes to the theme's colour undiluted, on a louder block", function()
        -- The peak *is* the colour the theme ships; rest is that held back. So a
        -- count announcing itself is the same green turned up, never another one.
        local rest = hl(fade.count_group("AgentsAdd", "added", nil))
        local peak = hl(fade.count_group("AgentsAdd", "added", 0))
        expect(chroma(peak.fg) > chroma(rest.fg)).to_be_true()
        expect(chroma(peak.bg) > chroma(rest.bg)).to_be_true()
        expect(dominant(peak.fg)).to_be("g")
        expect(dominant(peak.bg)).to_be("g")
        expect(contrast(peak.fg, peak.bg)).to_be_at_least(4.5)
      end)

      it("walks both halves back to the resting colours", function()
        local rest = fade.count_group("AgentsAdd", "added", nil)
        local peak = hl(fade.count_group("AgentsAdd", "added", 0))
        local mid = hl(fade.count_group("AgentsAdd", "added", 1500))
        expect(chroma(mid.fg) < chroma(peak.fg)).to_be_true()
        expect(chroma(mid.fg) > chroma(hl(rest).fg)).to_be_true()
        expect(chroma(mid.bg) < chroma(peak.bg)).to_be_true()
        -- And the end of the ramp is the resting group itself, both halves.
        expect(fade.count_group("AgentsAdd", "added", 3000)).to_be(rest)
        expect(fade.count_group("AgentsAdd", "added", 20000)).to_be(rest)
      end)

      it("is back to rest exactly at flash_ms", function()
        local rest = fade.count_group("AgentsAdd", "added", nil)
        expect(fade.count_group("AgentsAdd", "added", 2999) ~= rest).to_be_true()
        expect(fade.count_group("AgentsAdd", "added", 3000)).to_be(rest)
      end)

      it("does not fire at all with the fade switched off", function()
        -- The resting colours are not an animation, so they stay; only the flash
        -- goes. `fade = false` means "do not move", not "give me white on green".
        fade.setup({ agents = { fade = false } })
        define({ Added = { fg = 0xb3f6c0 }, AgentsAdd = { bg = GREEN_BLOCK } })
        local rest = fade.count_group("AgentsAdd", "added", nil)
        expect(rest ~= "AgentsAdd").to_be_true()
        expect(dominant(hl(rest).fg)).to_be("g")
        expect(fade.count_group("AgentsAdd", "added", 0)).to_be(rest)
      end)
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
      -- The count blocks keep their derived colours: those are what the theme's
      -- diff looks like, not an animation. Only the flash stops (see above).
      expect(fade.count_group("AgentsPath", "added", 0)).to_be(fade.count_group("AgentsPath", "added", nil))
    end)
  end)
end)
