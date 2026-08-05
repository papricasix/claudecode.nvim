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
    it("lifts a fresh row above its own colour so it pops", function()
      -- Without the lift, "fresh" means only "not yet dimmed" — and two of the
      -- three columns draw in `Comment`, a muted grey, so a new row announced
      -- itself hardly at all.
      local lit = fade.dim_group("AgentsPath", 0)
      expect(lit ~= "AgentsPath").to_be_true()
      expect(hl(lit).fg > CYAN).to_be_true()
      -- Still lifted at the end of the hold, and dropping once past it.
      expect(fade.dim_group("AgentsPath", 2999)).to_be(lit)
      expect(fade.dim_group("AgentsPath", 3000) ~= lit).to_be_true()
    end)

    it("passes back through the base colour on the way down", function()
      -- One continuous ramp bright -> normal -> quiet, rather than a hold at the
      -- base with a fade bolted after it.
      local o = fade.opts()
      local lit_fg = hl(fade.dim_group("AgentsPath", 0)).fg
      local rested_fg = hl(fade.dim_group("AgentsPath", 60000)).fg
      expect(lit_fg > CYAN).to_be_true()
      expect(rested_fg < CYAN).to_be_true()
      -- Somewhere in the middle it is within a hair of the group's own colour.
      local closest = math.huge
      for step = 0, o.steps do
        local fg = hl(fade.dim_group("AgentsPath", o.hold_ms + step * o.step_ms)).fg
        closest = math.min(closest, math.abs(fg - CYAN))
      end
      expect(closest < 0x030303).to_be_true()
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

  describe("flash_group", function()
    it("ignores a count that has never changed", function()
      expect(fade.flash_group("DiffAdd", nil)).to_be("DiffAdd")
    end)

    ---Rough brightness, for asserting *which way* a colour moved. Packed RGB
    ---compares as an integer, which says nothing about how light a colour looks.
    local function lum(n)
      return math.floor(n / 65536) % 256 + math.floor(n / 256) % 256 + n % 256
    end

    it("lights the text and its block together, the text further", function()
      -- Both halves lift, unequally. Lifting them the same amount put #04de5d on
      -- #005523 — green on green — so a count that had just changed was less
      -- legible than one at rest. The gap is what keeps the number readable.
      local spec = hl(fade.flash_group("DiffAdd", 0))
      expect(lum(spec.bg) > lum(GREEN_BLOCK)).to_be_true()
      expect(lum(spec.fg) > lum(spec.bg)).to_be_true()
    end)

    it("walks both halves back to the group's own colours", function()
      -- A separate base group, because the derived ones are cached per
      -- (base, step). This is the shape most colorschemes ship: white on green.
      local WHITE = 0xeef1f8
      define({ DiffAddText = { fg = WHITE, bg = GREEN_BLOCK } })
      local lit = hl(fade.flash_group("DiffAddText", 0))
      local mid = hl(fade.flash_group("DiffAddText", 2000))

      -- The block lifts, then sinks back towards its own colour.
      expect(lum(lit.bg) > lum(GREEN_BLOCK)).to_be_true()
      expect(lum(mid.bg) < lum(lit.bg)).to_be_true()
      expect(lum(mid.bg) > lum(GREEN_BLOCK)).to_be_true()

      -- The text starts as a bright version of the *block*, not as the group's
      -- own foreground, and is on its way there by the middle of the ramp.
      expect(lit.fg ~= WHITE).to_be_true()
      expect(mid.fg ~= lit.fg).to_be_true()
      expect(lum(mid.fg) > lum(lit.fg)).to_be_true() -- climbing towards white

      -- And the end of the ramp is the base group itself, both halves included.
      expect(fade.flash_group("DiffAddText", 3000)).to_be("DiffAddText")
    end)

    it("is back to the base group exactly at flash_ms", function()
      expect(fade.flash_group("DiffAdd", 2999) ~= "DiffAdd").to_be_true()
      expect(fade.flash_group("DiffAdd", 3000)).to_be("DiffAdd")
      expect(fade.flash_group("DiffAdd", 20000)).to_be("DiffAdd")
    end)

    it("brightens a foreground-only count instead of blocking it out", function()
      -- A scheme whose DiffDelete is a foreground and nothing else: using that
      -- foreground as a background too paints the number in its own colour and
      -- it vanishes. It must stay a foreground, and it must actually change —
      -- a colour already at peak brightness cannot be scaled up.
      local lit = fade.flash_group("DiffDelete", 0)
      expect(lit ~= "DiffDelete").to_be_true()
      local spec = hl(lit)
      expect(spec.bg).to_be_nil()
      expect(spec.fg ~= PINK_TEXT).to_be_true()
      expect(spec.fg > PINK_TEXT).to_be_true()
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
