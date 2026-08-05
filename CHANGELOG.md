# Changelog

## [Unreleased]

### Features

- Agents mode (`agents = { enabled = true }`, `<leader>aA`, `:ClaudeCodeAgents`): a tabpage running several Claudes on one project side by side, with the project's past and present sessions, each one's line counts and file activity, and the files it touched. Counts and titles come from Claude Code's own transcripts, so they cover conversations started outside the view and stay accurate while an agent is still working. Switching agents leaves the previous one running.
- Each agents-mode agent gets its own connection to Neovim, so a diff, a file open or an `@` mention reaches the agent it belongs to rather than every Claude sharing a tab.
- In agents mode, `<C-n>`/`<C-p>` select a session without starting it, so you can read what it did — its counts, files and activity all follow the selection — before deciding to reopen it. The centre pane names the conversation you landed on and the key that resumes it (`i`, the same key that puts you in a running agent, or `<CR>`), and the view opens already pointed at your newest session rather than at an empty pane. Inside a file float those keys step through the next and previous file of the pane the float came from instead, swapping the float's content in place and keeping the baseline you opened with; holding the key scrolls through the list and opens the row you settle on.
- The agents-mode session list no longer re-sorts itself. Every criterion worth sorting by moves while you are reading — one background agent finishing a tool call bumps its timestamp and its counts — so with several agents running, the session you were reaching for had moved by the time you got there. The order is now fixed once and rows keep their places; a session that starts later is sorted into its place once and pinned too. `gs` in any of the three list panes opens a menu to re-order by recent activity, name, changes or status (picking the criterion already in force reverses it), and `r` re-sorts as part of refreshing. The choice lasts as long as the view is open; `agents.sessions.sort` still sets what it opens with, and now takes `"name"`/`"changes"`/`"status"` alongside the older `"title"`/`"added"`.
- `diff_opts.layout = "float"` opens diffs in a floating window (requires unified.nvim; warns once and falls back to a split otherwise). Agents mode uses floats regardless, cascading and titled per agent so several are answerable at once.

- `:ClaudeCodeCloseAllDiffs` command to close pending Claude diffs at once (e.g. proposals orphaned by resolving them via Claude remote control). Diffs you have already accepted but whose file has not been written yet are left intact so saved edits are never discarded. ([#248](https://github.com/coder/claudecode.nvim/issues/248))

### Bug Fixes

- `openFile` could open a file in a tab that had nothing to do with the Claude that asked: it scanned every window in every tab and took the first suitable one, ignoring the plugin's own "not an editor window" marker. It is now scoped to the requesting Claude's tab and shares the window-picking rules with the diff module instead of keeping a second, drifted copy.
- A `cwd` passed to the terminal (`terminal.cwd`, `cwd_provider`) was silently dropped, because overrides were only applied to settings that already had a value and both of these default to unset.
- `closeAllDiffTabs` from one Claude could reject a pending diff belonging to another Claude in the same tab, which that Claude received as the user declining its edit. Diffs now record which connection opened them and are only closed for that one.

- Diffs opened via `openDiff` no longer linger forever when they are resolved outside this Neovim or their Claude session goes away. Pending diffs are now automatically closed when the client that opened them disconnects or the integration is stopped, and `closeAllDiffTabs` now also resolves/cleans the diff module's tracked state instead of only closing windows. ([#248](https://github.com/coder/claudecode.nvim/issues/248))
- Show diffs when the Claude Code terminal is the only window (no other splits). Previously `openDiff` failed with "No suitable editor window found"; now a split is created to host the diff, matching the behavior of the `openFile` tool. ([#231](https://github.com/coder/claudecode.nvim/issues/231))
- Work around a Neovim core bug (< 0.12.2) that fragmented large bracketed pastes into the terminal across `vim.paste` phases, making Cmd+V appear to truncate content. Added a scoped, version-gated `vim.paste` shim controlled by `terminal.fix_streamed_paste` (`"auto"` by default; no-op on Neovim >= 0.12.2). ([#161](https://github.com/coder/claudecode.nvim/issues/161))

## [0.3.0] - 2025-09-15

### Features

- External terminal provider to run Claude in a separate terminal ([#102](https://github.com/coder/claudecode.nvim/pull/102))
- Terminal provider APIs: implement `ensure_visible` for reliability ([#103](https://github.com/coder/claudecode.nvim/pull/103))
- Working directory control for Claude terminal ([#117](https://github.com/coder/claudecode.nvim/pull/117))
- Support function values for `external_terminal_cmd` for dynamic commands ([#119](https://github.com/coder/claudecode.nvim/pull/119))
- Add `"none"` terminal provider option for external CLI management ([#130](https://github.com/coder/claudecode.nvim/pull/130))
- Shift+Enter keybinding for newline in terminal input ([#116](https://github.com/coder/claudecode.nvim/pull/116))
- `focus_after_send` option to control focus after sending to Claude ([#118](https://github.com/coder/claudecode.nvim/pull/118))
- Snacks: `snacks_win_opts` to override `Snacks.terminal.open()` options ([#65](https://github.com/coder/claudecode.nvim/pull/65))
- Terminal/external quality: CWD support, stricter placeholder parsing, and `jobstart` CWD (commit e21a837)

- Diff UX redesign with horizontal layout and new tab options ([#111](https://github.com/coder/claudecode.nvim/pull/111))
- Prevent diff on dirty buffers ([#104](https://github.com/coder/claudecode.nvim/pull/104))
- `keep_terminal_focus` option for diff views ([#95](https://github.com/coder/claudecode.nvim/pull/95))
- Control behavior when rejecting “new file” diffs ([#114](https://github.com/coder/claudecode.nvim/pull/114))

- Add Claude Haiku model + updated type annotations ([#110](https://github.com/coder/claudecode.nvim/pull/110))
- `CLAUDE_CONFIG_DIR` environment variable support ([#58](https://github.com/coder/claudecode.nvim/pull/58))
- `PartialClaudeCodeConfig` type for safer partial configs ([#115](https://github.com/coder/claudecode.nvim/pull/115))
- Generalize format hook; add floating window docs (commit 7e894e9)
- Add env configuration option; fix `vim.notify` scheduling ([#21](https://github.com/coder/claudecode.nvim/pull/21))

- WebSocket authentication (UUID tokens) for the server ([#56](https://github.com/coder/claudecode.nvim/pull/56))
- MCP tools compliance aligned with VS Code specs ([#57](https://github.com/coder/claudecode.nvim/pull/57))

- Mini.files integration and follow-up touch-ups ([#89](https://github.com/coder/claudecode.nvim/pull/89), [#98](https://github.com/coder/claudecode.nvim/pull/98))

### Bug Fixes

- Wrap ERROR/WARN logging in `vim.schedule` to avoid fast-event context errors ([#54](https://github.com/coder/claudecode.nvim/pull/54))
- Native terminal: do not wipe Claude buffer on window close ([#60](https://github.com/coder/claudecode.nvim/pull/60))
- Native terminal: respect `auto_close` behavior ([#63](https://github.com/coder/claudecode.nvim/pull/63))
- Snacks integration: fix invalid window with `:ClaudeCodeFocus` ([#64](https://github.com/coder/claudecode.nvim/pull/64))
- Debounce update on selection for stability ([#92](https://github.com/coder/claudecode.nvim/pull/92))

### Documentation

- Update PROTOCOL.md with complete VS Code tool specs; streamline README ([#55](https://github.com/coder/claudecode.nvim/pull/55))
- Convert configuration examples to collapsible sections; add community extensions ([#93](https://github.com/coder/claudecode.nvim/pull/93))
- Local and native binary installation guide ([#94](https://github.com/coder/claudecode.nvim/pull/94))
- Auto-save plugin note and fix ([#106](https://github.com/coder/claudecode.nvim/pull/106))
- Add AGENTS.md and improve config validation notes (commit 3e2601f)

### Refactors & Development

- Centralize type definitions in dedicated `types.lua` module ([#108](https://github.com/coder/claudecode.nvim/pull/108))
- Devcontainer with Nix support; follow-up simplification ([#112](https://github.com/coder/claudecode.nvim/pull/112), [#113](https://github.com/coder/claudecode.nvim/pull/113))
- Add Neovim test fixture configs and helper scripts (commit 35bb60f)
- Update Nix dependencies and documentation formatting (commit a01b9dc)
- Debounce/Claude hooks refactor (commit e08921f)

### New Contributors

- @alvarosevilla95 — first contribution in [#60](https://github.com/coder/claudecode.nvim/pull/60)
- @qw457812 — first contribution in [#64](https://github.com/coder/claudecode.nvim/pull/64)
- @jdurand — first contribution in [#89](https://github.com/coder/claudecode.nvim/pull/89)
- @marcinjahn — first contribution in [#102](https://github.com/coder/claudecode.nvim/pull/102)
- @proofer — first contribution in [#98](https://github.com/coder/claudecode.nvim/pull/98)
- @ehaynes99 — first contribution in [#106](https://github.com/coder/claudecode.nvim/pull/106)
- @rpbaptist — first contribution in [#92](https://github.com/coder/claudecode.nvim/pull/92)
- @nerdo — first contribution in [#78](https://github.com/coder/claudecode.nvim/pull/78)
- @totalolage — first contribution in [#21](https://github.com/coder/claudecode.nvim/pull/21)
- @TheLazyLemur — first contribution in [#18](https://github.com/coder/claudecode.nvim/pull/18)
- @nabekou29 — first contribution in [#58](https://github.com/coder/claudecode.nvim/pull/58)

### Full Changelog

- <https://github.com/coder/claudecode.nvim/compare/v0.2.0...v0.3.0>

## [0.2.0] - 2025-06-18

### Features

- **Diagnostics Integration**: Added comprehensive diagnostics tool that provides Claude with access to LSP diagnostics information ([#34](https://github.com/coder/claudecode.nvim/pull/34))
- **File Explorer Integration**: Added support for oil.nvim, nvim-tree, and neotree with @-mention file selection capabilities ([#27](https://github.com/coder/claudecode.nvim/pull/27), [#22](https://github.com/coder/claudecode.nvim/pull/22))
- **Enhanced Terminal Management**:
  - Added `ClaudeCodeFocus` command for smart toggle behavior ([#40](https://github.com/coder/claudecode.nvim/pull/40))
  - Implemented auto terminal provider detection ([#36](https://github.com/coder/claudecode.nvim/pull/36))
  - Added configurable auto-close and enhanced terminal architecture ([#31](https://github.com/coder/claudecode.nvim/pull/31))
- **Customizable Diff Keymaps**: Made diff keymaps adjustable via LazyVim spec ([#47](https://github.com/coder/claudecode.nvim/pull/47))

### Bug Fixes

- **Terminal Focus**: Fixed terminal focus error when buffer is hidden ([#43](https://github.com/coder/claudecode.nvim/pull/43))
- **Diff Acceptance**: Improved unified diff acceptance behavior using signal-based approach instead of direct file writes ([#41](https://github.com/coder/claudecode.nvim/pull/41))
- **Syntax Highlighting**: Fixed missing syntax highlighting in proposed diff view ([#32](https://github.com/coder/claudecode.nvim/pull/32))
- **Visual Selection**: Fixed visual selection range handling for `:'\<,'\>ClaudeCodeSend` ([#26](https://github.com/coder/claudecode.nvim/pull/26))
- **Native Terminal**: Implemented `bufhidden=hide` for native terminal toggle ([#39](https://github.com/coder/claudecode.nvim/pull/39))

### Development Improvements

- **Testing Infrastructure**: Moved test runner from shell script to Makefile for better development experience ([#37](https://github.com/coder/claudecode.nvim/pull/37))
- **CI/CD**: Added Claude Code GitHub Workflow ([#2](https://github.com/coder/claudecode.nvim/pull/2))

## [0.1.0] - 2025-06-02

### Initial Release

First public release of claudecode.nvim - the first Neovim IDE integration for
Claude Code.

#### Features

- Pure Lua WebSocket server (RFC 6455 compliant) with zero dependencies
- Full MCP (Model Context Protocol) implementation compatible with official extensions
- Interactive terminal integration for Claude Code CLI
- Real-time selection tracking and context sharing
- Native Neovim diff support for code changes
- Visual selection sending with `:ClaudeCodeSend` command
- Automatic server lifecycle management

#### Commands

- `:ClaudeCode` - Toggle Claude terminal
- `:ClaudeCodeSend` - Send visual selection to Claude
- `:ClaudeCodeOpen` - Open/focus Claude terminal
- `:ClaudeCodeClose` - Close Claude terminal

#### Requirements

- Neovim >= 0.8.0
- Claude Code CLI
