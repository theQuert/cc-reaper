#!/usr/bin/env bash
# worktree-janitor / worktree-session-end: InstaBox runner VMs are reaped (stima-api#8631).
#   A  the SessionEnd hook, given a payload with session_id, ends in `reap --session <id>`
#   B  a scheduled run calls `reap --expired` once; a session sweep without an id calls nothing
#   C  a missing runner or a missing `instabox` is skipped with one line and no call
#   D  a reap that exits 1 is logged with its code and changes neither exit status; a reap that
#      outlives CC_WJ_INSTABOX_REAP_TIMEOUT_SECONDS is ended (124) and the sweep goes on
#   E  an id outside [A-Za-z0-9._-] is never passed on
# The runner is a recording stub and `instabox` a no-op: the real CLI and runner never run.
# TAP-style; set WJ_SCRIPT to test another copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
HOOK="$ROOT_DIR/hooks/worktree-session-end.sh"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then nok "$name"; else ok "$name"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { rm -rf "${T:?}"; }
trap cleanup EXIT
export HOME="$T/home"; mkdir -p "$HOME/.cc-reaper"
export GIT_CONFIG_NOSYSTEM=1
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
echo init > "$PRIMARY/README.md"
G -C "$PRIMARY" add README.md
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

STUBS="$T/stubs"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nprintf "p1\\nn/dev/null\\n"\n' > "$STUBS/lsof"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/instabox"
chmod +x "$STUBS"/*

RUNNER="$T/stima-api/scripts/ci/instabox_task_runner.py"; mkdir -p "$(dirname "$RUNNER")"
CALLS="$T/calls"; export CALLS
cat > "$RUNNER" <<'PY'
import os, sys, time
with open(os.environ["CALLS"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
time.sleep(float(os.environ.get("FAKE_REAP_SLEEP", "0")))
sys.exit(int(os.environ.get("FAKE_REAP_RC", "0")))
PY
export CC_WJ_STIMA_API_DIR="$T/stima-api"

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$T/spot.log"
export CC_WJ_SESSION_LOG="$T/session.log"
unset CC_WJ_DETACHED CC_WJ_INSTABOX_RUNNER

# A detached session sweep, as the launcher re-executes it.
session_sweep() { # <session id> <output file>
  PATH="$STUBS:$PATH" CC_WJ_DETACHED=1 CC_WJ_SESSION_DIR="$PRIMARY" CC_WJ_SESSION_APPLY=1 CC_WJ_HARNESS=claude \
    CC_WJ_SESSION_ID="$1" bash "$WJ" --session > "$2" 2>&1 </dev/null
}
scheduled() { # <output file>
  PATH="$STUBS:$PATH" bash "$WJ" --scheduled --repo "$PRIMARY" > "$1" 2>&1 </dev/null
}
calls_count() { grep -c . "$CALLS" 2>/dev/null || true; }

# ─── A: the hook end to end ───────────────────────────────────────────────────
cp "$WJ" "$HOME/.cc-reaper/worktree-janitor.sh"; chmod +x "$HOME/.cc-reaper/worktree-janitor.sh"
: > "$CALLS"; : > "$CC_WJ_SESSION_LOG"
PATH="$STUBS:$PATH" CC_WJ_SESSION_APPLY= bash "$HOOK" claude \
  <<< "{\"session_id\":\"abc-123_X.9\",\"cwd\":\"$PRIMARY\",\"hook_event_name\":\"SessionEnd\"}"
hook_rc=$?
i=0; while [ "$i" -lt 100 ] && ! grep -q 'session sweep ended' "$CC_WJ_SESSION_LOG" 2>/dev/null; do i=$((i + 1)); sleep 0.2; done
check "A hook: exits 0" test "$hook_rc" -eq 0
check "A hook: the runner got exactly 'reap --session abc-123_X.9'" test "$(cat "$CALLS")" = "reap --session abc-123_X.9"
check "A hook: the log says exit=0" grep -qF 'instabox reap --session exit=0' "$CC_WJ_SESSION_LOG"

# ─── B: session sweep and scheduled run ───────────────────────────────────────
: > "$CALLS"
session_sweep "sess-1" "$T/s1.txt"; src=$?
check "B session: 'reap --session sess-1' once" test "$(cat "$CALLS")" = "reap --session sess-1"
check "B session: status 0" test "$src" -eq 0
: > "$CALLS"
session_sweep "" "$T/s0.txt"
check "B session without an id: no reap call" test ! -s "$CALLS"
: > "$CALLS"
scheduled "$T/sched.txt"; rc=$?
check "B scheduled: 'reap --expired' exactly once" test "$(cat "$CALLS")" = "reap --expired"
check "B scheduled: the log says exit=0" grep -qF 'instabox reap --expired exit=0' "$T/sched.txt"
check "B scheduled: status 0" test "$rc" -eq 0

# ─── C: missing runner / instabox ─────────────────────────────────────────────
: > "$CALLS"
CC_WJ_STIMA_API_DIR="$T/nowhere" scheduled "$T/nr.txt"; rc=$?
check "C no runner: one skip line" test "$(grep -c 'instabox reap --expired skipped' "$T/nr.txt")" -eq 1
check "C no runner: no call, status unchanged" test ! -s "$CALLS" -a "$rc" -eq 0
CC_WJ_STIMA_API_DIR="$T/nowhere" session_sweep "sess-2" "$T/nr2.txt"; rc=$?
check "C no runner, session: skip line, status 0" test "$(grep -c 'instabox reap --session skipped' "$T/nr2.txt")" -eq 1 -a "$rc" -eq 0
# A PATH with only system dirs and no instabox stub (CC_WJ_TOOL_DIRS empty keeps the janitor from adding more).
NOI="$T/noinstabox"; mkdir -p "$NOI"; for t in gh pgrep osascript lsof; do cp "$STUBS/$t" "$NOI/$t"; done
NOI_PATH="$NOI:/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$NOI_PATH" command -v instabox >/dev/null 2>&1; then
  nok "C no instabox: a real instabox is on the system PATH, case cannot be exercised"
else
  PATH="$NOI_PATH" CC_WJ_TOOL_DIRS= bash "$WJ" --scheduled --repo "$PRIMARY" > "$T/ni.txt" 2>&1 </dev/null; rc=$?
  check "C no instabox: one skip line" test "$(grep -c 'instabox reap --expired skipped' "$T/ni.txt")" -eq 1
  check "C no instabox: no call, status 0" test ! -s "$CALLS" -a "$rc" -eq 0
fi

# ─── D: failing and slow reaps ────────────────────────────────────────────────
: > "$CALLS"
FAKE_REAP_RC=1 scheduled "$T/fail.txt"; rc=$?
check "D failing scheduled: logged exit=1" grep -qF 'instabox reap --expired exit=1' "$T/fail.txt"
check "D failing scheduled: status still 0" test "$rc" -eq 0
FAKE_REAP_RC=1 session_sweep "sess-3" "$T/fail2.txt"; rc=$?
check "D failing session: logged exit=1" grep -qF 'instabox reap --session exit=1' "$T/fail2.txt"
check "D failing session: the sweep still ran to its end line" grep -q 'session sweep ended .* status=0$' "$T/fail2.txt"
check "D failing session: status 0" test "$rc" -eq 0
t0=$(date +%s)
FAKE_REAP_SLEEP=30 CC_WJ_INSTABOX_REAP_TIMEOUT_SECONDS=1 session_sweep "sess-4" "$T/slow.txt"; rc=$?
elapsed=$(( $(date +%s) - t0 ))
check "D slow: ended by the bound (exit=124)" grep -qF 'instabox reap --session exit=124' "$T/slow.txt"
check "D slow: the sweep did not wait for it (took ${elapsed}s)" test "$elapsed" -lt 20 -a "$rc" -eq 0

# ─── E: the id is checked at the launcher ─────────────────────────────────────
: > "$CALLS"; : > "$CC_WJ_SESSION_LOG"
PATH="$STUBS:$PATH" CC_WJ_SESSION_APPLY= bash "$HOOK" claude \
  <<< "{\"session_id\":\"a b;touch $T/pwned\",\"cwd\":\"$PRIMARY\"}"
i=0; while [ "$i" -lt 100 ] && ! grep -q 'session sweep ended' "$CC_WJ_SESSION_LOG" 2>/dev/null; do i=$((i + 1)); sleep 0.2; done
check "E odd id: no reap call" test ! -s "$CALLS"
check "E odd id: nothing was executed" test ! -e "$T/pwned"

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
