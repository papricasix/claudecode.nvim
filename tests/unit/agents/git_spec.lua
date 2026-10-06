-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.git", function()
  local git
  local runs -- every argv the module asked to run

  ---Install a runner that answers with canned porcelain output.
  ---@param lines string[]|fun(argv: string[]): string[]
  ---@param code integer|nil
  local function respond_with(lines, code)
    git._set_runner(function(argv, cwd, cb)
      runs[#runs + 1] = { argv = argv, cwd = cwd }
      local out = type(lines) == "function" and lines(argv) or lines
      cb(out, code or 0)
    end)
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    runs = {}
    package.loaded["claudecode.agents.git"] = nil
    git = require("claudecode.agents.git")
    git.reset()
  end)

  describe("parsing", function()
    it("reads the letter out of each status pair", function()
      local status = git.parse_status({
        " M lua/a.lua",
        "A  lua/new.lua",
        " D lua/gone.lua",
        "?? notes.md",
      }, "/proj")

      expect(status["/proj/lua/a.lua"]).to_be("M")
      expect(status["/proj/lua/new.lua"]).to_be("A")
      expect(status["/proj/lua/gone.lua"]).to_be("D")
      expect(status["/proj/notes.md"]).to_be("?")
    end)

    it("prefers the index column when both are set", function()
      -- A staged add that was then modified is still an add.
      local status = git.parse_status({ "AM lua/a.lua" }, "/proj")
      expect(status["/proj/lua/a.lua"]).to_be("A")
    end)

    it("takes the new path of a rename", function()
      -- The file that exists now is the one the caller is showing.
      local status = git.parse_status({ "R  lua/old.lua -> lua/new.lua" }, "/proj")
      expect(status["/proj/lua/new.lua"]).to_be("R")
      expect(status["/proj/lua/old.lua"]).to_be(nil)
    end)

    it("unquotes a path git had to quote", function()
      local status = git.parse_status({ ' M "lua/with space.lua"' }, "/proj")
      expect(status["/proj/lua/with space.lua"]).to_be("M")
    end)

    it("leaves an absolute path alone", function()
      local status = git.parse_status({ " M /elsewhere/a.lua" }, "/proj")
      expect(status["/elsewhere/a.lua"]).to_be("M")
    end)

    it("keys a Windows root the way the caller looks it up", function()
      -- Git answers with `/` separators on every platform, while the paths the
      -- caller holds are the CLI's own — `D:\Git\proj\lua\a.lua`. Joining the two
      -- verbatim produced a key nothing could ever match, so no file in the
      -- Changes pane got a status letter.
      local status = git.parse_status({ " M lua/a.lua", "?? notes.md" }, "D:\\Git\\proj")
      local utils = require("claudecode.utils")
      expect(status[utils.path_key("D:\\Git\\proj\\lua\\a.lua")]).to_be("M")
      expect(status[utils.path_key("D:\\Git\\proj\\notes.md")]).to_be("?")
    end)

    it("leaves an absolute Windows path alone", function()
      local status = git.parse_status({ " M D:/elsewhere/a.lua" }, "D:\\Git\\proj")
      expect(status[require("claudecode.utils").path_key("D:\\elsewhere\\a.lua")]).to_be("M")
    end)

    it("survives empty and malformed output", function()
      expect(next(git.parse_status(nil, "/proj"))).to_be(nil)
      expect(next(git.parse_status({}, "/proj"))).to_be(nil)
      expect(next(git.parse_status({ "" }, "/proj"))).to_be(nil)
    end)
  end)

  describe("querying", function()
    it("restricts the query to the paths being shown", function()
      -- A big repository must never be walked to draw a three-file panel.
      respond_with({})
      git.status("/proj", { "/proj/a.lua", "/proj/b.lua" }, function() end)

      local argv = runs[1].argv
      local joined = table.concat(argv, " ")
      expect(joined:find("status", 1, true) ~= nil).to_be_true()
      expect(joined:find("--porcelain=v1", 1, true) ~= nil).to_be_true()
      expect(argv[#argv]).to_be("/proj/b.lua")
      expect(argv[#argv - 1]).to_be("/proj/a.lua")
    end)

    it("never asks for NUL-delimited output", function()
      -- jobstart splits stdout on newlines and turns NUL into \n, which destroys
      -- the exact framing -z exists to provide.
      respond_with({})
      git.status("/proj", { "/proj/a.lua" }, function() end)
      expect(table.concat(runs[1].argv, " "):find("-z", 1, true)).to_be(nil)
    end)

    it("hands back the parsed status", function()
      respond_with({ " M a.lua" })
      local result
      git.status("/proj", { "/proj/a.lua" }, function(status)
        result = status
      end)
      expect(result["/proj/a.lua"]).to_be("M")
    end)

    it("answers with nothing when git fails", function()
      respond_with({ "fatal: not a git repository" }, 128)
      local result = "unset"
      git.status("/proj", { "/proj/a.lua" }, function(status)
        result = status
      end)
      expect(next(result)).to_be(nil)
    end)

    it("does not run at all without a root or paths", function()
      respond_with({})
      local calls = 0
      local function count()
        calls = calls + 1
      end
      git.status(nil, { "/proj/a.lua" }, count)
      git.status("/proj", {}, count)
      git.status("", { "/proj/a.lua" }, count)

      expect(#runs).to_be(0)
      expect(calls).to_be(3) -- every caller still gets an answer
    end)
  end)

  describe("reading a file's committed content", function()
    local spawned

    ---Answer every command with `text` and `code`, recording what was run.
    local function spawn_answers(kind, root, text, code)
      git._working_copy = function()
        return kind, root
      end
      git._spawn = function(argv, cwd, cb)
        spawned[#spawned + 1] = { argv = argv, cwd = cwd }
        cb(text, code)
      end
    end

    local function read(path)
      local answer
      git._show_head(path, function(lines, info)
        answer = { lines = lines, info = info }
      end)
      return answer
    end

    before_each(function()
      spawned = {}
    end)

    it("asks git for HEAD, from the file's own directory", function()
      spawn_answers("git", "/proj", "one\ntwo\n", 0)
      local answer = read("/proj/lua/a.lua")

      expect(table.concat(spawned[1].argv, " ")).to_be("git -C /proj/lua show HEAD:./a.lua")
      -- The final newline is not a line of the file.
      expect(table.concat(answer.lines, "|")).to_be("one|two")
      expect(answer.info.rev).to_be("HEAD")
    end)

    it("asks svn for BASE in an svn working copy", function()
      spawn_answers("svn", "/wc", "one\n", 0)
      local answer = read("/wc/src/a@2x.lua")

      -- The trailing @ keeps an @ in the name from reading as a peg revision.
      expect(table.concat(spawned[1].argv, " ")).to_be("svn cat -r BASE /wc/src/a@2x.lua@")
      expect(spawned[1].cwd).to_be("/wc")
      expect(answer.lines[1]).to_be("one")
      expect(answer.info.vcs).to_be("svn")
      expect(answer.info.rev).to_be("BASE")
    end)

    it("reads a failure inside a working copy as not committed", function()
      spawn_answers("svn", "/wc", "", 1)
      local answer = read("/wc/new.lua")
      expect(answer.lines).to_be_nil()
      expect(answer.info.unversioned).to_be_nil()
      expect(answer.info.failed).to_be_nil()
    end)

    it("still asks git outside any working copy, and calls a failure unversioned", function()
      -- A repository named by GIT_DIR leaves no marker to find.
      spawn_answers(nil, nil, "", 128)
      local answer = read("/tmp/loose.lua")
      expect(spawned[1].argv[1]).to_be("git")
      expect(answer.info.unversioned).to_be_true()
    end)

    it("says when the command could not be started at all", function()
      spawn_answers("svn", "/wc", nil, -1)
      local answer = read("/wc/a.lua")
      expect(answer.lines).to_be_nil()
      expect(answer.info.failed).to_be_true()
    end)
  end)

  describe("single flight", function()
    it("coalesces a burst into one extra query", function()
      -- Deferred so several requests are genuinely in flight at once.
      local pending
      git._set_runner(function(argv, cwd, cb)
        runs[#runs + 1] = { argv = argv, cwd = cwd }
        pending = function()
          cb({ " M a.lua" }, 0)
        end
      end)

      local answers = 0
      for _ = 1, 5 do
        git.status("/proj", { "/proj/a.lua" }, function()
          answers = answers + 1
        end)
      end
      expect(#runs).to_be(1) -- one query out, not five

      pending()
      expect(answers).to_be(5) -- everyone answered from it
      expect(#runs).to_be(2) -- exactly one re-run for what arrived meanwhile

      pending()
      expect(#runs).to_be(2) -- and it settles
    end)

    it("keeps different repositories independent", function()
      local pending = {}
      git._set_runner(function(argv, cwd, cb)
        runs[#runs + 1] = { argv = argv, cwd = cwd }
        pending[#pending + 1] = function()
          cb({}, 0)
        end
      end)

      git.status("/one", { "/one/a.lua" }, function() end)
      git.status("/two", { "/two/a.lua" }, function() end)
      expect(#runs).to_be(2)

      for _, fn in ipairs(pending) do
        fn()
      end
    end)
  end)

  describe("paths spread over several working copies", function()
    -- A repository answers only for its own files. Measured: asked from the
    -- project, git prints nothing for a file inside one of its worktrees, which
    -- that worktree reports as modified.
    local WORKTREE = "/proj/.claude/worktrees/wt1"
    local walks

    before_each(function()
      walks = 0
      git._working_copy = function(path)
        walks = walks + 1
        if path:sub(1, #WORKTREE + 1) == WORKTREE .. "/" then
          return "git", WORKTREE
        elseif path:sub(1, 6) == "/proj/" then
          return "git", "/proj"
        elseif path:sub(1, 5) == "/svn/" then
          return "svn", "/svn"
        end
        return nil, nil
      end
    end)

    local function ask(paths, fallback)
      local answer, answers = nil, 0
      git.status_all(paths, fallback, function(status)
        answer = status
        answers = answers + 1
      end)
      expect(answers).to_be(1)
      return answer
    end

    it("asks each file's own working copy and merges the answers", function()
      respond_with(function(argv)
        -- `-C <root>` is where the question was put.
        return { argv[3] == WORKTREE and " M a.lua" or "A  b.lua" }
      end)

      local status = ask({ "/proj/b.lua", WORKTREE .. "/a.lua", "/proj/c.lua" }, "/proj")

      expect(#runs).to_be(2) -- one query per working copy, not per file
      assert.same({ "/proj/b.lua", "/proj/c.lua" }, { runs[1].argv[#runs[1].argv - 1], runs[1].argv[#runs[1].argv] })
      expect(runs[2].argv[3]).to_be(WORKTREE)
      expect(runs[2].argv[#runs[2].argv]).to_be(WORKTREE .. "/a.lua")
      expect(status[WORKTREE .. "/a.lua"]).to_be("M")
      expect(status["/proj/b.lua"]).to_be("A")
    end)

    it("asks the fallback about a file no git working copy claims", function()
      -- A `GIT_DIR` repository has no marker to find, and svn is not git's to
      -- answer for: both are asked where they always were.
      respond_with({})
      ask({ "/elsewhere/x.lua", "/svn/y.lua" }, "/proj")

      expect(#runs).to_be(1)
      expect(runs[1].argv[3]).to_be("/proj")
    end)

    it("answers with nothing when there is nowhere to ask", function()
      respond_with({})
      assert.same({}, ask({ "/elsewhere/x.lua" }, nil))
      assert.same({}, ask({}, "/proj"))
      expect(#runs).to_be(0)
    end)

    it("walks up from a directory once", function()
      expect(git.root_of("/proj/lua/a.lua")).to_be("/proj")
      expect(git.root_of("/proj/lua/b.lua")).to_be("/proj")
      expect(git.root_of("/elsewhere/x.lua")).to_be_nil()
      expect(git.root_of("/elsewhere/y.lua")).to_be_nil()
      expect(walks).to_be(2)

      git.forget_roots()
      git.root_of("/proj/lua/a.lua")
      expect(walks).to_be(3)
    end)

    it("names the directory above a path the way fnamemodify does", function()
      expect(git._parent_dir("/proj/lua/a.lua")).to_be("/proj/lua")
      expect(git._parent_dir("/a")).to_be("/")
      expect(git._parent_dir("/")).to_be("/")
      expect(git._parent_dir("D:\\Git\\proj\\a.lua")).to_be("D:\\Git\\proj")
      expect(git._parent_dir("D:\\a")).to_be("D:\\")
      expect(git._parent_dir("D:\\")).to_be("D:\\")
      expect(git._parent_dir("a.lua")).to_be(".")
    end)

    it("finds a file's working copy from a fast context, where vim.fn raises", function()
      -- `model.refresh_git` is called from the transcript fold's read callback.
      -- The specs' fake filesystem has no fast context to fail in, so this one
      -- makes every `vim.fn` call raise the way Neovim does there.
      local loop = vim.uv or vim.loop
      local real_stat, real_fn = loop.fs_stat, vim.fn
      local marks = { ["/proj/.git"] = true, [WORKTREE .. "/.git"] = true }
      loop.fs_stat = function(path)
        return marks[path] and {} or nil
      end
      package.loaded["claudecode.agents.git"] = nil
      git = require("claudecode.agents.git")
      vim.fn = setmetatable({}, {
        __index = function(_, name)
          return function()
            error("E5560: vim.fn." .. name .. " must not be called in a fast event context")
          end
        end,
      })

      local ok, kind, root = pcall(git._working_copy, WORKTREE .. "/lua/deep/a.lua")
      local ok_root, project = pcall(git.root_of, "/proj/lua/b.lua")
      local ok_none, none = pcall(git.root_of, "/elsewhere/c.lua")
      vim.fn = real_fn
      loop.fs_stat = real_stat

      expect(ok).to_be_true()
      expect(kind).to_be("git")
      -- The nearest one: a worktree is inside the repository it belongs to.
      expect(root).to_be(WORKTREE)
      expect(ok_root).to_be_true()
      expect(project).to_be("/proj")
      expect(ok_none).to_be_true()
      expect(none).to_be_nil()
    end)
  end)
end)
