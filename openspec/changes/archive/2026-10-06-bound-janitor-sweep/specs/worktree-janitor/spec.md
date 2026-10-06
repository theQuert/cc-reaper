## ADDED Requirements

### Requirement: A sweep phase is bounded by a budget
Each phase of a removal run (the removal sweep, and the scheduled trim) SHALL stop examining
worktrees once it has run `CC_WJ_SWEEP_BUDGET_SECONDS` (default 1800; `0` means unbounded). A
phase that stops this way SHALL release the repository lock before the run moves on or exits,
SHALL log the budget, the elapsed seconds and the number of worktrees left unexamined, SHALL keep
every unexamined worktree, and SHALL NOT by itself make the run exit non-zero. A worktree whose
examination has started SHALL be finished, so a removal is never cut midway. A phase SHALL
examine at least one worktree before it may stop on budget, so a repository whose preparation
alone outlasts the budget still makes progress.

#### Scenario: Budget exhausted
- **WHEN** a scheduled sweep passes its budget with worktrees left to examine
- **THEN** it removes none of the worktrees it did not examine, releases the lock, logs `budget exhausted` with the counts, and exits 0

#### Scenario: Session sweep after a yield
- **WHEN** a session sweep starts after a scheduled sweep yielded on budget
- **THEN** it takes the lock instead of deferring

### Requirement: A bounded sweep rotates where it starts
The janitor SHALL record, per repository, the last worktree a phase examined in a cursor file
under `~/.cc-reaper/state/`, and the next run SHALL examine worktrees after that one first and
wrap around. It SHALL likewise record the last repository in which a phase examined a worktree before its
budget ran out, and the next run of that phase SHALL start with the repository after it. A missing or unreadable cursor SHALL start from the beginning. Report-only runs SHALL
NOT write the cursor.

#### Scenario: Next sweep resumes
- **WHEN** a sweep yielded after examining worktrees A and B of A, B, C, D
- **THEN** the next sweep examines C, D, A, B in that order

#### Scenario: Repositories rotate too
- **WHEN** a phase's budget ran out while repository R1 of R1, R2, R3 was being swept
- **THEN** the next run of that phase starts with R2, so a large first repository cannot keep the others from ever being examined

#### Scenario: Budget runs out while a repository is still being prepared
- **WHEN** a phase examined worktrees in R1, then its budget ran out during R2's fetch or inventory, before any R2 worktree was examined
- **THEN** the next run of that phase starts with R2

### Requirement: Scans have configurable timeouts and one retry
The machine-wide `lsof` holder scans SHALL use `CC_WJ_LSOF_TIMEOUT_SECONDS` (default 120) and the
Codex writer-lock registry scan `CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS` (default 30). A scan that times
out SHALL be retried once with the same timeout before it counts as failed; a failed scan keeps
its existing fail-closed meaning.

#### Scenario: Slow scan succeeds on retry
- **WHEN** the first holder scan times out and the retry succeeds
- **THEN** the sweep proceeds with the retry's snapshot

#### Scenario: Both attempts time out
- **WHEN** the scan and its retry both time out
- **THEN** every worktree is kept as for any failed scan

## MODIFIED Requirements

### Requirement: Worktree-preserving regenerable trim

The janitor SHALL support an explicit `--trim-regenerable` mode that reports, and only with
`--apply` removes, ignored directories from the built-in regenerable set while retaining the
worktree, branch, tracked content, untracked authored content, and non-regenerable ignored content.

#### Scenario: Trim report is read-only

- **WHEN** the janitor runs with `--trim-regenerable` without `--apply`
- **THEN** it lists candidate directories and byte estimates
- **AND** it does not remove a directory, worktree, branch, or git administrative record

#### Scenario: Active worktree is never trimmed

- **WHEN** a process holder, verified live Claude/Codex claim, recent-session lease, locked state,
  or unreadable safety probe names the worktree
- **THEN** the janitor keeps every regenerable directory in that worktree

#### Scenario: Apply trims only selected regenerable directories

- **WHEN** `--trim-regenerable --apply` has a clean, unlocked worktree with successful holder and
  harness scans and an ignored built-in regenerable directory without a credential-shaped file
- **THEN** that directory may be removed
- **AND** the worktree and branch remain present
- **AND** tracked, untracked authored, and non-regenerable ignored content remain present

#### Scenario: Claim appears before a later directory

- **WHEN** a holder or live/recent session claim appears after one cache directory was trimmed but
  before another selected directory is removed, and the holder and session snapshot is older
  than `CC_WJ_RECHECK_FRESH_SECONDS` (default 120)
- **THEN** the janitor rescans, keeps the remaining directory, and reports the recheck reason

#### Scenario: A fresh snapshot is reused
- **WHEN** a later cache directory in the same worktree is about to be removed and the holder and
  session snapshot is younger than `CC_WJ_RECHECK_FRESH_SECONDS`
- **THEN** the janitor rechecks that worktree against the existing snapshot without rescanning the machine
