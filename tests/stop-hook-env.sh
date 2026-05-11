#!/usr/bin/env bash
# Validates CC_STOP_HOOK_DISABLE and CC_STOP_HOOK_AGGRESSIVE behavior in
# hooks/stop-cleanup-orphans.sh by sourcing it inside a subshell with shell-
# function overrides for `ps` and `kill` (functions take precedence over
# builtins, which PATH-based shims cannot do for `kill`).
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT_DIR/hooks/stop-cleanup-orphans.sh"

failures=0
expect_yes() {
  local name=$1
  shift
  if "$@"; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}
expect_no() {
  local name=$1
  shift
  if "$@"; then
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  else
    printf "ok - %s\n" "$name"
  fi
}

KILL_LOG=$(mktemp)
HOOK_OUT=$(mktemp)
trap 'rm -f "$KILL_LOG" "$HOOK_OUT"' EXIT

# Synthetic process table (PID PPID PGID COMMAND):
#   $$    ?    9999  bash test                ← test process; ancestor walk terminates here
#   1001  1    9999  node mcp-orphan          ← PPID=1 orphan in our PGID
#   1002  555  9999  node mcp-active          ← PPID!=1 active in our PGID
#   1003  1    9999  node context7-mcp        ← PPID=1 BUT whitelisted
#   2000  1    8888  unrelated daemon         ← different PGID (ignored by PGID loop)
#
# Global PPID=1 fallback is fed an empty list so the PGID loop is isolated.

run_hook() {
  : > "$KILL_LOG"
  : > "$HOOK_OUT"
  (
    # Env vars for this run: each positional arg is "VAR=val"
    for _kv in "$@"; do
      export "$_kv"
    done

    ps() {
      local args="$*"
      case "$args" in
        "-o ppid= -p $$")
          echo "1"
          ;;
        "-o pgid= -p $$")
          echo "9999"
          ;;
        "-eo pid,pgid")
          printf '%s 9999\n1001 9999\n1002 9999\n1003 9999\n2000 8888\n' "$$"
          ;;
        "-o ppid= -p 1001"|"-o ppid= -p 1003")
          echo "1"
          ;;
        "-o ppid= -p 1002")
          echo "555"
          ;;
        "-o command= -p 1001")
          echo "node mcp-orphan"
          ;;
        "-o command= -p 1002")
          echo "node mcp-active"
          ;;
        "-o command= -p 1003")
          echo "node context7-mcp"
          ;;
        "-eo pid=,ppid=,command=")
          : # empty list — global fallback finds nothing
          ;;
        *)
          command ps "$@"
          ;;
      esac
    }

    kill() {
      echo "$1" >> "$KILL_LOG"
    }

    # Hook calls `exit 0`; subshell exits cleanly. Capture stdout to file.
    source "$HOOK" > "$HOOK_OUT" 2>&1
  )
}

# ─── Test 1: CC_STOP_HOOK_DISABLE=1 short-circuits ─────────────────────────
run_hook "CC_STOP_HOOK_DISABLE=1"
expect_no "DISABLE=1 prints [cleanup] line" \
  grep -q '\[cleanup\]' "$HOOK_OUT"
expect_no "DISABLE=1 invokes kill" \
  test -s "$KILL_LOG"

# ─── Test 2: default mode emits [cleanup] echo ─────────────────────────────
run_hook
expect_yes "default mode prints [cleanup] line" \
  grep -q '\[cleanup\]' "$HOOK_OUT"

# ─── Test 3: default mode kills PPID=1 PGID member, skips PPID!=1 and whitelist ─
expect_yes "default: PPID=1 orphan (1001) killed" \
  grep -qw "1001" "$KILL_LOG"
expect_no "default: PPID!=1 active (1002) NOT killed" \
  grep -qw "1002" "$KILL_LOG"
expect_no "default: whitelisted context7-mcp (1003) NOT killed" \
  grep -qw "1003" "$KILL_LOG"
expect_no "default: different-PGID (2000) NOT killed" \
  grep -qw "2000" "$KILL_LOG"

# ─── Test 4: AGGRESSIVE=1 also kills PPID!=1 PGID members ──────────────────
run_hook "CC_STOP_HOOK_AGGRESSIVE=1"
expect_yes "AGGRESSIVE=1: PPID=1 orphan (1001) killed" \
  grep -qw "1001" "$KILL_LOG"
expect_yes "AGGRESSIVE=1: PPID!=1 PGID member (1002) killed" \
  grep -qw "1002" "$KILL_LOG"
expect_no "AGGRESSIVE=1: whitelisted (1003) still NOT killed" \
  grep -qw "1003" "$KILL_LOG"
expect_no "AGGRESSIVE=1: different-PGID (2000) NOT killed" \
  grep -qw "2000" "$KILL_LOG"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "stop-hook env validation passed\n"
