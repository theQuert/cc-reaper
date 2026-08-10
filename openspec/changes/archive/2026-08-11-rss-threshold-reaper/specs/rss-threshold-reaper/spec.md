## ADDED Requirements

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
The system SHALL calculate tree RSS as the sum of RSS of the session process and all its descendant processes (children + grandchildren), matching the existing `claude-sessions` logic.

#### Scenario: Session with MCP server children
- **WHEN** a Claude session (PID 1000) has 3 child MCP servers each using 200 MB, and the session itself uses 500 MB
- **THEN** tree RSS SHALL be calculated as 1100 MB

### Requirement: Bloated session detection
The system SHALL mark sessions as `[BLOATED]` when their tree RSS exceeds the configured threshold.

#### Scenario: Session exceeds threshold
- **WHEN** `claude-guard` runs and a session's tree RSS is 5000 MB
- **AND** `CC_MAX_RSS_MB` is 4096
- **THEN** the session SHALL be marked as `[BLOATED]`

#### Scenario: Session under threshold
- **WHEN** `claude-guard` runs and a session's tree RSS is 2000 MB
- **AND** `CC_MAX_RSS_MB` is 4096
- **THEN** the session SHALL NOT be marked as `[BLOATED]`

### Requirement: Bloated session termination
The system SHALL kill bloated sessions using PGID-based process group termination (`kill -- -$PGID`), regardless of whether the session is idle or active.

#### Scenario: Active session exceeds threshold
- **WHEN** a session is active (CPU > 1%) but tree RSS exceeds the threshold
- **THEN** the system SHALL kill the entire process group via PGID

#### Scenario: Idle session exceeds threshold
- **WHEN** a session is idle (CPU < 1%) and tree RSS exceeds the threshold
- **THEN** the system SHALL kill the entire process group via PGID (bloated takes priority over idle)

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
