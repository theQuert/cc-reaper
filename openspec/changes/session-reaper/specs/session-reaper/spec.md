## ADDED Requirements

### Requirement: A session is reaped only when every gate holds
The session reaper SHALL consider only interactive Claude Code sessions whose session file names a tmux pane that still holds the recorded process (same pid and start time). It SHALL keep a session when any of these holds: its tmux or session name matches a protection pattern; its status is not `idle`, or has been idle for less than `IDLE_MINUTES`; it has a background shell child, a pending `ScheduleWakeup`, more `CronCreate` than `CronDelete` calls, or a `scheduled_tasks.json` in its cwd; its latest assistant turn asks a question or asks for authorization; its latest assistant text has no `SESSION-DONE:` line or topic-end phrase and not every claimed issue is closed (no claim evidence keeps it); a worktree it owns has uncommitted changes or commits on no remote that the worktree janitor does not prove landed.

#### Scenario: A finished session
- **WHEN** a session is idle past the threshold, its last message carries `SESSION-DONE:`, and nothing else keeps it
- **THEN** the report marks it `would-reap`, or with apply on, it is reaped

#### Scenario: A session waiting on a person
- **WHEN** the latest assistant text asks for authorization, even beside a `SESSION-DONE:` line
- **THEN** it is kept as `waiting`

### Requirement: Reaping never stops background work or overwrites input
Before acting the reaper SHALL re-read the session file and skip the session if its status or status time changed since the sweep read it, if claude is not its tty's foreground process, or if the current tmux name is protected. It SHALL type `/exit` only when the cursor sits after an empty prompt and no dialog or menu is on screen, and SHALL press Enter only if the prompt line then reads exactly `/exit`, otherwise removing the typed text and skipping. When the background-task exit menu appears it SHALL press Esc (Stay) and skip the session. Only after the claude process has exited SHALL it close claude's pane, and the tmux session (targeted by id) only when that pane was its only one, and SHALL record the session in the closed-sessions log and on each claimed issue with its resume command.

#### Scenario: The cursor was moved into a draft
- **WHEN** the prompt line does not read exactly `/exit` after typing
- **THEN** the typed characters are removed, Enter is never pressed, and the report says `skipped:input-not-empty`

#### Scenario: The tmux session has other windows
- **WHEN** claude's pane is not the session's only pane
- **THEN** only that pane is closed and the other windows keep running

#### Scenario: Background work is running
- **WHEN** `/exit` opens the "Exit and stop tasks / Move to background / Stay" menu
- **THEN** the reaper selects Stay, the session and its tasks keep running, and the report says `skipped:background-tasks`

### Requirement: Every reap is verified and a failure is never silent
After each reap the reaper SHALL check that every process in the pre-exit descendant snapshot (pid and start time) is gone, that claude's pane, the tmux session when it was killed, and the session file no longer exist, and that no owned worktree has a `locked` file or `index.lock`. Any failure SHALL raise a local notification independent of GitHub, a comment on the configured tracking issue, and a non-zero exit, and SHALL appear in the report.

#### Scenario: A child outlives claude
- **WHEN** a process from the snapshot is still running after the reap
- **THEN** the report lists it under verification failures, a notification is raised, and the run exits 1
