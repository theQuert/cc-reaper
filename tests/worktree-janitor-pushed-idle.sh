#!/usr/bin/env bash
# worktree-janitor: two rules on probation that free disk without losing work.
#   pushed-idle      a worktree kept only as KEEP(unlanded), clean, whose HEAD a fetched origin ref
#                    (refs/remotes/origin/*) already contains and which has sat idle past
#                    CC_WJ_PUSHED_IDLE_HOURS (default 72); removal takes the checkout, never the branch
#   dirty-pressure   under disk pressure a dirty tree waits CC_WJ_TRIM_DIRTY_IDLE_HOURS_PRESSURE (24)
#                    instead of CC_WJ_TRIM_DIRTY_IDLE_HOURS (168) before its ignored regenerable
#                    directories are trimmed
#   CC_WJ_NEW_RULES_MODE spotcheck (default) logs what they would do and changes nothing; auto decides
# Real git repositories and a local bare "origin"; lsof and gh are stubs. The pushed trees are pushed
# and then deleted from origin, so the live listing no longer names them and only the tracking ref does.
# TAP-style; set WJ_SCRIPT to test another copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then nok "$name"; else ok "$name"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
live_pid=""
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'kill $live_pid 2>/dev/null; rm -rf "$T"' EXIT
[ -z "${WJ_KEEP_TMP:-}" ] || echo "# kept: $T"
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
printf '*.log\nnode_modules/\n' > "$PRIMARY/.gitignore"
echo init > "$PRIMARY/README.md"
G -C "$PRIMARY" add README.md .gitignore
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

# A branch with a commit of its own in worktree $T/wt-<name>. With `push` it reaches origin and is
# then deleted there: origin no longer lists it, the tracking ref refs/remotes/origin/<name> stays.
mkwt() { # <name> [push]
  G -C "$PRIMARY" worktree add -q -b "$1" "$T/wt-$1" main
  echo "$1" > "$T/wt-$1/$1.txt"
  G -C "$T/wt-$1" add "$1.txt"
  G -C "$T/wt-$1" commit -qm "work on $1"
  if [ "${2:-}" = push ]; then
    G -C "$T/wt-$1" push -q -u origin "$1" 2>/dev/null
    git --git-dir="$ORIGIN" update-ref -d "refs/heads/$1"
  fi
}
cache() { mkdir -p "$T/wt-$1/node_modules/pkg"; echo pkg > "$T/wt-$1/node_modules/pkg/index.js"; }
stamp() { date -v-"$1"H +%Y%m%d%H%M 2>/dev/null || date -d "$1 hours ago" +%Y%m%d%H%M; }
age() { # <name> <hours>: every file, the tree and the git dir's HEAD and index last touched that long ago
  local wt="$T/wt-$1" gd s
  s="$(stamp "$2")"
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)"
  find "$wt" -exec touch -h -t "$s" {} +
  touch -h -t "$s" "$gd/HEAD" "$gd/index"
}

# pushed-idle candidates
mkwt pi-clean push
mkwt pi-unpushed
mkwt pi-held push
mkwt pi-session push
mkwt pi-dirty push;   echo edited >> "$T/wt-pi-dirty/README.md"
mkwt pi-recent push
mkwt pi-log push;     echo "dev server" > "$T/wt-pi-log/next-manual.log"
# dirty-pressure candidates: a tracked edit keeps each dirty, node_modules is what a trim would take
mkwt dp-30;           echo edited >> "$T/wt-dp-30/README.md";      cache dp-30
mkwt dp-fresh;        echo edited >> "$T/wt-dp-fresh/README.md";   cache dp-fresh
mkwt dp-held;         echo edited >> "$T/wt-dp-held/README.md";    cache dp-held
for n in pi-clean pi-unpushed pi-held pi-session pi-dirty pi-log; do age "$n" 100; done
for n in dp-30 dp-held; do age "$n" 30; done

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"; export LSOF_CWD_FILE LSOF_OPEN_FILE
printf 'p1\nn/\np77\nn%s\np78\nn%s\n' "$T/wt-pi-held" "$T/wt-dp-held" > "$LSOF_CWD_FILE"
printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$STUBS"/*

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS/p"
# A live Claude session (not on any deny list) standing in wt-pi-session.
LIVE_SID="0000aaaa-0000-4000-8000-000000000098"
python3 -c 'import time; time.sleep(600)' "$LIVE_SID" </dev/null >/dev/null 2>&1 &
live_pid=$!; disown "$live_pid" 2>/dev/null || true
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"worker1"}\n' "$live_pid" "$LIVE_SID" "$T/wt-pi-session" \
  > "$SESSIONS/$live_pid.json"
printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' "$LIVE_SID" "$T/wt-pi-session" \
  > "$PROJECTS/p/$LIVE_SID.jsonl"

SPOT="$T/spotcheck.log"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive"
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$SPOT"
unset CC_WJ_NEW_RULES_MODE CC_WJ_PUSHED_IDLE_HOURS CC_WJ_TRIM_DIRTY_IDLE_HOURS CC_WJ_TRIM_DIRTY_IDLE_HOURS_PRESSURE CC_WJ_RECLAIM_PUSHED
wj() { PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }

block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
judged() { block "$1" "$2" | grep -qxF "    classification: $3"; }
spot_has() { grep -F -- "$1" "$SPOT" | grep -qF -- "$2"; }
logged() { grep -qF -- "path=$T/wt-$1 " "$SPOT"; }
tracked() { git -C "$PRIMARY" show-ref -q --verify "refs/heads/$1"; }

# ─── pushed-idle, spotcheck (default) ─────────────────────────────────────────

: > "$SPOT"
wj > "$T/report-spot.txt"
check "pushed-idle: a pushed, clean, idle tree is logged as would-remove" \
  spot_has "path=$T/wt-pi-clean " "phase=removal action=would-remove rule=pushed-idle"
check "  with a byte count, a holder note and a run id" \
  bash -c 'grep -F "path=$1 " "$2" | grep -Eq "run=[0-9TZ]+-[0-9]+ .* bytes=[0-9]+ holder=none"' _ "$T/wt-pi-clean" "$SPOT"
check "  and is still kept for removal as before" judged "$T/report-spot.txt" pi-clean "KEEP(unlanded)"
check "  and the report says the rule would make it removable" \
  bash -c 'grep -qF "spotcheck: pushed-idle would make it" <(awk -v tail="/wt-pi-clean" "/^  WORKTREE  / { on = (substr(\$0, length(\$0) - length(tail) + 1) == tail) } on" "$1")' _ "$T/report-spot.txt"
check "pushed-idle: a tree whose only extra pin is a top-level log is logged under both rules" \
  spot_has "path=$T/wt-pi-log " "rule=pushed-idle,top-level-log"
refute "pushed-idle: an unpushed commit is not logged" logged pi-unpushed
refute "pushed-idle: a tree a process stands in is not logged" logged pi-held
refute "pushed-idle: a tree a live session stands in is not logged" logged pi-session
refute "pushed-idle: a tree with a tracked edit is not logged" logged pi-dirty
refute "pushed-idle: a pushed tree touched within the window is not logged" logged pi-recent
check "spotcheck: nothing was removed by the report" \
  bash -c 'for n in pi-clean pi-unpushed pi-held pi-session pi-dirty pi-recent pi-log; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$T"

: > "$SPOT"
wj --apply > "$T/apply-spot.txt"
check "spotcheck --apply removes none of them" \
  bash -c 'for n in pi-clean pi-unpushed pi-held pi-session pi-dirty pi-recent pi-log; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$T"
check "  and still logs the would-remove" spot_has "path=$T/wt-pi-clean " "rule=pushed-idle"

# A longer window leaves the same tree alone.
: > "$SPOT"
CC_WJ_PUSHED_IDLE_HOURS=500 wj > "$T/report-long.txt"
refute "pushed-idle: CC_WJ_PUSHED_IDLE_HOURS=500 does not reach a tree idle for 100 hours" logged pi-clean
: > "$SPOT"
CC_WJ_PUSHED_IDLE_HOURS=0 wj > "$T/report-off.txt"
refute "pushed-idle: CC_WJ_PUSHED_IDLE_HOURS=0 turns the rule off" logged pi-clean
: > "$SPOT"
CC_WJ_RECLAIM_PUSHED=0 wj > "$T/report-noreclaim.txt"
refute "pushed-idle: CC_WJ_RECLAIM_PUSHED=0 turns the rule off" logged pi-clean

# ─── dirty-pressure, spotcheck ────────────────────────────────────────────────

: > "$SPOT"
wj --trim-regenerable --apply > "$T/trim-nopressure.txt"
refute "dirty-pressure: without pressure a dirty tree idle for 30 hours is not logged" logged dp-30/node_modules
check "  and its node_modules stays" test -d "$T/wt-dp-30/node_modules"

: > "$SPOT"
CC_WJ_PRESSURE_FREE_GB=99999 wj --trim-regenerable --apply > "$T/trim-spot.txt"
check "dirty-pressure: under pressure a dirty tree idle for 30 hours is logged as would-trim" \
  spot_has "path=$T/wt-dp-30/node_modules " "phase=trim action=would-trim rule=dirty-pressure"
check "  and nothing is deleted" test -d "$T/wt-dp-30/node_modules"
check "  and the tree is kept as before" judged "$T/trim-spot.txt" dp-30 "KEEP(unrebuildable=1)"
refute "dirty-pressure: a dirty tree touched within the window is not logged" logged dp-fresh/node_modules
refute "dirty-pressure: a dirty tree a process stands in is not logged" logged dp-held/node_modules
check "  and keeps its node_modules" test -d "$T/wt-dp-held/node_modules"

# ─── auto ─────────────────────────────────────────────────────────────────────

CC_WJ_NEW_RULES_MODE=auto wj --trim-regenerable --apply > "$T/trim-auto-nopressure.txt"
check "auto: without pressure the 30-hour dirty tree keeps its node_modules" test -d "$T/wt-dp-30/node_modules"
CC_WJ_NEW_RULES_MODE=auto CC_WJ_PRESSURE_FREE_GB=99999 wj --trim-regenerable --apply > "$T/trim-auto.txt"
refute "auto: under pressure the 30-hour dirty tree has its node_modules trimmed" test -e "$T/wt-dp-30/node_modules"
check "  and keeps the worktree and its edit" \
  bash -c 'grep -q edited "$1/README.md" && git -C "$1" rev-parse -q --verify HEAD' _ "$T/wt-dp-30"
check "auto: a fresh dirty tree keeps its node_modules" test -d "$T/wt-dp-fresh/node_modules"
check "auto: a held dirty tree keeps its node_modules" test -d "$T/wt-dp-held/node_modules"

CC_WJ_NEW_RULES_MODE=auto wj > "$T/report-auto.txt"
check "auto: a pushed, clean, idle tree reads REMOVABLE(pushed)" judged "$T/report-auto.txt" pi-clean "REMOVABLE(pushed)"
check "auto: an unpushed tree stays KEEP(unlanded)" judged "$T/report-auto.txt" pi-unpushed "KEEP(unlanded)"
CC_WJ_NEW_RULES_MODE=auto wj --apply > "$T/apply-auto.txt"
check "auto --apply removes the pushed idle trees" test ! -e "$T/wt-pi-clean" -a ! -e "$T/wt-pi-log"
check "  and their branches remain, with their commits" \
  bash -c 'git -C "$1" show-ref -q --verify refs/heads/pi-clean && git -C "$1" show-ref -q --verify refs/heads/pi-log && git -C "$1" cat-file -e refs/heads/pi-clean:pi-clean.txt' _ "$PRIMARY"
check "auto --apply keeps the unpushed tree" test -d "$T/wt-pi-unpushed"
check "auto --apply keeps the held tree and the one a live session stands in" test -d "$T/wt-pi-held" -a -d "$T/wt-pi-session"
check "auto --apply keeps the tree with a tracked edit and the recent one" test -d "$T/wt-pi-dirty" -a -d "$T/wt-pi-recent"

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
