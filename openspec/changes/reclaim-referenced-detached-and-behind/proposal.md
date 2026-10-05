## Why
On 2026-10-05, the stima-api worktrees held 20 KEEP(unlanded) trees (16 GB), with free disk at 30 GB against the CI's 20 GB floor. Two kinds had nothing left to keep:
- **Behind a merged head.** The branch checkout is one push behind its own pushed head, and that head was squash-merged.
- **Contained detached HEAD.** A detached HEAD, idle more than 7 days, contained in branches or remote refs.

## What Changes
- **Landed:** a branch checkout whose HEAD is a strict ancestor of `refs/remotes/origin/<branch>`, where that pushed head passes the merged-PR proof, counts as landed by PR.
- **Detached HEAD removal:**
  - A detached HEAD contained in a branch, tag or remote-tracking ref passes the detached-head gate.
  - After the abandon window it counts as abandoned.
  - Before removal it is pinned as `refs/cc-reaper/detached/<sha>`.
- **Operation in progress:** a worktree with a rebase, bisect, merge, cherry-pick or revert in progress is kept.
