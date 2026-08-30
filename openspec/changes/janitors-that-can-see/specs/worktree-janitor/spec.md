## ADDED Requirements

### Requirement: The worktree inventory stays manual, and says why
The inventory SHALL NOT be installed as a LaunchAgent, and the installer SHALL state the
reason rather than leaving its absence to look like an oversight.

A LaunchAgent cannot read `~/Documents`. Measured 2026-08-30 with a probe agent loaded
through `launchctl bootstrap`: `ls ~/Documents/GitHub` returned `DENIED`, and
`git -C ~/Documents/GitHub/stima-api rev-parse` returned `fatal: Unable to read current
working directory: Operation not permitted`. `_cc_wj_root` defaults to
`$HOME/Documents/GitHub`, so a scheduled run would traverse nothing and report nothing —
a silent empty report, which is the failure shape this whole change exists to remove.

The gap it was meant to close stays open and is recorded as such: the reclaim hook
derives its root from the session's working directory, so nothing sweeps a repository
nobody is sitting in. On this host that left 83 live worktrees in one repository. Closing
it needs a TCC-capable host process, which this project does not have.

#### Scenario: Installing cc-reaper
- **WHEN** `install.sh` runs
- **THEN** it SHALL NOT install a worktree-report agent, and SHALL print that the inventory is manual and why

#### Scenario: An operator wants the inventory
- **WHEN** an operator runs `~/.cc-reaper/worktree-janitor.sh`
- **THEN** it SHALL report, and SHALL remove nothing without `--apply`

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

### Requirement: The runner bounds any launchd log pair written on its behalf
The runner SHALL bound the `launchd-worktree-report-{stdout,stderr}.log` pair, at the top of
every run, on the same terms as every other cc-reaper runner.

Kept although the agent that would write them is not installed: the bounding is where a
future scheduled or user-installed invocation needs it, and it costs two `stat` calls. It is
placed at the top of `_cc_wj_run` because a report-only run never reaches `_cc_wj_log_write`,
where bounding it would be unreachable for the only caller that produces those files.

#### Scenario: Either file crosses the cap
- **WHEN** the inventory runs and either file exceeds the cap
- **THEN** it SHALL be bounded the same way the runner bounds its own log

#### Scenario: Inventory finds reclaimable worktrees
- **WHEN** the report identifies worktrees above the notification threshold
- **THEN** it SHALL surface them, and SHALL leave removal to an operator running `--apply`
