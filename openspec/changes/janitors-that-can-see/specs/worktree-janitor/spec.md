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

### Requirement: Report-only mode does not mutate the repository
Report mode SHALL NOT run `git worktree prune`. Removing administrative records is a
removal, and this tool's own contract is that removal requires `--apply`.

The report already prints `[cue: git worktree prune]` for a missing directory, so the
finding survives; only the unrequested action does not. Left ungated, the scheduled agent —
which never passes `--apply` — deleted metadata daily under the name "report-only".

#### Scenario: A worktree directory is missing during a report
- **WHEN** the inventory runs without `--apply` and finds a registered worktree whose directory is gone
- **THEN** it SHALL report the finding and the administrative record SHALL survive

#### Scenario: The same repository under --apply
- **WHEN** the inventory runs with `--apply`
- **THEN** the stale record SHALL be pruned, so the capability is gated rather than removed

### Requirement: The scheduled agent bounds its own launchd logs
The runner SHALL bound the `launchd-worktree-report-{stdout,stderr}.log` pair it causes
launchd to write, on the same terms as every other cc-reaper runner. Those files are opened
by launchd, so no script owns them unless one claims them, and the inventory prints roughly
three lines per worktree per run.

#### Scenario: The agent's log pair crosses the cap
- **WHEN** the inventory runs and either file exceeds the cap
- **THEN** it SHALL be bounded the same way the runner bounds its own log

#### Scenario: Inventory finds reclaimable worktrees
- **WHEN** the report identifies worktrees above the notification threshold
- **THEN** it SHALL surface them, and SHALL leave removal to an operator running `--apply`
