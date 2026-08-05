---@brief [[
--- Turning the CLI's `structuredPatch` hunks back into a "before" file.
---
--- The Changes and Activity panes know exactly what a session did to a file — the
--- transcript records a unified-diff hunk per edit — but showing it as a diff needs
--- the *other* side, and the CLI stores no baseline: `originalFile` is present on
--- only some edits (179 of 402 in one real transcript here), so it cannot be relied
--- on.
---
--- What is always there is every hunk. Applied to the file on disk in reverse,
--- newest edit first, they undo the session and yield the content it started from.
--- Diffing today's file against that is the session's own diff.
---
--- The one thing that breaks it is the file moving on afterwards — a later session,
--- or the user's own editing. So a hunk is located by *content* rather than by its
--- recorded line number: the new-side block is searched for, nearest to where the
--- patch says it should be. A hunk whose new side is no longer anywhere in the file
--- was overwritten later, and is skipped: those changes are genuinely not in this
--- file any more, so leaving them out of the diff is the honest answer rather than a
--- failure. Measured over six real transcripts, 253 of 349 hunks still locate, and
--- for a session that ran recently — the case the view is for — it is all of them.
---@brief ]]
---@module 'claudecode.agents.patch'

local M = {}

---Split a hunk's unified-diff body into its two sides.
---@param hunk table `{ lines: string[] }` — `+`/`-`/` ` prefixed.
---@return string[] new_side Lines as they look after the edit.
---@return string[] old_side Lines as they looked before it.
function M.sides(hunk)
  local new_side, old_side = {}, {}
  local lines = type(hunk) == "table" and hunk.lines or nil
  if type(lines) ~= "table" then
    return new_side, old_side
  end
  for _, line in ipairs(lines) do
    if type(line) == "string" then
      local mark, text = line:sub(1, 1), line:sub(2)
      if mark == "+" then
        new_side[#new_side + 1] = text
      elseif mark == "-" then
        old_side[#old_side + 1] = text
      else
        -- Context, and anything unprefixed (a truncation marker, say): it belongs
        -- to both sides, which is also what keeps an odd line from shifting one.
        new_side[#new_side + 1] = text
        old_side[#old_side + 1] = text
      end
    end
  end
  return new_side, old_side
end

---Find `block` in `lines`, preferring the occurrence nearest `near`.
---@param lines string[]
---@param block string[]
---@param near integer 0-based index the patch expects it at.
---@return integer|nil at 0-based index of the match.
function M.locate(lines, block, near)
  if #block == 0 then
    return nil
  end
  local best, best_distance = nil, nil
  local first = block[1]
  for index = 0, #lines - #block do
    if lines[index + 1] == first then
      local match = true
      for offset = 2, #block do
        if lines[index + offset] ~= block[offset] then
          match = false
          break
        end
      end
      if match then
        local distance = math.abs(index - near)
        if not best_distance or distance < best_distance then
          best, best_distance = index, distance
          if distance == 0 then
            break -- exactly where the patch said; nothing can beat it
          end
        end
      end
    end
  end
  return best
end

---Undo a session's hunks, newest first, to reconstruct what it started from.
---@param lines string[] The file as it is now.
---@param hunks table[] Every hunk the session recorded for it, oldest first.
---@return string[] before The reconstructed pre-session content.
---@return integer applied
---@return integer skipped Hunks whose new side is no longer in the file.
function M.reverse_apply(lines, hunks)
  local out = {}
  for index, line in ipairs(lines) do
    out[index] = line
  end
  local applied, skipped = 0, 0

  for index = #hunks, 1, -1 do
    local hunk = hunks[index]
    local new_side, old_side = M.sides(hunk)
    local at = M.locate(out, new_side, (tonumber(hunk.newStart) or 1) - 1)
    if at then
      local rebuilt = {}
      for i = 1, at do
        rebuilt[#rebuilt + 1] = out[i]
      end
      for _, line in ipairs(old_side) do
        rebuilt[#rebuilt + 1] = line
      end
      for i = at + #new_side + 1, #out do
        rebuilt[#rebuilt + 1] = out[i]
      end
      out = rebuilt
      applied = applied + 1
    else
      skipped = skipped + 1
    end
  end

  return out, applied, skipped
end

---Render hunks as unified-diff text, for when there is nothing to diff against —
---the file was deleted, or nothing could be located in it any more. It is the same
---thing `git show` prints, and it can never be wrong: it is the record itself.
---@param path string
---@param hunks table[]
---@return string[] lines
function M.to_diff_lines(path, hunks)
  local out = { "--- a/" .. path, "+++ b/" .. path }
  for _, hunk in ipairs(hunks) do
    out[#out + 1] = string.format(
      "@@ -%d,%d +%d,%d @@",
      tonumber(hunk.oldStart) or 0,
      tonumber(hunk.oldLines) or 0,
      tonumber(hunk.newStart) or 0,
      tonumber(hunk.newLines) or 0
    )
    for _, line in ipairs(type(hunk.lines) == "table" and hunk.lines or {}) do
      if type(line) == "string" then
        out[#out + 1] = line
      end
    end
  end
  return out
end

return M
