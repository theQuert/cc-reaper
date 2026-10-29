#!/usr/bin/env bash
# worktree-janitor: what one removal sweep costs per tree.
#   machine-wide rescans   the removal path reads the session registries, the holder list and the
#                          launchd plists again before a removal; within CC_WJ_RECHECK_FRESH_SECONDS
#                          the snapshot is reused, and only the per-tree questions are asked afresh
#                          (the claim checks, and an lsof on the tree's own path)
#   one status per tree    the dirty-tree classification reads `git status --ignored` once, not twice
#   ignored logs           a gitignored file named *.log is regenerable output, like a
#                          .worktree-regenerable entry; untracked work and other ignored entries keep
# Real git repositories and a local bare "origin"; lsof, gh, find and git are stubs that log.
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
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'rm -rf "$T"' EXIT
[ -z "${WJ_KEEP_TMP:-}" ] || echo "# kept: $T"
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
# Named ignores, not `*.log`: one fixture needs an untracked *.log that git does not ignore.
printf 'build.log\n.local-stack-up.log\n.npm-ci.log\nbudget.log\ndist/\n' > "$PRIMARY/.gitignore"
echo init > "$PRIMARY/README.md"
mkdir -p "$PRIMARY/app"; echo '{}' > "$PRIMARY/app/package.json"   # tracked, so app/ is not collapsed
G -C "$PRIMARY" add README.md .gitignore app
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

mkwt() { # <name>: a worktree on its own branch at main (landed)
  G -C "$PRIMARY" worktree add -q -b "$1" "$T/wt-$1" main
}

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"; LSOF_TREE_FILE="$T/lsof-tree.txt"
LSOF_LOG="$T/lsof.log"; FIND_LOG="$T/find.log"; GIT_LOG="$T/git.log"
export LSOF_CWD_FILE LSOF_OPEN_FILE LSOF_TREE_FILE LSOF_LOG FIND_LOG GIT_LOG
printf 'p1\nn/\n' > "$LSOF_CWD_FILE"; printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"; : > "$LSOF_TREE_FILE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
# A call that names a path after `--` is the per-tree question; LSOF_TREE_FILE answers it.
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LSOF_LOG"
case " $* " in
  *" -- "*) cat "$LSOF_TREE_FILE" ;;
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
REAL_FIND="$(command -v find)"; REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIND_LOG"\nexec "%s" "$@"\n' "$REAL_FIND" > "$STUBS/find"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GIT_LOG"\nexec "%s" "$@"\n' "$REAL_GIT" > "$STUBS/git"
chmod +x "$STUBS"/*

export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$T/claude-sessions" CC_WJ_CLAUDE_PROJECTS="$T/claude-projects"
mkdir -p "$CC_WJ_CLAUDE_SESSIONS" "$CC_WJ_CLAUDE_PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents"
unset CC_WJ_RECLAIM_PUSHED CC_WJ_RECHECK_FRESH_SECONDS CC_WJ_NEW_RULES_MODE
wj() { PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }
block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
says() { block "$1" "$2" | grep -qF -- "$3"; }
judged() { block "$1" "$2" | grep -qxF "    classification: $3"; }
logs() { : > "$LSOF_LOG"; : > "$FIND_LOG"; : > "$GIT_LOG"; }
sessions_scans() { grep -c -- "^$CC_WJ_CLAUDE_SESSIONS -maxdepth 1" "$FIND_LOG"; }
holder_scans() { grep -c -- ' -d cwd ' "$LSOF_LOG"; }
status_reads() { grep -c -- "-C $T/wt-$1 status --porcelain --ignored" "$GIT_LOG"; }

# ─── 1. The machine-wide scans are reused within the freshness window ────────

for n in a1 a2 a3 a4 zlate; do mkwt "$n"; done

logs
wj --apply > "$T/apply-fresh.txt"
check "five landed trees: all are removed" bash -c 'for n in a1 a2 a3 a4; do [ ! -e "$1/wt-$n" ] || exit 1; done' _ "$T"
check "sessions: the registry is read at the start and once more before the first removal, not once per tree" \
  test "$(sessions_scans)" -le 2
check "holders: the machine-wide lsof runs at the start and once more before the first removal, not once per tree" \
  test "$(holder_scans)" -le 2

for n in b1 b2 b3 b4; do mkwt "$n"; done
logs
CC_WJ_RECHECK_FRESH_SECONDS=0 wj --apply > "$T/apply-stale.txt"
check "window 0: every tree is rescanned (the guard is the only thing that held the count down): sessions" \
  test "$(sessions_scans)" -ge 5
check "window 0: and the holders" test "$(holder_scans)" -ge 5
check "window 0: and the trees are still removed" bash -c 'for n in b1 b2 b3 b4; do [ ! -e "$1/wt-$n" ] || exit 1; done' _ "$T"

# A holder that appears after the snapshot is found by the per-tree question and keeps its tree.
for n in c1 c2 c3 late; do mkwt "$n"; done
printf 'p1\nn/\n' > "$LSOF_CWD_FILE"
printf 'p77\nn%s\n' "$T/wt-late" > "$LSOF_TREE_FILE"
logs
wj --apply > "$T/apply-late.txt"
: > "$LSOF_TREE_FILE"
check "a holder that appeared after the scan keeps its tree" test -d "$T/wt-late"
check "  and the other trees of that sweep are removed" bash -c 'for n in c1 c2 c3; do [ ! -e "$1/wt-$n" ] || exit 1; done' _ "$T"
check "  and the sweep says why" grep -qF 'kept: it was entered or changed between the scan and the removal (a process holds it)' "$T/apply-late.txt"
check "  within one rescan of the machine" test "$(holder_scans)" -le 2

# A session that is live at the sweep's start is found by the inventory, as before.
mkwt held
printf 'p1\nn/\np78\nn%s\n' "$T/wt-held" > "$LSOF_CWD_FILE"
wj --apply > "$T/apply-held.txt"
printf 'p1\nn/\n' > "$LSOF_CWD_FILE"
check "a holder present at the scan keeps its tree" test -d "$T/wt-held"

# ─── 2. One status read per dirty tree ───────────────────────────────────────

mkwt dp
echo dp > "$T/wt-dp/dp.txt"; G -C "$T/wt-dp" add dp.txt; G -C "$T/wt-dp" commit -qm "work on dp"
G -C "$T/wt-dp" push -q origin dp
echo edited >> "$T/wt-dp/dp.txt"; echo scratch > "$T/wt-dp/scratch.txt"

logs
wj > "$T/report-dp.txt"
check "a pushed tree with edits is REMOVABLE(wip-pushed)" judged "$T/report-dp.txt" dp 'REMOVABLE(wip-pushed)'
check "a report reads git status --ignored once for it" test "$(status_reads dp)" -eq 1

logs
wj --apply > "$T/apply-dp.txt"
check "--apply removes it after its wip snapshot" test ! -e "$T/wt-dp"
check "  reading git status --ignored twice: once to classify, once fresh before the removal" \
  test "$(status_reads dp)" -eq 2

# ─── 3. Ignored *.log files are regenerable ──────────────────────────────────

mkwt ilog1; echo x > "$T/wt-ilog1/.local-stack-up.log"; echo x > "$T/wt-ilog1/.npm-ci.log"
mkwt ilog2; echo x > "$T/wt-ilog2/build.log"; echo x > "$T/wt-ilog2/app/budget.log"
mkwt ulog;  echo x > "$T/wt-ulog/notes.log"        # untracked, not ignored: work
mkwt idist; mkdir -p "$T/wt-idist/dist"; echo x > "$T/wt-idist/dist/out.js"; echo x > "$T/wt-idist/build.log"
mkwt ikey;  echo x > "$T/wt-ikey/build.log"
printf '.env.log\n' >> "$(G -C "$T/wt-ikey" rev-parse --git-path info/exclude)"; echo SECRET=1 > "$T/wt-ikey/.env.log"

CC_WJ_RECLAIM_PUSHED=0 wj > "$T/report-logs.txt"
check "ignored dot-logs at the top level no longer keep a landed tree" judged "$T/report-logs.txt" ilog1 REMOVABLE
check "ignored logs below the top level (in a tracked directory) no longer keep it" judged "$T/report-logs.txt" ilog2 REMOVABLE
check "an untracked *.log that is not ignored still keeps the tree" judged "$T/report-logs.txt" ulog 'KEEP(unrebuildable=1)'
check "  and the report names it" says "$T/report-logs.txt" ulog 'kept by: ?? notes.log'
check "an ignored dist/ still keeps the tree beside an ignored log" judged "$T/report-logs.txt" idist 'KEEP(unrebuildable=1)'
check "  and the report names dist/, not the log" says "$T/report-logs.txt" idist 'kept by: !! dist/'
check "a credential-shaped name that ends in .log still keeps the tree" judged "$T/report-logs.txt" ikey 'KEEP(unrebuildable=1)'

CC_WJ_RECLAIM_PUSHED=0 wj --apply > "$T/apply-logs.txt"
check "--apply removes the trees whose only leftovers were ignored logs" test ! -e "$T/wt-ilog1" -a ! -e "$T/wt-ilog2"
check "--apply keeps the untracked notes.log" test -f "$T/wt-ulog/notes.log"
check "--apply keeps the ignored dist/" test -f "$T/wt-idist/dist/out.js"
check "--apply keeps the credential-shaped .env.log" test -f "$T/wt-ikey/.env.log"

echo
if [ "$failures" -eq 0 ]; then echo "worktree-janitor-throughput: all passed"; else echo "worktree-janitor-throughput: $failures failed"; fi
[ "$failures" -eq 0 ]
