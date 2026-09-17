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
---
--- **The hunks are not the file's own text.** The CLI writes every tab in a patch
--- as two spaces (measured: of 2398 hunks checked against the `originalFile` they
--- were cut from, 784 differ, every one only by that), while `oldString`,
--- `newString` and `originalFile` keep the tab. Matched verbatim, no hunk touching
--- a tab-indented line ever located, and each one skipped took the older hunks
--- beside it down too — one tab-indented file located 2 of its 14 hunks. So a
--- block is located by comparing the file *as the CLI writes it* (`M.shown`), and
--- the lines put back are the file's own: context is kept from the file, and a
--- removed line is recovered from the tool result (`M.annotate`), falling back to
--- re-tabbing its indentation when the block around it is tab-indented.
---@brief ]]
---@module 'claudecode.agents.patch'

local M = {}

---A line as the CLI writes it into a patch: tabs as two spaces.
---
---A trailing CR is dropped as well. `readfile` drops it from the file on disk, so
---a patch cut from a CRLF file would otherwise never match it.
---@param line string
---@return string
function M.shown(line)
  return (line:gsub("\t", "  "):gsub("\r$", ""))
end

---Split text on newlines, CRs dropped the way `readfile` drops them.
---@param text string
---@return string[]
local function split_lines(text)
  local out, from = {}, 1
  while true do
    local nl = text:find("\n", from, true)
    if not nl then
      out[#out + 1] = (text:sub(from):gsub("\r$", ""))
      return out
    end
    out[#out + 1] = (text:sub(from, nl - 1):gsub("\r$", ""))
    from = nl + 1
  end
end

---Whether a line of a patch is ambiguous about its own text: only a line holding
---two spaces in a row can have had a tab in it.
---@param text string
---@return boolean
local function ambiguous(text)
  return text:find("  ", 1, true) ~= nil
end

---Record the exact text of the removed lines in one tool result's hunks, where the
---result carries it.
---
---`originalFile` is the whole file before the edit, so a removed line is simply
---the line at its position there — but the CLI leaves it out above ~10KB (the
---largest one kept across this store is 10,680 bytes). `oldString` is on every
---`Edit` and holds most removed lines whole. Measured without `originalFile`, on
---6967 removed lines where it could be checked: every one came back exact, from
---`oldString` or from the re-tabbing `reverse_apply` falls back to.
---
---Only lines that could have held a tab are recorded, as `hunk.exact_old`, keyed
---by the line's position on the old side.
---@param hunks table[] Hunks from one `toolUseResult.structuredPatch`.
---@param result table The `toolUseResult` itself.
function M.annotate(hunks, result)
  if type(hunks) ~= "table" or type(result) ~= "table" then
    return
  end
  local has_original = type(result.originalFile) == "string"
  local has_old_string = type(result.oldString) == "string"
  if not has_original and not has_old_string then
    return
  end

  -- Split lazily: most hunks have no ambiguous removed line at all.
  local original, by_shown
  for _, hunk in ipairs(hunks) do
    local position = 0
    for _, line in ipairs(type(hunk) == "table" and type(hunk.lines) == "table" and hunk.lines or {}) do
      if type(line) == "string" then
        local mark, text = line:sub(1, 1), line:sub(2)
        if mark ~= "+" and mark ~= "\\" then
          position = position + 1
        end
        if mark == "-" and ambiguous(text) then
          local exact
          if has_original then
            original = original or split_lines(result.originalFile)
            local candidate = original[(tonumber(hunk.oldStart) or 1) + position - 1]
            if candidate and M.shown(candidate) == M.shown(text) then
              exact = candidate
            end
          end
          if not exact and has_old_string then
            if not by_shown then
              by_shown = {}
              for _, old_line in ipairs(split_lines(result.oldString)) do
                local key = M.shown(old_line)
                by_shown[key] = by_shown[key] or old_line
              end
            end
            exact = by_shown[M.shown(text)]
          end
          if exact then
            hunk.exact_old = hunk.exact_old or {}
            hunk.exact_old[position] = exact
          end
        end
      end
    end
  end
end

---Split a hunk's unified-diff body into its two sides.
---
---Both are the text as the CLI wrote it (see `M.shown`), not the file's.
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
      elseif mark ~= "\\" then
        -- Context, and anything unprefixed (a truncation marker, say): it belongs
        -- to both sides, which is also what keeps an odd line from shifting one.
        -- Except `\ No newline at end of file`, which annotates the line before it
        -- and is a line of neither side: kept as context, it put a line in the
        -- block that no file holds, and the hunk never located.
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

---Whether any line of a block is indented with a tab.
---@param lines string[]
---@param from integer 1-based first line.
---@param to integer 1-based last line.
---@return boolean
local function tab_indented(lines, from, to)
  for i = from, to do
    local line = lines[i]
    if line and line:match("^[ \t]*"):find("\t", 1, true) then
      return true
    end
  end
  return false
end

---The file's own text for a removed line of a hunk.
---@param hunk table
---@param position integer The line's position on the hunk's old side.
---@param text string The line as the patch wrote it.
---@param tabbed boolean The located block is tab-indented.
---@return string
local function removed_line(hunk, position, text, tabbed)
  text = text:gsub("\r$", "")
  if not ambiguous(text) then
    return text
  end
  local exact = type(hunk.exact_old) == "table" and hunk.exact_old[position] or nil
  if exact then
    return exact
  end
  if tabbed then
    -- Two spaces of indentation per tab, the way the CLI wrote them out.
    local indent, rest = text:match("^( *)(.*)$")
    return string.rep("\t", math.floor(#indent / 2)) .. string.rep(" ", #indent % 2) .. rest
  end
  return text
end

---Undo a session's hunks, newest first, to reconstruct what it started from.
---@param lines string[] The file as it is now.
---@param hunks table[] Every hunk the session recorded for it, oldest first.
---@return string[] before The reconstructed pre-session content.
---@return integer applied
---@return integer skipped Hunks whose new side is no longer in the file.
function M.reverse_apply(lines, hunks)
  -- `out` is the file's own text, `view` the same lines as the CLI writes them;
  -- blocks are found in `view` and rebuilt in both.
  local out, view = {}, {}
  for index, line in ipairs(lines) do
    out[index] = line
    view[index] = M.shown(line)
  end
  local applied, skipped = 0, 0

  for index = #hunks, 1, -1 do
    local hunk = hunks[index]
    local new_side = M.sides(hunk)
    local at = M.locate(view, new_side, (tonumber(hunk.newStart) or 1) - 1)
    if at then
      local tabbed = tab_indented(out, at + 1, at + #new_side)
      local rebuilt, rebuilt_view = {}, {}
      for i = 1, at do
        rebuilt[#rebuilt + 1] = out[i]
        rebuilt_view[#rebuilt_view + 1] = view[i]
      end
      -- Walked in the order `sides` reads it, so `pos` steps through the located
      -- block exactly as the new side does.
      local pos, position = at + 1, 0
      for _, line in ipairs(hunk.lines) do
        if type(line) == "string" then
          local mark, text = line:sub(1, 1), line:sub(2)
          if mark == "+" then
            pos = pos + 1
          elseif mark == "-" then
            position = position + 1
            local exact = removed_line(hunk, position, text, tabbed)
            rebuilt[#rebuilt + 1] = exact
            rebuilt_view[#rebuilt_view + 1] = M.shown(exact)
          elseif mark ~= "\\" then
            -- Context: the file's line, not the patch's rendering of it.
            position = position + 1
            rebuilt[#rebuilt + 1] = out[pos]
            rebuilt_view[#rebuilt_view + 1] = view[pos]
            pos = pos + 1
          end
        end
      end
      for i = pos, #out do
        rebuilt[#rebuilt + 1] = out[i]
        rebuilt_view[#rebuilt_view + 1] = view[i]
      end
      out, view = rebuilt, rebuilt_view
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
