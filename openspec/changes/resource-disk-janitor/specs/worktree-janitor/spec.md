# worktree-janitor Specification (delta)

## ADDED Requirements

### Requirement: Multi-repo worktree inventory
The janitor SHALL discover git worktrees from a configurable repo list (default: every git repo directly under `~/Documents/GitHub/`) and classify each worktree as KEEP or REMOVABLE with a stated reason.

#### Scenario: Inventory run
- **WHEN** the janitor runs in report mode
- **THEN** every non-primary worktree is listed with: dirty file count, branch, ahead-of-origin/main count, push state, active-process state, and final classification

### Requirement: Dual safety gate for removal
A worktree SHALL be classified REMOVABLE only when BOTH gates pass: (1) `git status --porcelain` is empty (dirty=0), and (2) no running process has its cwd inside the worktree (checked via `lsof`/`ps`). Branches and commits are never deleted — only the working directory.

#### Scenario: Dirty worktree
- **WHEN** a worktree has any uncommitted or untracked (non-ignored) change
- **THEN** it is classified KEEP with reason `dirty=<n>` and is never removed, even with `--apply --force`

#### Scenario: Active session in clean worktree
- **WHEN** a worktree is clean but a process cwd resolves inside it
- **THEN** it is classified KEEP with reason `active-session` and is never removed

#### Scenario: Clean idle worktree
- **WHEN** a worktree has dirty=0 and no active process cwd
- **THEN** it is classified REMOVABLE; removal uses `git worktree remove` (falling back to `--force` only when the residue is ignored files such as node_modules), followed by `git worktree prune`

### Requirement: Dry-run by default
The janitor SHALL default to report-only mode; deletion SHALL occur only with an explicit `--apply` flag. The scheduled (launchd) invocation SHALL always run report mode and SHALL never pass `--apply`.

#### Scenario: Default invocation
- **WHEN** the janitor runs with no flags
- **THEN** it prints/logs the classification report and removes nothing

#### Scenario: Explicit apply
- **WHEN** the user runs `worktree-janitor --apply`
- **THEN** only REMOVABLE worktrees are removed, each removal is logged, and a summary (removed count, reclaimed bytes, kept count with reasons) is printed

#### Scenario: Scheduled run cannot delete
- **WHEN** the launchd-scheduled invocation runs
- **THEN** it is report mode unconditionally; if the report contains REMOVABLE worktrees above a configurable size threshold, a (cooldown-gated) notification suggests running `worktree-janitor --apply`
