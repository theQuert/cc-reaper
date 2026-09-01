#!/usr/bin/env bash
# install.sh must complete without a terminal, and an interrupted run must say so.
#
# Measured 2026-09-01 deploying #23: the installer blocked at the daemon prompt on
# stdin that was an open pipe with nothing coming, having already updated the shell
# functions and NOT the scripts under ~/.cc-reaper - and its transcript, ending
# mid-step, looked like any other. Only a byte comparison against the repository
# caught it.
#
# Everything here runs against a sandbox HOME. The installer writes LaunchAgents and
# rc files, so a test that used the real one would reinstall the machine.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

ok()   { printf "ok - %s\n" "$1"; }
bad()  { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }
check() { # name, condition-rc
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

sandbox_home() {
  local h; h="$(mktemp -d)" || return 1
  mkdir -p "$h/Library/LaunchAgents" "$h/.claude/hooks" "$h/.cc-reaper/logs"
  : > "$h/.zshrc"
  printf '%s' "$h"
}

# `launchctl` and `brew` are stubbed away: this is about control flow, not about
# actually loading agents into the session running the suite.
stub_bin() {
  local d; d="$(mktemp -d)" || return 1
  for c in launchctl brew cargo; do
    printf '#!/bin/sh\nexit 0\n' > "$d/$c"; chmod +x "$d/$c"
  done
  printf '%s' "$d"
}

STUBS="$(stub_bin)"

# A second stub set where `launchctl` blocks, so the installer is provably still
# mid-run when the kill lands. Without this the interruption case is vacuous: the fix
# makes the installer finish in well under a second, so a 2-second bound interrupts
# nothing and the case passes for the wrong reason.
SLOW_STUBS="$(stub_bin)"
printf '#!/bin/sh\nsleep 120\n' > "$SLOW_STUBS/launchctl"; chmod +x "$SLOW_STUBS/launchctl"

# macOS has no `timeout`, and `gtimeout` is a coreutils install this suite must not
# require. Run bounded by hand, and kill the process GROUP - the installer spawns
# children, and killing only the shell leaves them holding the pipe.
#
# Returns 124 on timeout, like the tool it replaces, so a hang is a distinct outcome
# rather than an indistinguishable failure.
# stdin that is an open pipe with nothing coming - the shape that hung the installer.
#
# Not `( sleep N ) | cmd`: a shell waits for EVERY side of a pipeline, so the writer's
# lifetime becomes the test's runtime no matter what the bound does. Measured both ways
# here - seven minutes against a 60-second bound before the writer was capped, then 87
# seconds of pure waiting after. A FIFO with a writer we kill afterwards gives the same
# stdin and costs what the installer costs.
with_dead_pipe_stdin() {
  local secs=$1; shift
  local fifo; fifo="$(mktemp -u)"
  mkfifo "$fifo" || return 1
  sleep 300 > "$fifo" & local wpid=$!
  local rc=0
  bounded "$secs" "$@" < "$fifo" || rc=$?
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  rm -f "$fifo"
  return $rc
}

bounded() {
  local secs=$1; shift
  # Directly, NOT wrapped in `( ... )`: a subshell wrapper makes `$!` the wrapper's pid,
  # so every signal lands on it while the command inside carries on - and the
  # interruption case below then passes with nothing interrupted.
  #
  # `set -m` was tried for a process-group kill and hung the whole suite, so the tree is
  # walked by ppid instead. The installer's own TERM trap does the rest.
  "$@" & local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      _kill_tree "$pid" TERM
      sleep 1
      _kill_tree "$pid" KILL
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# Children first, so a parent cannot outlive the signal by spawning during the walk.
_kill_tree() {
  local pid=$1 sig=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    _kill_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# ─── 1. A live pipe on stdin, which is what an agent harness and CI both give ──
#
# The shape that actually hung: not /dev/null, which returns EOF, but a pipe held open
# by a writer that never writes. A 60-second bound turns a hang into a failure rather
# than into a suite that never finishes.
H="$(sandbox_home)"
out="$(mktemp)"
HOME="$H" PATH="$STUBS:$PATH" with_dead_pipe_stdin 60 bash "$ROOT_DIR/install.sh" >"$out" 2>&1
rc=$?
[ "$rc" -ne 124 ]; check "a live pipe on stdin does not hang the installer" $?
grep -q "No terminal on stdin" "$out"; check "it says which default it took, and why" $?
grep -q "INSTALL DID NOT COMPLETE" "$out"; incomplete=$?
[ "$incomplete" -ne 0 ]; check "a run that finished does not claim to be incomplete" $?
rm -rf "$H" "$out"

# ─── 2. /dev/null stdin ───────────────────────────────────────────────────────
H="$(sandbox_home)"
out="$(mktemp)"
HOME="$H" PATH="$STUBS:$PATH" bounded 60 bash "$ROOT_DIR/install.sh" >"$out" 2>&1 < /dev/null
rc=$?
[ "$rc" -eq 0 ]; check "it completes with stdin at EOF" $?
grep -q "Done\." "$out"; check "it reaches the last step" $?
rm -rf "$H" "$out"

# ─── 3. An explicit choice from a script ──────────────────────────────────────
H="$(sandbox_home)"
out="$(mktemp)"
HOME="$H" PATH="$STUBS:$PATH" CC_REAPER_DAEMON=b bounded 60 bash "$ROOT_DIR/install.sh" >"$out" 2>&1 < /dev/null
grep -q "Choice from CC_REAPER_DAEMON" "$out"; check "CC_REAPER_DAEMON is honoured" $?
rm -rf "$H" "$out"

# ─── 4. An interrupted run must not read like a finished one ──────────────────
#
# The whole point. Killed part-way, the transcript must carry an explicit marker -
# otherwise a half-applied deploy looks exactly like a complete one, which is how a
# stale worktree-janitor.sh survived a deploy that reported success.
H="$(sandbox_home)"
out="$(mktemp)"
HOME="$H" PATH="$SLOW_STUBS:$PATH" with_dead_pipe_stdin 5 bash "$ROOT_DIR/install.sh" >"$out" 2>&1
grep -q "INSTALL DID NOT COMPLETE" "$out"; check "an interrupted run says it did not complete" $?
grep -q "may be a mix of versions" "$out"; check "it names the consequence, not just the fact" $?
rm -rf "$H" "$out"

# ─── 5. Each signal keeps its own exit status ─────────────────────────────────
#
# A caller reads 128+n to learn WHICH interruption happened. TERM and HUP shared a trap
# and both reported 143, so a closed SSH session or terminal was indistinguishable from
# a deliberate kill - in the one script whose whole job here is to say accurately what
# happened to it.
# SIGINT is deliberately NOT here, and the reason is worth more than the case.
#
# Three delivery mechanisms were tried and all three were wrong in the probe, not in
# the installer: (1) `cmd &` sets SIGINT to SIG_IGN and that survives exec, so the
# signal never arrived and the case would have passed while testing nothing;
# (2) resetting the disposition then signalling bash alone made bash defer the trap
# until the foreground child it was waiting on finished - `wait` hung for five minutes;
# (3) signalling the whole tree, which is what a terminal does, hung the suite too.
#
# SIGINT to a job with no controlling terminal is not the thing the trap exists for,
# and a fourth mechanism would be testing bash's job control rather than this script.
# The trap table is one edit, and HUP and TERM below pin the shape of it: if somebody
# collapses them back into a shared trap, those two go red.
for sig_pair in "HUP 129" "TERM 143"; do
  set -- $sig_pair
  signame=$1; want=$2
  H="$(sandbox_home)"
  fifo="$(mktemp -u)"; mkfifo "$fifo"
  sleep 300 > "$fifo" & wpid=$!
  # `trap - INT; exec` before the installer starts.
  #
  # Bash sets a background job's SIGINT disposition to SIG_IGN, and SIG_IGN SURVIVES
  # exec - so a plain `cmd &` cannot be sent SIGINT at all, and the case passed for
  # HUP and TERM while being undeliverable for INT. Restoring the default first, then
  # exec-ing, gives the installer the disposition it would have in the foreground.
  HOME="$H" PATH="$SLOW_STUBS:$PATH" \
    bash -c 'trap - INT TERM HUP; exec bash "$0"' "$ROOT_DIR/install.sh" \
    >/dev/null 2>&1 < "$fifo" &
  ipid=$!
  # Wait for it to be inside the blocking step rather than racing its startup.
  waited=0
  while [ "$waited" -lt 15 ] && ! pgrep -P "$ipid" >/dev/null 2>&1; do sleep 1; waited=$((waited+1)); done
  # The whole tree, not just the shell. A terminal sends SIGINT to the foreground
  # process GROUP, so signalling bash alone is not what a Ctrl-C does - and bash defers
  # a trap until the foreground child it is waiting on finishes, so with the blocking
  # stub still alive the trap never ran and `wait` hung for five minutes. Measured.
  _kill_tree "$ipid" "$signame"
  # Bounded: this loop has hung the suite twice while the delivery was wrong, and a
  # test that hangs is the failure mode this whole PR is about.
  irc=0; waited=0
  while kill -0 "$ipid" 2>/dev/null && [ "$waited" -lt 20 ]; do sleep 1; waited=$((waited+1)); done
  if kill -0 "$ipid" 2>/dev/null; then
    _kill_tree "$ipid" KILL 2>/dev/null; wait "$ipid" 2>/dev/null; irc=-1
  else
    wait "$ipid" 2>/dev/null || irc=$?
  fi
  _kill_tree "$ipid" KILL 2>/dev/null
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; rm -f "$fifo"; rm -rf "$H"
  [ "$irc" -eq "$want" ]; check "SIG$signame exits $want, not another signal's status" $?
done

rm -rf "$STUBS" "$SLOW_STUBS"
if [ "$failures" -eq 0 ]; then echo "install-no-tty: all tests passed"; else echo "$failures test failure(s)"; fi
[ "$failures" -eq 0 ]
