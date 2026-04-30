# cc-monitor Specification Delta — runaway-protected-detection

## ADDED Requirements

### Requirement: Monitor detects runaway protected processes
The system SHALL identify protected processes that are objectively stuck or runaway (sustained high CPU over a long elapsed time) and SHALL surface them as candidates for user intervention rather than leaving them as `DO_NOT_KILL`.

#### Scenario: Protected process meets runaway thresholds
- **WHEN** a sampled process matches the protected pattern AND its aggregated average CPU is at least `CC_RUNAWAY_CPU` percent (default 80) AND its elapsed time is at least `CC_RUNAWAY_MIN` minutes (default 60)
- **THEN** the monitor SHALL reclassify the finding from `DO_NOT_KILL` to `ASK_BEFORE_KILL`, set the family to `runaway`, and report a reason explaining the runaway condition (CPU% × elapsed time).

#### Scenario: Protected process below runaway thresholds
- **WHEN** a sampled process matches the protected pattern but does not meet both runaway thresholds
- **THEN** the monitor SHALL classify it as `DO_NOT_KILL` exactly as before.

#### Scenario: Runaway thresholds are configurable
- **WHEN** the user sets `CC_RUNAWAY_CPU` or `CC_RUNAWAY_MIN` to a numeric value
- **THEN** the monitor SHALL use those values to gate reclassification; non-numeric or zero values SHALL fall back to the defaults (80 and 60).

### Requirement: Monitor reports stuck/runaway processes in a dedicated section
The system SHALL print a dedicated section in the human report listing every runaway protected process with a copy-pasteable kill command, so the user can act without re-deriving PIDs from the top-contributors table.

#### Scenario: At least one runaway is detected
- **WHEN** the report contains one or more findings classified as `ASK_BEFORE_KILL` with family `runaway`
- **THEN** the human report SHALL print a `Stuck/runaway protected processes:` section listing each PID, label, average CPU, and elapsed time, followed by a suggested `kill <pid>` line per entry.

#### Scenario: No runaway candidates
- **WHEN** the report contains no runaway findings
- **THEN** the human report SHALL omit the runaway section entirely.

#### Scenario: JSON output reports runaway findings
- **WHEN** the user runs `cc-monitor --json` and runaway findings exist
- **THEN** the JSON output SHALL include those findings in the `findings` array with `family: "runaway"` and `classification: "ASK_BEFORE_KILL"`, and SHALL include a `runaway_candidates` array listing the same PIDs with reason text.
