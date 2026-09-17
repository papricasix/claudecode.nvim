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
end)
