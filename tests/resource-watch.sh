#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failures=0

expect_yes() {
  local name=$1
  shift
  local rc=0
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

expect_no() {
  local name=$1
  shift
  local rc=0
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# Build a stub-bin directory with fake system commands
# ---------------------------------------------------------------------------

TMPDIR_ROOT=$(mktemp -d)
stub_dir="$TMPDIR_ROOT/stubs"
mkdir -p "$stub_dir"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# fake top: reports CPU idle as 72%
cat > "$stub_dir/top" <<'STUB'
#!/usr/bin/env bash
echo "Processes: 412 total, 3 running, 409 sleeping"
echo "CPU usage: 15.0% user, 13.0% sys, 72.0% idle"
STUB

# fake df: reports /System/Volumes/Data with 20% used → 80% free, ~100GB free
cat > "$stub_dir/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem   1K-blocks      Used Available Capacity Mounted on"
echo "/dev/disk3s5 976562500 195312500 ${CC_RW_TEST_DF_KB:-104858562}     20%  /System/Volumes/Data"
STUB

# fake vm_stat: pages (4096 byte pages)
# phys = 16 GB = 17179869184 bytes → 4194304 pages
# free = 5% of phys = 209715 pages (free_pct should be > 5%)
# compressor = 10% of phys = 419430 pages → ~1.60 GB (below 50% of 16GB = 8GB threshold)
cat > "$stub_dir/vm_stat" <<'STUB'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 4096 bytes)"
echo "Pages free:                          209715."
echo "Pages active:                        500000."
echo "Pages inactive:                      200000."
echo "Pages speculative:                    50000."
echo "Pages throttled:                          0."
echo "Pages wired down:                    300000."
echo "Pages purgeable:                      10000."
echo "Translation faults:               10000000."
echo "Pages copy-on-write:                 500000."
echo "Pages zero filled:                  2000000."
echo "Pages reactivated:                   100000."
echo "Pages purged:                         50000."
echo "File-backed pages:                   300000."
echo "Anonymous pages:                     400000."
echo "Pages stored in compressor:          419430."
echo "Pages occupied by compressor:        200000."
echo "Decompressions:                      100000."
echo "Compressions:                        200000."
echo "Pageins:                             500000."
echo "Pageouts:                              1000."
echo "Swapins:                               5000."
echo "Swapouts:                              4000."
STUB

# fake sysctl: supports vm.loadavg, hw.ncpu, hw.pagesize, hw.memsize
cat > "$stub_dir/sysctl" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  vm.loadavg)    echo "{ 0.50 0.60 0.70 }" ;;
  hw.ncpu)       echo "8" ;;
  hw.pagesize)   echo "4096" ;;
  hw.memsize)    echo "17179869184" ;;  # 16 GB
  *)             echo "0" ;;
esac
STUB

# fake osascript: capture call args to a file (path passed via env CC_RW_OSASCRIPT_LOG)
cat > "$stub_dir/osascript" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${CC_RW_OSASCRIPT_LOG:-/dev/null}"
STUB

chmod +x "$stub_dir/top" "$stub_dir/df" "$stub_dir/vm_stat" \
         "$stub_dir/sysctl" "$stub_dir/osascript"

# Hermetic: no case may reach the deployed reclaim scripts (a real go cache cap or sweep).
export CC_RW_RECLAIM_SCRIPT=/nonexistent/reclaim-byproducts.sh CC_RW_JANITOR_SCRIPT=/nonexistent/worktree-janitor.sh
# Nor the installed LaunchAgent plist, which sets the stalled-reclaimer line (T19).
touch "$TMPDIR_ROOT/fresh-stamp"
export CC_RW_RECLAIM_PLIST=/nonexistent/com.cc-reaper.reclaim-byproducts.plist CC_RW_RECLAIM_STAMP="$TMPDIR_ROOT/fresh-stamp"

# Nor the real events.log: a case that turns the pause chain on names its own.
export CC_RW_EVENTS_LOG="$TMPDIR_ROOT/no-events/events.log"

# Helper: run a fresh snapshot in a controlled environment
# Usage: run_snapshot [extra env vars as VAR=val ...]
run_snapshot() {
  local log_dir state_dir osascript_log
  log_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
  state_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
  osascript_log=$(mktemp "$TMPDIR_ROOT/XXXXXX")

  (
    export PATH="$stub_dir:$PATH"
    export CC_RW_LOG="$log_dir/resource-watch.log"
    export CC_RW_STATE_DIR="$state_dir"
    export CC_RW_OSASCRIPT_LOG="$osascript_log"
    # parse any extra env vars
    for pair in "$@"; do
      export "$pair"
    done
    bash "$ROOT_DIR/shell/resource-watch.sh"
  )

  # expose paths for caller assertions via well-known files in osascript_log dir
  echo "$log_dir/resource-watch.log" > "$osascript_log.logpath"
  echo "$state_dir"                  > "$osascript_log.statedir"
  echo "$osascript_log"              > "$osascript_log.self"

  # return the osascript_log path so callers can read it
  echo "$osascript_log"
}

# ---------------------------------------------------------------------------
# Test 1: snapshot writes exactly one well-formed log line
# ---------------------------------------------------------------------------

t1_oascript=$(run_snapshot)
t1_log=$(cat "$t1_oascript.logpath")

expect_yes "T1: log file exists after snapshot" \
  test -f "$t1_log"

expect_yes "T1: exactly one log line written" \
  test "$(wc -l < "$t1_log")" -eq 1

expect_yes "T1: log line has timestamp (YYYY-MM-DDTHH:MM:SS)" \
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ' "$t1_log"

expect_yes "T1: log line has load= field" \
  grep -qE 'load=[0-9.]+/[0-9.]+/[0-9.]+' "$t1_log"

expect_yes "T1: log line has cpu_idle= field" \
  grep -qE 'cpu_idle=[0-9]+%' "$t1_log"

expect_yes "T1: log line has mem_free= field" \
  grep -qE 'mem_free=[0-9.]+%' "$t1_log"

expect_yes "T1: log line has compressor= field" \
  grep -qE 'compressor=[0-9.]+GB' "$t1_log"

expect_yes "T1: log line has disk_free= field" \
  grep -qE 'disk_free=[0-9.]+GB/[0-9.]+%' "$t1_log"

# default thresholds: load factor 2 × 8 cores = 16; stub load1=0.50 → no breach
expect_no "T1: no ALERT in log when nothing breached" \
  grep -q 'ALERT' "$t1_log"

expect_no "T1: osascript NOT called when no breach" \
  test -s "$t1_oascript"


# ---------------------------------------------------------------------------
# Test 2: disk breach → osascript called + ALERT in log
# ---------------------------------------------------------------------------

# Lower the disk threshold so 80% free triggers: set min to 90% (stub free=80%)
t2_oascript=$(run_snapshot "CC_RW_DISK_MIN_PCT=90")
t2_log=$(cat "$t2_oascript.logpath")

expect_yes "T2: ALERT marker in log on disk breach" \
  grep -q 'ALERT' "$t2_log"

expect_yes "T2: ALERT:disk in log on disk breach" \
  grep -q 'ALERT:disk' "$t2_log"

expect_yes "T2: osascript called on disk breach" \
  test -s "$t2_oascript"

expect_yes "T2: osascript message mentions disk" \
  grep -qi 'disk' "$t2_oascript"


# ---------------------------------------------------------------------------
# Test 3: load breach → osascript called + ALERT in log
# Stub load1=0.50; ncpu=8; to breach: set factor to 0.05 → threshold=0.40
# ---------------------------------------------------------------------------

t3_oascript=$(run_snapshot "CC_RW_LOAD_FACTOR=0.05")
t3_log=$(cat "$t3_oascript.logpath")

expect_yes "T3: ALERT:load in log on load breach" \
  grep -q 'ALERT:load' "$t3_log"

expect_yes "T3: osascript called on load breach" \
  test -s "$t3_oascript"

expect_yes "T3: osascript message mentions load" \
  grep -qi 'load' "$t3_oascript"


# ---------------------------------------------------------------------------
# Test 4: no breach → osascript NOT called (baseline re-check with clean env)
# ---------------------------------------------------------------------------

# Stub: load1=0.50 << threshold 16; disk free 80% >> 15%; mem free ~5% > 5%; comp << 8GB
# All pass → no notification
t4_oascript=$(run_snapshot)
t4_log=$(cat "$t4_oascript.logpath")

expect_no "T4: no ALERT in log when thresholds all pass" \
  grep -q 'ALERT' "$t4_log"

expect_no "T4: osascript NOT called when no breach" \
  test -s "$t4_oascript"


# ---------------------------------------------------------------------------
# Test 5: same-metric repeat within cooldown → second breach is silent
# Run two back-to-back snapshots against the SAME state_dir with disk breach active
# ---------------------------------------------------------------------------

t5_log_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t5_state_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t5_osascript1=$(mktemp "$TMPDIR_ROOT/XXXXXX")
t5_osascript2=$(mktemp "$TMPDIR_ROOT/XXXXXX")

(
  export PATH="$stub_dir:$PATH"
  export CC_RW_LOG="$t5_log_dir/resource-watch.log"
  export CC_RW_STATE_DIR="$t5_state_dir"
  export CC_RW_OSASCRIPT_LOG="$t5_osascript1"
  export CC_RW_DISK_MIN_PCT=90
  bash "$ROOT_DIR/shell/resource-watch.sh"
) || true

(
  export PATH="$stub_dir:$PATH"
  export CC_RW_LOG="$t5_log_dir/resource-watch.log"
  export CC_RW_STATE_DIR="$t5_state_dir"
  export CC_RW_OSASCRIPT_LOG="$t5_osascript2"
  export CC_RW_DISK_MIN_PCT=90
  bash "$ROOT_DIR/shell/resource-watch.sh"
) || true

expect_yes "T5: first breach notified" \
  test -s "$t5_osascript1"

expect_no "T5: second same-metric breach suppressed (no notification)" \
  test -s "$t5_osascript2"

expect_yes "T5: second breach still logged (two lines total)" \
  test "$(wc -l < "$t5_log_dir/resource-watch.log")" -eq 2


# ---------------------------------------------------------------------------
# Test 6: two different metrics breach → each notifies independently
# Trigger both disk (min=90%) and load (factor=0.05) in same run;
# Use a fresh state_dir so neither is in cooldown
# ---------------------------------------------------------------------------

t6_log_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t6_state_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t6_oascript=$(mktemp "$TMPDIR_ROOT/XXXXXX")

(
  export PATH="$stub_dir:$PATH"
  export CC_RW_LOG="$t6_log_dir/resource-watch.log"
  export CC_RW_STATE_DIR="$t6_state_dir"
  export CC_RW_OSASCRIPT_LOG="$t6_oascript"
  export CC_RW_DISK_MIN_PCT=90
  export CC_RW_LOAD_FACTOR=0.05
  bash "$ROOT_DIR/shell/resource-watch.sh"
) || true

expect_yes "T6: osascript called at least twice (two different metrics)" \
  test "$(wc -l < "$t6_oascript")" -ge 2

expect_yes "T6: log contains ALERT:disk" \
  grep -q 'ALERT:disk' "$t6_log_dir/resource-watch.log"

expect_yes "T6: log contains ALERT:load" \
  grep -q 'ALERT:load' "$t6_log_dir/resource-watch.log"

expect_yes "T6: cooldown-disk state file created" \
  test -f "${t6_state_dir}/cooldown-disk"

expect_yes "T6: cooldown-load state file created" \
  test -f "${t6_state_dir}/cooldown-load"


# ---------------------------------------------------------------------------
# Test 7: env override changes threshold behavior (mem min pct)
# Stub mem free ~5%; comp ~1.60GB; phys=16GB → comp threshold=8GB
# Even with mem_min_pct=1 (very low), compressor is well below 50%, so no mem breach.
# Raise disk threshold to confirm disk env override still works independently.
# ---------------------------------------------------------------------------

t7_log_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t7_state_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t7_oascript=$(mktemp "$TMPDIR_ROOT/XXXXXX")

(
  export PATH="$stub_dir:$PATH"
  export CC_RW_LOG="$t7_log_dir/resource-watch.log"
  export CC_RW_STATE_DIR="$t7_state_dir"
  export CC_RW_OSASCRIPT_LOG="$t7_oascript"
  # Set mem min very high so free ~5% triggers mem part, but comp won't
  # (comp ~1.60GB < 8GB threshold); so mem alert should NOT fire even at high pct
  export CC_RW_MEM_MIN_PCT=99
  # No disk or load override → should not breach those
  bash "$ROOT_DIR/shell/resource-watch.sh"
) || true

# mem_free ~5% < 99% BUT compressor ~1.60GB is NOT > 8GB (50% of 16GB)
# So mem breach condition requires BOTH: free<pct AND comp>threshold — only free fires here
expect_no "T7: mem alert does NOT fire when compressor below 50% phys (even with high pct threshold)" \
  grep -q 'ALERT:mem' "$t7_log_dir/resource-watch.log"

expect_no "T7: osascript not called when only one mem sub-condition met" \
  test -s "$t7_oascript"

# Now trigger disk with override to confirm env override path works
t7b_log_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t7b_state_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t7b_oascript=$(mktemp "$TMPDIR_ROOT/XXXXXX")

(
  export PATH="$stub_dir:$PATH"
  export CC_RW_LOG="$t7b_log_dir/resource-watch.log"
  export CC_RW_STATE_DIR="$t7b_state_dir"
  export CC_RW_OSASCRIPT_LOG="$t7b_oascript"
  export CC_RW_DISK_MIN_PCT=95   # disk free 80% < 95% → breach
  bash "$ROOT_DIR/shell/resource-watch.sh"
) || true

expect_yes "T7b: env override CC_RW_DISK_MIN_PCT=95 triggers disk alert" \
  grep -q 'ALERT:disk' "$t7b_log_dir/resource-watch.log"

expect_yes "T7b: osascript called with custom disk threshold" \
  test -s "$t7b_oascript"


# ---------------------------------------------------------------------------
# Test 8: -h / --help exits 0 and prints usage
# ---------------------------------------------------------------------------

expect_yes "T8: -h exits 0" \
  bash "$ROOT_DIR/shell/resource-watch.sh" -h

t8_help=$(bash "$ROOT_DIR/shell/resource-watch.sh" --help 2>&1 || true)
expect_yes "T8: --help prints 'Usage:'" \
  echo "$t8_help" | grep -q 'Usage:'

# ---------------------------------------------------------------------------
# Test 9: plutil validates plist XML
# ---------------------------------------------------------------------------

expect_yes "T9: plist passes plutil -lint" \
  plutil -lint "$ROOT_DIR/launchd/com.cc-reaper.resource-watch.plist"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

# ─── T10: compressor uses "occupied by", not "stored in" (regression) ───────
# stored=419430 pages (1.60 GB) vs occupied=200000 pages (0.76 GB) at 4096B.
# "stored in compressor" is pre-compression and can exceed physical RAM
# (observed live: 56 GB on a 36 GB machine); physical footprint is "occupied".
t10_mem_out=$(
  export PATH="$stub_dir:$PATH"
  source "$ROOT_DIR/shell/resource-watch.sh" >/dev/null 2>&1
  _cc_rw_collect_memory
)
t10_comp_gb=$(echo "$t10_mem_out" | awk '{print $2}')
expect_yes "T10: compressor_gb derived from occupied pages (0.76GB)" \
  test "$t10_comp_gb" = "0.76"
expect_no "T10: compressor_gb is NOT the stored-in value (1.60GB)" \
  test "$t10_comp_gb" = "1.60"

# ─── T11: sudden disk-free drop against a 25-45 minute old sample ───────────
# The df stub reports 100.0GB free. seed_drop writes the sample file a case
# starts from; drop_case runs one snapshot against that case's directory.
seed_drop() {
  local dir
  dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
  mkdir -p "$dir/state"
  printf '%s\n' "$@" > "$dir/state/disk-free-samples"
  echo "$dir"
}

drop_case() {
  local dir=$1
  shift
  (
    export PATH="$stub_dir:$PATH"
    export CC_RW_LOG="$dir/resource-watch.log"
    export CC_RW_STATE_DIR="$dir/state"
    export CC_RW_OSASCRIPT_LOG="$dir/osascript"
    for pair in "$@"; do
      export "$pair"
    done
    bash "$ROOT_DIR/shell/resource-watch.sh"
  ) || true
  touch "$dir/osascript"
}

t11_now=$(date +%s)

t11a=$(seed_drop "$((t11_now - 1800)) 115.0")
drop_case "$t11a"
expect_yes "T11a: a 15GB fall against a 30-minute-old sample logs ALERT:disk-drop" \
  grep -q 'ALERT:disk-drop' "$t11a/resource-watch.log"
expect_yes "T11a: the notification names the fall" \
  grep -q 'fell 15.0GB' "$t11a/osascript"
expect_yes "T11a: the drop has its own cooldown" \
  test -f "$t11a/state/cooldown-disk-drop"
drop_case "$t11a"
expect_yes "T11a: a repeat inside the cooldown is still logged" \
  test "$(grep -c 'ALERT:disk-drop' "$t11a/resource-watch.log")" -eq 2
expect_yes "T11a: but notified only once" \
  test "$(wc -l < "$t11a/osascript")" -eq 1

t11b=$(seed_drop "$((t11_now - 1800)) 105.0")
drop_case "$t11b"
expect_no "T11b: a 5GB fall raises nothing" \
  grep -q 'ALERT:disk-drop' "$t11b/resource-watch.log"
expect_no "T11b: and notifies nothing" \
  test -s "$t11b/osascript"

t11c=$(seed_drop "$((t11_now - 7200)) 150.0" "$((t11_now - 300)) 150.0")
drop_case "$t11c"
expect_no "T11c: no sample 25-45 minutes old means nothing is compared" \
  grep -q 'ALERT:disk-drop' "$t11c/resource-watch.log"

t11d=$(seed_drop "$((t11_now - 2600)) 150.0" "$((t11_now - 1600)) 105.0")
drop_case "$t11d"
expect_no "T11d: the newest sample in the window is the one compared" \
  grep -q 'ALERT:disk-drop' "$t11d/resource-watch.log"

t11e=$(seed_drop "$((t11_now - 1800)) 115.0")
drop_case "$t11e" "CC_RW_DISK_DROP_GB=0"
expect_no "T11e: CC_RW_DISK_DROP_GB=0 disables the drop alert" \
  grep -q 'ALERT:disk-drop' "$t11e/resource-watch.log"

t11f_seed=()
for i in $(seq 1 15); do
  t11f_seed+=("$((t11_now - 7200 + i * 60)) 100.0")
done
t11f=$(seed_drop "${t11f_seed[@]}")
drop_case "$t11f"
expect_yes "T11f: the sample file keeps the last 12 samples" \
  test "$(wc -l < "$t11f/state/disk-free-samples")" -eq 12
expect_yes "T11f: and the newest is this run's" \
  awk -v now="$t11_now" 'END { exit !($1 >= now && $2 == "100.0") }' "$t11f/state/disk-free-samples"

expect_yes "T11g: a first run starts the sample file with one sample" \
  test "$(wc -l < "$(cat "$t1_oascript.statedir")/disk-free-samples")" -eq 1


# ---------------------------------------------------------------------------
# T12: disk guard. Alert below 60GB free; below 40GB start worktree-janitor --scheduled and
# reclaim-byproducts, detached, at most once per 30 minutes; the go cache cap runs every round.
# ---------------------------------------------------------------------------
GB=1048576
guard_dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
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
sleep 300 &
echo "$!" >> "$CC_RW_TEST_PIDS"
wait
STUB

# Wait (at most 10s) for a detached act to release its lock.
wait_unlocked() {
  local i=0
  while [ -d "$1/state/disk-act.lock" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
}

guard_case() {
  local dir=$1 free_gb=$2
  shift 2
  mkdir -p "$dir/state"
  (
    export PATH="$stub_dir:$PATH"
    export CC_RW_LOG="$dir/resource-watch.log" CC_RW_STATE_DIR="$dir/state"
    export CC_RW_OSASCRIPT_LOG="$dir/osascript" CC_RW_TEST_CALLS="$dir/calls" CC_RW_TEST_PIDS="$dir/pids"
    export CC_RW_TEST_DF_KB=$(( free_gb * GB ))
    export CC_RW_JANITOR_SCRIPT="$guard_dir/janitor.sh" CC_RW_RECLAIM_SCRIPT="$guard_dir/reclaim.sh"
    export CC_RW_SWAP_USED_GB=""   # unreadable unless a case sets it: the host's real swap must not decide
    export CC_RW_VM_PRESSURE_LEVEL="" CC_RW_SWAPOUTS=""   # nor its real memory pressure or Swapouts
    for pair in "$@"; do export "$pair"; done
    /bin/bash "$ROOT_DIR/shell/resource-watch.sh"
  ) || true
  [ "${GUARD_NOWAIT:-0}" = "1" ] || wait_unlocked "$dir"
  touch "$dir/osascript" "$dir/calls"
}

g1=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g1" 70
expect_no  "T12a: 70GB free raises no disk-low" grep -q 'ALERT:disk-low' "$g1/resource-watch.log"
expect_yes "T12a: but the go cache cap still runs" grep -qx 'reclaim --go-cache-cap' "$g1/calls"
expect_no  "T12a: and nothing else does" grep -qE 'janitor|^reclaim $' "$g1/calls"

g2=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g2" 50
expect_yes "T12b: 50GB free logs ALERT:disk-low" grep -q 'ALERT:disk-low' "$g2/resource-watch.log"
expect_yes "T12b: and notifies once" test "$(grep -c 'disk-low' "$g2/osascript")" -eq 1
expect_no  "T12b: without running the reclaim" test -f "$g2/state/cooldown-disk-act"

g3=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g3" 30
expect_yes "T12c: 30GB free runs the janitor --scheduled, then reclaim-byproducts (apply, no flag)" \
  test "$(grep -v -- --go-cache-cap "$g3/calls" | tr '\n' '|')" = "janitor --scheduled|reclaim |"
expect_yes "T12c: and still alerts" grep -q 'ALERT:disk-low' "$g3/resource-watch.log"
expect_yes "T12c: the act releases its lock when it is done" test ! -e "$g3/state/disk-act.lock"
expect_yes "T12c: and writes its run to resource-watch-act.log" grep -q '== disk act done' "$g3/resource-watch-act.log"
guard_case "$g3" 30
expect_yes "T12d: a second run inside 30 minutes does not reclaim again" \
  test "$(grep -c '^janitor' "$g3/calls")" -eq 1
expect_yes "T12d: but caps the go cache again" test "$(grep -c -- --go-cache-cap "$g3/calls")" -eq 2
touch -t "$(date -v-31M +%Y%m%d%H%M 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M)" "$g3/state/cooldown-disk-act"
guard_case "$g3" 30
expect_yes "T12d: after the cooldown it reclaims again" test "$(grep -c '^janitor' "$g3/calls")" -eq 2

g4=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g4" 30 CC_RW_DISK_ACT_GB=0
expect_no "T12e: CC_RW_DISK_ACT_GB=0 turns the reclaim off" grep -q '^janitor' "$g4/calls"
g5=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g5" 45 CC_RW_DISK_ACT_GB=50
expect_yes "T12e: the act threshold is a knob" grep -q '^janitor' "$g5/calls"
g6=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$g6" 50 CC_RW_DISK_ALERT_GB=45 CC_RW_GO_CAP=0
expect_no "T12e: the alert threshold is a knob" grep -q 'ALERT:disk-low' "$g6/resource-watch.log"
expect_no "T12e: CC_RW_GO_CAP=0 stops the cap" grep -q -- --go-cache-cap "$g6/calls"

# ---------------------------------------------------------------------------
# T13: tiers fire at the right free values (60 alert / 40 act / 20 emergency)
# ---------------------------------------------------------------------------
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 61
expect_no  "T13a: 61GB: no disk-low" grep -q 'ALERT:disk-low' "$t13/resource-watch.log"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 59
expect_yes "T13b: 59GB: disk-low" grep -q 'ALERT:disk-low' "$t13/resource-watch.log"
expect_no  "T13b: 59GB: no act" grep -q '^janitor' "$t13/calls"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 41
expect_no  "T13c: 41GB: no act" grep -q '^janitor' "$t13/calls"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 39
expect_yes "T13d: 39GB: the act runs" grep -q '^janitor' "$t13/calls"
expect_no  "T13d: 39GB: no emergency" grep -q 'ALERT:disk-emergency' "$t13/resource-watch.log"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 21
expect_no  "T13e: 21GB: no emergency flag" test -e "$t13/state/disk-emergency"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 19
expect_yes "T13f: 19GB: ALERT:disk-emergency" grep -q 'ALERT:disk-emergency' "$t13/resource-watch.log"
expect_yes "T13f: 19GB: the emergency flag exists" test -f "$t13/state/disk-emergency"
expect_yes "T13f: the flag holds the epoch and the free GB" \
  awk 'NR==1 { exit !($1 ~ /^[0-9]+$/ && $2 == "19.0") }' "$t13/state/disk-emergency"
expect_yes "T13f: and notifies" grep -q 'EMERGENCY' "$t13/osascript"
expect_yes "T13f: the act still runs, with disk-low too" \
  sh -c "grep -q '^janitor' '$t13/calls' && grep -q 'ALERT:disk-low' '$t13/resource-watch.log'"
guard_case "$t13" 25
expect_no  "T13g: back at 25GB the emergency flag is removed" test -e "$t13/state/disk-emergency"
t13=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); guard_case "$t13" 19 CC_RW_DISK_EMERGENCY_GB=0
expect_no  "T13h: CC_RW_DISK_EMERGENCY_GB=0 disables the flag" test -e "$t13/state/disk-emergency"

# ---------------------------------------------------------------------------
# T14: the act is detached and the round returns at once; a second round does not start another
# ---------------------------------------------------------------------------
t14=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t14_start=$(date +%s)
GUARD_NOWAIT=1 guard_case "$t14" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
t14_secs=$(( $(date +%s) - t14_start ))
t14_pid=$(cat "$t14/state/disk-act.lock/pid" 2>/dev/null || true)
expect_yes "T14a: the round returns within 5s while the act hangs (${t14_secs}s)" test "$t14_secs" -le 5
expect_yes "T14a: the lock names the act's pid" test -n "$t14_pid"
expect_yes "T14a: the act is alive after the round exited" kill -0 "${t14_pid:-0}"
expect_yes "T14a: and leads its own process group, off the launchd job's" \
  test "$(ps -o pgid= -p "${t14_pid:-0}" | tr -d ' ')" = "$t14_pid"
expect_yes "T14a: its command line is resource-watch --act" \
  sh -c "ps -o command= -p '${t14_pid:-0}' | grep -q 'resource-watch.sh --act'"
expect_yes "T14a: the round logged ACT:started with that pid" grep -q "ACT:started:${t14_pid}" "$t14/resource-watch.log"
i=0; while [ "$(wc -l < "$t14/pids" 2>/dev/null || echo 0)" -lt 2 ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
rm -f "$t14/state/cooldown-disk-act"   # past the cooldown: only the lock may stop a second act
GUARD_NOWAIT=1 guard_case "$t14" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
expect_yes "T14b: a second round while the act runs starts no other" test "$(grep -c '^janitor' "$t14/calls")" -eq 1
expect_yes "T14b: and logs ACT:running with the same pid" grep -q "ACT:running:${t14_pid}" "$t14/resource-watch.log"
expect_yes "T14b: it still samples (two snapshot lines)" test "$(grep -c 'disk_free=' "$t14/resource-watch.log")" -eq 2

# ---------------------------------------------------------------------------
# T15: past CC_RW_ACT_MAX_SECONDS the next round ends exactly the act's recorded tree
# ---------------------------------------------------------------------------
sleep 300 &
t15_decoy=$!
echo "$(( $(date +%s) - 6000 ))" > "$t14/state/disk-act.lock/started"
t15_tree="$t14_pid $(tr '\n' ' ' < "$t14/pids")"
GUARD_NOWAIT=1 guard_case "$t14" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_KILL_GRACE_SECS=2
t15_alive=""
for p in $t15_tree; do kill -0 "$p" 2>/dev/null && t15_alive="$t15_alive $p"; done
expect_yes "T15a: every pid of the act's tree is gone (${t15_tree})" test -z "$t15_alive"
expect_yes "T15a: an unrelated sleep of the same name lives" kill -0 "$t15_decoy"
expect_yes "T15a: ERROR names the act and its tree" grep -q "ERROR disk act pid ${t14_pid} has run" "$t14/resource-watch.log"
expect_yes "T15a: the snapshot line carries ALERT:disk-act-overrun" grep -q 'ALERT:disk-act-overrun' "$t14/resource-watch.log"
expect_yes "T15a: and it notifies" grep -q 'disk-act-overrun' "$t14/osascript"
expect_yes "T15a: the lock is released" test ! -e "$t14/state/disk-act.lock"
expect_yes "T15a: no new act starts in the same round" test "$(grep -c '^janitor' "$t14/calls")" -eq 1
kill "$t15_decoy" 2>/dev/null; wait "$t15_decoy" 2>/dev/null || true
for p in $t15_alive; do kill -KILL "$p" 2>/dev/null || true; done

t15b=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
GUARD_NOWAIT=1 guard_case "$t15b" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh"
t15b_pid=$(cat "$t15b/state/disk-act.lock/pid" 2>/dev/null || true)
echo "$(( $(date +%s) - 6000 ))" > "$t15b/state/disk-act.lock/started"
GUARD_NOWAIT=1 guard_case "$t15b" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_MAX_SECONDS=0
expect_yes "T15b: CC_RW_ACT_MAX_SECONDS=0 leaves a long act running" kill -0 "${t15b_pid:-0}"
i=0; while [ "$(wc -l < "$t15b/pids" 2>/dev/null || echo 0)" -lt 2 ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
GUARD_NOWAIT=1 guard_case "$t15b" 30 CC_RW_JANITOR_SCRIPT="$guard_dir/janitor-slow.sh" CC_RW_ACT_KILL_GRACE_SECS=1
for p in ${t15b_pid:-} $(cat "$t15b/pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# T16: a stale lock is taken over; a pid that is not an act is never signalled
# ---------------------------------------------------------------------------
bash -c 'exit 0' &
t16_dead=$!
wait "$t16_dead" || true
t16=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t16/state/disk-act.lock"
echo "$t16_dead" > "$t16/state/disk-act.lock/pid"; echo "$(( $(date +%s) - 100 ))" > "$t16/state/disk-act.lock/started"
guard_case "$t16" 30
expect_yes "T16a: a dead pid's lock is logged stale" grep -q "WARN disk act lock stale (pid ${t16_dead}" "$t16/resource-watch.log"
expect_yes "T16a: and the round starts a new act" grep -q '^janitor' "$t16/calls"
expect_yes "T16a: which releases the lock when done" test ! -e "$t16/state/disk-act.lock"

sleep 300 &
t16_other=$!
t16b=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t16b/state/disk-act.lock"
echo "$t16_other" > "$t16b/state/disk-act.lock/pid"; echo "$(( $(date +%s) - 9000 ))" > "$t16b/state/disk-act.lock/started"
guard_case "$t16b" 30 CC_RW_ACT_KILL_GRACE_SECS=1
expect_yes "T16b: a live pid that is not an act is stale, not an overrun" grep -q 'WARN disk act lock stale' "$t16b/resource-watch.log"
expect_no  "T16b: no overrun is raised for it" grep -q 'ALERT:disk-act-overrun' "$t16b/resource-watch.log"
expect_yes "T16b: and it is never signalled" kill -0 "$t16_other"
expect_yes "T16b: the new act runs" grep -q '^janitor' "$t16b/calls"
kill "$t16_other" 2>/dev/null; wait "$t16_other" 2>/dev/null || true

t16c=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t16c/state/disk-act.lock"
echo "$(date +%s)" > "$t16c/state/disk-act.lock/started"
GUARD_NOWAIT=1 guard_case "$t16c" 30
expect_no  "T16c: a lock claimed just now with no pid yet is a spawn in flight" grep -q '^janitor' "$t16c/calls"
expect_yes "T16c: logged as running" grep -q 'ACT:running:spawning' "$t16c/resource-watch.log"
echo "$(( $(date +%s) - 200 ))" > "$t16c/state/disk-act.lock/started"
guard_case "$t16c" 30
expect_yes "T16c: the same lock 200s old is stale and taken over" grep -q '^janitor' "$t16c/calls"

# Two rounds racing past the supervisor: the mkdir claim alone must keep the second out.
t16d=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t16d/state/disk-act.lock"
t16d_rc=0
(
  export CC_RW_LOG="$t16d/resource-watch.log" CC_RW_STATE_DIR="$t16d/state" CC_RW_TEST_CALLS="$t16d/calls"
  export CC_RW_JANITOR_SCRIPT="$guard_dir/janitor.sh" CC_RW_RECLAIM_SCRIPT="$guard_dir/reclaim.sh"
  source "$ROOT_DIR/shell/resource-watch.sh"
  _cc_rw_disk_act 30 "$(date +%s)"
) || t16d_rc=$?
sleep 1
expect_yes "T16d: a claim against an existing lock directory fails" test "$t16d_rc" -ne 0
expect_no  "T16d: and starts no act" test -s "$t16d/calls"
expect_no  "T16d: nor touches the cooldown stamp" test -e "$t16d/state/cooldown-disk-act"

# ---------------------------------------------------------------------------
# T17: D7 write rate over the last ~60 minutes; >10GB/h alerts, >20GB/h flags, cleared below
# ---------------------------------------------------------------------------
rate_seed() {
  local dir
  dir=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
  mkdir -p "$dir/state"
  printf '%s\n' "$@" | tr ' ' '\t' > "$dir/state/disk-free-samples.tsv"
  echo "$dir"
}
t17_now=$(date +%s)
t17a=$(rate_seed "$((t17_now - 3600)) $((130 * GB))")
guard_case "$t17a" 100
expect_yes "T17a: 30GB in an hour logs ALERT:disk-rate" grep -q 'ALERT:disk-rate' "$t17a/resource-watch.log"
expect_yes "T17a: with the rate on the line" grep -qE 'disk_rate=(29\.9|30\.0)GB/h' "$t17a/resource-watch.log"
expect_yes "T17a: and writes the disk-rate-high flag" test -f "$t17a/state/disk-rate-high"
expect_yes "T17a: and notifies" grep -q 'GB/h' "$t17a/osascript"
expect_yes "T17a: the sample is appended as epoch<TAB>free KB" \
  awk -F'\t' 'END { exit !(NF == 2 && $2 == 100 * 1048576) }' "$t17a/state/disk-free-samples.tsv"
printf '%s\t%s\n' "$((t17_now - 3500))" "$((105 * GB))" > "$t17a/state/disk-free-samples.tsv"
guard_case "$t17a" 100
expect_no  "T17b: a 5GB/h rate clears the flag" test -e "$t17a/state/disk-rate-high"
expect_no  "T17b: and raises no new ALERT:disk-rate" test "$(grep -c 'ALERT:disk-rate' "$t17a/resource-watch.log")" -gt 1

t17c=$(rate_seed "$((t17_now - 3600)) $((115 * GB))")
guard_case "$t17c" 100
expect_yes "T17c: 15GB/h alerts" grep -q 'ALERT:disk-rate' "$t17c/resource-watch.log"
expect_no  "T17c: but sets no flag" test -e "$t17c/state/disk-rate-high"

t17d=$(rate_seed "$((t17_now - 3500)) $((120 * GB))" "$((t17_now - 1800)) $((100 * GB))")
guard_case "$t17d" 100
expect_yes "T17d: the oldest sample in the window is the one compared (20GB in 3500s > 20GB/h)" \
  test -f "$t17d/state/disk-rate-high"

t17e=$(rate_seed "$((t17_now - 7200)) $((200 * GB))" "$((t17_now - 600)) $((110 * GB))")
touch "$t17e/state/disk-rate-high"
guard_case "$t17e" 100
expect_no  "T17e: no sample 20-65 minutes old means no rate" grep -qE 'disk_rate=|ALERT:disk-rate' "$t17e/resource-watch.log"
expect_yes "T17e: and an unmeasured round leaves the flag as it was" test -f "$t17e/state/disk-rate-high"

t17f=$(rate_seed "$((t17_now - 3600)) $((80 * GB))")
touch "$t17f/state/disk-rate-high"
guard_case "$t17f" 100
expect_no  "T17f: free space growing is no alert" grep -q 'ALERT:disk-rate' "$t17f/resource-watch.log"
expect_no  "T17f: and clears the flag" test -e "$t17f/state/disk-rate-high"

t17g=$(rate_seed "$((t17_now - 200000)) $((100 * GB))" "$((t17_now - 180000)) $((100 * GB))" "$((t17_now - 1000)) $((100 * GB))")
guard_case "$t17g" 100
expect_yes "T17g: samples older than 48h are dropped (2 lines kept)" \
  test "$(wc -l < "$t17g/state/disk-free-samples.tsv")" -eq 2

t17h=$(rate_seed "$((t17_now - 3600)) $((130 * GB))")
guard_case "$t17h" 100 CC_RW_RATE_ALERT_GBH=0 CC_RW_RATE_FLAG_GBH=0
expect_no  "T17h: CC_RW_RATE_*_GBH=0 disable alert and flag" \
  sh -c "grep -q 'ALERT:disk-rate' '$t17h/resource-watch.log' || test -e '$t17h/state/disk-rate-high'"

# T17s: swap over CC_RW_SWAP_FLAG_GB holds heavy leases and says so in its own flag
t17s=$(rate_seed "$((t17_now - 3600)) $((80 * GB))")
guard_case "$t17s" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2
expect_yes "T17s: swap 22.5 > 18 under pressure 2 writes swap-high" test -f "$t17s/state/swap-high"
expect_yes "T17s: swap-high is <epoch> swap=<gb> limit=<gb> pressure=<n> swapouts=<n|?>" \
  grep -qE '^[0-9]+ swap=22\.5 limit=18 pressure=2 swapouts=\?$' "$t17s/state/swap-high"
expect_yes "T17s: and disk-rate-high with swap=" grep -q 'swap=22.5' "$t17s/state/disk-rate-high"
expect_yes "T17s: and ALERT:swap" grep -q 'ALERT:swap' "$t17s/resource-watch.log"
guard_case "$t17s" 100 CC_RW_SWAP_USED_GB=3.0
expect_no  "T17s: swap back under the limit removes swap-high" test -e "$t17s/state/swap-high"
expect_no  "T17s: and disk-rate-high" test -e "$t17s/state/disk-rate-high"
t17u=$(rate_seed "$((t17_now - 3600)) $((80 * GB))")
echo "1 swap=30 limit=18" > "$t17u/state/swap-high"
guard_case "$t17u" 100 CC_RW_SWAP_USED_GB=
expect_yes "T17u: unreadable swap leaves swap-high alone" test -f "$t17u/state/swap-high"
t17v=$(rate_seed "$((t17_now - 3600)) $((80 * GB))")
guard_case "$t17v" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_SWAP_FLAG_GB=30
expect_no  "T17v: CC_RW_SWAP_FLAG_GB raises the limit" test -e "$t17v/state/swap-high"

# T17w: macOS never shrinks swap, so the flag holds only while swap is still written:
# over the limit AND (pressure >= 2 OR Swapouts grew since the stored sample)
t17w_flags() { echo "1 swap=30 limit=18" > "$1/state/swap-high"; echo "1 0 100 swap=30" > "$1/state/disk-rate-high"; }
t17w=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17w"; echo 1000 > "$t17w/state/swapouts-last"
guard_case "$t17w" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=1000
expect_no  "T17w: high (20.9 > 18) but calm (pressure 1, Swapouts unchanged) removes swap-high" test -e "$t17w/state/swap-high"
expect_no  "T17w: and disk-rate-high, the rate being calm" test -e "$t17w/state/disk-rate-high"
expect_no  "T17w: and raises no ALERT:swap" grep -q 'ALERT:swap' "$t17w/resource-watch.log"
expect_yes "T17w: the Swapouts sample is kept" grep -qx 1000 "$t17w/state/swapouts-last"
guard_case "$t17w" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=1500
expect_yes "T17x: high and growing (Swapouts 1000 -> 1500, pressure 1) writes swap-high" \
  grep -qE '^[0-9]+ swap=20\.9 limit=18 pressure=1 swapouts=1500$' "$t17w/state/swap-high"
expect_yes "T17x: and disk-rate-high with swap=" grep -q 'swap=20.9' "$t17w/state/disk-rate-high"
expect_yes "T17x: and ALERT:swap" grep -q 'ALERT:swap' "$t17w/resource-watch.log"
expect_yes "T17x: the stored sample moves to 1500" grep -qx 1500 "$t17w/state/swapouts-last"
t17y=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); echo 1000 > "$t17y/state/swapouts-last"
guard_case "$t17y" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_SWAPOUTS=1000
expect_yes "T17y: pressure 2 with Swapouts unchanged writes swap-high" test -f "$t17y/state/swap-high"
expect_yes "T17y: and disk-rate-high" test -f "$t17y/state/disk-rate-high"
expect_yes "T17y: and ALERT:swap" grep -q 'ALERT:swap' "$t17y/resource-watch.log"
t17z=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17z"; echo 1000 > "$t17z/state/swapouts-last"
guard_case "$t17z" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL= CC_RW_SWAPOUTS=
expect_yes "T17z: high swap with pressure and Swapouts unreadable leaves swap-high as it was" \
  test "$(cat "$t17z/state/swap-high")" = "1 swap=30 limit=18"
expect_yes "T17z: and disk-rate-high as it was" test "$(cat "$t17z/state/disk-rate-high")" = "1 0 100 swap=30"
expect_yes "T17z: and the stored sample" grep -qx 1000 "$t17z/state/swapouts-last"
t17z2=$(rate_seed "$((t17_now - 3600)) $((80 * GB))")
guard_case "$t17z2" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL= CC_RW_SWAPOUTS=
expect_no  "T17z: nor sets swap-high when there was none" test -e "$t17z2/state/swap-high"
expect_no  "T17z: nor disk-rate-high, the rate being calm" test -e "$t17z2/state/disk-rate-high"
t17u2=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17u2"; echo 1000 > "$t17u2/state/swapouts-last"
guard_case "$t17u2" 100 CC_RW_SWAP_USED_GB=3.0 CC_RW_VM_PRESSURE_LEVEL=3 CC_RW_SWAPOUTS=9000
expect_no  "T17u2: swap under the limit clears swap-high, whatever pressure and Swapouts say" test -e "$t17u2/state/swap-high"
expect_no  "T17u2: and disk-rate-high" test -e "$t17u2/state/disk-rate-high"
t17r=$(rate_seed "$((t17_now - 3600)) $((130 * GB))"); t17w_flags "$t17r"; echo 1000 > "$t17r/state/swapouts-last"
guard_case "$t17r" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=1000
expect_no  "T17r: calm swap removes swap-high" test -e "$t17r/state/swap-high"
expect_yes "T17r: but a 30GB/h rate keeps disk-rate-high" test -f "$t17r/state/disk-rate-high"
t17f1=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17f1"
guard_case "$t17f1" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=1000
expect_no  "T17f1: first round (no stored Swapouts) at pressure 1: growth unknown, the flag clears" test -e "$t17f1/state/swap-high"
expect_yes "T17f1: and the first sample is stored" grep -qx 1000 "$t17f1/state/swapouts-last"
t17b1=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17b1"; echo 5000 > "$t17b1/state/swapouts-last"
guard_case "$t17b1" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=100
expect_no  "T17b1: Swapouts below the stored count (a reboot's reset) is not growth" test -e "$t17b1/state/swap-high"
expect_yes "T17b1: and the reset count is stored" grep -qx 100 "$t17b1/state/swapouts-last"
t17p=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17p"; echo 1000 > "$t17p/state/swapouts-last"
guard_case "$t17p" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL= CC_RW_SWAPOUTS=1000
expect_no  "T17p: pressure unreadable, Swapouts readable and unchanged: the flag clears" test -e "$t17p/state/swap-high"
t17f2=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17f2"
guard_case "$t17f2" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL= CC_RW_SWAPOUTS=1000
expect_yes "T17f2: first round with pressure unreadable: no calm evidence, swap-high left as it was" \
  test "$(cat "$t17f2/state/swap-high")" = "1 swap=30 limit=18"
expect_yes "T17f2: and its disk-rate-high" test "$(cat "$t17f2/state/disk-rate-high")" = "1 0 100 swap=30"
expect_yes "T17f2: the first sample is still stored" grep -qx 1000 "$t17f2/state/swapouts-last"
guard_case "$t17f2" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL= CC_RW_SWAPOUTS=1000
expect_no  "T17f2: the next round, Swapouts unchanged, clears it" test -e "$t17f2/state/swap-high"
t17q=$(rate_seed "$((t17_now - 3600)) $((80 * GB))"); t17w_flags "$t17q"; echo 1000 > "$t17q/state/swapouts-last"
guard_case "$t17q" 100 CC_RW_SWAP_USED_GB=20.9 CC_RW_VM_PRESSURE_LEVEL=1 CC_RW_SWAPOUTS=
expect_no  "T17q: pressure 1, Swapouts unreadable: the flag clears" test -e "$t17q/state/swap-high"
expect_yes "T17q: and an unreadable count leaves the stored sample" grep -qx 1000 "$t17q/state/swapouts-last"

# ---------------------------------------------------------------------------
# T18: the go cache cap is bounded, so a hung cap cannot hold the round
# ---------------------------------------------------------------------------
cat > "$guard_dir/reclaim-hang.sh" <<'STUB'
#!/usr/bin/env bash
echo "$$" >> "$CC_RW_TEST_PIDS"
sleep 300 &
echo "$!" >> "$CC_RW_TEST_PIDS"
wait
STUB
t18=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
t18_start=$(date +%s)
guard_case "$t18" 100 CC_RW_RECLAIM_SCRIPT="$guard_dir/reclaim-hang.sh" CC_RW_GO_CAP_MAX_SECONDS=1
t18_secs=$(( $(date +%s) - t18_start ))
t18_alive=""
for p in $(cat "$t18/pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && t18_alive="$t18_alive $p"; done
expect_yes "T18: a hung go cache cap is ended and the round returns within 10s (${t18_secs}s)" test "$t18_secs" -le 10
expect_yes "T18: its pids are gone" test -z "$t18_alive"
expect_yes "T18: and an ERROR says so" grep -q 'ERROR bash .*--go-cache-cap ran over 1s' "$t18/resource-watch.log"
for p in $t18_alive; do kill -KILL "$p" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# T19: a stalled reclaimer (stima-api #5886): reclaim-byproducts' last-finished stamp older than
# 2 x its hourly StartInterval (7200s) raises ALERT:reclaim-stalled, once per stall, alert only.
# ---------------------------------------------------------------------------
ago() { date -v-"$1"S +%Y%m%d%H%M.%S; }   # a touch -t stamp this many seconds back
t19_alerts() { grep -c 'ALERT:reclaim-stalled' "$1/resource-watch.log" 2>/dev/null || true; }
t19_notes() { grep -c 'reclaim-stalled' "$1/osascript" 2>/dev/null || true; }

t19=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t19/state"
touch -t "$(ago 10800)" "$t19/stamp"
guard_case "$t19" 100 CC_RW_RECLAIM_STAMP="$t19/stamp"
expect_yes "T19a: a stamp 3h old logs ALERT:reclaim-stalled" grep -q 'ALERT:reclaim-stalled' "$t19/resource-watch.log"
expect_yes "T19a: and notifies once" test "$(t19_notes "$t19")" -eq 1
expect_yes "T19a: the notification names the age" grep -Eq 'last finished sweep was 1080[0-9]s ago' "$t19/osascript"
guard_case "$t19" 100 CC_RW_RECLAIM_STAMP="$t19/stamp"
expect_yes "T19b: a second round on the same stall raises no second alert" test "$(t19_alerts "$t19")" -eq 1
expect_yes "T19b: and no second notification" test "$(t19_notes "$t19")" -eq 1
expect_no "T19c: alert only: the round started no reclaim and ended nothing" grep -qE '^janitor|^reclaim $' "$t19/calls"
touch "$t19/stamp"
guard_case "$t19" 100 CC_RW_RECLAIM_STAMP="$t19/stamp"
expect_yes "T19d: a fresh stamp re-arms the alert (the marker is gone)" test ! -e "$t19/state/reclaim-stalled.alerted"
expect_yes "T19d: and a fresh stamp alerts nothing" test "$(t19_alerts "$t19")" -eq 1
touch -t "$(ago 9000)" "$t19/stamp"
guard_case "$t19" 100 CC_RW_RECLAIM_STAMP="$t19/stamp"
expect_yes "T19e: the next stall alerts again" test "$(t19_alerts "$t19")" -eq 2
expect_yes "T19e: with its own notification" test "$(t19_notes "$t19")" -eq 2

t19b=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkdir -p "$t19b/state"
touch -t "$(ago 7100)" "$t19b/stamp"
guard_case "$t19b" 100 CC_RW_RECLAIM_STAMP="$t19b/stamp"
expect_no "T19f: 7100s old is inside the 7200s line: no alert" grep -q 'ALERT:reclaim-stalled' "$t19b/resource-watch.log"
touch -t "$(ago 7300)" "$t19b/stamp"
guard_case "$t19b" 100 CC_RW_RECLAIM_STAMP="$t19b/stamp"
expect_yes "T19f: 7300s old is over it: alert" grep -q 'ALERT:reclaim-stalled' "$t19b/resource-watch.log"
touch -t "$(ago 3000)" "$t19b/stamp"
guard_case "$t19b" 100 CC_RW_RECLAIM_STAMP="$t19b/stamp" CC_RW_RECLAIM_STALL_SECS=2400
expect_yes "T19g: the line is a knob (CC_RW_RECLAIM_STALL_SECS=2400, stamp 3000s old)" test "$(t19_alerts "$t19b")" -eq 2

# The line follows the installed agent: twice its StartInterval (7200 on the Mac mini, so 14400),
# 172800 for a calendar schedule, 7200 when the plist cannot be read.
mkplist() {  # <file> <keyxml>
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>x</string>%s</dict></plist>\n' "$2" > "$1"
}
t19p=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkplist "$t19p/p.plist" '<key>StartInterval</key><integer>7200</integer>'
touch -t "$(ago 10800)" "$t19p/stamp"
guard_case "$t19p" 100 CC_RW_RECLAIM_STAMP="$t19p/stamp" CC_RW_RECLAIM_PLIST="$t19p/p.plist"
expect_no "T19l: a 3h stamp is no stall for an agent that starts every 7200s (line 14400s)" grep -q 'ALERT:reclaim-stalled' "$t19p/resource-watch.log"
touch -t "$(ago 15000)" "$t19p/stamp"
guard_case "$t19p" 100 CC_RW_RECLAIM_STAMP="$t19p/stamp" CC_RW_RECLAIM_PLIST="$t19p/p.plist"
expect_yes "T19l: 15000s is" grep -q 'ALERT:reclaim-stalled' "$t19p/resource-watch.log"
expect_yes "T19l: and the alert names the line it used" grep -q 'over 14400s' "$t19p/osascript"
t19q=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkplist "$t19q/p.plist" '<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer></dict>'
touch -t "$(ago 100000)" "$t19q/stamp"
guard_case "$t19q" 100 CC_RW_RECLAIM_STAMP="$t19q/stamp" CC_RW_RECLAIM_PLIST="$t19q/p.plist"
expect_no "T19m: a daily agent's stamp 28h old is no stall" grep -q 'ALERT:reclaim-stalled' "$t19q/resource-watch.log"
t19r=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); touch -t "$(ago 7500)" "$t19r/stamp"
guard_case "$t19r" 100 CC_RW_RECLAIM_STAMP="$t19r/stamp" CC_RW_RECLAIM_PLIST="$t19r/no-such.plist"
expect_yes "T19n: an unreadable plist falls back to 7200s" grep -q 'over 7200s' "$t19r/osascript"

t19c=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$t19c" 100 CC_RW_RECLAIM_STAMP="$t19c/no-stamp"
# A fresh install has no stamp yet: that is not a stall (the first sweep has not finished). One
# info line, once; a stale stamp, not a missing one, is what alerts (T19a).
expect_no "T19h: no stamp at all (a fresh install) raises no alert" grep -q 'ALERT:reclaim-stalled' "$t19c/resource-watch.log"
expect_no "T19h: and no notification" test -s "$t19c/osascript"
expect_yes "T19h: but says so, as info" grep -q 'INFO reclaim-stalled: no finished-sweep stamp yet' "$t19c/resource-watch.log"
guard_case "$t19c" 100 CC_RW_RECLAIM_STAMP="$t19c/no-stamp"
expect_yes "T19h: once" test "$(grep -c 'INFO reclaim-stalled' "$t19c/resource-watch.log")" -eq 1
expect_no "T19h: and still no alert on the second round" grep -q 'ALERT:reclaim-stalled' "$t19c/resource-watch.log"
touch "$t19c/no-stamp"; touch -t "$(ago 40000)" "$t19c/no-stamp"
guard_case "$t19c" 100 CC_RW_RECLAIM_STAMP="$t19c/no-stamp"
expect_yes "T19h: the stamp appears and is stale: that alerts" test "$(t19_alerts "$t19c")" -eq 1

# No stamp is judged from a baseline: the reclaim plist's mtime (the agent's install), else the
# script's. A reclaimer whose first sweep hangs, or that always fails, never writes a stamp, and
# silence forever is the failure this alert exists for.
t19s=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkplist "$t19s/p.plist" '<key>StartInterval</key><integer>7200</integer>'
guard_case "$t19s" 100 CC_RW_RECLAIM_STAMP="$t19s/no-stamp" CC_RW_RECLAIM_PLIST="$t19s/p.plist"
expect_no "T19o: no stamp and a plist installed just now: no alert" grep -q 'ALERT:reclaim-stalled' "$t19s/resource-watch.log"
expect_yes "T19o: one info line" test "$(grep -c 'INFO reclaim-stalled: no finished-sweep stamp yet' "$t19s/resource-watch.log")" -eq 1
t19t=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); mkplist "$t19t/p.plist" '<key>StartInterval</key><integer>7200</integer>'
touch -t "$(ago 15000)" "$t19t/p.plist"
guard_case "$t19t" 100 CC_RW_RECLAIM_STAMP="$t19t/no-stamp" CC_RW_RECLAIM_PLIST="$t19t/p.plist"
expect_yes "T19p: no stamp and a plist older than the line (15000s > 14400s): alert" test "$(t19_alerts "$t19t")" -eq 1
expect_yes "T19p: the notification says no sweep has finished since the install" grep -q 'no finished-sweep stamp.*installed 150[0-9][0-9]s ago (over 14400s)' "$t19t/osascript"
guard_case "$t19t" 100 CC_RW_RECLAIM_STAMP="$t19t/no-stamp" CC_RW_RECLAIM_PLIST="$t19t/p.plist"
expect_yes "T19p: once, not every round" test "$(t19_alerts "$t19t")" -eq 1
expect_yes "T19p: one notification" test "$(t19_notes "$t19t")" -eq 1
touch "$t19t/stamp"
guard_case "$t19t" 100 CC_RW_RECLAIM_STAMP="$t19t/stamp" CC_RW_RECLAIM_PLIST="$t19t/p.plist"
expect_yes "T19q: a fresh stamp appearing re-arms (the marker is gone)" test ! -e "$t19t/state/reclaim-stalled.alerted"
expect_yes "T19q: and alerts nothing more" test "$(t19_alerts "$t19t")" -eq 1
rm -f "$t19t/stamp"
guard_case "$t19t" 100 CC_RW_RECLAIM_STAMP="$t19t/no-stamp" CC_RW_RECLAIM_PLIST="$t19t/p.plist"
expect_yes "T19q: the next stampless stall alerts again" test "$(t19_alerts "$t19t")" -eq 2
# No readable plist: the script's mtime is the baseline.
t19u=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); : > "$t19u/reclaim.sh"; touch -t "$(ago 8000)" "$t19u/reclaim.sh"
guard_case "$t19u" 100 CC_RW_RECLAIM_STAMP="$t19u/no-stamp" CC_RW_RECLAIM_PLIST="$t19u/no-such.plist" CC_RW_RECLAIM_SCRIPT="$t19u/reclaim.sh"
expect_yes "T19r: no stamp, no plist, a script older than the 7200s fallback line: alert" test "$(t19_alerts "$t19u")" -eq 1
t19v=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); : > "$t19v/reclaim.sh"
guard_case "$t19v" 100 CC_RW_RECLAIM_STAMP="$t19v/no-stamp" CC_RW_RECLAIM_PLIST="$t19v/no-such.plist" CC_RW_RECLAIM_SCRIPT="$t19v/reclaim.sh"
expect_no "T19r: and a script installed just now is not" grep -q 'ALERT:reclaim-stalled' "$t19v/resource-watch.log"

t19d=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); touch -t "$(ago 10800)" "$t19d/stamp"
guard_case "$t19d" 100 CC_RW_RECLAIM_STAMP="$t19d/stamp" CC_RW_RECLAIM_SCRIPT=/nonexistent/reclaim-byproducts.sh
expect_no "T19i: a reclaimer that is not installed cannot be stalled" grep -q 'ALERT:reclaim-stalled' "$t19d/resource-watch.log"
t19e=$(mktemp -d "$TMPDIR_ROOT/XXXXXX"); touch -t "$(ago 10800)" "$t19e/stamp"
guard_case "$t19e" 100 CC_RW_RECLAIM_STAMP="$t19e/stamp" CC_RW_RECLAIM_STALL_SECS=0
expect_no "T19j: CC_RW_RECLAIM_STALL_SECS=0 turns it off" grep -q 'ALERT:reclaim-stalled' "$t19e/resource-watch.log"
t19f=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
touch -t "$(date -v+1H +%Y%m%d%H%M.%S)" "$t19f/stamp"
guard_case "$t19f" 100 CC_RW_RECLAIM_STAMP="$t19f/stamp"
expect_no "T19k: a stamp dated in the future is fresh, not a stall" grep -q 'ALERT:reclaim-stalled' "$t19f/resource-watch.log"

# ---------------------------------------------------------------------------
# T20: the pause chain (EL-T24): one line per change of the combined pause state, shadow by default
# ---------------------------------------------------------------------------
t20_events() { grep -c ' EVENT ' "$1/resource-watch.log" 2>/dev/null || true; }
t20_lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
t20_now=$(date +%s)

t20a=$(rate_seed "$((t20_now - 3600)) $((80 * GB))")
guard_case "$t20a" 100 CC_RW_SWAP_USED_GB=3.0
expect_yes "T20a: nothing paused on a first round: no EVENT line" test "$(t20_events "$t20a")" -eq 0
expect_yes "T20a: the shadow state starts as clear" grep -qx clear "$t20a/state/disk-pause.shadow.state"
expect_no  "T20a: shadow writes no on-mode state" test -e "$t20a/state/disk-pause.state"
expect_yes "T20a: the snapshot line carries swap= and rate=" \
  grep -qE 'disk_free=100\.0GB/[0-9.]+% swap=3\.0GB rate=-20\.0GB/h( |$)' "$t20a/resource-watch.log"
guard_case "$t20a" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2
expect_yes "T20b: swap over the line: one shadow EVENT" test "$(t20_events "$t20a")" -eq 1
expect_yes "T20b: it names every flag present, in order, and the values" \
  grep -qE "EVENT shadow \(CC_RW_PAUSE_EVENTS=shadow\): would emit to $CC_RW_EVENTS_LOG: DISK-PAUSE on: disk-rate-high,swap-high free=100\.0GB swap=22\.5GB rate=-?[0-9.]+GB/h$" "$t20a/resource-watch.log"
expect_no  "T20b: shadow appends nothing to the events log" test -e "$CC_RW_EVENTS_LOG"
expect_yes "T20b: the shadow state records the pause" grep -qx 'paused disk-rate-high,swap-high' "$t20a/state/disk-pause.shadow.state"
guard_case "$t20a" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2
expect_yes "T20c: the same state next round tells nothing (deduped)" test "$(t20_events "$t20a")" -eq 1
guard_case "$t20a" 100 CC_RW_SWAP_USED_GB=3.0
expect_yes "T20d: every flag cleared: one DISK-RESUME" \
  grep -qE 'would emit to .*: DISK-RESUME: all clear free=100\.0GB swap=3\.0GB rate=-?[0-9.]+GB/h$' "$t20a/resource-watch.log"
guard_case "$t20a" 100 CC_RW_SWAP_USED_GB=3.0
expect_yes "T20d: and nothing the round after" test "$(t20_events "$t20a")" -eq 2

# on: the line goes to events.log, stamped as events.log stamps (diskwatch.py's %Y-%m-%dT%H:%M:%S%z)
t20e=$(rate_seed "$((t20_now - 3600)) $((80 * GB))"); ev="$t20e/events.log"
guard_case "$t20e" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$ev"
expect_yes "T20e: on: one line in events.log" test "$(t20_lines "$ev")" -eq 1
expect_yes "T20e: in the events.log shape" \
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} DISK-PAUSE on: disk-rate-high,swap-high free=100\.0GB swap=22\.5GB rate=' "$ev"
expect_yes "T20e: and the round's log says it was emitted" grep -q "EVENT emitted to $ev: DISK-PAUSE on:" "$t20e/resource-watch.log"
guard_case "$t20e" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$ev"
expect_yes "T20e: deduped across rounds" test "$(t20_lines "$ev")" -eq 1
guard_case "$t20e" 100 CC_RW_SWAP_USED_GB=3.0 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$ev"
guard_case "$t20e" 100 CC_RW_SWAP_USED_GB=3.0 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$ev"
expect_yes "T20e: one DISK-RESUME, once" test "$(t20_lines "$ev")" -eq 2
expect_yes "T20e: the second line is the resume" sh -c "tail -n 1 '$ev' | grep -q ' DISK-RESUME: all clear free=100.0GB swap=3.0GB rate='"

t20f=$(rate_seed "$((t20_now - 3600)) $((80 * GB))"); echo "EL-X stop for a test" > "$t20f/state/disk-stop"
guard_case "$t20f" 100 CC_RW_SWAP_USED_GB=3.0 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$t20f/events.log"
expect_yes "T20f: a dispatched disk-stop alone is a pause" grep -q ' DISK-PAUSE on: disk-stop free=' "$t20f/events.log"

t20g=$(rate_seed "$((t20_now - 3600)) $((5 * GB))")
guard_case "$t20g" 15 CC_RW_SWAP_USED_GB=3.0 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$t20g/events.log" CC_RW_DISK_ACT_GB=0
expect_yes "T20g: free under the emergency line is a pause" grep -q ' DISK-PAUSE on: disk-emergency free=15.0GB ' "$t20g/events.log"

t20h=$(rate_seed "$((t20_now - 3600)) $((80 * GB))")
guard_case "$t20h" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$t20h/no-such-dir/events.log"
expect_yes "T20h: an append that fails is an ERROR line" grep -q 'ERROR pause chain: cannot append to' "$t20h/resource-watch.log"
expect_no  "T20h: and leaves the state untold" test -e "$t20h/state/disk-pause.state"
guard_case "$t20h" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$t20h/events.log"
expect_yes "T20h: so the next round tells it" grep -q ' DISK-PAUSE on: ' "$t20h/events.log"

t20i=$(rate_seed "$((t20_now - 3600)) $((80 * GB))")
guard_case "$t20i" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=off CC_RW_EVENTS_LOG="$t20i/events.log"
expect_yes "T20i: off: no EVENT line" test "$(t20_events "$t20i")" -eq 0
expect_no  "T20i: no events.log" test -e "$t20i/events.log"
expect_no  "T20i: and no state" sh -c "ls '$t20i/state' | grep -q disk-pause"

t20j=$(rate_seed "$((t20_now - 3600)) $((80 * GB))")
guard_case "$t20j" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=bogus CC_RW_EVENTS_LOG="$t20j/events.log"
expect_yes "T20j: an unknown mode is shadow" grep -q 'EVENT shadow' "$t20j/resource-watch.log"
expect_no  "T20j: and writes no events.log" test -e "$t20j/events.log"
guard_case "$t20j" 100 CC_RW_SWAP_USED_GB=22.5 CC_RW_VM_PRESSURE_LEVEL=2 CC_RW_PAUSE_EVENTS=on CC_RW_EVENTS_LOG="$t20j/events.log"
expect_yes "T20k: turned on mid-pause, on tells the pause it finds (its own state)" \
  test "$(t20_lines "$t20j/events.log")" -eq 1

t20u=$(mktemp -d "$TMPDIR_ROOT/XXXXXX")
guard_case "$t20u" 100
expect_yes "T20l: unreadable swap and an unmeasured rate are ?" grep -qE 'GB/[0-9.]+% swap=\? rate=\?( |$)' "$t20u/resource-watch.log"

# T21: the judge (shell/resource-watch-judge.py) agrees with what the script really wrote, and catches a change
t21_judge() { PATH="$stub_dir:$PATH" python3 "$ROOT_DIR/shell/resource-watch-judge.py" --plist /nonexistent "$@" >/dev/null; }
expect_yes "T21a: the judge passes the T20 shadow log (pause, resume, swap= and rate= lines)" t21_judge --log "$t20a/resource-watch.log"
expect_yes "T21a: and the T20 on-mode log" t21_judge --log "$t20e/resource-watch.log"
sed 's/ ALERT:swap//' "$t20a/resource-watch.log" > "$t20a/no-swap-marker.log"
expect_no  "T21b: a swap_hot=1 line without ALERT:swap is a miss" t21_judge --log "$t20a/no-swap-marker.log"
expect_yes "T21b: (those lines do carry swap_hot=1)" grep -q ' swap=22\.5GB rate=[^ ]* swap_hot=1 ' "$t20a/resource-watch.log"
expect_yes "T21d: the judge passes the T17w log (swap high but calm, then growing)" t21_judge --log "$t17w/resource-watch.log"
expect_yes "T21d: whose calm line says swap_hot=0 and has no ALERT:swap" \
  sh -c "head -n 1 '$t17w/resource-watch.log' | grep ' swap=20\.9GB rate=[^ ]* swap_hot=0' | grep -qv 'ALERT:swap'"
expect_yes "T21d: and the T17z log (pressure and Swapouts unreadable: swap_hot=?)" t21_judge --log "$t17z/resource-watch.log"
expect_yes "T21d: (swap_hot=? on it)" grep -q ' swap_hot=? ' "$t17z/resource-watch.log"
sed -E 's/ swap_hot=[01?]//' "$t17w/resource-watch.log" > "$t17w/legacy.log"
expect_no  "T21e: the same lines without swap_hot (a legacy log) keep the size-only rule: a miss" \
  t21_judge --log "$t17w/legacy.log"
grep -v 'DISK-RESUME' "$t20a/resource-watch.log" > "$t20a/no-resume.log"; grep 'DISK-PAUSE' "$t20a/resource-watch.log" >> "$t20a/no-resume.log"
expect_no  "T21c: a second DISK-PAUSE with no resume between is a miss" t21_judge --log "$t20a/no-resume.log"

if [ "$failures" -gt 0 ]; then
  printf "%s test failure(s)\n" "$failures"
  exit 1
fi

printf "resource-watch validation passed\n"
