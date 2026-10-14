#!/usr/bin/env bash
# Calibration for the disk guard's reclaim half: the go build cache LRU cap
# (`reclaim-byproducts.sh --go-cache-cap`) and the session-temp reaper (task output files and
# finished ~/.claude/jobs tmp/). The resource-watch half (thresholds, cooldown) is T12 in
# tests/resource-watch.sh. Everything runs in a temp dir with HOME redirected and lsof faked.
#
# BYPRODUCT_SCRIPT points the suite at a COPY of the script, which is how each case is shown
# to fail without the change (the pre-change script) or under a mutation.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${BYPRODUCT_SCRIPT:-$REPO_ROOT/shell/reclaim-byproducts.sh}"
FAILURES=0; PASSED=0
pass() { echo "ok: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-disk-guard.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

mins_ago() { date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 minutes ago" +%Y%m%d%H%M; }
mib() { dd if=/dev/zero of="$1" bs=1048576 count="${2:-1}" 2>/dev/null; }
expect() { # label, condition command...
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# ------------------------------------------------------------------ go cache LRU cap
# Ten 1 MiB entries idle 100..1000 minutes, one 1 MiB entry idle 5 minutes, a top-level file
# and a fuzz/ file idle for ever. File NAMES run opposite to age (a lexical sort would pick
# the wrong ones). 8 MiB max, 4 MiB target, 60 minute floor.
cap_fixture() {
  local root="$1" i
  rm -rf "$root"; mkdir -p "$root/gc/fuzz" "$root/gc/aa" "$root/gc/bb" "$root/home"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    mib "$root/gc/aa/$(printf 'z%02d' $((11 - i)))-a"
    touch -t "$(mins_ago $((i * 100)))" "$root/gc/aa/$(printf 'z%02d' $((11 - i)))-a"   # z10 = 100m ... z01 = 1000m
  done
  mib "$root/gc/bb/fresh-d"; touch -t "$(mins_ago 5)" "$root/gc/bb/fresh-d"
  mib "$root/gc/testexpire.txt"; touch -t "$(mins_ago 99999)" "$root/gc/testexpire.txt"
  mib "$root/gc/fuzz/corpus-a"; touch -t "$(mins_ago 99999)" "$root/gc/fuzz/corpus-a"
}
cap_run() { # root, extra env as VAR=val..., then args after --
  local root="$1"; shift; local envs=(CC_UNUSED=1)
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env HOME="$root/home" BYPRODUCT_GO_CACHE_DIR="$root/gc" BYPRODUCT_LOG="$root/log" \
    CC_GO_CACHE_MAX_GB=0.0078125 CC_GO_CACHE_TARGET_GB=0.00390625 CC_GO_CACHE_MIN_AGE_MIN=60 \
    "${envs[@]}" bash "$SCRIPT" "${@:---go-cache-cap}" 2>&1
}
left() { (cd "$1/gc" && find . -type f | sort | tr '\n' ' '); }

R="$WORK/cap1"; cap_fixture "$R"
OUT="$(cap_run "$R" --)"
# du counts the top-level and fuzz/ files too: 13 MiB, target 4 MiB, so 9 MiB must go and the
# nine oldest entries (1000m..200m) are exactly that; z10 (100m), fresh and the two kept files
# are the 4 MiB left.
LEFT="$(left "$R")"
expect "over the cap, the oldest entries go first (z01..z09 gone, z10 stays)" \
  bash -c '! printf "%s" "$1" | grep -qE "/z0[1-9]-a" && printf "%s" "$1" | grep -q "/z10-a"' _ "$LEFT"
expect "an entry modified within the floor is never taken" grep -q 'bb/fresh-d' <<<"$LEFT"
expect "the top-level file and fuzz/ are never taken" bash -c 'printf "%s" "$1" | grep -q "./testexpire.txt" && printf "%s" "$1" | grep -q "fuzz/corpus-a"' _ "$LEFT"
expect "and it says what it did" grep -q 'go cache cap: .* is over 0.0078125GB; deleted 9 file(s) oldest-first' <<<"$OUT"

R="$WORK/cap2"; cap_fixture "$R"
OUT="$(cap_run "$R" CC_GO_CACHE_MAX_GB=1 --)"
expect "under the cap nothing is deleted and nothing is said" bash -c '[ -z "$1" ] && [ "$(find "$2/gc" -type f | wc -l | tr -d " ")" = 13 ]' _ "$OUT" "$R"

R="$WORK/cap3"; cap_fixture "$R"
OUT="$(cap_run "$R" CC_GO_CACHE_MIN_AGE_MIN=2000 --)"
expect "when every file is inside the floor nothing is deleted" bash -c '[ "$(find "$2/gc" -type f | wc -l | tr -d " ")" = 13 ]' _ "" "$R"
expect "and the log says the cache stayed over the target" grep -q 'deleted 0 file(s)' <<<"$OUT"

R="$WORK/cap4"; cap_fixture "$R"
OUT="$(cap_run "$R" -- --dry-run)"
expect "dry run deletes nothing" bash -c '[ "$(find "$2/gc" -type f | wc -l | tr -d " ")" = 13 ]' _ "" "$R"

R="$WORK/cap5"; cap_fixture "$R"
OUT="$(cap_run "$R" CC_GO_CACHE_MAX_GB=lots --)"
expect "a bad number caps nothing and says so" bash -c 'grep -q "not a number of GB; capping nothing" <<<"$1" && [ "$(find "$2/gc" -type f | wc -l | tr -d " ")" = 13 ]' _ "$OUT" "$R"

R="$WORK/cap6"; cap_fixture "$R"
OUT="$(cap_run "$R" CC_GO_CACHE_TARGET_GB=9 --)"
expect "a target above the max caps nothing" bash -c 'grep -q "above max" <<<"$1" && [ "$(find "$2/gc" -type f | wc -l | tr -d " ")" = 13 ]' _ "$OUT" "$R"

# ------------------------------------------------------------------ session temp
# lsof is faked: usable (-p), and a path containing "held" is held by pid 4242.
session_fixture() {
  local root="$1" sid=11111111-1111-1111-1111-111111111111 old
  rm -rf "$root"; mkdir -p "$root/bin" "$root/home/.claude/logs"
  old="$(mins_ago $((3 * 1440)))"
  cat > "$root/bin/lsof" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = -p ] && { echo "n/fake-cwd"; exit 0; }; done
case "${@: -1}" in *held*) echo 4242 ;; esac
exit 0
STUB
  chmod +x "$root/bin/lsof"; printf '#!/bin/sh\nexit 0\n' > "$root/bin/path-in-use.sh"
  local t="$root/scratch/proj/$sid/tasks"
  mkdir -p "$t" "$root/scratch/proj/push/tasks" "$root/scratch/proj/$sid/push/tasks"
  mib "$t/old.output" 2;        touch -t "$old" "$t/old.output"
  mib "$t/held.output" 2;       touch -t "$old" "$t/held.output"
  mib "$t/fresh.output" 2
  mib "$t/small.output" 1;      touch -t "$old" "$t/small.output"
  mib "$root/scratch/proj/push/tasks/old.output" 2;        touch -t "$old" "$root/scratch/proj/push/tasks/old.output"
  mib "$root/scratch/proj/$sid/push/tasks/old.output" 2;   touch -t "$old" "$root/scratch/proj/$sid/push/tasks/old.output"
  # jobs: <name> <state> <age: old|new> <tmp: plain|held>
  mkjob() {
    local d="$root/jobs/$1"; mkdir -p "$d/tmp"
    [ "$2" = none ] || printf '{"state":"%s"}' "$2" > "$d/state.json"
    echo '{}' > "$d/timeline.jsonl"; mib "$d/tmp/big.bin" 2
    [ "$3" = old ] && touch -t "$old" "$d/state.json" "$d/timeline.jsonl"
    return 0
  }
  mkjob donejob done old; mkjob stoppedjob stopped old; mkjob failedjob failed old
  mkjob newjob done new; mkjob blockedjob blocked old; mkjob runningjob running old
  mkjob heldjob done old; mv "$root/jobs/heldjob" "$root/jobs/job-held"
  mkjob nostate none old
}
session_run() {
  local root="$1"; shift
  env HOME="$root/home" PATH="$root/bin:$PATH" BYPRODUCT_SCRATCH_ROOT="$root/scratch" \
    BYPRODUCT_JOBS_DIR="$root/jobs" BYPRODUCT_LSOF_BIN="$root/bin/lsof" BYPRODUCT_TASK_OUTPUT_MB=1 \
    BYPRODUCT_GO_CACHE_DIR="$root/none" BYPRODUCT_DOCKER_BIN="$root/bin/none" BYPRODUCT_ARCHIVE_ROOT="$root/none" \
    BYPRODUCT_UV_BIN="$root/bin/none" BYPRODUCT_DEAD_CACHE_PATHS= BYPRODUCT_FREE_GB=9999 \
    BYPRODUCT_STAMP="$root/stamp" BYPRODUCT_LOG="$root/log" BYPRODUCT_DATA_VOLUME="$root" \
    PATH_IN_USE_BIN="$root/bin/path-in-use.sh" bash "$SCRIPT" "$@" 2>&1
}
S="$WORK/sess"; session_fixture "$S"
T="$S/scratch/proj/11111111-1111-1111-1111-111111111111/tasks"
OUT="$(session_run "$S" --dry-run)"
expect "dry run removes nothing" test -f "$T/old.output" -a -s "$S/jobs/donejob/tmp/big.bin"
expect "dry run names the old unheld output" grep -q 'task output WOULD be removed: .*tasks/old.output' <<<"$OUT"
OUT="$(session_run "$S")"
expect "an old, large, unheld task output is removed" test ! -e "$T/old.output"
expect "one held by a process is kept" test -f "$T/held.output"
expect "one written recently is kept" test -f "$T/fresh.output"
expect "one under the size line is kept" test -f "$T/small.output"
expect "a directory named push is never entered (depth 4 and deeper)" \
  test -f "$S/scratch/proj/push/tasks/old.output" -a -f "$S/scratch/proj/11111111-1111-1111-1111-111111111111/push/tasks/old.output"
for j in donejob stoppedjob failedjob; do
  expect "a finished job ($j) loses its tmp contents, keeps tmp/, state and timeline" \
    bash -c '[ -d "$1/tmp" ] && [ -z "$(ls -A "$1/tmp")" ] && [ -f "$1/state.json" ] && [ -f "$1/timeline.jsonl" ]' _ "$S/jobs/$j"
done
for j in newjob blockedjob runningjob job-held nostate; do
  expect "job $j keeps its tmp" test -f "$S/jobs/$j/tmp/big.bin"
done
expect "the ledger counts them" grep -q 'session temp: 4 reaped, 2 kept' <<<"$OUT"

# lsof missing or blind: fail closed
S2="$WORK/sess2"; session_fixture "$S2"; printf '#!/usr/bin/env bash\nexit 0\n' > "$S2/bin/lsof"
session_run "$S2" >/dev/null
expect "an lsof that cannot see this process keeps everything" \
  test -f "$S2/scratch/proj/11111111-1111-1111-1111-111111111111/tasks/old.output" -a -f "$S2/jobs/donejob/tmp/big.bin"

echo; echo "passed: $PASSED, failed: $FAILURES"
[ "$FAILURES" -eq 0 ]
