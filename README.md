# claudecode.nvim

[![Tests](https://github.com/coder/claudecode.nvim/actions/workflows/test.yml/badge.svg)](https://github.com/coder/claudecode.nvim/actions/workflows/test.yml)
![Neovim version](https://img.shields.io/badge/Neovim-0.8%2B-green)
![Status](https://img.shields.io/badge/Status-beta-blue)

**The first Neovim IDE integration for Claude Code** — bringing Anthropic's AI coding assistant to your favorite editor with a pure Lua implementation.

> 🎯 **TL;DR:** When Anthropic released Claude Code with VS Code and JetBrains support, I reverse-engineered their extension and built this Neovim plugin. This plugin implements the same WebSocket-based MCP protocol, giving Neovim users the same AI-powered coding experience.

<https://github.com/user-attachments/assets/9c310fb5-5a23-482b-bedc-e21ae457a82d>

## What Makes This Special

When Anthropic released Claude Code, they only supported VS Code and JetBrains. As a Neovim user, I wanted the same experience — so I reverse-engineered their extension and built this.

- 🚀 **Pure Lua, Zero Dependencies** — Built entirely with `vim.loop` and Neovim built-ins
- 🔌 **100% Protocol Compatible** — Same WebSocket MCP implementation as official extensions
- 🎓 **Fully Documented Protocol** — Learn how to build your own integrations ([see PROTOCOL.md](./PROTOCOL.md))
- ⚡ **First to Market** — Beat Anthropic to releasing Neovim support
- 🛠️ **Built with AI** — Used Claude to reverse-engineer Claude's own protocol

## Installation

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
}
```

That's it! The plugin will auto-configure everything else.

## Requirements

- Neovim >= 0.8.0
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for enhanced terminal support

## Local Installation Configuration

If you've used Claude Code's `migrate-installer` command to move to a local installation, you'll need to configure the plugin to use the local path.

### What is a Local Installation?

Claude Code offers a `claude migrate-installer` command that:

- Moves Claude Code from a global npm installation to `~/.claude/local/`
- Avoids permission issues with system directories
- Creates shell aliases but these may not be available to Neovim

### Detecting Your Installation Type

Check your installation type:

```bash
# Check where claude command points
which claude

# Global installation shows: /usr/local/bin/claude (or similar)
# Local installation shows: alias to ~/.claude/local/claude

# Verify installation health
claude doctor
```

### Configuring for Local Installation

If you have a local installation, configure the plugin with the direct path:

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "~/.claude/local/claude", -- Point to local installation
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

<details>
<summary>Native Binary Installation (Alpha)</summary>

Claude Code also offers an experimental native binary installation method currently in alpha testing. This provides a single executable with no Node.js dependencies.

#### Installation Methods

Install the native binary using one of these methods:

```bash
# Fresh install (recommended)
curl -fsSL claude.ai/install.sh | bash

# From existing Claude Code installation
claude install
```

#### Platform Support

- **macOS**: Full support for Intel and Apple Silicon
- **Linux**: x64 and arm64 architectures
- **Windows**: Via WSL (Windows Subsystem for Linux)

#### Benefits

- **Zero Dependencies**: Single executable file with no external requirements
- **Cross-Platform**: Consistent experience across operating systems
- **Secure Installation**: Includes checksum verification and automatic cleanup

#### Configuring for Native Binary

The exact binary path depends on your shell integration. To find your installation:

```bash
# Check where claude command points
which claude

# Verify installation type and health
claude doctor
```

Configure the plugin with the detected path:

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    terminal_cmd = "/path/to/your/claude", -- Use output from 'which claude'
  },
  config = true,
  keys = {
    -- Your keymaps here
  },
}
```

</details>

> **Note**: If Claude Code was installed globally via npm, you can use the default configuration without specifying `terminal_cmd`.

## Quick Demo

```vim
" Launch Claude Code in a split
:ClaudeCode

" Claude now sees your current file and selections in real-time!

" Send visual selection as context
:'<,'>ClaudeCodeSend

" Claude can open files, show diffs, and more
```

## Usage

1. **Launch Claude**: Run `:ClaudeCode` to open Claude in a split terminal
2. **Send context**:
   - Select text in visual mode and use `<leader>as` to send it to Claude
   - In `nvim-tree`/`neo-tree`/`oil.nvim`/`mini.nvim`, press `<leader>as` on a file to add it to Claude's context
3. **Let Claude work**: Claude can now:
   - See your current file and selections in real-time
   - Open files in your editor
   - Show diffs with proposed changes
   - Access diagnostics and workspace info

## Key Commands

- `:ClaudeCode` - Toggle the Claude Code terminal window
- `:ClaudeCodeFocus` - Smart focus/toggle Claude terminal
- `:ClaudeCodeSelectModel` - Select Claude model and open terminal with optional arguments
- `:ClaudeCodeSend` - Send current visual selection to Claude
- `:ClaudeCodeAdd <file-path> [start-line] [end-line]` - Add specific file to Claude context with optional line range
- `:ClaudeCodeDiffAccept` - Accept diff changes
- `:ClaudeCodeDiffDeny` - Reject diff changes
- `:ClaudeCodeCloseAllDiffs` - Close pending Claude diffs (leaves accepted/saved diffs intact)
- `:ClaudeCodeLiveCursor [preview|open|off]` - Toggle the live Claude cursor (see [Live Claude Cursor](#live-claude-cursor))
- `:ClaudeCodePlanView [on|off]` - Toggle showing Claude's plan-mode plan in an editor split (see [Plan View](#plan-view))
- `:ClaudeCodeAgents [on|off]` - Toggle the agents view: several Claudes on one project, side by side (see [Agents Mode](#agents-mode))
- `:ClaudeCodeAgentNew` - Start a new agent in the agents view

## Agents Mode

Several Claudes on one project, in one tabpage — with the answer to "which of
them is working, which one wants me, and what has each actually changed."

```text
┌───────────────┬─────────────────────────────┬──────────────────────┐
│ Changes       │                             │ Sessions             │
│               │   the selected agent's      │  ✳ Fix session res…  │
│ M session_st… │   Claude terminal           │    2m    +90    -5   │
│    +90   -5   │                             │  ○ Expose tab statu… │
│ A spec.lua    │                             │    1d   +865  -100   │
│    +45   -0   │                             ├──────────────────────┤
│               │                             │ Activity             │
│               │                             │  14:03 edit  statu…  │
│               │                             │  14:04 added git.l…  │
└───────────────┴─────────────────────────────┴──────────────────────┘
```

Opt in, then press `<leader>aA`:

```lua
opts = {
  agents = { enabled = true },
}
```

**The session list is every conversation this project has had**, read from
Claude Code's own transcripts — so it survives restarts, and it includes
sessions you started outside the agents view. Each row shows the CLI's own title
for the conversation, how long ago it ran, and how many lines it added and
removed. Those counts are Claude's own record of the edits it made, so they stay
accurate while an agent is still working. The list opens ordered by when each
conversation last did something — the newest timestamp inside the transcript,
not the file's modification time, which the CLI also bumps with bookkeeping
writes days later. So resuming an old session does not move it up the list;
talking to it does.

**The order then holds still.** Rows do not re-sort themselves as agents work,
because every criterion worth sorting by moves while you are reading: with three
agents running, the row you were reaching for is somewhere else by the time you
get there. A session that starts later is sorted into its place once and stays
there too.

- `<CR>` on a session shows it. If it is already running, you get its live
  terminal; if not, it resumes. A conversation running in one of your other tabs
  jumps you there instead of resuming it twice.
- `?` in any pane shows the keys that reach it — the pane's own on top, the ones
  that work anywhere below. It lists what is actually bound, so a key you
  rebound or turned off shows up rebound or not at all.
- `a` starts a new agent, `x` stops the one under the cursor, `r` re-reads
  everything and re-sorts the list.
- `gs` in any of the three list panes chooses the order: recent activity, name,
  changes, or status. Picking the one already in force reverses it, and the menu
  is where that order is stated — it names the direction in the criterion's own
  words ("newest first", "A → Z"). The choice lasts as long as the view is open;
  the next open starts from `agents.sessions.sort` again.
- `gf` in the sessions pane **searches the conversations themselves**: type, and
  the sessions whose transcripts mention it are listed with the lines they
  mention it in — what you said, what Claude said, the paths the session touched,
  the commands it ran, and what it was thinking. Each row says which (`you`,
  `claude`, `file`, `bash`, `think`). Tool _output_ is not searched, so a word is
  a match because it was written or run, not because it scrolled past in a `Bash`
  result. A session's few rows go to what was said first, so a talkative one does
  not bury its own sentences under its reasoning. Matching is literal and
  smartcase: lowercase finds any case, one capital makes case count.
  `<C-n>`/`<C-j>` and `<C-p>`/`<C-k>` (or the arrows) move through the results and
  the panes follow along, so you can read what a session did before committing;
  `<CR>` selects it and puts you in it, resuming it if it is not running; `<Esc>`
  puts the selection back where it was. The query survives the picker (reopening
  starts from it, selected) but not the view.
- `dd` deletes the session under the cursor after a confirmation dialog (a snacks.nvim float when you have it, `vim.fn.confirm` otherwise). This removes the conversation's transcript from disk, so it is gone for good and can no longer be resumed — from here or from the CLI. A session whose agent is still running is refused; stop it with `x` first.
- **Several at once**: `dd` takes a count (`3dd` deletes three rows from the cursor down), and `d` over a visual selection deletes every session the selection covers. One dialog for the whole batch, naming the first few and counting the rest. A running agent inside the range is left alone rather than vetoing the gesture — the dialog says how many were skipped and which key stops them.
- Switching agents leaves the previous one **running**. That is the point: start
  three, come back to whichever finishes first.
- `<C-n>` and `<C-p>` move through the session list from anywhere in the tab —
  including inside the agent's terminal, without leaving insert mode. A running
  conversation is swapped into the centre pane at once. A stopped one is
  **selected but not started**: the counts, the file list and the activity feed
  all follow the selection, so you can read what a session did before deciding to
  reopen it, and the centre pane says which key starts it. Press `i` (the same
  key that puts you in a running agent's terminal) or `<CR>` to pick it up where
  it left off.
- The view **opens already pointed at your newest session**, as though you had
  pressed `<C-n>` once — so `i` from any pane starts that one, and nothing has to
  be chosen before the panes have something to show.
- The Activity pane lists the selected agent's tool calls **newest first**, so
  what it is doing now is at the top rather than scrolled off the bottom.
- It lists **everything the agent did**, not only its file work: the shell
  commands it ran, the searches it made, the subagents it launched, each named by
  the tool it used and by what the call was for. A call still running is marked
  `…`, one that failed `✗`, and one you cancelled or declined `⊘` — a call that
  simply worked says nothing, since most of them do. `f` cycles the pane between
  everything, files only and commands only; `feed_tools = false` leaves the
  commands out for good.
- `<CR>` on one of those rows shows **what it ran and what it printed** —
  the command above its output, each stream under its own `── stdout ──` /
  `── stderr ──` heading, and the colours the command wrote rendered as colour
  rather than as `^[[32m` litter. A search shows
  its matches, a subagent its reply, and anything else its result as formatted
  JSON. Nothing is read until you ask: the row carries only the call's id, and
  the transcript is re-read for the two lines that carry it.
- `.` in the Activity or Changes pane diffs that file against **git HEAD** —
  everything uncommitted in it, whoever put it there — rather than against what
  the session started from. Useful once several agents have been over the same
  tree. A file not in HEAD reads as all new; one that matches HEAD says so
  instead of opening an empty diff.
- `gf` in the Activity or Changes pane opens the **file itself, in a new tab** —
  what is on disk, to work in, rather than a view of what the agent did to it.
  The other two keys answer questions about the row; this one leaves the row
  behind. A file that is no longer on disk says so instead of opening an empty
  buffer.
- `<CR>` in the Activity or Changes pane opens that file in a floating window,
  showing **what the agent did to it**: an inline diff of the session's changes,
  or, for a read in the Activity pane, the lines it read highlighted. See
  [what the file view shows](#what-the-file-view-shows).
- Inside such a float, `<C-n>` and `<C-p>` step to the **next and previous row of
  the pane it came from** rather than to the next session — so you can read
  through everything an agent changed without closing the float between files.
  The float itself stays put and its content is swapped, the pane's cursor
  follows, and the baseline stays whichever you opened with (the session's
  changes for `<CR>`, git HEAD for `.`). Holding the key scrolls through the list
  and opens the row you settle on.
- `q` closes the view; the agents keep running unless you set
  `kill_on_close = true`.

Floating windows — diffs, files, command output — use **your own display
settings**: `wrap`, `number`, `list`, `signcolumn` and the rest come from your
config rather than from the list pane the float was opened over. The panes
themselves stay unwrapped, since they draw fixed-width rows.

Each agent gets its own connection to Neovim, so a diff, a file open or an
`@` mention reaches the agent it belongs to and no other. Diffs open as floating
windows titled with the agent that asked, cascading so several are answerable at
once — accept with `:w` and reject with `:q`, exactly as elsewhere.

**Counts in the Changes pane are what the agent did**, not the net state of your
working tree: an edit that was later reverted still counts. The `M`/`A`/`D`/`?`
letter beside each file is git's, and is the on-disk truth.

### What the file view shows

A row in the Changes or Activity pane is a record of work, so opening it shows
that work rather than the file:

- **A file the agent changed** opens as the file as it is now, with the session's
  changes rendered inline — the same view you get while an edit is happening,
  only for everything that session did to the file.
- **A read in the Activity pane** opens the file with the lines that read covered
  highlighted.
- **A file the agent created** reads as one long addition, since there was
  nothing before it.
- **A command in the Activity pane** opens what it ran and what it printed, with
  its colours intact; a search opens its matches, a subagent its reply, and
  anything else its result as formatted JSON.

The diff is reconstructed by undoing the session's own edits, so a file that
moved on afterwards — later sessions, your own editing — can have changes that
are no longer there. Those are left out and the title says so
(`foo.lua  (3/5 changes still present)`). When none of them survive, or the file
was deleted, or you do not have unified.nvim, the patches themselves are shown
as a diff instead; that is Claude's own record and cannot be stale.

Live state comes from Claude Code's lifecycle hooks when you already have
[per-tab status](#per-tab-status) enabled, and otherwise from watching the
transcripts, which costs nothing but lags the status dot by up to half a second.
Force either with `agents = { source = "hooks" }` or `"poll"` — hooks run a
headless Neovim per tool call, per running agent. Two hooks are registered
either way: one when a plan is answered, and one when a session starts, which is
how the view follows an agent that has run `/clear` (the CLI starts a new
conversation in the same terminal, and nothing on disk says which agent it
belongs to). That is one headless Neovim per `/clear`, not per tool call.

<details>
<summary>All agents options</summary>

```lua
opts = {
  agents = {
    enabled = false,
    source = "auto",              -- "hooks" | "poll" | "auto"
    poll_ms = 500,
    layout = { left_width = 0.23, right_width = 0.23, sessions_height = 0.55 },
                                  -- the terminal absorbs the rest (0.54 by default)
    sessions = {
      limit = 30,                 -- most recent transcripts to list
      include_empty = true,       -- list conversations that changed no file
      -- The order the list opens in: "recent" | "name" | "changes" | "status"
      -- ("added" and "title" are the old names for two of them, still accepted).
      -- The list is then frozen — rows keep their places instead of shuffling as
      -- agents work — and `gs` re-orders it for as long as the view is open.
      sort = "recent",
      foreign = true,             -- also list Claudes running in your other tabs
    },
    feed_limit = 500,             -- activity events kept per session
    feed_tools = true,            -- also list the calls that touch no file:
                                  -- shell commands, searches, subagents. `<CR>`
                                  -- reads what one ran and printed out of the
                                  -- transcript, on demand.
    refresh_ms = 150,
    git = true,                   -- annotate Changes with git status letters
    git_refresh_ms = 1500,
    -- The animation's pace is `status.spinner_ms` — one spinner, one setting,
    -- however many places show it. Set this only to make the agents view run at
    -- a different rate from the tabline.
    -- spinner_ms = 120,
    -- A new Activity row arrives at full colour and settles into a quieter one;
    -- a +N/-N that has just moved lights up and drops back. `fade = false`
    -- switches both off. Sampled by the spinner's frame tick, so with
    -- `auto_redraw = false` or `spinner_ms = 0` a row simply arrives at its
    -- resting colour instead of travelling there.
    fade = {
      enabled = true,
      hold_ms = 3000,             -- an Activity row stays lifted this long,
      steps = 25,                 -- then fades over (steps - 1) * step_ms, ~3s
      step_ms = 120,              -- per step; matches spinner_ms, which samples it
      boost = 0.5,                -- how far a fresh row is pushed towards its own
                                  -- hue (more coloured, never paler; 0 = only fade)
      bold = true,                -- and drawn bold while fresh, which is the whole
                                  -- of the lift for an already-vivid colour
      dim = 0.55,                 -- how far a rested row blends into the background
      flash_ms = 3000,            -- a changed count lights up and then spends
                                  -- ~all of this fading back (no flat hold)
      -- The +N/-N blocks: one hue -- the theme's own added/removed colour -- at
      -- four strengths, so the number and its block are always the same colour.
      count_sat = 0.25,           -- the resting number, as a fraction of that
      count_dim = 0.60,           -- and dimmed this far towards its own block
      count_bg_sat = 0.22,        -- the block, fainter still
      count_bg_lift = 0.10,       -- and this far from the pane in lightness
      flash_level = 0.50,         -- the block a count wears just after it moves
      flash_lift = 0.05,          -- (the number goes to the theme's colour itself)
      count_contrast = 4.5,       -- every one of them stays this legible on
                                  -- whatever it sits on
    },
    fold_batch = 2,               -- transcripts read per tick while filling the list
    follow_cursor = false,        -- selecting follows the cursor
    restore_panes = true,
    kill_on_close = false,        -- stop running agents when the view closes
    focus = "center",             -- "center" | "sessions"
    resume_mode = "resume",       -- "resume" | "fork" (--fork-session)
    -- Overrides the top-level `float` block for agent-opened floats only.
    float = { width = 0.7, height = 0.7, border = "rounded", cascade_offset = 2 },
    -- `gf` in the sessions pane: read the transcripts for what was said in them.
    -- There is no index -- each query re-reads the store and is cancelled by the
    -- next keystroke -- so these two settings are what a search costs.
    search = {
      debounce_ms = 150,          -- how long typing settles before a scan starts
      max_per_session = 3,        -- match lines per conversation; a scan stops there
    },
    keymaps = {
      select = "<CR>", new = "a", stop = "x", delete = "dd", refresh = "r",
      search = "gf",              -- search the conversations (sessions pane)
      sort = "gs",                -- choose what the list is ordered by
      close = "q", open = "<CR>", git_diff = ".", goto_file = "gf", help = "?",
      filter = "f",               -- Activity: everything / files / commands
      next_pane = "<Tab>", focus_term = "i",
      -- Cycle the selected session from any pane, and from inside the agent's
      -- terminal (bound there in terminal mode too). Inside a file float the same
      -- keys step through that pane's rows instead:
      next_session = "<C-n>", prev_session = "<C-p>",
    },
    -- The terminal pane uses the background snacks gives its windows (SnacksNormal
    -- when snacks is loaded, else NormalFloat); the sidebars keep the editor's
    -- Normal. To make the terminal blend in too:
    --   highlights = { normal = "Normal", normal_nc = "Normal" }
    -- Every pane element can be pointed at your own group. Defaults, all set as
    -- links so a colorscheme keeps the last word:
    --   highlights = {
    --     title = "ClaudeCodeAgentsTitle",       -- links to Normal
    --     time  = "ClaudeCodeAgentsTime",        -- Comment
    --     kind  = "ClaudeCodeAgentsKind",        -- Comment (Activity's read/edit column)
    --     failed = "ClaudeCodeAgentsFailed",     -- DiagnosticError (a tool call
    --                                            -- the CLI marked as an error)
    --     path  = "ClaudeCodeAgentsPath",        -- Directory
    --     stopped = "ClaudeCodeAgentsStopped",   -- Comment (the bullet of a session
    --                                            -- that is not running; a running
    --                                            -- one keeps the pane's own colour)
    --     added = "ClaudeCodeAgentsAdded",       -- DiffAdd
    --     removed = "ClaudeCodeAgentsRemoved",   -- DiffDelete
    -- Only the *hue* is taken from these two groups: the +N/-N number and the
    -- block behind it are both derived from it (see agents.fade above), the way
    -- a diff draws one, rather than from the theme's own DiffAdd background --
    -- which is frequently a different colour from the diff text the same theme
    -- ships. Give the group a coloured foreground of your own to pick the hue.
    --     selected = "ClaudeCodeAgentsSelected", -- CursorLine
    --     header = "ClaudeCodeAgentsHelpHeader", -- Title
    --     key = "ClaudeCodeAgentsKey",           -- Special
    --   }
  },
}
```

Any keymap can be set to `false` to leave the key unbound.

</details>

## Working with Diffs

When Claude proposes changes, the plugin opens a diff view:

- **Accept**: `:w` (save) or `<leader>aa`
- **Reject**: `:q` or `<leader>ad`

You can edit Claude's suggestions before accepting them.

### Diff providers

`diff_opts.provider` selects the rendering backend:

| value              | behavior                                                                                                                                                           |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `"auto"` (default) | Use [unified.nvim](https://github.com/papricasix/unified.nvim) if it is installed; otherwise fall back to `native`.                                                |
| `"native"`         | Built-in side-by-side vimdiff: original on the left, proposed on the right.                                                                                        |
| `"unified"`        | One buffer containing the proposed content with inline +/- marks for the diff against the on-disk original. Marks auto-refresh as you edit. Requires unified.nvim. |

The unified provider ignores `diff_opts.open_in_new_tab` — proposals always open in the current tab.

`:ClaudeCodeDiffToggleProvider` (or `require("claudecode.diff").toggle_provider()`) flips the active provider for subsequent diffs. Any currently open diff keeps its existing view; the change takes effect on the next proposal. Suggested keymap:

```lua
vim.keymap.set("n", "<leader>aD", "<cmd>ClaudeCodeDiffToggleProvider<cr>", { desc = "Claude: toggle diff provider" })
```

If a diff is resolved outside this Neovim (for example via Claude remote control on another device) the diff windows would otherwise stay open. They are now closed automatically when the Claude session that opened them disconnects. If you resolve diffs remotely while the session is still connected, run `:ClaudeCodeCloseAllDiffs` to clear the leftover pending proposals — it leaves any diff you have already accepted (`:w`) but whose file has not been written yet untouched, so your saved edits are never discarded.

## How It Works

This plugin creates a WebSocket server that Claude Code CLI connects to, implementing the same protocol as the official VS Code extension. When you launch Claude, it automatically detects Neovim and gains full access to your editor.

The protocol uses a WebSocket-based variant of MCP (Model Context Protocol) that:

1. Creates a WebSocket server on a random port
2. Writes a lock file to `~/.claude/ide/[port].lock` (or `$CLAUDE_CONFIG_DIR/ide/[port].lock` if `CLAUDE_CONFIG_DIR` is set) with connection info
3. Sets environment variables that tell Claude where to connect
4. Implements MCP tools that Claude can call

📖 **[Read the full reverse-engineering story →](./STORY.md)**
🔧 **[Complete protocol documentation →](./PROTOCOL.md)**

## Architecture

Built with pure Lua and zero external dependencies:

- **WebSocket Server** - RFC 6455 compliant implementation using `vim.loop`
- **MCP Protocol** - Full JSON-RPC 2.0 message handling
- **Lock File System** - Enables Claude CLI discovery
- **Selection Tracking** - Real-time context updates
- **Native Diff Support** - Seamless file comparison

For deep technical details, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Advanced Configuration

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    -- Server Configuration
    port_range = { min = 10000, max = 65535 },
    auto_start = true,
    log_level = "info", -- "trace", "debug", "info", "warn", "error"
    terminal_cmd = nil, -- Custom terminal command (default: "claude")
                        -- For local installations: "~/.claude/local/claude"
                        -- For native binary: use output from 'which claude'

    -- Send/Focus Behavior
    -- When true, successful sends will focus the Claude terminal if already connected
    focus_after_send = false,

    -- Selection Tracking
    track_selection = true,
    visual_demotion_delay_ms = 50,

    -- Terminal Configuration
    terminal = {
      split_side = "right", -- "left" or "right"
      split_width_percentage = 0.30,
      provider = "auto", -- "auto", "snacks", "native", "external", "none", or custom provider table
      auto_close = true,
      snacks_win_opts = {}, -- Opts to pass to `Snacks.terminal.open()` - see Floating Window section below
      -- Work around a Neovim core bug (< 0.12.2) that fragments large pastes into
      -- the terminal, making Cmd+V appear to truncate ([#161]). true | false | "auto"
      -- ("auto", the default, enables it only on affected Neovim versions).
      fix_streamed_paste = "auto",

      -- Provider-specific options
      provider_opts = {
        -- Command for external terminal provider. Can be:
        -- 1. String with %s placeholder: "alacritty -e %s" (backward compatible)
        -- 2. String with two %s placeholders: "alacritty --working-directory %s -e %s" (cwd, command)
        -- 3. Function returning command: function(cmd, env) return "alacritty -e " .. cmd end
        external_terminal_cmd = nil,
      },
    },

    -- Diff Integration
    diff_opts = {
      provider = "auto", -- "auto" (unified.nvim if installed, else native), "native", or "unified"
      layout = "vertical", -- "vertical", "horizontal", or "float" (see `float` below)
      open_in_new_tab = false, -- ignored by the unified provider
      keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens
      hide_terminal_in_new_tab = false,
      -- on_new_file_reject = "keep_empty", -- "keep_empty" or "close_window"

      -- Legacy aliases (still supported):
      -- vertical_split = true,
      -- open_in_current_tab = true,
    },

    -- Geometry for every floating window Claude opens for a file or a diff:
    -- `diff_opts.layout = "float"`, and agents mode, which floats regardless
    -- since none of its panes is an editor window a diff could take over.
    -- `agents.float` overrides this for agent-opened floats.
    float = {
      width = 0.7, -- fraction of the screen
      height = 0.7,
      border = "rounded", -- anything nvim_open_win accepts
      cascade_offset = 2, -- rows/columns each stacked float is offset by
    },

    -- Live Claude cursor (opt-in): a real-time view of what Claude is reading/editing
    live_cursor = {
      enabled = false, -- master switch
      mode = nil, -- REQUIRED when enabled: "preview" or "open"
      layout = "horizontal", -- "vertical" or "horizontal" split for the preview window
      split_size_percentage = 0.5, -- preview split size as a fraction of the screen (0..1): height (horizontal) or width (vertical)
      highlight = "ClaudeCodeLiveCursor", -- highlight group (defaults to a link to Visual)
      clear_delay_ms = 4000, -- clear the highlight after this much inactivity (0 = never)
      diff_suppress_ms = 250, -- delay before painting an edit, to detect a review diff first
      preview_winbar = true, -- colored winbar label marking the preview window
      preview_divider = true, -- tint the preview window's split divider
      preview_label = "● Claude live preview", -- winbar brand text (file name + read/write action are appended)
      preview_align = "center", -- winbar alignment: "center" or "left"
      preview_highlight = "ClaudeCodeLivePreview", -- marker color (defaults to a link to DiagnosticOk / green)
    },

    -- Plan view (opt-in): show Claude's plan-mode plan in the editor
    plan = {
      enabled = false, -- master switch
      focus = true, -- move focus into the plan window when it opens
      close_on_resolve = true, -- restore the editor when the plan is accepted/rejected
      clear_delay_ms = 0, -- inactivity backstop close (0 = rely on accept/reject signals)
      label = "● Claude plan", -- winbar brand text for the plan window
      highlight = "ClaudeCodePlan", -- winbar color (defaults to a link to DiagnosticInfo)
      -- layout / split_size_percentage only apply to the fallback split that is
      -- created when there is no editor window to take over (terminal-only layout):
      layout = "vertical", -- "vertical" or "horizontal" fallback split
      split_size_percentage = 0.5, -- fallback split size as a fraction of the screen (0..1)
    },

    -- Session persistence (opt-in): restore each tab's Claude conversation when a
    -- saved Neovim session is loaded. "off" | "global" | "external" -- see below.
    session_persistence = "off",
  },
  keys = {
    -- Your keymaps here
  },
}
```

#### Live Claude Cursor

A "ride-along" view: as Claude uses its `Read`/`Edit`/`Write` tools, claudecode.nvim opens or previews the touched file and highlights the exact line range — a live picture of what the agent is doing.

This works by injecting a Claude Code `PreToolUse` hook at launch via `claude --settings` (your own settings files are never modified) that reports each tool event back to the running Neovim over its RPC socket. The hook is a small Lua script run through `nvim` itself, so it works on macOS, Linux, and native Windows alike. It requires the `claude` CLI's hook support and an `nvim` on `PATH`.

- `enabled` — off by default; set to `true` to turn it on.
- `mode` — **required** when enabled:
  - `"preview"` — load the file into a single reserved split, leaving your layout and focus untouched (the "live camera"). The split is spawned next to the editor window closest to the Claude terminal. It is `horizontal` (below) by default; set `layout = "vertical"` for a split beside instead. When Claude goes idle for `clear_delay_ms`, the preview split auto-closes — unless your cursor is in it, in which case it stays until you leave. Set `clear_delay_ms = 0` to keep it open.
  - `"open"` — load the file into your current editor window if you're focused in one; otherwise (e.g. focus is in the Claude terminal, the usual case) into the editor window closest to the terminal.
- Focus never moves — the file updates passively while you keep working.
- Reads highlight the read range. Edits are shown only when **no review diff** is open for that file (i.e. in auto / accept-edits mode); when a normal diff is shown, that already visualizes the change and the live cursor stays out of the way.
- **Edits render a real inline diff** when [unified.nvim](https://github.com/papricasix/unified.nvim) is installed: the live cursor reconstructs the pre-edit file (post-edit content with the edit reversed) and shows the precise added/removed lines, rather than a heuristic highlight. Without unified.nvim it falls back to highlighting the changed line range.
- **Multi-tab aware:** each Claude is stamped with the tab it launched in, and its reads/edits only drive the preview when you are viewing that tab. A Claude running in a background tab never opens previews in the tab you are currently working in.
- `highlight` — the highlight group used for the range. Define your own group of this (or another) name to customize colors.
- In `preview` mode the window is marked so you can tell it apart from a normal split: a colored winbar label (`preview_winbar`) and a tinted split divider (`preview_divider`), both on by default. The winbar reads `<label> · <reading|writing> · <file>` (e.g. `● Claude live preview · reading · config.lua`) so you can see at a glance what Claude is doing and to which file. `preview_label` sets the leading brand text, `preview_align` centers (`"center"`, default) or left-aligns (`"left"`) it, and `preview_highlight` sets the color — it defaults to a link to `DiagnosticOk` (green); point it at a different group (e.g. `Function`, `Directory`) for blue, or define `ClaudeCodeLivePreview` yourself.
- Neovim splits have no true border, so a window can only recolor the separators it _owns_ (right/bottom edges). The divider tint is therefore most effective with `layout = "vertical"` (it colors the separator beside the preview); with `layout = "horizontal"` the top divider belongs to the window above and stays uncolored, so the **winbar** is the reliable marker there. If you run a winbar plugin (dropbar, barbecue, lualine winbar, …), the live-preview label intentionally overrides it inside the preview window.

Toggle it at runtime with `:ClaudeCodeLiveCursor`:

- `:ClaudeCodeLiveCursor` — flip enabled/disabled (requires a `mode` to already be set).
- `:ClaudeCodeLiveCursor preview` / `:ClaudeCodeLiveCursor open` — enable in that mode.
- `:ClaudeCodeLiveCursor off` — disable and clear any highlight.

Because the hook is injected when Claude launches, enabling mid-session takes effect the next time you start Claude; disabling stops the highlighting immediately.

Agents in the [agents view](#agents-mode) never preview. Every window in that tabpage is one of its panes, so there is no editor window to ride along in — a preview there would take over a pane instead of showing you a file. The same goes for the plan view.

#### Plan View

When Claude runs in **plan mode** (`shift+tab`) and presents its finished plan, claudecode.nvim can open that plan as a markdown document in the editor — the same idea as the VS Code extension, instead of leaving the plan only in the terminal.

It uses the same launch hook as the live cursor: Claude presents a plan by calling its built-in `ExitPlanMode` tool, whose input carries the plan markdown. A `PreToolUse` hook on that tool forwards the plan into Neovim the moment it is ready to read (before you accept or reject), and we render it in the editor. The same launch-time requirements apply (`claude` CLI hook support; an `nvim` on `PATH`; Claude must be started through the plugin).

- `enabled` — off by default; set to `true` to turn it on. Independent of `live_cursor` (either can be on without the other).
- The plan **takes over an existing editor window** — the one physically closest to the Claude terminal — rather than opening a new split, so it reads like the VS Code experience. When the plan resolves, that window's **previous buffer (and cursor) are restored**. If you navigate that window to a different buffer while reading the plan, your choice is left alone.
- If there is **no editor window** to take over (e.g. only the Claude terminal is visible), it falls back to a dedicated split sized by `layout` / `split_size_percentage`, which is closed on resolve.
- `focus` — when `true` (default), focus moves into the plan window so you can scroll it with normal motions; switch back to the Claude terminal to accept/reject. Set `false` to leave focus where it was.
- `close_on_resolve` — when `true` (default), the plan is dismissed once resolved: accepting it (Claude starts executing) or rejecting it (Claude resumes planning) both restore the editor.
- **Multi-tab aware:** like the live cursor, a Claude running in a background tab never opens its plan in the tab you are currently working in.
- `label` / `highlight` — the winbar brand text and its color (defaults to a link to `DiagnosticInfo`).

Toggle it at runtime with `:ClaudeCodePlanView` (`on` / `off`, or no argument to flip). As with the live cursor, the hook is injected at launch, so enabling mid-session applies the next time you start Claude.

#### Terminal Links

Click a file path in the Claude terminal to open it in your editor — like the VS Code extension, instead of having it open in your OS file explorer (Finder, etc.).

Claude marks file references (the `Read`/`Update`/`Write` headers and inline `path:line` mentions) as clickable hyperlinks. Inside Neovim's `:terminal` those clicks would otherwise be handled by Claude/your terminal and opened with the OS, so this feature captures the links Claude emits and opens them in Neovim itself.

- `enabled` — **on by default**; set to `false` to turn it off.
- **Plain click** (no modifier) on a file link opens it. The file opens in the editor window closest to the Claude terminal (the same targeting the plan view uses), replacing that window's buffer, and jumps to the `:line` when one is shown. Clicks that aren't on a file pass straight through to Claude, so its own terminal UI keeps working. It works regardless of how far the conversation has scrolled, and on file names shown by themselves, with a relative path, or split across two lines.
- `key` — a normal-mode keymap on the terminal buffer (default `"gf"`) that opens the path under the cursor; set `""` to disable. Handy if your terminal doesn't deliver the click into Neovim.
- `mouse_motion` — on by default; enables Neovim's `'mousemoveevent'` so mouse motion reaches Claude and **Claude's own hover** (underlining the link under the pointer) works inside `:terminal`. Set `false` to leave the global option untouched.
- `click` — set to `false` to keep the `gf` keymap (and `mouse_motion`) but not intercept mouse clicks at all.

```lua
opts = {
  terminal_links = {
    enabled = true,
    click = true,
    key = "gf",
    mouse_motion = true,
  },
}
```

Unlike the live cursor and plan view, this needs no launch hook — it reads the hyperlinks already in the terminal — so toggling the config takes effect on the next Claude terminal you open.

#### Session Persistence

If you keep one Claude per tab and restore your Neovim session on startup, this brings the conversations back with the tabs: each tab's Claude resumes the chat it was having.

Every Claude the plugin launches is given a stable conversation id (`claude --session-id <uuid>`), so it can be asked for again later (`claude --resume <uuid>`). The id is recorded per tab and handed to whatever already persists your Neovim session — the plugin writes no state file of its own.

- `session_persistence = "off"` — default; no ids are tracked.
- `session_persistence = "global"` — the plugin mirrors the ids into `g:CLAUDECODE_SESSION` and reads them back on `SessionLoadPost`. Works with plain `:mksession`, [persistence.nvim](https://github.com/folke/persistence.nvim), and mini.sessions, as long as `'sessionoptions'` contains `globals`:

  ```lua
  vim.opt.sessionoptions:append("globals")
  ```

- `session_persistence = "external"` — the plugin tracks ids but stores nothing; your session manager saves and restores the payload itself through `require("claudecode.session_state").capture()` / `.restore(data)`.

**Restoring is lazy.** Loading a session arms each tab; the CLI is only launched — resuming that tab's chat — when you next open that tab's Claude terminal. Nothing is spawned behind your back, and eight restored tabs don't mean eight Claude processes at startup.

`:ClaudeCodeSessionRestore!` opens them all right away: it walks every armed tab, opens its Claude terminal (resuming that conversation), and leaves you on the tab and window you started from. Without `!` it only reports how many tabs are armed. Whenever session persistence is enabled the plugin binds this to **`<leader>aR`**; remap it with:

```lua
vim.keymap.set("n", "<leader>aR", "<cmd>ClaudeCodeSessionRestore!<cr>", { desc = "Restore Claude sessions in every tab" })
```

**Only chats you actually had are saved.** The CLI writes a conversation's transcript on your first message, so a Claude you open and never talk to has nothing to resume. Those tabs are left out of the saved session — they open a fresh chat next time instead of being armed with an id that cannot come back — and a tab that had a real conversation before keeps it rather than losing it to the empty one.

**Conversations you close stay closed.** Only chats that were still running when you quit Neovim come back. If you end Claude yourself — `/exit`, `Ctrl-D`, or the process dying — that tab's conversation is forgotten immediately: reopening its terminal starts a fresh chat, and a later session restore won't bring it back either. Hiding the terminal (`:ClaudeCodeClose`, toggling the split) does not end anything, so those chats are unaffected. One gap: the `external` terminal provider runs Claude outside Neovim, where there is no terminal buffer to watch, so a Claude closed there is still treated as restorable.

**[auto-session](https://github.com/rmagatti/auto-session)** — its extra-data hook is a single slot, so compose it (the snippet below is the whole integration):

```lua
require("auto-session").setup({
  save_extra_data = function()
    return vim.json.encode({ claudecode = require("claudecode.session_state").capture() })
  end,
  restore_extra_data = function(_, extra_data)
    local ok, blob = pcall(vim.json.decode, extra_data)
    if ok and blob then
      require("claudecode.session_state").restore(blob.claudecode)
    end
  end,
})
```

**[resession.nvim](https://github.com/stevearc/resession.nvim)** — an extension ships with the plugin:

```lua
require("resession").setup({ extensions = { claudecode = {} } })
```

Notes:

- Tabs are matched by **position**, not identity: tabpage handles change across a restart and `:mksession` cannot save tab-local variables, so the payload is keyed by tab number. Reordering tabs between save and load moves conversations with the positions.
- A conversation is tied to the directory it started in. If a restored tab now points at a different directory, or the conversation is no longer on disk, that tab quietly starts a fresh chat instead of failing to resume.
- A tab that already has a running Claude is never retargeted by a session load.
- `:ClaudeCodeStatus` reports the current tab's conversation id.
- If your session manager saves terminal buffers (`'sessionoptions'` containing `terminal`), consider `vim.opt.sessionoptions:remove("terminal")` — the plugin recreates its own terminal, and a restored dead one just gets in the way.

#### Per-Tab Status (busy / waiting / idle)

If you run one Claude per tab, this answers "which tab is working, and which one is waiting on me?" — and publishes it so your tabline, statusline, or any other plugin can draw a glyph next to the tab.

```lua
require("claudecode").setup({
  status = {
    enabled = true, -- opt-in
    icons = { busy = "●", waiting = "◆", done = "●", idle = "○", none = "" },
    highlights = {
      busy = "ClaudeCodeStatusBusy", -- links to DiagnosticInfo by default
      waiting = "ClaudeCodeStatusWaiting", -- links to DiagnosticWarn
      done = "ClaudeCodeStatusDone", -- links to DiagnosticOk
      idle = "ClaudeCodeStatusIdle", -- links to Comment
    },
    auto_redraw = true, -- redraw the tabline/statusline on every change
    spinner_ms = 120, -- frame interval for animated icons (0 disables animation)
  },
})
```

**Animating a working tab.** Any icon may be a list of frames instead of a single glyph, and the plugin cycles it. `status.SPINNER` is the Claude Code CLI's own spinner, taken from the CLI rather than approximated: six glyphs played forwards and then backwards — `· ✢ ✳ ✶ ✻ ✽ ✽ ✻ ✶ ✳ ✢ ·` — so the motion breathes instead of jumping from the last frame to the first. All are single-width, so the bar does not jitter, and the CLI's own pace is one frame per 120ms (the `spinner_ms` default). On Ghostty the CLI substitutes the last glyph, which `SPINNER` mirrors off `$TERM`. On Windows, PowerShell and Windows Terminal (including WSL Neovim, detected via `WT_SESSION`) `✳` U+2733 is drawn with the colour emoji font — it is the one frame Unicode lists as emoji-capable — so it is swapped for `✱` U+2731 there, the same asterisk without an emoji presentation. Any of this can be overridden by passing your own frame list.

```lua
status = {
  enabled = true,
  icons = { busy = require("claudecode.status").SPINNER },
},
```

The timer runs only while some tab actually shows an animated icon — an all-idle Neovim ticks nothing — and never when `auto_redraw = false`, since then the redraw is yours to do.

To match the colour the CLI paints its own spinner in, override the highlight with Claude's clay orange (`--clay: #d97757` in the CLI's palette) — re-applying it on `ColorScheme`, which wipes highlight groups:

```lua
local function brand()
  vim.api.nvim_set_hl(0, "ClaudeCodeStatusBusy", { fg = "#d97757" })
end
brand()
vim.api.nvim_create_autocmd("ColorScheme", { callback = brand })
```

The states, per tab:

| State     | Meaning                                                                     |
| --------- | --------------------------------------------------------------------------- |
| `busy`    | Claude is working: your prompt is in flight, or a tool is running           |
| `waiting` | Claude needs **you**: a permission prompt, or a plan waiting to be accepted |
| `done`    | Finished, and you have not looked at the answer yet                         |
| `idle`    | Finished and seen — ready for your next prompt                              |
| `none`    | No Claude in that tab (never launched, or it exited)                        |

`done` versus `idle` is the "unread" distinction: a turn that ends while you are on another tab lands in `done`, and arriving at that tab clears it to `idle` — so the filled glyph marks answers you have not read, and the hollow one everything you have. An answer that arrives while Neovim itself is in the background counts as unread too (`FocusLost`/`FocusGained`), since you were not there to see it. Looking at a tab never clears `waiting`: reading a question is not answering it.

Reading it:

```lua
local status = require("claudecode.status")

status.get_state(tab)  -- "busy" | "waiting" | "idle" | "none"  (tab defaults to the current one)
status.get(tab)        -- full record: state, tool, message, session_id, since, tabnr
status.all()           -- { [tabpage] = record } for every tab that has a Claude
status.icon(tab)       -- the configured glyph for that tab's state ("" when none)
status.hl_group(tab)   -- highlight group for that state (nil when none)
```

`status.get()` takes a **tabpage handle** — what `nvim_list_tabpages()` gives you — so a tabline can ask about the tab it is drawing. Every change also fires `User ClaudeCodeStatusChanged`, whose `data` carries `{ tab, tabnr, state, prev, status }`, so a statusline plugin can refresh on demand instead of polling.

A minimal tabline that puts the glyph in front of each tab number:

```lua
function _G.ClaudeCodeTabline()
  local status = require("claudecode.status")
  local current = vim.api.nvim_get_current_tabpage()
  local out = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local sel = (tab == current) and "%#TabLineSel#" or "%#TabLine#"
    local icon, hl = status.icon(tab), status.hl_group(tab)
    local glyph = (icon ~= "" and hl) and ("%#" .. hl .. "#" .. icon .. " " .. sel) or ""
    out[#out + 1] = "%" .. i .. "T" .. sel .. " " .. glyph .. i .. " "
  end
  return table.concat(out) .. "%#TabLineFill#%T"
end

vim.o.tabline = "%!v:lua.ClaudeCodeTabline()"
```

Notes:

- The state comes from Claude Code's own lifecycle hooks, injected at launch the same way the live cursor and plan view are (`claude --settings`, your own settings untouched). It applies to Claude terminals opened after `setup`.
- This is the one feature that costs a hook invocation per tool call — it has to see every `PreToolUse`/`PostToolUse`, not just the file tools — which is why it is opt-in.
- `waiting` needs a permission prompt to fire. A Claude running with permissions pre-approved (`--dangerously-skip-permissions`, or an allow-list covering everything it does) goes straight from `busy` to `idle` — except for plan mode, where the plan itself is the thing waiting on you.
- It relies on hook events (`UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`) that a very old `claude` binary may not know; keep the CLI reasonably current.
- `:ClaudeCodeStatus` prints the tracked state of every tab.

### Working Directory Control

You can fix the Claude terminal's working directory regardless of `autochdir` and buffer-local cwd changes. Options (precedence order):

- `cwd_provider(ctx)`: function that returns a directory string. Receives `{ file, file_dir, cwd }`.
- `cwd`: static path to use as working directory.
- `git_repo_cwd = true`: resolves git root from the current file directory (or cwd if no file).

Examples:

```lua
require("claudecode").setup({
  -- Top-level aliases are supported and forwarded to terminal config
  git_repo_cwd = true,
})

require("claudecode").setup({
  terminal = {
    cwd = vim.fn.expand("~/projects/my-app"),
  },
})

require("claudecode").setup({
  terminal = {
    cwd_provider = function(ctx)
      -- Prefer repo root; fallback to file's directory
      local cwd = require("claudecode.cwd").git_root(ctx.file_dir or ctx.cwd) or ctx.file_dir or ctx.cwd
      return cwd
    end,
  },
})
```

## Floating Window Configuration

The `snacks_win_opts` configuration allows you to create floating Claude Code terminals with custom positioning, sizing, and key bindings. Here are several practical examples:

### Basic Floating Window with Ctrl+, Toggle

```lua
local toggle_key = "<C-,>"
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
    },
    opts = {
      terminal = {
        ---@module "snacks"
        ---@type snacks.win.Config|{}
        snacks_win_opts = {
          position = "float",
          width = 0.9,
          height = 0.9,
          keys = {
            claude_hide = {
              toggle_key,
              function(self)
                self:hide()
              end,
              mode = "t",
              desc = "Hide",
            },
          },
        },
      },
    },
  },
}
```

<details>
<summary>Alternative with Meta+, (Alt+,) Toggle</summary>

```lua
local toggle_key = "<M-,>"  -- Alt/Meta + comma
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { toggle_key, "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code", mode = { "n", "x" } },
    },
    opts = {
      terminal = {
        snacks_win_opts = {
          position = "float",
          width = 0.8,
          height = 0.8,
          border = "rounded",
          keys = {
            claude_hide = { toggle_key, function(self) self:hide() end, mode = "t", desc = "Hide" },
          },
        },
      },
    },
  },
}
```

</details>

<details>
<summary>Centered Floating Window with Custom Styling</summary>

```lua
require("claudecode").setup({
  terminal = {
    snacks_win_opts = {
      position = "float",
      width = 0.6,
      height = 0.6,
      border = "double",
      backdrop = 80,
      keys = {
        claude_hide = { "<Esc>", function(self) self:hide() end, mode = "t", desc = "Hide" },
        claude_close = { "q", "close", mode = "n", desc = "Close" },
      },
    },
  },
})
```

</details>

<details>
<summary>Multiple Key Binding Options</summary>

```lua
{
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  keys = {
    { "<C-,>", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code (Ctrl+,)", mode = { "n", "x" } },
    { "<M-,>", "<cmd>ClaudeCodeFocus<cr>", desc = "Claude Code (Alt+,)", mode = { "n", "x" } },
    { "<leader>tc", "<cmd>ClaudeCodeFocus<cr>", desc = "Toggle Claude", mode = { "n", "x" } },
  },
  opts = {
    terminal = {
      snacks_win_opts = {
        position = "float",
        width = 0.85,
        height = 0.85,
        border = "rounded",
        keys = {
          -- Multiple ways to hide from terminal mode
          claude_hide_ctrl = { "<C-,>", function(self) self:hide() end, mode = "t", desc = "Hide (Ctrl+,)" },
          claude_hide_alt = { "<M-,>", function(self) self:hide() end, mode = "t", desc = "Hide (Alt+,)" },
          claude_hide_esc = { "<C-\\><C-n>", function(self) self:hide() end, mode = "t", desc = "Hide (Ctrl+\\)" },
        },
      },
    },
  },
}
```

</details>

<details>
<summary>Window Position Variations</summary>

```lua
-- Bottom floating (like a drawer)
snacks_win_opts = {
  position = "bottom",
  height = 0.4,
  width = 1.0,
  border = "single",
}

-- Side floating panel
snacks_win_opts = {
  position = "right",
  width = 0.4,
  height = 1.0,
  border = "rounded",
}

-- Small centered popup
snacks_win_opts = {
  position = "float",
  width = 120,  -- Fixed width in columns
  height = 30,  -- Fixed height in rows
  border = "double",
  backdrop = 90,
}
```

</details>

For complete configuration options, see:

- [Snacks.nvim Terminal Documentation](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md)
- [Snacks.nvim Window Documentation](https://github.com/folke/snacks.nvim/blob/main/docs/win.md)

## Terminal Providers

### None (No-Op) Provider

Run Claude Code without any terminal management inside Neovim. This is useful for advanced setups where you manage the CLI externally (tmux, kitty, separate terminal windows) while still using the WebSocket server and tools.

You have to take care of launching CC and connecting it to the IDE yourself. (e.g. `claude --ide` or launching claude and then selecting the IDE using the `/ide` command)

```lua
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "none", -- no UI actions; server + tools remain available
    },
  },
}
```

Notes:

- No windows/buffers are created. `:ClaudeCode` and related commands will not open anything.
- The WebSocket server still starts and broadcasts work as usual. Launch the Claude CLI externally when desired.

### External Terminal Provider

Run Claude Code in a separate terminal application outside of Neovim:

```lua
-- Using a string template (simple)
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "external",
      provider_opts = {
        external_terminal_cmd = "alacritty -e %s", -- %s is replaced with claude command
        -- Or with working directory: "alacritty --working-directory %s -e %s" (first %s = cwd, second %s = command)
      },
    },
  },
}

-- Using a function for dynamic command generation (advanced)
{
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      provider = "external",
      provider_opts = {
        external_terminal_cmd = function(cmd, env)
          -- You can build complex commands based on environment or conditions
          if vim.fn.has("mac") == 1 then
            return { "osascript", "-e", string.format('tell app "Terminal" to do script "%s"', cmd) }
          else
            return "alacritty -e " .. cmd
          end
        end,
      },
    },
  },
}
```

### Custom Terminal Providers

You can create custom terminal providers by passing a table with the required functions instead of a string provider name:

```lua
require("claudecode").setup({
  terminal = {
    provider = {
      -- Required functions
      setup = function(config)
        -- Initialize your terminal provider
      end,

      open = function(cmd_string, env_table, effective_config, focus)
        -- Open terminal with command and environment
        -- focus parameter controls whether to focus terminal (defaults to true)
      end,

      close = function()
        -- Close the terminal
      end,

      simple_toggle = function(cmd_string, env_table, effective_config)
        -- Simple show/hide toggle
      end,

      focus_toggle = function(cmd_string, env_table, effective_config)
        -- Smart toggle: focus terminal if not focused, hide if focused
      end,

      get_active_bufnr = function()
        -- Return terminal buffer number or nil
        return 123 -- example
      end,

      is_available = function()
        -- Return true if provider can be used
        return true
      end,

      -- Optional functions (auto-generated if not provided)
      toggle = function(cmd_string, env_table, effective_config)
        -- Defaults to calling simple_toggle for backward compatibility
      end,

      _get_terminal_for_test = function()
        -- For testing only, defaults to return nil
        return nil
      end,
    },
  },
})
```

### Custom Provider Example

Here's a complete example using a hypothetical `my_terminal` plugin:

```lua
local my_terminal_provider = {
  setup = function(config)
    -- Store config for later use
    self.config = config
  end,

  open = function(cmd_string, env_table, effective_config, focus)
    if focus == nil then focus = true end

    local my_terminal = require("my_terminal")
    my_terminal.open({
      cmd = cmd_string,
      env = env_table,
      width = effective_config.split_width_percentage,
      side = effective_config.split_side,
      focus = focus,
    })
  end,

  close = function()
    require("my_terminal").close()
  end,

  simple_toggle = function(cmd_string, env_table, effective_config)
    require("my_terminal").toggle()
  end,

  focus_toggle = function(cmd_string, env_table, effective_config)
    local my_terminal = require("my_terminal")
    if my_terminal.is_focused() then
      my_terminal.hide()
    else
      my_terminal.focus()
    end
  end,

  get_active_bufnr = function()
    return require("my_terminal").get_bufnr()
  end,

  is_available = function()
    local ok, _ = pcall(require, "my_terminal")
    return ok
  end,
}

require("claudecode").setup({
  terminal = {
    provider = my_terminal_provider,
  },
})
```

The custom provider will automatically fall back to the native provider if validation fails or `is_available()` returns false.

Note: If your command or working directory may contain spaces or special characters, prefer returning a table of args from a function (e.g., `{ "alacritty", "--working-directory", cwd, "-e", "claude", "--help" }`) to avoid shell-quoting issues.

## Community Extensions

The following are third-party community extensions that complement claudecode.nvim. **These extensions are not affiliated with Coder and are maintained independently by community members.** We do not ensure that these extensions work correctly or provide support for them.

### 🔍 [claude-fzf.nvim](https://github.com/pittcat/claude-fzf.nvim)

Integrates fzf-lua's file selection with claudecode.nvim's context management:

- Batch file selection with fzf-lua multi-select
- Smart search integration with grep → Claude
- Tree-sitter based context extraction
- Support for files, buffers, git files

### 📚 [claude-fzf-history.nvim](https://github.com/pittcat/claude-fzf-history.nvim)

Provides convenient Claude interaction history management and access for enhanced workflow continuity.

> **Disclaimer**: These community extensions are developed and maintained by independent contributors. The authors and their extensions are not affiliated with Coder. Use at your own discretion and refer to their respective repositories for installation instructions, documentation, and support.

## Auto-Save Plugin Issues

Using auto-save plugins can cause diff windows opened by Claude to immediately accept without waiting for input. You can avoid this using a custom condition:

<details>
<summary>Pocco81/auto-save.nvim</summary>

```lua
opts = {
  -- ... other options
  condition = function(buf)
    local fn = vim.fn
    local utils = require("auto-save.utils.data")

    -- First check the default conditions
    if not (fn.getbufvar(buf, "&modifiable") == 1 and utils.not_in(fn.getbufvar(buf, "&filetype"), {})) then
      return false
    end

    -- Exclude claudecode diff buffers by buffer name patterns
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match("%(proposed%)") or
       bufname:match("%(NEW FILE %- proposed%)") or
       bufname:match("%(New%)") then
      return false
    end

    -- Exclude by buffer variables (claudecode sets these)
    if vim.b[buf].claudecode_diff_tab_name or
       vim.b[buf].claudecode_diff_new_win or
       vim.b[buf].claudecode_diff_target_win then
      return false
    end

    -- Exclude by buffer type (claudecode diff buffers use "acwrite")
    local buftype = fn.getbufvar(buf, "&buftype")
    if buftype == "acwrite" then
      return false
    end

    return true -- Safe to auto-save
  end,
},
```

</details>
<details>
<summary>okuuva/auto-save.nvim</summary>

```lua
opts = {
  -- ... other options
  condition = function(buf)
    -- Exclude claudecode diff buffers by buffer name patterns
    local bufname = vim.api.nvim_buf_get_name(buf)
    if bufname:match('%(proposed%)') or bufname:match('%(NEW FILE %- proposed%)') or bufname:match('%(New%)') then
      return false
    end

    -- Exclude by buffer variables (claudecode sets these)
    if
      vim.b[buf].claudecode_diff_tab_name
      or vim.b[buf].claudecode_diff_new_win
      or vim.b[buf].claudecode_diff_target_win
    then
      return false
    end

    -- Exclude by buffer type (claudecode diff buffers use "acwrite")
    local buftype = vim.fn.getbufvar(buf, '&buftype')
    if buftype == 'acwrite' then
      return false
    end

    return true -- Safe to auto-save
  end,
},
```

</details>

## Troubleshooting

- **Claude not connecting?** Check `:ClaudeCodeStatus` and verify lock file exists in `~/.claude/ide/` (or `$CLAUDE_CONFIG_DIR/ide/` if `CLAUDE_CONFIG_DIR` is set)
- **Need debug logs?** Set `log_level = "debug"` in opts
- **Terminal issues?** Try `provider = "native"` if using snacks.nvim
- **Local installation not working?** If you used `claude migrate-installer`, set `terminal_cmd = "~/.claude/local/claude"` in your config. Check `which claude` vs `ls ~/.claude/local/claude` to verify your installation type.
- **Native binary installation not working?** If you used the alpha native binary installer, run `claude doctor` to verify installation health and use `which claude` to find the binary path. Set `terminal_cmd = "/path/to/claude"` with the detected path in your config.

## Contributing

See [DEVELOPMENT.md](./DEVELOPMENT.md) for build instructions and development guidelines. Tests can be run with `mise run test`.

## License

[MIT](LICENSE)

## Acknowledgements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) by Anthropic
- Inspired by analyzing the official VS Code extension
- Built with assistance from AI (how meta!)
