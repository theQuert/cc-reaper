## ADDED Requirements

### Requirement: Worktree inventory runs on a schedule, report-only
A LaunchAgent SHALL run the worktree inventory on a schedule in its default report-only
mode. The agent SHALL NOT pass `--apply`.

The reclaim hook derives its repository root from the session's working directory, so it
sweeps only the repository someone was sitting in. Nothing else crosses repositories. On
this host that left 83 live worktrees in one repository while a working cross-repo
inventory sat on disk with no agent to run it.

Removal stays a human decision: the inventory's own criteria cannot distinguish work that
was never pushed from work that was abandoned, and on this host 43 of 83 worktrees had a
HEAD that exists on no remote.

#### Scenario: Scheduled inventory runs
- **WHEN** the agent fires
- **THEN** the inventory SHALL run in report-only mode and SHALL delete nothing

#### Scenario: Inventory finds reclaimable worktrees
- **WHEN** the report identifies worktrees above the notification threshold
- **THEN** it SHALL surface them, and SHALL leave removal to an operator running `--apply`
