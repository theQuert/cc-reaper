## 1. Holders and idleness

- [x] 1.1 Replace the `pgrep`-subset cwd scan with machine-wide `lsof -d cwd` and all-open-files scans, bounded; an empty or failed scan keeps everything
- [x] 1.2 Add `CC_WJ_IDLE_HOURS` (default 6) with up-front validation; a failed `find` keeps
- [x] 1.3 Red-verify: a worktree held only by an open file, and one touched a minute ago, are REMOVABLE against the pre-change script and KEEP after

## 2. Landed

- [x] 2.1 Resolve the base branch (override, `origin/HEAD`, `ls-remote --symref`), fetch it through an explicit refspec, report an unfetchable base once
- [x] 2.2 Ancestor, merge-tree content, and PR-head proofs; detached HEAD needs ancestry
- [x] 2.3 Keep locked worktrees and worktrees with a populated submodule
- [x] 2.4 Red-verify: an unlanded clean branch, a squash-merged branch, a PR landed after a revert, and a PR at a different head SHA

## 3. Contents

- [x] 3.1 Parse status with `-z`; name up to three pinning entries in the report
- [x] 3.2 Read `.worktree-regenerable` from the fetched base; drop and report patterns that name no path; walk collapsed directories up to 200 files
- [x] 3.3 Credential scan of declared directories and built-in caches
- [x] 3.4 Red-verify: declared byproduct discounted, branch-only declaration ignored, credential in a declared directory kept, `*` dropped

## 4. Session mode

- [x] 4.1 `--session`: fork-then-setsid launcher, per-repository lock with takeover, own-checkout keep, run record, apply only on `CC_WJ_SESSION_APPLY=1`
- [x] 4.2 Process-group timeout helper for lsof/fetch/ls-remote/gh
- [x] 4.3 Proof: the launcher returns before the sweep ends, a live lock blocks, a dead lock is taken over, report-only without opt-in, a hung command returns 124

## 5. Documentation

- [x] 5.1 `docs/worktree-reclamation.md`: the gates, why each exists, the five silent-nothing failures, the SessionEnd snippet
- [x] 5.2 README, CHANGELOG, CLAUDE.md test list, installer guidance

## 6. Proof

- [x] 6.1 Full `tests/worktree-janitor.sh` plus the repository's other suites, `bash -n`, `zsh -n`
- [x] 6.2 Report mode against real repositories on this host, read-only apart from the base fetch
- [ ] 6.3 Independent review of the candidate
