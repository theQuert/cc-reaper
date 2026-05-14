# agent-process-reapers Specification Delta — systemd-user-orphan-detection

## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Manual cleanup reaps stale agent browser processes

The system SHALL allow `claude-cleanup` to reap detached or stale agent-browser
and Chrome-for-Testing processes that remain after an agent/browser automation
session ends.

#### Scenario: Orphaned agent-browser process is found

- **WHEN** an `agent-browser-darwin-arm64` process or its Chrome-for-Testing
  child is detached from its owning session or has been reparented to an orphan
  parent (PID 1, or the invoking user's `systemd --user` manager on Linux)
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and
  terminate it.

#### Scenario: Stale Chrome-for-Testing profile is found

- **WHEN** a Chrome-for-Testing process uses an `agent-browser-chrome-*`
  profile and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and
  terminate it.

### Requirement: Manual cleanup reaps stale Codex background processes

The system SHALL allow `claude-cleanup` to reap stale or orphaned Codex CLI
background sessions and their short-lived MCP subprocesses.

#### Scenario: Orphaned Codex process group is found

- **WHEN** a process group leader is a Codex CLI/native process and the leader
  has been reparented to an orphan parent (PID 1, or the invoking user's
  `systemd --user` manager on Linux)
- **THEN** `claude-cleanup` SHALL terminate the process group unless a member
  matches a shared-service whitelist.

#### Scenario: Codex MCP subprocess is detached

- **WHEN** a Codex-owned `chrome-devtools-mcp`, `context7-mcp`, `mcp-remote`,
  or npm MCP subprocess is detached and exceeds the configured stale age
  threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates unless it
  matches a shared-service whitelist.
