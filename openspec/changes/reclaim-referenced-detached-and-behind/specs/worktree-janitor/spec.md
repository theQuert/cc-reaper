## MODIFIED Requirements

### Requirement: Detached HEAD
A detached HEAD SHALL be removable only when it is landed by ancestry, or when a ref under
`refs/heads`, `refs/tags` or `refs/remotes` contains it. A contained detached HEAD that has not
landed SHALL count as abandoned once nothing under it changed within `CC_WJ_ABANDON_HOURS`.
Immediately before removing a detached HEAD not landed by ancestry, the janitor SHALL write
`refs/cc-reaper/detached/<sha>` pointing at it and log the SHA; if that write fails the
worktree SHALL be kept.

#### Scenario: Detached HEAD landed by content only
- **WHEN** a detached HEAD is landed by content or PR, not by ancestry, and no ref contains it
- **THEN** it is classified KEEP with reason `detached-head`

#### Scenario: Detached HEAD a ref contains
- **WHEN** an idle, clean, unheld, unclaimed detached HEAD is contained in a branch, tag or remote-tracking ref
- **THEN** it is classified REMOVABLE, and `--apply` pins it under `refs/cc-reaper/detached/` before removing the checkout

## ADDED Requirements

### Requirement: A checkout behind its merged pushed head has landed
When HEAD is on a branch and is a strict ancestor of `refs/remotes/origin/<branch>`, and that
commit passes the merged-pull-request proof (merged, base is the base branch, merge commit
contained in the fetched base), the worktree SHALL count as landed by PR.

#### Scenario: One push behind a squash-merged head
- **WHEN** a branch checkout is one commit behind its pushed head, which a pull request merged into the base
- **THEN** it is landed by PR

### Requirement: An operation in progress keeps the worktree
A worktree whose git directory holds `rebase-merge`, `rebase-apply`, `BISECT_LOG`, `MERGE_HEAD`,
`CHERRY_PICK_HEAD` or `REVERT_HEAD` SHALL be classified KEEP with reason `in-progress`.

#### Scenario: Rebase in progress
- **WHEN** a worktree is mid-rebase
- **THEN** it is classified `KEEP(in-progress)`, whatever the other gates say
