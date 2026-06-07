#!/usr/bin/env bash
# claudecode.nvim live-cursor hook.
#
# Registered as a Claude Code PreToolUse hook (injected per-launch via
# `claude --settings`). Claude pipes the tool-event JSON to us on stdin. We hand
# it to the running Neovim over its RPC socket so the plugin can open/preview the
# file and highlight the line range Claude is touching.
#
# Transport: we write the JSON to a tempfile and pass only its path across the
# shell boundary (an mktemp path has no special characters), sidestepping all
# quoting/escaping issues. The Lua side reads and deletes the tempfile.
#
# No-ops silently when not launched from Neovim or when nvim is unavailable, so
# it can never block or break a Claude session.

set -u

[ -n "${CLAUDECODE_NVIM_SERVER:-}" ] || exit 0
command -v nvim >/dev/null 2>&1 || exit 0

tmp=$(mktemp) || exit 0
cat >"$tmp"

# The tabpage this Claude was launched in (0 = unknown). Strip to digits so it is
# always a safe integer literal inside the expression.
tab="${CLAUDECODE_NVIM_TAB:-0}"
tab="${tab//[^0-9]/}"
[ -n "$tab" ] || tab=0

# --remote-expr evaluates Vimscript: pass the args as a Vimscript LIST ([...], not
# {...} which is a dict), which luaeval converts to a Lua table -> _A = { path, tab }.
nvim --server "$CLAUDECODE_NVIM_SERVER" --remote-expr \
  "luaeval('require(\"claudecode.live_cursor\").ingest_file(_A)', ['$tmp', $tab])" >/dev/null 2>&1 &

exit 0
