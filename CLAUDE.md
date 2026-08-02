# CLAUDE.md

This file provides context for Claude Code when working with this codebase.

## Project Overview

claudecode.nvim - A Neovim plugin that implements the same WebSocket-based MCP protocol as Anthropic's official IDE extensions. Built with pure Lua and zero dependencies.

## Common Development Commands

### Testing

- `mise run test` - Run all tests using busted with coverage
- `busted tests/unit/specific_spec.lua` - Run specific test file
- `busted --coverage -v` - Run tests with coverage

### Code Quality

- `mise run check` - Check Lua syntax and run luacheck
- `mise run format` - Format code with treefmt
- `luacheck lua/ tests/ --no-unused-args --no-max-line-length` - Direct linting

### Build Commands

- `mise run all` - **RECOMMENDED**: Run formatting, linting, and testing (complete validation)
- `mise run test` - Run all tests using busted with coverage
- `mise run check` - Check Lua syntax and run luacheck
- `mise run format` - Format code with treefmt
- `mise run clean` - Remove generated test files
- `mise tasks` - List available tasks

**Best Practice**: Always use `mise run all` at the end of editing sessions for complete validation.

### Development with mise

The dev toolchain is provisioned by [mise](https://mise.jdx.dev) (see `mise.toml`), which replaced the former Nix flake devShell.

- `mise install` - Install all tools (Neovim, LuaJIT, formatters, etc.)
- `mise run setup` - Build the Lua test rocks (busted/luacheck/luacov) into `./.luarocks`
- `mise run all` - Format, lint, and test
- `mise run format` - Format all files with treefmt
- Activate mise in your shell so its tools (and `fixtures/bin`) are on PATH — add `eval "$(mise activate bash)"` (or `zsh`/`fish`) to your shell rc. (`mise run <task>` works without activation.)

### Integration Testing with Fixtures

The `fixtures/` directory contains test Neovim configurations for verifying plugin integrations:

- `vv <config>` - Start Neovim with a specific fixture configuration
- `vve <config>` - Start Neovim with a fixture config in edit mode
- `list-configs` - Show available fixture configurations
- Source `fixtures/nvim-aliases.sh` to enable these commands

**Available Fixtures**:

- `netrw` - Tests with Neovim's built-in file explorer
- `nvim-tree` - Tests with nvim-tree.lua file explorer
- `oil` - Tests with oil.nvim file explorer
- `mini-files` - Tests with mini.files file explorer

**Usage**: `source fixtures/nvim-aliases.sh && vv oil` starts Neovim with oil.nvim configuration

## Architecture Overview

### Core Components

1. **WebSocket Server** (`lua/claudecode/server/`) - Pure Neovim implementation using vim.loop, RFC 6455 compliant
2. **MCP Tool System** (`lua/claudecode/tools/`) - Implements tools that Claude can execute (openFile, getCurrentSelection, etc.)
3. **Lock File System** (`lua/claudecode/lockfile.lua`) - Creates discovery files for Claude CLI at `~/.claude/ide/`. A lock is deleted on `VimLeavePre`, which a crash or `kill -9` never reaches, so `cleanup_stale()` sweeps the directory once per Neovim (from `setup`, before any server claims a port). That directory is shared with every other editor and user, so the sweep is deliberately timid: `uv.kill(pid, 0)` decides liveness, and **only an explicit `ESRCH` counts as dead** — `EPERM` means the process is alive but owned by someone else, and an unparseable or pid-less lock is always left alone. This matters because Windows recycles pids aggressively; erring toward "alive" only leaks a lock file, while erring the other way deletes a live editor's. Discovery reaches these files only when `CLAUDE_CODE_SSE_PORT` is unset — i.e. our server failed to start — in which case the CLI scans the directory and may attach to _another_ editor, which is why `terminal.lua` logs an error rather than launching silently in that state
4. **Selection Tracking** (`lua/claudecode/selection.lua`) - Monitors text selections and sends updates to Claude
5. **Diff Integration** (`lua/claudecode/diff.lua`) - Native Neovim diff support for Claude's file comparisons. The unified (inline) provider scrolls the change into view with `center_diff_region`: `_measure_diff_region` reads unified.nvim's extmarks to get the changed line span **plus the deleted lines**, which are virtual lines hung off those marks and therefore invisible to a plain `zz` (they scroll off the top). `_diff_scroll_position` then centers the whole change when it fits the window, and otherwise pins its first changed line — with the lines deleted above it, via `topfill` — to the top. Applied with `winrestview`, since `topfill` is the only way to keep leading virtual lines on screen. Shared with the live cursor's edit preview, which renders the same marks.
6. **Terminal Integration** (`lua/claudecode/terminal.lua`) - Manages Claude CLI terminal sessions with support for internal Neovim terminals and external terminal applications
7. **Live Cursor** (`lua/claudecode/live_cursor.lua`) - Opt-in "ride-along" view. Injects a Claude Code `PreToolUse` hook at launch (via `claude --settings`, so user settings are untouched) that reports `Read`/`Edit`/`Write` tool events back over Neovim's RPC socket. The hook is a small cross-platform Lua script (`scripts/live_cursor_hook.lua`) run as `nvim --headless -u NONE -l` — no shell or POSIX tools, so it works identically on macOS, Linux, and native Windows. It reads the event JSON from stdin, `sockconnect`s to the launching Neovim (`CLAUDECODE_NVIM_SERVER`), and forwards it to `live_cursor.ingest`, stamped with the launching tabpage via `CLAUDECODE_NVIM_TAB` so background-tab Claudes don't preview in the current tab. Reads highlight the read line range; edits render a real inline diff via unified.nvim (`show_diff` reconstructs the pre-edit file and calls `unified.diff.show_against_text`), falling back to a line highlight when unified.nvim is absent. `Write` is handled separately by `show_write`: the hook fires _before_ the tool runs, so a file Claude is creating does not exist yet — opening the path would show an empty buffer that never fills in (the write may only land once you answer the permission prompt, or never if you reject it). The payload already carries the whole file in `tool_input.content`, so that is rendered directly, diffed against the pre-write content — `""` for a new file, so every line reads as an addition; for an overwrite, the on-disk text **snapshotted synchronously in `dispatch`**, since the deferred preview would otherwise read a file the write had already replaced and diff it to nothing. Without unified.nvim it still shows the content, just undiffed. All snippet/content text goes through `split_lines`, which strips the CR of a CRLF file as well as the trailing empty element: every line we compare against comes from `readfile()`, which already removed it, so without this a Windows file's every line would mismatch and the whole file would read as changed. Reads and edits are suppressed when a review diff already owns the file (`diff.is_live_for_file`), and the diff calls `live_cursor.on_diff_opened` the instant it opens to dismiss any in-flight preview (closing the race where the preview opens just before the diff registers as pending). Without this coordination the preview and the diff fight over the same window — which can leave the diff's `acwrite` buffer in a state where accepting with `:w` fails (`E676`). `diff.find_main_editor_window` also skips the preview split (tagged with the `claudecode_live_preview` window var) so a diff never opens into it. Both modes resolve their target editor window via `diff.find_window_closest_to_terminal` (the same geometry-based finder the plan view uses), falling back to `find_main_editor_window`. Each previewed file is opened with `bufadd`/`bufload`, so to keep the buffer list from growing one entry per file Claude touches over a long session, the module tracks the buffers it created (`state.owned_bufs` — a file you already had open is never owned, gated on a pre-`bufadd` `bufexists` check) and reaps them via `reap_owned` once they leave the screen: on every `show`/`show_diff`/`show_write`, on idle-close, on `on_diff_opened`, and on `cleanup`. A still-displayed, currently-active (`last_buf`), or modified buffer is left alone (`force=false` so unsaved changes refuse deletion) and retried on a later pass — but `last_buf` is cleared when the inactivity timer fires (and in `on_diff_opened`), so the last file of a burst is reaped too instead of lingering forever as a loaded, **unlisted** buffer that no buffer picker shows. That leftover buffer is what made the preview marker haunt a later plain `:edit`: Neovim remembers window-local options **per (window, buffer) pair**, so a window that once wore the preview `winbar` re-applies it the next time that same buffer returns to it — no code of ours involved, long after the preview is over. Three things contain that. `apply_preview_marker` snapshots the window's own `winbar`/`winhighlight` before overwriting them (`state.marker`) and `strip_preview_marker` puts them back rather than blanking them — `winhighlight` is window-local only, never remembered per buffer, so blanking would silently drop a user's or plugin's setting. Every buffer swap we make goes through `swap_preview_buf`, which strips the marker _before_ `nvim_win_set_buf` so the options Neovim snapshots for the outgoing buffer are the window's own, and records `state.preview_buf` _before_ the swap because `BufWinEnter` fires synchronously inside it. And a `BufWinEnter`/`WinEnter`/`BufWinLeave` watcher (`ensure_preview_watcher`, armed from `setup`) notices anyone else putting a buffer in the preview window — a file picker, a `:edit`, a jump — and calls `release_preview_window`, which restores the options, drops the `claudecode_live_preview` tag, and forgets the window. The idle close does the same instead of leaving a focused preview window marked forever: it hands the window over (`handover = true` also unowns the buffer shown there and lists it, so it behaves like a file the user opened).
8. **Plan View** (`lua/claudecode/plan_view.lua`) - Opt-in. Renders Claude's plan-mode plan in an editor split, like the VS Code extension. Claude presents a plan by calling its built-in `ExitPlanMode` tool (internal to the CLI — never sent over the MCP WebSocket), whose `tool_input.plan` carries the plan markdown. It rides the **same launch hook** as Live Cursor: `build_launch_injection` adds `ExitPlanMode` to the `PreToolUse` matcher (and a `PostToolUse` entry scoped to `ExitPlanMode`) whenever the plan view is enabled, even if Live Cursor is off. `live_cursor.dispatch` routes the event — `PreToolUse(ExitPlanMode)` (plan ready to read, before the user decides) → `plan_view.show`. Rather than opening its own split, the plan **takes over the editor window closest to the Claude terminal** (`diff.find_window_closest_to_terminal`, which reuses `find_main_editor_window` for suitability and picks by screen geometry via `_closest_rect_index`); it records the displaced buffer/cursor and restores them on resolve. The hosting window is tagged with the `claudecode_live_preview` var (cleared on restore) so review diffs skip it while the plan shows. Only when there is no editor window to reuse does it fall back to a created split (closed, not restored, on resolve). The plan is dismissed on resolution: `PostToolUse(ExitPlanMode)` (user accepted) or the next tool event of any kind (covers reject → replan and accept → execute), both → `plan_view.close`. Tab-aware via the same `CLAUDECODE_NVIM_TAB` stamp. Falls back to the longest string in `tool_input` if the `plan` field is ever renamed.
9. **Terminal Links** (`lua/claudecode/terminal_links.lua`) - On by default. Click a file path in the Claude terminal to open it in the editor (VS Code parity) instead of the OS file explorer. Claude renders file references (`Read`/`Update`/`Write` headers, inline `path:line`) as OSC 8 hyperlinks carrying a `file://` URL, but inside Neovim's `:terminal` those clicks are forwarded to Claude, which shells out to the OS opener — and Neovim has no built-in "open hyperlink on click". So this module captures the OSC 8 URLs and intercepts the click itself. A `TermRequest` autocmd records the **set of linked file paths** for the terminal (`_url_to_path` handles absolute _and_ the relative `file://name` form Claude emits for cwd files shown by name). It deliberately does **not** track screen coordinates: Claude's TUI repaints/scrolls links to buffer rows that no longer match where the OSC 8 fired, so geometry-based lookup misses almost every real click (verified empirically). Instead a buffer-local `<LeftMouse>` map opens on **release** (opening on press races the trailing `<LeftRelease>`, which then starts a stray visual selection in the editor) and `_resolve_click` matches the **filename token under the cursor** against the captured paths — exact, `/<token>` suffix (basename or relative path → absolute), or a long substring (a wrapped multi-line path/filename's chunk); a bare word matching nothing is left for Claude. The file opens in the editor window closest to the terminal (`diff.find_window_closest_to_terminal`, the plan view's targeting), jumping to `:line` when shown; non-link clicks are re-fed so Claude's own mouse UI keeps working. A normal-mode `gf` keymap does the same for the path under the cursor. Enabling the feature also turns on `'mousemoveevent'` so Claude's own hover (link underline) works in `:terminal`. Config: `terminal_links = { enabled, click, key = "gf", mouse_motion }`.

10. **Session Persistence** (`lua/claudecode/session_state.lua`) - Opt-in (`session_persistence = "off"|"global"|"external"`). Restores each tab's Claude _conversation_ when a saved Neovim session is loaded. Every launch is stamped with a conversation id we choose — `terminal.get_claude_command_and_env` appends `--session-id <uuid v4>` (`utils.random_bytes`, shared with the lockfile's auth token) — so the chat has a stable name instead of one we would have to discover; a later start asks for it back with `--resume <uuid>`. `launch_args` is idempotent per tab (every terminal toggle rebuilds the command, so a tab keeps its id) and stands down entirely when the command already picks a conversation (`-r`, `-c`, `--session-id`, `--fork-session`, `--from-pr` — checked against the whole command, so a `terminal_cmd = "claude --continue"` is respected). The id is corrected by the launch hook: session persistence adds a `SessionStart` entry to `live_cursor.build_launch_injection` (injected even when live cursor and plan view are both off — an empty `PreToolUse` matcher would match every tool, so that entry is omitted instead), and `live_cursor.dispatch` feeds every payload's `session_id` to `note_session_id`, which makes the reported id authoritative after a `/clear` or a manual resume. **The module does no file I/O**: `capture()`/`restore()` exchange a versioned plain table so whatever already persists the user's Neovim session carries the ids — `"global"` mirrors it into `g:CLAUDECODE_SESSION` (`:mksession` writes it when `'sessionoptions'` has `globals`; re-applied on `SessionLoadPost`), `"external"` leaves storage to auto-session's `save_extra_data`/`restore_extra_data` or the shipped resession extension (`lua/resession/extensions/claudecode.lua`). Tabs are keyed by **tab number**, not tabpage handle: handles are not stable across a restart and `:mksession` cannot save tab-local vars, so position is the only identity a restored session reproduces. Restore is **lazy** — it arms tabs (`pending`) and the CLI only starts on that tab's next terminal toggle, so N restored tabs are not N processes at startup (`open_pending`, behind `:ClaudeCodeSessionRestore!`, forces the eager path: it switches to each armed tab, calls `terminal.ensure_visible`, and restores the original tab/window). `:ClaudeCodeSessionRestore` re-reads the `"global"` payload unconditionally but never gates the rest on that call's result — in `"external"` mode the session manager has already armed the tabs, and an earlier version returned early there, making the command a silent no-op for resession/auto-session users. It reports `pending_count()` without `!`. Bound to `<leader>aR` (only when `session_persistence` is not `"off"`, so the key stays free otherwise). A pending id is dropped rather than resumed if the tab's cwd changed (a conversation belongs to the directory it started in) or if no transcript exists — checked by globbing `<CLAUDE_CONFIG_DIR|~/.claude>/projects/*/<id>.jsonl`, which sidesteps the CLI's undocumented path-to-slug rule since ids are unique on their own. A tab that already has a live record is never retargeted by a restore. **Only ids the CLI wrote a transcript for are ever persisted** (`persistable_id`, applied in `capture()`): a minted id is a _name_, not a conversation, until the first message — the CLI creates the `.jsonl` only then, and `--resume` on such an id fails. Persisting one anyway is what made restores rot in place, verified against a real saved session: every eager restore (`<leader>aR`) opens a Claude in each armed tab, the tabs the user does not talk in save an unresumable id, the next restore drops exactly those and mints fresh ones — so half the tabs resumed and half started new, run after run. A record therefore also carries `fallback`, the last id of that tab that did exist, so an unproven id never overwrites a real conversation (it is set wherever a record is replaced: a fresh mint in `launch_args`, and the hook's `note_session_id` after a `/clear` or manual resume). A tab with neither is left out of the payload entirely — it opens fresh rather than being armed with garbage. `forget()` deletes the whole record, fallback included, so this never resurrects a chat the user closed. **A conversation the user closed is not restored**: `forget(tab)` drops the record when Claude's process ends while Neovim is still running. The two kinds of "the terminal closed" are told apart by ordering, verified empirically — on exit Neovim fires `VimLeavePre`/`VimLeave` _before_ `TermClose`, so a `TermClose` arriving while `M.state.shutting_down` is unset is the user's doing. The watcher uses `TermClose` rather than the providers' own exit hooks because during shutdown the job's `on_exit` never runs at all (and snacks only registers its `TermClose` when `auto_close` is on). `TermClose` reports only a buffer, and a hidden terminal is in no window, so `terminal.tag_terminal_tab` stamps `b:claudecode_tab` right after `provider.open` — every provider keys its state by the current tabpage, so that is the terminal's tab by construction. Any exit counts, including a crash. The **external** terminal provider has no terminal buffer and therefore no `TermClose`, so a Claude closed in an external terminal is still restored.

11. **Per-Tab Status** (`lua/claudecode/status.lua`) - Opt-in (`status = { enabled }`). Publishes each tab's Claude as `busy` / `waiting` (on you) / `idle` / `none`, for tablines, statuslines and third-party plugins — the question "which of my tabs is working and which one wants an answer?" has no answer from outside the CLI, since the MCP WebSocket only carries the editor actions Claude asks for, never the conversation's own state. So it rides the **same launch hook** as Live Cursor and the Plan View and folds Claude Code's lifecycle events into a state machine (`note`): `UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`PreCompact` → busy, `PreToolUse(ExitPlanMode)` → waiting (a plan is on screen for the user to accept), `Notification` → waiting with its message — _unless_ the message is the "waiting for your input" idle nudge, which is an idle timer, not a question — `Stop` → idle, `SessionStart`/`SessionEnd` → idle/none. `PostToolUse` is what makes `waiting` end: between answering a permission prompt and the tool's result **nothing else fires**, so without it a tab would read as waiting for the whole run. That is also why enabling this widens the injected `PreToolUse` matcher to `"*"` (and adds a `"*"` `PostToolUse`) instead of live-cursor's file-tool matcher: a `Bash` call must not read as idle. It is the one feature that costs a hook invocation (a headless `nvim`) per tool call — hence opt-in. State is keyed by **tabpage handle**, not tab number like `session_state`: nothing here outlives the Neovim session, and handles are never reused. `terminal.tag_terminal_tab` calls `note_launch` so a tab counts as having a Claude before its first hook event lands (never overriding a known state), and the `TermClose` watcher in `init.lua` — extended to arm for this feature too — clears the tab when Claude ends, on shutdown as well as on a user-closed chat. Changes emit `User ClaudeCodeStatusChanged` (`data = { tab, tabnr, state, prev, status }`) and, unless `auto_redraw = false`, a `redrawtabline`/`redrawstatus`; a repeat event that changes nothing user-visible is swallowed so a tabline is not redrawn per tool call. `since` marks when the _state_ was entered (a busy→busy tool change keeps it) so a consumer can age it. `get`/`all` hand out copies, so a consumer cannot corrupt the state. An icon may also be a **list of frames** (`M.SPINNER` reproduces the CLI's own spinner, read out of the shipped binary rather than approximated: six glyphs `· ✢ ✳ ✶ ✻ ✽` played forwards then backwards — the CLI builds `[...frames, ...frames.reverse()]`, so the turning points repeat and the motion breathes instead of jumping — advanced one frame per 120ms, which is our `spinner_ms` default, and with the last glyph swapped for `✻` when `$TERM` is `xterm-ghostty`, as the CLI does. All are single-width so a tabline does not jitter as they cycle — except on Windows and in Windows Terminal (`win32`, or `WT_SESSION`/`ConEmuANSI`, so WSL Neovim in that host counts too), where `✳` U+2733 — the one frame Unicode marks emoji-capable — is drawn with the colour emoji font, coloured and often double-width; there it becomes `✱` U+2731, the same asterisk with no emoji presentation); `icon()` then returns the current frame and a `spinner_ms` timer advances it. That timer is started/stopped by `sync_spinner` from every path that mutates `entries`, so it runs only while a tab actually shows an animated icon — it drives a repeating `redrawtabline`/`redrawstatus` of the whole UI, which must not outlive the work it depicts — and it never starts under `auto_redraw = false`, where the redraw is the consumer's to do.

### WebSocket Server Implementation

- **TCP Server**: `server/tcp.lua` handles port binding and connections. Port selection has two non-obvious constraints, both learned from a real `EADDRINUSE` on startup. First, **`bind()` does not prove a port is free**: libuv sets `SO_REUSEADDR` on every TCP bind, and on macOS that bind succeeds even when another _process_ is already listening there — only `listen()` reports the conflict. So `_port_is_free` binds _and_ listens, and `create_server` skips the probe entirely, binding and listening on the real socket and moving to the next candidate (up to `MAX_BIND_ATTEMPTS`) when a port turns out to be taken, rather than failing the whole start. Second, the shuffle that picks a candidate is seeded in `server/utils.lua`: `os.time()` alone has one-second resolution, so two Neovim instances started in the same second seeded identically, shuffled identically, and picked the _same_ port out of 55000 — the seed now mixes in the pid and `vim.loop.hrtime()`
- **Handshake**: `server/handshake.lua` processes HTTP upgrade requests with authentication
- **Frame Processing**: `server/frame.lua` implements RFC 6455 WebSocket frames
- **Client Management**: `server/client.lua` manages individual connections
- **Utils**: `server/utils.lua` provides base64, SHA-1, XOR operations in pure Lua

#### Authentication System

The WebSocket server implements secure authentication using:

- **128-bit Tokens**: 32-char lowercase hex from the OS CSPRNG, generated per session
- **Header-based Auth**: Uses `x-claude-code-ide-authorization` header
- **Lock File Discovery**: Tokens stored in `~/.claude/ide/[port].lock` for Claude CLI
- **MCP Compliance**: Follows official Claude Code IDE authentication protocol

### MCP Tools Architecture (✅ FULLY COMPLIANT)

**Complete VS Code Extension Compatibility**: All tools now implement identical behavior and output formats as the official VS Code extension.

**MCP-Exposed Tools** (with JSON schemas):

- `openFile` - Opens files with optional line/text selection (startLine/endLine), preview mode, text pattern matching, and makeFrontmost flag
- `getCurrentSelection` - Gets current text selection from active editor
- `getLatestSelection` - Gets most recent text selection (even from inactive editors)
- `getOpenEditors` - Lists currently open files with VS Code-compatible `tabs` structure
- `openDiff` - Opens native Neovim diff views
- `checkDocumentDirty` - Checks if document has unsaved changes
- `saveDocument` - Saves document with detailed success/failure reporting
- `getWorkspaceFolders` - Gets workspace folder information
- `closeAllDiffTabs` - Closes all diff-related tabs and windows
- `getDiagnostics` - Gets language diagnostics (errors, warnings) from the editor

**Internal Tools** (not exposed via MCP):

- `close_tab` - Internal-only tool for tab management (hardcoded in Claude Code)

**Format Compliance**: All tools return MCP-compliant format: `{content: [{type: "text", text: "JSON-stringified-data"}]}`

### Terminal Integration Options

**Internal Terminals** (within Neovim):

- **Snacks.nvim**: `terminal/snacks.lua` - Advanced terminal with floating windows
- **Native**: `terminal/native.lua` - Built-in Neovim terminal as fallback

**External Terminals** (separate applications):

- **External Provider**: `terminal/external.lua` - Launches Claude in external terminal apps

**Configuration Example**:

```lua
opts = {
  terminal = {
    provider = "external",  -- "auto", "snacks", "native", or "external"
    external_terminal_cmd = "alacritty -e %s"  -- Required for external provider
  }
}
```

### Key File Locations

- `lua/claudecode/init.lua` - Main entry point and setup
- `lua/claudecode/config.lua` - Configuration management
- `plugin/claudecode.lua` - Plugin loader with version checks
- `tests/` - Comprehensive test suite with unit, component, and integration tests

## MCP Protocol Compliance

### Protocol Implementation Status

- ✅ **WebSocket Server**: RFC 6455 compliant with MCP message format
- ✅ **Tool Registration**: JSON Schema-based tool definitions
- ✅ **Authentication**: 128-bit token-based secure handshake (32-char lowercase hex from the OS CSPRNG)
- ✅ **Message Format**: JSON-RPC 2.0 with MCP content structure
- ✅ **Error Handling**: Comprehensive JSON-RPC error responses

### VS Code Extension Compatibility

claudecode.nvim implements **100% feature parity** with Anthropic's official VS Code extension:

- **Identical Tool Set**: All 10 VS Code tools implemented
- **Compatible Formats**: Output structures match VS Code extension exactly
- **Behavioral Consistency**: Same parameter handling and response patterns
- **Error Compatibility**: Matching error codes and messages

### Protocol Validation

Run `mise run test` to verify MCP compliance:

- **Tool Format Validation**: All tools return proper MCP structure
- **Schema Compliance**: JSON schemas validated against VS Code specs
- **Integration Testing**: End-to-end MCP message flow verification

## Testing Architecture

Tests are organized in three layers:

- **Unit tests** (`tests/unit/`) - Test individual functions in isolation
- **Component tests** (`tests/component/`) - Test subsystems with controlled environment
- **Integration tests** (`tests/integration/`) - End-to-end functionality with mock Claude client

Test files follow the pattern `*_spec.lua` or `*_test.lua` and use the busted framework.

### Test Infrastructure

**JSON Handling**: Custom JSON encoder/decoder with support for:

- Nested objects and arrays
- Special Lua keywords as object keys (`["end"]`)
- MCP message format validation
- VS Code extension output compatibility

**Test Pattern**: Run specific test files during development:

```bash
# Run a specific test file (mise sets LUA_PATH automatically)
busted tests/unit/tools/specific_tool_spec.lua --verbose

# Or run the whole suite
mise run test  # Recommended for complete validation
```

**Coverage Metrics**:

- **320+ tests** covering all MCP tools and core functionality
- **Unit Tests**: Individual tool behavior and error cases
- **Integration Tests**: End-to-end MCP protocol flow
- **Format Tests**: MCP compliance and VS Code compatibility

### Test Organization Principles

- **Isolation**: Each test should be independent and not rely on external state
- **Mocking**: Use comprehensive mocking for vim APIs and external dependencies
- **Coverage**: Aim for both positive and negative test cases, edge cases included
- **Performance**: Tests should run quickly to encourage frequent execution
- **Clarity**: Test names should clearly describe what behavior is being verified

## Authentication Testing

The plugin implements authentication using 128-bit tokens (32-char lowercase hex) from the OS CSPRNG that are generated for each server session and stored in lock files. This ensures secure connections between Claude CLI and the Neovim WebSocket server.

### Testing Authentication Features

**Lock File Authentication Tests** (`tests/lockfile_test.lua`):

- Auth token generation and uniqueness validation
- Lock file creation with authentication tokens
- Reading auth tokens from existing lock files
- Error handling for missing or invalid tokens

**WebSocket Handshake Authentication Tests** (`tests/unit/server/handshake_spec.lua`):

- Valid authentication token acceptance
- Invalid/missing token rejection
- Edge cases (empty tokens, malformed headers, length limits)
- Case-insensitive header handling

**Server Integration Tests** (`tests/unit/server_spec.lua`):

- Server startup with authentication tokens
- Auth token state management during server lifecycle
- Token validation throughout server operations

**End-to-End Authentication Tests** (`tests/integration/mcp_tools_spec.lua`):

- Complete authentication flow from server start to tool execution
- Authentication state persistence across operations
- Concurrent operations with authentication enabled

### Manual Authentication Testing

**Test Script Authentication Support**:

```bash
# Test scripts automatically detect and use authentication tokens
cd scripts/
./claude_interactive.sh  # Automatically reads auth token from lock file
```

**Authentication Flow Testing**:

1. Start the plugin: `:ClaudeCodeStart`
2. Check lock file contains `authToken`: `cat ~/.claude/ide/*.lock | jq .authToken`
3. Test WebSocket connection with auth: Use test scripts in `scripts/` directory
4. Verify authentication in logs: Set `log_level = "debug"` in config

**Testing Authentication Failures**:

```bash
# Test invalid auth token (should fail)
websocat ws://localhost:PORT --header "x-claude-code-ide-authorization: invalid-token"

# Test missing auth header (should fail)
websocat ws://localhost:PORT

# Test valid auth token (should succeed)
websocat ws://localhost:PORT --header "x-claude-code-ide-authorization: $(cat ~/.claude/ide/*.lock | jq -r .authToken)"
```

### Authentication Logging

Enable detailed authentication logging by setting:

```lua
require("claudecode").setup({
  log_level = "debug",  -- Shows auth token generation, validation, and failures
  diff_opts = {
    keep_terminal_focus = true,  -- If true, moves focus back to terminal after diff opens
  },
})
```

### Configuration Options

#### Diff Options

The `diff_opts` configuration allows you to customize diff behavior:

- `layout` ("vertical"|"horizontal", default: `"vertical"`) - Whether the diff panes open in a vertical or horizontal split.
- `keep_terminal_focus` (boolean, default: `false`) - When enabled, keeps focus in the Claude Code terminal when a diff opens instead of moving focus to the diff buffer. This allows you to continue using terminal keybindings like `<CR>` for accepting/rejecting diffs without accidentally triggering other mappings.
- `open_in_new_tab` (boolean, default: `false`) - Open diffs in a new tab instead of the current tab.
- `hide_terminal_in_new_tab` (boolean, default: `false`) - When opening diffs in a new tab, do not show the Claude terminal split in that new tab. The terminal remains in the original tab, giving maximum screen estate for reviewing the diff.
- `on_new_file_reject` ("keep_empty"|"close_window", default: `"keep_empty"`) - Behavior when rejecting a diff for a new file (where the old file did not exist).
- Legacy aliases (still supported): `vertical_split` (maps to `layout`) and `open_in_current_tab` (inverse of `open_in_new_tab`).

**Example use case**: If you frequently use `<CR>` or arrow keys in the Claude Code terminal to accept/reject diffs, enable this option to prevent focus from moving to the diff buffer where `<CR>` might trigger unintended actions.

```lua
require("claudecode").setup({
  diff_opts = {
    layout = "vertical", -- "vertical" or "horizontal"
    keep_terminal_focus = true, -- If true, moves focus back to terminal after diff opens
    open_in_new_tab = true, -- Open diff in a separate tab
    hide_terminal_in_new_tab = true, -- In the new tab, do not show Claude terminal
    on_new_file_reject = "keep_empty", -- "keep_empty" or "close_window"

    -- Legacy aliases (still supported):
    -- vertical_split = true,
    -- open_in_current_tab = true,
  },
})
```

Log levels for authentication events:

- **DEBUG**: Server startup authentication state, client connections, handshake processing, auth token details
- **WARN**: Authentication failures during handshake
- **ERROR**: Auth token generation failures, handshake response errors

### Logging Best Practices

- **Connection Events**: Use DEBUG level for routine connection establishment/teardown
- **Authentication Flow**: Use DEBUG for successful auth, WARN for failures
- **User-Facing Events**: Use INFO sparingly for events users need to know about
- **System Errors**: Use ERROR for failures that require user attention

## Development Notes

### Technical Requirements

- Plugin requires Neovim >= 0.8.0
- Uses only Neovim built-ins for WebSocket implementation (vim.loop, vim.json, vim.schedule)
- Zero external dependencies for core functionality

### Security Considerations

- WebSocket server only accepts local connections (127.0.0.1) for security
- Authentication tokens are 128-bit tokens (32-char lowercase hex) from the OS CSPRNG
- Lock files created at `~/.claude/ide/[port].lock` for Claude CLI discovery
- All authentication events are logged for security auditing

### Performance Optimizations

- Selection tracking is debounced to reduce overhead
- WebSocket frame processing optimized for JSON-RPC payload sizes
- Connection pooling and cleanup to prevent resource leaks

### Integration Support

- Terminal integration supports both snacks.nvim and native Neovim terminal
- Compatible with popular file explorers (nvim-tree, oil.nvim, neo-tree, mini.files)
- Visual selection tracking across different selection modes

## Release Process

### Version Updates

When updating the version number for a new release, you must update **ALL** of these files:

1. **`lua/claudecode/init.lua`** - Main version table:

   ```lua
   M.version = {
     major = 0,
     minor = 2,  -- Update this
     patch = 0,  -- Update this
     prerelease = nil,  -- Remove for stable releases
   }
   ```

2. **`scripts/claude_interactive.sh`** - Multiple client version references:
   - Line ~52: `"version": "0.2.0"` (handshake)
   - Line ~223: `"version": "0.2.0"` (initialize)
   - Line ~309: `"version": "0.2.0"` (reconnect)

3. **`scripts/lib_claude.sh`** - ClaudeCodeNvim version:
   - Line ~120: `"version": "0.2.0"` (init message)

4. **`CHANGELOG.md`** - Add new release section with:
   - Release date
   - Features with PR references
   - Bug fixes with PR references
   - Development improvements

### Release Commands

```bash
# Get merged PRs since last version
gh pr list --state merged --base main --json number,title,mergedAt,url --jq 'sort_by(.mergedAt) | reverse'

# Get commit history
git log --oneline v0.1.0..HEAD

# Always run before committing
mise run all

# Verify no old version references remain
rg "0\.1\.0" .  # Should only show CHANGELOG.md historical entries
```

## Development Workflow

### Pre-commit Requirements

**ALWAYS run `mise run all` before committing any changes.** This runs code quality checks and formatting that must pass for CI to succeed. Never skip this step - many PRs fail CI because contributors don't run the build commands before committing.

### Recommended Development Flow

1. **Start Development**: Use existing tests and documentation to understand the system
2. **Make Changes**: Follow existing patterns and conventions in the codebase
3. **Validate Work**: Run `mise run all` to ensure formatting, linting, and tests pass
4. **Document Changes**: Update relevant documentation (this file, PROTOCOL.md, etc.)
5. **Commit**: Only commit after successful `mise run all` execution

### Integration Development Guidelines

**Adding New Integrations** (file explorers, terminals, etc.):

1. **Implement Integration**: Add support in relevant modules (e.g., `lua/claudecode/tools/`)
2. **Create Fixture Configuration**: **REQUIRED** - Add a complete Neovim config in `fixtures/[integration-name]/`
3. **Test Integration**: Use fixture to verify functionality with `vv [integration-name]`
4. **Update Documentation**: Add integration to fixtures list and relevant tool documentation
5. **Run Full Test Suite**: Ensure `mise run all` passes with new integration

**Fixture Requirements**:

- Complete Neovim configuration with plugin dependencies
- Include `dev-claudecode.lua` with development keybindings
- Test all relevant claudecode.nvim features with the integration
- Document any integration-specific behaviors or limitations

### MCP Tool Development Guidelines

**Adding New Tools**:

1. **Study Existing Patterns**: Review `lua/claudecode/tools/` for consistent structure
2. **Implement Handler**: Return MCP format: `{content: [{type: "text", text: JSON}]}`
3. **Add JSON Schema**: Define parameters and expose via MCP (if needed)
4. **Create Tests**: Both unit tests and integration tests required
5. **Update Documentation**: Add to this file's MCP tools list

**Tool Testing Pattern**:

```lua
-- All tools should return MCP-compliant format
local result = tool_handler(params)
expect(result).to_be_table()
expect(result.content).to_be_table()
expect(result.content[1].type).to_be("text")
local parsed = json_decode(result.content[1].text)
-- Validate parsed structure matches VS Code extension
```

**Error Handling Standard**:

```lua
-- Use consistent JSON-RPC error format
error({
  code = -32602,  -- Invalid params
  message = "Description of the issue",
  data = "Additional context"
})
```

### Code Quality Standards

- **Test Coverage**: Maintain comprehensive test coverage (currently **320+ tests**, 100% success rate)
- **Zero Warnings**: All code must pass luacheck with 0 warnings/errors
- **MCP Compliance**: All tools must return proper MCP format with JSON-stringified content
- **VS Code Compatibility**: New tools must match VS Code extension behavior exactly
- **Consistent Formatting**: Use `mise run format` (treefmt) for consistent code style
- **Documentation**: Update CLAUDE.md for architectural changes, PROTOCOL.md for protocol changes

### Development Quality Gates

1. **`mise run check`** - Syntax and linting (0 warnings required)
2. **`mise run test`** - All tests passing (320/320 success rate required)
3. **`mise run format`** - Consistent code formatting
4. **MCP Validation** - Tools return proper format structure
5. **Integration Test** - End-to-end protocol flow verification

## Development Troubleshooting

### Common Issues

**Test Failures with LUA_PATH**:

`mise` sets `LUA_PATH`/`LUA_CPATH` automatically (see `mise.toml` `[env]`), so prefer `mise run test` or run `busted` through the activated mise environment (`mise exec -- busted ...`). If a module still can't be found, you're likely running `busted` outside the mise environment.

**JSON Format Issues**:

- Ensure all tools return: `{content: [{type: "text", text: "JSON-string"}]}`
- Use `vim.json.encode()` for proper JSON stringification
- Test JSON parsing with custom test decoder in `tests/busted_setup.lua`

**MCP Tool Registration**:

- Tools with `schema = nil` are internal-only
- Tools with schema are exposed via MCP
- Check `lua/claudecode/tools/init.lua` for registration patterns

**Authentication Testing**:

```bash
# Verify auth token generation
cat ~/.claude/ide/*.lock | jq .authToken

# Test WebSocket connection
websocat ws://localhost:PORT --header "x-claude-code-ide-authorization: $(cat ~/.claude/ide/*.lock | jq -r .authToken)"
```
