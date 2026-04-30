# agent-process-reapers Specification

## Purpose
TBD - created by archiving change agent-process-reapers. Update Purpose after archive.
## Requirements
### Requirement: Manual cleanup reaps stale agent browser processes
The system SHALL allow `claude-cleanup` to reap detached or stale agent-browser and Chrome-for-Testing processes that remain after an agent/browser automation session ends.

#### Scenario: Orphaned agent-browser process is found
- **WHEN** an `agent-browser-darwin-arm64` process or its Chrome-for-Testing child is detached from its owning session or has been reparented to PID 1
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

#### Scenario: Stale Chrome-for-Testing profile is found
- **WHEN** a Chrome-for-Testing process uses an `agent-browser-chrome-*` profile and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

### Requirement: Manual cleanup reaps stale Puppeteer headless Chrome processes
The system SHALL allow `claude-cleanup` to reap runaway Puppeteer/headless Chrome processes that use temporary automation profiles.

#### Scenario: Runaway Puppeteer Chrome is found
- **WHEN** a Chrome or Chrome Helper process uses a `puppeteer_dev_chrome_profile-*` profile, runs in headless mode, and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

#### Scenario: Regular Chrome is running
- **WHEN** a Chrome process does not use a Puppeteer or agent-browser automation profile
- **THEN** `claude-cleanup` SHALL NOT terminate it because of this capability.

### Requirement: Manual cleanup reaps stale Codex background processes
The system SHALL allow `claude-cleanup` to reap stale or orphaned Codex CLI background sessions and their short-lived MCP subprocesses.

#### Scenario: Orphaned Codex process group is found
- **WHEN** a process group leader is a Codex CLI/native process and the leader has been reparented to PID 1
- **THEN** `claude-cleanup` SHALL terminate the process group unless a member matches a shared-service whitelist.

#### Scenario: Codex MCP subprocess is detached
- **WHEN** a Codex-owned `chrome-devtools-mcp`, `context7-mcp`, `mcp-remote`, or npm MCP subprocess is detached and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates unless it matches a shared-service whitelist.

### Requirement: Scheduled monitor covers agent process families
The LaunchAgent monitor SHALL apply the same stale/orphan cleanup coverage to agent-browser, Puppeteer headless Chrome, and Codex process families.

#### Scenario: Monitor finds stale browser automation
- **WHEN** `cc-reaper-monitor.sh` runs and finds stale agent-browser, Chrome-for-Testing, or Puppeteer headless Chrome processes
- **THEN** it SHALL log the candidate details and terminate the stale processes.

#### Scenario: Monitor finds orphaned Codex group
- **WHEN** `cc-reaper-monitor.sh` runs and finds an orphaned process group whose leader is a Codex process
- **THEN** it SHALL log the group and terminate the group using the existing SIGTERM then SIGKILL fallback behavior.

### Requirement: proc-janitor configuration includes agent process targets
The proc-janitor configuration SHALL include target patterns for stale/orphan agent-browser, Puppeteer headless Chrome, and Codex background process families.

#### Scenario: proc-janitor scans orphan targets
- **WHEN** proc-janitor scans reparented processes
- **THEN** its targets SHALL match agent-browser, Chrome-for-Testing automation profiles, Puppeteer temporary headless profiles, and Codex background CLI/native processes.

#### Scenario: proc-janitor protects shared services
- **WHEN** proc-janitor scans processes that match shared MCP services or common development servers
- **THEN** its whitelist SHALL prevent those processes from being killed by these new patterns.

### Requirement: Safety boundaries protect user and system processes
The system SHALL keep explicit safety boundaries for processes that are not part of stale agent automation cleanup.

#### Scenario: User apps and system scanners are running
- **WHEN** ChatGPT.app, cmux.app, Bitdefender, Spotlight, normal Chrome browsing, or a frontend/backend dev server is running
- **THEN** cc-reaper SHALL NOT target those processes through this capability.

#### Scenario: Active session is running
- **WHEN** a Codex or Claude process is still attached to an active terminal/session and does not exceed stale/orphan criteria
- **THEN** cc-reaper SHALL NOT terminate it through this capability.

### Requirement: Stale threshold is configurable
The system SHALL expose configurable stale-age thresholds for browser automation and agent background cleanup with conservative defaults.

#### Scenario: User sets a lower stale threshold
- **WHEN** the user sets the stale threshold environment variable to a positive integer
- **THEN** manual cleanup and the scheduled monitor SHALL use that threshold for stale-process detection.

#### Scenario: User does not configure thresholds
- **WHEN** no stale threshold environment variable is set
- **THEN** cc-reaper SHALL use a conservative default that avoids killing recent active automation.
