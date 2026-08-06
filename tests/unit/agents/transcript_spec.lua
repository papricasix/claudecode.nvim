-- luacheck: globals expect
require("tests.busted_setup")

describe("agents.transcript", function()
  local transcript

  -- In-memory transcript store. The parser only ever reaches the filesystem
  -- through `_io`, so a spec can model growth, truncation and replacement
  -- exactly — and every read is synchronous, which keeps the assertions free of
  -- event-loop timing.
  local fs, dirs, reads, decodes, removed

  local function install_io()
    transcript._io = {
      stat = function(path)
        local f = fs[path]
        if not f then
          return nil
        end
        return { size = #f.data, mtime = f.mtime, ino = f.ino }
      end,
      scandir = function(dir)
        return dirs[dir]
      end,
      remove = function(path)
        local existed = fs[path] ~= nil or dirs[path] ~= nil
        removed[#removed + 1] = path
        fs[path] = nil
        dirs[path] = nil
        return existed
      end,
      read = function(path, offset, len, cb)
        local f = fs[path]
        if not f then
          cb(nil, "ENOENT")
          return
        end
        reads[#reads + 1] = { offset = offset, len = len }
        cb(f.data:sub(offset + 1, offset + len), nil)
      end,
      read_sync = function(path, len)
        local f = fs[path]
        return f and f.data:sub(1, len) or nil
      end,
    }
  end

  ---Write a transcript, or replace one (a new inode models a rewrite).
  local function put(path, lines, opts)
    opts = opts or {}
    local data = #lines > 0 and (table.concat(lines, "\n") .. (opts.no_eol and "" or "\n")) or ""
    fs[path] = { data = data, mtime = opts.mtime or 1, ino = opts.ino or 1 }
  end

  local function append(path, lines, opts)
    opts = opts or {}
    local f = fs[path]
    f.data = f.data .. table.concat(lines, "\n") .. "\n"
    f.mtime = opts.mtime or (f.mtime + 1)
  end

  ---Fold synchronously (the fake `_io` never defers) and hand back the summary.
  local function fold(path)
    local result, called = nil, false
    transcript.summary(path, function(sum)
      result = sum
      called = true
    end)
    assert.is_true(called, "summary() did not answer synchronously")
    return result
  end

  --- Fixture lines -----------------------------------------------------------

  local function edit_line(file, plus, minus, ts)
    local lines = {}
    for _ = 1, plus do
      lines[#lines + 1] = "+added"
    end
    for _ = 1, minus do
      lines[#lines + 1] = "-gone"
    end
    lines[#lines + 1] = " context"
    return vim.json.encode({
      type = "user",
      timestamp = ts or "2026-08-02T20:19:59.000Z",
      toolUseResult = {
        filePath = file,
        oldString = "a",
        newString = "b",
        structuredPatch = { { oldStart = 1, oldLines = 1, newStart = 1, newLines = 1, lines = lines } },
      },
    })
  end

  local function write_create_line(file, content, ts)
    return vim.json.encode({
      type = "user",
      timestamp = ts or "2026-08-02T20:20:00.000Z",
      toolUseResult = {
        filePath = file,
        content = content,
        type = "create",
        structuredPatch = {},
      },
    })
  end

  local function read_line(file, ts)
    return vim.json.encode({
      type = "user",
      timestamp = ts or "2026-08-02T20:21:00.000Z",
      toolUseResult = {
        type = "text",
        file = { filePath = file, content = "irrelevant", numLines = 3, startLine = 1, totalLines = 3 },
      },
    })
  end

  local function bash_line()
    return vim.json.encode({
      type = "user",
      timestamp = "2026-08-02T20:22:00.000Z",
      toolUseResult = { stdout = "lots of output", stderr = "", interrupted = false, isImage = false },
    })
  end

  local function title_line(title)
    return vim.json.encode({ type = "ai-title", aiTitle = title, sessionId = "s" })
  end

  local function name_line(name)
    return vim.json.encode({ type = "agent-name", agentName = name, sessionId = "s" })
  end

  local function prompt_line(text)
    return vim.json.encode({
      type = "user",
      cwd = "/proj",
      gitBranch = "main",
      timestamp = "2026-08-02T20:00:00.000Z",
      message = { role = "user", content = text },
    })
  end

  before_each(function()
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end
    fs, dirs, reads, decodes, removed = {}, {}, {}, 0, {}

    -- The mock's vim.json.decode is a non-functional stub; the busted setup ships
    -- a real one. Count calls so the "Bash results are never decoded" claim can
    -- actually be asserted rather than assumed.
    local real_decode = _G.json_decode
    vim.json.decode = function(str)
      decodes = decodes + 1
      return real_decode(str)
    end

    package.loaded["claudecode.agents.transcript"] = nil
    transcript = require("claudecode.agents.transcript")
    transcript.reset()
    install_io()
  end)

  describe("line counting", function()
    it("sums + and - lines across structuredPatch hunks", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 5, 2), edit_line("/proj/y.lua", 3, 0) })
      local sum = fold("/p/a.jsonl")
      expect(sum.added).to_be(8)
      expect(sum.removed).to_be(2)
    end)

    it("counts a created file's content, since its patch is empty", function()
      -- A Write that creates a file records `structuredPatch: []` — there is no
      -- "before" to diff. Without the content fallback every new file reads +0.
      put("/p/a.jsonl", { write_create_line("/proj/new.lua", "one\ntwo\nthree\n") })
      local sum = fold("/p/a.jsonl")
      expect(sum.added).to_be(3)
      expect(sum.removed).to_be(0)
      expect(sum.files["/proj/new.lua"].kind).to_be("add")
    end)

    it("counts a final line with no trailing newline", function()
      put("/p/a.jsonl", { write_create_line("/proj/new.lua", "one\ntwo") })
      expect(fold("/p/a.jsonl").added).to_be(2)
    end)

    it("records reads without counting them as changes", function()
      put("/p/a.jsonl", { read_line("/proj/z.lua") })
      local sum = fold("/p/a.jsonl")
      expect(sum.added).to_be(0)
      expect(sum.files["/proj/z.lua"].kind).to_be("read")
      expect(#sum.events).to_be(1)
      expect(sum.events[1].kind).to_be("read")
    end)

    it("does not let a later read downgrade an edited file", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0), read_line("/proj/x.lua") })
      expect(fold("/p/a.jsonl").files["/proj/x.lua"].kind).to_be("edit")
    end)
  end)

  describe("prefiltering", function()
    it("never decodes a Bash result", function()
      put("/p/a.jsonl", { bash_line(), bash_line(), bash_line() })
      local sum = fold("/p/a.jsonl")
      expect(decodes).to_be(0)
      expect(sum.added).to_be(0)
      expect(#sum.events).to_be(0)
    end)

    it("skips a malformed line without failing the fold", function()
      put("/p/a.jsonl", { '{"toolUseResult":{"structuredPatch": THIS IS NOT JSON', edit_line("/proj/x.lua", 2, 0) })
      local sum = fold("/p/a.jsonl")
      expect(sum.skipped).to_be(1)
      expect(sum.added).to_be(2)
    end)
  end)

  describe("deleting", function()
    it("removes the transcript, its sidecar directory and its cached fold", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      dirs["/p/a"] = { "tool-results" } -- the CLI parks tool results beside the log
      expect(fold("/p/a.jsonl").added).to_be(1)

      local ok = transcript.delete("/p/a.jsonl")
      expect(ok).to_be_true()
      expect(fs["/p/a.jsonl"]).to_be(nil)
      expect(dirs["/p/a"]).to_be(nil)
      expect(transcript.get("/p/a.jsonl")).to_be(nil)
    end)

    it("reports a failure rather than pretending the session is gone", function()
      local ok, err = transcript.delete("/p/never-existed.jsonl")
      expect(ok).to_be(false)
      expect(type(err)).to_be("string")
      -- The sidecar is only attempted once the transcript itself is gone.
      expect(#removed).to_be(1)
    end)
  end)

  describe("metadata", function()
    it("takes the last ai-title", function()
      put("/p/a.jsonl", { title_line("first guess"), edit_line("/proj/x.lua", 1, 0), title_line("settled title") })
      expect(fold("/p/a.jsonl").title).to_be("settled title")
    end)

    it("takes the last agent-name a rename wrote", function()
      -- Renaming writes its own entry and only sometimes rewrites `aiTitle`, so the
      -- name has to be read on its own or most renames stay invisible.
      put("/p/a.jsonl", { title_line("generated"), name_line("my-agent"), name_line("my-agent-2") })
      local sum = fold("/p/a.jsonl")
      expect(sum.name).to_be("my-agent-2")
      expect(sum.title).to_be("generated")
    end)

    it("falls back to the first user message, and learns cwd and branch", function()
      put("/p/a.jsonl", { prompt_line("do the thing"), prompt_line("and another") })
      local sum = fold("/p/a.jsonl")
      expect(sum.title).to_be(nil)
      expect(sum.first_prompt).to_be("do the thing")
      expect(sum.cwd).to_be("/proj")
      expect(sum.git_branch).to_be("main")
    end)

    it("dates the session from any timestamped entry, not only tool results", function()
      -- A conversation that only ran Bash produces no events at all, so dating it
      -- from those would put it in 1970 and sort it last for ever (measured on a
      -- real session). Still no decoding: the timestamp is matched out of the raw
      -- line, so the Bash prefilter holds.
      put("/p/a.jsonl", { bash_line() })
      local sum = fold("/p/a.jsonl")
      expect(#sum.events).to_be(0)
      expect(sum.last_ts).to_be(transcript._iso_to_epoch("2026-08-02T20:22:00.000Z"))
      expect(decodes).to_be(0)
    end)

    it("keeps the newest timestamp, and untimestamped bookkeeping cannot move it", function()
      -- The CLI appends entries with no timestamp (`last-prompt`) days after the
      -- last message; the file's mtime follows them, which is why the sort cannot.
      put("/p/a.jsonl", {
        edit_line("/proj/x.lua", 1, 0, "2026-08-02T10:00:00.000Z"),
        read_line("/proj/x.lua", "2026-08-02T11:00:00.000Z"),
        vim.json.encode({ type = "last-prompt", lastPrompt = "later, but undated" }),
      })
      expect(fold("/p/a.jsonl").last_ts).to_be(transcript._iso_to_epoch("2026-08-02T11:00:00.000Z"))
    end)

    it("notices the CLI's record that the user cancelled a turn", function()
      -- Pressing <Esc> fires no Claude Code hook at all (measured against the
      -- real CLI), so this entry is the only report of an interrupt there is.
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      expect(fold("/p/a.jsonl").interrupted_ts).to_be(nil)

      put("/p/b.jsonl", {
        edit_line("/proj/x.lua", 1, 0),
        vim.json.encode({
          type = "user",
          message = { role = "user", content = "[Request interrupted by user]" },
          timestamp = "2026-08-02T21:00:00.000Z",
        }),
      })
      expect(fold("/p/b.jsonl").interrupted_ts ~= nil).to_be_true()

      -- The tool variant carries a suffix, hence the prefix match.
      put("/p/c.jsonl", {
        vim.json.encode({
          type = "user",
          message = { role = "user", content = "[Request interrupted by user for tool use]" },
          timestamp = "2026-08-02T21:00:00.000Z",
        }),
      })
      expect(fold("/p/c.jsonl").interrupted_ts ~= nil).to_be_true()
    end)

    it("does not mistake a conversation that merely mentions the marker", function()
      -- A transcript of writing this very code quotes the string. Checking for
      -- `"type":"user"` is *not* enough to tell them apart, and this is the case
      -- that proved it on real data: tool results are `user` entries too, so a
      -- Bash result quoting the marker matched both substrings and the whole
      -- conversation read as cancelled. The CLI writes the marker as the entire
      -- message content; a quoting result has it buried in a longer text.
      put("/p/a.jsonl", {
        vim.json.encode({
          type = "assistant",
          message = { role = "assistant", content = "the marker is [Request interrupted by user]" },
          timestamp = "2026-08-02T21:00:00.000Z",
        }),
        vim.json.encode({
          type = "user",
          message = {
            role = "user",
            content = {
              {
                type = "text",
                text = "grep output: an action (e.g. [Request interrupted by user]) appears after a command",
              },
            },
          },
          timestamp = "2026-08-02T21:01:00.000Z",
        }),
      })
      expect(fold("/p/a.jsonl").interrupted_ts).to_be(nil)
    end)

    it("reads the marker out of a content-block message, as the CLI writes it", function()
      -- The real shape, copied from the one genuine interrupt in this repo's
      -- store: `content` is a list holding a single text block.
      put("/p/a.jsonl", {
        vim.json.encode({
          type = "user",
          message = { role = "user", content = { { type = "text", text = "[Request interrupted by user]" } } },
          timestamp = "2026-08-02T21:00:00.000Z",
        }),
      })
      expect(fold("/p/a.jsonl").interrupted_ts ~= nil).to_be_true()
    end)

    it("derives the session id from the filename", function()
      put("/p/9f3c2b1a-0000-4000-8000-000000000000.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      expect(fold("/p/9f3c2b1a-0000-4000-8000-000000000000.jsonl").id).to_be("9f3c2b1a-0000-4000-8000-000000000000")
    end)

    it("converts UTC timestamps without applying the local offset", function()
      -- 2026-08-02T20:19:59Z. Computed rather than handed to os.time, which would
      -- read the fields as local time and shift every event.
      expect(transcript._iso_to_epoch("2026-08-02T20:19:59.373Z")).to_be(1785701999)
      expect(transcript._iso_to_epoch("1970-01-01T00:00:00.000Z")).to_be(0)
      expect(transcript._iso_to_epoch("nonsense")).to_be(0)
    end)
  end)

  describe("incremental folding", function()
    it("reads only the appended bytes on a second pass", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 5, 1) })
      local first = fold("/p/a.jsonl")
      expect(first.added).to_be(5)
      local consumed = first.offset

      reads = {}
      append("/p/a.jsonl", { edit_line("/proj/y.lua", 2, 0) })
      local second = fold("/p/a.jsonl")

      expect(second.added).to_be(7)
      expect(second.removed).to_be(1)
      expect(#reads > 0).to_be_true()
      expect(reads[1].offset).to_be(consumed)
    end)

    it("does not re-read at all when nothing changed", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 3, 0) })
      fold("/p/a.jsonl")
      reads = {}
      local again = fold("/p/a.jsonl")
      expect(#reads).to_be(0)
      expect(again.added).to_be(3)
    end)

    it("stops the offset at the last complete line", function()
      -- A transcript caught mid-write ends in a partial line. Advancing past it
      -- would drop that entry forever, so the offset stays at the last newline
      -- and the line is re-read once it is complete.
      local whole = edit_line("/proj/x.lua", 4, 0)
      put("/p/a.jsonl", { whole }, { no_eol = false })
      fs["/p/a.jsonl"].data = fs["/p/a.jsonl"].data .. '{"toolUseResult":{"structured'
      local sum = fold("/p/a.jsonl")
      expect(sum.added).to_be(4)
      expect(sum.offset).to_be(#whole + 1)

      -- Completing the line makes it count, exactly once.
      fs["/p/a.jsonl"].data = fs["/p/a.jsonl"].data:sub(1, #whole + 1) .. edit_line("/proj/y.lua", 6, 0) .. "\n"
      fs["/p/a.jsonl"].mtime = 2
      expect(fold("/p/a.jsonl").added).to_be(10)
    end)

    it("reparses from scratch when the file shrank", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 5, 0), edit_line("/proj/y.lua", 5, 0) })
      expect(fold("/p/a.jsonl").added).to_be(10)
      -- A compaction rewrote it shorter; extending the old offset would count
      -- the surviving entries a second time.
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 5, 0) }, { mtime = 2 })
      expect(fold("/p/a.jsonl").added).to_be(5)
    end)

    it("reparses from scratch when the inode changed", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 5, 0) })
      expect(fold("/p/a.jsonl").added).to_be(5)
      -- Same size, new file: a write-temp-and-rename replacement.
      put("/p/a.jsonl", { edit_line("/proj/z.lua", 5, 0) }, { mtime = 2, ino = 99 })
      local sum = fold("/p/a.jsonl")
      expect(sum.added).to_be(5)
      expect(sum.files["/proj/x.lua"]).to_be(nil)
    end)

    it("forgets a transcript that disappeared", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      fold("/p/a.jsonl")
      fs["/p/a.jsonl"] = nil
      expect(fold("/p/a.jsonl")).to_be(nil)
      expect(transcript.get("/p/a.jsonl")).to_be(nil)
    end)
  end)

  describe("chunking", function()
    it("folds a transcript larger than one chunk", function()
      transcript._chunk_size = 4096
      local lines = {}
      for _ = 1, 60 do
        lines[#lines + 1] = edit_line("/proj/x.lua", 3, 1)
      end
      put("/p/big.jsonl", lines)
      expect(#fs["/p/big.jsonl"].data > transcript._chunk_size).to_be_true()

      local sum = fold("/p/big.jsonl")
      expect(sum.added).to_be(180)
      expect(sum.removed).to_be(60)
      expect(#reads > 1).to_be_true()
    end)

    it("folds a single line longer than one chunk", function()
      -- One Read result can be hundreds of KB. A chunk with no line boundary in
      -- it must pull the rest of the line rather than spin on the same bytes.
      transcript._chunk_size = 4096
      local huge = string.rep("x", 8 * 1024)
      put(
        "/p/big.jsonl",
        { write_create_line("/proj/huge.lua", "a\nb\n") .. string.rep(" ", 0), read_line("/proj/" .. huge) }
      )
      local sum = fold("/p/big.jsonl")
      expect(sum.added).to_be(2)
      expect(sum.files["/proj/" .. huge].kind).to_be("read")
    end)
  end)

  describe("events", function()
    it("keeps events in order with their own counts", function()
      put("/p/a.jsonl", {
        read_line("/proj/x.lua", "2026-08-02T20:00:00.000Z"),
        edit_line("/proj/x.lua", 4, 1, "2026-08-02T20:01:00.000Z"),
        write_create_line("/proj/n.lua", "a\nb\n", "2026-08-02T20:02:00.000Z"),
      })
      local sum = fold("/p/a.jsonl")
      expect(#sum.events).to_be(3)
      expect(sum.events[1].kind).to_be("read")
      expect(sum.events[2].kind).to_be("edit")
      expect(sum.events[2].added).to_be(4)
      expect(sum.events[2].removed).to_be(1)
      expect(sum.events[3].kind).to_be("add")
      expect(sum.last_ts).to_be(transcript._iso_to_epoch("2026-08-02T20:02:00.000Z"))
    end)

    it("trims to the configured limit", function()
      transcript.setup({ agents = { feed_limit = 5 } })
      local lines = {}
      for _ = 1, 40 do
        lines[#lines + 1] = read_line("/proj/x.lua")
      end
      put("/p/a.jsonl", lines)
      local sum = fold("/p/a.jsonl")
      expect(#sum.events <= 10).to_be_true()
      expect(#sum.events >= 5).to_be_true()
    end)

    it("carries the window a read covered, so it can be shown later", function()
      put("/p/a.jsonl", { read_line("/proj/x.lua") })
      local sum = fold("/p/a.jsonl")
      expect(sum.events[1].start_line).to_be(1)
      expect(sum.events[1].num_lines).to_be(3)
    end)

    it("records touched files in first-touch order", function()
      put("/p/a.jsonl", {
        edit_line("/proj/b.lua", 1, 0),
        edit_line("/proj/a.lua", 1, 0),
        edit_line("/proj/b.lua", 1, 0),
      })
      local sum = fold("/p/a.jsonl")
      expect(#sum.order).to_be(2)
      expect(sum.order[1]).to_be("/proj/b.lua")
      expect(sum.order[2]).to_be("/proj/a.lua")
      expect(sum.files["/proj/b.lua"].added).to_be(2)
    end)
  end)

  describe("file history", function()
    ---`file_history` always answers through `vim.schedule`; the mock runs that
    ---immediately, so this stays synchronous.
    local function history(transcript_path, file)
      local result, called = nil, false
      transcript.file_history(transcript_path, file, function(hist)
        result, called = hist, true
      end)
      assert.is_true(called, "file_history() did not answer")
      return result
    end

    it("collects every hunk for one file, and only that file", function()
      put("/p/a.jsonl", {
        edit_line("/proj/x.lua", 2, 1),
        edit_line("/proj/other.lua", 9, 9),
        edit_line("/proj/x.lua", 1, 0),
      })
      local hist = history("/p/a.jsonl", "/proj/x.lua")
      expect(#hist.hunks).to_be(2)
      expect(hist.created).to_be_false()
    end)

    it("marks a file the session created, which has no patch to diff", function()
      put("/p/a.jsonl", { write_create_line("/proj/new.lua", "a\nb\n") })
      local hist = history("/p/a.jsonl", "/proj/new.lua")
      expect(hist.created).to_be_true()
      expect(#hist.hunks).to_be(0)
      expect(hist.content).to_be("a\nb\n")
    end)

    it("collects the windows the session read", function()
      put("/p/a.jsonl", { read_line("/proj/x.lua"), read_line("/proj/x.lua") })
      local hist = history("/p/a.jsonl", "/proj/x.lua")
      expect(#hist.reads).to_be(2)
      expect(hist.reads[1].start_line).to_be(1)
      expect(hist.reads[1].num_lines).to_be(3)
    end)

    it("never decodes a Bash result", function()
      put("/p/a.jsonl", { bash_line(), edit_line("/proj/x.lua", 1, 0) })
      local before = decodes
      history("/p/a.jsonl", "/proj/x.lua")
      expect(decodes - before).to_be(1)
    end)

    it("re-reads only when the transcript changed", function()
      put("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      history("/p/a.jsonl", "/proj/x.lua")
      local before = #reads
      history("/p/a.jsonl", "/proj/x.lua")
      expect(#reads).to_be(before) -- cached

      append("/p/a.jsonl", { edit_line("/proj/x.lua", 1, 0) })
      local hist = history("/p/a.jsonl", "/proj/x.lua")
      expect(#reads > before).to_be_true()
      expect(#hist.hunks).to_be(2)
    end)

    it("answers nil for a transcript that is not there", function()
      expect(history("/p/missing.jsonl", "/proj/x.lua")).to_be_nil()
    end)
  end)

  describe("single flight", function()
    it("shares one scan between concurrent callers", function()
      -- Defer the reads so both calls are in flight at once.
      local queue = {}
      local base = transcript._io.read
      transcript._io.read = function(path, offset, len, cb)
        queue[#queue + 1] = function()
          base(path, offset, len, cb)
        end
      end

      put("/p/a.jsonl", { edit_line("/proj/x.lua", 3, 0) })
      local answers = 0
      transcript.summary("/p/a.jsonl", function()
        answers = answers + 1
      end)
      transcript.summary("/p/a.jsonl", function()
        answers = answers + 1
      end)

      expect(#queue).to_be(1) -- one scan, not two
      while #queue > 0 do
        local next_read = table.remove(queue, 1)
        next_read()
      end
      expect(answers).to_be(2) -- both callers answered
    end)
  end)

  describe("list", function()
    it("enumerates a project's transcripts newest first", function()
      vim._mock.add_dir("/home/user/.claude/projects")
      vim._mock.add_dir("/home/user/.claude/projects/-proj")
      dirs["/home/user/.claude/projects/-proj"] = { "old.jsonl", "new.jsonl", "notes.txt" }
      put("/home/user/.claude/projects/-proj/old.jsonl", { edit_line("/proj/x.lua", 1, 0) }, { mtime = 10 })
      put("/home/user/.claude/projects/-proj/new.jsonl", { edit_line("/proj/y.lua", 1, 0) }, { mtime = 20 })

      local rows = transcript.list("/proj")
      expect(#rows).to_be(2)
      expect(rows[1].id).to_be("new")
      expect(rows[2].id).to_be("old")
    end)

    it("is empty when the project has no transcript directory", function()
      vim._mock.add_dir("/home/user/.claude/projects")
      expect(#transcript.list("/nope")).to_be(0)
    end)

    it("slugifies a path the way the CLI names its directories", function()
      expect(transcript.slugify("/Users/m/Dev/claudecode.nvim")).to_be("-Users-m-Dev-claudecode-nvim")
      expect(transcript.slugify("/Users/m/.dotfiles")).to_be("-Users-m--dotfiles")
      expect(transcript.slugify("D:\\proj")).to_be("D--proj")
    end)

    -- Every expectation here was produced by running the CLI's own rule (read out
    -- of the 2.1.222 binary) in node, not by reading this implementation.
    it("cuts a slug past 200 characters and appends the CLI's hash", function()
      local long = "D:\\Git\\" .. string.rep("verylongdirectoryname", 12) .. "\\proj"
      local slug = transcript.slugify(long)
      expect(#slug).to_be(200 + 1 + 6)
      expect(slug:sub(1, 12)).to_be("D--Git-veryl")
      expect(slug:sub(201)).to_be("-qnqb13")
    end)

    it("counts a non-ASCII character the way JavaScript does", function()
      -- The CLI substitutes one dash per UTF-16 code unit, so a two-byte `ö` is
      -- one dash and an astral emoji is two. Counting Lua's bytes would name a
      -- directory that does not exist.
      expect(transcript.slugify("/Users/m/Gr\195\182\195\159e/pro\240\159\152\128j")).to_be("-Users-m-Gr--e-pro--j")
    end)

    it("strips a trailing separator without eating a root", function()
      expect(transcript._trim_separator("D:\\proj\\")).to_be("D:\\proj")
      expect(transcript._trim_separator("/a/b/")).to_be("/a/b")
      expect(transcript._trim_separator("D:\\")).to_be("D:\\")
      expect(transcript._trim_separator("/")).to_be("/")
    end)

    it("finds a Windows project directory", function()
      -- `fnamemodify(cwd, ":p")` appends a separator and the CLI slugifies a path
      -- that has none, so a trailing backslash used to make every Windows lookup
      -- miss: `D--proj-` against the CLI's `D--proj`.
      vim._mock.add_dir("/home/user/.claude/projects")
      vim._mock.add_dir("/home/user/.claude/projects/D--proj")
      dirs["/home/user/.claude/projects/D--proj"] = { "a.jsonl" }
      put("/home/user/.claude/projects/D--proj/a.jsonl", { edit_line("D:\\proj\\x.lua", 1, 0) })

      expect(transcript.project_dir("D:\\proj\\")).to_be("/home/user/.claude/projects/D--proj")
      expect(#transcript.list("D:\\proj\\")).to_be(1)
    end)

    it("falls back to the transcript's own cwd when the slug misses", function()
      -- The fallback used to ask the asynchronous reader and treat "no answer
      -- yet" as "no match", so it could never fire at all.
      vim._mock.add_dir("/home/user/.claude/projects")
      vim._mock.add_dir("/home/user/.claude/projects/renamed-by-a-future-cli")
      dirs["/home/user/.claude/projects"] = { "renamed-by-a-future-cli" }
      dirs["/home/user/.claude/projects/renamed-by-a-future-cli"] = { "a.jsonl" }
      fs["/home/user/.claude/projects/renamed-by-a-future-cli/a.jsonl"] = {
        data = '{"type":"user","cwd":"/proj","timestamp":"2026-01-01T00:00:00.000Z"}\n',
        mtime = 1,
        ino = 1,
      }

      expect(transcript.project_dir("/proj")).to_be("/home/user/.claude/projects/renamed-by-a-future-cli")
    end)

    it("matches a Windows cwd through JSON's escaping of its separators", function()
      vim._mock.add_dir("/home/user/.claude/projects")
      vim._mock.add_dir("/home/user/.claude/projects/opaque")
      dirs["/home/user/.claude/projects"] = { "opaque" }
      dirs["/home/user/.claude/projects/opaque"] = { "a.jsonl" }
      fs["/home/user/.claude/projects/opaque/a.jsonl"] = {
        data = '{"type":"user","cwd":"D:\\\\proj"}\n',
        mtime = 1,
        ino = 1,
      }

      expect(transcript.project_dir("D:\\proj\\")).to_be("/home/user/.claude/projects/opaque")
    end)
  end)

  describe("cancellation", function()
    it("stops an in-flight scan", function()
      transcript._chunk_size = 4096
      local queue = {}
      local base = transcript._io.read
      transcript._io.read = function(path, offset, len, cb)
        queue[#queue + 1] = function()
          base(path, offset, len, cb)
        end
      end

      local lines = {}
      for _ = 1, 60 do
        lines[#lines + 1] = edit_line("/proj/x.lua", 3, 0)
      end
      put("/p/big.jsonl", lines)

      local answered = false
      transcript.summary("/p/big.jsonl", function()
        answered = true
      end)
      table.remove(queue, 1)() -- first chunk lands
      transcript.cancel_all()
      while #queue > 0 do
        table.remove(queue, 1)()
      end
      expect(answered).to_be_true() -- callers are always answered, never stranded
      expect(transcript.get("/p/big.jsonl").added < 180).to_be_true()
    end)
  end)
end)
