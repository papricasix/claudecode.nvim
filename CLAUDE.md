# CLAUDE.md

Context for Claude Code when working with this codebase.

## Project Overview

claudecode.nvim — Neovim plugin implementing the same WebSocket-based MCP protocol as Anthropic's official IDE extensions. Pure Lua, zero dependencies.

## Common Development Commands

### Testing

- `mise run test` — run all tests (busted, with coverage)
- `busted tests/unit/specific_spec.lua` — run one test file

### Code Quality

- `mise run check` — Lua syntax + luacheck (0 warnings required)
- `mise run format` — treefmt
- `luacheck lua/ tests/ --no-unused-args --no-max-line-length`

### Build

- `mise run all` — **RECOMMENDED**: format, lint, test. Always run before committing.
- `mise run clean` — remove generated test files
- `mise tasks` — list tasks

### Toolchain (mise)

Toolchain comes from [mise](https://mise.jdx.dev) (`mise.toml`); it replaced the former Nix flake devShell.

- `mise install` — install tools (Neovim, LuaJIT, formatters)
- `mise run setup` — build test rocks (busted/luacheck/luacov) into `./.luarocks`
- Activate mise in your shell (`eval "$(mise activate fish)"`) so its tools and `fixtures/bin` are on PATH. `mise run <task>` works without activation.
- `mise` sets `LUA_PATH`/`LUA_CPATH` (`mise.toml` `[env]`). Module-not-found in tests usually means busted ran outside the mise env — use `mise exec -- busted ...`.

### Integration Fixtures

`fixtures/` holds test Neovim configs. `source fixtures/nvim-aliases.sh` enables:

- `vv <config>` / `vve <config>` — start Neovim with a fixture config
- `list-configs` — list available configs

Available: `netrw`, `nvim-tree`, `oil`, `mini-files`.

## Architecture Overview

### Core Components

1. **WebSocket Server** (`lua/claudecode/server/`) — pure `vim.loop`, RFC 6455 compliant.
2. **MCP Tool System** (`lua/claudecode/tools/`) — tools Claude can execute.
3. **Lock File System** (`lua/claudecode/lockfile.lua`) — discovery files at `~/.claude/ide/`.
4. **Selection Tracking** (`lua/claudecode/selection.lua`).
5. **Diff Integration** (`lua/claudecode/diff.lua`).
6. **Terminal Integration** (`lua/claudecode/terminal.lua`) — internal and external terminals.
7. **Live Cursor** (`lua/claudecode/live_cursor.lua`) — opt-in ride-along view.
8. **Plan View** (`lua/claudecode/plan_view.lua`) — opt-in plan-mode rendering.
9. **Terminal Links** (`lua/claudecode/terminal_links.lua`) — on by default.
10. **Session Persistence** (`lua/claudecode/session_state.lua`) — opt-in.
11. **Per-Tab Status** (`lua/claudecode/status.lua`) — opt-in.
12. **Agents Mode** (`lua/claudecode/agents_view.lua`, `lua/claudecode/agents/*.lua`) — opt-in.
13. **Floating Windows** (`lua/claudecode/float.lua`).

---

### 3. Lock Files

- Lock deleted on `VimLeavePre`; a crash never reaches it, so `cleanup_stale()` sweeps once per Neovim (from `setup`, before any server claims a port).
- The directory is shared with other editors and users, so the sweep is deliberately timid: `uv.kill(pid, 0)`, and **only an explicit `ESRCH` counts as dead**. `EPERM` = alive but owned by someone else. Unparseable or pid-less locks are left alone. (Erring toward "alive" leaks a file; erring the other way deletes a live editor's lock.)
- Discovery reaches these files only when `CLAUDE_CODE_SSE_PORT` is unset (our server failed to start), in which case the CLI may attach to _another_ editor — hence `terminal.lua` logs an error rather than launching silently in that state.

### 5. Diff Integration

- The unified (inline) provider scrolls the change into view with `center_diff_region`.
- `_measure_diff_region` reads unified.nvim's extmarks for the changed line span **plus deleted lines**, which are virtual lines and therefore invisible to a plain `zz`.
- `_diff_scroll_position` centers the change when it fits the window, else pins its first changed line — with deleted lines above it, via `topfill` — to the top. Applied with `winrestview`; `topfill` is the only way to keep leading virtual lines on screen.
- Shared with the live cursor's edit preview, which renders the same marks.

### 7. Live Cursor

- Injects a `PreToolUse` hook at launch via `claude --settings` (user settings untouched). Hook is `scripts/live_cursor_hook.lua` run as `nvim --headless -u NONE -l` — no shell or POSIX tools, so macOS/Linux/native Windows behave identically.
- Hook reads event JSON from stdin, `sockconnect`s to `CLAUDECODE_NVIM_SERVER`, forwards to `live_cursor.ingest`, stamped with `CLAUDECODE_NVIM_TAB` (launching tabpage, so background-tab Claudes don't preview in the current tab) and, for agents-mode launches, `CLAUDECODE_AGENT_ID` (names the **launch**, not the conversation — see 12).
- `Read` → highlight the read line range. `Edit` → real inline diff via unified.nvim (`show_diff` reconstructs the pre-edit file, calls `unified.diff.show_against_text`); falls back to a line highlight without unified.nvim.
- `Write` → `show_write`. The hook fires _before_ the tool runs, so a file being created does not exist yet; opening the path would show an empty buffer that never fills in. Render `tool_input.content` directly, diffed against the pre-write content: `""` for a new file, else the on-disk text **snapshotted synchronously in `dispatch`** (a deferred read would see the already-written file). Without unified.nvim the content is shown undiffed.
- All snippet/content text goes through `split_lines`, which strips the CR of a CRLF file and the trailing empty element — baselines come from `readfile()`, which already dropped them, so otherwise every line of a Windows file mismatches.
- Suppressed when a review diff owns the file (`diff.is_live_for_file`); the diff calls `live_cursor.on_diff_opened` the instant it opens, dismissing any in-flight preview. Without this the preview and diff fight over one window and can leave the diff's `acwrite` buffer unable to accept with `:w` (`E676`). `diff.find_main_editor_window` skips the preview split (`claudecode_live_preview` window var).
- Target window: `diff.find_window_closest_to_terminal`, falling back to `find_main_editor_window`.
- **Buffer hygiene**: previewed files opened with `bufadd`/`bufload`; buffers we created are tracked in `state.owned_bufs` (gated on a pre-`bufadd` `bufexists` check, so a file you already had open is never owned) and reaped by `reap_owned` on every `show`/`show_diff`/`show_write`, on idle-close, on `on_diff_opened`, and on `cleanup`. Displayed, currently-active (`last_buf`), or modified buffers are left alone (`force=false`) and retried later; `last_buf` is cleared when the inactivity timer fires and in `on_diff_opened`, so the last file of a burst is reaped too.
- **Preview marker leakage**: Neovim remembers window-local options per (window, buffer) pair, so a window that once wore the preview `winbar` re-applies it when that buffer returns. Three guards:
  - `apply_preview_marker` snapshots the window's own `winbar`/`winhighlight` (`state.marker`); `strip_preview_marker` restores rather than blanks them (`winhighlight` is window-local only and never remembered per buffer, so blanking would drop a user's setting).
  - `swap_preview_buf` strips the marker _before_ `nvim_win_set_buf`, and records `state.preview_buf` _before_ the swap (`BufWinEnter` fires synchronously inside it).
  - `ensure_preview_watcher` (`BufWinEnter`/`WinEnter`/`BufWinLeave`, armed from `setup`) notices anyone else putting a buffer in the preview window and calls `release_preview_window` (restore options, drop the tag, forget the window). Idle close does the same with `handover = true`, which also unowns and lists the buffer shown there.

### 8. Plan View

- Renders Claude's plan-mode plan in an editor split, like the VS Code extension. Claude presents plans via its built-in `ExitPlanMode` tool (internal to the CLI, never sent over MCP); `tool_input.plan` carries the markdown.
- Rides the **same launch hook** as Live Cursor: `build_launch_injection` adds `ExitPlanMode` to the `PreToolUse` matcher and a `PostToolUse` entry scoped to it whenever the plan view is enabled, even if Live Cursor is off.
- `live_cursor.dispatch` routes `PreToolUse(ExitPlanMode)` → `plan_view.show`.
- Takes over the editor window closest to the Claude terminal (`diff.find_window_closest_to_terminal`, which uses `find_main_editor_window` for suitability and `_closest_rect_index` for geometry), recording the displaced buffer/cursor and restoring on resolve. The host window is tagged `claudecode_live_preview` so review diffs skip it. Only with no reusable editor window does it create a split (closed, not restored, on resolve).
- Dismissed on `PostToolUse(ExitPlanMode)` (accepted) or the next tool event of any kind (covers reject → replan and accept → execute) → `plan_view.close`.
- Tab-aware via `CLAUDECODE_NVIM_TAB`. Falls back to the longest string in `tool_input` if `plan` is renamed.

### 9. Terminal Links

Click a file path in the Claude terminal to open it in the editor (VS Code parity) instead of the OS file explorer.

- Claude renders file references as OSC 8 hyperlinks with `file://` URLs, but inside `:terminal` clicks go to Claude, which shells out to the OS opener; Neovim has no built-in "open hyperlink on click".
- A `TermRequest` autocmd records the **set of linked file paths** for the terminal (`_url_to_path` handles absolute and the relative `file://name` form Claude emits for cwd files).
- **No screen coordinates are tracked**: Claude's TUI repaints/scrolls links to rows that no longer match where the OSC 8 fired, so geometry lookup misses almost every real click (verified empirically).
- A buffer-local `<LeftMouse>` map opens on **release** (opening on press races the trailing `<LeftRelease>`, which then starts a stray visual selection). `_resolve_click` matches the filename token under the cursor against captured paths — exact, `/<token>` suffix, or a long substring (wrapped path chunks). A bare word matching nothing is left for Claude; non-link clicks are re-fed so Claude's mouse UI keeps working.
- Opens in the window closest to the terminal (`diff.find_window_closest_to_terminal`), jumping to `:line`. Normal-mode `gf` does the same for the path under the cursor.
- Enabling also sets `'mousemoveevent'` so Claude's hover underline works.
- Config: `terminal_links = { enabled, click, key = "gf", mouse_motion }`.

### 10. Session Persistence

`session_persistence = "off"|"global"|"external"`. Restores each tab's Claude _conversation_ when a saved Neovim session loads.

- Every launch is stamped with a conversation id we choose: `terminal.get_claude_command_and_env` appends `--session-id <uuid v4>` (`utils.random_bytes`, shared with the lockfile token). Later starts use `--resume <uuid>`.
- `launch_args` is idempotent per tab (terminal toggles rebuild the command) and stands down when the command already picks a conversation (`-r`, `-c`, `--session-id`, `--fork-session`, `--from-pr` — checked against the whole command, so `terminal_cmd = "claude --continue"` is respected).
- The id is corrected by the launch hook: a `SessionStart` entry is added to `build_launch_injection` even when live cursor and plan view are off (an empty `PreToolUse` matcher would match every tool, so that entry is omitted instead). `dispatch` feeds every payload's `session_id` to `note_session_id`, making the reported id authoritative after `/clear` or a manual resume.
- **The module does no file I/O.** `capture()`/`restore()` exchange a versioned plain table:
  - `"global"` mirrors it into `g:CLAUDECODE_SESSION` (`:mksession` writes it when `'sessionoptions'` has `globals`; re-applied on `SessionLoadPost`).
  - `"external"` leaves storage to auto-session's `save_extra_data`/`restore_extra_data` or the shipped resession extension (`lua/resession/extensions/claudecode.lua`).
- Tabs are keyed by **tab number**, not tabpage handle: handles are not stable across restarts and `:mksession` cannot save tab-local vars.
- Restore is **lazy** — tabs are armed (`pending`) and the CLI starts on that tab's next terminal toggle, so N restored tabs are not N processes at startup. `open_pending` (`:ClaudeCodeSessionRestore!`) forces the eager path.
- `:ClaudeCodeSessionRestore` re-reads the `"global"` payload unconditionally but never gates the rest on that result — in `"external"` mode the session manager has already armed the tabs. Reports `pending_count()` without `!`. Bound to `<leader>aR` only when persistence is not `"off"`.
- A pending id is dropped rather than resumed if the tab's cwd changed, or if no transcript exists — globbed as `<CLAUDE_CONFIG_DIR|~/.claude>/projects/*/<id>.jsonl`, which sidesteps the CLI's undocumented slug rule since ids are unique. A tab with a live record is never retargeted.
- **Only ids the CLI wrote a transcript for are persisted** (`persistable_id`, applied in `capture()`): a minted id is a name, not a conversation, and `--resume` on it fails. A record also carries `fallback`, the tab's last id that did exist, set wherever a record is replaced (a fresh mint in `launch_args`, `note_session_id` after `/clear` or manual resume). A tab with neither is left out of the payload entirely.
- `forget()` deletes the whole record, fallback included. It is called when Claude's process ends while Neovim is still running, so a conversation the user closed is not restored.
- Telling "user closed it" from "Neovim exited": on exit Neovim fires `VimLeavePre`/`VimLeave` **before** `TermClose`, so a `TermClose` while `M.state.shutting_down` is unset is the user's doing. `TermClose` is used rather than provider exit hooks because during shutdown the job's `on_exit` never runs (and snacks only registers `TermClose` when `auto_close` is on). `TermClose` reports only a buffer and a hidden terminal is in no window, so `terminal.tag_terminal_tab` stamps `b:claudecode_tab` right after `provider.open`.
- The **external** terminal provider has no terminal buffer and therefore no `TermClose`, so those Claudes are still restored.

### 11. Per-Tab Status

`status = { enabled }`. Publishes each tab's Claude as `busy` / `waiting` / `idle` / `none` for tablines, statuslines and third-party plugins. The MCP WebSocket only carries editor actions, never conversation state, so this rides the **same launch hook** and folds lifecycle events into a state machine (`note`):

- `UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`PreCompact` → busy
- `PreToolUse(ExitPlanMode)` → waiting (a plan is on screen)
- `Notification` → waiting with its message, **unless** it is the "waiting for your input" idle nudge (that is a timer, not a question)
- `Stop` → done or idle; `SessionStart`/`SessionEnd` → idle/none

Rules:

- `done` = "finished but unread". `finished_state` lands a turn in `idle` only when that tab was current **and** Neovim had focus. Otherwise it stays unread until `mark_read` (wired to `TabEnter`/`TabNewEntered` and `FocusGained`, which also restores `set_focused`; `FocusLost` clears it). Reading never clears `waiting`.
- `PostToolUse` is what ends `waiting`: between answering a permission prompt and the tool's result nothing else fires. That is why this feature widens the injected `PreToolUse` matcher to `"*"` and adds a `"*"` `PostToolUse` — a `Bash` call must not read as idle. Cost: one hook invocation (headless `nvim`) per tool call, hence opt-in.
- State is keyed by **tabpage handle** (nothing here outlives the session; handles are never reused), unlike `session_state`.
- `terminal.tag_terminal_tab` calls `note_launch` so a tab counts as having a Claude before its first hook event (never overriding a known state). The `TermClose` watcher in `init.lua` clears the tab when Claude ends.
- Changes emit `User ClaudeCodeStatusChanged` (`data = { tab, tabnr, state, prev, status }`) and, unless `auto_redraw = false`, `redrawtabline`/`redrawstatus`. Repeat events that change nothing user-visible are swallowed. `since` marks when the _state_ was entered (busy→busy tool changes keep it). `get`/`all` hand out copies.

**Spinner / frame clock**

- An icon may be a **list of frames**. `M.SPINNER` reproduces the CLI's spinner, read out of the shipped binary: six glyphs `· ✢ ✳ ✶ ✻ ✽` played forwards then backwards (the CLI builds `[...frames, ...frames.reverse()]`, so turning points repeat), one frame per 120ms (`spinner_ms` default), with the last glyph swapped for `✻` when `$TERM` is `xterm-ghostty`. On Windows and in Windows Terminal (`win32`, or `WT_SESSION`/`ConEmuANSI`) `✳` U+2733 is replaced by `✱` U+2731 — U+2733 is emoji-capable and renders coloured/double-width there.
- `icon()` returns the current frame; a `spinner_ms` timer advances it. `sync_spinner` starts/stops that timer from every path that mutates `entries`, so it runs only while something animates, and never under `auto_redraw = false`.
- **There is exactly one timer.** Views a `redrawtabline` cannot reach (the agents view) call `request_frames(name, interval_ms)` to share it, and `status.on_frame(name, fn)` to be called on the tick that _advances_ the frame. It runs at `status.spinner_ms`; a requester may override the rate but does not by default (`agents.spinner_ms` has no default — taking the fastest requested rate silently sped up the tabline).
- Stopping the timer does not reset the frame counter; the counter is **global, not per tab**, so every view shows the same glyph.
- `_tick(interval_ms)` marks a timer-driven tick and redraws only when the frame has not already advanced within that interval. `_tick()` with no interval is an unconditional manual step (for tests). `_frame_requests()` reports who holds the clock. `open()` arms through `sync_timers`, not `arm_poll` alone.

**Interrupts**

- **A turn cancelled with `<Esc>` is reported by no hook at all** — verified against CLI 2.1.221 with hooks on every event: the interrupt fires nothing, not `Stop`, not `StopFailure`. So an interrupted tab stayed `busy` forever.
- The CLI does write `[Request interrupted by user]` into the conversation as a real `user` entry. `agents.transcript` matches it (`INTERRUPT_MARKER`, prefix-matched because tool interrupts append `for tool use`); `_is_interrupt_line` decodes the entry and requires the marker to be the _whole_ message content, because `toolUseResult` entries are `type:"user"` too and a conversation quoting the string would otherwise read as cancelled. `agents.model` calls `note_interrupt` per conversation.
- Tab-hosted Claude with agents disabled is covered by `lua/claudecode/interrupt_watch.lua`, which tails a `busy` tab's transcript for the same marker and calls `status.note_interrupt` (dropping to `idle`, leaving other states alone). Its clock runs only while some tab is `busy`, it is **armed at end-of-file** on the transition into `busy` (so any marker it sees belongs to the watched turn, needing no timestamp bookkeeping), and a tick is one `uv.fs_stat` per busy tab plus a read of only the appended bytes, capped at 256KB. 500ms tick.
- The agents-side equivalent needs two extra rules: the marker is **stamped with its own timestamp** and only ends a turn that started before it (a transcript keeps every interrupt the conversation ever had), and "already acted on" is keyed by **conversation, not the row** (`refresh_list` replaces row tables every 2s).
- Reading the keypress instead was built and rejected: `<Esc>` means a dozen other things in Claude's TUI, and in a turn with no tool calls there is no later event to correct a wrong guess.

### 12. Agents Mode

`agents = { enabled }`, `<leader>aA` / `:ClaudeCodeAgents`. A dedicated tabpage running several Claudes on one project: selected agent's terminal centre, project sessions top-right, that agent's file activity bottom-right, files it touched top-left, the subagents it started bottom-left.

**Transcript store is the source of truth**

- All numbers come from the CLI's own store (`<CLAUDE_CONFIG_DIR|~/.claude>/projects/<slug>/<id>.jsonl`), not our accounting — so they are right even for conversations that ran in another editor.
- `agents/transcript.lua` folds `toolUseResult.structuredPatch` hunks (counting `+`/`-` lines) plus the session name. Name priority: user rename (`{"type":"agent-name","agentName":…}`, last wins) → generated `ai-title` → first user message. The rename must be read on its own: renaming only sometimes rewrites `aiTitle`.
- A `Write` that _creates_ a file records an empty patch, so the whole `content` is counted instead; otherwise every new file reads `+0`.
- Cheap enough to run per tool call because of a **substring prefilter** (`"toolUseResult"` and `"structuredPatch"`/`"file":`) that skips ~99% of bytes before `vim.json.decode`, and because the log is append-only: `offset` (advanced only to the end of the last _complete_ line, so a scan caught mid-write re-reads it) makes an update cost only the new bytes. Cache key is `(size, mtime, ino)` — a shrink or new inode means compaction, and the fold restarts.

**Slug rule (Windows-critical)**

- The slug is the cwd with every non-alphanumeric character replaced by `-`. Do **not** use `fnamemodify(cwd, ":p")`: its trailing separator gets slugified (`D--proj-` vs the CLI's `D--proj`), which broke every Windows project.
- Past **200 characters** the slug is cut there and `-<hash>` appended, where `h = h * 31 + unit` over the path's **UTF-16 code units** kept to a signed 32-bit int, then `Math.abs(h).toString(36)`. Code units, not bytes — JS `replace(/[^a-zA-Z0-9]/g, "-")` substitutes one dash per unit, so a two-byte `ö` is one dash and an astral emoji is two. Both halves were checked against the CLI's algorithm run in node.
- Fallback on a slug miss: scan every project directory for a transcript naming this cwd. It must use `_io.read_sync` (bounded, miss-path only) — the asynchronous reader never answers in time, and treating "hasn't answered" as "no match" made a slug miss always return an empty list. Match the cwd both raw and with separators escaped the way JSON writes them, case-folded on Windows.

**Path handling**

- `utils.normalize_path`/`path_key` (`/` separators, no trailing one, case-folded on Windows) is the key for `git.parse_status` (git answers with `/` separators on every platform while the CLI supplies `D:\Git\proj\x.lua`) and the comparison basis for `render.relative_path`.
- `render.shorten_path` splits on **both** separators, keeping a drive with the folder it names.

**Concurrency and instances**

- Nothing blocks: reads go through `uv.fs_*` callbacks in `_chunk_size` slices, sessions are folded a `fold_batch` at a time newest-first, and a warm cache under `stdpath("cache")` paints real numbers in frame one. Unknown counts show `+· -·`, never blank.
- **Each agent gets its own MCP server** (`claudecode.start_agent_instance`) — own port, token, lock file. `M.instances` is keyed by opaque instance id, `M.tab_instance` points at a tab's own Claude, and `_G._claudecode_active_tab_id` is replaced by `claudecode.request_context` (with N Claudes per tab, "which tab" no longer identifies the sender). `close_all_diffs` scopes by instance so one agent's routine `closeAllDiffTabs` cannot reject a sibling's pending diff.
- Agents run through `agents/registry.lua`, not the terminal providers (which hold one terminal per tabpage). `bufhidden = "hide"` is what lets a hidden agent keep working; switching is a buffer swap.
- `session_state.disown_tab` keeps the view's tab out of per-tab session bookkeeping.
- **Every buffer the plugin rewrites from a timer or hook RPC has `undolevels = -1`** (`render.paint` sets it on whatever it paints; `live_cursor`'s preview buffer and `plan_view`'s plan buffer set it at creation). Neovim closes an undo block only after a typed command, so writes from callbacks all land in **one** block that `undolevels` (a count of blocks) never trims — each full-buffer replace kept a copy of the old lines until the buffer was deleted. A 500ms-polled pane grew ~13KB per paint, 12GB over a week-long session. Measured: 20k repaints of a 26-line buffer, +104MB with undo vs +0.9MB without; `undotree().seq_last` stayed `1` throughout. Buffers the user edits (`diff.lua`'s proposed buffers, the search input) keep undo.
- `render.paint` also skips a repaint whose lines and marks equal the last one (copies are kept, not the caller's tables), guarded by `changedtick` so a buffer written by anything else is still repainted. Row payloads are updated either way.
- **A launch never enters a directory that is gone**: a row records the cwd its conversation ran in, and a moved project leaves transcripts naming a missing path — `termopen` refuses such a cwd (`E475`). An unusable recorded path is dropped for the directory the view is attached to. A failed spawn reports the reason it was given.

**Layout and routing**

- Every pane carries `claudecode_live_preview` and the tab is marked `claudecode_agents`, so diffs, previews and the plan view never take one over. The tab declares `t:claudecode_layout_owner = { forbids_split, host = "float", float_module, origin }` — the routing protocol every "where does this file go" decision reads (`diff.resolve_target_window`).
- **The centre pane wears the snacks terminal background** (`Normal:ClaudeCodeAgentsNormal` → `SnacksNormal` → `NormalFloat`; the sidebars keep the editor's own `Normal`), and it is **repainted per buffer swap, not once at build time** — Neovim remembers window-local options per _(window, buffer)_ pair, so `nvim_win_set_buf` hands the window whatever that pair last had, which for a buffer that has never been in the pane is nothing (measured). Painting once therefore lasted only until the first agent's terminal replaced the buffer the pane was built around. `paint_center` merges rather than overwrites, since `termopen` appends `StatusLine:StatusLineTerm` as a buffer becomes a terminal; a `BufWinEnter`/`TermOpen` autocmd is the backstop for every path that swaps the pane's buffer, and `show_notice` paints itself because the opening notice is shown before `arm_autocmds` runs.
- `agents.tab_name` names the tab, plus `tab_name_var` for which tab-local variable to write (tablines disagree: `t:name`, tabby's `tab_name`, taboo's `taboo_tab_name`), or a function form handed the tabpage for tablines that rename via a command. Nothing undoes it on close.
- **The view stands down for a Neovim session write** (`close_for_session`, via `session_state.prepare_save`): `:mksession` would record four pane buffers and, with `'sessionoptions'` carrying `terminal`, a `term://` buffer per live agent that Neovim restores by re-running the command. It must happen in the manager's **pre-save** hook (auto-session order is `pre_save` → `mksession` → `save_extra_data`), and a `VimLeavePre` autocmd of ours loses the race (the session manager loads at startup, claudecode is lazy-loaded, same-event autocmds run in registration order). The record is therefore taken _before_ the close and held in `pending_capture`, consumed by the first later `capture()`. Only on exit: `v:exiting` is the test (`v:null` normally, an exit code from `VimLeavePre` on); `M.state.shutting_down` cannot help, being set by an autocmd registered after the session manager's.
- `M.close({ keep_tab = true })` takes only our own windows, emptying rather than closing the last one, when the tab holds a window of the user's.
- `openFile` from an agent **floats**; a **clicked** terminal link goes to a real editor window in the origin tab and takes you there. Deliberately different: one is the agent's idea, the other is yours.

**Floats in agents mode**

- Diffs and file opens land in cascading floats (`agents/float.lua`, a thin wrapper over `lua/claudecode/float.lua` — see 13), tagged and titled per agent so several are answerable at once.
- A float records what it is _for_, so `float.close_all(session_id, "open")` dismisses the file a plan was shown in (on `PostToolUse(ExitPlanMode)`) without touching a pending diff.
- The diff float hosts the unified inline provider, so `:w` acceptance and the blocking MCP response are unchanged. The float is recorded on the diff state (`float_window`) so `_cleanup_diff_state` closes it on resolve, **forced** (a rejected diff's buffer is still modified).
- `diff_opts.layout = "float"` needs unified.nvim and warns once when it resolves to the native provider, which needs two real windows.
- **Live cursor and the plan view stand down for agents** (`live_cursor.from_agents_mode`, checked in `dispatch` after status/agents routing and before anything opens a window): every window in the agents tab is a pane. Detected by the tab stamp _or_ `registry.is_live(session_id)`, since the stamp only says where the CLI launched.

**Hooks, status and read-state**

- `source = "auto"` rides the hooks `status` already pays for, else polls transcript mtimes. Hook cost is two headless `nvim` per tool call _per running agent_, so polling is the default.
- Two hooks are registered even under polling: `PostToolUse(ExitPlanMode)` and `SessionStart`.
- Live state is per **conversation**, not per tab (`status.classify` is extracted so the rules stay shared). `done` takes the same three conditions as the tab rule: the conversation is the selected one, the view's tab is current, and Neovim has focus (`status.is_focused`, exported so the rules cannot drift).
- Clearing `done` needs its own wiring: `model.mark_read` (`done` → `idle`; `waiting` untouched) is called by `model.select` (covers `<CR>` and `<C-n>`/`<C-p>`) and by `agents_view.mark_selected_read` on `TabEnter`/`FocusGained`. `status`'s own autocmds cannot help — its entries are keyed by tab and several conversations share this one.

**Activity pane**

- Lists events **newest first** (`model.feed` reverses the store's order and trims the oldest).
- **Includes calls that touch no file** (`agents/tools.lua`, `agents/tool_view.lua`, `agents/ansi.lua`) — shell commands, searches, subagents. They produce no `filePath`, so the file fold skips them by construction.
- A call and its result are two entries joined by a `toolu_…` id, and the **row is built from the call**, so a command appears when it starts, which is what allows showing it as running.
- Only three of five outcomes are drawn (`…` running, `✗` failed, `⊘` stopped by you); most calls simply work.
- **Failure is `is_error`, never stderr** (measured: one session had 3 `is_error` against 55 with stderr output, nearly all `git`/`rg` progress). A **refusal is not a failure** (32 of 379 `is_error` results here are the user declining). `"interrupted":true` on the Bash result shape is worthless — `false` in all 25 transcripts checked.
- `_fold_line` closes out every still-pending call when it sees the `[Request interrupted by user]` marker (see 11), else an interrupted `sleep 300` keeps a "still running" marker forever.
- **The row carries only what it draws** — tool, one-line label, id — and `<CR>` re-reads the pair (`transcript.tool_call`). Payloads are the bulk of a transcript (~116KB of commands and output in one session here), and the id is an excellent prefilter: exactly two lines contain it. Fold cost on this project's largest transcript (11.9MB, 2628 lines, 451 with a `tool_use` block, 1.26MB): 34ms → 47ms.
- Row labels are per-tool knowledge (`tools.label`): only `Bash` and `Task` carry a `description`; `Grep` is named by its pattern, `WebFetch` by its URL without the scheme, `TodoWrite` by what is in progress and how many are done — with a field-order fallback so unknown MCP tools still get a readable row.
- Float bodies are too (`tools.body`): `Bash` puts the command above its output with stderr as a **named section rather than an error**; on Windows the CLI calls the same tool `PowerShell` (identical input and `{stdout, stderr}` result), so every shell rule is keyed through `SHELLS` (`$ ` vs `PS> ` prompt, `pwsh` kind), and reader detection also knows `Get-Content`/`gc`/`type` (case-insensitive, skipping value parameters like `-Tail 20`) and `ConvertTo-Json`; a subagent shows the reply the parent received; a file list shows one per line; anything unrecognized is pretty-printed **valid** JSON (commas and all — readers copy it out).
- Command output goes through `agents/ansi.lua`, which turns SGR codes into extmarks against `g:terminal_color_*` (256-colour and 24-bit resolved to hex) and drops what a buffer cannot act on (cursor moves, erases, OSC titles). Subtlety: `gmatch("[^;]*")` yields a trailing empty match read as `0`, which resets every colour immediately after setting it — must be handled.
- **The float names what it shows** (`tools.detect_filetype`). Sniff the **output** (not the command — patches come from `git diff | head`, `log --patch`, a written `.patch`) for `diff --git`, an `@@` hunk header, an `index <sha>..<sha>` line, or a `--- `/`+++ ` **pair** (a lone `--- ` opens a YAML document or closes Markdown front matter) → `diff`, or `git` when `commit <sha>` headers are present. The command is asked only what it alone knows: a file being printed (`cat`/`bat`/`head`/`tail`/`less`, taken from the pipeline's **last** stage) is whatever `vim.filetype.match` says, and `jq` is JSON unless asked for raw text. Everything else gets no filetype — a wrong syntax is worse than none. Only the first `SNIFF_LINES` are read, and only stdout (stderr is progress; the `$ …` and `── stdout ──` lines are ours).
- `.` and `gf` say a tool row is not a file rather than doing nothing, but a float stepping with `<C-n>`/`<C-p>` lands on tool rows too — except a `.`-opened one, which skips them silently.
- `f` (`keymaps.filter`) cycles everything / files only / commands only. The filter is applied while walking events from the newest end, not to a slice (with a filter on, visible rows come from anywhere in history). It lives on the view and dies with it, like the sort criterion. `feed_tools = false` folds none of them.
- `model.feed(visible)` takes the pane height plus slack, since the pane repaints wholesale (240 rows 1.31ms/paint → 24 rows 0.17ms) and it no longer grows with the conversation. The exception is a row the cursor or a float holds (`keep`, see Navigation).
- `model.feed` returns `events, ages` as parallel arrays rather than copying events (those are the transcript's own cached tables). Ages come from `model`: `stamp_feed` keys a weak table by the event table itself; the first batch after a selection change is a backfill, so it is aged from **each event's own timestamp** rather than declared old wholesale. `stamp_counts` only calls a count changed when it moved from one already shown.

**Layout sizing**

- `layout.sessions_height` defaults to `0.55`; widths default to `0.23`/`0.23` with the terminal taking `0.54`.
- **Only the sidebars are `winfixwidth`/`winfixheight`; the centre absorbs.** Fixing the centre too leaves Neovim no window to take space from (widening one sidebar shrank the other).
- `build_layout` clears those flags on the window it splits from (a rebuild starts from a surviving pane that still carries them) and applies sizes **last**, after buffers, tags and winbars. Do not toggle `'equalalways'` around construction — restoring it re-equalises every window.
- **A split opened in the tab and then closed redistributes the panes** (`winfixheight` does not stop Neovim when no unfixed window is available in that column). `remember_sizes` snapshots the three sizes whenever the tab holds nothing but the four panes (floats excluded), and `restore_sizes` puts the snapshot back after any window in the tab closes. A snapshot, not the configured fractions, so a dragged size survives. `sizes_locked` is set the moment a window closes and cleared by the restore, so a redraw landing in that gap does not snapshot the damage.
- Snapshots are taken on `WinResized`, `WinEnter`/`WinLeave`, and from `redraw` — deliberately **not** `WinNew`, which fires after Neovim has already taken the space. A focus change is the last moment the layout is reliably intact.

**Fade (`agents/fade.lua`)**

- `fade.lua` owns its defaults **alone**; `config.defaults` deliberately carries no `fade` table, because `fade.opts()` merges applied config over its own and a second copy silently wins.
- A new Activity row is drawn lifted above its own colour (`fade.boost`) and **bold** (`fade.bold`) for `fade.hold_ms` (3s), then walks down through that colour into the pane background over `(steps - 1) × step_ms` (~3s) — one continuous ramp from `lit` to `rest`, collapsing to the pre-boost formula when `boost = 0`. Bold is dropped when the ramp starts.
- **The lift is intensity and weight, never brightness.** `intensify` saturates towards 1 (all the lift for a muted `Comment`, none for a vivid `Directory`) and moves lightness towards a colourful band **only away from the pane background and only if the colour is on the wrong side of it**. Scaling channels towards peak does nothing for a colour already there (`#82aaff` at s=1.00 came back a pale wash). Brightening (scale channels to lift the largest, spending the remainder towards white) survives only as the fallback for a hueless colour.
- Saturation can cost legibility (the eye weights blue at a fourteenth of green): the result is walked back up in lightness at its new hue until it is at least as legible as the colour it came from.
- A `+N`/`-N` that moved is drawn lit and ramps back within `flash_ms` (3s), set one step longer than the ramp so it has no flat hold.
- `step_ms` matches `spinner_ms` because that clock samples the ramp; ramp length is set by the step _count_, and 25 steps is what makes a 3s fade a fade.
- The ramp is pre-computed highlight groups, not per-frame `nvim_set_hl` (redefining a group is global). It needs no timer: `redraw` asks `anything_moving` of the rows it drew — an animated status icon (`status.is_animated`) or a fade still ramping (`fade.animating`) — and **releases the frame request otherwise**. The shipped `busy` icon is a single glyph (the spinner is opt-in via `icons = { busy = status.SPINNER }`), so by default nothing animates.
- **A count block is one hue at four strengths** (`fade.count_group`). Rest = the theme's colour at `count_sat` (0.25) dimmed `count_dim` (0.60) towards its own block; block = `count_bg_sat` (0.22) of it, `count_bg_lift` from the pane in lightness; flash = the colour itself on a block at `flash_level` (0.50), text following `flash_text_lift` (0.25) of lightness up at the same hue and saturation. Both the dim and the desaturation are needed on the resting number: at equal lightness a desaturated green and a full one read alike.
- Hue priority: the group's own foreground when it is an actual colour → `Added`/`Removed` (Neovim ships these) → the block's own hue → nothing derived. **The block follows the number, not the theme's `DiffAdd` background**, which is often a different hue (tokyonight-moon pairs a green `Added` with a blue block).
- All four colours are walked in lightness at their own hue until they clear `count_contrast` (4.5:1) on whatever they sit on. That floor also limits how quiet `count_dim` can make a number.
- "Is this a colour" is decided by **channel spread**, not HSL saturation, which runs away at both ends (`#eef1f8` reports s = 0.42 with 4% spread; `#a89984` reports 0.14 of spread and looks grey).
- A near-grey has no hue to intensify (hue 0 is red — saturating would flash it pink) and is brightened instead. The two halves must differ, or a flashed count is _less_ legible than one at rest. `flash_level` and `flash_text_lift` trade against each other: a **lower** `flash_level` buys a more legible number (on a `#005523` DiffAdd, `0.8`/`0.1` gives 1.36:1 vs `0.55`/`0.25` at 2.09:1).
- Every span of an Activity row must carry a group — the `read`/`edit` column had none and fell through to `Normal`, the one span the fade could not reach. It uses `ClaudeCodeAgentsKind` (default-linked to `Comment`).

**Sessions pane**

- The cursor is anchored to its **conversation** across repaints, not its line (a re-sort or a new session moves rows under it, and `<CR>`/`x`/`dd` would act on the wrong one). `cursorline` painting a line like the selection is why a merely-busy session looked selected.
- **A session's bullet is dimmed when it is _not_ running** — the reverse of `status`, which dims `idle` (right for a tabline, where a tab with no Claude draws nothing). `model.rows` paints a not-running row in `ClaudeCodeAgentsStopped` (`agents.highlights.stopped`, linked to `Comment`) and drops the group entirely from a live `idle` one. Other states keep `status`'s groups.
- The selected row carries `❯` in the gutter (`SELECTED_MARK`). Its highlight band is a **character range ending where the counts start**, not a `line_hl_group`: a line highlight composes over character-highlight backgrounds whatever the priorities, which stripped the coloured count blocks on exactly the row you most want to read.
- **`/clear` swaps the conversation id under a running terminal** — verified against CLI 2.1.226: `SessionEnd(reason="clear")` for the old id, then `SessionStart(source="clear")` with a brand new one, same process, terminal and socket. `--fork-session` has the same shape. Nothing on disk attributes the new conversation to an agent, so the CLI has to say so:
  - A **launch** gets its own name (`agent_key`, passed as `CLAUDECODE_AGENT_ID`) — the registry's second index, since the first one moves.
  - `SessionStart` is injected whenever agents mode is enabled, even under polling.
  - `registry.rekey` moves the agent: this index, its server instance (`claudecode.rekey_agent_instance` **renames rather than replaces** — the client is still connected to that port and `request_context.session_id()` reads the instance), and any float on screen (`float.retag`).
  - The selection follows the terminal only when it was on the conversation being left.
  - `term.retired` stops an agent drifting back onto a conversation it left: the two events are separate async hook processes, so arrival order is not the CLI's order. `SessionStart` is exempt (`reclaim`) — that is the CLI stating which conversation it is having now.
  - `model.note_session_change` drops the old conversation's per-agent state (otherwise a spinner sits on a row nothing will report about again).
- **A conversation started here is listed before it exists on disk** (the CLI writes the transcript on the first message). `refresh_list` lists what the registry is running as well as what the directory holds (`registry.live_ids`, one synthetic row per live conversation the enumeration missed), built from the only three known things: id, directory, running. Counts are `0`/`0` (not the unknown placeholder, which would claim they are still being read); titled `New session`; `refresh_list` carries a row's previous title across a rebuild so the name does not flicker back to the id prefix. It is rebuilt from `live_ids` every pass, so it is taken over by the enumeration or drops out.
- `M.select` resumes only a conversation that has a row; an id that never got a transcript is claimed with `--session-id` as it was the first time.
- The row is named with `transcript.session_path`, which applies the slug rule directly when `project_dir` finds nothing (the project that matters most is the one the CLI has never run in).
- Cursor anchoring is overridden for one paint whenever the selection moved since the cursor was last placed (`state.cursor_selection`), so the cursor lands on a new row when it appears.
- **Every pane line begins with a blank cell**: word-highlight plugins (mini.cursorword, vim-illuminate) lit up every row sharing a timestamp or status letter with the cursor's column-1 word. All of them stand down over whitespace. `create_buf` also sets `b:minicursorword_disable`.
- **A path too long for its pane is cut from the inside** (`render.shorten_path`), never the tail: `first/…/parent/name` → `first/…/name` → `…/name` → `name` → the name cut with its **extension kept**. The first folder outranks the parent because it is the coarser answer (`lua/…/init.lua` vs `tests/…/init.lua`).
- Rows are ordered by `summary.last_ts` — **the newest `"timestamp"` anywhere in the transcript**, matched out of the raw line rather than decoded, from any entry type. Dating from tool results alone leaves a Bash-only conversation at epoch 0; the file's mtime is worse (the CLI appends untimestamped `last-prompt` bookkeeping days later).
- **The order is then frozen** (`model.apply_order`): every criterion moves on its own, so with several agents running the list shuffled continuously. `state.order` records the ids in shown order, rows keep their places, and a new session is **sorted in once** at the position the active criterion gives it and then pinned (appending would file every new agent at the bottom of a recency sort). `state.order` is rebuilt from the rows present, so deletions need no cleanup.
- Only two things re-sort: `r` (explicit re-read) and `gs` (`keymaps.sort`) → `agents/sort_menu.lua`, a single-key float (`snacks.win`, else `nvim_open_win`, our own rendered buffer either way) offering `recent`/`name`/`changes`/`status` from `model.SORTS`, with re-picking the active one meaning **reverse**. It is the only place the order is stated, so it names the direction in the criterion's own words ("newest first", "A → Z"), and it answers exactly once however many buffer-local keys are pressed after it closes. The choice lives on `state` and dies with `detach`; the next open starts from `agents.sessions.sort` (old values `added`/`title` are aliases for `changes`/`name`).

**How far back the list reaches**

- `agents.sessions.limit` is **either a count or a span**: `"2w"` (the default), `"3d"`, `"1m"` — thirty days, since a calendar month would make one setting mean different spans — `"all"`, or a plain number for the newest N. `model.parse_limit` reads both and falls back to the default rather than erroring, because it runs on a timer; `config.validate` is where a wrong value is reported.
- `agents.sessions.max` (200) is a ceiling that **holds however wide the window is**, so `"all"` costs a bounded number of rows and folds. A count below it wins; it is never lifted.
- Age comes from the file's **mtime**, not `summary.last_ts`: the enumeration is stat-only, and asking for `last_ts` would mean folding every transcript in the project to decide which ones to show. A row that disappeared once it folded would be worse than one that is a bookkeeping write too young. (This is the one place mtime is the right clock — it answers "was this touched recently", not "when did the conversation last say something", which is what the _order_ needs.)
- **The window never drops what the user is holding on to**: a running agent (`registry.live_ids`), the selected row, and anything pinned. Otherwise a live terminal older than the window would be re-listed by the `live_ids` pass as a synthetic `New session` row, losing its title and counts.
- `state.hidden` counts what was left out, so the centre can say "nothing from the last 2 weeks — 7 older conversations" instead of "no conversations in this project" (`show_empty_notice`). That screen names `gs` and binds it, since `gs` is otherwise a list-pane key and the centre is where the message is read.
- The `gs` float grew a second section (`model.WINDOWS`, keys `1`/`3`/`w`/`W`/`m`/`a`) for the same reason it states the order: the rows the window leaves out leave no trace of themselves. `on_pick` is answered with `(key, kind)`, `kind` being `"sort"` or `"window"`. With a **count** in force no span is marked — the heading says "newest 30" instead, since marking a row would misreport the list.
- Like the sort criterion, a window chosen with `gs` lives on `state` and dies with `detach`.
- `model.pin`/`model.unpin` keep a conversation listed whatever the window says, and list one the project's enumeration cannot see at all (a search hit from another project, built from the transcript path and cwd the search knew). Pins die with the view.

**Deleting conversations**

- `dd` (`keymaps.delete`) → `transcript.delete` removes the `.jsonl` **and** the sidecar directory of tool results (`<dir>/<id>/`). The row disappears because `refresh_list` re-enumerates, not because anything removed it locally.
- **Deleting the selected (or offered) session moves the selection** (`follow_deletion`) to the row that took its place — the one the cursor lands on, or the one above when the last row went — through `preview_session`, so a running agent is shown and a stopped one offered. Without it the model dropped the selection but the centre kept offering the deleted id, and `i` on that offer found no row and claimed the deleted id with `--session-id`, starting a new conversation under it. The row order is read before the delete. An offer for any deleted id is cleared; nothing left falls to `sync_empty_notice`.
- Irreversible (the transcript _is_ the conversation), so it asks first through `agents/confirm.lua`: a centred `snacks.win` float, else `vim.fn.confirm`. Every path answers exactly once; closing the window counts as "no" (the callback is guarded and deferred out of the closing keymap).
- Takes a **count** and a **visual range** (`3dd`, or `d` over a selection — `_visual_lhs` binds a doubled key under its single form, since over a selection the range _is_ the selection). A batch asks **once**: the dialog names the first `DELETE_LIST_MAX` rows and counts the rest, and `model.delete_sessions` re-enumerates once for the whole batch.
- A session whose agent is still running is refused (the CLI has the file open). Inside a range it is _set aside_ rather than vetoing the gesture; the dialog reports how many were left alone. Only a range with nothing deletable merely warns.
- `stop` moved to `x` because `map` binds with `nowait`, so a `d` binding makes `dd` unreachable.

**Row actions**

- **A row in either pane is a record of work, not a file reference.** `<CR>` shows what the session did to that file (`agents/file_view.lua`): today's content with the session's changes rendered inline by unified.nvim; for a read row, the lines that read covered, in live-cursor's own highlight group.
- **An Activity edit row is one call, and opens as that one edit** (`prefer = "step"` with the row's `tool_id`; a subagent transcript's call lines do the same). `file_history` keeps `steps` beside the flat `hunks` — one per result, oldest first, with the call's id, kind (`edit`, or `write` when the result carries `content`) and its own hunk tables. `open_step` rebuilds the file as the call left it: a `Write`'s `content` is that file exactly; an `Edit`'s is today's file with every later step reverse-applied. The other side is that state with the step's own hunks reversed. Any hunk that fails to locate, later or own, means an outside edit has touched those lines and the moment cannot be rebuilt, so the call's patch is shown as diff text with `file moved on` in the title — never an approximate inline diff. Title says `(edit 3 of 7)`, the position among the session's edits to that file, so `<C-n>`/`<C-p>` read as a sequence. A `tool_id` the history has no step for (a result naming no call) falls back to the cumulative diff. Changes rows carry no `tool_id` and stay cumulative.
- The baseline is not in the store (`originalFile` is on only some edits — 179 of 402 in one transcript), so `agents/patch.lua` reconstructs it by **reverse-applying the session's own hunks** to the file on disk, newest first. A hunk is located by content nearest its recorded line (the file moves on afterwards); one that is nowhere any more was overwritten later and is skipped, and the float's title says how much of the session's work is still present (253/349 hunks located across six real transcripts). When nothing can be located, the file is gone, or unified.nvim is absent, the hunks themselves are shown as diff text — the CLI's own record, which cannot be stale.
- **A hunk is not the file's text: the CLI writes every tab in `structuredPatch` as two spaces** (of 2398 hunks checked against their `originalFile`, 784 differ, every one only by that; one more carried a `\ No newline at end of file` line). `oldString`, `newString` and `originalFile` keep the tab. Matched verbatim, no hunk touching a tab-indented line located, and each skip took its older neighbours down too (one file showed 2 of 14). So `patch.reverse_apply` locates against `patch.shown` (tabs → two spaces, trailing CR dropped) and rebuilds with the file's own text: context lines from the file, removed lines from `hunk.exact_old` (`patch.annotate`, called in `fold_history`: `originalFile` by position, else `oldString` by shown text), else re-tabbed leading indentation when the located block is tab-indented. `originalFile` is dropped above ~10KB (largest kept: 10,680 bytes), which is why `oldString` matters: without `originalFile`, 6967 of 6967 checkable removed lines came back exact. `\` lines belong to neither side.
- The baseline handed to unified.nvim ends in a newline: `show_against_text` appends one to the buffer's text when `'endofline'` is set, so a baseline without it marked every file's last line changed.
- `.` (`keymaps.git_diff`) → `file_view.open_against_head`: same float and renderer, the file's committed content as the baseline (`git.file_at_head`). `git._working_copy` walks up for the nearest `.git` (dir or file) or `.svn`, with a stat per candidate so a deleted directory is walked past. Git: `git show HEAD:./<name>` with `-C <the file's own directory>` so the repo root never has to be found, run from the root found (which exists even if the file's directory was deleted). svn: `svn cat -r BASE <path>@` — `BASE` is what `svn diff` compares against, the trailing `@` stops an `@` in the name reading as a peg revision — and the float says `BASE` wherever it would say `HEAD`. Non-zero exit inside a working copy = never committed, so every line is an addition; outside one git is still asked (a `GIT_DIR` repository has no marker) and failure means **not versioned**, which is said instead of opening an all-additions diff; a command that could not start (`text == nil`, including a `jobstart` id ≤ 0) is said too. A file identical to its baseline says so instead of opening an empty diff; without unified.nvim it falls back to `vim.diff` text. This read bypasses `git.run`, which drops empty lines (right for status, wrong for file content). Status letters in the Changes pane are git-only; in svn they fall back to the transcript's own.
- `gf` (`keymaps.goto_file`) opens **the file itself, on disk, in a new tab** — the other two are for reading what happened, this one is for working. A new tab carries none of the agents tab's vars. A path that is no longer readable is refused with a log line (`tabnew` on a missing path opens a buffer whose first `:w` resurrects the file).
- **The float's title says where the file is** (`file_view.title` → `utils.path_title`, see 13), not just its tail: a session touches several `init.lua`, and a row is a record of work rather than a file you already have open. Relative to the directory the conversation ran in (`cwd`, passed from `model.selected_cwd`), with the note (`(read)`, `(vs HEAD)`, `(3/9 changes still present)`) after it.
- File history is read on demand (`transcript.file_history`, prefiltered on the basename, ~21ms for a session's whole file list) rather than folded into the summary, and answers through `vim.schedule` — its reads land in a libuv fast context where opening a window is `E5560`.
- The Changes pane takes `+N/-N` from the transcript and only its `M`/`A`/`D`/`?` letter from git (`agents/git.lua`, pathspec-restricted, single-flight, newline-delimited rather than `-z` because `jobstart` renders NUL as `\n`), so the pane and the session row cannot contradict each other.
- **A file no longer on disk is drawn `D` and dimmed whole** (`ClaudeCodeAgentsDeleted` → `Comment`), counts kept but without blocks or flashes. Deletion is git's `D` **or** our own `uv.fs_stat` answering `ENOENT` (`model._is_gone`, run in `refresh_git` even with `git = false`): a file the session created and then `rm`'d was never tracked, so git says nothing and the transcript still calls it an add. `refresh_git` also runs when the selected transcript's `last_ts` moves (a shell `rm` is not a `WRITING_TOOLS` call, and polling reports no tool), and a request inside the rate gate schedules one trailing refresh instead of being dropped. `.` on a deleted tracked file shows HEAD as all removals, always as diff text (a buffer on the missing path is one `:w` from resurrecting it).
- **A file in the CLI's scratchpad is drawn like a settled tool call's label** in Activity — `fade.dim_group(hl("title"), nil)`, the very group a rested Bash description gets, so the two follow each other through `fade = false`, `highlights.title` and colorscheme changes. Quieter than a path, not grey (grey means deleted); counts keep their blocks, and a deleted one is grey like any other. `transcript.is_scratchpad` matches the **shape** `…/claude-<uid>/<slug>/<uuid>/scratchpad/<file>`, either separator, rather than deriving the directory (CLI 2.1.274 builds it from `<temp root>/claude-<uid>/<slug>/<session>/scratchpad`): the root is `/private/tmp` on macOS, `/tmp` on Linux, `$CLAUDE_CODE_TMPDIR` when set, and something else on Windows (the platform branch is compiled out of each build), where the uid is not a number either. Not tied to the transcript's own id — 43 of 131 transcripts checked wrote to another session's scratchpad (resumes, forks). The UUID segment keeps a project folder that is merely called `scratchpad` out (one here had 110 writes).

**Navigation**

- `<C-n>`/`<C-p>` (`keymaps.next_session`/`prev_session`) move the selection from **any** pane and from inside the terminal, in terminal mode as well as normal.
- A live conversation is swapped into the centre at once. A **stopped one is selected but never started** — cycling is how you read what sessions did, and every pane follows the selection. The centre shows a notice naming the conversation and the key that starts it (`show_start_prompt`, recorded as `state.pending_start`); the notice is one reused scratch buffer (`state.notice_buf`), which is also what a dead agent's pane shows.
- `focus_terminal` (`keymaps.focus_term`, `i`) resumes a stopped conversation and then lands in it — "put me in this session" is one intent either way. It falls back to the offer if pressed before the list arrives, and starts a new agent when there is neither an offer nor a session.
- **The view opens already pointed at a session** (`offer_initial_session`, armed by `state.await_initial`, fired from the model's change callback as well as `open`, since the list folds asynchronously). Otherwise the centre holds `tabnew`'s blank _modifiable_ buffer where `i` edits a scratch file. It offers the selected or newest session, starts nothing, and stands down once a terminal or earlier offer owns the pane. `refresh_start_prompt` repaints it when the fold replaces the placeholder title.
- A conversation running in another tab is offered as a **jump**, not a start (two CLIs on one transcript).
- **A project Claude has never run in gets its own screen** (`show_empty_notice`, painted by `sync_empty_notice`): the offer bails on an empty list and waits for a model change that never comes. Enumeration is synchronous (`transcript.list` is stat-only), so `open` answers immediately: no conversations yet, plus the key that starts one. That key (`keymaps.new`, `a`) is bound on **every** centre notice screen (empty project, offer to resume, ended agent) and named in each one's hints — whatever the centre offers, no agent is running there. It is bound in `apply_notice_keys` (not only via `KEY_SPECS`) so it holds under a bare config. The same screen returns when a project _becomes_ empty and re-arms `state.await_initial`.
- **Inside a file float those keys step through the pane's rows** (`bind_float_nav`): the float is a view of one row, so they walk the rows one level down, wrapping at both ends, skipping rows with no file, moving the pane's cursor along and keeping the baseline the float was opened with.
- Stepping **swaps the float's content in place** (`float.create`'s `reuse`, threaded through `file_view`) rather than close-then-open: `file_view.open` reads history asynchronously, so a close-then-open leaves focus in the _pane_, where the same keys change the session. Reuse also stops the cascade walking down the screen per file.
- Repeats are **coalesced**: the aim moves on the keypress and only one open is in flight, so holding the key walks at key-repeat speed and opens the row it settles on.
- Bound only on scratch buffers we made — `float.open_file` shows the real file buffer, where a buffer-local `<C-n>` would follow that file into the editor.
- **Every pane's cursor is held on its row, not its line.** A repaint replaces the lines wholesale and Neovim keeps the cursor's line number (measured), so a row landing above it slid another under the cursor: every new Activity event (newest first), a Changes file first read then edited, a Tasks shell started inside a subagent. `render` gives every payload a `key` (session id; `transcript.event_key` for Activity — the call's `toolu_…` id, which file events now carry too, read from the result's `tool_result` block; path; `kind\0id` for Tasks), and `redraw` reads the key under each cursor before painting and puts the cursor back on it after (`cursor_row`/`restore_cursor_row`; ties go to the nearest line).
- **Activity's top row watches the newest**: a cursor on line 1 stays on line 1 as events land, since holding it would scroll the newest rows out of sight a screenful later. Any other row is held, and so is a top row a float is showing; `gg` returns to watching.
- A held Activity row is drawn however far it is pushed: `model.feed(visible, keep)` walks past the pane height until every kept key is drawn, never past `feed_limit`, and the pane scrolls to keep the cursor on screen. A float row the pane no longer draws (the filter hid it) is let go of (`drop_lost_float_rows`), or the feed would walk the whole history every frame looking for it.
- Held only **within one session**: after a selection change the rows are another conversation's (the same path in Changes included), so the cursor stays on its line (`state.rows_session`).
- **The float's stepping state names rows too**: `float_nav` carries `key`/`aim_key` beside `lnum`/`aim`, which are only where the rows were last seen. `step_float` steps from where the aimed row is _now_, and `open_aimed` resolves the aim by key when the open lands. Stepping by line stepped from whatever had been pushed onto the float's old line — `<C-n>` reopened the row on screen, `<C-p>` skipped one.

**Search (`agents/search.lua`, `gf` in the sessions pane / `keymaps.search`)**

Same key as `goto_file`, different meaning; possible because no pane is offered both.

- Searches **what was said** (`user`/`assistant` `text` blocks), the **paths touched** (`toolUseResult.filePath`), **what the turn ran** (`tool_use` block inputs), **what it was reasoning about** (`thinking` blocks), and the title.
- Deliberately **not** tool output: "handshake" appears 133 times in this store and not once in a message (96 in `attachment` entries, 30 in tool results), so searching output returns every session that ever read the file.
- A `tool_use` input skips path fields (`file_path` and friends), since the call's `toolUseResult` already reports that path as a `file` match. Remaining string fields are read in `TOOL_FIELDS` order then alphabetically (`pairs` order is not stable, and a result list that reorders itself between identical queries is worse than a dull order).
- **Match priority is decided over the whole file** (`SEARCH_KINDS`: said → file → ran → thought), not within an entry. Per-entry ranking let reasoning take every row ("windows": 26 thinking vs 6 message lines per-entry; 5 vs 24 globally). The scan collects into a **bag keyed by kind**, stopping when the top tiers are full (`bag_done`) or at `limit * 3` of anything.
- Matching is **literal and smartcase** (`transcript.compile_query`); case-insensitivity is compiled into a Lua pattern (`[aA]`) rather than lowering the haystack.
- **There is no index.** Each query past the debounce re-reads the store and is cancelled by the next keystroke. Affordable because the prefilter runs on the **raw JSON line** (non-matching lines are never decoded) and a scan stops at `max_per_session` (3). Measured on 32 transcripts / 88.9MB: a query matching nothing sweeps everything in ~830ms, with results streaming as each file finishes.
- Cost of raw-line prefiltering: a query containing a quote, backslash or newline is spelled differently in the file and will not be found. Ordinary words, paths and identifiers are fine.
- A line over `SEARCH_LINE_LIMIT` (256KB) is skipped rather than decoded, and walked a slice at a time.
- Scans run four at a time but results are stored **by session position**, so the list is in the sessions pane's order however reads finish. The cursor is anchored to its session across repaints.
- **Two windows**: the query is a real buffer (every editing key works), the list is `focusable = false` and never entered. `<C-n>`/`<C-j>`/`<Down>` and `<C-p>`/`<C-k>`/`<Up>` drive its cursor from the input; leaving the input cancels.
- Moving **previews** (`agents_view.preview_session` — `cycle_session`'s body reached from an id; panes follow, nothing starts), so `<Esc>` restores the selection the picker opened with.
- `<CR>` is `focus_terminal`'s intent (`agents_view.enter_session`): select, resume if stopped, land in it. The query outlives the picker and dies with the view.
- **The scan is not bounded by the list** (`M.SCOPES`, `<Tab>`/`<S-Tab>`): `visible` reads the pane's rows, `project` every transcript for this cwd (`transcript.list`), `disk` every project directory (`transcript.list_all`). It opens on `project` — the conversation being searched for is very often the one the window dropped, which is why you are searching — and the scope is remembered like the query, dying with the view (`search.reset`).
- Order follows the same rule as the list: **the pane's rows first, in the pane's own order**, then everything else by mtime. `sessions_for` dedupes by id, so a conversation the project pass already listed is not listed again by the store-wide one.
- A `disk` hit is resumed **in the directory it ran in**, read from the transcript by `transcript.cwd_of` (memoised, one bounded synchronous read) — the slug is not reversible. The row is labelled with that directory's tail, read only for rows that actually match.
- A hit with no row is **pinned** (`model.pin`) before the panes are pointed at it: every pane follows a row, and `select` reads the launch directory from one. Pins made while merely browsing are taken back when the picker is cancelled.
- No cap on a `disk` scan — it streams — but the paint is throttled (`REDRAW_MS`, 60ms; the last one is immediate) since a repaint is the whole list, and only `MAX_LISTED` (60) sessions are drawn, with a line saying how many more matched.

**Tasks pane (`agents/subagents.lua`)**

- Under Changes, split at `layout.sessions_height` so its divider lines up with Sessions/Activity; `state.sizes.changes` is snapshotted and restored like the other sizes. Draws the selected session's subagents **and background shells** as one tree: connectors, state glyph (`●` running, `✓` done, `✗` failed, `⊘` stopped), name, tokens, runtime. Internally still the `subagents` pane (keys, `state.wins`, config); only the winbar and help say `Tasks` — the CLI's own word for both kinds.
- The name column shows each run's `description` by default (several `general-purpose` rows are told apart only by it); `g.` (`keymaps.subagent_label`) toggles to the agent type, or a shell's command (`model.subagent_label`, lives on the view and dies with `detach`, like the Activity filter). The winbar marks only the non-default reading (`Tasks` / `Tasks · type/command`) instead of a notify. A description is collapsed to one line and falls back to the type when empty. The name's room floors at **1 cell**, not a readable minimum, so it is always cut with `…` rather than pushing the numbers past the window edge, where Neovim clips silently.
- **The store layout** (verified against CLI 2.1.270): each subagent has `<session>/subagents/agent-<id>.jsonl` plus `agent-<id>.meta.json` (`agentType`, `description`, `toolUseId`, `parentAgentId`, `spawnDepth`, `requestShape`). Nested subagents live in the **same flat directory**; `parentAgentId` makes the tree. A parent whose descriptor is unreadable puts its children at the top rather than dropping them.
- **How a run ends is recorded by its launcher, not by the subagent**: a background run gets a `<task-notification>` (`<status>`, `<subagent_tokens>`, `<duration_ms>`) in the launching transcript, written twice (a `queue-operation` enqueue, then the delivered `user` entry) — and for a nested run the enqueue also lands in the session's transcript. A foreground run gets the `Agent` call's `toolUseResult` with `totalTokens`/`totalDurationMs`. `transcript._fold_line` folds both into every summary (`task_notes` by agent id, `agent_results` by tool_use id), so `subagents.rows` merges the session's summary with every subagent's.
- `_task_notification` checks structurally, like `_is_interrupt_line`: only a `queue-operation` enqueue or a `user` entry whose whole string content is the notification (optionally after the `[SYSTEM NOTIFICATION` header). A tool result quoting one — reading a transcript does — is skipped before decoding.
- **A notification can be stale**: a resumed agent (sent another message) notifies again later. A note only ends the run when the subagent's newest line is no newer than it (same second counts as ended; the note is written after the last line).
- Live tokens: `_usage_tokens` decodes only the balanced `usage` object of the newest assistant line (input + cache creation + cache read + output ≈ the CLI's `subagent_tokens`; 167,704 vs 167,410 measured). Raw key matching was order-dependent because `usage.iterations` repeats the keys.
- **Running with no recorded end** requires the session to be live (`model.is_live`) or the subagent's transcript/descriptor to be written within `STALE_S` (10 min, the longest a single tool call may run). Otherwise its CLI exited without notifying anyone, and the row reads stopped. A foreground `Agent` call the interrupt marker resolved (`agent_calls[id].status`) is stopped too.
- **`<CR>` opens the run's transcript in a float** (`agents/subagent_view.lua`, routed through `open_row` like tool rows, so `<C-n>`/`<C-p>` stepping works; `next_open_row` counts `kind = "subagent"` rows). A pure core (`fold_line` → document, `render` → Markdown lines, marks, links, folds) is what the specs drive; `filetype = markdown`, so render-markdown/markview draw it.
  - Headline: `# <description>` in full, then `` `type` · state · tokens · runtime ``. The border title carries only type/state/cost (a border cuts at its right edge).
  - Tool **output is never rendered**, only summarised (`summarize_result`: `N lines`, `+A -R`, `N tokens`, `started in the background`, `✗ <first error line>`, `declined`). It is almost all of a subagent transcript (1.1MB and 1.7MB measured). A result line over 256KB is summarised from its raw text. File tools are named by their path relative to the session's cwd; labels are cut at 100 cells with `…`.
  - Thinking is a closed manual fold per block (`_thinking_` header), every line on `ClaudeCodeAgentsFoldable` (→ `ColorColumn`) so an open block reads as one piece; a closed one keeps Neovim's `Folded`. **`<Tab>` toggles the fold under the cursor** (`za`, nothing off a fold). It is mapped **before** `float.bind_close`, which skips any key the buffer already maps — otherwise its `<Tab>` (focus next float) wins. `l` still opens a fold only because of Neovim's own `'foldopen'` default, which is global and left alone.
  - Messages to the run (the prompt, later messages) are drawn like Claude Code's own: `›` (dimmed) then the text, continuation lines indented, every line on `ClaudeCodeAgentsPrompt` (→ `CursorLine`). No `## Prompt` heading.
  - **`<BS>` walks back up**: `<CR>` on a child passes `history` (the chain of `{ agent_id, lnum }` it came down), the child's header gets ``← `<BS>` back to <parent>``, and `<BS>` reopens the parent in the same float with the cursor on the line that opened the child. Live updates rewrite only from the **first line that changed** — for a running run that is line 2 every tick (its runtime) — and a cursor on the last line follows the end. Folds are therefore **rebuilt every rewrite, never re-applied** (`restore_folds`): each window's open/closed state is read per block ordinal before the rewrite, `zE` clears them, and each is recreated and reopened if it was open. `:fold` over a range that already holds a fold nests a new closed one inside it, so re-applying stacked a level per tick — `<Tab>` opened one and the float looked like it refused.
  - User entries: the first is the prompt; bracketed/tagged ones are the harness (`> …`); an interrupt is `> ⊘ interrupted`; a `<task-notification>` is a `finished:` line. A call with no result while the run is not running reads `⊘`.
  - A child run's `Agent` call line (matched by the child's `toolUseId`) and its notification line are **links**: buffer-local `<CR>` swaps that child into the same float (`reuse`), and `on_open` rebinds the stepping keys on the new buffer.
  - **Every other tool line is a call** (`render`'s fifth return, `{ tool_id, tool, label, path, read, status }`): `<CR>` → `open_call` opens exactly what the Activity pane opens for that row, reading the **run's own transcript** — `file_view.open` for `tools.FILE_TOOLS` with a path (`prefer = "read"` with the read window from `toolUseResult.file` for a `Read`, else the run's diff), `tool_view.open` otherwise. A new float stacked on top, never `reuse`, so `q` lands back in the transcript.
  - Reads are chunked through `transcript._io`, with an incomplete trailing line carried to the next read. **Folding is scheduled onto the main loop**: the read callback is libuv's fast context, where `vim.fn` (used by `utils.truncate`) raises `E5560`.
  - A 1s follow timer per buffer (stopped on `BufWipeout`) calls `subagents.refresh(session)` before pulling: the headline's state and tokens come from folds the pane keeps current only for the selected session. Measured end to end against a live run: calls appear with `…`, flip to `✓ · 2 lines`, and the title settles to the notification's figures.
- A running subagent keeps `model.poll` marking `dirty.subagents`, so the runtime ticks at `poll_ms` in hooks mode too, without taking the frame clock. `refresh_subagents` folds the session and every subagent transcript (a stat each when unchanged) and repaints only when one grew. Subagent summaries are left out of the warm cache file.

**Background shells (`subagents.rows`, `agents/shell_view.lua`)**

Only background shells and monitors — foreground shells are Activity rows already. Monitors ride the same record (`task_type = "monitor"`, drawn `~`, events where tokens go).

- **The store** (verified against CLI 2.1.270): a `Bash`/`PowerShell` `tool_use`, then a result whose `toolUseResult.backgroundTaskId` names the task (`b4mk05121`) and whose text says `Output is being written to: <path>`. The same field marks all three routes — `run_in_background`, Ctrl+B (`backgroundedByUser`), moved there on timeout. The end is a `<task-notification>` with `<tool-use-id>`, `<output-file>`, `<status>` (`completed`/`failed`/`killed`) and the exit code **only in `<summary>`** (`… (exit code 0)`, `… failed with exit code 144`), in the **launching** transcript — a subagent's own for its shells, enqueued in the session's too.
- **Output lives outside the store**: `<realpath($CLAUDE_CODE_TMPDIR or /tmp)>/claude-<uid>/<slug>/<session>/tasks/<id>.output` (read from the binary). The path is **read from the result text, never derived** (the temp root is platform- and symlink-dependent); the JSON-escaped separators are undone for Windows. Foreground shells stream to the same directory but their file is deleted on completion; background files persist until swept — a subagent's shell file was measured gone later. A missing file never reads as running.
- Folding (`transcript.lua`): `fold_tool_use` records every shell call in `sum.shell_calls` (regardless of `feed_tools` — the tool_use branch now decodes Bash/PowerShell lines even with tool rows off). `settle_shell` runs on result lines **raw, never decoded** (a foreground result carries its whole output): it drops the pending call and, when `"backgroundTaskId":"` is present unescaped, promotes it to `sum.shells[task_id]`. An interrupt marker clears `shell_calls`. `_task_notification` now also returns `tool_use_id`, `output_file`, `exit_code`.
- `subagents.rows` walks shells as nodes of the same tree (parent = the subagent whose transcript holds the shell), sorted by start with the subagents. `shell_state`: a note decides (non-zero exit → failed); without one, a stat of the output file — gone → stopped; else running if the session is live or the file was written within `STALE_S`. `ended` (a note exists) is what lets a float stop following.
- Pane row: `$ ` after the glyph, tokens field blank. Payload `{ kind = "shell", task_id, tool_id, transcript }`; `next_open_row` counts it.
- **`shell_view`**: header (`# description`, the command under its prompt via `tools.command_lines`, status line, `tools.rule` over the output), then the file tailed on a 500ms timer. `feed` splits on `\n`, keeps what follows a line's last `\r` (progress bars; a trailing CR is a CRLF, not a redraw), carries SGR state across reads (`ansi.parse(lines, state)`), and draws the unfinished last line from a **copy** of that state, replaced when the rest lands. The first read starts `TAIL_BYTES` (1MB) from the end, dropping the partial first line; the buffer keeps `MAX_LINES` (10k). Everything left out, a missing file, or "nothing yet" is said on the rule. Cursor on the last line follows; elsewhere it stays put. Status and title re-derive per tick via `row_for` (the pane's rows, which know liveness) else `subagents.rows`; `subagents.refresh(session)` is called first since the notification lands in a transcript the pane only folds for the selected session. The timer stops one quiet tick after a recorded end (the last write can trail the notification). Measured live against a real background shell: output streamed, `\r` bars collapsed, status flipped to `✗ exit 3 · 0:26`, timer stopped.
- **Monitors** (verified against CLI 2.1.270 by running each ending): call `Monitor` with `command` **or** `ws.url`, `description`, `timeout_ms`, `persistent`; result `{taskId, timeoutMs, persistent}` whose text names **no output path** — yet one exists at `tasks/<id>.output` (stdout, stderr prefixed `[stderr] `). `subagents.tasks_dir` takes the directory from any path the session's records state, else the binary's rule (not applied on Windows; checked to match the real directory). Each event is a `<task-notification>` with `<event>` and **no `<status>`** — `_task_notification` must not default those to `completed` (it did, which would end a monitor on its first event); they fold into `sum.task_events` (counted from the `queue-operation` copy only, since each is written again on delivery). Ends: exit → a status notification (`… script failed (exit 2)` — `exit N`, not `exit code N`; a clean end says `stream ended` with no code, so the footer's code is used); **expiry → only a last event** `[Monitor expired after …]` (older CLIs: `[Monitor timed out …]`).
- **Ends nothing notifies**: a shell or monitor stopped with `TaskStop` gets **no notification** — its only transcript record is the TaskStop result `{message = "Successfully stopped task: …", task_id, task_type = "local_bash"}` (`note_task_stop` → `sum.task_stops`). The CLI also closes every task's output file with `\n[exited with code N]\n` or `\n[killed]\n` (stopped, or expired); `subagents.output_footer` reads the last 128 bytes (`_io.read_tail_sync`, cached by size/mtime) as the backstop. `shell_state` precedence: status notification → TaskStop → expiry event → footer → resume guess → file gone (stopped) → live/recent (running). `how` = `killed`/`expired`/`orphaned`.
- **A resumed CLI guesses**: on resume it writes `<status>stopped</status>` with `Background shell command didn't finish before the previous session ended` for every task it found no end for — including ones whose end _was_ recorded in a form it does not count (a monitor's expiry event). `_task_notification` marks those `orphaned`, and `shell_state`/`workflow_state` rank them below every recorded end; their timestamp is the resume, so runtime comes from the output file's last write.
- The fold's table is `sum.tasks` (shells, monitors, workflow runs) with pending calls in `sum.task_calls`; rows keep `kind = "shell"` for shells and monitors (they share `shell_view`) and `kind = "workflow"` for runs.

**Workflow runs (`subagents.scan_workflow`, `agents/workflow_view.lua`)** (verified against CLI 2.1.272 by running completed, failed and stopped probes)

- Launch result: `{status = "async_launched", taskId, taskType = "local_workflow", workflowName, runId, summary, transcriptDir, scriptPath}` — small, decoded in `settle_shell`. A `remote_launched` run has nothing local and is skipped.
- The agents are subagents of their own under `<session>/subagents/workflows/<runId>/` (`agent-<id>.jsonl` + meta with `agentType = "workflow-subagent"`, `description` = label, `workflowPhase`) — **not** the flat `subagents/` directory, so `scan` never lists them as orphans. Beside them `journal.jsonl` (`launched`/`started`/`result`/`failed` by `agentId`) is the only record that moves while the run does.
- `<session>/workflows/<runId>.json` (status `completed`/`failed`/`killed`, `error`, `logs`, `result`, `totalTokens`, `durationMs`, per-agent `workflowProgress` with `state` `start`/`progress`/`done`/`error`, `tokens`, `durationMs`) is written **only when the run ends**, every ending. The task's `tasks/<id>.output` is empty until then, so it is not used.
- Ends: a status notification (`Dynamic workflow "…" completed|failed: …|was stopped`, `<usage>` with `subagent_tokens`/`duration_ms`); a stopped run gets **no notification** (TaskStop result, `task_type = "local_workflow"`), but its record says `killed`. `workflow_state` precedence: notification → record → TaskStop → resume guess → live/recent (journal or agent transcripts written within `STALE_S`).
- `rows` walks sources by index because it grows them: each run's agent transcripts become sources with the agent as parent, so their shells and monitors nest under them. Agent rows are `kind = "subagent"` with `workflow`, `phase` and `path` (their transcript); state from the record's progress, else the journal, else the run's own state (a run that ended with an agent unfinished cut it off → stopped). `subagent_view.open` takes `path` (and threads it through `<BS>` history) for them. `refresh` folds the agent transcripts too.
- `workflow_view`: header, agents grouped by phase in journal order (each line `<CR>` → subagent float stacked on top), then Error (left out for `killed` — it is only the abort's stack), Result (pretty JSON, first 40 lines) and Log from the record. Repainted per 1s tick from the pane's rows (`opts.rows`), stopping one tick after the end. `tool_view` hands a `Workflow` launch to it, and a subagent transcript's Workflow call/notification lines route to it through `open_call`.
- **Foreground commands** (`subagents.foreground_output`, verified against CLI 2.1.272): a running foreground shell streams to `tasks/<id>.output` too, and the file is **deleted when the command returns** — but its id reaches the transcript only with the result, so the file is matched to the call. Measured: the call is written ~0.9s before the file is created (at spawn); a conversation's Bash calls run one at a time even when issued in parallel; overlap happens only across conversations (a subagent beside its parent). Matching: running = every pending `task_calls` entry across the session, its subagents and workflow agents (monitor/workflow launches not yet folded own unclaimed files too); unclaimed = files whose id is no task, notification or subagent of the session, created after the earliest running call − 2s; answered only for one-and-one, or equal counts paired by start order (`task_calls[].at` — the ISO timestamp's fraction, `_iso_to_epoch_precise` — against `_io.stat().birth`, the file's birthtime) with no file older than its call. Without birthtimes only one-and-one.
- `tool_view.open` on a running `Bash`/`PowerShell` call follows it in `shell_view` (`foreground = { output_path, started, tool, description }`, a row synthesized from the call). A float opened before the file exists shows "still running" and **retries** every `RETRY_MS` (`wait_for_output`): the file appearing upgrades it in place, the result landing shows the finished call. The live float hands off the same way (`handed_off`: `task_calls[tool_id]` gone after `subagents.refresh`) to `tool_view.open` with `reuse`; `on_handoff` rebinds the pane's stepping keys on the new buffer. Measured live: waiting → live ticks → finished stdout in one window.
- **Every door opens it**: the Tasks row; `tool_view.open` delegates when `toolUseResult.backgroundTaskId` is set (so an Activity row does too, passing the command it already read); in a subagent transcript, `context` maps shells by tool_use id so the call line shows the shell's glyph (`in the background · exit N · 0:42`) and its `<task-notification>` line resolves to the shell rather than a subagent link, both routed by `open_call` on `call.shell`.

**Help (`?` / `keymaps.help`, `agents/help.lua`)**

- Lists the keys reaching the pane the cursor is in, grouped "this pane" then "anywhere in the view". A float via `snacks.win`, else `nvim_open_win`, into a scratch buffer we render and highlight ourselves so both paths match. A second `?` toggles it shut.
- Contents come from `KEY_SPECS`, the **same table `bind_keys` binds from**, filtered by pane and by what the user left bound.
- Headers/keys use `ClaudeCodeAgentsHelpHeader`/`ClaudeCodeAgentsKey` (linked to `Title`/`Special`, overridable via `agents.highlights.header`/`key`).

### 13. Floating Windows

Where a diff or file goes when there is no editor window: the agents tab (every window is an excluded pane) and `diff_opts.layout = "float"`.

- Floats **cascade** — each offset from the last, newest on top, title in the border, stack clamped so it never walks off screen. Several agents work at once and diffs arrive faster than you answer them; queueing would block a waiting CLI.
- Each carries `claudecode_live_preview` and `claudecode_float` so a second diff never targets the first's window.
- **The title says where the file is** (`utils.path_title`): the path relative to a root — the session's cwd for a pane float, the editor's own directory for a diff float unless a caller passes `root` — `~`-shortened when it is outside that root, with the note (`(vs HEAD)`, `·  <agent>`) after it. Fitted by the caller against `float.title_width()`, since Neovim cuts an over-long title at its **right** edge, which is the filename; `utils.shorten_path` drops interior directories instead. `diff.open_float` resolves the host module first so it fits to that module's geometry, not the global block's.
- `utils` owns `truncate`/`shorten_path`/`relative_path`/`path_title`; `agents/render.lua` re-exports the first three. They started there, but `claudecode.float` and `claudecode.diff` need the same rules and core modules cannot require an opt-in feature.
- **The user's own display settings are applied, not inherited.** A float copies window-local options from the _current_ window, usually an agents pane with `wrap`/`number`/`list` off for fixed-width rows, and `style = "minimal"` wipes them again. `apply_user_options` runs after the window opens and puts the globals (`vim.go.*`) back on top. `fillchars` is left to `minimal` (frame chrome, not a reading preference).
- **A reused float is dressed again after every swap** (`reuse_window` → `apply_window_options`): putting a buffer in a `minimal` float re-applies minimal style (measured, 0.12.2), resetting `number` and `winhighlight`, so `<C-n>`/`<C-p>` stepping lost the line numbers and the border colour on the first step. The border group is kept on the registry entry for the swap.
- **Every window option this plugin sets goes through `utils.set_win_option`, which passes `scope = "local"`.** `vim.wo[win].x = v` and `nvim_set_option_value(…, {win = w})` behave like `:set`, not `:setlocal`, when `w` is the current window — so they write the user's global. A pane is current while being built, so this leaked `wrap=false number=false list=false` into the user's globals for the rest of the session.
- Geometry comes from the **top-level `float` block**, overridden by a feature's own table (`agents.float`). That split is why the module was extracted from `agents/float.lua`: `layout = "float"` used to take its geometry from a feature the user may have disabled. `config.validate_float` is shared by both blocks so key lists cannot drift.
- `agents/float.lua` is now a thin wrapper supplying the session id, agents geometry and the `claudecode_agents_float` tag. **The stack is shared**, so agent floats and plain diff floats cascade past each other, and `diff.lua`'s cleanup closes a float through this module whichever door it came in by.
- **Terminal insert mode is restored**: entering a float leaves terminal-mode, so dismissing a diff handed focus back in normal mode. The mode is read in `create` _before_ `nvim_open_win`, and the current window is only taken as the answer when it actually holds a terminal (`terminal_mode_window`) — a diff float is opened inside `nvim_win_call` (`diff.in_owning_tab`), which makes another window current while `mode()` still says `t`. `_setup_blocking_diff_unified` therefore reads the terminal _before_ entering `in_owning_tab` and passes it as `term_win`. Restore happens from a `WinClosed` autocmd (a float also goes away by `:w`, `:q` and a closing tab), then from `vim.schedule` (focus has not moved yet inside `WinClosed`), and only when the close actually returns to that terminal window.
- `bind_close` gives a float `q` and `<Tab>`. Because a float can hold a **real file buffer** (`open_file`), a mapping somebody else made is left alone, and ours are deleted on `WinClosed` — tied to the window, not to `M.close`, since `:q`, `<C-w>c` and a closing tab never reach it. Otherwise every file Claude showed you would carry a window-closing `q` forever.

---

### WebSocket Server Implementation

- **TCP Server**: `server/tcp.lua`. Port selection has two non-obvious constraints:
  - **`bind()` does not prove a port is free**: libuv sets `SO_REUSEADDR` on every TCP bind, and on macOS the bind succeeds even when another process is listening — only `listen()` reports the conflict. `_port_is_free` binds _and_ listens; `create_server` skips the probe entirely, binding and listening on the real socket and moving to the next candidate (up to `MAX_BIND_ATTEMPTS`) rather than failing the start.
  - The candidate shuffle is seeded in `server/utils.lua` mixing pid and `vim.loop.hrtime()` — `os.time()` alone has one-second resolution, so two Neovims started in the same second picked the same port.
- **Handshake**: `server/handshake.lua` — HTTP upgrade with authentication.
- **Frame Processing**: `server/frame.lua` — RFC 6455 frames.
- **Client Management**: `server/client.lua`.
- **Utils**: `server/utils.lua` — base64, SHA-1, XOR in pure Lua.

#### Authentication

- **128-bit tokens**: 32-char lowercase hex from the OS CSPRNG, per session.
- **Header**: `x-claude-code-ide-authorization`.
- **Discovery**: tokens stored in `~/.claude/ide/[port].lock`.
- Server accepts only local connections (127.0.0.1).

### MCP Tools

All tools return MCP-compliant `{content: [{type: "text", text: "JSON-stringified-data"}]}` and match the VS Code extension's behaviour and output.

**MCP-exposed** (with JSON schemas): `openFile` (optional startLine/endLine, preview mode, text pattern matching, makeFrontmost), `getCurrentSelection`, `getLatestSelection`, `getOpenEditors` (VS Code-compatible `tabs` structure), `openDiff`, `checkDocumentDirty`, `saveDocument`, `getWorkspaceFolders`, `closeAllDiffTabs`, `getDiagnostics`.

**Internal** (not exposed): `close_tab`.

Tools with `schema = nil` are internal-only; see `lua/claudecode/tools/init.lua` for registration.

- JSON payloads are encoded compactly — no `indent`, which only spent tokens.
- `getDiagnostics` answers in VS Code's shape: one text block holding `[{uri, diagnostics: [{message, severity, range, source, code}]}]`, grouped per file, with **LSP ranges** (0-based lines and characters) and severity **names**, not Neovim's numbers. Claude parses that shape.
- `openFile` applies its selection inside the window the file landed in, which is not the current one for a background open (`makeFrontmost = false`) or a float.
- A path is expanded with `utils.expand_tilde`, never `vim.fn.expand`, which reads `$name` as an environment variable and drops undefined ones — mangling a literal `$` in a path (`src/routes/$post.tsx`). `:ClaudeCodeAdd` still expands the `%`/`#`/`<cfile>` token forms, since `:ClaudeCodeAdd %` is the documented "add this buffer" keymap.
- The `initialize` response advertises no `resources` capability: we implement none.

### Health Check

`:checkhealth claudecode` (`lua/claudecode/health.lua`) reports the prerequisites (Neovim version, `setup()` called, the CLI on `$PATH` and its version, terminal provider, unified.nvim) and then **every running instance** — a tab's own Claude and each agent — with its port, lock file and connected clients. It launches nothing.

### Terminal Integration

- **Snacks.nvim**: `terminal/snacks.lua`
- **Native**: `terminal/native.lua`
- **External**: `terminal/external.lua`

```lua
opts = {
  terminal = {
    provider = "external",  -- "auto", "snacks", "native", "external"
    external_terminal_cmd = "alacritty -e %s"  -- required for external
  }
}
```

### Key File Locations

- `lua/claudecode/init.lua` — entry point and setup
- `lua/claudecode/config.lua` — configuration
- `plugin/claudecode.lua` — plugin loader with version checks
- `tests/` — unit, component, integration suites

## Configuration Options

### Diff Options

- `layout` (`"vertical"`|`"horizontal"`, default `"vertical"`) — split direction.
- `keep_terminal_focus` (default `false`) — keep focus in the terminal when a diff opens, so terminal keybindings like `<CR>` still accept/reject.
- `open_in_new_tab` (default `false`).
- `hide_terminal_in_new_tab` (default `false`) — in the new tab, do not show the Claude terminal split.
- `on_new_file_reject` (`"keep_empty"`|`"close_window"`, default `"keep_empty"`).
- Legacy aliases: `vertical_split` (→ `layout`), `open_in_current_tab` (inverse of `open_in_new_tab`).

```lua
require("claudecode").setup({
  log_level = "debug",
  diff_opts = {
    layout = "vertical",
    keep_terminal_focus = true,
    open_in_new_tab = true,
    hide_terminal_in_new_tab = true,
    on_new_file_reject = "keep_empty",
  },
})
```

## Testing Architecture

Three layers:

- **Unit** (`tests/unit/`) — individual functions in isolation
- **Component** (`tests/component/`) — subsystems with a controlled environment
- **Integration** (`tests/integration/`) — end-to-end with a mock Claude client

Files match `*_spec.lua` / `*_test.lua`, busted framework. Custom JSON encoder/decoder in `tests/busted_setup.lua` handles nested structures, Lua keywords as keys (`["end"]`), and MCP message validation.

Principles: isolation (no external state), comprehensive vim-API mocking, positive/negative/edge cases, fast execution, descriptive names.

**Tool test pattern**:

```lua
local result = tool_handler(params)
expect(result).to_be_table()
expect(result.content).to_be_table()
expect(result.content[1].type).to_be("text")
local parsed = json_decode(result.content[1].text)
```

**Error format**:

```lua
error({
  code = -32602,  -- Invalid params
  message = "Description of the issue",
  data = "Additional context"
})
```

### Authentication Testing

- `tests/lockfile_test.lua` — token generation/uniqueness, lock file creation, reading tokens, missing/invalid token handling
- `tests/unit/server/handshake_spec.lua` — valid/invalid/missing tokens, empty tokens, malformed headers, length limits, case-insensitive headers
- `tests/unit/server_spec.lua` — startup with tokens, token state across lifecycle
- `tests/integration/mcp_tools_spec.lua` — full auth flow, persistence across operations, concurrent operations

Manual checks:

```bash
# Auth token from lock file
cat ~/.claude/ide/*.lock | jq -r .authToken

# Should succeed
websocat ws://localhost:PORT --header "x-claude-code-ide-authorization: $(cat ~/.claude/ide/*.lock | jq -r .authToken)"

# Should fail
websocat ws://localhost:PORT --header "x-claude-code-ide-authorization: invalid-token"
websocat ws://localhost:PORT

# Interactive script reads the token automatically
cd scripts/ && ./claude_interactive.sh
```

Log levels: DEBUG for successful auth/connection/handshake detail, WARN for handshake auth failures, ERROR for token generation and handshake response errors. Use INFO sparingly, only for events users need to know about.

## Development Notes

- Requires Neovim >= 0.8.0; only built-ins (`vim.loop`, `vim.json`, `vim.schedule`); zero external dependencies for core functionality.
- Selection tracking is debounced; WebSocket frames optimized for JSON-RPC payload sizes; connections pooled and cleaned up.
- Compatible with nvim-tree, oil.nvim, neo-tree, mini.files.

## Release Process

Update the version in **all** of these:

1. `lua/claudecode/init.lua` — `M.version = { major, minor, patch, prerelease }` (remove `prerelease` for stable)
2. `scripts/claude_interactive.sh` — three client version references (~line 52 handshake, ~223 initialize, ~309 reconnect)
3. `scripts/lib_claude.sh` — ClaudeCodeNvim version (~line 120, init message)
4. `CHANGELOG.md` — date, features and fixes with PR references, development improvements

```bash
gh pr list --state merged --base main --json number,title,mergedAt,url --jq 'sort_by(.mergedAt) | reverse'
git log --oneline v0.1.0..HEAD
mise run all
rg "0\.1\.0" .  # only CHANGELOG.md historical entries should remain
```

## Development Workflow

**Always run `mise run all` before committing.** Many PRs fail CI because this was skipped.

1. Read existing tests and docs to understand the system
2. Follow existing patterns and conventions
3. `mise run all`
4. Update docs (this file, PROTOCOL.md)
5. Commit

### Adding an Integration (file explorer, terminal)

1. Implement support in the relevant modules
2. **Required**: add a complete fixture config in `fixtures/[integration-name]/`, including `dev-claudecode.lua` with dev keybindings
3. Verify with `vv [integration-name]`
4. Document the integration and any integration-specific behaviour
5. `mise run all`

### Adding an MCP Tool

1. Follow the structure in `lua/claudecode/tools/`
2. Return `{content: [{type: "text", text: JSON}]}`
3. Add a JSON schema if the tool should be MCP-exposed
4. Unit **and** integration tests required
5. Add it to the MCP tools list above

### Quality Gates

1. `mise run check` — 0 warnings
2. `mise run test` — all passing (320+ tests)
3. `mise run format`
4. MCP format validation
5. End-to-end protocol flow verification
