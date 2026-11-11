#!/usr/bin/env bash
# worktree-janitor (stima-api#7904): the log lines a sweep repeats unchanged are written once.
#   `summary: removed=.. kept=..`, `trim summary: ..` and `pruned: <repo>` go to the janitor log only when their
#   text differs from what the previous sweep wrote; a changed value is written, and so is a value that returns.
# Real git repositories under a sandbox HOME; gh is a failing stub. TAP-style; set WJ_SCRIPT to test another copy.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
is() { # name, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1 (expected $2, got $3)"; fi
}

T="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "${T:?}"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/state" "$T/stubs"
export GIT_CONFIG_NOSYSTEM=1
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }
printf '#!/bin/sh\nexit 1\n' > "$T/stubs/gh"; chmod +x "$T/stubs/gh"
export PATH="$T/stubs:$PATH"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"

G init -q --bare "$T/origin.git" -b main
G clone -q "$T/origin.git" "$T/primary" 2>/dev/null
echo init > "$T/primary/README.md"
G -C "$T/primary" add README.md
G -C "$T/primary" commit -qm init
G -C "$T/primary" push -q origin main
G -C "$T/primary" worktree add -q -b A "$T/wt-A" main

sweep() { bash "$WJ" "$@" >> "$T/out" 2>&1; }
count() { grep -c -- "$1" "$T/wj.log" 2>/dev/null || true; }

sweep --apply
is "the first sweep writes its summary" 1 "$(count '\] summary: removed=')"
sweep --apply
sweep --apply
is "two more sweeps with the same numbers write none" 1 "$(count '\] summary: removed=')"
G -C "$T/primary" worktree add -q -b B "$T/wt-B" main
sweep --apply
is "a changed number is written" 2 "$(count '\] summary: removed=')"
G -C "$T/primary" worktree remove --force "$T/wt-B"
G -C "$T/primary" branch -q -D B
sweep --apply
is "and so is the earlier number coming back" 3 "$(count '\] summary: removed=')"

sweep --apply --trim-regenerable
sweep --apply --trim-regenerable
is "the trim summary is written once while it stays the same" 1 "$(count 'trim summary: ')"

for _ in 1 2; do
  G -C "$T/primary" worktree add -q -b M "$T/wt-M" main
  rm -rf "${T:?}/wt-M"
  sweep --apply
  G -C "$T/primary" worktree prune
  G -C "$T/primary" branch -q -D M
done
is "the same repository pruned again is not written again" 1 "$(count '\] pruned: ')"

[ "$failures" -eq 0 ] && echo "worktree-janitor-log-changed: all passed" || { echo "worktree-janitor-log-changed: $failures failed"; exit 1; }
