#!/usr/bin/env bash
# Shared Claude Code / Codex SessionEnd trigger.  The janitor performs its own detach,
# bounds the hook payload, and returns promptly.
set -u

harness="${1:-unknown}"
case "$harness" in
  claude|codex) ;;
  *) harness=unknown ;;
esac

janitor="$HOME/.cc-reaper/worktree-janitor.sh"
if [ ! -x "$janitor" ]; then
  printf 'cc-reaper: %s SessionEnd could not find %s\n' "$harness" "$janitor" >&2
  exit 0
fi

# Started by its interpreter, not its #! line: on macOS 26 each #! start leaks kernel
# memory that only a restart frees (theQuert/stima-api#9010).
CC_WJ_HARNESS="$harness" exec bash "$janitor" --session
