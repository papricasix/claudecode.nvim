--- Tool implementation for opening a file.

local schema = {
  description = "Open a file in the editor and optionally select a range of text",
  inputSchema = {
    type = "object",
    properties = {
      filePath = {
        type = "string",
        description = "Path to the file to open",
      },
      preview = {
        type = "boolean",
        description = "Whether to open the file in preview mode",
        default = false,
      },
      startLine = {
        type = "integer",
        description = "Optional: Line number to start selection",
      },
      endLine = {
        type = "integer",
        description = "Optional: Line number to end selection",
      },
      startText = {
        type = "string",
        description = "Text pattern to find the start of the selection range. Selects from the beginning of this match.",
      },
      endText = {
        type = "string",
        description = "Text pattern to find the end of the selection range. Selects up to the end of this match. If not provided, only the startText match will be selected.",
      },
      selectToEndOfLine = {
        type = "boolean",
        description = "If true, selection will extend to the end of the line containing the endText match.",
        default = false,
      },
      makeFrontmost = {
        type = "boolean",
        description = "Whether to make the file the active editor tab. If false, the file will be opened in the background without changing focus.",
        default = true,
      },
    },
    required = { "filePath" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Finds a suitable main editor window to open files in.
---
---Delegates to `diff`'s finder rather than keeping a second copy of the rules.
---The copy that used to live here drifted in two ways that mattered: it scanned
---`nvim_list_wins()` across *every* tab, so a file could open in a tab the user
---was not in and that no Claude owned, and it did not honour the
---`claudecode_live_preview` tag, so it would take over windows the plugin had
---explicitly marked as not-an-editor.
---
---Scoped to the tab that owns the request, which is where the asking Claude lives.
---@return integer? win_id Window ID of the main editor window, or nil if not found
local function find_main_editor_window(file_path)
  local diff = require("claudecode.diff")
  local target_tab = require("claudecode.request_context").tab()

  local windows
  if target_tab then
    local ok, tab_wins = pcall(vim.api.nvim_tabpage_list_wins, target_tab)
    windows = ok and tab_wins or nil
  end
  if not windows then
    local ok, tab_wins = pcall(function()
      return vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())
    end)
    windows = ok and tab_wins or nil
  end

  -- One rule stays here rather than moving into the shared finder: opening a file
  -- must not take over a scratch window (a start screen, a plugin panel), while a
  -- diff legitimately may reuse one. Filtering the candidates keeps that
  -- difference without duplicating the rest of the rules.
  local candidates = {}
  for _, win in ipairs(windows or {}) do
    local ok, buftype = pcall(function()
      return vim.api.nvim_buf_get_option(vim.api.nvim_win_get_buf(win), "buftype")
    end)
    if ok and buftype ~= "nofile" then
      candidates[#candidates + 1] = win
    end
  end

  return diff.resolve_target_window({
    tab = target_tab,
    purpose = "open",
    file_path = file_path,
    session_id = require("claudecode.request_context").session_id(),
    candidates = candidates,
  })
end

--- Handles the openFile tool invocation.
--- Opens a file in the editor with optional selection.
---@param params table The input parameters for the tool
---@return table MCP-compliant response with content array
local function handler(params)
  if not params.filePath then
    error({ code = -32602, message = "Invalid params", data = "Missing filePath parameter" })
  end

  -- Expand a leading `~` only: `vim.fn.expand` would read `$name` as an
  -- environment variable and drop undefined ones, breaking a literal `$` in a
  -- path (e.g. TanStack Router's `src/routes/$post.tsx`).
  local file_path = require("claudecode.utils").expand_tilde(params.filePath)

  if vim.fn.filereadable(file_path) == 0 then
    -- Using a generic error code for tool-specific operational errors
    error({ code = -32000, message = "File operation error", data = "File not found: " .. file_path })
  end

  -- Set default values for optional parameters
  local preview = params.preview or false
  local make_frontmost = params.makeFrontmost ~= false -- default true
  local select_to_end_of_line = params.selectToEndOfLine or false

  local message = "Opened file: " .. file_path

  -- Where this file may go, which is not a question this tool answers alone: a
  -- tab that owns its layout (the agents view) has no window to spare and hosts
  -- files in a float instead. See `diff.resolve_target_window`.
  local target_win, kind = find_main_editor_window(file_path)

  if target_win then
    -- Open file in the target window
    vim.api.nvim_win_call(target_win, function()
      if preview then
        vim.cmd("pedit " .. vim.fn.fnameescape(file_path))
      else
        vim.cmd("edit " .. vim.fn.fnameescape(file_path))
      end
    end)
    if kind == "float" then
      -- A float is answerable on its own terms: `q` closes it, `<Tab>` reaches the
      -- one behind. `create` already focused it, so `makeFrontmost` has nothing
      -- left to do — and honouring it literally would mean switching tabpages,
      -- which for a tool Claude calls several times a minute is not a favour.
      pcall(function()
        require("claudecode.float").bind_close(target_win)
      end)
    elseif make_frontmost then
      vim.api.nvim_set_current_win(target_win)
    end
  else
    -- Fallback: Create a new window if no suitable window found
    -- Try to move to a better position
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

    -- If we're still in a special window -- or one that belongs to a diff -- create a
    -- new split, so we never `:edit` over a terminal, a sidebar, or someone's diff.
    local cur_win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(cur_win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" or vim.api.nvim_win_get_option(cur_win, "diff") then
      vim.cmd("vsplit")
      -- A new split inherits window-local options, 'diff' included, from the window
      -- it was made from. Clear it so the file we open cannot join the user's diff
      -- set as an extra pane (upstream issue #277). `:diffoff` acts on this window
      -- only -- never `:diffoff!`.
      vim.cmd("diffoff")
    end

    if preview then
      vim.cmd("pedit " .. vim.fn.fnameescape(file_path))
    else
      vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    end
    target_win = vim.api.nvim_get_current_win()
  end

  -- The selection below addresses the current buffer and window, which is not
  -- necessarily the one the file landed in: a background open (makeFrontmost =
  -- false) or a float leaves the user's window current, and the marks would be
  -- set in whatever they were looking at.
  local function run_in_target_window(callback)
    if target_win and vim.api.nvim_win_is_valid(target_win) then
      return vim.api.nvim_win_call(target_win, callback)
    end
    return callback()
  end

  -- Handle text selection by line numbers
  if params.startLine or params.endLine then
    run_in_target_window(function()
      local start_line = params.startLine or 1
      local end_line = params.endLine or start_line

      -- Convert to 0-based indexing for vim API
      local start_pos = { start_line - 1, 0 }
      local end_pos = { end_line - 1, -1 } -- -1 means end of line

      vim.api.nvim_buf_set_mark(0, "<", start_pos[1], start_pos[2], {})
      vim.api.nvim_buf_set_mark(0, ">", end_pos[1], end_pos[2], {})
      vim.cmd("normal! gv")
    end)

    local start_line = params.startLine or 1
    message = "Opened file and selected lines " .. start_line .. " to " .. (params.endLine or start_line)
  end

  -- Handle text pattern selection
  if params.startText then
    local buf = run_in_target_window(function()
      return vim.api.nvim_get_current_buf()
    end)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local start_line_idx, start_col_idx
    local end_line_idx, end_col_idx

    -- Find start text
    for line_idx, line in ipairs(lines) do
      local col_idx = string.find(line, params.startText, 1, true) -- plain text search
      if col_idx then
        start_line_idx = line_idx - 1 -- Convert to 0-based
        start_col_idx = col_idx - 1 -- Convert to 0-based
        break
      end
    end

    if start_line_idx then
      -- Find end text if provided
      if params.endText then
        for line_idx = start_line_idx + 1, #lines do
          local line = lines[line_idx] -- Access current line directly
          if line then
            local col_idx = string.find(line, params.endText, 1, true)
            if col_idx then
              end_line_idx = line_idx
              end_col_idx = col_idx + string.len(params.endText) - 1
              if select_to_end_of_line then
                end_col_idx = string.len(line)
              end
              break
            end
          end
        end

        if end_line_idx then
          message = 'Opened file and selected text from "' .. params.startText .. '" to "' .. params.endText .. '"'
        else
          -- End text not found, select only start text
          end_line_idx = start_line_idx
          end_col_idx = start_col_idx + string.len(params.startText) - 1
          message = 'Opened file and positioned at "'
            .. params.startText
            .. '" (end text "'
            .. params.endText
            .. '" not found)'
        end
      else
        -- Only start text provided
        end_line_idx = start_line_idx
        end_col_idx = start_col_idx + string.len(params.startText) - 1
        message = 'Opened file and selected text "' .. params.startText .. '"'
      end

      -- Apply the selection
      run_in_target_window(function()
        vim.api.nvim_win_set_cursor(0, { start_line_idx + 1, start_col_idx })
        vim.api.nvim_buf_set_mark(0, "<", start_line_idx, start_col_idx, {})
        vim.api.nvim_buf_set_mark(0, ">", end_line_idx, end_col_idx, {})
        vim.cmd("normal! gv")
        vim.cmd("normal! zz") -- Center the selection in the window
      end)
    else
      message = 'Opened file, but text "' .. params.startText .. '" not found'
    end
  end

  -- Return format based on makeFrontmost parameter
  if make_frontmost then
    -- Simple message format when makeFrontmost=true
    return {
      content = {
        {
          type = "text",
          text = message,
        },
      },
    }
  else
    -- Detailed JSON format when makeFrontmost=false
    local buf = run_in_target_window(function()
      return vim.api.nvim_get_current_buf()
    end)
    local detailed_info = {
      success = true,
      filePath = file_path,
      languageId = vim.api.nvim_buf_get_option(buf, "filetype"),
      lineCount = vim.api.nvim_buf_line_count(buf),
    }

    return {
      content = {
        {
          type = "text",
          text = vim.json.encode(detailed_info),
        },
      },
    }
  end
end

return {
  name = "openFile",
  schema = schema,
  handler = handler,
}
