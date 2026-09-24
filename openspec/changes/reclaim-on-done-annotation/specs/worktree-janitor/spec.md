## ADDED Requirements

### Requirement: An accepted task is reclaimed without the idle and session windows
The janitor SHALL treat a worktree as *done* only when all of these hold: its undiscounted
content count is exactly `0`; `<its absolute git dir>/claude-task-done` exists and has exactly
one line beginning `head=`, and that line is `head=` followed by exactly 40 lowercase
hexadecimal characters; that value equals the worktree's current `git rev-parse HEAD`; and
HEAD is on a branch. Any other state SHALL be treated as not done, and the worktree judged as
if the file were absent.

For a done worktree only, the janitor SHALL NOT ask for a recent-session lease, before
landing, before classification or immediately before removal; SHALL treat a lease answer from
the live-claim check as no lease while still reading every live claim; and SHALL use an idle
window of 0 hours, at classification and immediately before removal. Every other gate and
recheck SHALL apply unchanged, and no branch SHALL be deleted. Immediately before a removal
the annotation SHALL be read again, and a worktree that is no longer done SHALL take the lease
and idle rechecks. For a done worktree the inventory SHALL print the line
`    done: claude-task-done at HEAD <first 12 characters of HEAD>`, and SHALL NOT change any
existing line.

#### Scenario: Accepted task named by a recent session
- **WHEN** a landed, clean, unheld worktree modified within `CC_WJ_IDLE_HOURS` carries a recent Claude session lease, by cwd or by a structured tool call, and a valid `claude-task-done` naming its HEAD
- **THEN** it is classified REMOVABLE with a `done:` line, `--apply` removes it, and its branch remains

#### Scenario: The same worktree without the annotation
- **WHEN** such a worktree has no `claude-task-done`
- **THEN** it is classified `KEEP(recent-session)`, as before

#### Scenario: Stale annotation
- **WHEN** the `head=` line names a commit other than the worktree's HEAD
- **THEN** the annotation is ignored and the worktree is judged as before

#### Scenario: Malformed annotation
- **WHEN** the file is empty, has no `head=` line or more than one, or its `head=` value is not exactly 40 lowercase hexadecimal characters (short, uppercase, followed by other text or by a carriage return)
- **THEN** the annotation is ignored

#### Scenario: Detached HEAD
- **WHEN** a well-formed annotation names HEAD but HEAD is detached
- **THEN** the annotation is ignored

#### Scenario: Annotated worktree holding uncommitted work
- **WHEN** an annotated worktree holds undiscounted content
- **THEN** it is classified `KEEP(unrebuildable=<n>)` and printed without a `done:` line

#### Scenario: Annotated worktree whose work has not landed
- **WHEN** a done worktree's HEAD satisfies no landed proof and the worktree is not abandoned
- **THEN** it is classified `KEEP(unlanded)`

#### Scenario: Annotated worktree that is held or claimed
- **WHEN** a process holds a done worktree, or a verified-live Claude or Codex session claims it
- **THEN** it is classified `KEEP(active-session)`

#### Scenario: A lease answer comes before a live claim
- **WHEN** a Codex task archives while a done worktree's claims are read, which turns its claim into a lease, and a live task listed after it names the worktree
- **THEN** the lease is waived, and the live claim still keeps the worktree `KEEP(active-session)`

#### Scenario: Annotation withdrawn before removal
- **WHEN** a done worktree's annotation stops being valid between classification and removal
- **THEN** the lease and idle rechecks apply before the removal, and a recent-session lease keeps the worktree
