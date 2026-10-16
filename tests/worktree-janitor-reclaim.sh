#!/usr/bin/env bash
# worktree-janitor: work that origin already holds is reclaimable (CC_WJ_RECLAIM_PUSHED).
#   REMOVABLE(pushed)      clean, HEAD on a branch origin lists now, every other gate holds
#   REMOVABLE(wip-pushed)  tracked edits / untracked files, snapshotted to refs/wip on origin,
#                          read back, and only then removed (--apply only; a report pushes nothing)
# Real git repositories and a local bare "origin"; lsof and gh are stubs.
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
pid_a=""; pid_b=""
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'kill $pid_a $pid_b 2>/dev/null; rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
echo init > "$PRIMARY/README.md"
G -C "$PRIMARY" add README.md
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

# A branch with one commit of its own (never landed on main) in worktree $T/wt-<name>.
mkwt() { # <name> [push]
  G -C "$PRIMARY" worktree add -q -b "$1" "$T/wt-$1" main
  echo "$1" > "$T/wt-$1/$1.txt"
  G -C "$T/wt-$1" add "$1.txt"
  G -C "$T/wt-$1" commit -qm "work on $1"
  if [ "${2:-}" = push ]; then G -C "$T/wt-$1" push -q origin "$1"; fi
}
wips() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname)' refs/wip; }
wip_of() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname)' "refs/wip/macmini/wt-$1-*"; }

# ─── Stubs and env (as tests/worktree-janitor.sh) ─────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"; export LSOF_CWD_FILE LSOF_OPEN_FILE
lsof_default() { printf 'p1\nn/\n' > "$LSOF_CWD_FILE"; printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"; }
lsof_default
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

export CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$T/claude-sessions" CC_WJ_CLAUDE_PROJECTS="$T/claude-projects"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive"
unset CC_WJ_RECLAIM_PUSHED
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents"
wj() { PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }
phys() { (cd -P "$1" 2>/dev/null && pwd); }
block() { awk -v w="wt-$2" '/^  WORKTREE/ { on = index($0, w) && substr($0, length($0) - length(w) + 1) == w } on' "$1"; }
has() { grep -q -- "$2" "$1"; }

# ─── Fixtures ─────────────────────────────────────────────────────────────────

mkwt pc push                       # clean, pushed
mkwt uc                            # clean, never pushed
mkwt sp push                       # pushed, then deleted from origin behind this clone's back
git --git-dir="$ORIGIN" update-ref -d refs/heads/sp
mkwt dp push                       # pushed; a tracked edit and an untracked file on top
echo edited >> "$T/wt-dp/dp.txt"; echo scratch > "$T/wt-dp/scratch.txt"
mkwt du                            # edits on a branch origin does not hold
echo edited >> "$T/wt-du/du.txt"
mkwt di push                       # edits plus an ignored file no command rebuilds
echo ".env" > "$T/wt-di/.gitignore"; G -C "$T/wt-di" add .gitignore; G -C "$T/wt-di" commit -qm ignore
G -C "$T/wt-di" push -q origin di
echo edited >> "$T/wt-di/di.txt"; echo SECRET=1 > "$T/wt-di/.env"
mkwt pa push                       # pushed, but a session holds it

# Two live Claude sessions. A's cwd is the primary, but its current turn names wt-pt in a tool
# call; B stands in wt-dc. Neither worktree may be judged removable, nor get a wip ref.
mkwt pt push
mkwt dc push
echo edited >> "$T/wt-dc/dc.txt"
mkdir -p "$CC_WJ_CLAUDE_SESSIONS" "$CC_WJ_CLAUDE_PROJECTS/p"
sid_a=aaaaaaaa-1111-4222-8333-444444444444; sid_b=bbbbbbbb-1111-4222-8333-444444444444
python3 -c 'import time; time.sleep(300)' "$sid_a" </dev/null >/dev/null 2>&1 & pid_a=$!
python3 -c 'import time; time.sleep(300)' "$sid_b" </dev/null >/dev/null 2>&1 & pid_b=$!
disown "$pid_a" "$pid_b"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$pid_a" "$sid_a" "$PRIMARY" > "$CC_WJ_CLAUDE_SESSIONS/$pid_a.json"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$pid_b" "$sid_b" "$T/wt-dc" > "$CC_WJ_CLAUDE_SESSIONS/$pid_b.json"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"workdir":"%s"}}]}}\n' "$T/wt-pt" > "$CC_WJ_CLAUDE_PROJECTS/p/$sid_a.jsonl"
: > "$CC_WJ_CLAUDE_PROJECTS/p/$sid_b.jsonl"

# ─── Report: classifications, and nothing pushed ──────────────────────────────

OUT="$T/report.txt"; wj > "$OUT"
printf 'p1\nn/\np9\nn%s\n' "$(phys "$T/wt-pa")" > "$LSOF_CWD_FILE"
wj > "$T/report-held.txt"; lsof_default

block "$OUT" pc > "$T/b-pc"; block "$OUT" uc > "$T/b-uc"; block "$OUT" sp > "$T/b-sp"
block "$OUT" dp > "$T/b-dp"; block "$OUT" du > "$T/b-du"; block "$OUT" di > "$T/b-di"
check "pushed and clean is REMOVABLE(pushed)" has "$T/b-pc" 'classification: REMOVABLE(pushed)'
check "never pushed and clean stays KEEP(unlanded)" has "$T/b-uc" 'classification: KEEP(unlanded)'
check "a branch origin no longer lists is not pushed, whatever the stale origin/<branch> says" \
  has "$T/b-sp" 'classification: KEEP(unlanded)'
check "tracked edits on pushed work are REMOVABLE(wip-pushed)" has "$T/b-dp" 'classification: REMOVABLE(wip-pushed)'
check "the report says it would push wip, and where" has "$T/b-dp" 'would push wip: 2 entries to refs/wip/macmini/wt-dp-'
check "edits on a branch origin does not hold stay KEEP(unlanded)" has "$T/b-du" 'classification: KEEP(unlanded)'
check "an ignored file no command rebuilds keeps the tree out of the wip path" \
  has "$T/b-di" 'classification: KEEP(unrebuildable='
check "the report still counts the edits" has "$T/b-dp" 'dirty=2'
check "a report pushes no wip ref" test -z "$(wips)"
check "the summary estimates what would be reclaimed" has "$OUT" 'estimated-reclaimable=[0-9.]* GB'
check "the summary counts removable" has "$OUT" 'removable=[1-9].*pushed=.*wip=1'
block "$T/report-held.txt" pa > "$T/b-pa"
check "a pushed worktree a session holds is KEEP(active-session)" has "$T/b-pa" 'classification: KEEP(active-session)'
block "$OUT" pt > "$T/b-pt"; block "$OUT" dc > "$T/b-dc"
check "a pushed worktree named in a live session's current tool call is kept" \
  grep -Eq 'classification: KEEP\((active|recent)-session\)' "$T/b-pt"
check "an edited worktree a live session stands in is kept, not queued for a wip push" \
  grep -Eq 'classification: KEEP\((active|recent)-session\)' "$T/b-dc"

CC_WJ_IDLE_HOURS=6 wj > "$T/report-idle.txt"
block "$T/report-idle.txt" pc > "$T/b-pr"; block "$T/report-idle.txt" dp > "$T/b-dp6"
check "inside the idle window a pushed worktree is KEEP(recent-activity)" has "$T/b-pr" 'classification: KEEP(recent-activity)'
check "inside the idle window an edited worktree is kept and nothing is pushed" \
  bash -c '[ -z "$(git --git-dir="$1" for-each-ref refs/wip)" ] && grep -q "KEEP(recent-activity)" "$2"' _ "$ORIGIN" "$T/b-dp6"

CC_WJ_RECLAIM_PUSHED=0 wj > "$T/report-off.txt"
block "$T/report-off.txt" pc > "$T/b-pc0"; block "$T/report-off.txt" dp > "$T/b-dp0"
check "CC_WJ_RECLAIM_PUSHED=0 restores KEEP(unlanded) for pushed work" has "$T/b-pc0" 'classification: KEEP(unlanded)'
check "CC_WJ_RECLAIM_PUSHED=0 restores KEEP(unrebuildable) for edits" has "$T/b-dp0" 'classification: KEEP(unrebuildable='

# ─── A push that origin refuses keeps the worktree ────────────────────────────

mkdir -p "$ORIGIN/hooks"
printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/wip/*) echo "no wip here" >&2; exit 1 ;; esac; done\n' > "$ORIGIN/hooks/pre-receive"
chmod +x "$ORIGIN/hooks/pre-receive"
printf 'p1\nn/\np9\nn%s\n' "$(phys "$T/wt-pa")" > "$LSOF_CWD_FILE"
wj --apply > "$T/apply-refused.txt"
check "a refused wip push keeps the edited worktree" test -d "$T/wt-dp"
check "and keeps its edits" has "$T/wt-dp/scratch.txt" scratch
check "and says why" has "$T/apply-refused.txt" 'kept: its edits could not be pushed'
check "the refused run left no wip ref" test -z "$(wips)"
rm -f "$ORIGIN/hooks/pre-receive"
refute "the clean pushed worktree was still removed by that run" test -d "$T/wt-pc"

# ─── Apply ────────────────────────────────────────────────────────────────────

wj --apply > "$T/apply.txt"; lsof_default
check "apply removes the edited worktree once its snapshot is on origin" test ! -d "$T/wt-dp"
WIPREF="$(wip_of dp)"
check "exactly one wip ref was made for it" test "$(printf '%s\n' "$WIPREF" | grep -c .)" = 1
WIPSHA="$(git --git-dir="$ORIGIN" rev-parse "$WIPREF")"
check "the wip ref's parent is the pushed HEAD" \
  test "$(git --git-dir="$ORIGIN" rev-parse "$WIPSHA^")" = "$(git --git-dir="$ORIGIN" rev-parse refs/heads/dp)"
check "the wip snapshot holds the untracked file" test "$(git --git-dir="$ORIGIN" show "$WIPSHA:scratch.txt")" = scratch
check "the wip snapshot holds the tracked edit" bash -c 'git --git-dir="$1" show "$2:dp.txt" | grep -q edited' _ "$ORIGIN" "$WIPSHA"
check "the apply log names the pushed ref" has "$T/apply.txt" "wip pushed: $WIPREF"
refute "a pushed clean worktree was removed" test -d "$T/wt-pc"
check "its branch survives" G -C "$PRIMARY" rev-parse --verify -q pc
check "the edited worktree's branch survives" G -C "$PRIMARY" rev-parse --verify -q dp
check "unpushed work is kept" test -d "$T/wt-uc"
check "an edit on a branch origin lacks is kept" test -d "$T/wt-du"
check "an ignored secret keeps its worktree" test -f "$T/wt-di/.env"
check "a held worktree is kept" test -d "$T/wt-pa"
check "the claimed worktrees are still there" test -d "$T/wt-pt" -a -d "$T/wt-dc"
check "no wip ref was made for any kept worktree" test "$(wips | grep -c .)" = 1

echo
if [ "$failures" -eq 0 ]; then echo "worktree-janitor-reclaim: all passed"; else echo "worktree-janitor-reclaim: $failures failed"; fi
[ "$failures" -eq 0 ]
