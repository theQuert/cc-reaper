#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-launchd-rules.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
mkdir -p "$HOME"
export CC_REAPER_RULES_FILE="$tmp_dir/process-rules.tsv"
export CC_REAPER_MONITOR_SOURCE_ONLY=1
source "$ROOT_DIR/launchd/cc-reaper-monitor.sh"
unset CC_REAPER_MONITOR_SOURCE_ONLY

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

printf "protect\tCUSTOM.WORKER\ncleanup\tcustom.worker\n" > "$CC_REAPER_RULES_FILE"
expect_yes "LaunchAgent reads case-insensitive literal protect rules" \
  has_user_rule protect "/opt/custom.worker --daemon"
expect_no "literal dots are not treated as regex wildcards" \
  has_user_rule protect "/opt/customXworker --daemon"
expect_no "protect wins before scheduled candidate classification" \
  is_cleanup_candidate 1 "??" "12:00:00" "/opt/custom.worker worker-service.cjs --daemon"

signal_log="$tmp_dir/signals"
: > "$signal_log"
ps() {
  case "$*" in
    "-o command= -p 42") printf "%s\n" "/opt/custom.worker worker-service.cjs --daemon" ;;
    "-o command= -p 43") printf "%s\n" "/opt/ordinary worker-service.cjs --daemon" ;;
    *) command ps "$@" ;;
  esac
}
kill() {
  printf "%s\n" "$*" >> "$signal_log"
}

expect_no "signal boundary blocks protected scheduled TERM" \
  terminate_unless_user_protected 42
expect_no "signal boundary blocks protected scheduled SIGKILL" \
  terminate_unless_user_protected 42 -9
expect_yes "signal boundary still permits an unprotected candidate" \
  terminate_unless_user_protected 43

if [ "$(cat "$signal_log")" = "43" ]; then
  printf "ok - only the unprotected PID received a signal\n"
else
  printf "not ok - unexpected signal log: %s\n" "$(tr '\n' ' ' < "$signal_log")"
  failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
  echo "launchd process-rule validation passed"
else
  exit 1
fi
