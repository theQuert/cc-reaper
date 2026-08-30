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

expect_yes "dirty: classified KEEP(dirty=...) in report mode" \
  file_after "$OUT1" "wt-dirty" 4 "KEEP(dirty="

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

# ─── Final result ─────────────────────────────────────────────────────────────

if [ "$failures" -gt 0 ]; then
  printf "%d test failure(s)\n" "$failures"
  exit 1
fi

printf "worktree-janitor: all tests passed\n"
