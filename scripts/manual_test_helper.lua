-- Manual test helper for openDiff
-- Run this in Neovim with :luafile scripts/manual_test_helper.lua

local function test_opendiff_directly()
  print("🧪 Testing openDiff tool directly...")

  -- Use the actual README.md file like the real scenario, resolved relative to
  -- this script so the helper works in any checkout.
  local script_path = debug.getinfo(1, "S").source:sub(2)
  local repo_root = vim.fn.fnamemodify(script_path, ":p:h:h")
  local readme_path = repo_root .. "/README.md"

  -- Check if README exists
  if vim.fn.filereadable(readme_path) == 0 then
    print("❌ README.md not found at", readme_path)
    return
  end

  -- Read the actual README content
  local file = io.open(readme_path, "r")
  if not file then
    print("❌ Could not read README.md")
    return
  end
  local original_content = file:read("*a")
  file:close()

  -- Create the same modification that Claude would make (add license section)
  local new_content = original_content
    .. "\n\n## License\n\nThis project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.\n"

  -- Load the openDiff tool
  local success, open_diff_tool = pcall(require, "claudecode.tools.open_diff")
  if not success then
    print("❌ Failed to load openDiff tool:", open_diff_tool)
    return
  end

  local params = {
    old_file_path = readme_path,
    new_file_path = readme_path,
    new_file_contents = new_content,
    tab_name = "✻ [Claude Code] README.md (test) ⧉",
  }

  print("📤 Calling openDiff handler...")
  print("   Old file:", params.old_file_path)
  print("   Tab name:", params.tab_name)
  print("   Original content length:", #original_content)
  print("   New content length:", #params.new_file_contents)

  -- Call in coroutine context
  local co = coroutine.create(function()
    local result = open_diff_tool.handler(params)
    print("📥 openDiff completed with result:", vim.inspect(result))
    return result
  end)

  local start_time = vim.fn.localtime()
  local co_success, co_result = coroutine.resume(co)

  if not co_success then
    print("❌ openDiff failed:", co_result)
    return
  end

  local status = coroutine.status(co)
  print("🔍 Coroutine status:", status)

  if status == "suspended" then
    print("✅ openDiff is properly blocking!")
    print("👉 You should see a diff view now")
    print("👉 Save or close the diff to continue")

    -- Set up a timer to check when it completes
    local timer = vim.loop.new_timer()
    if not timer then
      print("❌ Failed to create timer")
      return
    end
    timer:start(
      1000,
      1000,
      vim.schedule_wrap(function()
        local current_status = coroutine.status(co)
        if current_status == "dead" then
          timer:stop()
          timer:close()
          local elapsed = vim.fn.localtime() - start_time
          print("✅ openDiff completed after " .. elapsed .. " seconds")
        elseif current_status ~= "suspended" then
          timer:stop()
          timer:close()
          print("⚠️  Unexpected coroutine status:", current_status)
        end
      end)
    )
  else
    print("❌ openDiff did not block (status: " .. status .. ")")
    if co_result then
      print("   Result:", vim.inspect(co_result))
    end
  end

  -- No cleanup needed since we're using the actual README file
end

-- Run the test
test_opendiff_directly()
