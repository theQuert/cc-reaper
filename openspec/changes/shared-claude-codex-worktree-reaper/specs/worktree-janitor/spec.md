# worktree-janitor Delta Specification

## ADDED Requirements

### Requirement: Attached-resource reapers share landed policy

The system SHALL expose a read-only single-worktree query that uses the same ancestry,
content-equivalence, and exact-head merged-PR proofs as worktree reclamation.

#### Scenario: A squash-merged stack is no longer retained by ancestry-only logic
- **WHEN** a resource reaper queries a worktree whose content landed with a different commit
- **THEN** the query succeeds and reports `content`
- **AND** the query does not remove the worktree

### Requirement: Active harness session veto

No verified active Claude or Codex session may claim a removable worktree by cwd or by a
structured tool-call input in its current two human user turns. Stale registry artifacts SHALL NOT become claims, and an
unmappable verified-live claim SHALL make the destructive run fail closed.

#### Scenario: Active Claude session
- **WHEN** a live PID-named Claude session record maps to a worktree, or its unique transcript contains a structured tool call naming that worktree
- **THEN** the worktree is kept with an active Claude reason

#### Scenario: Active Codex task
- **WHEN** an open Codex thread writer lock maps to a worktree, or its rollout contains a structured tool call naming that worktree
- **THEN** the worktree is kept with an active Codex reason

#### Scenario: Stale registry artifact
- **WHEN** a Claude PID record is dead or reused, or a Codex lock file exists but is not open
- **THEN** that artifact alone does not claim a worktree

#### Scenario: Live claim cannot be mapped
- **WHEN** a verified live record cannot be parsed or mapped uniquely to cwd and transcript
- **THEN** no worktree is removed and the run states which claim was unknowable

#### Scenario: Session starts during a sweep
- **WHEN** a session claim appears after classification but before removal
- **THEN** the janitor's pre-removal refresh keeps the worktree

#### Scenario: Codex task archives while its claim is inspected
- **WHEN** a Codex writer lock closes and its rollout moves to the archive while the janitor is inspecting it
- **THEN** the janitor remaps the task through current Codex state
- **AND** only the task's cwd or current-two-turn structured tool paths receive its bounded recent-session protection
- **AND** a missing or renamed recorded cwd does not discard current structured tool-path evidence for another existing worktree
- **AND** unrelated worktrees are not reported as actively claimed by that task

#### Scenario: Transcript evidence is shared across candidates
- **WHEN** several candidate worktrees are judged from the same activity snapshot
- **THEN** each transcript's current-two-user-turn window is indexed at most once for that snapshot
- **AND** its normalized structured tool inputs are materialized at most once for that snapshot
- **AND** matching another candidate does not start another interpreter for that transcript
- **AND** malformed relevant evidence still uses the exact parser and fails closed
- **AND** non-UTF-8 filesystem path bytes round-trip through normalized evidence
- **AND** normal completion or an interrupt removes the private projection directory
- **AND** the pre-removal activity refresh builds a new snapshot before destructive action
- **AND** structured active and recent transcript matching is skipped when a cheaper gate already keeps the worktree

#### Scenario: Unchanged transcript evidence is reused across scheduled sweeps
- **WHEN** a later scheduled sweep sees the same transcript path, device, inode, size, and modification time
- **THEN** it reuses the offset-only persistent index without rereading the transcript window
- **AND** any identity or content change rebuilds the evidence before it can authorize removal

#### Scenario: Cleanup task inventories another worktree
- **WHEN** the task running the janitor names a target in its own structured tool call
- **THEN** that self-reference does not claim the target
- **AND** the task's verified cwd still protects its actual checkout

### Requirement: Installed unattended cleanup policy

The installed cc-reaper policy SHALL use a 48-hour idle window. Direct invocation SHALL
remain report-only without `--apply`; `--session` and `--scheduled` MAY apply only when
their separate cc-reaper config switches are exactly `1`.

#### Scenario: Scheduled guarantee
- **WHEN** the installed LaunchAgent runs every six hours with `CC_WJ_SCHEDULE_APPLY=1`
- **THEN** it removes only worktrees that pass every existing gate and have been idle at least 48 hours

#### Scenario: Legacy destructive schedule exists
- **WHEN** the shared policy is installed over a Claude-owned worktree LaunchAgent
- **THEN** the legacy agent is unloaded and moved to a recoverable migration archive
- **AND** only the shared policy remains scheduled to remove worktrees

#### Scenario: Missing scheduled opt-in
- **WHEN** `--scheduled` runs without `CC_WJ_SCHEDULE_APPLY=1`
- **THEN** it reports only

#### Scenario: Scheduled run evidence is bounded and delimited
- **WHEN** the LaunchAgent starts a scheduled sweep
- **THEN** the actual LaunchAgent stdout and stderr files are bounded
- **AND** stdout records start time, end time, elapsed seconds, pid, and exit status for that run

### Requirement: Harness-neutral SessionEnd trigger

`worktree-janitor --session` SHALL accept SessionEnd payloads from Claude or Codex through
one deployed cc-reaper entrypoint.

#### Scenario: Either harness ends a session
- **WHEN** Claude or Codex invokes `worktree-session-end.sh <harness>`
- **THEN** the hook returns promptly, the detached sweep logs the harness, and the same policy implementation runs

### Requirement: Harness-owned repository discovery

The janitor SHALL discover repositories in ordinary configured source roots and in the
Claude and Codex harness worktree roots, deduplicating clones/worktrees by git common
directory.

#### Scenario: Harness-owned second clone
- **WHEN** a harness-owned checkout is not registered under an ordinary source root
- **THEN** it is still present in the report and evaluated by the same gates
