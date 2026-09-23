## ADDED Requirements

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
  before another selected directory is removed
- **THEN** the janitor keeps the remaining directory and reports the recheck reason
