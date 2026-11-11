#!/usr/bin/env bash
# worktree-janitor (stima-api#7904):
#   A  a `--session` sweep probes the repository lock before any scan. With a live holder it logs
#      the defer line and ends at once, having run no process, transcript or session scan; with the
#      lock free it scans as before.
#   B  a Claude session record that cannot be parsed is read once more after a second, at most five
#      times per sweep; one that stays broken is still an unknown record.
# Real git repositories; lsof and jq are counting stubs. TAP-style; set WJ_SCRIPT to test another
# copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then nok "$name"; else ok "$name"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
pids=""
cleanup() {
  local p
  for p in $pids; do kill "$p" 2>/dev/null; done
  rm -rf "${T:?}"
}
trap cleanup EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
echo init > "$PRIMARY/README.md"
G -C "$PRIMARY" add README.md
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main
G -C "$PRIMARY" worktree add -q -b A "$T/wt-A" main

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CALLS="$T/lsof-calls"; JQ_CALLS="$T/jq-calls"
export LSOF_CALLS JQ_CALLS
: > "$LSOF_CALLS"; : > "$JQ_CALLS"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
echo x >> "$LSOF_CALLS"
case " $* " in
  *" -d cwd "*) ;;
  *) printf 'p1\nn/dev/null\n' ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
REAL_JQ="$(command -v jq)"; export REAL_JQ
# jq fails (a record being rewritten) for the first BREAK_FIRST reads of BREAK_FILES, one per
# line, every read when BREAK_FIRST is `all`; each read of a record is counted.
cat > "$STUBS/jq" <<'STUB'
#!/usr/bin/env bash
last=""; for a in "$@"; do last="$a"; done
if [ -n "${BREAK_FILES:-}" ] && printf '%s\n' "$BREAK_FILES" | grep -qxF "$last"; then
  echo x >> "$JQ_CALLS"
  n="$(grep -c . "$JQ_CALLS")"
  if [ "${BREAK_FIRST:-all}" = all ] || [ "$(grep -c "" "$last.reads" 2>/dev/null || echo 0)" -lt "$BREAK_FIRST" ]; then
    echo x >> "$last.reads"
    echo "jq: parse error: Unfinished string" >&2
    exit 5
  fi
fi
exec "$REAL_JQ" "$@"
STUB
chmod +x "$STUBS"/*

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$T/spot.log"

# ─── A: the repository lock is probed before any scan ─────────────────────────

LOCK="$PRIMARY/.git/cc-reaper-worktree-janitor.lock"
# A forked background job shows its parent's command line until it has exec'd: the lock records
# what the holder runs, so wait for `sleep` to be what ps says.
exec_settled() { local i=0; while [ "$i" -lt 200 ] && ! ps -o command= -p "$1" 2>/dev/null | grep -q '^sleep 600'; do i=$((i + 1)); sleep 0.05; done; }
sleep 600 </dev/null >/dev/null 2>&1 &
holder=$!; pids="$pids $holder"
exec_settled "$holder"
mkdir "$LOCK"
echo "$holder" > "$LOCK/pid"
ps -o command= -p "$holder" > "$LOCK/cmd"

session_sweep() { # <output file>; prints the elapsed seconds
  local t0 t1
  t0="$(date +%s)"
  PATH="$STUBS:$PATH" CC_WJ_DETACHED=1 CC_WJ_SESSION_DIR="$PRIMARY" CC_WJ_SESSION_APPLY=1 CC_WJ_HARNESS=claude \
    bash "$WJ" --session > "$1" 2>&1 </dev/null
  t1="$(date +%s)"
  echo $((t1 - t0))
}

: > "$LSOF_CALLS"
elapsed="$(session_sweep "$T/held.txt")"
check "A held: the defer line names the holder and the repository lock" \
  grep -qF "worktree-janitor: another worktree-janitor sweep (pid $holder) holds $LOCK; deferred to it and removed nothing in this repository" "$T/held.txt"
check "A held: the session sweep still ends with status=0" grep -q 'session sweep ended .* status=0$' "$T/held.txt"
check "A held: it ends within a couple of seconds" test "$elapsed" -le 5
check "A held: no process scan ran" test ! -s "$LSOF_CALLS"
refute "A held: no disk-pressure or scan output, nothing was examined" grep -q 'WORKTREE\|Summary:' "$T/held.txt"
check "A held: the holder's lock is untouched" test "$(cat "$LOCK/pid")" = "$holder"

# A holder that is not alive is no holder: the sweep scans and takes the lock itself.
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
: > "$LSOF_CALLS"
session_sweep "$T/dead.txt" >/dev/null
refute "A dead holder: no defer line" grep -qF 'deferred to it' "$T/dead.txt"
check "A dead holder: the process scan ran" test -s "$LSOF_CALLS"
check "A dead holder: the lock is released afterwards" test ! -e "$LOCK"

: > "$LSOF_CALLS"
session_sweep "$T/free.txt" >/dev/null
refute "A free: no defer line" grep -qF 'deferred to it' "$T/free.txt"
check "A free: the process scan ran, as before" test -s "$LSOF_CALLS"

# The lock itself is unchanged: a live holder is deferred to, one past 60 minutes is taken over, and
# the read-only probe says which, without touching the lock.
sleep 600 </dev/null >/dev/null 2>&1 &
holder2=$!; pids="$pids $holder2"
exec_settled "$holder2"
L2="$T/probe.lock"; mkdir "$L2"
echo "$holder2" > "$L2/pid"; ps -o command= -p "$holder2" > "$L2/cmd"
lockfn() { PATH="$STUBS:$PATH" bash -c 'source "$1" >/dev/null 2>&1; shift; "$@"; echo "rc=$?"' _ "$WJ" "$@"; }
check "lock: a fresh live holder is deferred to (status 2)" test "$(lockfn _cc_wj_lock "$L2" | tail -n 1)" = rc=2
check "lock: the probe reports it held (status 0)" test "$(lockfn _cc_wj_lock_live "$L2")" = rc=0
touch -t "$(date -v-2H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M.%S')" "$L2"
check "lock: the probe reports a holder past 60 minutes (status 2)" test "$(lockfn _cc_wj_lock_live "$L2")" = rc=2
out="$(lockfn _cc_wj_lock "$L2")"
check "lock: a live holder past 60 minutes is taken over, as before" \
  test "$(printf '%s\n' "$out" | grep -c "has held $L2 for over 60 minutes; taking it over")" -eq 1
check "lock: and the lock is then this run's" test "$(cat "$L2/pid")" != "$holder2"
rm -f "$L2/pid" "$L2/cmd"; rmdir "$L2"
check "lock: a free lock is not held (status 1)" test "$(lockfn _cc_wj_lock_live "$L2")" = rc=1

# ─── B: a record being rewritten is read once more ────────────────────────────

# A live process whose command line carries the session id, so a readable record binds to it, and
# a transcript for that id in the project directory of its cwd. $2 is `whole` or `torn`: a torn
# record stops before its cwd, as a half-written one does, and its raw text names no tree.
mkrec() { # <n> <whole|torn> -> sets REC_PID, REC_FILE
  local sid="0000aaaa-0000-4000-8000-00000000000$1" dir
  python3 -c 'import time; time.sleep(600)' "$sid" </dev/null >/dev/null 2>&1 &
  REC_PID=$!; pids="$pids $REC_PID"
  local i=0
  while [ "$i" -lt 200 ] && ! ps -o command= -p "$REC_PID" 2>/dev/null | grep -qF "$sid"; do i=$((i + 1)); sleep 0.05; done
  REC_FILE="$SESSIONS/$REC_PID.json"
  if [ "$2" = whole ]; then
    printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$REC_PID" "$sid" "$T/wt-A" > "$REC_FILE"
  else
    printf '{"pid":%s,"sessionId":"%s",' "$REC_PID" "$sid" > "$REC_FILE"
  fi
  dir="$PROJECTS/$(printf '%s' "$T/wt-A" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$T/wt-A" > "$dir/$sid.jsonl"
}

scan() { # prints "<elapsed> <unknown rows> <claims> <settles>"
  PATH="$STUBS:$PATH" SCAN_ERR="$T/scan.err" bash -c '
    source "$1" >/dev/null 2>&1
    _CC_WJ_ACTIVE_CLAIMS=""; _CC_WJ_ACTIVE_TRANSCRIPTS=""; _CC_WJ_ACTIVE_ERROR=""; _CC_WJ_ACTIVE_NAMES=""
    _CC_WJ_UNKNOWN=""; _CC_WJ_UNKNOWN_ERRORS=""; _CC_WJ_RECORD_SETTLES=0
    s="$(date +%s)"
    _cc_wj_scan_claude_sessions >/dev/null 2>"$SCAN_ERR"
    e="$(( $(date +%s) - s ))"
    printf "%s %s %s %s\n" "$e" "$(printf "%s" "$_CC_WJ_UNKNOWN_ERRORS" | grep -c .)" \
      "$(printf "%s" "$_CC_WJ_ACTIVE_CLAIMS" | grep -c .)" "$_CC_WJ_RECORD_SETTLES"' _ "$WJ"
}

# One in-scan read per record, so the second read is the settle read.
export CC_WJ_RECORD_READS=1

mkrec 1 whole
: > "$JQ_CALLS"
out="$(BREAK_FILES="$REC_FILE" BREAK_FIRST=1 scan)"
read -r el unk claims settles <<< "$out"
check "B torn once: the record was read a second time" test "$(grep -c . "$JQ_CALLS")" -ge 2
check "B torn once: it is no unknown record" test "$unk" -eq 0
check "B torn once: its cwd claim was made" test "$claims" -eq 1
check "B torn once: one settle was used" test "$settles" -eq 1
check "B torn once: the settle wait is about a second" test "$el" -ge 1
kill "$REC_PID" 2>/dev/null; rm -f "$REC_FILE" "$REC_FILE.reads"

mkrec 2 torn
: > "$JQ_CALLS"
out="$(BREAK_FILES="$REC_FILE" BREAK_FIRST=all scan)"
read -r el unk claims settles <<< "$out"
check "B torn for good: read twice, then given up" test "$(grep -c . "$JQ_CALLS")" -eq 2
check "B torn for good: it is an unknown record, as before" test "$unk" -eq 1
check "B torn for good: no claim was made" test "$claims" -eq 0
kill "$REC_PID" 2>/dev/null; rm -f "$REC_FILE" "$REC_FILE.reads"

# Seven broken records: five settle reads, so 7 + 5 reads and an unchanged outcome (all unknown).
files=""
for n in 3 4 5 6 7 8 9; do
  mkrec "$n" torn; files="$files$REC_FILE"$'\n'
done
: > "$JQ_CALLS"
out="$(BREAK_FILES="${files%$'\n'}" BREAK_FIRST=all scan)"
read -r el unk claims settles <<< "$out"
check "B bound: five settle reads, not seven" test "$settles" -eq 5
check "B bound: 7 first reads and 5 settle reads" test "$(grep -c . "$JQ_CALLS")" -eq 12
check "B bound: every broken record is still unknown" test "$unk" -eq 7

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
