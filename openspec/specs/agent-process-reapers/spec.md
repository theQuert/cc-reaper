# agent-process-reapers Specification

## Purpose
TBD - created by archiving change agent-process-reapers. Update Purpose after archive.
## Requirements
### Requirement: Cross-platform orphan parent detection

The system SHALL recognize a process as orphaned not only when its parent is
PID 1 but also when its parent is the invoking user's `systemd --user` manager,
which is the Linux per-user reparent target for processes whose session has
exited. The Stop hook, `claude-cleanup`, and the orphan report SHALL all use
this shared orphan-parent definition.

#### Scenario: macOS or host with no systemd --user manager

- **WHEN** cc-reaper runs on a host where the invoking user has no
  `systemd --user` manager process (e.g. macOS)
- **THEN** the orphan-parent set SHALL contain only PID 1, and orphan detection
  SHALL behave identically to the prior PID=1-only behavior.

#### Scenario: Linux host with a systemd --user manager

- **WHEN** cc-reaper runs on a Linux host where the invoking user has a
  `systemd --user` manager process, and a Claude subagent or MCP server has
  been reparented to that manager after its session exited
- **THEN** the orphan-parent set SHALL include both PID 1 and that manager's
  PID, and the reparented process SHALL be detected as an orphan by the Stop
  hook, `claude-cleanup`, and the orphan report.

#### Scenario: Multiple systemd --user managers exist

- **WHEN** more than one `systemd --user` process exists on the host (e.g.
  several logged-in users each have their own manager)
- **THEN** cc-reaper SHALL include only the manager(s) owned by the invoking
  user in the orphan-parent set, and SHALL NOT treat another user's manager as
  an orphan parent.

#### Scenario: systemd --user manager is never a cleanup candidate

- **WHEN** orphan cleanup runs and a `systemd --user` manager PID is part of
  the orphan-parent set
- **THEN** cc-reaper SHALL NOT terminate the manager process itself — it is a
  reparent target, not an orphan.

### Requirement: Manual cleanup reaps stale agent browser processes
The system SHALL allow `claude-cleanup` to reap detached or stale agent-browser and Chrome-for-Testing processes that remain after an agent/browser automation session ends.

#### Scenario: Orphaned agent-browser process is found
- **WHEN** an `agent-browser-darwin-arm64` process or its Chrome-for-Testing child is detached from its owning session or has been reparented to an orphan parent (PID 1, or the invoking user's `systemd --user` manager on Linux)
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
- **WHEN** a process group leader is a Codex CLI/native process and the leader has been reparented to an orphan parent (PID 1, or the invoking user's `systemd --user` manager on Linux)
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

### Requirement: claude-guard reaps stuck protected processes
The system SHALL detect runaway protected processes (sustained high CPU over a long elapsed time) and SHALL terminate them after an explicit grace window, treating them as a distinct phase before existing FD-leak / bloated / idle phases.

#### Scenario: Runaway protected process detected
- **WHEN** `claude-guard` runs and one or more protected processes meet runaway thresholds (CPU ≥ `CC_RUNAWAY_CPU` percent over etime ≥ `CC_RUNAWAY_MIN` minutes; defaults 80 and 60)
- **THEN** claude-guard SHALL print a "Runaway protected processes" section listing each PID, command, CPU, and etime, SHALL wait `CC_RUNAWAY_GRACE_SEC` seconds (default 5) for the user to Ctrl+C, AND SHALL then send PGID-aware termination signals to those processes (preserving non-runaway protected services within the same group).

#### Scenario: --dry-run preserves runaway protected processes
- **WHEN** `claude-guard --dry-run` runs and runaway processes are detected
- **THEN** claude-guard SHALL print the runaway list and the actions it would take, but SHALL NOT send any signals.

#### Scenario: Runaway phase is opt-out
- **WHEN** the user sets `CC_RUNAWAY_DISABLE=1`
- **THEN** claude-guard SHALL skip the runaway phase entirely and proceed directly to the FD-leak / bloated / idle phases as before.

#### Scenario: No runaway candidates
- **WHEN** no protected process meets the runaway thresholds
- **THEN** claude-guard SHALL skip the runaway phase silently and continue with the existing phases.
