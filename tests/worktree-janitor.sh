#!/usr/bin/env bash
# Tests for shell/worktree-janitor.sh
# TAP-style: prints "ok - ..." / "not ok - ...", exits non-zero on any failure.
set -uo pipefail

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

# Check whether a file contains a fixed/regex pattern (safe from SIGPIPE)
file_has() {
  local file="$1" pattern="$2"
  grep -q -- "$pattern" "$file" 2>/dev/null
}

# Check lines after a matched pattern in a file
file_after() {
  local file="$1" before="$2" count="$3" pattern="$4"
  local section
  section=$(grep -A "$count" -- "$before" "$file" 2>/dev/null) || return 1
  echo "$section" | grep -q -- "$pattern" 2>/dev/null
}

# ─── Fixture setup ────────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'rm -rf "$TMPDIR_ROOT"' EXIT

ORIGIN="$TMPDIR_ROOT/origin.git"
PRIMARY="$TMPDIR_ROOT/primary"
WT_DIRTY="$TMPDIR_ROOT/wt-dirty"
WT_CLEAN="$TMPDIR_ROOT/wt-clean"
WT_RESIDUE="$TMPDIR_ROOT/wt-residue"

# Create bare origin
git init --bare "$ORIGIN" -b main >/dev/null 2>&1

# Primary clone with initial commit
git clone "$ORIGIN" "$PRIMARY" >/dev/null 2>&1
git -C "$PRIMARY" config user.email "test@test.com"
git -C "$PRIMARY" config user.name "Test"
echo "init" > "$PRIMARY/README.md"
git -C "$PRIMARY" add README.md
git -C "$PRIMARY" commit -m "init" >/dev/null 2>&1
git -C "$PRIMARY" push origin main >/dev/null 2>&1

# Dirty worktree: has an uncommitted file
git -C "$PRIMARY" branch wt-dirty-branch >/dev/null 2>&1
git -C "$PRIMARY" worktree add "$WT_DIRTY" wt-dirty-branch >/dev/null 2>&1
git -C "$WT_DIRTY" config user.email "test@test.com"
git -C "$WT_DIRTY" config user.name "Test"
echo "dirty" > "$WT_DIRTY/dirty.txt"

# Clean worktree: no dirty files
git -C "$PRIMARY" branch wt-clean-branch >/dev/null 2>&1
git -C "$PRIMARY" worktree add "$WT_CLEAN" wt-clean-branch >/dev/null 2>&1

# Residue worktree: clean tracked, has ignored residue (node_modules)
git -C "$PRIMARY" branch wt-residue-branch >/dev/null 2>&1
git -C "$PRIMARY" worktree add "$WT_RESIDUE" wt-residue-branch >/dev/null 2>&1
git -C "$WT_RESIDUE" config user.email "test@test.com"
git -C "$WT_RESIDUE" config user.name "Test"
echo "node_modules/" > "$WT_RESIDUE/.gitignore"
git -C "$WT_RESIDUE" add .gitignore >/dev/null 2>&1
git -C "$WT_RESIDUE" commit -m "add gitignore" >/dev/null 2>&1
mkdir -p "$WT_RESIDUE/node_modules/some-pkg"
echo "residue" > "$WT_RESIDUE/node_modules/some-pkg/index.js"
# Landed: the janitor removes only work that has reached the base.
git -C "$WT_RESIDUE" push -q origin HEAD:main >/dev/null 2>&1

# ─── Stub setup ───────────────────────────────────────────────────────────────
#
# One lsof stub serves every case. What it prints is read from files, so a case changes
# the machine it describes by writing a file rather than by building another stub
# directory: `-d cwd` invocations print $LSOF_CWD_FILE, every other invocation prints
# $LSOF_OPEN_FILE, and both exit $LSOF_RC.
#
# The default describes a live machine holding nothing of interest. It is not empty on
# purpose: every running system has at least one working directory, so an empty scan is
# a scan that did not work, and the janitor is required to treat it that way.

WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"

STUBS_IDLE="$TMPDIR_ROOT/stubs-idle"
mkdir -p "$STUBS_IDLE"
OSASCRIPT_LOG="$TMPDIR_ROOT/osascript.log"
LSOF_CWD_FILE="$TMPDIR_ROOT/lsof-cwd.txt"
LSOF_OPEN_FILE="$TMPDIR_ROOT/lsof-open.txt"
export LSOF_CWD_FILE LSOF_OPEN_FILE
lsof_default() {
  printf 'p1\nn/\n' > "$LSOF_CWD_FILE"
  printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
  export LSOF_RC=0
}
lsof_default

# osascript stub: capture calls to log file
cat > "$STUBS_IDLE/osascript" <<STUB
#!/usr/bin/env bash
printf "%s\n" "\$*" >> "${OSASCRIPT_LOG}"
STUB
chmod +x "$STUBS_IDLE/osascript"

# pgrep stub: no candidate pids (idle)
cat > "$STUBS_IDLE/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUBS_IDLE/pgrep"

cat > "$STUBS_IDLE/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
exit "${LSOF_RC:-0}"
STUB
chmod +x "$STUBS_IDLE/lsof"

# No test may reach the real GitHub API. A case that wants a pull request writes one.
GH_PULLS_FILE="$TMPDIR_ROOT/gh-pulls.txt"
export GH_PULLS_FILE
cat > "$STUBS_IDLE/gh" <<'STUB'
#!/usr/bin/env bash
[ -s "$GH_PULLS_FILE" ] || exit 1
cat "$GH_PULLS_FILE"
STUB
chmod +x "$STUBS_IDLE/gh"

# ─── Env wiring ───────────────────────────────────────────────────────────────

export CC_WJ_ROOT="$TMPDIR_ROOT"
export CC_WJ_LOG="$TMPDIR_ROOT/wj.log"
export CC_WJ_STATE_DIR="$TMPDIR_ROOT/state"
export CC_WJ_NOTIFY_MIN_GB=0
export CC_WJ_COOLDOWN_SECS=0
# Fixtures are created seconds before they are judged. The idle gate has its own cases
# below; everywhere else it is set to a window nothing can fall inside.
export CC_WJ_IDLE_HOURS=0

# ─── Runner helpers ───────────────────────────────────────────────────────────

_wj_idle() {
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" "$@" 2>&1
}

# Physical path, the form lsof reports: on macOS mktemp answers under /var and lsof
# under /private/var.
phys() { (cd -P "$1" 2>/dev/null && pwd); }

# ─── Test 1: inventory lists all worktrees with correct dirty counts ──────────

OUT1="$TMPDIR_ROOT/out1.txt"
_wj_idle --repo "$PRIMARY" > "$OUT1"

expect_yes "inventory: wt-dirty path present" \
  file_has "$OUT1" "wt-dirty"

expect_yes "inventory: wt-clean path present" \
  file_has "$OUT1" "wt-clean"

expect_yes "inventory: wt-residue path present" \
  file_has "$OUT1" "wt-residue"

expect_yes "inventory: wt-dirty shows dirty=1" \
  file_after "$OUT1" "wt-dirty" 3 "dirty=1"

expect_yes "inventory: wt-clean shows dirty=0" \
  file_after "$OUT1" "wt-clean" 3 "dirty=0"

# ─── Test 2: dirty → KEEP in report mode ─────────────────────────────────────

expect_yes "dirty: classified KEEP(unrebuildable=...) in report mode" \
  file_after "$OUT1" "wt-dirty" 4 "KEEP(unrebuildable="

# ─── Test 3: active-cwd → KEEP ────────────────────────────────────────────────

printf 'p1\nn/\np12345\nn%s\n' "$(phys "$WT_CLEAN")" > "$LSOF_CWD_FILE"
OUT3="$TMPDIR_ROOT/out3.txt"
_wj_idle --repo "$PRIMARY" > "$OUT3"
lsof_default

expect_yes "active-cwd: wt-clean is KEEP(active-session)" \
  file_after "$OUT3" "wt-clean" 4 "KEEP(active-session)"

# ─── Test 4: lsof failure → conservative KEEP ────────────────────────────────

export LSOF_RC=1
: > "$LSOF_CWD_FILE"
OUT4="$TMPDIR_ROOT/out4.txt"
_wj_idle --repo "$PRIMARY" > "$OUT4"
lsof_default

expect_yes "lsof-fail: wt-clean conservatively KEEP(active-session)" \
  file_after "$OUT4" "wt-clean" 4 "KEEP(active-session)"

# An empty scan that exits 0 is the same failure wearing a success status. Every live
# system has at least this shell's working directory, so "no lines" means the scan saw
# nothing, not that nothing is there.
: > "$LSOF_CWD_FILE"
OUT4B="$TMPDIR_ROOT/out4b.txt"
_wj_idle --repo "$PRIMARY" > "$OUT4B"
lsof_default

expect_yes "an empty cwd scan with status 0 still keeps every worktree" \
  file_after "$OUT4B" "wt-clean" 4 "KEEP(active-session)"

# ─── A session rarely stands in the worktree it edits ────────────────────────
#
# Claude Code and Codex drive a task worktree through `git -C` and absolute paths while
# their own cwd is the primary checkout. The only holder check used to be the cwd of a
# `pgrep` subset, so a worktree with an editor or a dev server holding files in it read
# as unheld. Held by an open file alone, it must be kept.

printf 'p1\nn/\np777\nn%s/server.log\n' "$(phys "$WT_CLEAN")" > "$LSOF_OPEN_FILE"
OUT_OPEN="$TMPDIR_ROOT/out-open.txt"
_wj_idle --repo "$PRIMARY" > "$OUT_OPEN"
lsof_default

expect_yes "a file held open inside a worktree keeps it" \
  file_after "$OUT_OPEN" "wt-clean" 4 "KEEP(active-session)"

# A failed open-file scan cannot show a worktree unheld either, even when the cwd scan
# worked.
: > "$LSOF_OPEN_FILE"
OUT_OPEN_FAIL="$TMPDIR_ROOT/out-open-fail.txt"
_wj_idle --repo "$PRIMARY" > "$OUT_OPEN_FAIL"
lsof_default

expect_yes "an empty open-file scan keeps every worktree" \
  file_after "$OUT_OPEN_FAIL" "wt-clean" 4 "KEEP(active-session)"

# ─── Idle is measured, not assumed ───────────────────────────────────────────
#
# Clean, unheld and landed are all true of a worktree committed to a minute ago. The
# fixtures were written seconds ago, so under the default six-hour window they are kept.

OUT_RECENT="$TMPDIR_ROOT/out-recent.txt"
CC_WJ_IDLE_HOURS=6 _wj_idle --repo "$PRIMARY" > "$OUT_RECENT"

expect_yes "a worktree touched within the idle window is KEEP(recent-activity)" \
  file_after "$OUT_RECENT" "wt-clean" 4 "KEEP(recent-activity)"

# A malformed window used to be the way a reclaimer silently reclaimed nothing for a
# week. Here it refuses to run at all, loudly, and removes nothing.
expect_no "a malformed CC_WJ_IDLE_HOURS fails the run" \
  env CC_WJ_IDLE_HOURS=off PATH="$STUBS_IDLE:$PATH" bash "$WJ" --repo "$PRIMARY" --apply

expect_yes "and the malformed run removed nothing" \
  test -d "$WT_CLEAN"

# ─── Test 5: default (no --apply) removes nothing ────────────────────────────

# Confirm fixtures are intact before apply
expect_yes "dry-run: wt-clean exists before apply" \
  test -d "$WT_CLEAN"

expect_yes "dry-run: wt-residue exists before apply" \
  test -d "$WT_RESIDUE"

expect_yes "dry-run: output mentions dry-run" \
  file_has "$OUT1" "dry-run"

# ─── Test 6: --apply removes clean idle and residue; leaves dirty intact ──────

OUT6="$TMPDIR_ROOT/out6.txt"
_wj_idle --repo "$PRIMARY" --apply > "$OUT6"

# 6a: clean worktree removed
expect_no "apply: wt-clean directory removed" \
  test -d "$WT_CLEAN"

# 6b: residue worktree removed via force-fallback
expect_no "apply: wt-residue directory removed with its ignored cache" \
  test -d "$WT_RESIDUE"

# 6c: prune ran — removed worktrees absent from list
WT_LIST="$TMPDIR_ROOT/wt-list.txt"
git -C "$PRIMARY" worktree list > "$WT_LIST" 2>&1

expect_no "apply: wt-clean absent from git worktree list after prune" \
  file_has "$WT_LIST" "wt-clean"

expect_no "apply: wt-residue absent from git worktree list after prune" \
  file_has "$WT_LIST" "wt-residue"

# 6d: apply summary shows at least 1 removal
expect_yes "apply: summary shows removed count >= 1" \
  file_has "$OUT6" "removed=[1-9]"

# 6e: dirty KEEP verified — dirty worktree dir intact after apply
expect_yes "apply: dirty worktree intact (KEEP honoured)" \
  test -d "$WT_DIRTY"

# ─── Test 7: branch refs survive worktree removal ────────────────────────────

expect_yes "branch wt-clean-branch ref still exists" \
  git -C "$PRIMARY" rev-parse --verify wt-clean-branch >/dev/null 2>&1

expect_yes "branch wt-residue-branch ref still exists" \
  git -C "$PRIMARY" rev-parse --verify wt-residue-branch >/dev/null 2>&1

# ─── Test 9: osascript notification fires on --apply ─────────────────────────

# The apply run above should have invoked osascript (CC_WJ_NOTIFY_MIN_GB=0,
# CC_WJ_COOLDOWN_SECS=0). The stub wrote to OSASCRIPT_LOG.
expect_yes "osascript notification triggered on apply" \
  test -s "$OSASCRIPT_LOG"

# ─── Report-only must not mutate the repository ──────────────────────────────
#
# `git worktree prune` removes administrative records, and this script's own usage says
# removal needs --apply. Running it from a report made the default mode mutate the
# repository it was only supposed to describe. That became load-bearing once the
# scheduled agent landed: an agent that never passes --apply was deleting metadata daily
# under the name "report-only".

PRUNE_REPO="$TMPDIR_ROOT/prune-probe"
mkdir -p "$PRUNE_REPO"
git -C "$PRUNE_REPO" init -q 2>/dev/null
git -C "$PRUNE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$PRUNE_REPO" worktree add -q "$TMPDIR_ROOT/prune-probe-wt" -b probe 2>/dev/null
# The worktree directory disappears; its administrative record must survive a report.
rm -rf "$TMPDIR_ROOT/prune-probe-wt"
ADMIN_DIR="$PRUNE_REPO/.git/worktrees/prune-probe-wt"

PATH="$STUBS_IDLE:$PATH" bash "$WJ" \
  --repo "$PRUNE_REPO" >/dev/null 2>&1

expect_yes "report-only leaves the administrative record for a missing worktree" \
  test -d "$ADMIN_DIR"

PATH="$STUBS_IDLE:$PATH" bash "$WJ" \
  --apply --repo "$PRUNE_REPO" >/dev/null 2>&1

expect_no "--apply does remove it, so the capability is not merely disabled" \
  test -d "$ADMIN_DIR"

# ─── The report-only path bounds the scheduled agent's launchd logs ──────────
#
# A report never calls `_cc_wj_log_write` - every call site is in removal, pruning, or the
# apply-only summary - so bounding from there was unreachable for the one caller that
# writes these files daily.

WJ_HOME="$TMPDIR_ROOT/fakehome"
AGENT_LOG_DIR="$WJ_HOME/.cc-reaper/logs"
mkdir -p "$AGENT_LOG_DIR"
BIG_LOG="$AGENT_LOG_DIR/launchd-worktree-report-stdout.log"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$BIG_LOG"

HOME="$WJ_HOME" PATH="$STUBS_IDLE:$PATH" \
  bash "$WJ" --repo "$PRUNE_REPO" >/dev/null 2>&1

expect_yes "report-only bounds the scheduled agent's stdout log" \
  bash -c '[ "$(wc -c < "$1")" -le 1048576 ]' _ "$BIG_LOG"


# ─── Blind roots, and the difference between absent and denied ────────────────
#
# The reported failure: the single default root `~/Documents/GitHub` did not exist on
# the host, so discovery found nothing, printed "no repos found" and exited 0 - the
# same output and status as a machine with nothing to clean, while 34 GB of stale
# worktrees sat under two roots the default never named.

# Denial is simulated with a stubbed `find`, not with `chmod 000`. Run as UID 0 -
# ordinary in container CI - mode bits deny nothing: `[ -r ]`, `[ -x ]` and `find` all
# succeed, and both assertions below fail while the implementation is correct. A test
# that only passes for unprivileged users is not a test of this code.
BLIND_ROOT="$TMPDIR_ROOT/blindroots"
mkdir -p "$BLIND_ROOT/denied"
FIND_STUB_WJ="$TMPDIR_ROOT/stub-find-wj"
mkdir -p "$FIND_STUB_WJ"
printf '#!/bin/sh\necho "find: permission denied" >&2\nexit 1\n' > "$FIND_STUB_WJ/find"
chmod +x "$FIND_STUB_WJ/find"

expect_yes "an absent root is a skip, not a failure" \
  bash -c 'CC_WJ_ROOT=/nope/does/not/exist bash "$1" >/dev/null 2>&1' _ "$WJ"

expect_no "a root that exists and cannot be listed fails the run" \
  bash -c 'PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" >/dev/null 2>&1' \
    _ "$WJ" "$BLIND_ROOT" "$FIND_STUB_WJ"

expect_yes "a denied root says so rather than reporting an empty scan" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1); printf "%s\\n" "$out" | grep -q "could not be listed\\|cannot be read"' \
    _ "$WJ" "$BLIND_ROOT" "$FIND_STUB_WJ"

# The wording, not just the fact. A denial that says "needs Full Disk Access" without
# naming the binary is what sent a real grant to a terminal that already had one, while
# the binary launchd spawns stayed absent from the TCC database - measured 2026-09-01.
expect_yes "a denied root names the binary to grant, not a description" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1);
           printf "%s\\n" "$out" | grep -q "THIS binary: /" &&
           printf "%s\\n" "$out" | grep -q "Cmd-Shift-G" &&
           ! printf "%s\\n" "$out" | grep -q "the program in the plist"' \
    _ "$WJ" "$BLIND_ROOT" "$FIND_STUB_WJ"

# The trade-off and the alternative travel with it, or the message reads as an
# instruction to grant rather than a decision to make. install.sh has said both since it
# was written; this is the copy the operator sees when it actually bites.
expect_yes "a denied root carries the trade-off and the alternative" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1);
           printf "%s\\n" "$out" | grep -q "EVERY bash script" &&
           printf "%s\\n" "$out" | grep -q "outside those three"' \
    _ "$WJ" "$BLIND_ROOT" "$FIND_STUB_WJ"

expect_yes "roots are plural" \
  bash -c 'CC_WJ_ROOT="/nope/a:/nope/b" bash "$1" 2>&1 | grep -q "/nope/a,/nope/b"' \
    _ "$WJ"


# ─── A detached HEAD is the one removal this script cannot undo ───────────────
#
# Removal takes the checkout and leaves the branch, so commits on a branch survive it
# whether or not a remote has them. On a detached HEAD nothing references them
# afterwards. The push state was already measured and printed here, and then never
# consulted by the classifier.

# `expect_yes` runs its command in this shell, so the classifier is sourced once here
# and called directly - no subshell to lose the function in.
# shellcheck source=../shell/worktree-janitor.sh
source "$WJ"

# ─── Ignored content is what a removal actually destroys ─────────────────────
#
# Removing a worktree deletes its ignored content along with the checkout, and plain
# `--porcelain` shows none of it. The gate was measuring the wrong thing: on the
# reporting host 29 worktrees were REMOVABLE and 28 of them held ignored content the
# report never mentioned. Anything not known to be rebuildable now keeps the tree.

IGN_ROOT="$TMPDIR_ROOT/ignored"
mkdir -p "$IGN_ROOT"
make_ign_repo() {
  # Two declarations, not one: under `set -u` the right-hand sides of a single
  # `local a=$1 b="$a"` are expanded before either name is bound.
  local name=$1
  local r="$IGN_ROOT/$name"
  mkdir -p "$r"
  git -C "$r" init -q 2>/dev/null
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf 'node_modules/\n.env\nnext-env.d.ts\nblobs/\n' > "$r/.gitignore"
  echo x > "$r/README"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm base >/dev/null 2>&1
  echo "$r"
}

R_CACHE=$(make_ign_repo cache); mkdir -p "$R_CACHE/node_modules/p"; echo 1 > "$R_CACHE/node_modules/p/i.js"
R_ENV=$(make_ign_repo env);     printf 'SECRET=1\n' > "$R_ENV/.env"
R_GEN=$(make_ign_repo gen);     echo '/// ref' > "$R_GEN/next-env.d.ts"
R_UNK=$(make_ign_repo unk);     mkdir -p "$R_UNK/blobs"; echo 1 > "$R_UNK/blobs/x.bin"
# Reproducing the measured shape exactly, because two easier fixtures test nothing:
#
#  - the link's parent must hold TRACKED files. git collapses a wholly-ignored
#    directory to a single `dir/` line and never names what is inside it, so with no
#    sources beside the link the entry under test does not appear at all.
#  - the ignore rule must be `node_modules`, not `node_modules/`. A trailing slash
#    matches directories only, and a symlink is not a directory - it then arrives as
#    `?? b/node_modules`, an untracked entry, which is a different class this gate
#    deliberately treats as real work.
#
# Both hold in the repository this came from, where porcelain emits exactly
# `!! web/shared/node_modules` for `web/shared/node_modules -> ../next/node_modules`.
R_LINK=$(make_ign_repo link)
printf 'node_modules\n' > "$R_LINK/.gitignore"
mkdir -p "$R_LINK/web/next" "$R_LINK/web/shared"
echo 'export const a = 1' > "$R_LINK/web/next/app.ts"
echo 'export const b = 1' > "$R_LINK/web/shared/src.ts"
git -C "$R_LINK" add -A >/dev/null 2>&1
git -C "$R_LINK" commit -qm sources >/dev/null 2>&1
mkdir -p "$R_LINK/web/next/node_modules"; echo 1 > "$R_LINK/web/next/node_modules/i.js"
ln -s ../next/node_modules "$R_LINK/web/shared/node_modules"

# The fixture is only evidence if it produces the shape it claims to. A silent
# mismatch here would let the gate regress while this file still reported "ok".
expect_yes "the symlink fixture reproduces the measured porcelain shape" \
  bash -c 'git -C "$1" status --porcelain --ignored | grep -qx "!! web/shared/node_modules"' \
    _ "$R_LINK"

undiscounted_is() {
  local repo="$1" want="$2" got
  got="$(_cc_wj_undiscounted_count "$repo")"
  [ "$got" = "$want" ] || { printf "       got %s, want %s\n" "$got" "$want" >&2; return 1; }
}

# An entry on the list is a claim that losing it is safe, so the list is tested from
# both ends: a cache is discounted, and a local database that merely looks like
# tooling is not.
R_WRANGLER=$(make_ign_repo wrangler)
printf 'node_modules\n.env\n.wrangler/\n' > "$R_WRANGLER/.gitignore"
# Committed, or the modified .gitignore is itself an undiscounted change and the
# count says 2 for a reason that has nothing to do with what is under test.
git -C "$R_WRANGLER" add -A >/dev/null 2>&1
git -C "$R_WRANGLER" commit -qm "ignore wrangler" >/dev/null 2>&1
mkdir -p "$R_WRANGLER/.wrangler/state/v3/d1"
echo "local data" > "$R_WRANGLER/.wrangler/state/v3/d1/db.sqlite"

expect_yes "a package cache is discounted"                 undiscounted_is "$R_CACHE" 0
expect_yes "local wrangler state is NOT discounted"        undiscounted_is "$R_WRANGLER" 1

# ── sourced from zsh, which this file advertises and which reserves names ────
#
# `status` is READ-ONLY in zsh. `local status` aborts the function before git runs,
# the dirty field comes back empty, the tab-separated inventory line shifts by one,
# and `--apply` then classifies a worktree holding ignored local data as REMOVABLE.
# bash cannot see this at all, so only a zsh run can.
if command -v zsh >/dev/null 2>&1; then
  zsh_counts_the_same() {
    local b z
    b="$(bash -c 'source "$1" >/dev/null 2>&1; _cc_wj_undiscounted_count "$2"' \
         _ "$WJ" "$R_ENV" 2>/dev/null)"
    z="$(zsh -c 'source "$1" >/dev/null 2>&1; _cc_wj_undiscounted_count "$2"' \
         _ "$WJ" "$R_ENV" 2>/dev/null)"
    [ -n "$z" ] && [ "$b" = "$z" ]
  }
  expect_yes "sourced from zsh, the dirty gate answers the same as bash" \
    zsh_counts_the_same
else
  printf "ok - zsh not installed, reserved-name case skipped\n"
fi
expect_yes "a generated file is discounted"                undiscounted_is "$R_GEN" 0
expect_yes "a symlink to a cache is discounted"            undiscounted_is "$R_LINK" 0
expect_yes "an ignored .env keeps the worktree"            undiscounted_is "$R_ENV" 1
expect_yes "unknown ignored content keeps the worktree"    undiscounted_is "$R_UNK" 1
expect_yes "an unreadable repo counts as dirty, not clean" undiscounted_is "$IGN_ROOT/nope" 1


# ─── The classifier: every unanswered gate keeps ─────────────────────────────

classify7_is() {
  local want="$1" got; shift
  got="$(_cc_wj_classify /wt "$@")"
  [ "$got" = "$want" ] || { printf "       got %s, want %s\n" "$got" "$want" >&2; return 1; }
}

expect_yes "a clean, unheld, idle, landed branch is removable" \
  classify7_is REMOVABLE 0 no yes task/x ancestor yes
# Superseded: "an unpushed branch is still removable - the branch keeps the commits".
# The branch still keeps them; an unlanded worktree is now also the checkout somebody is
# working in, and it is kept.
expect_yes "an unlanded branch is kept, although its branch would keep the commits" \
  classify7_is "KEEP(unlanded)" 0 no yes task/unpushed no yes
expect_yes "a base that was not fetched keeps" \
  classify7_is "KEEP(base-unfetched)" 0 no yes task/x unfetched yes
expect_yes "a landed but recently modified worktree is kept" \
  classify7_is "KEEP(recent-activity)" 0 no yes task/x content no
expect_yes "an idle test that could not run keeps" \
  classify7_is "KEEP(idle-unknown)" 0 no yes task/x pr unknown
expect_yes "a detached HEAD landed only by content is kept" \
  classify7_is "KEEP(detached-head)" 0 no yes "(detached)" content yes
expect_yes "a detached HEAD landed by ancestry is removable" \
  classify7_is REMOVABLE 0 no yes "(detached)" ancestor yes
expect_yes "an empty landed answer is not a yes" \
  classify7_is "KEEP(unlanded)" 0 no yes task/x "" yes
expect_yes "an empty idle answer is not a yes" \
  classify7_is "KEEP(idle-unknown)" 0 no yes task/x ancestor ""
# `[ "" -gt 0 ]` is false, so a "greater than zero" test passes an empty count. An empty
# count is what a failed read looks like.
expect_yes "an empty dirty count is not clean" \
  classify7_is "KEEP(unrebuildable=)" "" no yes task/x ancestor yes
expect_yes "an empty active answer is not unheld" \
  classify7_is "KEEP(active-session)" 0 "" yes task/x ancestor yes

# ─── Landed, proven against the fetched base ─────────────────────────────────

L_ROOT="$TMPDIR_ROOT/landed"
mkdir -p "$L_ROOT"
L_ORIGIN="$L_ROOT/origin.git"
L_PRIMARY="$L_ROOT/primary"
git init -q --bare "$L_ORIGIN" -b main
git clone -q "$L_ORIGIN" "$L_PRIMARY" 2>/dev/null
lgit() { git -C "$L_PRIMARY" -c user.email=t@t -c user.name=t "$@"; }
echo base > "$L_PRIMARY/README"; lgit add README; lgit commit -qm base; lgit push -q origin main

# Work that never reached the base.
lgit worktree add -q "$L_ROOT/wt-unlanded" -b unlanded 2>/dev/null
echo wip > "$L_ROOT/wt-unlanded/wip.txt"
git -C "$L_ROOT/wt-unlanded" -c user.email=t@t -c user.name=t add wip.txt
git -C "$L_ROOT/wt-unlanded" -c user.email=t@t -c user.name=t commit -qm wip

# Squash-merged: the same change reached main as a different commit, and main moved on.
lgit worktree add -q "$L_ROOT/wt-squash" -b squash 2>/dev/null
echo s > "$L_ROOT/wt-squash/s.txt"
git -C "$L_ROOT/wt-squash" -c user.email=t@t -c user.name=t add s.txt
git -C "$L_ROOT/wt-squash" -c user.email=t@t -c user.name=t commit -qm "add s"
SQUASH_HEAD="$(git -C "$L_ROOT/wt-squash" rev-parse HEAD)"
echo s > "$L_PRIMARY/s.txt"; lgit add s.txt; lgit commit -qm "squash: add s"
echo later > "$L_PRIMARY/later.txt"; lgit add later.txt; lgit commit -qm later
# Detached at that same head: its change is on main, its commit is on nothing.
lgit worktree add -q --detach "$L_ROOT/wt-squash-detached" "$SQUASH_HEAD" 2>/dev/null
# Detached at a commit that is itself on main.
lgit worktree add -q --detach "$L_ROOT/wt-ancestor-detached" "$(lgit rev-parse HEAD)" 2>/dev/null

# Landed by PR only: squash-merged, then reverted on main, so neither ancestry nor
# content can show it. A second branch at a different head has a PR record for a head
# that is not its own.
lgit worktree add -q "$L_ROOT/wt-pr" -b pr 2>/dev/null
echo p > "$L_ROOT/wt-pr/p.txt"
git -C "$L_ROOT/wt-pr" -c user.email=t@t -c user.name=t add p.txt
git -C "$L_ROOT/wt-pr" -c user.email=t@t -c user.name=t commit -qm "add p"
PR_HEAD="$(git -C "$L_ROOT/wt-pr" rev-parse HEAD)"
echo p > "$L_PRIMARY/p.txt"; lgit add p.txt; lgit commit -qm "squash: add p (#1)"
PR_MERGE="$(lgit rev-parse HEAD)"
lgit rm -q p.txt; lgit commit -qm "revert p"
lgit worktree add -q "$L_ROOT/wt-pr-other" -b pr-other 2>/dev/null
echo q > "$L_ROOT/wt-pr-other/q.txt"
git -C "$L_ROOT/wt-pr-other" -c user.email=t@t -c user.name=t add q.txt
git -C "$L_ROOT/wt-pr-other" -c user.email=t@t -c user.name=t commit -qm "add q"
lgit push -q origin main

# The PR proof names the repository from the configured URL, so the origin gets a GitHub
# identity and git reaches the local bare repository through insteadOf.
lgit config remote.origin.url https://github.com/acme/demo.git
lgit config "url.$L_ORIGIN.insteadOf" https://github.com/acme/demo.git

# The gh stub answers the question the janitor actually asks: which merged PRs, into this
# base, have THIS head. It filters on the commit in the endpoint path and requires the
# filter expression to carry the same head and base, so a janitor that stopped comparing
# the head SHA would stop matching here too.
cat > "$STUBS_IDLE/gh" <<'STUB'
#!/usr/bin/env bash
# Each record: <commit asked about> <that PR's head sha> <merge sha> <base>. The endpoint
# returns every PR associated with the commit; the stub then applies whichever conditions
# the caller's --jq filter actually states, so a filter that stops comparing the head or
# the base lets the wrong PR through here exactly as it would against GitHub.
[ -s "$GH_PULLS_FILE" ] || exit 1
host="" endpoint="" jq=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) host="$2"; shift 2 ;;
    --jq) jq="$2"; shift 2 ;;
    repos/*) endpoint="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$host" = github.com ] || exit 1
sha="${endpoint#repos/acme/demo/commits/}"; sha="${sha%/pulls}"
while read -r asked head merge base; do
  [ "$asked" = "$sha" ] || continue
  case "$jq" in *'.head.sha == '*) case "$jq" in *".head.sha == \"$head\""*) ;; *) continue ;; esac ;; esac
  case "$jq" in *'.base.ref == '*) case "$jq" in *".base.ref == \"$base\""*) ;; *) continue ;; esac ;; esac
  echo "$merge"
done < "$GH_PULLS_FILE"
STUB
chmod +x "$STUBS_IDLE/gh"
printf '%s %s %s main\n' "$PR_HEAD" "$PR_HEAD" "$PR_MERGE" > "$GH_PULLS_FILE"
# pr-other's commit is associated with a merged PR whose head later moved past it.
printf '%s %s %s main\n' "$(git -C "$L_ROOT/wt-pr-other" rev-parse HEAD)" \
  "2222222222222222222222222222222222222222" "$PR_MERGE" >> "$GH_PULLS_FILE"

OUT_L="$TMPDIR_ROOT/out-landed.txt"
_wj_idle --repo "$L_PRIMARY" > "$OUT_L"

expect_yes "unlanded work is KEEP(unlanded)" \
  file_after "$OUT_L" "wt-unlanded$" 2 "KEEP(unlanded)"
expect_yes "a squash-merged branch is landed by content" \
  file_after "$OUT_L" "wt-squash$" 2 "landed=content"
expect_yes "and is removable" \
  file_after "$OUT_L" "wt-squash$" 2 "REMOVABLE"
expect_yes "a detached HEAD whose change landed by content is KEEP(detached-head)" \
  file_after "$OUT_L" "wt-squash-detached$" 2 "KEEP(detached-head)"
expect_yes "a detached HEAD on the base is removable" \
  file_after "$OUT_L" "wt-ancestor-detached$" 2 "REMOVABLE"
expect_yes "a PR merged at this exact head lands work that was later reverted" \
  file_after "$OUT_L" "wt-pr$" 2 "landed=pr"
expect_yes "a PR recorded at a different head does not count" \
  file_after "$OUT_L" "wt-pr-other$" 2 "KEEP(unlanded)"

# The PR proof must not outlive the base: the merge commit has to be on what was fetched.
printf '%s %s %s main\n' "$PR_HEAD" "$PR_HEAD" "1111111111111111111111111111111111111111" > "$GH_PULLS_FILE"
OUT_L2="$TMPDIR_ROOT/out-landed2.txt"
_wj_idle --repo "$L_PRIMARY" > "$OUT_L2"
expect_yes "a merged PR whose merge commit is not on the base does not count" \
  file_after "$OUT_L2" "wt-pr$" 2 "KEEP(unlanded)"
: > "$GH_PULLS_FILE"

# An origin that cannot be reached keeps everything, and says why once.
U_ROOT="$TMPDIR_ROOT/unfetched"
git clone -q "$L_ORIGIN" "$U_ROOT" 2>/dev/null
git -C "$U_ROOT" worktree add -q "$TMPDIR_ROOT/unfetched-wt" -b u origin/main 2>/dev/null
git -C "$U_ROOT" config remote.origin.url "$TMPDIR_ROOT/no-such-origin.git"
OUT_U="$TMPDIR_ROOT/out-unfetched.txt"
_wj_idle --repo "$U_ROOT" > "$OUT_U"
expect_yes "an unreachable origin keeps its worktrees as KEEP(base-unfetched)" \
  file_after "$OUT_U" "unfetched-wt$" 2 "KEEP(base-unfetched)"
expect_yes "and the report says the base could not be fetched" \
  file_has "$OUT_U" "could not be fetched"


# ─── What git itself protects ─────────────────────────────────────────────────
#
# Found by running the report on a real repository: Claude Code locks the worktrees it
# creates for agents (`claude agent <id> (pid ...)`), and one such worktree - landed,
# clean, idle - was classified REMOVABLE. A lock is an explicit request to keep.

lgit worktree add -q "$L_ROOT/wt-locked" -b locked-wt origin/main 2>/dev/null
lgit worktree lock --reason "claude agent agent-test (pid 1)" "$L_ROOT/wt-locked"

# A populated submodule carries state the outer status does not show.
SUB_SRC="$L_ROOT/sub-src"
git init -q "$SUB_SRC" -b main
git -C "$SUB_SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m sub
lgit worktree add -q "$L_ROOT/wt-submodule" -b submodule-wt origin/main 2>/dev/null
git -C "$L_ROOT/wt-submodule" -c protocol.file.allow=always -c user.email=t@t -c user.name=t \
  submodule add -q "$SUB_SRC" sub >/dev/null 2>&1
git -C "$L_ROOT/wt-submodule" -c user.email=t@t -c user.name=t commit -qm "add submodule"
git -C "$L_ROOT/wt-submodule" push -q origin HEAD:main 2>/dev/null

OUT_GITKEEP="$TMPDIR_ROOT/out-gitkeep.txt"
_wj_idle --repo "$L_PRIMARY" > "$OUT_GITKEEP"

expect_yes "the submodule fixture is landed, so only the submodule can keep it" \
  file_after "$OUT_GITKEEP" "wt-submodule$" 1 "landed=ancestor"
expect_yes "a locked worktree is KEEP(locked)" \
  file_after "$OUT_GITKEEP" "wt-locked$" 2 "KEEP(locked)"
expect_yes "and the report carries the lock's reason" \
  file_after "$OUT_GITKEEP" "wt-locked$" 3 "claude agent agent-test"
expect_yes "a worktree with a populated submodule is KEEP(submodule)" \
  file_after "$OUT_GITKEEP" "wt-submodule$" 2 "KEEP(submodule)"

# ─── A repository declares its own byproducts, on its base ───────────────────

C_ROOT="$TMPDIR_ROOT/contents"
mkdir -p "$C_ROOT"
C_ORIGIN="$C_ROOT/origin.git"
C_PRIMARY="$C_ROOT/primary"
git init -q --bare "$C_ORIGIN" -b main
git clone -q "$C_ORIGIN" "$C_PRIMARY" 2>/dev/null
cgit() { git -C "$C_PRIMARY" -c user.email=t@t -c user.name=t "$@"; }
printf 'logs/\nnotes.txt\nbuild/\nnode_modules/\n' > "$C_PRIMARY/.gitignore"
printf '# runtime output\nlogs/*.log   # the API opens this on import\n/build/\n*\n[[:alpha:]][[:alpha:]]*\n' \
  > "$C_PRIMARY/.worktree-regenerable"
echo x > "$C_PRIMARY/README"
cgit add -A; cgit commit -qm base; cgit push -q origin main

c_wt() { cgit worktree add -q "$C_ROOT/$1" -b "$1" origin/main 2>/dev/null; echo "$C_ROOT/$1"; }
W_LOGS=$(c_wt wt-logs);     mkdir -p "$W_LOGS/logs"; : > "$W_LOGS/logs/api.log"
W_NOTES=$(c_wt wt-notes);   echo "remember" > "$W_NOTES/notes.txt"
W_CRED=$(c_wt wt-cred);     mkdir -p "$W_CRED/build/out"; echo SECRET=1 > "$W_CRED/build/out/.env"
W_NM=$(c_wt wt-nm-cred);    mkdir -p "$W_NM/node_modules/pkg"; echo k > "$W_NM/node_modules/pkg/deploy.pem"
W_MIXED=$(c_wt wt-mixed);   mkdir -p "$W_MIXED/logs"; : > "$W_MIXED/logs/api.log"; echo n > "$W_MIXED/logs/notes.md"
# A branch that declares its own ignored file disposable. The declaration is on the
# branch, not on the base, and must discount nothing.
W_SELF=$(c_wt wt-selfdecl)
printf 'notes.txt\n' >> "$W_SELF/.worktree-regenerable"
git -C "$W_SELF" -c user.email=t@t -c user.name=t commit -qam "declare my notes disposable"
echo "remember" > "$W_SELF/notes.txt"

OUT_C="$TMPDIR_ROOT/out-contents.txt"
_wj_idle --repo "$C_PRIMARY" > "$OUT_C"

expect_yes "a declared log inside a collapsed ignored directory is discounted" \
  file_after "$OUT_C" "wt-logs$" 2 "REMOVABLE"
expect_yes "an undeclared ignored file keeps the worktree" \
  file_after "$OUT_C" "wt-notes$" 2 "KEEP(unrebuildable=1)"
expect_yes "and the report names it" \
  file_after "$OUT_C" "wt-notes$" 3 "kept by: !! notes.txt"
expect_yes "and says where a declaration would release it" \
  file_after "$OUT_C" "wt-notes$" 4 "list it in .worktree-regenerable on origin/main"
expect_yes "a declared directory holding a credential keeps the worktree" \
  file_after "$OUT_C" "wt-cred$" 3 "declared, but holds a credential-shaped file"
expect_yes "a cache holding a credential two levels down keeps the worktree" \
  file_after "$OUT_C" "wt-nm-cred$" 3 "node_modules/ (holds a credential-shaped file)"
expect_yes "a collapsed directory with one undeclared file keeps the worktree" \
  file_after "$OUT_C" "wt-mixed$" 2 "KEEP(unrebuildable=1)"
expect_yes "a declaration only on the branch discounts nothing" \
  file_after "$OUT_C" "wt-selfdecl$" 3 "kept by: !! notes.txt"
expect_yes "a pattern that names no path is dropped, and said so" \
  file_has "$OUT_C" "name no path: \\*"

# A name git would C-quote without -z. Read raw, it is matched as the file it is.
W_UTF=$(c_wt wt-utf8)
# A tracked file beside the cache, or git collapses the whole directory to `!! café/`.
mkdir -p "$W_UTF/café/node_modules"; echo 1 > "$W_UTF/café/node_modules/i.js"
echo src > "$W_UTF/café/src.txt"
git -C "$W_UTF" -c user.email=t@t -c user.name=t add "café/src.txt"
git -C "$W_UTF" -c user.email=t@t -c user.name=t commit -qm "tracked beside the cache"
git -C "$W_UTF" -c user.email=t@t -c user.name=t -c core.quotepath=true status --porcelain --ignored > "$TMPDIR_ROOT/utf8-status.txt"
expect_yes "the non-ASCII fixture is one git quotes without -z" \
  file_has "$TMPDIR_ROOT/utf8-status.txt" '"caf'
expect_yes "a cache under a non-ASCII directory is still discounted" \
  undiscounted_is "$W_UTF" 0

# ─── Bounded commands ─────────────────────────────────────────────────────────

timeout_rc_is_124() {
  local rc=0
  _cc_wj_with_timeout 1 sleep 30 || rc=$?
  [ "$rc" -eq 124 ]
}
expect_yes "a command past its bound returns 124" timeout_rc_is_124

# The bound ends the group, not just the child: a grandchild holding the output pipe
# would otherwise keep `$(...)` waiting.
timeout_ends_the_group() {
  local marker="$TMPDIR_ROOT/grandchild.pid" start end
  start=$(date +%s)
  _cc_wj_with_timeout 1 bash -c 'sleep 30 & echo $! > "$1"; wait' _ "$marker" >/dev/null 2>&1
  end=$(date +%s)
  sleep 1
  [ $((end - start)) -lt 10 ] && ! ps -p "$(cat "$marker")" >/dev/null 2>&1
}
expect_yes "a bounded command's grandchild is ended with it" timeout_ends_the_group

# And when the command exits on its own: a background grandchild it leaves holding the
# output pipe would keep a `$(...)` caller waiting for as long as the grandchild lives.
exit_ends_the_group() {
  local marker="$TMPDIR_ROOT/leftover.pid" start end
  start=$(date +%s)
  out="$(_cc_wj_with_timeout 20 bash -c 'sleep 30 & echo $! > "$1"; exit 0' _ "$marker")"
  end=$(date +%s)
  [ $((end - start)) -lt 10 ] && ! ps -p "$(cat "$marker")" >/dev/null 2>&1
}
expect_yes "a command that exits leaves no grandchild holding its output" exit_ends_the_group

timeout_passes_status() {
  local rc=0
  _cc_wj_with_timeout 5 bash -c 'exit 3' || rc=$?
  [ "$rc" -eq 3 ]
}
expect_yes "a command inside its bound keeps its own exit status" timeout_passes_status

# ─── Session mode ─────────────────────────────────────────────────────────────

S_ROOT="$TMPDIR_ROOT/session"
mkdir -p "$S_ROOT"
S_ORIGIN="$S_ROOT/origin.git"
S_PRIMARY="$S_ROOT/primary"
git init -q --bare "$S_ORIGIN" -b main
git clone -q "$S_ORIGIN" "$S_PRIMARY" 2>/dev/null
sgit() { git -C "$S_PRIMARY" -c user.email=t@t -c user.name=t "$@"; }
echo x > "$S_PRIMARY/README"; sgit add README; sgit commit -qm base; sgit push -q origin main
sgit worktree add -q "$S_ROOT/wt-done" -b done origin/main 2>/dev/null
sgit worktree add -q "$S_ROOT/wt-mine" -b mine origin/main 2>/dev/null
S_LOG="$TMPDIR_ROOT/session.log"

# Polls the log for the end marker rather than sleeping a fixed time: the sweep is
# detached, and a fixed sleep either wastes time or reads a half-written log.
wait_session_end() {
  local want="$1" i=0
  while [ "$i" -lt 60 ]; do
    [ "$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)" -ge "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# A slow process scan, so the launcher can be shown to return before the sweep ends.
SLOW_STUBS="$TMPDIR_ROOT/stubs-slow"
mkdir -p "$SLOW_STUBS"
cat > "$SLOW_STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
sleep 3
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$SLOW_STUBS/lsof"

session_returns_first() {
  local start end
  start=$(date +%s)
  CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_ROOT/wt-mine" \
    PATH="$SLOW_STUBS:$STUBS_IDLE:$PATH" bash "$WJ" --session </dev/null
  end=$(date +%s)
  [ $((end - start)) -lt 3 ]
}
expect_yes "--session returns before the sweep finishes" session_returns_first

# While the slow scan runs, the sweep is its own session and process group leader.
session_is_detached() {
  local pid="" i=0
  while [ -z "$pid" ] && [ "$i" -lt 20 ]; do
    pid="$(sed -n 's/.*(pid \([0-9][0-9]*\))$/\1/p' "$S_LOG" 2>/dev/null | tail -n 1)"
    [ -n "$pid" ] || sleep 0.2
    i=$((i + 1))
  done
  [ -n "$pid" ] || return 1
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ] &&
    [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]
}
expect_yes "the session sweep leads its own process group" session_is_detached
expect_yes "the session sweep finishes and records its end" wait_session_end 1
expect_yes "the run record carries start time, elapsed seconds and free space" \
  bash -c 'grep -q "session sweep 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T" "$1" &&
           grep -q "elapsed=[0-9]*s free_before=[0-9.]*GiB free_after=[0-9.]*GiB" "$1"' _ "$S_LOG"
expect_yes "without opt-in the session sweep only reports" \
  bash -c 'grep -q "dry-run" "$1" && [ -d "$2" ]' _ "$S_LOG" "$S_ROOT/wt-done"

CC_WJ_SESSION_APPLY=yes CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_ROOT/wt-mine" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session </dev/null
wait_session_end 2
expect_yes "a truthy-looking value is not consent" \
  bash -c 'grep -q "CC_WJ_SESSION_APPLY=yes is not 1; reporting only" "$1" && [ -d "$2" ]' \
    _ "$S_LOG" "$S_ROOT/wt-done"

printf '{"session_id":"x","cwd":"%s"}\n' "$S_ROOT/wt-mine" |
  CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_ROOT/wt-mine" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
wait_session_end 3
expect_no "with CC_WJ_SESSION_APPLY=1 a landed idle worktree is removed" \
  test -d "$S_ROOT/wt-done"
expect_yes "the session's own checkout is kept" \
  bash -c 'grep -q "KEEP(this-session)" "$1" && [ -d "$2" ]' _ "$S_LOG" "$S_ROOT/wt-mine"

S_OUTSIDE="$TMPDIR_ROOT/not-a-repo"
mkdir -p "$S_OUTSIDE"
CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_OUTSIDE" PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session </dev/null
wait_session_end 4
expect_yes "a session outside any repository sweeps nothing and says so" \
  file_has "$S_LOG" "is not inside a git repository; swept nothing"

# ─── The sweep lock ───────────────────────────────────────────────────────────

sgit worktree add -q "$S_ROOT/wt-locked" -b locked origin/main 2>/dev/null
S_LOCK="$(git -C "$S_PRIMARY" rev-parse --path-format=absolute --git-common-dir)/cc-reaper-worktree-janitor.lock"
# A live holder that is this script by name.
bash -c 'exec -a worktree-janitor-holder sleep 30' &
HOLDER=$!
sleep 0.3
mkdir -p "$S_LOCK"; echo "$HOLDER" > "$S_LOCK/pid"; ps -o command= -p "$HOLDER" > "$S_LOCK/cmd"
OUT_LOCK="$TMPDIR_ROOT/out-lock.txt"
LOCK_RC=0
PATH="$STUBS_IDLE:$PATH" bash "$WJ" --repo "$S_PRIMARY" --apply > "$OUT_LOCK" 2>&1 || LOCK_RC=$?
expect_yes "a run that skipped a locked repository exits non-zero" test "$LOCK_RC" -ne 0
expect_yes "a live sweep's lock blocks removal" \
  bash -c 'grep -q "another worktree-janitor sweep (pid [0-9]*) holds" "$1" && [ -d "$2" ]' \
    _ "$OUT_LOCK" "$S_ROOT/wt-locked"
# A live pid that no longer runs the command recorded with it is not a sweep.
echo "bash /somewhere/worktree-janitor.sh --apply" > "$S_LOCK/cmd"
OUT_LOCK_REUSED="$TMPDIR_ROOT/out-lock-reused.txt"
_wj_idle --repo "$S_PRIMARY" > /dev/null
PATH="$STUBS_IDLE:$PATH" bash "$WJ" --repo "$S_PRIMARY" --apply > "$OUT_LOCK_REUSED" 2>&1
expect_no "a live pid recorded with another command does not hold the lock" \
  test -d "$S_ROOT/wt-locked"
sgit worktree add -q "$S_ROOT/wt-locked" -b locked2 origin/main 2>/dev/null
mkdir -p "$S_LOCK"; echo "$HOLDER" > "$S_LOCK/pid"; ps -o command= -p "$HOLDER" > "$S_LOCK/cmd"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
OUT_LOCK2="$TMPDIR_ROOT/out-lock2.txt"
_wj_idle --repo "$S_PRIMARY" --apply > "$OUT_LOCK2"
expect_no "a dead holder's lock is taken over" \
  test -d "$S_ROOT/wt-locked"
expect_no "and released afterwards" \
  test -d "$S_LOCK"


# ─── The decision is asked again right before removal ────────────────────────
#
# A sweep over many worktrees decides from scans taken before its loop began. A session
# that enters a worktree after that scan must still keep it. The stub reports nobody on
# its first open-file listing and a holder on every later one.

sgit worktree add -q "$S_ROOT/wt-entered" -b entered origin/main 2>/dev/null
RACE_STUBS="$TMPDIR_ROOT/stubs-race"
mkdir -p "$RACE_STUBS"
RACE_COUNT="$TMPDIR_ROOT/race-count"
: > "$RACE_COUNT"
export RACE_COUNT RACE_WT="$(phys "$S_ROOT/wt-entered")"
cat > "$RACE_STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) printf 'p1\nn/\n' ;;
  *)
    echo x >> "$RACE_COUNT"
    if [ "$(wc -l < "$RACE_COUNT")" -le 1 ]; then
      printf 'p1\nn/dev/null\n'
    else
      printf 'p1\nn/dev/null\np4242\nn%s/editor.swp\n' "$RACE_WT"
    fi ;;
esac
STUB
chmod +x "$RACE_STUBS/lsof"
OUT_RACE="$TMPDIR_ROOT/out-race.txt"
PATH="$RACE_STUBS:$STUBS_IDLE:$PATH" bash "$WJ" --repo "$S_PRIMARY" --apply > "$OUT_RACE" 2>&1
expect_yes "a holder that appears after the scan keeps the worktree" \
  bash -c 'grep -q "entered or changed between the scan and the removal" "$1" && [ -d "$2" ]' \
    _ "$OUT_RACE" "$S_ROOT/wt-entered"


# ─── Review round 2: what the first candidate could not see ───────────────────

R2_ROOT="$TMPDIR_ROOT/r2"
mkdir -p "$R2_ROOT"
R2_ORIGIN="$R2_ROOT/origin.git"
R2_PRIMARY="$R2_ROOT/primary"
git init -q --bare "$R2_ORIGIN" -b main
git clone -q "$R2_ORIGIN" "$R2_PRIMARY" 2>/dev/null
r2git() { git -C "$R2_PRIMARY" -c user.email=t@t -c user.name=t "$@"; }
echo x > "$R2_PRIMARY/README"; r2git add README; r2git commit -qm base
echo y > "$R2_PRIMARY/second"; r2git add second; r2git commit -qm second; r2git push -q origin main
R2_FIRST="$(r2git rev-parse HEAD~1)"
r2_wt() { r2git worktree add -q "$1" -b "$2" origin/main 2>/dev/null; }

# Old, as far as every mtime the idle gate reads is concerned: the tree and the
# worktree's git administrative files.
age_tree() {
  local gd
  find -H "$1" -exec touch -h -t 202001010000 {} + 2>/dev/null
  gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  find "$gd" -exec touch -h -t 202001010000 {} + 2>/dev/null
}

# An lsof stub that spells names the way lsof can in any locale: every byte outside
# printable ASCII escaped as \xNN, and a backslash doubled. Real lsof escapes U+200B,
# U+200F, U+FEFF and U+0085 even under en_US.UTF-8, so no locale yields raw names.
ESC_STUBS="$TMPDIR_ROOT/stubs-escape"
mkdir -p "$ESC_STUBS"
cat > "$ESC_STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -d cwd "*) f="$LSOF_CWD_FILE" ;; *) f="$LSOF_OPEN_FILE" ;; esac
[ -n "${LSOF_LOCALE_LOG:-}" ] && printf '%s\n' "${LC_ALL-unset}" >> "$LSOF_LOCALE_LOG"
perl -pe 's/\\/\\\\/g; s/([^\x20-\x7e\n])/sprintf("\\x%02x", ord $1)/ge' "$f"
STUB
chmod +x "$ESC_STUBS/lsof"

r2_wt "$R2_ROOT/專案-wt" cjk
r2_wt "$R2_ROOT/back\\slash-wt" backslash
r2_wt "$R2_ROOT/閒置-wt" cjk-idle
ZW="$(printf 'zw\342\200\213x-wt')"
r2_wt "$R2_ROOT/$ZW" zero-width
printf 'p1\nn/\np55\nn%s\np56\nn%s\np57\nn%s/editor.swp\n' "$(phys "$R2_ROOT/專案-wt")" \
  "$(phys "$R2_ROOT/back\\slash-wt")" "$(phys "$R2_ROOT/$ZW")" > "$LSOF_CWD_FILE"
OUT_ESC="$TMPDIR_ROOT/out-escape.txt"
LSOF_LOCALE_LOG="$TMPDIR_ROOT/lsof-locale.log"
LSOF_LOCALE_LOG="$LSOF_LOCALE_LOG" LC_ALL=en_US.UTF-8 PATH="$ESC_STUBS:$STUBS_IDLE:$PATH" \
  bash "$WJ" --repo "$R2_PRIMARY" > "$OUT_ESC" 2>&1
# In a double-byte locale such as ja_JP.SJIS lsof leaves `\` undoubled after a lead byte,
# and the decoded name no longer matches. Found in review round 3.
expect_yes "both holder scans run in the C locale whatever the caller's" \
  bash -c '[ "$(sort -u "$1")" = C ] && [ "$(wc -l < "$1" | tr -d " ")" = 2 ]' _ "$LSOF_LOCALE_LOG"
lsof_default

# Found by review: lsof escapes these bytes, so a match against git's raw spelling of the
# path finds no holder. The realistic locale for a hook or launchd is C.
expect_yes "a held worktree with a non-ASCII path is kept" \
  file_after "$OUT_ESC" "專案-wt$" 2 "KEEP(active-session)"
expect_yes "a held worktree whose path holds a backslash is kept" \
  file_after "$OUT_ESC" 'back\\slash-wt$' 2 "KEEP(active-session)"
# The other direction: scanned in a UTF-8 locale, a non-ASCII path nobody holds is
# matched as the name it is, and is not kept merely for being non-ASCII.
expect_yes "an unheld worktree with a non-ASCII path is still removable" \
  file_after "$OUT_ESC" "閒置-wt$" 2 "REMOVABLE"

# Found in review round 2: under a UTF-8 locale real lsof still escapes a zero-width
# space, so a holder of this worktree matched nothing whatever locale the scan ran in.
expect_yes "a held worktree whose path holds an invisible character is kept" \
  bash -c 'grep -a -A 2 -- "zw.*x-wt$" "$1" | grep -q "KEEP(active-session)"' _ "$OUT_ESC"

# A tab in the path would shift every field of the inventory line that carries it.
r2_wt "$R2_ROOT/tab	wt" tabwt
OUT_TAB="$TMPDIR_ROOT/out-tab.txt"
_wj_idle --repo "$R2_PRIMARY" > "$OUT_TAB"
expect_yes "a worktree whose path holds a tab is KEEP(unsafe-path)" \
  file_after "$OUT_TAB" "tab?wt$" 2 "KEEP(unsafe-path)"
OUT_TAB_APPLY="$TMPDIR_ROOT/out-tab-apply.txt"
_wj_idle --repo "$R2_PRIMARY" --apply > "$OUT_TAB_APPLY"
expect_yes "and is never removed" test -d "$R2_ROOT/tab	wt"

# ─── Idle, measured where the work actually happens ──────────────────────────

IDLE_ROOT="$TMPDIR_ROOT/idle"
mkdir -p "$IDLE_ROOT"
IDLE_ORIGIN="$IDLE_ROOT/origin.git"
IDLE_PRIMARY="$IDLE_ROOT/primary"
git init -q --bare "$IDLE_ORIGIN" -b main
git clone -q "$IDLE_ORIGIN" "$IDLE_PRIMARY" 2>/dev/null
igit() { git -C "$IDLE_PRIMARY" -c user.email=t@t -c user.name=t "$@"; }
echo x > "$IDLE_PRIMARY/README"; igit add README; igit commit -qm base
echo y > "$IDLE_PRIMARY/second"; igit add second; igit commit -qm second; igit push -q origin main
I_FIRST="$(igit rev-parse HEAD~1)"

# The positive control: old everywhere, so it is idle - and it stays idle although the
# janitor runs `git status` in it, which must not rewrite the index it is about to judge.
igit worktree add -q "$IDLE_ROOT/wt-old" -b old origin/main 2>/dev/null
age_tree "$IDLE_ROOT/wt-old"

# Every file old, but a branch switched a minute ago: only the git administrative files
# say so.
igit worktree add -q "$IDLE_ROOT/wt-switched" -b switched origin/main 2>/dev/null
age_tree "$IDLE_ROOT/wt-switched"
git -C "$IDLE_ROOT/wt-switched" switch -q -c switched-again

# Moved to another disk and linked back: git records the link.
igit worktree add -q "$IDLE_ROOT/wt-linked" -b linked origin/main 2>/dev/null
mv "$IDLE_ROOT/wt-linked" "$IDLE_ROOT/elsewhere"
ln -s "$IDLE_ROOT/elsewhere" "$IDLE_ROOT/wt-linked"
age_tree "$IDLE_ROOT/wt-linked"
echo fresh > "$IDLE_ROOT/elsewhere/fresh.txt"
echo 'fresh.txt' >> "$(git -C "$IDLE_ROOT/elsewhere" rev-parse --absolute-git-dir)/info/exclude" 2>/dev/null ||
  { mkdir -p "$(git -C "$IDLE_ROOT/elsewhere" rev-parse --git-common-dir)/info" &&
    echo 'fresh.txt' >> "$(git -C "$IDLE_ROOT/elsewhere" rev-parse --git-common-dir)/info/exclude"; }
touch -h -t 202001010000 "$IDLE_ROOT/wt-linked"

OUT_IDLE="$TMPDIR_ROOT/out-idle.txt"
CC_WJ_IDLE_HOURS=6 CC_WJ_REGENERABLE_FILES="fresh.txt" _wj_idle --repo "$IDLE_PRIMARY" > "$OUT_IDLE"
expect_yes "an old, landed, clean worktree is idle after the janitor's own git status" \
  file_after "$OUT_IDLE" "wt-old$" 2 "REMOVABLE"
expect_yes "a branch switched a minute ago is not idle" \
  file_after "$OUT_IDLE" "wt-switched$" 2 "KEEP(recent-activity)"
expect_yes "a worktree reached through a symlink is examined through the link" \
  file_after "$OUT_IDLE" "wt-linked$" 2 "KEEP(recent-activity)"

# ─── The re-check before removal asks every question again ───────────────────
#
# One stub, one action: its first open-file listing reports nobody, and on the second -
# the one taken right before removal - it runs $RACE_ACTION and still reports nobody.
ACT_STUBS="$TMPDIR_ROOT/stubs-act"
mkdir -p "$ACT_STUBS"
ACT_COUNT="$TMPDIR_ROOT/act-count"
export ACT_COUNT
cat > "$ACT_STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) printf 'p1\nn/\n' ;;
  *)
    echo x >> "$ACT_COUNT"
    [ "$(wc -l < "$ACT_COUNT")" -eq 2 ] && eval "$RACE_ACTION" >/dev/null 2>&1
    printf 'p1\nn/dev/null\n' ;;
esac
STUB
chmod +x "$ACT_STUBS/lsof"

race_keeps() {
  local name="$1" hours="$2" action="$3" setup="${4:-:}" wt="$IDLE_ROOT/race-$1" out
  _wj_idle --repo "$IDLE_PRIMARY" --apply >/dev/null 2>&1
  igit worktree add -q "$wt" -b "race-$name" origin/main 2>/dev/null
  eval "${setup//@WT@/$wt}" >/dev/null 2>&1
  age_tree "$wt"
  : > "$ACT_COUNT"
  out="$TMPDIR_ROOT/out-race-$name.txt"
  RACE_ACTION="${action//@WT@/$wt}" CC_WJ_IDLE_HOURS="$hours" \
    PATH="$ACT_STUBS:$STUBS_IDLE:$PATH" bash "$WJ" --repo "$IDLE_PRIMARY" --apply > "$out" 2>&1
  grep -q "entered or changed between the scan and the removal" "$out" && [ -d "$wt" ]
}

expect_yes "untracked work written after the scan keeps the worktree" \
  race_keeps contents 0 'echo notes > "@WT@/notes.txt"'
expect_yes "a file touched after the scan keeps the worktree" \
  race_keeps idle 6 'echo later > "@WT@/second"' 'git -C "@WT@" update-index --assume-unchanged second'
expect_yes "a HEAD moved after the scan keeps the worktree" \
  race_keeps head 0 "git -C '@WT@' checkout -q --detach $I_FIRST"
expect_yes "a lock taken after the scan keeps the worktree" \
  race_keeps lock 0 'git -C "@WT@" worktree lock "@WT@"'

# ─── Git state that cannot be read ────────────────────────────────────────────

git_keep_unknown() { [ "$(_cc_wj_git_keep "$TMPDIR_ROOT/not-a-repo")" = "unknown" ]; }
expect_yes "a git state probe that fails answers unknown, not clean" git_keep_unknown

# ─── A negation or a character class in a declaration ────────────────────────

NEG_ROOT="$TMPDIR_ROOT/negation"
mkdir -p "$NEG_ROOT"
git init -q --bare "$NEG_ROOT/origin.git" -b main
git clone -q "$NEG_ROOT/origin.git" "$NEG_ROOT/primary" 2>/dev/null
ngit() { git -C "$NEG_ROOT/primary" -c user.email=t@t -c user.name=t "$@"; }
printf 'logs/\n' > "$NEG_ROOT/primary/.gitignore"
# Written the way a .gitignore author writes it: everything in logs, except the notes.
printf 'logs\n!logs/keep.md\n' > "$NEG_ROOT/primary/.worktree-regenerable"
ngit add -A; ngit commit -qm base; ngit push -q origin main
ngit worktree add -q "$NEG_ROOT/wt-neg" -b neg origin/main 2>/dev/null
mkdir -p "$NEG_ROOT/wt-neg/logs"; echo keep > "$NEG_ROOT/wt-neg/logs/keep.md"
OUT_NEG="$TMPDIR_ROOT/out-negation.txt"
_wj_idle --repo "$NEG_ROOT/primary" > "$OUT_NEG"
expect_yes "a declaration file with a negation is not applied at all" \
  file_after "$OUT_NEG" "wt-neg$" 2 "KEEP(unrebuildable=1)"
expect_yes "and the run says why" \
  file_has "$OUT_NEG" "negation"

class_dropped() {
  [ -z "$(printf '[[:alpha:]][[:alpha:]]*\n[!]][!]]*\n[]]x*\n*[!]]]*\n(*|ab)\n(|ab)*\nab^*\nab~x*\n<1->ab*\n' | _cc_wj_names_a_path 1)" ] &&
    [ "$(printf 'logs/*.log\nmodel/one-api.db\n' | _cc_wj_names_a_path 1 | wc -l | tr -d ' ')" = 2 ]
}
expect_yes "a pattern with any bracket expression names no path, and ordinary ones still do" class_dropped

# ─── Sourced from zsh ─────────────────────────────────────────────────────────

if command -v zsh >/dev/null 2>&1; then
  # `$base:r` is a zsh modifier: "+refs/heads/$base:refs/..." fetched `mainefs/...`.
  zsh_fetches_base() {
    zsh -c 'source "$1" >/dev/null 2>&1; _cc_wj_prepare_base "$2" >/dev/null 2>&1; [ "$_CC_WJ_BASE_OK" = 1 ]' \
      _ "$WJ" "$IDLE_PRIMARY"
  }
  expect_yes "sourced from zsh, the base branch fetches" zsh_fetches_base
  zsh_report_is_clean() {
    local out
    out="$(CC_WJ_KEEP_PATH=/nonexistent PATH="$STUBS_IDLE:$PATH" \
      zsh -c 'source "$1" >/dev/null 2>&1; _cc_wj_run --repo "$2"' _ "$WJ" "$IDLE_PRIMARY" 2>&1)"
    # More than one worktree, or there is no second pass to print on.
    [ "$(printf '%s\n' "$out" | grep -c '^  WORKTREE')" -ge 2 ] || return 1
    # Positive control: the report ran and reached its summary.
    printf '%s\n' "$out" | grep -q '^Summary:' || return 1
    ! printf '%s\n' "$out" | grep -q '^[a-z_]*='
  }
  expect_yes "sourced from zsh, the report prints no stray variable assignments" zsh_report_is_clean
  zsh_session_refuses() {
    local out
    out="$(zsh -c 'source "$1" >/dev/null 2>&1; _cc_wj_run --session' _ "$WJ" 2>&1 </dev/null)"
    printf '%s\n' "$out" | grep -q "requires bash"
  }
  expect_yes "sourced from zsh, --session refuses rather than exec a wrong path" zsh_session_refuses
fi

# ─── The session's cwd comes from its hook input too ─────────────────────────

sgit worktree add -q "$S_ROOT/wt-cwd" -b cwd origin/main 2>/dev/null
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
printf '{"session_id":"x","hook_event_name":"SessionEnd","cwd":"%s","reason":"exit"}\n' "$S_ROOT/wt-cwd" |
  CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
expect_yes "the session sweep ran to its end" wait_session_end $((before_ends + 1))
last_sweep_says() {
  local section
  section="$(awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG")"
  printf '%s\n' "$section" | grep -A 2 -- "$1\$" > "$TMPDIR_ROOT/last-sweep.txt"
  grep -q -- "$2" "$TMPDIR_ROOT/last-sweep.txt"
}
expect_yes "the worktree named by the hook input's cwd is kept" \
  bash -c 'test -d "$1"' _ "$S_ROOT/wt-cwd"
expect_yes "and its own sweep reports it as this session's" \
  last_sweep_says "wt-cwd" "KEEP(this-session)"

# ─── Review round 3 ───────────────────────────────────────────────────────────

# Hook input: an open pipe must not hold the SessionEnd hook for longer than the bounded
# read, with or without perl.
session_stdin_bounded() {
  local start end
  start=$(date +%s)
  CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_OUTSIDE" \
    PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session < <(sleep 8)
  end=$(date +%s)
  [ $((end - start)) -lt 5 ]
}
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
expect_yes "an open stdin pipe does not hold the session launcher" session_stdin_bounded
expect_yes "the session sweep ran to its end" wait_session_end $((before_ends + 1))

# A cwd the parser cannot read means the session's own worktree is unknown: report only.
sgit worktree add -q "$S_ROOT/wt-unparsed" -b unparsed origin/main 2>/dev/null
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
printf '{"session_id":"x","cwd":"%s\\"quoted","reason":"exit"}\n' "$S_ROOT/wt-unparsed" |
  CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
expect_yes "the session sweep ran to its end" wait_session_end $((before_ends + 1))
expect_yes "an unparseable hook cwd turns the session sweep into a report" \
  bash -c 'test -d "$1"' _ "$S_ROOT/wt-unparsed"
awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG" > "$TMPDIR_ROOT/unparsed-sweep.txt"
expect_yes "and says why" file_has "$TMPDIR_ROOT/unparsed-sweep.txt" "no cwd could be parsed from the hook input"

# Names lsof spelled that could not be decoded: a non-ASCII or backslash path cannot be
# matched, so it is held; a plain one is still matched honestly.
UNDEC="$TMPDIR_ROOT/undecoded"
mkdir -p "$UNDEC"
printf '/elsewhere\n' > "$UNDEC/cwd"
printf '/elsewhere/x\n' > "$UNDEC/open"
expect_yes "undecoded names hold a non-ASCII path" _cc_wj_held "$UNDEC" "/nowhere/caf$(printf '\303\251')"
expect_yes "undecoded names hold a backslash path" _cc_wj_held "$UNDEC" '/nowhere/a\b'
expect_no "undecoded names do not hold a plain unmatched path" _cc_wj_held "$UNDEC" "/nowhere/plain"
: > "$UNDEC/decoded"
expect_no "decoded names do not hold a non-ASCII path nobody has" _cc_wj_held "$UNDEC" "/nowhere/caf$(printf '\303\251')"
# lsof spells a control character as `^A`, which no decoding turns back into the byte.
printf '/nowhere/a^Ab\n' >> "$UNDEC/cwd"
expect_yes "a path with a control character is held even when names were decoded" \
  _cc_wj_held "$UNDEC" "/nowhere/a$(printf '\001')b"

# A git that cannot list worktrees - older than 2.36, or failing - is not an empty repository.
REAL_GIT="$(command -v git)"
GIT_STUBS="$TMPDIR_ROOT/stubs-git"
mkdir -p "$GIT_STUBS"
GIT_ARGS_LOG="$TMPDIR_ROOT/git-args.log"
export GIT_ARGS_LOG REAL_GIT
cat > "$GIT_STUBS/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_ARGS_LOG"
case " $* " in
  *" worktree list "*) [ -n "${GIT_FAIL_LIST:-}" ] && { echo "error: unknown switch \`z'" >&2; exit 129; } ;;
esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$GIT_STUBS/git"
: > "$GIT_ARGS_LOG"
LIST_RC=0
GIT_FAIL_LIST=1 PATH="$GIT_STUBS:$STUBS_IDLE:$PATH" bash "$WJ" --repo "$S_PRIMARY" > "$TMPDIR_ROOT/out-nolist.txt" 2>&1 || LIST_RC=$?
expect_yes "a repository whose worktrees cannot be listed fails the run" test "$LIST_RC" -ne 0
expect_yes "and is named" file_has "$TMPDIR_ROOT/out-nolist.txt" "could not list the worktrees of"

# The report's fetch must not start git's automatic maintenance, whose gc prunes worktree
# records - a removal in a mode that removes nothing.
expect_yes "the base fetch disables automatic maintenance" \
  bash -c 'grep " fetch " "$1" | grep -q -- "--no-auto-maintenance"' _ "$GIT_ARGS_LOG"

# ─── Review round 4 ───────────────────────────────────────────────────────────

# bash 3.2's `read -t` discards what it read when it times out, so a hook that writes its
# JSON and leaves the pipe open delivered no cwd - and the session's worktree lost its keep.
sgit worktree add -q "$S_ROOT/wt-open" -b open-pipe origin/main 2>/dev/null
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
{ printf '{"session_id":"x","cwd":"%s","reason":"exit"}\n' "$S_ROOT/wt-open"; sleep 4; } |
  CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
expect_yes "the session sweep ran to its end" wait_session_end $((before_ends + 1))
awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG" > "$TMPDIR_ROOT/open-sweep.txt"
expect_yes "hook input written to a pipe left open still keeps its cwd" \
  bash -c 'test -d "$1"' _ "$S_ROOT/wt-open"
expect_yes "and that cwd was read, not lost to a timeout" \
  bash -c '! grep -q "no cwd could be parsed" "$1" && grep -A 2 -- "wt-open\$" "$1" | grep -q "KEEP(this-session)"' \
    _ "$TMPDIR_ROOT/open-sweep.txt"

# The parser took the last "cwd" in the input, so a nested one replaced the top-level cwd,
# non-empty, and nothing flagged it. Which one is top-level cannot be told without parsing
# JSON, so two of them - in either order - are not trusted.
sgit worktree add -q "$S_ROOT/wt-twice" -b twice origin/main 2>/dev/null
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
printf '{"extra":{"cwd":"%s"},"cwd":"%s"}\n' "$S_PRIMARY" "$S_ROOT/wt-twice" |
  CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
expect_yes "the session sweep ran to its end" wait_session_end $((before_ends + 1))
awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG" > "$TMPDIR_ROOT/twice-sweep.txt"
expect_yes "hook input naming cwd twice is not trusted" \
  bash -c 'test -d "$1" && grep -q "no cwd could be parsed" "$2"' _ "$S_ROOT/wt-twice" "$TMPDIR_ROOT/twice-sweep.txt"

# Hook input that could not be read at all is not a session without a worktree of its own.
sgit worktree add -q "$S_ROOT/wt-silent" -b silent origin/main 2>/dev/null
before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
  PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session </dev/null
expect_yes "and that sweep ran to its end" wait_session_end $((before_ends + 1))
awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG" > "$TMPDIR_ROOT/silent-sweep.txt"
expect_yes "a non-terminal stdin without a cwd turns the session sweep into a report" \
  bash -c 'test -d "$1" && grep -q "no cwd could be parsed" "$2"' _ "$S_ROOT/wt-silent" "$TMPDIR_ROOT/silent-sweep.txt"

# ─── Review round 5 ───────────────────────────────────────────────────────────

# Each applying sweep below would remove a fresh landed worktree if the session's own
# checkout were not in doubt, so a kept one shows the sweep only reported.
# A kept worktree alone would also pass for a sweep that died before judging anything, so
# the sweep must also have ended - wait_session_end counts its own end line - and said why
# it only reported.
session_reports_for() {
  local name="$1" json="$2" why="$3" wt="$S_ROOT/wt-$1" section
  sgit worktree add -q "$wt" -b "r5-$name" origin/main 2>/dev/null
  before_ends="$(grep -c 'session sweep ended' "$S_LOG" 2>/dev/null)"
  printf '%s\n' "${json//@WT@/$wt}" |
    CC_WJ_SESSION_APPLY=1 CC_WJ_SESSION_LOG="$S_LOG" CLAUDE_PROJECT_DIR="$S_PRIMARY" \
    PATH="$STUBS_IDLE:$PATH" bash "$WJ" --session
  wait_session_end $((before_ends + 1)) || return 1
  section="$(awk -v n="$before_ends" '/session sweep ended/ { c++ } c >= n' "$S_LOG")"
  case "$section" in *"$why"*) ;; *) return 1 ;; esac
  test -d "$wt"
}

in_dir() { (cd "$1" && shift && "$@"); }

# A relative cwd resolves against whatever directory the launcher happens to stand in -
# here a directory that exists and covers no worktree, so it would pass for a real cwd.
expect_yes "a relative hook cwd turns the session sweep into a report" \
  in_dir "$S_ROOT" session_reports_for relative '{"cwd":"."}' "no cwd could be parsed"

# The session stood in a directory it deleted before exiting: its worktree is still its own.
expect_yes "a hook cwd that no longer exists turns the session sweep into a report" \
  session_reports_for gone '{"cwd":"@WT@/build-deleted"}' "does not resolve"

# Input longer than a SessionEnd payload is not read to the end: bash 3.2 appends each
# character in quadratic time and 70K bytes took 77 seconds, past the hook's deadline.
# The cwd comes first, so what is cut off is where a second "cwd" would have been seen.
long_input_bounded() {
  local pad start end
  pad="$(printf '%09000d' 0)"
  start=$(date +%s)
  session_reports_for long "{\"cwd\":\"$S_PRIMARY\",\"pad\":\"$pad\"}" "no cwd could be parsed" || return 1
  end=$(date +%s)
  [ $((end - start)) -lt 20 ]
}
expect_yes "hook input past the size bound is not trusted" long_input_bounded

# ─── Final result ─────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
  printf "%d test failure(s)\n" "$failures"
  exit 1
fi

printf "worktree-janitor: all tests passed\n"
