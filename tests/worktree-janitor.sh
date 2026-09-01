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
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

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

# ─── Stub setup ───────────────────────────────────────────────────────────────

STUBS_IDLE="$TMPDIR_ROOT/stubs-idle"
mkdir -p "$STUBS_IDLE"
OSASCRIPT_LOG="$TMPDIR_ROOT/osascript.log"

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

# lsof stub: no cwd output (idle)
cat > "$STUBS_IDLE/lsof" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUBS_IDLE/lsof"

# ─── Env wiring ───────────────────────────────────────────────────────────────

export CC_WJ_ROOT="$TMPDIR_ROOT"
export CC_WJ_LOG="$TMPDIR_ROOT/wj.log"
export CC_WJ_STATE_DIR="$TMPDIR_ROOT/state"
export CC_WJ_NOTIFY_MIN_GB=0
export CC_WJ_COOLDOWN_SECS=0

# ─── Runner helpers ───────────────────────────────────────────────────────────

_wj_idle() {
  PATH="$STUBS_IDLE:$PATH" bash "$ROOT_DIR/shell/worktree-janitor.sh" "$@" 2>&1
}

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

STUBS_ACTIVE="$TMPDIR_ROOT/stubs-active"
mkdir -p "$STUBS_ACTIVE"

# pgrep returns a single pid
cat > "$STUBS_ACTIVE/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "12345"
STUB
chmod +x "$STUBS_ACTIVE/pgrep"

# lsof reports that pid 12345 has cwd inside WT_CLEAN
cat > "$STUBS_ACTIVE/lsof" <<STUB
#!/usr/bin/env bash
if [ "\${2:-}" = "12345" ]; then
  printf "p12345\nn${WT_CLEAN}\n"
fi
exit 0
STUB
chmod +x "$STUBS_ACTIVE/lsof"

OUT3="$TMPDIR_ROOT/out3.txt"
PATH="$STUBS_ACTIVE:$STUBS_IDLE:$PATH" bash "$ROOT_DIR/shell/worktree-janitor.sh" \
  --repo "$PRIMARY" > "$OUT3" 2>&1

expect_yes "active-cwd: wt-clean is KEEP(active-session)" \
  file_after "$OUT3" "wt-clean" 4 "KEEP(active-session)"

# ─── Test 4: lsof failure → conservative KEEP ────────────────────────────────

STUBS_FAIL="$TMPDIR_ROOT/stubs-fail"
mkdir -p "$STUBS_FAIL"

cat > "$STUBS_FAIL/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "99999"
STUB
chmod +x "$STUBS_FAIL/pgrep"

cat > "$STUBS_FAIL/lsof" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUBS_FAIL/lsof"

OUT4="$TMPDIR_ROOT/out4.txt"
PATH="$STUBS_FAIL:$STUBS_IDLE:$PATH" bash "$ROOT_DIR/shell/worktree-janitor.sh" \
  --repo "$PRIMARY" > "$OUT4" 2>&1

expect_yes "lsof-fail: wt-clean conservatively KEEP(active-session)" \
  file_after "$OUT4" "wt-clean" 4 "KEEP(active-session)"

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
expect_no "apply: wt-residue directory removed (force-fallback)" \
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

PATH="$STUBS_IDLE:$PATH" bash "$ROOT_DIR/shell/worktree-janitor.sh" \
  --repo "$PRUNE_REPO" >/dev/null 2>&1

expect_yes "report-only leaves the administrative record for a missing worktree" \
  test -d "$ADMIN_DIR"

PATH="$STUBS_IDLE:$PATH" bash "$ROOT_DIR/shell/worktree-janitor.sh" \
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
  bash "$ROOT_DIR/shell/worktree-janitor.sh" --repo "$PRUNE_REPO" >/dev/null 2>&1

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
  bash -c 'CC_WJ_ROOT=/nope/does/not/exist bash "$1" >/dev/null 2>&1' _ "$ROOT_DIR/shell/worktree-janitor.sh"

expect_no "a root that exists and cannot be listed fails the run" \
  bash -c 'PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" >/dev/null 2>&1' \
    _ "$ROOT_DIR/shell/worktree-janitor.sh" "$BLIND_ROOT" "$FIND_STUB_WJ"

expect_yes "a denied root says so rather than reporting an empty scan" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1); printf "%s\\n" "$out" | grep -q "could not be listed\\|cannot be read"' \
    _ "$ROOT_DIR/shell/worktree-janitor.sh" "$BLIND_ROOT" "$FIND_STUB_WJ"

# The wording, not just the fact. A denial that says "needs Full Disk Access" without
# naming the binary is what sent a real grant to a terminal that already had one, while
# the binary launchd spawns stayed absent from the TCC database - measured 2026-09-01.
expect_yes "a denied root names the binary to grant, not a description" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1);
           printf "%s\\n" "$out" | grep -q "THIS binary: /" &&
           printf "%s\\n" "$out" | grep -q "Cmd-Shift-G" &&
           ! printf "%s\\n" "$out" | grep -q "the program in the plist"' \
    _ "$ROOT_DIR/shell/worktree-janitor.sh" "$BLIND_ROOT" "$FIND_STUB_WJ"

# The trade-off and the alternative travel with it, or the message reads as an
# instruction to grant rather than a decision to make. install.sh has said both since it
# was written; this is the copy the operator sees when it actually bites.
expect_yes "a denied root carries the trade-off and the alternative" \
  bash -c 'out=$(PATH="$3:$PATH" CC_WJ_ROOT="$2/denied" bash "$1" 2>&1);
           printf "%s\\n" "$out" | grep -q "EVERY bash script" &&
           printf "%s\\n" "$out" | grep -q "outside those three"' \
    _ "$ROOT_DIR/shell/worktree-janitor.sh" "$BLIND_ROOT" "$FIND_STUB_WJ"

expect_yes "roots are plural" \
  bash -c 'CC_WJ_ROOT="/nope/a:/nope/b" bash "$1" 2>&1 | grep -q "/nope/a,/nope/b"' \
    _ "$ROOT_DIR/shell/worktree-janitor.sh"


# ─── A detached HEAD is the one removal this script cannot undo ───────────────
#
# Removal takes the checkout and leaves the branch, so commits on a branch survive it
# whether or not a remote has them. On a detached HEAD nothing references them
# afterwards. The push state was already measured and printed here, and then never
# consulted by the classifier.

# `expect_yes` runs its command in this shell, so the classifier is sourced once here
# and called directly - no subshell to lose the function in.
# shellcheck source=../shell/worktree-janitor.sh
source "$ROOT_DIR/shell/worktree-janitor.sh"

classify_is() {
  local branch="$1" want="$2" got
  got="$(_cc_wj_classify /wt 0 no yes "$branch")"
  [ "$got" = "$want" ] || { printf "       got %s, want %s\n" "$got" "$want" >&2; return 1; }
}

expect_yes "a detached HEAD is kept" \
  classify_is "(detached)" "KEEP(detached-head)"

expect_yes "a clean idle branch is still removable" \
  classify_is "task/x" "REMOVABLE"

expect_yes "an unpushed branch is still removable — the branch keeps the commits" \
  classify_is "task/unpushed" "REMOVABLE"


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
         _ "$ROOT_DIR/shell/worktree-janitor.sh" "$R_ENV" 2>/dev/null)"
    z="$(zsh -c 'source "$1" >/dev/null 2>&1; _cc_wj_undiscounted_count "$2"' \
         _ "$ROOT_DIR/shell/worktree-janitor.sh" "$R_ENV" 2>/dev/null)"
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

# ─── Final result ─────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
  printf "%d test failure(s)\n" "$failures"
  exit 1
fi

printf "worktree-janitor: all tests passed\n"
