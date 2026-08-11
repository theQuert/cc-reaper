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

# worktree-janitor is sourceable as well as executable. The bound used to hang
# off the direct-execution guard, so a sourced caller appended without any cap.
wj_log="$tmp_dir/wj.log"
head -c 1200000 /dev/zero | tr '\0' 'x' > "$wj_log"
bash -c "source '$ROOT_DIR/shell/worktree-janitor.sh'; CC_WJ_LOG='$wj_log' _cc_wj_log_write 'sourced call'" 2>/dev/null || true
[ -f "$wj_log.old" ] && [ "$(wc -c < "$wj_log" | tr -d ' ')" -lt 1000 ] \
  && pass "sourced worktree-janitor still bounds its log" \
  || fail "sourced worktree-janitor did not bound its log"

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

# A terminal on any descriptor counts. `claude-guard | tee guard.log` redirects
# stdout while stdin and stderr stay attached, and a stdout-only check silenced
# every notification for that ordinary case.
# Not covered automatically: a terminal on stdin or stderr while stdout is
# redirected — `claude-guard | tee guard.log`. Reproducing it needs a pty, and
# whether `script` can attach one depends on the stdio of whoever runs the suite,
# so the check was flaky under a command substitution and in CI. Verified by hand
# instead: with a pty, `tty0=y tty1=n tty2=y` and the notification fires.
# The negative direction — no terminal at all, which is the launchd case — is
# asserted above.

# A failing notifier must not change the caller's status.# A failing notifier must not change the caller's status.
notify_rc=$( osascript() { return 1; }; _cc_reaper_notify "T" "S" "M" >/dev/null 2>&1; echo $? )
[ "$notify_rc" = 0 ] && pass "failing notifier does not affect status" || fail "notifier failure leaked rc=$notify_rc"

# ─── cc-monitor temp cleanup on interrupt ──────────────────────────────────

# `ls` exits non-zero when the glob matches nothing, and pipefail would abort the
# whole script on that — counting with find keeps an empty result an empty result.
# Every monitor the suite spawns gets a private TMPDIR. Globbing the user's
# shared one would delete directories belonging to a cc-monitor they are running
# right now, and make it aggregate files that vanished underneath it.
mon_tmp="$tmp_dir/mon"
mkdir -p "$mon_tmp"
count_monitor_dirs() { find "$mon_tmp" -maxdepth 1 -name 'cc-monitor.*' -type d 2>/dev/null | wc -l | tr -d ' '; }

# Both exit paths must clean up. Signal delivery is not asserted: whether
# cc-monitor's subshell is a distinct process depends on the shell's
# last-command optimisation, which makes signalling it racy. Failing a stage
# inside the subshell reaches the same handler deterministically.
#
# Regression: the handler originally referenced $tmp_dir, a `local`. Bash unwinds
# function scopes before running an EXIT trap, so it expanded to empty and
# `rm -rf ""` cleaned nothing. The path is baked into the trap instead.
for mode in normal abort; do
  rm -rf "$mon_tmp"/cc-monitor.* 2>/dev/null || true
  if [ "$mode" = normal ]; then
    mode_rc=0
    TMPDIR="$mon_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --once >/dev/null 2>&1" || mode_rc=$?
  else
    mode_rc=0
    TMPDIR="$mon_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'
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

# `cc-monitor ... &` then `kill $!`: $$ keeps pointing at the interactive shell
# inside a background job, so an owner check on $$ would never notice. This was
# unassertable while the suite matched process names — a worker inherits its
# parent's argv — but it cannot inherit a directory it never created, so the
# private TMPDIR settles it.
rm -rf "$mon_tmp"/cc-monitor.* 2>/dev/null || true
bg_script="$tmp_dir/bg-cancel.sh"
# Written to a file rather than inlined: the nested quoting swallowed `$!`, the
# kill then did nothing, and the wrapper exited leaving an orphaned sampler —
# which read as the feature being broken rather than the test.
cat > "$bg_script" <<INNER
source "$ROOT_DIR/shell/cc-monitor.sh"
cc-monitor --duration 60 --interval 2 >/dev/null 2>&1 &
job=\$!
sleep 3
kill -TERM "\$job" 2>/dev/null
sleep 4
INNER
TMPDIR="$mon_tmp" bash "$bg_script" >/dev/null 2>&1 || true
if [ "$(count_monitor_dirs)" = 0 ]; then
  pass "cancelling a background job stops the sampler and cleans up"
else
  fail "a sampler outlived a background-job cancellation"
  ls -ld "$mon_tmp"/cc-monitor.* 2>/dev/null | sed 's/^/      /' >&2
fi

# Cancellation must be prompt whatever interval was asked for: a single
# `sleep "$interval"` delayed the owner check by the whole interval, so at
# --interval 30 a cancelled run kept sampling for half a minute.
rm -rf "$mon_tmp"/cc-monitor.* 2>/dev/null || true
TMPDIR="$mon_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --duration 100 --interval 30 >/dev/null 2>&1" &
slow_pid=$!
sleep 3
kill -TERM "$slow_pid" 2>/dev/null || true
wait "$slow_pid" 2>/dev/null || true
sleep 4
# The private TMPDIR is the assertion: a sampler still running would still own a
# directory in it. Counting processes would need `pgrep -f`, which cannot tell
# the wrapper from a worker that inherited its argv.
[ "$(count_monitor_dirs)" = 0 ] \
  && pass "long interval still cancels promptly" \
  || fail "a sampler was alive 4s after cancelling a 30s-interval run"

# Cancelling the top-level command must stop the worker. Signals aimed at the
# invoking shell are never delivered to cc-monitor's subshell, so the sampler
# checks whether its owner is still there between snapshots.
rm -rf "$mon_tmp"/cc-monitor.* 2>/dev/null || true
TMPDIR="$mon_tmp" bash -c "source '$ROOT_DIR/shell/cc-monitor.sh'; cc-monitor --duration 40 --interval 2 >/dev/null 2>&1" &
cancel_pid=$!
sleep 3
kill -TERM "$cancel_pid" 2>/dev/null || true
wait "$cancel_pid" 2>/dev/null || true
sleep 6
[ "$(count_monitor_dirs)" = 0 ] \
  && pass "cancelling the caller stops the sampler and cleans up" \
  || fail "a sampler outlived the caller"

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
