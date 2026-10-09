-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.model", function()
  local model
  local checkpoints
  local flags
  local summaries -- [path] = summary handed back by the stubbed transcript
  local scans -- paths passed to transcript.summary, in order
  local live -- conversations the stubbed registry reports as running
  local launch_names -- [id] = what the stubbed registry says a launch named its conversation
  local git_calls
  local git_result -- what the stubbed `git status` answers
  local scheduled -- pending scheduler callbacks
  local deleted -- transcripts the stubbed store was asked to remove
  local stale -- transcripts the stubbed store says have grown since their fold
  local elsewhere -- [id] = where the stubbed store finds a transcript the listing does not hold
  local locates -- every search of the store for one, in order
  local invalidated -- paths whose fold the model dropped
  local rehomed -- [old path] = the fold the stubbed store carries over to a moved transcript
  local git_roots -- [path] = the working copy the stubbed git says a file is in

  local function summary_for(id, fields)
    return vim.tbl_extend("force", {
      id = id,
      path = "/p/" .. id .. ".jsonl",
      title = "Title " .. id,
      cwd = "/proj",
      added = 0,
      removed = 0,
      files = {},
      order = {},
      events = {},
      last_ts = 100,
    }, fields or {})
  end

  local function stub_modules()
    summaries, scans, live, git_calls, scheduled, deleted, stale = {}, {}, {}, 0, {}, {}, {}
    git_result = {}
    elsewhere, locates, invalidated, git_roots, rehomed = {}, {}, {}, {}, {}
    launch_names = {}

    package.loaded["claudecode.agents.transcript"] = {
      setup = function() end,
      cache_load = function() end,
      cache_save = function() end,
      cancel_all = function() end,
      list = function()
        local rows = {}
        for _, sum in pairs(summaries) do
          -- Written just now unless the test says otherwise: the list reaches back
          -- a fortnight by default, and these summaries carry a token `last_ts`
          -- that is not meant to say when the file was touched.
          rows[#rows + 1] = { id = sum.id, path = sum.path, size = 1, mtime = sum.mtime or os.time(), summary = sum }
        end
        table.sort(rows, function(a, b)
          return a.id < b.id
        end)
        return rows
      end,
      summary = function(path, cb)
        scans[#scans + 1] = path
        for _, sum in pairs(summaries) do
          if sum.path == path then
            cb(sum)
            return
          end
        end
        cb(nil)
      end,
      get = function(path)
        for _, sum in pairs(summaries) do
          if sum.path == path then
            return sum
          end
        end
        return nil
      end,
      stale = function(path)
        return stale[path] == true
      end,
      delete = function(path)
        deleted[#deleted + 1] = path
        for id, sum in pairs(summaries) do
          if sum.path == path then
            summaries[id] = nil
          end
        end
        return true, nil
      end,
      events = function(path)
        for _, sum in pairs(summaries) do
          if sum.path == path then
            return sum.events
          end
        end
        return {}
      end,
      session_path = function(_, id)
        return "/p/" .. id .. ".jsonl"
      end,
      event_key = function(event)
        return event.tool_id or event.path
      end,
      -- The real rule is the transcript spec's to pin down; this only has to
      -- tell the model's two kinds of path apart.
      is_scratchpad = function(path)
        return path:find("/scratchpad/", 1, true) ~= nil
      end,
      -- Reading one back out of the directory a conversation started in is the
      -- transcript spec's too: a summary here says outright which it is in.
      worktree_of = function(sum)
        return sum and sum.worktree or nil
      end,
      -- A conversation the project's own listing does not hold, wherever else in
      -- the store a spec says the CLI has it.
      locate = function(id, hint)
        locates[#locates + 1] = { id = id, hint = hint }
        return elsewhere[id]
      end,
      invalidate = function(path)
        invalidated[#invalidated + 1] = path
      end,
      -- Whether a moved file is the one that was folded is the transcript spec's
      -- to decide; here a spec says so by naming the summary that comes along.
      rehome = function(from, to)
        local sum = rehomed[from]
        if sum then
          sum.path = to
        end
        return sum
      end,
    }

    package.loaded["claudecode.agents.registry"] = {
      is_live = function(id)
        return live[id] == true
      end,
      live_ids = function()
        local ids = {}
        for id, running in pairs(live) do
          if running then
            ids[#ids + 1] = id
          end
        end
        table.sort(ids)
        return ids
      end,
      get = function(id)
        return live[id] and { session_id = id, cwd = "/proj", name = launch_names[id] } or nil
      end,
    }

    local git = {
      status = function(_, _, cb)
        git_calls = git_calls + 1
        cb(git_result)
      end,
      forget_roots = function() end,
    }
    -- The grouping is the git spec's to pin down. Here every file is in the
    -- project unless a spec says otherwise, and `status` is looked up per call
    -- because specs replace it.
    git.status_all = function(paths, fallback, cb)
      local groups, order = {}, {}
      for _, path in ipairs(paths) do
        local root = git_roots[path] or fallback
        if not groups[root] then
          groups[root] = {}
          order[#order + 1] = root
        end
        groups[root][#groups[root] + 1] = path
      end
      local merged, waiting = {}, #order
      for _, root in ipairs(order) do
        git.status(root, groups[root], function(result)
          for key, letter in pairs(result or {}) do
            merged[key] = letter
          end
          waiting = waiting - 1
          if waiting == 0 then
            cb(merged)
          end
        end)
      end
    end
    package.loaded["claudecode.agents.git"] = git
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    stub_modules()

    package.loaded["claudecode.agents.model"] = nil
    model = require("claudecode.agents.model")
    model.setup({ agents = { enabled = true, refresh_ms = 10, fold_batch = 10 } })
    model.reset()
    model.setup({ agents = { enabled = true, refresh_ms = 10, fold_batch = 10 } })

    -- Checkpoints live in memory here: the store would otherwise be a real file
    -- under the mock's cache directory, shared between tests.
    checkpoints = require("claudecode.agents.checkpoints")
    checkpoints.reset()
    checkpoints._io = {
      read = function()
        return nil
      end,
      write = function() end,
    }

    -- Flags likewise, but theirs has to hold what it is given: the store is read
    -- back before every change, through the decoder the mock only stubs.
    vim.json.decode = _G.json_decode
    local flag_store = nil
    flags = require("claudecode.agents.flags")
    flags.reset()
    flags._io = {
      read = function()
        return flag_store
      end,
      write = function(_, data)
        flag_store = data
        return true
      end,
      stat = function()
        return flag_store
      end,
    }

    -- The vim mock runs defer_fn immediately, which would defeat every assertion
    -- about coalescing. Queue instead, and let each test decide when time passes.
    model._set_scheduler(function(fn)
      scheduled[#scheduled + 1] = fn
    end)
  end)

  local function tick()
    local pending = scheduled
    scheduled = {}
    for _, fn in ipairs(pending) do
      fn()
    end
  end

  after_each(function()
    for _, name in ipairs({ "transcript", "registry", "git" }) do
      package.loaded["claudecode.agents." .. name] = nil
    end
  end)

  describe("rows", function()
    before_each(function()
      summaries.aaa = summary_for("aaa", { added = 10, removed = 2, last_ts = 200 })
      summaries.bbb = summary_for("bbb", { added = 5, removed = 0, last_ts = 300 })
      model.attach(1, "/proj")
    end)

    it("lists the project's sessions, newest first", function()
      local rows = model.rows()
      expect(#rows).to_be(2)
      expect(rows[1].session_id).to_be("bbb")
      expect(rows[2].session_id).to_be("aaa")
    end)

    it("carries each session's counts", function()
      local rows = model.rows()
      expect(rows[2].added).to_be(10)
      expect(rows[2].removed).to_be(2)
    end)

    it("prefers the name the user renamed a session to", function()
      -- The generated title is a guess; a rename is the user saying it was wrong.
      summaries.ccc = summary_for("ccc", { name = "my-agent" })
      summaries.ddd = summary_for("ddd", { first_prompt = "do the thing" })
      summaries.ddd.title = nil
      model.attach(1, "/proj")
      local by_id = {}
      for _, row in ipairs(model.rows()) do
        by_id[row.session_id] = row
      end
      expect(by_id.ccc.title).to_be("my-agent")
      expect(by_id.aaa.title).to_be("Title aaa")
      expect(by_id.ddd.title).to_be("do the thing")
    end)

    it("marks a running agent live", function()
      live.aaa = true
      for _, row in ipairs(model.rows()) do
        if row.session_id == "aaa" then
          expect(row.live).to_be_true()
        else
          expect(row.live).to_be(false)
        end
      end
    end)

    it("lists a session that changed nothing", function()
      -- Asking a question and reading the answer is still a session, and it is
      -- still resumable.
      summaries.ccc = summary_for("ccc", { added = 0, removed = 0 })
      model.attach(1, "/proj")
      local found = false
      for _, row in ipairs(model.rows()) do
        if row.session_id == "ccc" then
          found = true
        end
      end
      expect(found).to_be_true()
    end)

    it("hides sessions that changed nothing when asked to", function()
      summaries.ccc = summary_for("ccc", { added = 0, removed = 0 })

      local function ids_now()
        local ids = {}
        for _, row in ipairs(model.rows()) do
          ids[row.session_id] = true
        end
        return ids
      end

      model.attach(1, "/proj")
      expect(ids_now().ccc).to_be_true() -- listed by default

      model.setup({ agents = { enabled = true, sessions = { include_empty = false } } })
      model.attach(1, "/proj")
      expect(ids_now().ccc).to_be(nil) -- and hidden on request
    end)

    it("lists an agent we are running that has written no transcript yet", function()
      -- The CLI creates the transcript on the first message, so a brand new agent
      -- is in no enumeration until the user talks to it — and a row is the only
      -- way back to a conversation, so without this one it becomes unreachable
      -- the moment the selection moves off it.
      live.ccc = true
      model.refresh_list()

      local by_id = {}
      for _, row in ipairs(model.rows()) do
        by_id[row.session_id] = row
      end
      expect(by_id.ccc).not_to_be_nil()
      expect(by_id.ccc.live).to_be_true()
      expect(by_id.ccc.title).to_be("New session")
      -- It has changed nothing yet, which is a fact rather than an unread count.
      expect(by_id.ccc.added).to_be(0)
      expect(by_id.ccc.removed).to_be(0)
    end)

    it("keeps such an agent selectable across a rebuild", function()
      live.ccc = true
      model.refresh_list()
      model.select("ccc")
      model.refresh_list()
      expect(model.selected()).to_be("ccc")
    end)

    it("hands it over to the enumeration once its transcript appears", function()
      live.ccc = true
      model.refresh_list()

      summaries.ccc = summary_for("ccc", { added = 3, removed = 1 })
      model.refresh_list()

      local seen = 0
      for _, row in ipairs(model.rows()) do
        if row.session_id == "ccc" then
          seen = seen + 1
          expect(row.added).to_be(3)
          expect(row.title).to_be("Title ccc")
        end
      end
      expect(seen).to_be(1)
    end)

    it("keeps the title it had while its transcript is being folded", function()
      -- The row is listed as soon as the file exists and folded moments later.
      -- Falling back to the id prefix in between is a flicker on the one row the
      -- user is watching.
      live.ccc = true
      model.refresh_list()
      -- Listed, but nothing has read it yet.
      package.loaded["claudecode.agents.transcript"].list = function()
        return { { id = "ccc", path = "/p/ccc.jsonl", size = 1, mtime = 1, summary = nil } }
      end
      model.refresh_list()
      expect(model.rows()[1].title).to_be("New session")
    end)

    it("calls such an agent what its launch named it", function()
      -- The CLI shows a `--name` in its prompt box at once and writes it with the
      -- first message; until then the launch is the only place that knows it.
      live.ccc = true
      launch_names.ccc = "plan-2"
      model.refresh_list()
      for _, row in ipairs(model.rows()) do
        if row.session_id == "ccc" then
          expect(row.title).to_be("plan-2")
        end
      end
      expect(model.row("ccc").title).to_be("plan-2")
    end)

    describe("a running conversation whose transcript is there but unread", function()
      -- What `/clear` leaves in a named session (measured against CLI 2.1.295):
      -- the new conversation's transcript is written at once, so it is listed
      -- from the directory with no fold and no row before it.
      local function list_unread(id)
        package.loaded["claudecode.agents.transcript"].list = function()
          return { { id = id, path = "/p/" .. id .. ".jsonl", size = 1, mtime = os.time(), summary = nil } }
        end
      end

      it("is called what its launch says, not by its id", function()
        live.ccc = true
        launch_names.ccc = "carried-over"
        list_unread("ccc")
        model.refresh_list()
        expect(model.rows()[1].session_id).to_be("ccc")
        expect(model.rows()[1].title).to_be("carried-over")
      end)

      it("is called what its transcript says once that has been read", function()
        live.ccc = true
        launch_names.ccc = "carried-over"
        list_unread("ccc")
        model.refresh_list()
        summaries.ccc = summary_for("ccc", { name = "renamed since" })
        model.fold_row(model.row("ccc"))
        expect(model.rows()[1].title).to_be("renamed since")
      end)

      it("keeps the title it already had over the launch's", function()
        summaries.ccc = summary_for("ccc", { name = "renamed since" })
        model.refresh_list()
        live.ccc = true
        launch_names.ccc = "plan-2"
        list_unread("ccc")
        model.refresh_list()
        expect(model.rows()[1].title).to_be("renamed since")
      end)

      it("still goes by its id when the launch has no name for it", function()
        live.ccc = true
        list_unread("ccc")
        model.refresh_list()
        expect(model.rows()[1].title).to_be("ccc")
      end)

      it("is called that wherever else in the store its transcript is", function()
        -- `/cd` puts it where the project's enumeration does not look.
        live.ccc = true
        launch_names.ccc = "carried-over"
        elsewhere.ccc = "/elsewhere/ccc.jsonl"
        model.refresh_list()
        expect(model.row("ccc").path).to_be("/elsewhere/ccc.jsonl")
        expect(model.row("ccc").title).to_be("carried-over")
      end)
    end)

    it("drops the row when the agent stops before saying anything", function()
      live.ccc = true
      model.refresh_list()
      live.ccc = nil
      model.refresh_list()
      local found = false
      for _, row in ipairs(model.rows()) do
        found = found or row.session_id == "ccc"
      end
      expect(found).to_be_false()
    end)

    it("dims the bullet of a session that is not running, not the one that is", function()
      -- `status` dims `idle`, which is right in a tabline (a tab with no Claude
      -- draws nothing at all there) and backwards here: the stopped sessions are
      -- rows on screen too, and they were the ones at full strength.
      live.aaa = true
      model.attach(1, "/proj")

      local by_id = {}
      for _, row in ipairs(model.rows()) do
        by_id[row.session_id] = row
      end
      expect(by_id.aaa.hl).to_be_nil()
      expect(by_id.bbb.hl).to_be("ClaudeCodeAgentsStopped")
    end)

    it("sorts by additions when asked", function()
      model.setup({ agents = { enabled = true, sessions = { sort = "added" } } })
      model.attach(1, "/proj")
      expect(model.rows()[1].session_id).to_be("aaa")
    end)

    it("takes the old sort names for the ones that replaced them", function()
      model.setup({ agents = { enabled = true, sessions = { sort = "title" } } })
      model.attach(1, "/proj")
      expect(model.sort_mode().key).to_be("name")
      expect(model.sort_mode().desc).to_be(false)
    end)
  end)

  describe("naming a new conversation after one", function()
    it("numbers a name on", function()
      expect(model._next_name("plan")).to_be("plan-2")
      expect(model._next_name("plan-2")).to_be("plan-3")
      expect(model._next_name("plan-9")).to_be("plan-10")
      expect(model._next_name("Fix session restoration")).to_be("Fix session restoration-2")
    end)

    it("counts only the last number", function()
      expect(model._next_name("v2-plan")).to_be("v2-plan-2")
      expect(model._next_name("a-1-2")).to_be("a-1-3")
      expect(model._next_name("plan2")).to_be("plan2-2")
    end)

    it("keeps a counter as wide as it was", function()
      expect(model._next_name("part-01")).to_be("part-02")
      expect(model._next_name("part-09")).to_be("part-10")
      expect(model._next_name("part-99")).to_be("part-100")
    end)

    it("takes a long number for a date or a ticket, not a counter", function()
      expect(model._next_name("notes-20261009")).to_be("notes-20261009-2")
      expect(model._next_name("issue-4521")).to_be("issue-4521-2")
      expect(model._next_name("issue-452")).to_be("issue-453")
    end)

    it("leaves a name that is only a number alone", function()
      expect(model._next_name("-5")).to_be("-5-2")
      expect(model._next_name("7")).to_be("7-2")
    end)

    it("steps over a name somebody already has", function()
      expect(model._next_name("plan", { ["plan-2"] = true })).to_be("plan-3")
      expect(model._next_name("plan-2", { ["plan-3"] = true, ["plan-4"] = true })).to_be("plan-5")
    end)

    it("puts a name on one line", function()
      expect(model._next_name("  two\nlines\there ")).to_be("two lines here-2")
    end)

    describe("from a listed session", function()
      before_each(function()
        summaries.aaa = summary_for("aaa", { name = "plan" })
        summaries.bbb = summary_for("bbb")
        model.attach(1, "/proj")
      end)

      it("uses what the session is listed as", function()
        expect(model.follow_up_name("aaa")).to_be("plan-2")
        -- No rename: the generated title is the name it is read by.
        expect(model.follow_up_name("bbb")).to_be("Title bbb-2")
      end)

      it("steps over the names of the other sessions in the list", function()
        summaries.ccc = summary_for("ccc", { name = "plan-2" })
        model.refresh_list()
        expect(model.follow_up_name("aaa")).to_be("plan-3")
        expect(model.follow_up_name("ccc")).to_be("plan-3")
      end)

      it("steps over one that was started and has said nothing yet", function()
        -- Asked twice in a row: the first is running under its name and has no
        -- transcript to be read from.
        live.ccc = true
        launch_names.ccc = "plan-2"
        model.refresh_list()
        expect(model.follow_up_name("aaa")).to_be("plan-3")
        expect(model.follow_up_name("ccc")).to_be("plan-3")
      end)

      it("has no name to give for a session that has none yet", function()
        live.ccc = true
        model.refresh_list()
        expect(model.follow_up_name("ccc")).to_be(nil)
      end)

      it("has none for a session that is not listed", function()
        expect(model.follow_up_name("nobody")).to_be(nil)
      end)
    end)
  end)

  describe("the name a conversation was given", function()
    before_each(function()
      summaries.aaa = summary_for("aaa", { name = "plan" })
      summaries.bbb = summary_for("bbb")
      model.attach(1, "/proj")
    end)

    it("is the rename, not the generated title", function()
      local name, known = model.given_name("aaa")
      expect(name).to_be("plan")
      expect(known).to_be_true()
    end)

    it("is known to be none for a conversation that was never named", function()
      local name, known = model.given_name("bbb")
      expect(name).to_be(nil)
      expect(known).to_be_true()
    end)

    it("is not known for a conversation with nothing written", function()
      live.ccc = true
      model.refresh_list()
      local name, known = model.given_name("ccc")
      expect(name).to_be(nil)
      expect(known).to_be(false)
    end)

    it("is not known for a conversation that is not listed", function()
      local name, known = model.given_name("nobody")
      expect(name).to_be(nil)
      expect(known).to_be(false)
    end)
  end)

  describe("a conversation that works somewhere else", function()
    -- The CLI keeps a transcript under the directory its session is in, so one
    -- that works in a git worktree — or was taken elsewhere with `/cd` — is not
    -- in the project's own directory of the store.
    local WORKTREE =
      { path = "/proj/.claude/worktrees/wt1", name = "wt1", branch = "worktree-wt1", original_cwd = "/proj" }

    local function row_of(id)
      for _, row in ipairs(model.rows()) do
        if row.session_id == id then
          return row
        end
      end
    end

    ---The project's own enumeration lists nothing: whatever is found is found
    ---some other way.
    local function list_nothing()
      package.loaded["claudecode.agents.transcript"].list = function()
        return {}
      end
    end

    it("marks a session that works in a worktree, and no other", function()
      summaries.aaa = summary_for("aaa", { worktree = WORKTREE })
      summaries.bbb = summary_for("bbb")
      model.attach(1, "/proj")

      expect(row_of("aaa").worktree.name).to_be("wt1")
      expect(row_of("bbb").worktree).to_be_nil()
      expect(model.worktree_of("aaa").branch).to_be("worktree-wt1")
      expect(model.worktree_of("bbb")).to_be_nil()
    end)

    it("does not mark the conversations of the worktree the view is itself in", function()
      -- The mark says "not here", and here every row would wear it.
      summaries.aaa = summary_for("aaa", { cwd = WORKTREE.path, worktree = WORKTREE })
      model.attach(1, WORKTREE.path)

      expect(row_of("aaa").worktree).to_be_nil()
      expect(model.worktree_of("aaa")).to_be_nil()
    end)

    it("resumes it from where it was before it entered, and names its files from the worktree", function()
      -- Started with `--worktree`, so even its first message names the worktree.
      summaries.aaa = summary_for("aaa", { cwd = WORKTREE.path, worktree = WORKTREE })
      model.attach(1, "/proj")
      model.select("aaa")

      expect(model.row("aaa").cwd).to_be("/proj")
      expect(model.selected_cwd()).to_be(WORKTREE.path)
    end)

    it("resumes one started by hand inside a worktree where it ran", function()
      -- The CLI never took it anywhere, so there is no "before" to go back to.
      summaries.aaa = summary_for("aaa", { cwd = WORKTREE.path, worktree = { path = WORKTREE.path, name = "wt1" } })
      model.attach(1, "/proj")

      expect(model.row("aaa").cwd).to_be(WORKTREE.path)
      expect(row_of("aaa").worktree.name).to_be("wt1")
    end)

    it("takes the mark off once the conversation has left the worktree", function()
      summaries.aaa = summary_for("aaa", { worktree = WORKTREE })
      model.attach(1, "/proj")
      model.select("aaa")
      expect(row_of("aaa").worktree).not_to_be_nil()

      summaries.aaa.worktree = nil
      model.refresh_list()
      expect(row_of("aaa").worktree).to_be_nil()
      expect(model.selected_cwd()).to_be("/proj")
    end)

    it("keeps the mark and the title while a moved transcript is still unread", function()
      summaries.aaa = summary_for("aaa", { worktree = WORKTREE })
      model.attach(1, "/proj")

      -- Listed where the CLI moved it, and nothing has folded it there yet.
      package.loaded["claudecode.agents.transcript"].list = function()
        return { { id = "aaa", path = "/w/aaa.jsonl", size = 1, mtime = os.time(), summary = nil } }
      end
      model.refresh_list()

      expect(row_of("aaa").worktree.name).to_be("wt1")
      expect(row_of("aaa").title).to_be("Title aaa")
    end)

    it("takes the fold along when the moved file is the one it read", function()
      -- Nothing on screen blanks and refills: the row is the row it was, and
      -- only what the CLI has appended since is left to read.
      summaries.aaa = summary_for("aaa", { added = 7 })
      model.attach(1, "/proj")
      model.select("aaa")
      rehomed["/p/aaa.jsonl"] = summaries.aaa
      -- Listed at its new place, where nothing has been folded.
      package.loaded["claudecode.agents.transcript"].list = function()
        return { { id = "aaa", path = "/w/aaa.jsonl", size = 2, mtime = os.time(), summary = nil } }
      end
      scans = {}
      model.refresh_list()

      local row = row_of("aaa")
      expect(row.added).to_be(7)
      expect(row.title).to_be("Title aaa")
      expect(model.transcript_path("aaa")).to_be("/w/aaa.jsonl")
      -- Read on from where the file now is, and never again from where it was.
      expect(#scans > 0).to_be(true)
      for _, path in ipairs(scans) do
        expect(path).to_be("/w/aaa.jsonl")
      end
    end)

    it("drops the fold of a transcript the CLI moved from under a conversation", function()
      summaries.aaa = summary_for("aaa")
      summaries.bbb = summary_for("bbb")
      model.attach(1, "/proj")
      model.select("aaa")
      assert.same({}, invalidated)

      -- Entered a worktree: the same conversation, in another directory.
      summaries.aaa.path = "/w/aaa.jsonl"
      model.refresh_list()

      assert.same({ "/p/aaa.jsonl" }, invalidated)
      expect(model.transcript_path("aaa")).to_be("/w/aaa.jsonl")
      expect(model.selected()).to_be("aaa")
    end)

    it("follows a running conversation whose transcript left the project", function()
      -- `/cd`, or a worktree a hook made somewhere else: no rule about this
      -- project names the directory, only the conversation's id does. This was a
      -- "New session" row with nothing in any pane.
      list_nothing()
      live.ccc = true
      summaries.ccc = summary_for("ccc", { path = "/elsewhere/ccc.jsonl", title = "Moved away", added = 4 })
      elsewhere.ccc = "/elsewhere/ccc.jsonl"
      model.attach(1, "/proj")

      local row = row_of("ccc")
      expect(row.title).to_be("Moved away")
      expect(row.added).to_be(4)
      expect(row.live).to_be_true()
      expect(model.transcript_path("ccc")).to_be("/elsewhere/ccc.jsonl")
    end)

    it("fills such a row in once its transcript has been read", function()
      list_nothing()
      live.ccc = true
      elsewhere.ccc = "/elsewhere/ccc.jsonl"
      local moved = summary_for("ccc", { path = "/elsewhere/ccc.jsonl", title = "Moved away", added = 4 })
      -- Found, but not folded: the store hands the summary to a fold only.
      package.loaded["claudecode.agents.transcript"].get = function()
        return nil
      end
      package.loaded["claudecode.agents.transcript"].summary = function(path, cb)
        cb(path == moved.path and moved or nil)
      end
      model.attach(1, "/proj")

      expect(row_of("ccc").title).to_be("Moved away")
      expect(row_of("ccc").added).to_be(4)
    end)

    it("does not search the store on every pass for an agent nobody has typed into", function()
      local now = 1000
      model._set_epoch_clock(function()
        return now
      end)
      list_nothing()
      live.ccc = true
      model.attach(1, "/proj")
      model.refresh_list()
      model.refresh_list()
      expect(#locates).to_be(1)
      expect(row_of("ccc").title).to_be("New session")

      now = now + 11
      model.refresh_list()
      expect(#locates).to_be(2)
    end)

    it("checks where it found one before searching again, and follows it when it moves on", function()
      list_nothing()
      live.ccc = true
      elsewhere.ccc = "/one/ccc.jsonl"
      model.attach(1, "/proj")
      expect(model.transcript_path("ccc")).to_be("/one/ccc.jsonl")

      elsewhere.ccc = "/two/ccc.jsonl"
      model.refresh_list()
      expect(locates[2].hint).to_be("/one/ccc.jsonl")
      expect(model.transcript_path("ccc")).to_be("/two/ccc.jsonl")
    end)

    it("forgets where a conversation was once its agent has stopped", function()
      list_nothing()
      live.ccc = true
      elsewhere.ccc = "/one/ccc.jsonl"
      model.attach(1, "/proj")
      live.ccc = nil
      model.refresh_list()

      expect(row_of("ccc")).to_be_nil()
      expect(next(model._state().located)).to_be_nil()
    end)

    it("asks git about each file in the working copy it is in", function()
      -- The project's repository says nothing at all about a file in a worktree.
      local inside = WORKTREE.path .. "/a.lua"
      summaries.aaa = summary_for("aaa", {
        worktree = WORKTREE,
        files = {
          ["/proj/b.lua"] = { added = 1, removed = 0, kind = "edit", last_ts = 1 },
          [inside] = { added = 2, removed = 0, kind = "edit", last_ts = 2 },
        },
        order = { "/proj/b.lua", inside },
      })
      git_roots[inside] = WORKTREE.path
      local asked = {}
      package.loaded["claudecode.agents.git"].status = function(root, paths, cb)
        asked[root] = paths
        cb({ [paths[1]] = root == "/proj" and "M" or "A" })
      end
      model._is_gone = function()
        return false
      end
      model.attach(1, "/proj")
      model.select("aaa")
      model.refresh_git(true)

      assert.same({ "/proj/b.lua" }, asked["/proj"])
      assert.same({ inside }, asked[WORKTREE.path])
      local letters = {}
      for _, entry in ipairs(model.changes()) do
        letters[entry.path] = entry.status
      end
      expect(letters["/proj/b.lua"]).to_be("M")
      expect(letters[inside]).to_be("A")
    end)
  end)

  describe("how far back the list reaches", function()
    local DAY = 24 * 60 * 60
    local NOW = 1700000000

    local function ids_now()
      local out = {}
      for _, row in ipairs(model.rows()) do
        out[row.session_id] = true
      end
      return out
    end

    before_each(function()
      model._set_epoch_clock(function()
        return NOW
      end)
      summaries.fresh = summary_for("fresh", { mtime = NOW - 2 * DAY })
      summaries.stale = summary_for("stale", { mtime = NOW - 30 * DAY })
    end)

    it("reads a count, a span, or everything", function()
      expect(model.parse_limit(30).count).to_be(30)
      expect(model.parse_limit("3d").seconds).to_be(3 * DAY)
      expect(model.parse_limit("2w").seconds).to_be(14 * DAY)
      -- A month is thirty days: the window says "about this far back", and a
      -- calendar month would mean a different span depending on when it was asked.
      expect(model.parse_limit("1m").seconds).to_be(30 * DAY)
      expect(model.parse_limit("all").seconds).to_be_nil()
      expect(model.parse_limit("all").count).to_be_nil()
      -- Anything unparseable falls back rather than erroring: this runs on a timer,
      -- and `config.validate` is where a wrong value is reported.
      expect(model.parse_limit("last tuesday").seconds).to_be(14 * DAY)
    end)

    it("lists the last fortnight by default, and counts what it left out", function()
      model.attach(1, "/proj")
      expect(ids_now().fresh).to_be_true()
      expect(ids_now().stale).to_be_nil()
      expect(model.hidden_count()).to_be(1)
    end)

    it("takes a count instead, when the config asks for one", function()
      model.setup({ agents = { enabled = true, sessions = { limit = 1 } } })
      model.attach(1, "/proj")
      -- Newest first, so the old one is what a count of one leaves out — by
      -- position rather than by age.
      expect(ids_now().fresh).to_be_true()
      expect(ids_now().stale).to_be_nil()
    end)

    it("never lets a window past the cap", function()
      model.setup({ agents = { enabled = true, sessions = { limit = "all", max = 1 } } })
      model.attach(1, "/proj")
      expect(model.hidden_count()).to_be(1)
    end)

    it("keeps a running agent listed however old its conversation is", function()
      -- The window is about finding work again, and work that is running has been
      -- found: dropping it would take away the only way back to a live terminal.
      live.stale = true
      model.attach(1, "/proj")
      expect(ids_now().stale).to_be_true()
    end)

    it("keeps the selected conversation listed", function()
      model.setup({ agents = { enabled = true, sessions = { limit = "all" } } })
      model.attach(1, "/proj")
      model.select("stale")
      model.setup({ agents = { enabled = true, sessions = { limit = "2w" } } })
      model.refresh_list()
      expect(model.selected()).to_be("stale")
      expect(ids_now().stale).to_be_true()
    end)

    it("widens and narrows on request, for as long as the view is open", function()
      model.attach(1, "/proj")
      expect(ids_now().stale).to_be_nil()

      expect(model.set_window("1m").key).to_be("1m")
      expect(ids_now().stale).to_be_true()

      expect(model.set_window("1d").label).to_be("Last day")
      expect(ids_now().fresh).to_be_nil()

      -- And the next open starts from the config again, like the sort criterion.
      model.detach()
      model.attach(1, "/proj")
      expect(model.window().key).to_be("2w")
    end)

    it("says what is in force, for the menu and the empty screen", function()
      model.attach(1, "/proj")
      expect(model.window().label).to_be("Last 2 weeks")
      model.setup({ agents = { enabled = true, sessions = { limit = 30 } } })
      expect(model.window().label).to_be("newest 30")
      expect(model.window().key).to_be_nil()
    end)

    it("holds a conversation from outside the window until it is let go", function()
      -- What a search hit needs: the panes follow a row, so a conversation you
      -- picked has to have one whether or not the window reaches it.
      model.attach(1, "/proj")
      expect(ids_now().stale).to_be_nil()

      model.pin("stale", { path = "/p/stale.jsonl", cwd = "/proj" })
      expect(ids_now().stale).to_be_true()
      expect(model.row("stale").title).to_be("Title stale")

      model.unpin("stale")
      expect(ids_now().stale).to_be_nil()
    end)

    it("lists a pinned conversation the project's own enumeration cannot see", function()
      -- A hit from another project: the row is built from what the search knew,
      -- and it is resumed in the directory that conversation ran in.
      model.attach(1, "/proj")
      model.pin("elsewhere", { path = "/other/elsewhere.jsonl", cwd = "/other" })
      expect(ids_now().elsewhere).to_be_true()
      expect(model.row("elsewhere").cwd).to_be("/other")
    end)
  end)

  describe("flags", function()
    local DAY = 24 * 60 * 60
    local NOW = 1700000000

    local function row_of(id)
      for _, row in ipairs(model.rows()) do
        if row.session_id == id then
          return row
        end
      end
      return nil
    end

    ---How often a transcript has been handed to the fold.
    local function scans_of(id)
      local count = 0
      for _, path in ipairs(scans) do
        if path == "/p/" .. id .. ".jsonl" then
          count = count + 1
        end
      end
      return count
    end

    before_each(function()
      model._set_epoch_clock(function()
        return NOW
      end)
      -- `size`/`mtime` as the fold left them, matching what the stubbed listing
      -- reports: these transcripts have not grown since.
      summaries.aaa = summary_for("aaa", { size = 1, mtime = NOW - DAY, last_reply_ts = NOW - DAY })
      summaries.bbb = summary_for("bbb", { size = 1, mtime = NOW - DAY, last_reply_ts = NOW - DAY })
      model.attach(1, "/proj")
    end)

    it("puts a flag on a row and takes it off again", function()
      expect(row_of("aaa").flag).to_be(nil)
      expect(model.flag_count()).to_be(0)

      local flag = model.toggle_flag("aaa")
      expect(flag.at).to_be(NOW)
      expect(row_of("aaa").flag.at).to_be(NOW)
      expect(row_of("bbb").flag).to_be(nil)
      expect(model.flag_count()).to_be(1)

      expect(model.toggle_flag("aaa")).to_be(nil)
      expect(row_of("aaa").flag).to_be(nil)
      expect(model.flag_count()).to_be(0)
    end)

    it("carries the note of a flag that has one", function()
      model.set_flag("aaa", "review before merging")
      expect(row_of("aaa").flag.note).to_be("review before merging")
      expect(model.flag_of("aaa").note).to_be("review before merging")
    end)

    it("survives the row being selected and read", function()
      -- The whole difference from the unread dot, which selecting clears.
      model.toggle_flag("aaa")
      model.select("aaa")
      model.poll()
      tick()
      expect(row_of("aaa").flag.at).to_be(NOW)
    end)

    it("ends a bare flag when the user answers the conversation", function()
      model.toggle_flag("aaa")
      model.select("aaa")

      summaries.aaa.last_reply_ts = NOW + 60
      model.poll()
      tick()

      expect(row_of("aaa").flag).to_be(nil)
      expect(flags.get("aaa")).to_be(nil)
    end)

    it("keeps a flag with a note through any number of replies", function()
      model.set_flag("aaa", "review before merging")
      model.select("aaa")

      summaries.aaa.last_reply_ts = NOW + 60
      model.poll()
      tick()

      expect(row_of("aaa").flag.note).to_be("review before merging")
    end)

    it("notices a reply given somewhere else, to a conversation that is neither selected nor running", function()
      -- Answered from a bare terminal or another editor. Nothing else re-reads
      -- such a row, so without this its flag would outlive the reply until the
      -- row was next selected.
      model.toggle_flag("bbb")
      model.refresh_list()
      expect(scans_of("bbb")).to_be(0) -- the transcript has not moved

      summaries.bbb.last_reply_ts = NOW + 60
      summaries.bbb.size = 0 -- as last folded; the listing now reports more
      model.refresh_list()

      expect(scans_of("bbb")).to_be(1)
      expect(row_of("bbb").flag).to_be(nil)
    end)

    it("re-reads no transcript for a flag's sake unless a reply could end it", function()
      model.set_flag("aaa", "stays whatever is said")
      summaries.aaa.size = 0
      summaries.bbb.size = 0 -- grown, but not flagged
      model.refresh_list()
      expect(scans_of("aaa")).to_be(0)
      expect(scans_of("bbb")).to_be(0)
    end)

    it("keeps a flagged conversation listed however old it is, and lets it go with the flag", function()
      -- A flag that aged out of the list would be a reminder nobody is reminded by.
      summaries.old = summary_for("old", { size = 1, mtime = NOW - 60 * DAY })
      model.refresh_list()
      expect(row_of("old")).to_be(nil)

      flags.set("old", "do not lose this", NOW)
      model.refresh_list()
      expect(row_of("old").flag.note).to_be("do not lose this")

      model.clear_flag("old")
      expect(row_of("old")).to_be(nil)
      expect(model.hidden_count()).to_be(1)
    end)

    it("takes in a flag another Neovim set, on the list's own refresh", function()
      expect(row_of("aaa").flag).to_be(nil)
      flags._io.write(nil, _G.json_encode({ version = 1, sessions = { aaa = { at = NOW, note = "from over there" } } }))
      model.refresh_list()
      expect(row_of("aaa").flag.note).to_be("from over there")
    end)

    it("sorts flagged conversations first by status, without moving them otherwise", function()
      local function ids()
        local out = {}
        for _, row in ipairs(model.rows()) do
          out[#out + 1] = row.session_id
        end
        return table.concat(out, ",")
      end
      live.aaa = true -- idle and running outranks stopped
      model.set_sort("status")
      expect(ids()).to_be("aaa,bbb")

      -- The order is frozen: a flag does not make a row jump.
      model.toggle_flag("bbb")
      expect(ids()).to_be("aaa,bbb")

      -- Until the list is sorted again, where the flag outranks any status.
      model.resort()
      expect(ids()).to_be("bbb,aaa")
    end)

    it("drops the flag of a conversation that is deleted", function()
      model.set_flag("aaa", "review")
      expect(model.delete_session("aaa")).to_be_true()
      expect(flags.get("aaa")).to_be(nil)
    end)
  end)

  describe("order", function()
    local function ids()
      local out = {}
      for _, row in ipairs(model.rows()) do
        out[#out + 1] = row.session_id
      end
      return table.concat(out, ",")
    end

    before_each(function()
      summaries.aaa = summary_for("aaa", { added = 10, removed = 2, last_ts = 200 })
      summaries.bbb = summary_for("bbb", { added = 5, removed = 0, last_ts = 300 })
      model.attach(1, "/proj")
    end)

    it("keeps a row where it is when its activity moves", function()
      expect(ids()).to_be("bbb,aaa")

      -- What the list used to do on every rebuild: aaa working in the background
      -- overtook bbb and the rows swapped under the cursor.
      model.row("aaa").last_ts = 900
      expect(ids()).to_be("bbb,aaa")
    end)

    it("sorts a new session in once, and pins it there", function()
      summaries.ccc = summary_for("ccc", { last_ts = 250 })
      model.refresh_list()
      expect(ids()).to_be("bbb,ccc,aaa")

      -- Placed by the criterion when it arrived; frozen like everything else
      -- afterwards, however far its own value moves.
      model.row("ccc").last_ts = 1
      expect(ids()).to_be("bbb,ccc,aaa")
    end)

    it("drops a conversation that is gone from the order", function()
      model.delete_session("bbb")
      expect(ids()).to_be("aaa")
      summaries.ccc = summary_for("ccc", { last_ts = 250 })
      model.refresh_list()
      expect(ids()).to_be("ccc,aaa")
    end)

    it("re-sorts on request, from the values the rows have now", function()
      model.row("aaa").last_ts = 900
      model.resort()
      expect(ids()).to_be("aaa,bbb")
    end)

    it("reverses a criterion that is picked again", function()
      expect(model.sort_mode().key).to_be("recent")
      expect(model.sort_mode().desc).to_be(true)

      local mode = model.set_sort("recent")
      expect(mode.desc).to_be(false)
      expect(ids()).to_be("aaa,bbb") -- oldest first

      model.set_sort("recent")
      expect(model.sort_mode().desc).to_be(true)
      expect(ids()).to_be("bbb,aaa")
    end)

    it("starts a criterion in its own direction, not the last one's", function()
      model.set_sort("recent") -- flipped to ascending
      model.set_sort("name")
      expect(model.sort_mode().key).to_be("name")
      expect(model.sort_mode().desc).to_be(false) -- A to Z
      expect(ids()).to_be("aaa,bbb")

      model.set_sort("changes")
      expect(model.sort_mode().desc).to_be(true) -- most first
      expect(ids()).to_be("aaa,bbb") -- 12 changed lines against 5
    end)

    it("forgets the chosen sort when the view closes", function()
      model.set_sort("name")
      model.detach()
      model.attach(1, "/proj")
      expect(model.sort_mode().key).to_be("recent")
    end)
  end)

  describe("deleting", function()
    before_each(function()
      summaries.aaa = summary_for("aaa")
      summaries.bbb = summary_for("bbb")
      model.attach(1, "/proj")
    end)

    it("removes the conversation and its row", function()
      local ok = model.delete_session("aaa")
      expect(ok).to_be_true()
      expect(deleted[1]).to_be("/p/aaa.jsonl")
      expect(model.row("aaa")).to_be(nil)
      expect(#model.rows()).to_be(1)
    end)

    it("refuses while its agent is running", function()
      live.aaa = true
      local ok, err = model.delete_session("aaa")
      expect(ok).to_be(false)
      expect(type(err)).to_be("string")
      expect(#deleted).to_be(0)
      expect(model.row("aaa")).to_be_table()
    end)

    it("clears the selection when the selected session goes", function()
      model.select("aaa")
      expect(model.delete_session("aaa")).to_be_true()
      expect(model.selected()).to_be(nil)
    end)

    it("leaves an unknown session alone", function()
      local ok = model.delete_session("nope")
      expect(ok).to_be(false)
      expect(#deleted).to_be(0)
    end)

    it("deletes a batch, and reports what it could not", function()
      -- A running agent in the batch is reported rather than aborting the rest:
      -- the caller pointed at a stretch of the list, not at one row.
      live.bbb = true
      local gone, failed = model.delete_sessions({ "aaa", "bbb", "nope" })
      expect(#gone).to_be(1)
      expect(gone[1]).to_be("aaa")
      expect(#failed).to_be(2)
      expect(failed[1].session_id).to_be("bbb")
      expect(model.row("aaa")).to_be(nil)
      expect(model.row("bbb")).to_be_table()
    end)
  end)

  describe("selection", function()
    before_each(function()
      summaries.aaa = summary_for("aaa", {
        added = 10,
        files = { ["/proj/a.lua"] = { added = 10, removed = 2, kind = "edit", last_ts = 1 } },
        order = { "/proj/a.lua" },
        events = { { ts = 1, kind = "edit", path = "/proj/a.lua", added = 10, removed = 2 } },
      })
      model.attach(1, "/proj")
    end)

    it("starts with nothing selected", function()
      expect(model.selected()).to_be(nil)
      expect(#model.feed()).to_be(0)
      expect(#model.changes()).to_be(0)
    end)

    it("keeps a running conversation selected before it has a transcript", function()
      -- A brand new agent is selected the moment it launches, and the CLI writes
      -- its transcript only on the first message: it is in no enumeration until
      -- then. Dropping the selection here left the row unmarked when it finally
      -- appeared, until the list was cycled off it and back on.
      live.fresh = true
      model.select("fresh")
      model.refresh_list()
      expect(model.selected()).to_be("fresh")

      summaries.fresh = summary_for("fresh")
      model.refresh_list()
      expect(model.selected()).to_be("fresh")
      local marked = false
      for _, row in ipairs(model.rows()) do
        if row.session_id == "fresh" then
          marked = row.selected
        end
      end
      expect(marked).to_be_true()
    end)

    it("still drops a selection whose session is gone and not running", function()
      model.select("ghost")
      model.refresh_list()
      expect(model.selected()).to_be(nil)
    end)

    it("exposes the selected session's feed and files", function()
      model.select("aaa")
      expect(model.selected()).to_be("aaa")
      expect(#model.feed()).to_be(1)
      expect(model.feed()[1].path).to_be("/proj/a.lua")
      expect(#model.changes()).to_be(1)
      expect(model.changes()[1].added).to_be(10)
    end)

    it("shows the newest activity first, and trims from the far end", function()
      -- What the agent is doing *now* is the question the pane answers, so it
      -- belongs at the top edge rather than scrolled off the bottom.
      summaries.aaa.events = {
        { ts = 1, kind = "edit", path = "/proj/first.lua" },
        { ts = 2, kind = "edit", path = "/proj/second.lua" },
        { ts = 3, kind = "edit", path = "/proj/third.lua" },
      }
      model.select("aaa")
      local feed = model.feed()
      expect(feed[1].path).to_be("/proj/third.lua")
      expect(feed[3].path).to_be("/proj/first.lua")

      model.setup({ agents = { enabled = true, feed_limit = 2 } })
      feed = model.feed()
      expect(#feed).to_be(2)
      expect(feed[1].path).to_be("/proj/third.lua") -- the oldest is what is dropped
      expect(feed[2].path).to_be("/proj/second.lua")
    end)

    it("draws a row someone holds however far new events have pushed it, and no further", function()
      -- The view keeps the Activity cursor on its row as events land above it. Cut
      -- to what the pane shows, the row fell out of the list after a screenful,
      -- and the cursor with it.
      local events = {}
      for n = 1, 10 do
        events[n] = { ts = n, kind = "tool", tool = "Bash", label = "call " .. n, tool_id = "t" .. n }
      end
      summaries.aaa.events = events
      model.select("aaa")

      expect(#model.feed(3)).to_be(3)
      local feed = model.feed(3, { t4 = true })
      expect(#feed).to_be(7)
      expect(feed[7].tool_id).to_be("t4")
      -- Held rows already on screen cost nothing extra.
      expect(#model.feed(3, { t9 = true })).to_be(3)

      -- A row that is not there at all is looked for as far as the store keeps.
      model.setup({ agents = { enabled = true, feed_limit = 6 } })
      expect(#model.feed(3, { gone = true })).to_be(6)
    end)

    describe("the activity filter", function()
      before_each(function()
        summaries.aaa.events = {
          { ts = 1, kind = "edit", path = "/proj/first.lua" },
          { ts = 2, kind = "tool", tool = "Bash", label = "run it", tool_id = "t1", status = "done" },
          { ts = 3, kind = "read", path = "/proj/second.lua" },
          { ts = 4, kind = "tool", tool = "Grep", label = "find it", tool_id = "t2", status = "done" },
        }
        model.select("aaa")
      end)

      it("shows everything until asked otherwise", function()
        expect(#model.feed()).to_be(4)
        expect(model.feed_filter()).to_be("all")
      end)

      it("cycles through files only and commands only", function()
        expect(model.cycle_feed_filter().key).to_be("files")
        local feed = model.feed()
        expect(#feed).to_be(2)
        expect(feed[1].path).to_be("/proj/second.lua")

        expect(model.cycle_feed_filter().key).to_be("tools")
        feed = model.feed()
        expect(#feed).to_be(2)
        expect(feed[1].tool).to_be("Grep")

        expect(model.cycle_feed_filter().key).to_be("all")
        expect(#model.feed()).to_be(4)
      end)

      it("keeps a rewind's rule under every filter", function()
        summaries.aaa.events[#summaries.aaa.events + 1] = { ts = 5, kind = "rewind", dropped = 3 }
        expect(model.cycle_feed_filter().key).to_be("files")
        local feed = model.feed()
        expect(#feed).to_be(3)
        expect(feed[1].kind).to_be("rewind")
        expect(model.cycle_feed_filter().key).to_be("tools")
        feed = model.feed()
        expect(#feed).to_be(3)
        expect(feed[1].kind).to_be("rewind")
      end)

      it("names subagents by what they were sent to do until switched, and forgets the switch with the view", function()
        expect(model.subagent_label()).to_be("description")
        expect(model.toggle_subagent_label()).to_be("type")
        expect(model.toggle_subagent_label()).to_be("description")
        model.toggle_subagent_label()
        model.detach()
        expect(model.subagent_label()).to_be("description")
      end)

      it("fills the pane from the whole history, not from the last few events", function()
        -- Slicing to the limit first and filtering after would show a short list
        -- of whatever happened to be at the end — with a filter on, the rows that
        -- fill the pane can come from anywhere.
        summaries.aaa.events = {
          { ts = 1, kind = "edit", path = "/proj/a.lua" },
          { ts = 2, kind = "edit", path = "/proj/b.lua" },
          { ts = 3, kind = "tool", tool = "Bash", label = "one", tool_id = "t1" },
          { ts = 4, kind = "tool", tool = "Bash", label = "two", tool_id = "t2" },
          { ts = 5, kind = "tool", tool = "Bash", label = "three", tool_id = "t3" },
        }
        model.cycle_feed_filter() -- files
        local feed = model.feed(2)
        expect(#feed).to_be(2)
        expect(feed[1].path).to_be("/proj/b.lua")
      end)
    end)

    it("marks a file in the CLI's scratchpad, and only that one", function()
      local pad = "/tmp/claude-501/-proj/0b3c2f4e-1a2b-4c3d-8e9f-0123456789ab/scratchpad/probe.lua"
      summaries.aaa.files[pad] = { added = 5, removed = 0, kind = "add", last_ts = 2 }
      table.insert(summaries.aaa.order, pad)
      model.select("aaa")

      local marked = {}
      for _, e in ipairs(model.changes()) do
        marked[e.path] = e.scratchpad
      end
      expect(marked[pad]).to_be_true()
      expect(marked["/proj/a.lua"]).to_be_false()
    end)

    it("leaves reads out of the changed-files list", function()
      summaries.aaa.files["/proj/read.lua"] = { added = 0, removed = 0, kind = "read", last_ts = 1 }
      table.insert(summaries.aaa.order, "/proj/read.lua")
      model.select("aaa")
      expect(#model.changes()).to_be(1)
    end)

    it("reports the directory the session actually ran in", function()
      summaries.aaa.cwd = "/elsewhere"
      model.attach(1, "/proj")
      model.select("aaa")
      expect(model.selected_cwd()).to_be("/elsewhere")
    end)

    describe("a changed file that is no longer on disk", function()
      local gone

      before_each(function()
        gone = {}
        model._is_gone = function(path)
          return gone[path] == true
        end
        summaries.aaa.files["/proj/scratch.lua"] = { added = 40, removed = 0, kind = "add", last_ts = 2 }
        table.insert(summaries.aaa.order, "/proj/scratch.lua")
        model.select("aaa")
      end)

      local function entry(path)
        for _, e in ipairs(model.changes()) do
          if e.path == path then
            return e
          end
        end
      end

      it("is marked deleted even though git never tracked it", function()
        -- Created and then removed by the session: git has nothing to say about
        -- it, and the transcript alone still calls it an add.
        gone["/proj/scratch.lua"] = true
        model.refresh_git(true)

        local e = entry("/proj/scratch.lua")
        expect(e.deleted).to_be_true()
        expect(e.status).to_be("D")
        expect(e.added).to_be(40) -- the session's work still counts
        expect(entry("/proj/a.lua").deleted).to_be_false()
        expect(entry("/proj/a.lua").status).to_be("M")
      end)

      it("takes git's D for a tracked file", function()
        git_result = { ["/proj/a.lua"] = "D" }
        model.refresh_git(true)
        expect(entry("/proj/a.lua").deleted).to_be_true()
      end)

      it("checks the disk with git turned off", function()
        model.setup({ agents = { enabled = true, refresh_ms = 10, git = false } })
        gone["/proj/scratch.lua"] = true
        model.refresh_git(true)
        expect(entry("/proj/scratch.lua").deleted).to_be_true()
        expect(git_calls).to_be(0)
      end)

      it("is noticed when the conversation moves, whatever tool removed it", function()
        -- A shell `rm` is not one of the editing tools, and polling reports no
        -- tool at all: the transcript moving is the signal.
        tick()
        model._state().git_at = nil
        local before = git_calls
        gone["/proj/scratch.lua"] = true
        summaries.aaa.last_ts = 200
        model.note({ hook_event_name = "PostToolUse", tool_name = "Bash", session_id = "aaa" })
        tick()

        expect(git_calls).to_be(before + 1)
        expect(entry("/proj/scratch.lua").deleted).to_be_true()
      end)

      it("asks once more when a request lands inside the rate gate", function()
        model.refresh_git(true)
        local before = git_calls
        gone["/proj/scratch.lua"] = true
        model.refresh_git()
        expect(git_calls).to_be(before)
        model.refresh_git() -- a second request inside the gate queues nothing more
        expect(#scheduled).to_be(1)

        model._state().git_at = nil
        tick()
        expect(git_calls).to_be(before + 1)
        expect(entry("/proj/scratch.lua").deleted).to_be_true()
      end)
    end)
  end)

  describe("how old the panes say a row is", function()
    local clock

    before_each(function()
      clock = 10000
      model._set_clock(function()
        return clock
      end)
      summaries.aaa = summary_for("aaa", {
        added = 10,
        removed = 2,
        files = { ["/proj/a.lua"] = { added = 10, removed = 2, kind = "edit", last_ts = 1 } },
        order = { "/proj/a.lua" },
        events = { { ts = 1, kind = "edit", path = "/proj/a.lua" } },
      })
      model.attach(1, "/proj")
      model.select("aaa")
    end)

    it("stamps a backfilled feed as already old, not as news", function()
      -- Everything a session already did arrives in one batch when you select it.
      -- Treating that as new would light the whole pane up at once. The fixture's
      -- events are from 1970, so "old" here means very old indeed.
      local _, ages = model.feed()
      expect(ages[1] > 60000).to_be_true()
    end)

    it("keeps a *recent* backfilled row fresh, however you arrived at it", function()
      -- Declaring the whole backfill infinitely old made the pane read as
      -- permanently dim: switching session and back re-backfills, so an edit from
      -- a second ago went grey the moment you looked away and returned.
      table.insert(summaries.aaa.events, { ts = os.time() - 1, kind = "edit", path = "/proj/just.lua" })
      summaries.bbb = summary_for("bbb")
      model.refresh_list()
      model.select("bbb")
      model.select("aaa")

      local feed, ages = model.feed()
      expect(feed[1].path).to_be("/proj/just.lua")
      expect(ages[1] < 3000).to_be_true()
      -- And the genuinely old rows beside it are still old.
      expect(ages[2] > 60000).to_be_true()
    end)

    it("ages a row from when it first appeared, not from its timestamp", function()
      model.feed() -- the backfill
      table.insert(summaries.aaa.events, { ts = 2, kind = "edit", path = "/proj/b.lua" })
      local feed, ages = model.feed()
      expect(feed[1].path).to_be("/proj/b.lua")
      expect(ages[1]).to_be(0)
      clock = clock + 450
      expect(select(2, model.feed())[1]).to_be(450)
      -- The row that was already there stays old.
      expect(select(2, model.feed())[2] > 60000).to_be_true()
    end)

    it("keeps a row's age across a redraw that changes nothing", function()
      model.feed()
      table.insert(summaries.aaa.events, { ts = 2, kind = "read", path = "/proj/c.lua" })
      model.feed()
      clock = clock + 100
      expect(select(2, model.feed())[1]).to_be(100)
      clock = clock + 100
      expect(select(2, model.feed())[1]).to_be(200)
    end)

    it("forgets what it has seen when the selection moves", function()
      model.feed()
      summaries.bbb = summary_for("bbb", {
        events = { { ts = 5, kind = "edit", path = "/proj/other.lua" } },
      })
      model.refresh_list()
      model.select("bbb")
      -- Another conversation's history is not this one's activity.
      expect(select(2, model.feed())[1] > 60000).to_be_true()
    end)

    it("does not call a count new the first time it sees one", function()
      -- Opening the view would otherwise flash every number in it.
      local row = model.rows()[1]
      expect(row.added_age_ms).to_be(nil)
      expect(row.removed_age_ms).to_be(nil)
      expect(model.changes()[1].added_age_ms).to_be(nil)
    end)

    it("times a count from the moment it moved", function()
      model.rows()
      summaries.aaa.added = 25
      model.refresh_list()
      local row = model.rows()[1]
      expect(row.added).to_be(25)
      expect(row.added_age_ms).to_be(0)
      -- Only the count that moved is news.
      expect(row.removed_age_ms).to_be(nil)
      clock = clock + 700
      expect(model.rows()[1].added_age_ms).to_be(700)
    end)

    it("times a changed file's count the same way", function()
      model.changes()
      summaries.aaa.files["/proj/a.lua"].removed = 9
      local entry = model.changes()[1]
      expect(entry.removed_age_ms).to_be(0)
      expect(entry.added_age_ms).to_be(nil)
    end)
  end)

  describe("an agent moving to another conversation", function()
    before_each(function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
    end)

    it("forgets what the abandoned conversation was doing", function()
      -- /clear leaves the terminal running and swaps the chat underneath it. The
      -- old conversation is not mid-tool any more; leaving its entry alone left a
      -- spinner on a row nothing was going to report about again.
      model.note({ hook_event_name = "UserPromptSubmit", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("busy")

      model.note_session_change("aaa", "bbb")
      expect(model.status_of("aaa")).to_be(nil)
    end)

    it("says whether the selection was pointing at the old conversation", function()
      model.select("aaa")
      expect(model.note_session_change("aaa", "bbb")).to_be_true()
      expect(model.note_session_change("zzz", "yyy")).to_be(false)
    end)

    it("lists the new conversation from the registry before it has a transcript", function()
      -- The CLI writes nothing until the first message, so this is the whole
      -- window in which the running agent would otherwise be off the list.
      live.bbb = true
      model.note_session_change("aaa", "bbb")
      model.refresh_list()

      local by_id = {}
      for _, row in ipairs(model.rows()) do
        by_id[row.session_id] = row
      end
      expect(by_id.bbb).to_be_table()
      expect(by_id.bbb.live).to_be_true()
      expect(by_id.aaa.live).to_be(false)
    end)
  end)

  describe("interrupting an agent", function()
    before_each(function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
    end)

    it("drops a busy conversation to idle", function()
      -- Pressing <Esc> fires no Claude Code hook at all (measured against the
      -- real CLI), so without this the row spins for ever.
      model.note({ hook_event_name = "UserPromptSubmit", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("busy")
      expect(model.note_interrupt("aaa")).to_be_true()
      expect(model.status_of("aaa").state).to_be("idle")
    end)

    it("does not let an old marker end the turn running now", function()
      -- The transcript keeps every interrupt the conversation ever had, so the
      -- marker being present says nothing on its own. Reported as an agent's
      -- spinner freezing whenever its counts updated: a tool finishing re-reads
      -- the transcript, an interrupt from an hour ago fired again, and `busy`
      -- dropped to `idle` until the next hook event.
      summaries.aaa.interrupted_ts = os.time() - 3600
      model.note({ hook_event_name = "UserPromptSubmit", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("busy")

      model.select("aaa")
      tick()
      expect(model.status_of("aaa").state).to_be("busy")
    end)

    it("keeps track of markers it has acted on across a list refresh", function()
      -- `refresh_list` replaces every row table, so anything remembered *on the
      -- row* is forgotten every couple of seconds and the same marker fires for
      -- ever. This is that bug: the state has to be keyed by conversation.
      summaries.aaa.interrupted_ts = os.time() - 3600
      model.select("aaa")
      tick()

      for _ = 1, 3 do
        model.note({ hook_event_name = "UserPromptSubmit", session_id = "aaa" })
        expect(model.status_of("aaa").state).to_be("busy")
        model.refresh_list()
        model.poll({})
        tick()
        expect(model.status_of("aaa").state).to_be("busy")
      end
    end)

    it("ends a turn the marker is newer than", function()
      model.note({ hook_event_name = "UserPromptSubmit", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("busy")
      -- The cancel happened after this turn started, so it is this turn's.
      summaries.aaa.interrupted_ts = os.time() + 5
      model.select("aaa")
      tick()
      expect(model.status_of("aaa").state).to_be("idle")
    end)

    it("takes down a question the conversation dismissed", function()
      -- <Esc> on AskUserQuestion is the same keypress, just as silent.
      model.note({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("waiting")
      expect(model.note_interrupt("aaa")).to_be_true()
      expect(model.status_of("aaa").state).to_be("idle")
    end)

    it("reads a dismissal off a marker newer than the question", function()
      model.note({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion", session_id = "aaa" })
      summaries.aaa.interrupted_ts = os.time() + 5
      model.select("aaa")
      tick()
      expect(model.status_of("aaa").state).to_be("idle")
    end)

    it("leaves a subagent's question, and a finished conversation, alone", function()
      model.note({ hook_event_name = "PermissionRequest", tool_name = "Bash", agent_id = "a1", session_id = "aaa" })
      expect(model.note_interrupt("aaa")).to_be(false)
      expect(model.status_of("aaa").state).to_be("waiting")

      model.note({ hook_event_name = "Stop", session_id = "bbb" })
      expect(model.note_interrupt("bbb")).to_be(false)
      expect(model.note_interrupt("unknown")).to_be(false)
    end)
  end)

  describe("coalescing", function()
    before_each(function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
    end)

    it("turns a burst of events into one pass", function()
      for _ = 1, 20 do
        model.request_refresh()
      end
      expect(#scheduled).to_be(1)
    end)

    it("arms again after the pass runs", function()
      model.request_refresh()
      tick()
      model.request_refresh()
      expect(#scheduled).to_be(1)
    end)
  end)

  describe("hook events", function()
    before_each(function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      scans = {}
    end)

    it("records per-conversation state, not per tab", function()
      -- Several agents share the view's tab, so a tab-keyed state would be
      -- whichever agent fired last.
      model.note({ hook_event_name = "PreToolUse", tool_name = "Bash", session_id = "aaa" })
      model.note({ hook_event_name = "Notification", message = "needs permission", session_id = "bbb" })

      expect(model.status_of("aaa").state).to_be("busy")
      expect(model.status_of("bbb").state).to_be("waiting")
    end)

    it("counts a finished turn as read only for the session on screen", function()
      model.select("aaa")
      model.note({ hook_event_name = "Stop", session_id = "aaa" })
      model.note({ hook_event_name = "Stop", session_id = "bbb" })

      expect(model.status_of("aaa").state).to_be("idle")
      expect(model.status_of("bbb").state).to_be("done")
    end)

    it("counts a finished turn as unread when the view's tab is not the current one", function()
      -- The selected agent is usually the one being waited on, so its answer
      -- arriving while the user works in another tab is exactly the case the
      -- unread marker exists for.
      model.select("aaa")
      _G.vim._current_tabpage = 2
      model.note({ hook_event_name = "Stop", session_id = "aaa" })
      _G.vim._current_tabpage = 1

      expect(model.status_of("aaa").state).to_be("done")
    end)

    it("counts a finished turn as unread when Neovim itself has no focus", function()
      local status = require("claudecode.status")
      model.select("aaa")
      status.set_focused(false)
      model.note({ hook_event_name = "Stop", session_id = "aaa" })
      -- Restored before asserting: `focused` lives on the module, and the module
      -- is shared with every test after this one.
      status.set_focused(true)

      expect(model.status_of("aaa").state).to_be("done")
    end)

    it("marks a finished answer read when its session is selected", function()
      model.note({ hook_event_name = "Stop", session_id = "bbb" })
      expect(model.status_of("bbb").state).to_be("done")

      expect(model.mark_read("bbb")).to_be_true()
      expect(model.status_of("bbb").state).to_be("idle")
    end)

    it("marks a finished answer read by selecting it", function()
      -- <CR> on the row and <C-n>/<C-p> onto it both land here.
      model.note({ hook_event_name = "Stop", session_id = "bbb" })
      model.select("bbb")

      expect(model.status_of("bbb").state).to_be("idle")
    end)

    it("keeps a conversation's question up while its background subagent works", function()
      -- The reported bug: an agent asked, a subagent it had started in the
      -- background kept calling tools under the same session id, and the row
      -- spun as busy for as long as the question was on screen.
      model.note({ hook_event_name = "PreToolUse", tool_name = "AskUserQuestion", session_id = "aaa" })
      model.note({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion", session_id = "aaa" })
      model.note({ hook_event_name = "PreToolUse", tool_name = "Bash", agent_id = "a1", session_id = "aaa" })
      model.note({ hook_event_name = "PostToolUse", tool_name = "Bash", agent_id = "a1", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("waiting")

      model.note({ hook_event_name = "PostToolUse", tool_name = "AskUserQuestion", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("busy")
    end)

    it("keeps a question up when the agent it launched in the same message returns", function()
      -- The second report: a background Agent and AskUserQuestion issued in one
      -- message. The launch returning is a PostToolUse from the thread that
      -- asked, and it took the question down the instant it went up.
      local status = require("claudecode.status")
      local function hook(event)
        event.session_id = "aaa"
        status.identify(event)
        model.note(event)
      end
      hook({ hook_event_name = "PreToolUse", tool_name = "Agent", tool_use_id = "toolu_agent" })
      hook({ hook_event_name = "PreToolUse", tool_name = "AskUserQuestion", tool_use_id = "toolu_ask" })
      hook({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion" })
      hook({ hook_event_name = "PostToolUse", tool_name = "Agent", tool_use_id = "toolu_agent" })
      hook({ hook_event_name = "Notification", message = "Claude needs your permission" })
      hook({ hook_event_name = "PreToolUse", tool_name = "Bash", tool_use_id = "toolu_b", agent_id = "a1" })
      expect(model.status_of("aaa").state).to_be("waiting")

      hook({ hook_event_name = "PostToolUse", tool_name = "AskUserQuestion", tool_use_id = "toolu_ask" })
      expect(model.status_of("aaa").state).to_be("busy")
    end)

    it("never clears waiting by reading it", function()
      -- Looking at a question is not answering it.
      model.note({ hook_event_name = "Notification", message = "needs permission", session_id = "bbb" })
      model.select("bbb")

      expect(model.mark_read("bbb")).to_be_false()
      expect(model.status_of("bbb").state).to_be("waiting")
    end)

    it("re-reads the transcript when a tool finishes, not when it starts", function()
      -- The transcript's record of a tool is written when the tool returns.
      -- Drain the read that selecting a session legitimately asks for first, so
      -- what is left measures only what the hook event caused.
      model.select("aaa")
      model.request_refresh()
      tick()
      scans = {}

      model.note({ hook_event_name = "PreToolUse", tool_name = "Edit", session_id = "aaa" })
      tick()
      expect(#scans).to_be(0)

      model.note({ hook_event_name = "PostToolUse", tool_name = "Edit", session_id = "aaa" })
      tick()
      expect(#scans > 0).to_be_true()
    end)

    it("does not ask git anything about a read", function()
      model.select("aaa")
      git_calls = 0
      model.note({ hook_event_name = "PostToolUse", tool_name = "Read", session_id = "aaa" })
      tick()
      expect(git_calls).to_be(0)
    end)

    it("asks git after a write", function()
      summaries.aaa.files["/proj/a.lua"] = { added = 1, removed = 0, kind = "edit", last_ts = 1 }
      summaries.aaa.order = { "/proj/a.lua" }
      model.select("aaa")
      git_calls = 0
      model.note({ hook_event_name = "PostToolUse", tool_name = "Edit", session_id = "aaa" })
      tick()
      expect(git_calls).to_be(1)
    end)

    it("ignores an event with no conversation id", function()
      local ok = pcall(model.note, { hook_event_name = "Stop" })
      expect(ok).to_be_true()
      expect(model.status_of(nil)).to_be(nil)
    end)

    it("keeps a background agent's counts moving", function()
      -- The selected session is not the only one that matters: an agent working
      -- in the background must not show stale numbers when you look back at it.
      summaries.bbb = summary_for("bbb")
      model.attach(1, "/proj")
      live.bbb = true
      model.select("aaa")
      scans = {}

      model.note({ hook_event_name = "PostToolUse", tool_name = "Edit", session_id = "bbb" })
      tick()

      local scanned_bbb = false
      for _, path in ipairs(scans) do
        if path == "/p/bbb.jsonl" then
          scanned_bbb = true
        end
      end
      expect(scanned_bbb).to_be_true()
    end)
  end)

  describe("filling in the list", function()
    it("keeps folding until every session has its counts", function()
      -- Regression: folding only ran from refresh_list, so after the first batch
      -- the rest of the list kept placeholder counts and no title until something
      -- happened to re-enumerate -- which made it look as though opening a
      -- session was what updated the list.
      model.setup({ agents = { enabled = true, fold_batch = 1 } })
      for _, id in ipairs({ "aaa", "bbb", "ccc", "ddd" }) do
        summaries[id] = summary_for(id, { added = 1, partial = true })
      end
      model.attach(1, "/proj")

      -- Nothing selects a session and no hook event arrives; the drain is the
      -- only thing that can finish the job.
      for _ = 1, 10 do
        for _, sum in pairs(summaries) do
          sum.partial = nil
        end
        tick()
      end

      -- `rows()` exposes counts, not fold state: an unread session is one whose
      -- counts are still nil, which is exactly what the placeholder draws.
      local unread = 0
      for _, row in ipairs(model.rows()) do
        if row.added == nil then
          unread = unread + 1
        end
      end
      expect(unread).to_be(0)
    end)

    it("stops asking for a transcript that cannot be read", function()
      -- Otherwise the drain would come back to it forever.
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      local row = model.row("aaa")
      row.folded = false
      summaries.aaa = nil -- the file went away mid-scan

      model.fold_row(row)
      expect(row.fold_failed).to_be_true()

      scans = {}
      for _ = 1, 5 do
        tick()
      end
      expect(#scans).to_be(0)
    end)
  end)

  describe("polling", function()
    it("marks the transcript dirty without a hook in sight", function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      model.select("aaa")
      scans = {}

      model.poll()
      tick()

      expect(#scans > 0).to_be_true()
    end)

    it("re-enumerates the project, so a session started elsewhere shows up", function()
      -- Hooks report what a running agent does; they say nothing about a
      -- conversation started in another tab, another editor or a bare terminal.
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      expect(#model.rows()).to_be(1)

      summaries.bbb = summary_for("bbb")
      model.poll({ list_only = true })
      tick()

      expect(#model.rows()).to_be(2)
    end)

    it("re-reads the selected transcript when the file has grown, even in hooks mode", function()
      -- A hook says a tool returned; the CLI may write its line a beat later, or
      -- the hook may never arrive. The panes are drawn from the file, so the
      -- file is what the tick has to ask about — a stat, not a read.
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      model.select("aaa")
      model.request_refresh()
      tick() -- drain the read that selecting legitimately asks for
      scans = {}

      model.poll({ list_only = true })
      tick()
      expect(#scans).to_be(0)

      stale["/p/aaa.jsonl"] = true
      model.poll({ list_only = true })
      tick()
      expect(scans[1]).to_be("/p/aaa.jsonl")
    end)

    it("enumerates even when it is told not to read transcripts", function()
      summaries.aaa = summary_for("aaa")
      model.attach(1, "/proj")
      model.select("aaa")
      model.request_refresh()
      tick() -- drain the read that selecting legitimately asks for
      scans = {}

      model.poll({ list_only = true })
      tick()

      -- The list was refreshed, but no transcript was re-read for it.
      local reread_selected = false
      for _, path in ipairs(scans) do
        if path == "/p/aaa.jsonl" then
          reread_selected = true
        end
      end
      expect(reread_selected).to_be(false)
    end)
  end)

  describe("checkpoints", function()
    before_each(function()
      summaries.aaa = summary_for("aaa", {
        added = 30,
        removed = 6,
        files = {
          ["/proj/a.lua"] = {
            added = 30,
            removed = 6,
            kind = "edit",
            last_ts = 30,
            edits = {
              { ts = 10, added = 10, removed = 2, kind = "edit" },
              { ts = 20, added = 5, removed = 1, kind = "edit" },
              { ts = 30, added = 15, removed = 3, kind = "edit" },
            },
          },
          ["/proj/new.lua"] = {
            added = 4,
            removed = 0,
            kind = "add",
            last_ts = 25,
            edits = { { ts = 25, added = 4, removed = 0, kind = "add" } },
          },
          ["/proj/read.lua"] = { added = 0, removed = 0, kind = "read", last_ts = 12, edits = {} },
        },
        order = { "/proj/a.lua", "/proj/new.lua", "/proj/read.lua" },
        events = {
          { ts = 10, kind = "edit", path = "/proj/a.lua" },
          { ts = 20, kind = "edit", path = "/proj/a.lua" },
          { ts = 25, kind = "add", path = "/proj/new.lua" },
          { ts = 30, kind = "edit", path = "/proj/a.lua" },
        },
      })
      model.attach(1, "/proj")
      model.select("aaa")
    end)

    it("lists a file once per era it was edited in, with that era's own counts", function()
      checkpoints.add("aaa", 20)
      local rows = model.changes()
      local drawn = {}
      for _, row in ipairs(rows) do
        if row.kind == "checkpoint" then
          drawn[#drawn + 1] = "── " .. row.ts
        else
          drawn[#drawn + 1] =
            string.format("%s +%d -%d (%d/%d)", row.path, row.added, row.removed, row.era.index, row.era.count)
        end
      end
      -- Newest era on top, the rule under it, the file edited on both sides twice.
      assert.same({
        "/proj/a.lua +15 -3 (2/1)",
        "/proj/new.lua +4 -0 (2/1)",
        "── 20",
        "/proj/a.lua +15 -3 (1/1)",
      }, drawn)
      expect(rows[1].era.from).to_be(20)
      expect(rows[1].era.to).to_be(nil)
      expect(rows[4].era.to).to_be(20)
    end)

    it("stacks: each checkpoint splits again", function()
      checkpoints.add("aaa", 10)
      checkpoints.add("aaa", 22)
      local drawn = {}
      for _, row in ipairs(model.changes()) do
        drawn[#drawn + 1] = row.kind == "checkpoint" and ("──" .. row.ts) or (row.path .. " +" .. row.added)
      end
      assert.same(
        { "/proj/a.lua +15", "/proj/new.lua +4", "──22", "/proj/a.lua +5", "──10", "/proj/a.lua +10" },
        drawn
      )
    end)

    it("draws a rule at the top when nothing has happened since it", function()
      checkpoints.add("aaa", 100)
      local rows = model.changes()
      expect(rows[1].kind).to_be("checkpoint")
      expect(#rows).to_be(3)
    end)

    it("keeps the whole conversation's counts on the session row", function()
      checkpoints.add("aaa", 20)
      expect(model.rows()[1].added).to_be(30)
      expect(model.rows()[1].removed).to_be(6)
    end)

    it("dates a file's totals by its last touch when there is no per-edit record", function()
      summaries.aaa.files["/proj/a.lua"].edits = nil
      checkpoints.add("aaa", 20)
      local drawn = {}
      for _, row in ipairs(model.changes()) do
        drawn[#drawn + 1] = row.kind == "checkpoint" and "──" or (row.path .. " +" .. row.added)
      end
      assert.same({ "/proj/a.lua +30", "/proj/new.lua +4", "──" }, drawn)
    end)

    it("lists every file once with no checkpoint, as before", function()
      local rows = model.changes()
      expect(#rows).to_be(2)
      expect(rows[1].era).to_be(nil)
    end)

    it("slots a rule into the activity feed where the checkpoint falls", function()
      checkpoints.add("aaa", 25)
      local kinds = {}
      for _, event in ipairs(model.feed()) do
        kinds[#kinds + 1] = event.kind == "checkpoint" and ("──" .. event.ts) or (event.kind .. event.ts)
      end
      -- Newest first: the add at 25 is at or before the checkpoint, so below it.
      assert.same({ "edit30", "──25", "add25", "edit20", "edit10" }, kinds)
    end)

    it("puts a checkpoint newer than everything at the top of the feed", function()
      checkpoints.add("aaa", 100)
      local feed = model.feed()
      expect(feed[1].kind).to_be("checkpoint")
      expect(#feed).to_be(5)
    end)

    it("leaves a rule older than the rows drawn out of a feed cut to the pane", function()
      checkpoints.add("aaa", 5)
      local cut = model.feed(2)
      expect(#cut).to_be(2)
      expect(cut[2].kind).to_be("add")
      -- Drawn whole, the rule sits at the bottom where it belongs.
      local whole = model.feed()
      expect(whole[#whole].kind).to_be("checkpoint")
    end)

    it("hands the feed the same rule table each time, so it settles like any row", function()
      checkpoints.add("aaa", 25)
      local first = model.feed()[2]
      expect(first.kind).to_be("checkpoint")
      expect(model.feed()[2]).to_be(first)
    end)

    it("forgets a deleted conversation's checkpoints", function()
      checkpoints.add("aaa", 20)
      expect(model.delete_session("aaa")).to_be_true()
      expect(#checkpoints.list("aaa")).to_be(0)
    end)

    it("carries a checkpoint's name on its rule in every pane", function()
      checkpoints.add("aaa", 20)
      checkpoints.set_name("aaa", 20, "reviewed")
      expect(model.changes()[3].name).to_be("reviewed")
      -- Newest first: the add at 25 is above the rule, so the rule is row 3.
      expect(model.feed()[3].name).to_be("reviewed")
      -- Renamed later: the kept Activity row follows the store.
      checkpoints.set_name("aaa", 20, "again")
      expect(model.feed()[3].name).to_be("again")
    end)

    it("asks git and the disk about each file once, and never about a rule", function()
      -- The rule row has no path, and `fs_stat(nil)` threw from the poll timer.
      local stats, git_paths = {}, nil
      model._is_gone = function(path)
        stats[#stats + 1] = path
        return false
      end
      package.loaded["claudecode.agents.git"].status = function(_, paths, cb)
        git_paths = paths
        cb({})
      end
      checkpoints.add("aaa", 20)
      model.refresh_git(true)
      assert.same({ "/proj/a.lua", "/proj/new.lua" }, stats)
      assert.same({ "/proj/a.lua", "/proj/new.lua" }, git_paths)
    end)
  end)

  describe("change notifications", function()
    it("tells its listeners when something moved", function()
      summaries.aaa = summary_for("aaa")
      local calls = 0
      model.on_change("spec", function()
        calls = calls + 1
      end)
      model.attach(1, "/proj")
      expect(calls > 0).to_be_true()
    end)
  end)
end)
