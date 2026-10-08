#!/usr/bin/env bash
# wip-backup.sh against a real bare remote: what a snapshot holds, that it leaves the
# worktree alone, when it pushes, and which WIP refs it deletes. lsof is stubbed.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${WIP_SCRIPT:-$REPO_ROOT/shell/wip-backup.sh}"
FAILURES=0; PASSED=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok: $1"; PASSED=$((PASSED + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/test-wip.XXXXXX")" && pwd -P)" || exit 1
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/GitHub" "$WORK/bin"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
F=(-c user.name=Fixture -c user.email=fixture@example.com -c init.defaultBranch=main)
OLD="$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)"

# lsof stub: prints the cwd lines listed in $WORK/live, in lsof -Fn form.
cat > "$WORK/bin/lsof" <<'STUB'
#!/bin/sh
[ -f "$WIP_TEST_LIVE" ] || exit 1
while IFS= read -r d; do echo "p4242"; echo "n$d"; done < "$WIP_TEST_LIVE"
STUB
chmod +x "$WORK/bin/lsof"
export WIP_LSOF="$WORK/bin/lsof" WIP_TEST_LIVE="$WORK/live" WIP_MAX_MB=1 WIP_CONF="$WORK/none.conf"

R="$WORK/remote.git"; P="$HOME/GitHub/proj"
git "${F[@]}" init -q --bare "$R"
git "${F[@]}" init -q "$P"
git -C "$P" remote add origin "$R"
printf 'ignored.log\n' > "$P/.gitignore"
echo one > "$P/a.txt"; echo two > "$P/b.txt"; echo keep > "$P/c.txt"
git -C "$P" add -A && git "${F[@]}" -C "$P" commit -qm init && git -C "$P" push -q origin main
git -C "$P" remote set-head origin main >/dev/null 2>&1 || git -C "$P" fetch -q origin
git -C "$P" fetch -q origin && git -C "$P" remote set-head origin main >/dev/null

wt() {  # name branch: a linked worktree on a new branch
  git -C "$P" worktree add -q -b "$2" "$WORK/$1" main
}
age() { find "$1" -name .git -prune -o -type f -exec touch -t "$OLD" {} +; }
run() { "$SCRIPT" "$@" > "$WORK/out" 2>&1; echo $? > "$WORK/rc"; cat "$WORK/out" >> "$WORK/all"; }
rref() { git --git-dir="$R" rev-parse -q --verify "$1" 2>/dev/null; }
refs() { git --git-dir="$R" for-each-ref --format='%(refname)' | sort; }

# ---------------------------------------------------------------- snapshot contents
wt w1 feat/1-active
echo changed > "$WORK/w1/a.txt"                  # unstaged edit
echo staged > "$WORK/w1/c.txt"; git -C "$WORK/w1" add c.txt   # staged edit
git -C "$WORK/w1" rm -q b.txt                    # staged deletion
echo new > "$WORK/w1/new.txt"                    # untracked
mkdir -p "$WORK/w1/sub"; echo deep > "$WORK/w1/sub/deep.txt"
echo noise > "$WORK/w1/ignored.log"              # ignored
head -c 2000000 /dev/zero > "$WORK/w1/big.bin"   # over WIP_MAX_MB=1
status_before="$(git -C "$WORK/w1" status --porcelain=v1 | sort)"
index_before="$(git -C "$WORK/w1" ls-files -s | cksum)"
before="$(refs)"
run
REF=refs/wip/macmini/feat/1-active
S="$(rref $REF)"
check "an active worktree is pushed to refs/wip/macmini/<branch>" '[ -n "$S" ] && [ "$(cat "$WORK/rc")" = 0 ]'
show() { git --git-dir="$R" show "$S:$1" 2>/dev/null; }
check "the snapshot holds unstaged, staged and untracked changes" \
  '[ "$(show a.txt)" = changed ] && [ "$(show c.txt)" = staged ] && [ "$(show new.txt)" = new ] && [ "$(show sub/deep.txt)" = deep ]'
check "a deleted file is gone from the snapshot" '! show b.txt >/dev/null'
check "ignored and oversized files are left out" '! show ignored.log >/dev/null && ! show big.bin >/dev/null'
check "the oversized file is logged" 'grep -q "skip file over 1 MB: .*big.bin" "$WORK/out"'
check "the snapshot's parent is the worktree HEAD" \
  '[ "$(git --git-dir="$R" rev-parse "$S^1")" = "$(git -C "$WORK/w1" rev-parse HEAD)" ]'
check "the worktree, its index and its branches are untouched" \
  '[ "$(git -C "$WORK/w1" status --porcelain=v1 | sort)" = "$status_before" ] && [ "$(git -C "$WORK/w1" ls-files -s | cksum)" = "$index_before" ] && [ -z "$(git -C "$WORK/w1" stash list)" ]'
check "nothing but refs/wip/macmini/* changed on the remote" \
  '[ "$(refs | grep -v ^refs/wip/macmini/)" = "$(echo "$before" | grep -v ^refs/wip/macmini/)" ]'
check "the main checkout (main) is skipped" '[ -z "$(rref refs/wip/macmini/main)" ]'

# ---------------------------------------------------------------- push only on change
run
check "an unchanged snapshot is not pushed again" '[ "$(rref $REF)" = "$S" ] && grep -q "pushed=0 unchanged=1" "$WORK/out"'
echo again > "$WORK/w1/a.txt"
run
check "a change is pushed as a new snapshot" '[ "$(rref $REF)" != "$S" ] && [ "$(git --git-dir="$R" show "$(rref $REF):a.txt")" = again ]'

# ---------------------------------------------------------------- what counts as active
wt w2 feat/2-idle
echo idle-work > "$WORK/w2/a.txt"; age "$WORK/w2"
run
check "an idle worktree with no live session is not pushed" '[ -z "$(rref refs/wip/macmini/feat/2-idle)" ]'
mkdir -p "$WORK/w2/deeper"; touch -t "$OLD" "$WORK/w2/deeper"
echo "$WORK/w2/deeper" > "$WORK/live"
run
check "a live claude cwd inside a worktree makes it active" \
  '[ -n "$(rref refs/wip/macmini/feat/2-idle)" ] && grep -q "feat/2-idle .*(live session)" "$WORK/out"'
: > "$WORK/live"
wt w3 feat/3-clean
git -C "$WORK/w3" push -q origin feat/3-clean; touch "$WORK/w3/a.txt"
run
check "a clean worktree whose HEAD is pushed needs no WIP ref" '[ -z "$(rref refs/wip/macmini/feat/3-clean)" ]'

# ---------------------------------------------------------------- dry run
echo dry > "$WORK/w1/a.txt"; S="$(rref $REF)"
run --dry-run
check "--dry-run pushes nothing and says what it would" '[ "$(rref $REF)" = "$S" ] && grep -q "would push proj $REF" "$WORK/out"'
run

# ---------------------------------------------------------------- deleting WIP refs
export WIP_STATE_DIR="$WORK/state"
# merged: the branch landed on main and its worktree is gone; the local branch stays.
wt w4 feat/4-merged
echo landed > "$WORK/w4/d.txt"; git -C "$WORK/w4" add d.txt; git "${F[@]}" -C "$WORK/w4" commit -qm landed
echo wip > "$WORK/w4/e.txt"; git -C "$WORK/w4" push -q origin feat/4-merged
run
check "setup: feat/4-merged has a WIP ref" '[ -n "$(rref refs/wip/macmini/feat/4-merged)" ]'
git -C "$P" push -q origin feat/4-merged:main && git -C "$P" fetch -q origin
git -C "$P" worktree remove --force "$WORK/w4"
# gone, but local: the branch exists locally only and has no worktree.
wt w5 feat/5-local
echo local > "$WORK/w5/a.txt"; run
git -C "$P" worktree remove --force "$WORK/w5"
# gone everywhere: worktree, local branch and remote branch all removed.
wt w6 feat/6-gone
echo gone > "$WORK/w6/a.txt"; run
git -C "$P" worktree remove --force "$WORK/w6"; git -C "$P" branch -q -D feat/6-gone
rm -rf "$WIP_STATE_DIR"
run
check "a merged branch's WIP ref is deleted" '[ -z "$(rref refs/wip/macmini/feat/4-merged)" ] && grep -q "deleted proj refs/wip/macmini/feat/4-merged (merged into origin/main)" "$WORK/all"'
check "a gone branch's snapshot is kept through the grace period" '[ -n "$(rref refs/wip/macmini/feat/6-gone)" ]'
check "a branch that still exists locally keeps its WIP ref" '[ -n "$(rref refs/wip/macmini/feat/5-local)" ]'
check "a branch with a worktree keeps its WIP ref" '[ -n "$(rref $REF)" ]'
check "no branch was deleted by the cleanup" '[ -n "$(rref refs/heads/feat/4-merged)" ] && git -C "$P" show-ref -q --verify refs/heads/feat/4-merged'
rm -rf "$WIP_STATE_DIR"
WIP_GONE_GRACE_HOURS=0 run
check "after the grace a gone branch's WIP ref is deleted" '[ -z "$(rref refs/wip/macmini/feat/6-gone)" ] && [ -n "$(rref refs/wip/macmini/feat/5-local)" ]'
# A live session in a worktree whose branch is merged keeps the ref.
git -C "$P" worktree add -q "$WORK/w4b" feat/4-merged
echo more > "$WORK/w4b/f.txt"; echo "$WORK/w4b" > "$WORK/live"; run; : > "$WORK/live"
age "$WORK/w4b"; rm -rf "$WIP_STATE_DIR"; run
check "a worktree on a merged branch keeps its WIP ref" '[ -n "$(rref refs/wip/macmini/feat/4-merged)" ]'
run
check "an idle machine with a fresh cleanup stamp makes no remote call" \
  'git -C "$P" remote set-url origin "$WORK/nowhere.git"; age "$WORK/w1"; age "$WORK/w2"; age "$WORK/w3"; run; [ "$(cat "$WORK/rc")" = 0 ]'
rm -rf "$WIP_STATE_DIR"; run
check "an unreachable remote is one FAIL line and exit 1" '[ "$(cat "$WORK/rc")" = 1 ] && grep -q "FAIL ls-remote proj" "$WORK/out"'

echo "wip-backup: $PASSED passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
