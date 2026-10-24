#!/usr/bin/env bash
# reclaim-byproducts: what a slow or stopped sweep may no longer do to the disk guard (stima-api #5886).
# On 2026-10-24 the scratchpad liveness phase took ~2 minutes a directory, the go cache steps
# behind it never ran, and a stopped holder of the lock made every other run exit 0 silently.
#
#   R1  the go cache (age trim and cap) runs before the scratchpad liveness phase
#   R2  the scratchpad phase has a time budget and a cursor; what it does not reach is kept
#   R3  a stopped or over-age lock holder is an ERROR and an alert, never taken over;
#       --go-cache / --go-cache-cap have their own lock, so a sweep cannot block them
#
# BYPRODUCT_SCRIPT runs the cases against a copy (how the mutants are shown to fail).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${BYPRODUCT_SCRIPT:-$REPO_ROOT/shell/reclaim-byproducts.sh}"
FAILURES=0; PASSED=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok: $1"; PASSED=$((PASSED + 1)); }
check() {  # <label> <output> <present pattern> [absent pattern]
  local label="$1" out="$2" want="$3" unwant="${4:-}"
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -q -- "$want"; then fail "$label: expected /$want/"; return; fi
  if [ -n "$unwant" ] && printf '%s' "$out" | grep -q -- "$unwant"; then fail "$label: did not expect /$unwant/"; return; fi
  pass "$label"
}
yes_() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-byproducts-wd.XXXXXX")" || exit 1
FIXTURE_PIDS="$WORK/fixture-pids"; : > "$FIXTURE_PIDS"
# Only pids this suite started are signalled, continued first so a stopped one can die.
cleanup() {
  local p
  for p in $(cat "$FIXTURE_PIDS" 2>/dev/null); do kill -CONT "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
OLD_TS="$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '40 days ago' +%Y%m%d%H%M)"
S1=11111111-1111-1111-1111-111111111111
S2=22222222-2222-2222-2222-222222222222
S3=33333333-3333-3333-3333-333333333333
S4=44444444-4444-4444-4444-444444444444

fx() {
  local root="$1" s
  rm -rf "$root"; mkdir -p "$root/bin" "$root/scratch/proj" "$root/archive" "$root/home/.claude/logs"
  for s in $S1 $S2 $S3; do mkdir -p "$root/scratch/proj/$s"; touch "$root/scratch/proj/$s/f"; touch -t "$OLD_TS" "$root/scratch/proj/$s/f" "$root/scratch/proj/$s"; done
  mkdir -p "$root/scratch/proj/$S4"; touch "$root/scratch/proj/$S4/just-written"
  # The liveness gate: every directory is free, after RB_TEST_GATE_SLEEP seconds. Each call is recorded.
  cat > "$root/bin/path-in-use.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$root/gate-calls"
sleep "\${RB_TEST_GATE_SLEEP:-0}"
echo "free      \$1"; exit 0
STUB
  printf '#!/usr/bin/env bash\nprintf "p1\\nn/\\n"\nexit 0\n' > "$root/bin/lsof"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/tmux"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/docker"
  printf '#!/usr/bin/env bash\necho "uv $*" >> "%s/uv-calls"\nexit 0\n' "$root" > "$root/bin/uv"
  printf '#!/usr/bin/env bash\necho "go $*" >> "%s/go-calls"\nexit 0\n' "$root" > "$root/bin/go"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/osascript-calls"\nexit 0\n' "$root" > "$root/bin/osascript"
  chmod +x "$root/bin/"*
  mkdir -p "$root/gocache/aa" "$root/gocache/bb"
  # 64 KiB each: the cap measures the cache with du, and empty files would leave it at 0.
  for s in aa/old-one-d bb/old-two-d aa/fresh-d; do head -c 65536 /dev/zero > "$root/gocache/$s"; done
  touch -t "$OLD_TS" "$root/gocache/aa/old-one-d" "$root/gocache/bb/old-two-d"
}

_run() {
  local root="$1" script="$2"; shift 2
  HOME="$root/home" \
  PATH="$root/bin:$PATH" \
  BYPRODUCT_LAUNCHCTL="$root/bin/launchctl" \
  BYPRODUCT_SCRATCH_ROOT="$root/scratch" \
  BYPRODUCT_ARCHIVE_ROOT="$root/archive" \
  BYPRODUCT_DOCKER_BIN="$root/bin/docker" \
  BYPRODUCT_GO_CACHE_DIR="$root/gocache" \
  BYPRODUCT_GO_CACHE_TRIM_DAYS=3 \
  BYPRODUCT_GO_CACHE_MAX_GB=99999 \
  BYPRODUCT_GO_BUSY=0 \
  BYPRODUCT_FREE_GB=9999 \
  PATH_IN_USE_BIN="$root/bin/path-in-use.sh" \
  BYPRODUCT_LSOF_BIN="$root/bin/lsof" \
  BYPRODUCT_TMUX_BIN="$root/bin/tmux" \
  BYPRODUCT_SESSIONS_DIR="$root/home/.claude/sessions" \
  BYPRODUCT_PROJECTS_DIR="$root/home/.claude/projects" \
  BYPRODUCT_CODEX_SESSIONS_DIR="$root/home/.codex/sessions" \
  BYPRODUCT_JOBS_DIR="$root/home/.claude/jobs" \
  BYPRODUCT_CLOSED_SESSIONS="$root/closed-sessions.md" \
  BYPRODUCT_SPOTCHECK_LOG="$root/spotcheck.log" \
  BYPRODUCT_IDLE_HOURS=24 \
  BYPRODUCT_STAMP="$root/stamp" \
  BYPRODUCT_LOG="$root/home/.claude/logs/reclaim-byproducts.log" \
  BYPRODUCT_DATA_VOLUME="$root" \
  BYPRODUCT_UV_BIN="$root/bin/uv" \
  BYPRODUCT_PIP_BIN="$root/bin/pip" \
  BYPRODUCT_DEAD_CACHE_PATHS="" \
  BYPRODUCT_OSASCRIPT_BIN="$root/bin/osascript" \
    bash "$script" "$@" 2>&1
}
there() { [ -d "$1/scratch/proj/$2" ]; }
gone()  { [ ! -e "$1/scratch/proj/$2" ]; }
STATE() { echo "$1/home/.cc-reaper/state"; }
CURSOR() { echo "$(STATE "$1")/reclaim-byproducts.scratch-cursor"; }

# ---------------------------------------------------------------- R1: go cache first
F="$WORK/r1"; fx "$F"
OUT="$(_run "$F" "$SCRIPT")"
go_line=$(printf '%s\n' "$OUT" | grep -n '^go cache: trimmed' | head -1 | cut -d: -f1)
sp_line=$(printf '%s\n' "$OUT" | grep -n '^-- scratchpads' | head -1 | cut -d: -f1)
yes_ "R1a: the go cache trim is logged before the scratchpad phase starts (line ${go_line:-none} < ${sp_line:-none})" \
  test -n "$go_line" -a -n "$sp_line" -a "${go_line:-0}" -lt "${sp_line:-0}"
# While the liveness phase is still busy, the go cache has already been freed.
F="$WORK/r1b"; fx "$F"
( RB_TEST_GATE_SLEEP=3 _run "$F" "$SCRIPT" > "$F/out" ) &
r1b=$!
i=0; while [ ! -s "$F/gate-calls" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
yes_ "R1b: the liveness phase is running" test -s "$F/gate-calls"
yes_ "R1b: and the old go cache entries are already gone" test ! -e "$F/gocache/aa/old-one-d" -a ! -e "$F/gocache/bb/old-two-d"
yes_ "R1b: a fresh entry is not" test -e "$F/gocache/aa/fresh-d"
wait "$r1b"

# ---------------------------------------------------------------- R2: scratchpad time budget + cursor
F="$WORK/r2"; fx "$F"
OUT="$(RB_TEST_GATE_SLEEP=2 CC_RB_SCRATCH_BUDGET_SECONDS=1 _run "$F" "$SCRIPT")"
check "R2a: past the budget the phase stops and says so" "$OUT" "scratchpads: time budget 1s reached"
yes_ "R2a: the directory it reached is reaped" gone "$F" $S1
yes_ "R2a: the ones it did not reach are kept, not deleted ($S2)" there "$F" $S2
yes_ "R2a: ($S3)" there "$F" $S3
yes_ "R2a: the gate was asked once" test "$(wc -l < "$F/gate-calls" | tr -d ' ')" -eq 1
yes_ "R2a: the cursor names where it stopped" test "$(cat "$(CURSOR "$F")" 2>/dev/null)" = "proj/$S1"
OUT="$(RB_TEST_GATE_SLEEP=2 CC_RB_SCRATCH_BUDGET_SECONDS=1 _run "$F" "$SCRIPT" --dry-run)"
yes_ "R2b: a dry run does not move the cursor" test "$(cat "$(CURSOR "$F")" 2>/dev/null)" = "proj/$S1"
yes_ "R2b: nor deletes" there "$F" $S2
OUT="$(RB_TEST_GATE_SLEEP=2 CC_RB_SCRATCH_BUDGET_SECONDS=1 _run "$F" "$SCRIPT")"
yes_ "R2c: the next run continues after the cursor" gone "$F" $S2
yes_ "R2c: and stops again, keeping the rest" there "$F" $S3
yes_ "R2c: cursor moved" test "$(cat "$(CURSOR "$F")" 2>/dev/null)" = "proj/$S2"
OUT="$(RB_TEST_GATE_SLEEP=2 CC_RB_SCRATCH_BUDGET_SECONDS=1 _run "$F" "$SCRIPT")"
yes_ "R2d: the third run reaches the last one" gone "$F" $S3
OUT="$(RB_TEST_GATE_SLEEP=2 CC_RB_SCRATCH_BUDGET_SECONDS=1 _run "$F" "$SCRIPT")"
check "R2e: a pass that reaches the end says it finished" "$OUT" "" "time budget"
yes_ "R2e: and clears the cursor" test ! -e "$(CURSOR "$F")"
yes_ "R2e: the recent scratchpad was judged and kept all along" there "$F" $S4
F="$WORK/r2f"; fx "$F"
OUT="$(RB_TEST_GATE_SLEEP=1 CC_RB_SCRATCH_BUDGET_SECONDS=0 _run "$F" "$SCRIPT")"
yes_ "R2f: CC_RB_SCRATCH_BUDGET_SECONDS=0 is no budget" sh -c "! test -e '$F/scratch/proj/$S1' && ! test -e '$F/scratch/proj/$S3'"

# ---------------------------------------------------------------- R3: the lock
LK="$WORK/lk"; LKDIR="$(STATE "$LK")/reclaim-byproducts.lock"; GOLK="$(STATE "$LK")/reclaim-byproducts-go.lock"
# Sets HP. Not in a command substitution: a sleep holding its stdout would block it for 300s.
holder() { sleep 300 > /dev/null 2>&1 < /dev/null & HP=$!; echo "$HP" >> "$FIXTURE_PIDS"; }
# A STOP sent before the child has exec'd sleep is lost, so wait for the exec, stop, confirm `T`.
stop_pid() {
  local i=0
  while [ "$(ps -o comm= -p "$1" 2>/dev/null)" != sleep ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -STOP "$1"; i=0
  while ! ps -o stat= -p "$1" 2>/dev/null | grep -q T && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

fx "$LK"; holder; H=$HP; stop_pid "$H"
mkdir -p "$LKDIR"; echo "$H" > "$LKDIR/pid"; date +%s > "$LKDIR/started"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3a: a stopped holder is an ERROR naming it" "$OUT" "ERROR.*pid $H.*stopped"
check "R3a: with ALERT:byproducts-lock-held" "$OUT" "ALERT:byproducts-lock-held"
check "R3a: and a non-zero exit, not a silent 0" "$OUT" "rc=1" "sweep started"
yes_ "R3a: it notifies" grep -q 'byproducts' "$LK/osascript-calls" 2>/dev/null
yes_ "R3a: nothing was swept" there "$LK" $S1
yes_ "R3a: the lock is not taken over" test "$(cat "$LKDIR/pid")" = "$H"
yes_ "R3a: the holder is not signalled (still stopped)" sh -c "ps -o stat= -p $H | grep -q T"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
yes_ "R3a: a second refusal inside the cooldown notifies no more" test "$(cat "$LK/osascript-calls" 2>/dev/null | wc -l | tr -d ' ')" -eq 1
check "R3a: but still logs the ERROR" "$OUT" "ALERT:byproducts-lock-held"
kill -CONT "$H"; kill "$H" 2>/dev/null; wait "$H" 2>/dev/null

fx "$LK"; holder; H=$HP
mkdir -p "$LKDIR"; echo "$H" > "$LKDIR/pid"; echo "$(( $(date +%s) - 20000 ))" > "$LKDIR/started"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3b: a holder older than the max age is an ERROR" "$OUT" "ERROR.*pid $H for 2000[0-9]s"
check "R3b: with ALERT:byproducts-lock-old" "$OUT" "ALERT:byproducts-lock-old"
check "R3b: non-zero" "$OUT" "rc=1" "sweep started"
yes_ "R3b: not taken over" test "$(cat "$LKDIR/pid")" = "$H"
yes_ "R3b: and not signalled" kill -0 "$H"
# A lock written before `started` existed: its pid file's mtime is the age.
rm -f "$LKDIR/started"; touch -t "$OLD_TS" "$LKDIR/pid"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3b: a lock with no started file is aged by its pid file" "$OUT" "ALERT:byproducts-lock-old"
OUT="$(CC_RB_LOCK_MAX_AGE_SECONDS=0 _run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3b: CC_RB_LOCK_MAX_AGE_SECONDS=0 turns the age alert off" "$OUT" "another sweep, pid $H, is running; this one exits" "ERROR"
kill "$H" 2>/dev/null; wait "$H" 2>/dev/null

fx "$LK"; holder; H=$HP
mkdir -p "$LKDIR"; echo "$H" > "$LKDIR/pid"; date +%s > "$LKDIR/started"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3c: a young live holder is unchanged: exit 0, says so" "$OUT" "another sweep, pid $H, is running; this one exits" "ERROR"
check "R3c: rc 0" "$OUT" "rc=0"
OUT="$(_run "$LK" "$SCRIPT" --go-cache; echo "rc=$?")"
check "R3d: a sweep holding its lock does not block --go-cache" "$OUT" "go cache only" "another sweep"
fx "$LK"; mkdir -p "$LKDIR"; echo "$H" > "$LKDIR/pid"; date +%s > "$LKDIR/started"
OUT="$(CC_GO_CACHE_MAX_GB=0 CC_GO_CACHE_TARGET_GB=0 _run "$LK" "$SCRIPT" --go-cache-cap; echo "rc=$?")"
check "R3d: nor --go-cache-cap" "$OUT" "go cache cap:" "another sweep"
yes_ "R3d: which deleted the old entries" test ! -e "$LK/gocache/aa/old-one-d"
yes_ "R3d: the sweep's lock is untouched" test "$(cat "$LKDIR/pid")" = "$H"
kill "$H" 2>/dev/null; wait "$H" 2>/dev/null

fx "$LK"; holder; G=$HP
mkdir -p "$GOLK"; echo "$G" > "$GOLK/pid"; date +%s > "$GOLK/started"
OUT="$(CC_GO_CACHE_MAX_GB=0 CC_GO_CACHE_TARGET_GB=0 _run "$LK" "$SCRIPT" --go-cache-cap; echo "rc=$?")"
check "R3e: a live go-cache holder blocks a second cap" "$OUT" "another go cache run, pid $G, is running; this one exits" "go cache cap:"
yes_ "R3e: which removed nothing" test -e "$LK/gocache/aa/old-one-d"
stop_pid "$G"
OUT="$(CC_GO_CACHE_MAX_GB=0 CC_GO_CACHE_TARGET_GB=0 _run "$LK" "$SCRIPT" --go-cache-cap; echo "rc=$?")"
check "R3e: a stopped go-cache holder is an ERROR and an alert" "$OUT" "ALERT:byproducts-lock-held" "go cache cap:"
yes_ "R3e: and its lock is kept" test "$(cat "$GOLK/pid")" = "$G"
OUT="$(_run "$LK" "$SCRIPT"; echo "rc=$?")"
check "R3e: the full sweep does not take the go-cache lock" "$OUT" "sweep ended" "ALERT:byproducts-lock"
kill -CONT "$G"; kill "$G" 2>/dev/null; wait "$G" 2>/dev/null

# ---------------------------------------------------------------- R4: a newline in a name never leaves the root
# A name with a newline, split into lines, gave a relative path that resolved against the cwd. Each
# decoy below is an idle directory with a session id, in the cwd, exactly where such a fragment points.
F="$WORK/r4"; fx "$F"
mkdir -p "$F/cwd/$S1" "$F/cwd/$S2/$S3"
touch -t "$OLD_TS" "$F/cwd/$S1" "$F/cwd/$S2/$S3" "$F/cwd/$S2"
NL2="$F/scratch/proj/a
$S1"                                   # newline at the second level -> "<uuid>"
NL1="$F/scratch/b
$S2"                                   # newline at the first level  -> "<uuid>/<uuid>"
mkdir -p "$NL2" "$NL1/$S3"
touch -t "$OLD_TS" "$NL2" "$NL1/$S3" "$NL1"
OUT="$(cd "$F/cwd" && _run "$F" "$SCRIPT")"
yes_ "R4a: a session-id directory in the cwd is never removed ($S1)" test -d "$F/cwd/$S1"
yes_ "R4a: nor one two levels down ($S2/$S3)" test -d "$F/cwd/$S2/$S3"
yes_ "R4a: the gate is never asked about a path outside the root" \
  sh -c "! grep -v '^$F/scratch/' '$F/gate-calls'"
check "R4b: a name with a newline is skipped and logged" "$OUT" "scratchpad skipped: .*newline"
yes_ "R4b: and kept" test -d "$NL2"
yes_ "R4c: the ordinary scratchpads beside it are still reaped" gone "$F" $S1

# ---------------------------------------------------------------- R5: one alert cooldown per lock
fx "$LK"; holder; H=$HP; stop_pid "$H"; holder; G=$HP; stop_pid "$G"
mkdir -p "$LKDIR" "$GOLK"; echo "$H" > "$LKDIR/pid"; echo "$G" > "$GOLK/pid"; date +%s > "$LKDIR/started"; date +%s > "$GOLK/started"
rm -f "$(STATE "$LK")"/cooldown-* 2>/dev/null
OUT="$(_run "$LK" "$SCRIPT")"
OUT="$(_run "$LK" "$SCRIPT" --go-cache-cap)"
yes_ "R5: a stopped sweep holder and a stopped go-cache holder each notify once" \
  test "$(cat "$LK/osascript-calls" 2>/dev/null | wc -l | tr -d ' ')" -eq 2
OUT="$(_run "$LK" "$SCRIPT" --go-cache-cap)"
yes_ "R5: and each keeps its own cooldown" test "$(cat "$LK/osascript-calls" 2>/dev/null | wc -l | tr -d ' ')" -eq 2
kill -CONT "$H" "$G"; kill "$H" "$G" 2>/dev/null; wait "$H" "$G" 2>/dev/null

echo
echo "passed: $PASSED, failed: $FAILURES"
[ "$FAILURES" -eq 0 ]
