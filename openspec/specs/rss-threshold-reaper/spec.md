# rss-threshold-reaper Specification

## Purpose

A hard memory ceiling for Claude Code sessions. `claude-guard` terminates any session whose tree RSS meets or exceeds `CC_MAX_RSS_MB`, regardless of whether the session is idle or active, because a leaking session can balloon to multiple GB while still busy. Tree RSS covers the session process, its children, and its grandchildren.

## Requirements

### Requirement: RSS threshold configuration
The system SHALL support a configurable RSS threshold via the `CC_MAX_RSS_MB` environment variable. The default value SHALL be 4096 (4 GB).

#### Scenario: Default threshold when env var is not set
- **WHEN** `CC_MAX_RSS_MB` is not set
- **THEN** the threshold SHALL default to 4096 MB

#### Scenario: Custom threshold via env var
- **WHEN** `CC_MAX_RSS_MB` is set to 2048
- **THEN** the threshold SHALL be 2048 MB

#### Scenario: Invalid threshold value
- **WHEN** `CC_MAX_RSS_MB` is set to a non-numeric value
- **THEN** the system SHALL fall back to the default 4096 MB and print a warning

### Requirement: Tree RSS calculation
The system SHALL calculate tree RSS as the sum of RSS of the session process, its direct children, and its grandchildren — two generations, matching the existing `claude-sessions` logic. It SHALL NOT recurse further.

Anything deeper is therefore not counted, so a session behind a long wrapper chain (CLI → `npm` → shell → server) is undercounted. On ordinary sessions the shortfall is around 1% (measured: 3–4 MB on trees of 6–10 processes), which is why the bound is accepted rather than paid for with a full recursive walk on every sampled session. Widening it is a behavior change, not a wording change.

#### Scenario: Session with MCP server children
- **WHEN** a Claude session (PID 1000) has 3 child MCP servers each using 200 MB, and the session itself uses 500 MB
- **THEN** tree RSS SHALL be calculated as 1100 MB

### Requirement: Bloated session detection
The system SHALL mark a session as `[BLOATED]` when its tree RSS **meets or exceeds** the configured threshold **and** it has not already matched a higher-priority status. Tree RSS is carried as whole megabytes, so equality is a reachable boundary and is treated as bloated.

Classification is first-match in this order, so each session carries exactly one status:

1. `[USER-PROTECTED]` — a user `protect` rule covers the session
2. `[FD-LEAK]` — file descriptors meet or exceed `CC_MAX_FD`
3. `[BLOATED]` — tree RSS meets or exceeds `CC_MAX_RSS_MB`
4. `[IDLE]` — CPU is below `CC_IDLE_THRESHOLD`
5. `LIVE` — none of the above

An over-threshold session that is also leaking descriptors is reaped by the FD-leak phase, with that phase's notification, not this one.

#### Scenario: Session exceeds threshold
- **WHEN** `claude-guard` runs and a session's tree RSS is 5000 MB
- **AND** `CC_MAX_RSS_MB` is 4096
- **THEN** the session SHALL be marked as `[BLOATED]`

#### Scenario: Over-threshold session is also leaking descriptors
- **WHEN** a session's tree RSS is 5000 MB against a 4096 MB threshold **and** its descriptor count meets `CC_MAX_FD`
- **THEN** the session SHALL be marked `[FD-LEAK]` rather than `[BLOATED]`, and SHALL be reaped by the FD-leak phase

#### Scenario: Over-threshold session is covered by a user protect rule
- **WHEN** a session's tree RSS exceeds the threshold and a user `protect` rule covers it
- **THEN** the session SHALL be marked `[USER-PROTECTED]`, SHALL count as live, and SHALL NOT be reaped

#### Scenario: Session exactly at threshold
- **WHEN** `claude-guard` runs and a session's tree RSS is 4096 MB
- **AND** `CC_MAX_RSS_MB` is 4096
- **THEN** the session SHALL be marked as `[BLOATED]`

#### Scenario: Session under threshold
- **WHEN** `claude-guard` runs and a session's tree RSS is 2000 MB
- **AND** `CC_MAX_RSS_MB` is 4096
- **THEN** the session SHALL NOT be marked as `[BLOATED]`

### Requirement: Bloated session termination
The system SHALL terminate bloated sessions PGID-aware, regardless of whether the session is idle or active: it SHALL enumerate the members of the session's process group and signal each one individually, skipping any member that matches the shared-service whitelist or a user `protect` rule.

It SHALL NOT signal the group as a whole (`kill -- -$PGID`), because that would take shared MCP services down with it and contradict the safety boundaries in the `agent-process-reapers` capability.

#### Scenario: Active session meets threshold
- **WHEN** a session is active (CPU > 1%) but tree RSS meets or exceeds the threshold
- **THEN** the system SHALL signal each member of its process group individually

#### Scenario: Idle session meets threshold
- **WHEN** a session is idle (CPU < 1%) and tree RSS meets or exceeds the threshold
- **THEN** the system SHALL signal each member of its process group individually (bloated takes priority over idle)

#### Scenario: Bloated session shares its group with a shared MCP service
- **WHEN** a bloated session's process group also contains a whitelisted MCP server, or a process covered by a user `protect` rule
- **THEN** that member SHALL be skipped and SHALL survive the reap, while the remaining members are signalled

### Requirement: Bloated session prioritization
The system SHALL kill bloated sessions before idle sessions. Bloated sessions SHALL be killed regardless of the `CC_MAX_SESSIONS` limit.

#### Scenario: One bloated and two idle sessions under limit
- **WHEN** there are 2 active sessions, 2 idle sessions, 1 bloated session, and `CC_MAX_SESSIONS` is 5
- **THEN** the bloated session SHALL be killed even though total count (5) equals the limit

### Requirement: Desktop notification on RSS kill
The system SHALL send a macOS desktop notification when a session is killed for exceeding the RSS threshold, including the session PID and the RSS value.

#### Scenario: Notification content
- **WHEN** session PID 12345 with tree RSS 5200 MB is killed for exceeding the 4096 MB threshold
- **THEN** a notification SHALL be sent with title "Claude Guard" and message indicating PID 12345 was killed for using 5200 MB (threshold: 4096 MB)

### Requirement: Dry-run visibility
The `--dry-run` flag SHALL display bloated sessions with their tree RSS and the configured threshold, without killing them.

#### Scenario: Dry-run with bloated session
- **WHEN** `claude-guard --dry-run` runs and a session has tree RSS of 5000 MB exceeding the 4096 MB threshold
- **THEN** output SHALL show the session as `[BLOATED]` with its tree RSS value, and the session SHALL NOT be killed
