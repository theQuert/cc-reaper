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
echo "/dev/disk3s5 976562500 195312500 104858562     20%  /System/Volumes/Data"
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

if [ "$failures" -gt 0 ]; then
  printf "%s test failure(s)\n" "$failures"
  exit 1
fi

printf "resource-watch validation passed\n"
