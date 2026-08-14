-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.model", function()
  local model
  local summaries -- [path] = summary handed back by the stubbed transcript
  local scans -- paths passed to transcript.summary, in order
  local live -- conversations the stubbed registry reports as running
  local git_calls
  local scheduled -- pending scheduler callbacks
  local deleted -- transcripts the stubbed store was asked to remove

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
    summaries, scans, live, git_calls, scheduled, deleted = {}, {}, {}, 0, {}, {}

    package.loaded["claudecode.agents.transcript"] = {
      setup = function() end,
      cache_load = function() end,
      cache_save = function() end,
      cancel_all = function() end,
      list = function()
        local rows = {}
        for _, sum in pairs(summaries) do
          rows[#rows + 1] = { id = sum.id, path = sum.path, size = 1, mtime = sum.last_ts, summary = sum }
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
        return live[id] and { session_id = id, cwd = "/proj" } or nil
      end,
    }

    package.loaded["claudecode.agents.git"] = {
      status = function(_, _, cb)
        git_calls = git_calls + 1
        cb({})
      end,
    }
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

    it("leaves a conversation that is not working alone", function()
      model.note({ hook_event_name = "Notification", message = "needs your permission", session_id = "aaa" })
      expect(model.status_of("aaa").state).to_be("waiting")
      expect(model.note_interrupt("aaa")).to_be(false)
      expect(model.status_of("aaa").state).to_be("waiting")
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
