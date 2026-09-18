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

CC_WJ_HARNESS="$harness" exec "$janitor" --session
