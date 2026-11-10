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

# A tracked file under a gitignored directory, modified: ls-files lists it, and add must not
# re-judge it against .gitignore ("paths are ignored ... Use -f"), which skipped the whole backup.
wt wign feat/2-tracked-under-ignored
mkdir -p "$WORK/wign/managed"; echo v1 > "$WORK/wign/managed/x"
git -C "$WORK/wign" add -f managed/x
git "${F[@]}" -C "$WORK/wign" commit -qm "track managed/x"
printf 'managed/\n' >> "$WORK/wign/.gitignore"
git "${F[@]}" -C "$WORK/wign" commit -qam "ignore managed/"
echo v2 > "$WORK/wign/managed/x"                 # tracked, modified, under an ignored dir
echo secret > "$WORK/wign/managed/untracked"     # untracked, ignored: must stay out
run
SI="$(rref refs/wip/macmini/feat/2-tracked-under-ignored)"
check "a modified tracked file under an ignored dir is backed up" \
  '[ -n "$SI" ] && [ "$(git --git-dir="$R" show "$SI:managed/x" 2>/dev/null)" = v2 ]'
check "an untracked ignored file beside it stays out of the snapshot" \
  '! git --git-dir="$R" show "$SI:managed/untracked" >/dev/null 2>&1'
check "the ignored-path add error is not logged" '! grep -q "add failed" "$WORK/out"'
age "$WORK/wign"                                 # idle from here on, so later counts hold

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
# worktree-janitor's pre-removal snapshot, <worktree>-<UTC stamp>, has no branch of that name
# and is the only copy of what the worktree held: the cleanup must never treat it as gone.
SNAP=refs/wip/macmini/old-worktree-20260101T000000Z
git -C "$P" push -q origin "$(git -C "$P" rev-parse HEAD):$SNAP"
rm -rf "$WIP_STATE_DIR"; WIP_GONE_GRACE_HOURS=0 run
check "a janitor pre-removal snapshot is never cleaned up as a gone branch" '[ -n "$(rref $SNAP)" ]'
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

# ---------------------------------------------------------------- the mtime gate (stima-api#7073)
GR="$WORK/gate-remote.git"; GP="$HOME/GitHub/gate"
git "${F[@]}" init -q --bare "$GR"; git "${F[@]}" init -q "$GP"; git -C "$GP" remote add origin "$GR"
mkdir -p "$GP/dir"; echo a > "$GP/a.txt"; echo d1 > "$GP/dir/d1.txt"; echo d2 > "$GP/dir/d2.txt"
git -C "$GP" add -A && git "${F[@]}" -C "$GP" commit -qm init && git -C "$GP" push -q origin main
git -C "$GP" worktree add -q -b feat/g1 "$WORK/g1" main
export WIP_REPOS="$GP" WIP_STATE_DIR="$WORK/gstate"
gref() { git --git-dir="$GR" rev-parse -q --verify refs/wip/macmini/feat/g1 2>/dev/null; }
gshow() { git --git-dir="$GR" show "$(gref):$1" 2>/dev/null; }
echo e1 > "$WORK/g1/a.txt"
run
G1="$(gref)"
check "gate: first run (no stamp) snapshots and pushes" '[ -n "$G1" ] && grep -q "pushed=1 unchanged=0 gated=0" "$WORK/out"'
check "gate: the done line carries took=Ns" 'grep -Eq "done: .* took=[0-9]+s" "$WORK/out"'
sleep 1
git -C "$GP" remote set-url origin "$WORK/nowhere.git"
run
check "gate: nothing changed means no snapshot and no ls-remote (an unreachable remote is not even tried)" \
  '[ "$(cat "$WORK/rc")" = 0 ] && ! grep -q "FAIL" "$WORK/out" && grep -q "pushed=0 unchanged=1 gated=1" "$WORK/out" && [ "$(gref)" = "$G1" ]'
git -C "$GP" remote set-url origin "$GR"
sleep 1; echo e2 > "$WORK/g1/a.txt"
run
check "gate: an edited file after the stamp is in the next snapshot" '[ "$(gshow a.txt)" = e2 ] && grep -q "pushed=1 .*gated=0" "$WORK/out"'
sleep 1; echo fresh > "$WORK/g1/dir/created.txt"
run
check "gate: a file created after the stamp is in the next snapshot" '[ "$(gshow dir/created.txt)" = fresh ]'
sleep 1; rm "$WORK/g1/dir/d1.txt"
run
check "gate: a file deleted after the stamp is gone from the next snapshot (directory mtime counts)" \
  '! git --git-dir="$GR" cat-file -e "$(gref):dir/d1.txt" 2>/dev/null && [ "$(gshow dir/d2.txt)" = d2 ]'
sleep 1; echo 1 > "$WIP_STATE_DIR/run-count"; run   # run 2: not a full run
check "gate: and then it is gated again" 'grep -q "pushed=0 unchanged=1 gated=1 gate-miss=0" "$WORK/out"'
# New commit: HEAD differs from the stamp, so no skip even with no newer file.
sleep 1; git "${F[@]}" -C "$WORK/g1" commit -q --allow-empty -m moved
run
check "gate: a HEAD that moved is not skipped" 'grep -q "gated=0" "$WORK/out" && [ "$(git --git-dir="$GR" rev-parse "$(gref)^1")" = "$(git -C "$WORK/g1" rev-parse HEAD)" ]'
# Seeded gate-miss: an edit whose mtime is older than the stamp (the gate cannot see it); the hourly full run must.
sleep 1; echo sneaky > "$WORK/g1/a.txt"; touch -t "$OLD" "$WORK/g1/a.txt"
run
check "gate: the seeded edit is invisible to a gated run" '[ "$(gshow a.txt)" = e2 ] && grep -q "gated=1" "$WORK/out"'
echo 5 > "$WIP_STATE_DIR/run-count"    # the next run is the sixth: a full run
run
check "gate: the full run snapshots all, finds the edit and logs gate-miss" \
  '[ "$(gshow a.txt)" = sneaky ] && grep -q "gate-miss $WORK/g1" "$WORK/out" && grep -q "gate-miss=1" "$WORK/out"'
check "gate: a miss arms the next six runs to snapshot all" '[ "$(cat "$WIP_STATE_DIR/full-remaining")" = 6 ]'
echo sneaky2 > "$WORK/g1/a.txt"; touch -t "$OLD" "$WORK/g1/a.txt"
run
check "gate: the run after a miss is a full run (gate off), and a second miss re-arms it" '[ "$(gshow a.txt)" = sneaky2 ] && grep -q "gated=0 gate-miss=1" "$WORK/out" && [ "$(cat "$WIP_STATE_DIR/full-remaining")" = 6 ]'
run
check "gate: a full run with no miss spends one of the armed runs and skips nothing" 'grep -q "pushed=0 unchanged=1 gated=0 gate-miss=0" "$WORK/out" && [ "$(cat "$WIP_STATE_DIR/full-remaining")" = 5 ]'
rm -rf "$WIP_STATE_DIR"; run; run
check "gate: WIP_GATE=0 never skips" 'WIP_GATE=0 run; grep -q "gated=0" "$WORK/out"'

# ---------------------------------------------------------------- review repairs (stima-api#7073)
# An edit made while the push runs is newer than the stamp, so the next round must take it.
MR="$WORK/mid-remote.git"; MP="$HOME/GitHub/mid"
git "${F[@]}" init -q --bare "$MR"; git "${F[@]}" init -q "$MP"; git -C "$MP" remote add origin "$MR"
echo a > "$MP/a.txt"; git -C "$MP" add -A && git "${F[@]}" -C "$MP" commit -qm init && git -C "$MP" push -q origin main
git -C "$MP" worktree add -q -b feat/mid "$WORK/m1" main
printf '#!/bin/sh\n/bin/sleep 1\necho during-push > "%s/m1/a.txt"\n/bin/sleep 1\n' "$WORK" > "$MP/.git/hooks/pre-push"
chmod +x "$MP/.git/hooks/pre-push"
export WIP_REPOS="$MP" WIP_STATE_DIR="$WORK/mstate"
mref() { git --git-dir="$MR" rev-parse -q --verify "$1" 2>/dev/null; }
echo before > "$WORK/m1/a.txt"; echo recent > "$WORK/m1/b.txt"  # b.txt keeps the worktree inside the recent window
run
rm -f "$MP/.git/hooks/pre-push"
check "mid-push: the first round pushed the content it snapshotted" \
  '[ "$(git --git-dir="$MR" show "$(mref refs/wip/macmini/feat/mid):a.txt")" = before ] && [ "$(cat "$WORK/m1/a.txt")" = during-push ]'
run
check "mid-push: an edit made during the push is not gated and is in the next round" \
  'grep -q "pushed=1 unchanged=0 gated=0" "$WORK/out" && [ "$(git --git-dir="$MR" show "$(mref refs/wip/macmini/feat/mid):a.txt")" = during-push ]'
sleep 1; run
check "mid-push: and then it is gated again" 'grep -q "pushed=0 unchanged=1 gated=1" "$WORK/out"'
# The gate also keys on the branch: a rename with the same HEAD is a new ref to back up.
git -C "$WORK/m1" branch -m feat/mid feat/mid2
run
check "gate: a branch renamed with the same HEAD is not gated and gets its own WIP ref" \
  'grep -q "gated=0" "$WORK/out" && [ -n "$(mref refs/wip/macmini/feat/mid2)" ]'
# --dry-run changes no state, a gate-miss included.
sleep 1; echo sneaky > "$WORK/m1/a.txt"; touch -t "$OLD" "$WORK/m1/a.txt"
echo 5 > "$WIP_STATE_DIR/run-count"; echo 0 > "$WIP_STATE_DIR/full-remaining"
run --dry-run
check "dry run: a gate-miss is reported but full-remaining is not armed" \
  'grep -q "gate-miss=1" "$WORK/out" && [ "$(cat "$WIP_STATE_DIR/full-remaining")" = 0 ] && [ "$(cat "$WIP_STATE_DIR/run-count")" = 5 ]'

# ---------------------------------------------------------------- what a tick costs
# The cleanup judges every WIP ref of the repository (2000+ on the Mac mini, 83 of a 161 s run), so
# it is hourly: a tick with work but a fresh cleanup stamp must not run it.
export WIP_STATE_DIR="$WORK/mstate"; unset WIP_GONE_GRACE_HOURS
git -C "$MP" update-ref refs/tmp/zz "$(git -C "$MP" rev-parse HEAD)"
git --git-dir="$MR" fetch -q "$MP" refs/tmp/zz:refs/wip/macmini/zz-gone
echo tick > "$WORK/m1/c.txt"
WIP_GONE_GRACE_HOURS=0 run
check "cost: a tick with a fresh cleanup stamp leaves the cleanup for the hour" \
  '[ -n "$(mref refs/wip/macmini/zz-gone)" ] && ! grep -q " deleted " "$WORK/out"'
touch -t "$OLD" "$WIP_STATE_DIR"/*.cleanup; echo tick2 > "$WORK/m1/c.txt"
WIP_GONE_GRACE_HOURS=0 run
check "cost: once the stamp is an hour old the cleanup runs and restamps" \
  '[ -z "$(mref refs/wip/macmini/zz-gone)" ] && grep -q "deleted mid refs/wip/macmini/zz-gone" "$WORK/out" && [ -n "$(find "$WIP_STATE_DIR"/*.cleanup -mmin -60)" ]'
# The primary checkout is on a skipped branch (main): its tree, which holds every nested
# worktree, is not walked to learn that. find is shimmed to log the directory it is given.
mkdir -p "$WORK/findbin"
printf '#!/bin/sh\necho "$1" >> "%s/find.log"\nexec /usr/bin/find "$@"\n' "$WORK" > "$WORK/findbin/find"
chmod +x "$WORK/findbin/find"; : > "$WORK/find.log"; echo tick3 > "$WORK/m1/c.txt"
PATH="$WORK/findbin:$PATH" run
check "cost: the walk reaches a worktree (shim sees it) but never the primary checkout on main" \
  'grep -qxF "$WORK/m1" "$WORK/find.log" && ! grep -qxF "$MP" "$WORK/find.log"'

echo "wip-backup: $PASSED passed, $FAILURES failed"
[ "$FAILURES" -eq 0 ]
