## ADDED Requirements

### Requirement: Runaway identification does not depend on protection status
cc-monitor SHALL identify a process as a runaway from its behaviour alone — sustained CPU
above the threshold for longer than the duration floor — regardless of whether the process
matches a protected pattern. Protection status SHALL govern only what may be done about a
runaway, never whether it is named one.

The test previously sat inside the protected-command branch, so a process could be called a
runaway only if it was already on the protection list. The processes that run away are the
ones nobody listed. Measured 2026-08-30 and replayed through the report: a Python process at
99% CPU for 51 minutes under a live session was classified `family=other`; the same row is
`family=runaway` once the test is evaluated for every row.

Every runaway SHALL be classified `ASK_BEFORE_KILL` and SHALL NOT be reaped by this path. A
live session's child at 100% CPU may equally be a legitimate long build, and this tool cannot
tell those apart.

#### Scenario: Unprotected runaway with a live parent
- **WHEN** an unprotected process exceeds both thresholds and its parent is alive
- **THEN** it SHALL be reported with `family=runaway` and `classification=ASK_BEFORE_KILL`

#### Scenario: Protected runaway
- **WHEN** a protected process exceeds both thresholds
- **THEN** it SHALL be reported as a runaway on the same terms, preserving the existing behaviour

#### Scenario: Short CPU burst
- **WHEN** a process is above the CPU threshold but below the duration floor
- **THEN** it SHALL NOT be identified as a runaway, because a build and a stuck loop are indistinguishable at that timescale

#### Scenario: Report wording matches what is listed
- **WHEN** the human report renders the runaway section
- **THEN** neither the heading nor the reason SHALL describe the listed processes as protected

### Requirement: The reporting floor is lower than the reaping floor
The duration floor for *identifying* a runaway SHALL be 30 minutes by default. The floor for
*signalling* one SHALL remain 60 minutes, and SHALL stay in its own implementation with its
own whitelist.

An hour in which a non-terminating loop holds a core and is labelled `other` is the cost of a
single floor. Reporting earlier than the reaper acts is the intended asymmetry; the two
numbers are not copies of each other and SHALL NOT be collapsed into one.

#### Scenario: Runaway between the two floors
- **WHEN** a process has exceeded the CPU threshold for 45 minutes
- **THEN** it SHALL appear in the report as a runaway, and SHALL NOT be signalled by the guard agent

#### Scenario: Guard's selection is unchanged
- **WHEN** the guard agent runs
- **THEN** the set of processes it may signal SHALL be exactly what it was before this change
