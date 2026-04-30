# agent-process-reapers Specification Delta — runaway-protected-detection

## ADDED Requirements

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
