## ADDED Requirements

### Requirement: Work the process tree cannot show keeps a session
The session reaper SHALL keep a session in any of these cases:
- **`subagent-active`:** a file under `<projects>/*/<session id>/subagents/` or `.../workflows/` was written within `SUBAGENT_QUIET_MINUTES`.
- **`handoff-pending:relay#N`:** a request file `<issue>-*.json` for one of its claimed issues sits at the top of `RELAY_DIR` and is younger than `RELAY_MAX_AGE_HOURS`.
- **`handoff-pending:prompt`:** the last 15 lines of its pane match `PROMPT_RE`.
- **`handoff-missing:<file>`:** its latest assistant text names a path under `HANDOFF_ROOT` that does not exist.

With `RELAY_DIR` or `HANDOFF_ROOT` empty, the matching check SHALL be off.

#### Scenario: A subagent is still working while the main prompt is idle
- **WHEN** a session is idle past the threshold, done, and clean, but a subagent transcript was written within `SUBAGENT_QUIET_MINUTES`
- **THEN** it is kept as `subagent-active`

#### Scenario: An answered request does not keep a session
- **WHEN** the only request for a claimed issue is renamed `.done`, moved into a subdirectory, or older than `RELAY_MAX_AGE_HOURS`
- **THEN** no `handoff-pending:relay` reason is reported

### Requirement: The context to bring a session back is written before it exits
Before typing `/exit`, the reaper SHALL write `<REAPED_DIR>/<tmux name>.json` holding:
- the tmux name, session name, session id and cwd;
- the claimed issues;
- each owned worktree's path and branch;
- the last 2,000 characters of the latest assistant text;
- the resume command, `tmux new-session -d -s <tmux> -c <cwd> 'claude --resume <session id>'`.

After the attempt it SHALL set the record's status to `reaped`, or to `aborted:<outcome>` when the reap was skipped.

#### Scenario: The exit menu appears
- **WHEN** `/exit` opens the background-task menu and the reaper selects Stay
- **THEN** the record's status reads `aborted:skipped:background-tasks`

### Requirement: The report shows what the new gates changed
Each report row SHALL state:
- whether the session is held only by background shells (its keep reasons are a subset of `status:shell` and `shell-child`);
- whether it is kept only by the new gates, which means the earlier gates would have reaped it.

#### Scenario: Comparing before trusting
- **WHEN** an operator reads a report-only sweep
- **THEN** every row the new gates alone kept is marked "kept only by new gates"

### Requirement: An idle session's open claims are judged by the delivery oracle
For a session idle at least `IDLE_MINUTES` with no DONE signal, the reaper SHALL classify each claimed issue with `python3 scripts/ci/delivery_state.py <N> --brief` run in `ORACLE_ROOT` (30 s timeout, answer cached `ORACLE_CACHE_MINUTES`, default 10, in `ORACLE_CACHE_DIR`):
- `ended`: the brief says "the session may end", names another session as claimant, or the issue is closed; it adds no keep reason;
- `owed`: the claimant is this session; keep reason `owed-step:#N`, and the report marks the claim `stalled` when a check-by in the brief is past;
- `unknown`: oracle failed or unparseable; keep reason `issue-unknown:#N`.
A session that is not idle keeps `issue-open:#N`. Every other gate, and `PROTECT`, are unchanged. The report's issues column shows `#N:ended|owed|unknown[:stalled]`.

#### Scenario: Every claim has ended
- **WHEN** an idle session's claims are all `ended` and no other gate holds
- **THEN** the row is `would-reap` and the claim stays on the issue, resumable from the closed-sessions record
