require("tests.busted_setup")

-- The unified review diff scrolls the whole change into view: centered when it
-- fits the window, otherwise pinned with its first changed line at the top.
-- Deleted lines are virtual lines above the first changed line, so they have to
-- be measured (region.rows) and shown (topfill) or they scroll off the top.

describe("Unified diff scroll position", function()
  local diff

  before_each(function()
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
  end)

  it("centers a change that fits the window, deleted lines included", function()
    -- 3 added lines at line 50 with 2 deleted lines above them: 5 rows in a
    -- 22-row window leaves 17 rows of context, 8 of them above.
    local top, fill = diff._diff_scroll_position({ first = 50, rows = 5, fill_above = 2 }, 22)

    assert.equal(42, top)
    -- Real context lines are above the region, so the deleted lines are already
    -- on screen without borrowing fill rows from the top line.
    assert.equal(0, fill)
  end)

  it("pins the first changed line at the top when the change is taller than the window", function()
    local top, fill = diff._diff_scroll_position({ first = 40, rows = 82, fill_above = 3 }, 22)

    assert.equal(40, top)
    -- The lines deleted at the start of the change stay visible above it.
    assert.equal(3, fill)
  end)

  it("keeps its own deleted lines when the change starts at the first buffer line", function()
    local top, fill = diff._diff_scroll_position({ first = 1, rows = 6, fill_above = 4 }, 40)

    -- There is nothing to scroll above, so the fill rows have to be asked for.
    assert.equal(1, top)
    assert.equal(4, fill)
  end)

  it("clamps to the first buffer line when the change is near the top", function()
    local top, fill = diff._diff_scroll_position({ first = 2, rows = 6, fill_above = 4 }, 40)

    assert.equal(1, top)
    -- Line 1 is on screen above the region, so its deleted lines render anyway.
    assert.equal(0, fill)
  end)

  it("centers exactly when the change is one row shorter than the window", function()
    local top, fill = diff._diff_scroll_position({ first = 10, rows = 21, fill_above = 0 }, 22)

    assert.equal(10, top)
    assert.equal(0, fill)
  end)
end)
