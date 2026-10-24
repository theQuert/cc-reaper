#!/usr/bin/env bash
# resource-watch: the round watchdog (stima-api #5886). On 2026-10-24 one round never returned,
# so launchd started no other and sampling, alerts and the go cache cap all stopped for hours.
#
#   W1  the heartbeat is written before any step that can block
#   W2  a round past CC_RW_ROUND_MAX_SECONDS ends itself; a detached act is not part of it
#   W3  a stopped act (or a stopped pid in its tree) is an operator hold: ERROR, ALERT:disk-act-held,
#       never signalled, and every round still samples, alerts and caps the go cache
#
# CC_RW_SCRIPT_UNDER_TEST runs the cases against a copy (how the mutants are shown to fail).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RW="${CC_RW_SCRIPT_UNDER_TEST:-$ROOT_DIR/shell/resource-watch.sh}"
failures=0
passes=0

expect_yes() {
  local name=$1 rc=0
  shift
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then printf "ok - %s\n" "$name"; passes=$((passes + 1))
  else printf "not ok - %s\n" "$name"; failures=$((failures + 1)); fi
}
expect_no() {
  local name=$1 rc=0
  shift
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then printf "ok - %s\n" "$name"; passes=$((passes + 1))
  else printf "not ok - %s\n" "$name"; failures=$((failures + 1)); fi
}

TMPDIR_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-resource-watch-wd.XXXXXX")
case "$TMPDIR_ROOT" in ''|/) echo "mktemp gave '$TMPDIR_ROOT'; refusing to run" >&2; exit 1 ;; esac
# The only rm in this suite (EL-5886-RM-1752). Every path must be under <root>, which is the suite's
# own mktemp -d directory or a directory under it: not empty, not the root itself, no `..`
# component. The whole call is refused if any path fails, before anything is removed.
safe_rm() {
  local root="$1" p
  shift
  case "$root" in ''|/) echo "safe_rm: refusing: root '$root' is empty or /" >&2; return 1 ;; esac
  for p in "$@"; do
    case "$p" in
      */../*|*/..) echo "safe_rm: refusing $p (a .. component)" >&2; return 1 ;;
      "$root"/?*) ;;
      *) echo "safe_rm: refusing $p (not under $root)" >&2; return 1 ;;
    esac
  done
  rm -rf -- "$@"
}
stub_dir="$TMPDIR_ROOT/stubs"
guard_dir="$TMPDIR_ROOT/guard"
mkdir -p "$stub_dir" "$guard_dir"
FIXTURE_PIDS="$TMPDIR_ROOT/fixture-pids"
ACT_GROUPS="$TMPDIR_ROOT/act-groups"
: > "$FIXTURE_PIDS"; : > "$ACT_GROUPS"
# Only pids this suite started are ever signalled, continued first so a stopped one can die. An
# act leads its own process group, and a child of it can outlive both the act and the record of
# its pid; the group is ended too, and only while every member is one of this suite's fixtures.
cleanup() {
  local p g members m ours
  for p in $(cat "$FIXTURE_PIDS" 2>/dev/null); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  for g in $(cat "$ACT_GROUPS" 2>/dev/null); do
    members=$(pgrep -g "$g" 2>/dev/null) || continue
    ours=1
    for m in $members; do
      case "$(ps -o command= -p "$m" 2>/dev/null)" in
        ''|"sleep 300"|*"$TMPDIR_ROOT"*) ;;
        *) ours=0 ;;
      esac
    done
    if [ "$ours" -eq 1 ]; then kill -CONT -- "-$g" 2>/dev/null; kill -KILL -- "-$g" 2>/dev/null; fi
  done
  # The root goes only when it is still the directory mktemp made.
  [ -n "$TMPDIR_ROOT" ] && [ -d "$TMPDIR_ROOT" ] \
    && case "$TMPDIR_ROOT" in "${TMPDIR:-/tmp}"/test-resource-watch-wd.?*) rm -rf -- "$TMPDIR_ROOT" ;; esac
  return 0
}
trap cleanup EXIT

# top hangs when CC_RW_TEST_HANG_TOP names a file: it writes its pid there and sleeps 40s.
cat > "$stub_dir/top" <<'STUB'
#!/usr/bin/env bash
if [ -n "${CC_RW_TEST_HANG_TOP:-}" ]; then
  [ -n "${CC_RW_TEST_TOP_IGNORES_TERM:-}" ] && trap '' TERM
  echo "$$" > "$CC_RW_TEST_HANG_TOP"
  echo "$$" >> "$CC_RW_TEST_FIXTURE_PIDS"
  exec sleep 40
fi
echo "CPU usage: 15.0% user, 13.0% sys, 72.0% idle"
STUB
cat > "$stub_dir/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem   1K-blocks      Used Available Capacity Mounted on"
echo "/dev/disk3s5 976562500 195312500 ${CC_RW_TEST_DF_KB:-104858562}     20%  /System/Volumes/Data"
STUB
cat > "$stub_dir/vm_stat" <<'STUB'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
echo "Pages free:                          209715."
echo "Pages inactive:                      200000."
echo "Pages occupied by compressor:        200000."
STUB
cat > "$stub_dir/sysctl" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  vm.loadavg) echo "{ 0.50 0.60 0.70 }" ;;
  hw.ncpu) echo "8" ;;
  hw.pagesize) echo "4096" ;;
  hw.memsize) echo "17179869184" ;;
  *) echo "0" ;;
esac
STUB
cat > "$stub_dir/osascript" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${CC_RW_OSASCRIPT_LOG:-/dev/null}"
STUB
chmod +x "$stub_dir"/*

for name in janitor reclaim; do
  cat > "$guard_dir/$name.sh" <<STUB
#!/usr/bin/env bash
echo "$name \$*" >> "\$CC_RW_TEST_CALLS"
STUB
done
# A janitor that hangs: records its own pid and its child's, then waits on the child.
cat > "$guard_dir/janitor-slow.sh" <<'STUB'
#!/usr/bin/env bash
echo "janitor $*" >> "$CC_RW_TEST_CALLS"
echo "$$" >> "$CC_RW_TEST_PIDS"
echo "$$" >> "$CC_RW_TEST_FIXTURE_PIDS"
sleep 300 &
echo "$!" >> "$CC_RW_TEST_PIDS"
echo "$!" >> "$CC_RW_TEST_FIXTURE_PIDS"
wait
STUB
chmod +x "$guard_dir"/*.sh

# ---------------------------------------------------------------------------
# S0: safe_rm, the only rm here
# ---------------------------------------------------------------------------
SR="$TMPDIR_ROOT/safe-rm-selftest"; mkdir -p "$SR/a" "$SR/b"; touch "$SR/b/keep" "$SR/a/drop"
sr_refuses() { local err rc=0; err="$(safe_rm "$@" 2>&1 >/dev/null)" || rc=$?; [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'safe_rm: refusing'; }
expect_yes "S0a: safe_rm refuses a path outside its root" sr_refuses "$SR/a" "$SR/b/keep"
expect_yes "S0a: and that path survives" test -e "$SR/b/keep"
expect_yes "S0b: it refuses an empty path" sr_refuses "$TMPDIR_ROOT" ""
expect_yes "S0c: it refuses the root itself" sr_refuses "$TMPDIR_ROOT" "$TMPDIR_ROOT"
expect_yes "S0d: it refuses a .. escape" sr_refuses "$SR/a" "$SR/a/../b/keep"
expect_yes "S0e: it refuses an empty root" sr_refuses "" "$SR/b/keep"
expect_yes "S0f: one bad path refuses the whole call" sr_refuses "$SR/a" "$SR/a/drop" "$SR/b/keep"
expect_yes "S0f: so nothing was removed" test -e "$SR/a/drop" -a -e "$SR/b/keep"
expect_yes "S0g: it removes a path under its root" safe_rm "$SR/a" "$SR/a/drop"
expect_yes "S0g: which is gone" test ! -e "$SR/a/drop"

GB=1048576
# One round in <dir> at <free GB>, extra VAR=value pairs after. Foreground; never fails the suite.
round() {
  local dir=$1 free_gb=$2
  shift 2
  mkdir -p "$dir/state"
  (
    export PATH="$stub_dir:$PATH"
    export CC_RW_LOG="$dir/resource-watch.log" CC_RW_STATE_DIR="$dir/state"
    export CC_RW_OSASCRIPT_LOG="$dir/osascript" CC_RW_TEST_CALLS="$dir/calls" CC_RW_TEST_PIDS="$dir/pids"
    export CC_RW_TEST_FIXTURE_PIDS="$FIXTURE_PIDS"
    export CC_RW_TEST_DF_KB=$(( free_gb * GB ))
    export CC_RW_JANITOR_SCRIPT="$guard_dir/janitor.sh" CC_RW_RECLAIM_SCRIPT="$guard_dir/reclaim.sh"
    for pair in "$@"; do export "$pair"; done
    /bin/bash "$RW"
  ) || true
  touch "$dir/osascript" "$dir/calls"
}
wait_for_lines() {  # <file> <n>: at most 10s
  local i=0
  while [ "$(wc -l 2>/dev/null < "$1" || echo 0)" -lt "$2" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
}
is_stopped() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in *T*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------------------
# W1: the heartbeat is the first thing a round writes, before any step that can block
# ---------------------------------------------------------------------------
w1=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
w1_start=$(date +%s)
round "$w1" 100 CC_RW_TEST_HANG_TOP="$w1/top.pid" CC_RW_ROUND_MAX_SECONDS=0 &
w1_round=$!
wait_for_lines "$w1/top.pid" 1
w1_hb=$(cat "$w1/state/resource-watch.heartbeat" 2>/dev/null || true)
expect_yes "W1a: while the round hangs in its first metric, the heartbeat already exists" \
  test -f "$w1/state/resource-watch.heartbeat"
expect_yes "W1a: and holds this round's epoch (${w1_hb:-none} >= ${w1_start})" \
  sh -c "[ -n '$w1_hb' ] && [ '$w1_hb' -ge '$w1_start' ]"
expect_yes "W1b: CC_RW_ROUND_MAX_SECONDS=0 leaves a hung round alone" \
  sh -c "sleep 3; kill -0 '$(cat "$w1/top.pid" 2>/dev/null || echo 0)'"
kill -KILL "$(cat "$w1/top.pid" 2>/dev/null || echo 0)" 2>/dev/null || true
wait "$w1_round" 2>/dev/null || true
echo 1 > "$w1/state/resource-watch.heartbeat"
round "$w1" 100
expect_yes "W1c: every round rewrites it" \
  sh -c "[ \"\$(cat '$w1/state/resource-watch.heartbeat')\" -ge '$w1_start' ]"

# ---------------------------------------------------------------------------
# W2: the whole-round deadline
# ---------------------------------------------------------------------------
w2=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
# A detached act first, so the deadline is shown not to reach it.
round "$w2" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
w2_act=$(cat "$w2/state/disk-act.lock/pid" 2>/dev/null || echo 0)
echo "$w2_act" >> "$FIXTURE_PIDS"; echo "$w2_act" >> "$ACT_GROUPS"
wait_for_lines "$w2/pids" 2
w2_start=$(date +%s)
round "$w2" 30 CC_RW_TEST_HANG_TOP="$w2/top.pid" CC_RW_ROUND_MAX_SECONDS=2 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
w2_secs=$(( $(date +%s) - w2_start ))
expect_yes "W2a: a round hung past CC_RW_ROUND_MAX_SECONDS=2 ends itself (${w2_secs}s, hang is 40s)" test "$w2_secs" -le 15
expect_no  "W2a: the hung step is gone" kill -0 "$(cat "$w2/top.pid" 2>/dev/null || echo 0)"
expect_yes "W2a: an ERROR names the deadline" grep -q 'ERROR resource-watch round ran over CC_RW_ROUND_MAX_SECONDS=2' "$w2/resource-watch.log"
expect_yes "W2a: with ALERT:round-overrun" grep -q 'ALERT:round-overrun' "$w2/resource-watch.log"
expect_yes "W2b: the detached act is not part of the round and still runs" kill -0 "$w2_act"
expect_yes "W2b: its tree too" sh -c "for p in \$(cat '$w2/pids'); do kill -0 \$p || exit 1; done"
expect_yes "W2b: and its lock is left alone" test "$(cat "$w2/state/disk-act.lock/pid" 2>/dev/null)" = "$w2_act"
# A round that finishes leaves no watchdog behind (237: a value nothing else on the host sleeps).
w2c=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
round "$w2c" 100 CC_RW_ROUND_MAX_SECONDS=237
sleep 0.5
expect_no  "W2c: a round that finishes in time leaves no watchdog sleeping" pgrep -fx 'sleep 237'
expect_no  "W2c: and logs no overrun" grep -q 'ALERT:round-overrun' "$w2c/resource-watch.log"

# ---------------------------------------------------------------------------
# W3: a stopped act is an operator hold
# ---------------------------------------------------------------------------
w3=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
round "$w3" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
w3_act=$(cat "$w3/state/disk-act.lock/pid" 2>/dev/null || echo 0)
echo "$w3_act" >> "$FIXTURE_PIDS"; echo "$w3_act" >> "$ACT_GROUPS"
wait_for_lines "$w3/pids" 2
kill -STOP "$w3_act"
echo "$(( $(date +%s) - 6000 ))" > "$w3/state/disk-act.lock/started"   # past the 5400s cap
safe_rm "$TMPDIR_ROOT" "$w3/state/cooldown-disk-act"
round "$w3" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_KILL_GRACE_SECS=1
expect_yes "W3a: a stopped act past the cap is never ended" kill -0 "$w3_act"
expect_yes "W3a: and is still stopped (not continued, not signalled)" is_stopped "$w3_act"
expect_yes "W3a: its tree is untouched" sh -c "for p in \$(cat '$w3/pids'); do kill -0 \$p || exit 1; done"
expect_yes "W3a: an ERROR names the hold" grep -q "ERROR disk act pid ${w3_act} is stopped" "$w3/resource-watch.log"
expect_yes "W3a: the snapshot line carries ALERT:disk-act-held" grep -q 'disk_free=.*ALERT:disk-act-held' "$w3/resource-watch.log"
expect_no  "W3a: not ALERT:disk-act-overrun" grep -q 'ALERT:disk-act-overrun' "$w3/resource-watch.log"
expect_yes "W3a: it notifies" grep -q 'disk-act-held' "$w3/osascript"
expect_yes "W3a: no second act starts while it is held" test "$(grep -c '^janitor' "$w3/calls")" -eq 1
expect_yes "W3a: the lock still names it" test "$(cat "$w3/state/disk-act.lock/pid" 2>/dev/null)" = "$w3_act"
round "$w3" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_KILL_GRACE_SECS=1
expect_yes "W3b: every round still samples (three snapshot lines)" test "$(grep -c 'disk_free=' "$w3/resource-watch.log")" -eq 3
expect_yes "W3b: and still caps the go cache (three caps)" test "$(grep -c -- '--go-cache-cap' "$w3/calls")" -eq 3
expect_yes "W3b: and still alerts on disk-low" test "$(grep -c 'ALERT:disk-low' "$w3/resource-watch.log")" -eq 3
expect_yes "W3b: the act is still stopped after two rounds" is_stopped "$w3_act"
kill -CONT "$w3_act" 2>/dev/null || true

# A stopped pid inside the act's tree (the 2026-10-24 shape: the reclaim child was stopped) is a hold too.
w3c=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
round "$w3c" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
w3c_act=$(cat "$w3c/state/disk-act.lock/pid" 2>/dev/null || echo 0)
echo "$w3c_act" >> "$FIXTURE_PIDS"; echo "$w3c_act" >> "$ACT_GROUPS"
wait_for_lines "$w3c/pids" 2
w3c_child=$(head -1 "$w3c/pids")
kill -STOP "$w3c_child"
echo "$(( $(date +%s) - 6000 ))" > "$w3c/state/disk-act.lock/started"
round "$w3c" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_KILL_GRACE_SECS=1
expect_yes "W3c: a stopped child of the act holds it too: the act lives" kill -0 "$w3c_act"
expect_yes "W3c: the stopped child lives, still stopped" is_stopped "$w3c_child"
expect_yes "W3c: ALERT:disk-act-held" grep -q 'ALERT:disk-act-held' "$w3c/resource-watch.log"
kill -CONT "$w3c_child" 2>/dev/null || true

# A running act inside its cap is still just running.
w3d=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
round "$w3d" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
w3d_act=$(cat "$w3d/state/disk-act.lock/pid" 2>/dev/null || echo 0)
echo "$w3d_act" >> "$FIXTURE_PIDS"; echo "$w3d_act" >> "$ACT_GROUPS"
wait_for_lines "$w3d/pids" 2
round "$w3d" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
expect_yes "W3d: a running act is ACT:running" grep -q "ACT:running:${w3d_act}" "$w3d/resource-watch.log"
expect_no  "W3d: not held" grep -q 'disk-act-held' "$w3d/resource-watch.log"

# ---------------------------------------------------------------------------
# W4: under launchd the job's process group dies with the round, the watchdog included, so the
# alert and the notification go out before the round is ended. launchd_round stands in for it.
# ---------------------------------------------------------------------------
launchd_round() {
  local dir=$1 free_gb=$2
  shift 2
  mkdir -p "$dir/state"
  (
    set -m
    export PATH="$stub_dir:$PATH"
    export CC_RW_LOG="$dir/resource-watch.log" CC_RW_STATE_DIR="$dir/state"
    export CC_RW_OSASCRIPT_LOG="$dir/osascript" CC_RW_TEST_CALLS="$dir/calls" CC_RW_TEST_PIDS="$dir/pids"
    export CC_RW_TEST_FIXTURE_PIDS="$FIXTURE_PIDS" CC_RW_TEST_DF_KB=$(( free_gb * GB ))
    export CC_RW_JANITOR_SCRIPT="$guard_dir/janitor.sh" CC_RW_RECLAIM_SCRIPT="$guard_dir/reclaim.sh"
    for pair in "$@"; do export "$pair"; done
    /bin/bash "$RW" &
    job=$!
    wait "$job" || true
    kill -KILL -- "-$job" 2>/dev/null   # what launchd does to the job's group once the job exits
    exit 0
  ) || true
  touch "$dir/osascript" "$dir/calls"
}
w4=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
launchd_round "$w4" 100 CC_RW_TEST_HANG_TOP="$w4/top.pid" CC_RW_TEST_TOP_IGNORES_TERM=1 CC_RW_ROUND_MAX_SECONDS=2
expect_yes "W4: the overrun notification is sent even though the job's group dies with the round" \
  grep -q 'round-overrun' "$w4/osascript"
expect_yes "W4: and the ERROR is logged" grep -q 'ERROR resource-watch round ran over' "$w4/resource-watch.log"
expect_no  "W4: the TERM-proof step is gone (the group kill)" kill -0 "$(cat "$w4/top.pid" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# W5: the watchdog acts only on its own parent, and only when that parent is resource-watch
# ---------------------------------------------------------------------------
# An unrelated process whose command line does say resource-watch, so only the parent check stands
# between it and the watchdog (a reused pid can look like anything).
mkdir -p "$TMPDIR_ROOT/w5"
printf '#!/usr/bin/env bash\nsleep 300 &\necho "$!" >> "$1"\nwait\n' > "$TMPDIR_ROOT/w5/resource-watch.sh"
/bin/bash "$TMPDIR_ROOT/w5/resource-watch.sh" "$FIXTURE_PIDS" > /dev/null 2>&1 &
w5_other=$!
echo "$w5_other" >> "$FIXTURE_PIDS"
w5=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$w5/state"
(
  export CC_RW_LOG="$w5/resource-watch.log" CC_RW_STATE_DIR="$w5/state" CC_RW_OSASCRIPT_LOG="$w5/osascript"
  export PATH="$stub_dir:$PATH"
  # shellcheck source=/dev/null
  source "$RW"
  _cc_rw_round_watchdog "$w5_other" 1
) || true
expect_yes "W5a: a round pid that is not the watchdog's parent (orphaned, or reused) is never signalled" kill -0 "$w5_other"
expect_no  "W5a: and nothing is logged as an overrun" grep -q 'round ran over' "$w5/resource-watch.log"
cat > "$TMPDIR_ROOT/not-the-guard.sh" <<STUB
#!/usr/bin/env bash
export CC_RW_LOG="$w5/resource-watch.log" CC_RW_STATE_DIR="$w5/state" CC_RW_OSASCRIPT_LOG="$w5/osascript"
source "$RW"
( _cc_rw_round_watchdog \$\$ 1 ) &
wait \$!
echo survived > "\$1"
STUB
/bin/bash "$TMPDIR_ROOT/not-the-guard.sh" "$w5/flag" || true
expect_yes "W5b: a parent whose command line is not resource-watch is never signalled" test -f "$w5/flag"
kill "$w5_other" 2>/dev/null || true

# ---------------------------------------------------------------------------
# W6: the round tree skips a resource-watch act and everything under it
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR_ROOT/fake"
cat > "$TMPDIR_ROOT/fake/resource-watch.sh" <<'STUB'
#!/usr/bin/env bash
sleep 300 &
echo "$!" >> "$W6_PIDS"
wait
STUB
cat > "$TMPDIR_ROOT/w6-root.sh" <<'STUB'
#!/usr/bin/env bash
/bin/bash "$W6_FAKE" --act 30 &
echo "act $!" >> "$W6_PIDS"
sleep 299 &
echo "plain $!" >> "$W6_PIDS"
wait
STUB
W6_PIDS="$TMPDIR_ROOT/w6-pids" W6_FAKE="$TMPDIR_ROOT/fake/resource-watch.sh" /bin/bash "$TMPDIR_ROOT/w6-root.sh" &
w6_root=$!
echo "$w6_root" >> "$FIXTURE_PIDS"
wait_for_lines "$TMPDIR_ROOT/w6-pids" 3
w6_act=$(awk '$1 == "act" {print $2}' "$TMPDIR_ROOT/w6-pids")
w6_plain=$(awk '$1 == "plain" {print $2}' "$TMPDIR_ROOT/w6-pids")
w6_actkid=$(awk 'NF == 1 {print $1}' "$TMPDIR_ROOT/w6-pids")
for p in $w6_act $w6_plain $w6_actkid; do echo "$p" >> "$FIXTURE_PIDS"; done
w6_tree=$( source "$RW"; _cc_rw_round_tree "$w6_root" 0 | tr '\n' ' ' )
expect_yes "W6: the round tree holds the round and its plain child (${w6_tree})" \
  sh -c "echo ' $w6_tree ' | grep -q ' $w6_root ' && echo ' $w6_tree ' | grep -q ' $w6_plain '"
expect_no  "W6: but not a resource-watch act" sh -c "echo ' $w6_tree ' | grep -q ' ${w6_act:-x} '"
expect_no  "W6: nor the act's child" sh -c "echo ' $w6_tree ' | grep -q ' ${w6_actkid:-x} '"
for p in $w6_actkid $w6_plain $w6_act $w6_root; do kill "$p" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# W7: a stopped pid in the round's OWN tree is ended with it, and named. Unlike a detached act, a
# held round holds every later round (launchd starts none while it runs): the 2026-10-24 failure.
# ---------------------------------------------------------------------------
w7=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
round "$w7" 100 CC_RW_TEST_HANG_TOP="$w7/top.pid" CC_RW_ROUND_MAX_SECONDS=3 &
w7_round=$!
wait_for_lines "$w7/top.pid" 1
w7_top=$(cat "$w7/top.pid" 2>/dev/null || echo 0)
i=0; while [ "$(ps -o comm= -p "$w7_top" 2>/dev/null)" != sleep ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
kill -STOP "$w7_top" 2>/dev/null || true
wait "$w7_round" 2>/dev/null || true
i=0; while kill -0 "$w7_top" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done   # the KILL follows a 5s grace
expect_no  "W7: a stopped step of the round is ended with the round" kill -0 "$w7_top"
expect_yes "W7: and the ERROR names it as stopped" grep -q "ERROR resource-watch round ran over.*stopped pid(s) ${w7_top}" "$w7/resource-watch.log"

printf "passed: %s, failed: %s\n" "$passes" "$failures"
[ "$failures" -eq 0 ]
