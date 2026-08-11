#!/usr/bin/env bash
# Pins cc-reaper's own resource hygiene: bounded logs, terminal-gated
# notifications, and temp cleanup on interrupt.
# See openspec/specs/agent-process-reapers/spec.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0
pass() { printf "ok - %s\n" "$1"; }
fail() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-hygiene.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

# ─── Bounded logs ──────────────────────────────────────────────────────────

log="$tmp_dir/big.log"
head -c 2000 /dev/zero | tr '\0' 'x' > "$log"
before=$(ls -i "$log" | awk '{print $1}')
_cc_reaper_bound_log "$log" 1000
after=$(ls -i "$log" | awk '{print $1}')

[ -f "$log" ] && [ ! -s "$log" ] \
  && pass "over cap: live file emptied" \
  || fail "over cap: live file not emptied"
[ -s "$log.old" ] && pass "over cap: previous generation kept" || fail "over cap: no .old written"
[ "$before" = "$after" ] && pass "over cap: inode preserved" || fail "inode changed $before -> $after"

# A descriptor opened before the bound must keep writing to the live file —
# this is why the helper truncates instead of renaming.
appender="$tmp_dir/appender.log"
head -c 2000 /dev/zero | tr '\0' 'q' > "$appender"
exec 9>>"$appender"
_cc_reaper_bound_log "$appender" 1000
printf 'after-bound\n' >&9
exec 9>&-
grep -q 'after-bound' "$appender" \
  && pass "held descriptor keeps writing to the live file" \
  || fail "held descriptor lost the file"

printf 'small\n' > "$log"
_cc_reaper_bound_log "$log" 1000
[ "$(cat "$log")" = small ] && pass "under cap: left untouched" || fail "under cap: file was disturbed"

# Rotating twice must replace the generation, not accumulate them.
head -c 2000 /dev/zero | tr '\0' 'y' > "$log"
_cc_reaper_bound_log "$log" 1000
n=$(ls "$tmp_dir" | grep -c '^big\.log' || true)
[ "$n" = 2 ] && pass "only one generation is kept" || fail "big.log files present: $n"

_cc_reaper_bound_log "$tmp_dir/missing.log" 1000 \
  && pass "missing file: succeeds silently" \
  || fail "missing file: returned non-zero"
[ -e "$tmp_dir/missing.log" ] && fail "missing file: was created" || pass "missing file: nothing created"

# ─── Notification gating ───────────────────────────────────────────────────

notify_out=$( _cc_reaper_notify "T" "S" "M" </dev/null >"$tmp_dir/n.out" 2>&1; echo "rc=$?" )
[ "$notify_out" = "rc=0" ] && pass "no terminal: returns success" || fail "no terminal: $notify_out"
[ -s "$tmp_dir/n.out" ] && fail "no terminal: produced output" || pass "no terminal: silent"

# Nothing may be left running behind it.
before_jobs=$(jobs -p | wc -l | tr -d ' ')
_cc_reaper_notify "T" "S" "M" >/dev/null 2>&1 || true
after_jobs=$(jobs -p | wc -l | tr -d ' ')
[ "$before_jobs" = "$after_jobs" ] \
  && pass "no background job is spawned" \
  || fail "background jobs leaked: $before_jobs -> $after_jobs"

# A failing notifier must not change the caller's status.
notify_rc=$( osascript() { return 1; }; _cc_reaper_notify "T" "S" "M" >/dev/null 2>&1; echo $? )
[ "$notify_rc" = 0 ] && pass "failing notifier does not affect status" || fail "notifier failure leaked rc=$notify_rc"

# ─── cc-monitor temp cleanup on interrupt ──────────────────────────────────

# `ls` exits non-zero when the glob matches nothing, and pipefail would abort the
# whole script on that — counting with find keeps an empty result an empty result.
count_monitor_dirs() { find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cc-monitor.*' -type d 2>/dev/null | wc -l | tr -d ' '; }

# Both exit paths must clean up. Signal delivery is not asserted: whether
# cc-monitor's subshell is a distinct process depends on the shell's
# last-command optimisation, which makes signalling it racy. Failing a stage
# inside the subshell reaches the same handler deterministically.
#
# Regression: the handler originally referenced $tmp_dir, a `local`. Bash unwinds
# function scopes before running an EXIT trap, so it expanded to empty and
# `rm -rf ""` cleaned nothing. The path is baked into the trap instead.
for mode in normal abort; do
  rm -rf "${TMPDIR:-/tmp}"/cc-monitor.* 2>/dev/null || true
  if [ "$mode" = normal ]; then
    mode_rc=0
    bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --once >/dev/null 2>&1" || mode_rc=$?
  else
    mode_rc=0
    bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'
             _cc_monitor_aggregate_samples() { exit 130; }
             cc-monitor --once >/dev/null 2>&1" || mode_rc=$?
  fi
  [ "$(count_monitor_dirs)" = 0 ] \
    && pass "$mode exit leaves no temp directory" \
    || fail "$mode exit leaked a temp directory"
  if [ "$mode" = abort ]; then
    [ "$mode_rc" = 130 ] \
      && pass "aborted run propagates the failing status" \
      || fail "aborted run returned $mode_rc, expected 130"
  else
    [ "$mode_rc" = 0 ] && pass "normal run succeeds" || fail "normal run returned $mode_rc"
  fi
done

# A TMPDIR containing a quote must not break the handler or let the path inject
# commands into it — trap bodies are re-parsed as shell source, so the path is
# expanded at handler time rather than embedded.
quoted_tmp="$tmp_dir/has'quote"
mkdir -p "$quoted_tmp"
TMPDIR="$quoted_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --once >/dev/null 2>&1" || true
[ "$(find "$quoted_tmp" -maxdepth 1 -name 'cc-monitor.*' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && pass "quoted TMPDIR: temp directory still cleaned" \
  || fail "quoted TMPDIR: temp directory leaked"

inject_marker="$tmp_dir/injected"
inject_tmp="$tmp_dir/x'\$(touch '$inject_marker')'y"
mkdir -p "$inject_tmp" 2>/dev/null || true
if [ -d "$inject_tmp" ]; then
  TMPDIR="$inject_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --once >/dev/null 2>&1" 2>/dev/null || true
  [ -f "$inject_marker" ] \
    && fail "a crafted TMPDIR injected a command into the trap" \
    || pass "crafted TMPDIR cannot inject into the trap"
fi

# A completed run must leave the caller's traps alone too.
marker2="$tmp_dir/caller-trap-2"
( trap 'printf fired > "$marker2"' EXIT
  source "$ROOT_DIR/shell/cc-monitor.sh"
  cc-monitor --once >/dev/null 2>&1 ) || true
[ -f "$marker2" ] \
  && pass "caller's EXIT trap survives a completed run" \
  || fail "completed run cleared the caller's EXIT trap"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "runner hygiene validation passed\n"
