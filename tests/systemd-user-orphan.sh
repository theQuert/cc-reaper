#!/usr/bin/env bash
set -euo pipefail

# Validates cross-platform orphan-parent detection: PID 1 plus, on Linux, the
# invoking user's `systemd --user` manager. macOS / no-systemd hosts must
# resolve to exactly "1" (behavior identical to the prior PID=1-only logic).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0
kill_log=$(mktemp)
trap 'rm -f "$kill_log"' EXIT

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

expect_eq() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# Mock kill: record killed PIDs (works across the pipeline subshell)
kill() {
  echo "$1" >> "$kill_log"
}

MY_UID=$(id -u)
OTHER_UID=$((MY_UID + 1))
SYSTEMD_USER_PID=4242

# ─────────────────────────────────────────────────────────────────────────────
# Scenario A: Linux host with a `systemd --user` manager owned by this user
# ─────────────────────────────────────────────────────────────────────────────
ps() {
  if [ "$1" = "-eo" ] && [ "$2" = "pid=,uid=,command=" ]; then
    cat <<EOF
$SYSTEMD_USER_PID $MY_UID /usr/lib/systemd/systemd --user
9001 $OTHER_UID /usr/lib/systemd/systemd --user
1 0 /sbin/init
EOF
  elif [ "$1" = "-eo" ] && [ "$2" = "pid=,ppid=,command=" ]; then
    cat <<EOF
$SYSTEMD_USER_PID 1 /usr/lib/systemd/systemd --user
100 $SYSTEMD_USER_PID npm exec mcp-server-foo
200 1 node /usr/local/bin/claude --dangerously-allow-all --session-id abc stream-json
300 $SYSTEMD_USER_PID npm exec @upstash/context7-mcp
400 9001 npm exec mcp-server-bar
EOF
  else
    command ps "$@"
  fi
}

_CC_REAPER_ORPHAN_PPIDS=""
expect_eq "orphan-parent set = PID 1 + this user's systemd --user manager" \
  "1 $SYSTEMD_USER_PID" "$(_cc_reaper_orphan_ppids)"

expect_yes "PID 1 is an orphan parent" \
  _cc_reaper_is_orphan_ppid 1
expect_yes "this user's systemd --user PID is an orphan parent" \
  _cc_reaper_is_orphan_ppid "$SYSTEMD_USER_PID"
expect_no "another user's systemd --user PID is NOT an orphan parent" \
  _cc_reaper_is_orphan_ppid 9001

: > "$kill_log"
_cc_reaper_ppid_fallback || true

expect_yes "MCP server reparented to systemd --user is reaped" \
  grep -q "^100$" "$kill_log"
expect_yes "claude stream-json orphaned to PID 1 is still reaped" \
  grep -q "^200$" "$kill_log"
expect_no "protected context7-mcp under systemd --user is NOT reaped" \
  grep -q "^300$" "$kill_log"
expect_no "MCP under another user's systemd --user is NOT reaped" \
  grep -q "^400$" "$kill_log"
expect_no "systemd --user manager itself is NOT reaped" \
  grep -q "^${SYSTEMD_USER_PID}$" "$kill_log"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario B: macOS / no `systemd --user` manager → set is exactly "1"
# ─────────────────────────────────────────────────────────────────────────────
ps() {
  if [ "$1" = "-eo" ] && [ "$2" = "pid=,uid=,command=" ]; then
    cat <<EOF
1 0 /sbin/launchd
500 $MY_UID /usr/local/bin/node some-service.js
EOF
  elif [ "$1" = "-eo" ] && [ "$2" = "pid=,ppid=,command=" ]; then
    cat <<EOF
600 1 node /usr/local/bin/claude --dangerously-allow-all --session-id def stream-json
700 $SYSTEMD_USER_PID npm exec mcp-server-foo
EOF
  else
    command ps "$@"
  fi
}

_CC_REAPER_ORPHAN_PPIDS=""
expect_eq "no systemd --user manager → orphan-parent set is exactly '1'" \
  "1" "$(_cc_reaper_orphan_ppids)"

expect_no "non-orphan PID is NOT an orphan parent on a no-systemd host" \
  _cc_reaper_is_orphan_ppid "$SYSTEMD_USER_PID"

: > "$kill_log"
_cc_reaper_ppid_fallback || true

expect_yes "PID=1 orphan is still reaped on a no-systemd host" \
  grep -q "^600$" "$kill_log"
expect_no "process parented to a non-orphan PID is left alone (no-op vs old behavior)" \
  grep -q "^700$" "$kill_log"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "systemd-user orphan detection validation passed\n"
