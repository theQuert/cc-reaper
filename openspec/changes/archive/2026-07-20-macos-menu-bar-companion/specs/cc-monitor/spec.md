## ADDED Requirements

### Requirement: Monitor excludes its own sampling process tree
The monitor SHALL exclude the process tree used to invoke `cc-monitor` and the companion app itself from reportable findings.

#### Scenario: Monitor is launched through a shell wrapper
- **WHEN** a sampled command contains the current `cc-monitor.sh` invocation or its shell wrapper
- **THEN** the monitor SHALL omit that process from findings and family totals

#### Scenario: Companion process is sampled
- **WHEN** a sampled command belongs to CCReaper
- **THEN** the monitor SHALL omit it from findings and family totals

#### Scenario: Known UI automation helper is sampled
- **WHEN** a sampled command belongs to the Codex Computer Use helper
- **THEN** the monitor SHALL classify it as protected and SHALL NOT recommend direct termination

### Requirement: Cleanup dry-run shares cleanup policy
The cleanup engine SHALL support a non-destructive dry-run mode that traverses the same candidate and protection logic as normal cleanup.

#### Scenario: Dry-run finds a cleanup candidate
- **WHEN** `claude-cleanup --dry-run` encounters a process that normal cleanup would reap
- **THEN** it SHALL report the PID as a would-reap action and SHALL send no signal

#### Scenario: Dry-run preserves protected processes
- **WHEN** `claude-cleanup --dry-run` encounters a protected process
- **THEN** it SHALL omit that process from would-reap actions and SHALL send no signal
