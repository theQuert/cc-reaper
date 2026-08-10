## ADDED Requirements

### Requirement: Shared Claude Code session detection
The system SHALL locate Claude Code sessions through a single helper,
`_cc_reaper_session_pids`, which emits one PID per line. `claude-guard`,
`claude-sessions`, and `claude-fd` SHALL all obtain their session list from that helper so
that the three commands can never disagree about what a session is.

#### Scenario: All three commands agree
- **WHEN** `claude-guard`, `claude-sessions`, and `claude-fd` run against the same process table
- **THEN** each SHALL classify exactly the same set of PIDs as sessions

#### Scenario: Helper emits nothing on an idle host
- **WHEN** no Claude Code process is running
- **THEN** `_cc_reaper_session_pids` SHALL emit no output and exit without error

### Requirement: A session is a terminal-attached top-level Claude CLI process
The system SHALL treat a process as a Claude Code session only when it runs the `claude`
CLI executable **and** is attached to a real controlling terminal. Processes with no
controlling terminal SHALL NOT be treated as sessions.

The matcher SHALL recognise the session by the `claude` executable together with a session
flag (`--session-id`, or the legacy `--dangerously…` form), and SHALL NOT depend on any
single flag remaining in future Claude Code releases.

#### Scenario: Interactive CLI session is found
- **WHEN** `/Users/me/.local/bin/claude --session-id 3ded1c38-… --settings {…}` runs on `ttys006`
- **THEN** its PID SHALL be reported as a session

#### Scenario: Legacy launch form still matches
- **WHEN** a session runs as `claude --dangerously-skip-permissions` on a terminal
- **THEN** its PID SHALL be reported as a session

#### Scenario: Desktop-hosted claude-code is excluded
- **WHEN** `…/Claude/claude-code/2.1.222/claude.app/Contents/MacOS/claude --output-format stream-json --input-format stream-json …` runs with no controlling terminal
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Subagent is excluded
- **WHEN** a `claude … stream-json` process runs with no controlling terminal as the child of another `claude` process
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Headless run on a terminal is excluded
- **WHEN** `claude -p "summarize" --output-format stream-json` runs on `ttys003`
- **THEN** its PID SHALL NOT be reported as a session, because a batch run below the idle CPU threshold is indistinguishable from an abandoned session

#### Scenario: Helper process on a terminal is excluded
- **WHEN** `claude mcp-server …` runs on a terminal
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Unrelated process naming claude is excluded
- **WHEN** `vim shell/claude-cleanup.sh` or `grep claude --session-id log.txt` runs on a terminal
- **THEN** its PID SHALL NOT be reported as a session, because neither runs the `claude` executable

### Requirement: Record boundaries never derive from process arguments
The system SHALL obtain the candidate PID and TTY from a process listing that carries the
executable name only and no argument text, so that no value a session was launched with can
forge a process record. The full command line SHALL be fetched per PID, never parsed out of
a concatenated table.

A session started with a `--settings` JSON argument containing newlines SHALL be reported
exactly once, and no token from that argument SHALL ever be emitted as a PID.

#### Scenario: Session arguments carry a forged process record
- **WHEN** a session's `--settings` payload contains the text `12345 ttys999 /path/claude --session-id injected` on its own line
- **THEN** the helper SHALL emit only the real session's PID, and SHALL NOT emit `12345`

#### Scenario: Forged PID belongs to a live process
- **WHEN** the forged PID names a live, unrelated process that exceeds an FD, RSS, or idle threshold
- **THEN** that process SHALL NOT be classified as a session, so `claude-guard` cannot reap its process group

#### Scenario: Session carries multi-line JSON settings
- **WHEN** a session's `--settings` argument contains embedded newlines
- **THEN** the helper SHALL emit that session's PID exactly once

### Requirement: Only the CLI's own arguments decide session status
The system SHALL ignore the `--settings` payload when testing for session and exclusion
flags. Every balanced `{…}` region of the command line is user-supplied data and SHALL NOT
qualify or disqualify a session.

The payload SHALL be cut out rather than truncated at, so top-level arguments written after
it still count. Braces inside JSON strings SHALL NOT affect the pairing. When the braces
never balance, the command SHALL be rejected: a missed session leaves the reaper inert,
while trusting a half-parsed line could hand `claude-guard` the wrong process group.

#### Scenario: Exclusion flag written after the payload
- **WHEN** `claude --session-id real --settings={} --output-format json` runs on a terminal
- **THEN** it SHALL NOT be reported, because `--output-format` is a top-level argument even though it follows the payload

#### Scenario: Session flag written after the payload
- **WHEN** `claude --settings={} --session-id real` runs on a terminal
- **THEN** it SHALL be reported

#### Scenario: Braces inside a JSON string
- **WHEN** the payload is `{"a":"}{"}`
- **THEN** the region SHALL still be treated as balanced and the session reported

#### Scenario: Braces never balance
- **WHEN** the command line ends mid-payload, as in `--settings {"truncated":`
- **THEN** the command SHALL NOT be reported as a session

#### Scenario: Hook command inside settings names an exclusion flag
- **WHEN** an interactive session's `--settings` JSON contains a hook such as `claude -p x --output-format json`
- **THEN** the session SHALL still be reported, because `--output-format` there belongs to the payload rather than to the CLI's own arguments

#### Scenario: Payload cannot qualify a non-session
- **WHEN** a non-session command such as `claude doctor --settings {"x":"--session-id fake"}` runs on a terminal
- **THEN** it SHALL NOT be reported, because the session flag appears only inside the payload

#### Scenario: Equals form of the settings flag
- **WHEN** the payload is passed as `--settings={…}` rather than `--settings {…}`
- **THEN** the payload SHALL be excluded from matching just the same

#### Scenario: Genuine headless run is still excluded
- **WHEN** `claude -p "summarize" --session-id ghi` runs on a terminal with the flags in its own arguments
- **THEN** it SHALL NOT be reported as a session

### Requirement: claude-guard runs identically under bash and zsh
`claude-guard` SHALL classify and report the same sessions whether sourced into bash or zsh.
Its kill phases SHALL NOT depend on array index numbering, because `${!arr[@]}` raises
`bad substitution` in zsh and `${arr[0]}` is empty there. Each candidate SHALL carry its own
detail alongside its PID rather than relying on a second array walked by the same index.

The reserved variable name `status` SHALL NOT be declared, since it is read-only in zsh.

#### Scenario: FD-leak phase under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with a session above `CC_MAX_FD`
- **THEN** the phase SHALL name that session's PID and SHALL NOT abort with `bad substitution`

#### Scenario: Bloated phase under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with a session above `CC_MAX_RSS_MB`
- **THEN** the phase SHALL name that session's PID

#### Scenario: Idle eviction under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with more idle sessions than `CC_MAX_SESSIONS`
- **THEN** each eviction line SHALL name a real PID, never an empty one

#### Scenario: Session table renders under zsh
- **WHEN** `claude-guard` or `claude-fd` prints a session's status column under zsh
- **THEN** it SHALL not fail with `read-only variable: status`

## MODIFIED Requirements

### Requirement: Safety boundaries protect user and system processes
Cleanup SHALL never target user applications, system scanners, or active Claude Code
sessions. `claude-guard` SHALL additionally never treat a process as a reapable session
unless it satisfies the terminal-attached top-level Claude CLI definition, so that
Desktop-hosted sessions, headless batch runs, and subagents are out of reach of RSS, FD,
and idle reaping.

#### Scenario: User apps and system scanners are running
- **WHEN** cleanup runs while Chrome, Slack, `mdworker`, and `mds_stores` are active
- **THEN** none of them SHALL be signalled

#### Scenario: Active session is running
- **WHEN** cleanup runs while a Claude Code session is attached to a terminal and below all thresholds
- **THEN** that session SHALL be reported `LIVE` and SHALL NOT be signalled

#### Scenario: Headless batch run is active during guard
- **WHEN** `claude-guard` runs while a headless `claude -p` batch job sits at 0% CPU
- **THEN** the batch job SHALL NOT be counted toward `CC_MAX_SESSIONS` and SHALL NOT be signalled
