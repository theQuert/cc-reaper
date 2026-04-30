## ADDED Requirements

### Requirement: Monitor is read-only by default
The system SHALL provide a `cc-monitor` command that observes process state and reports heat attribution without terminating or modifying processes.

#### Scenario: User runs the monitor
- **WHEN** the user runs `cc-monitor` with default options
- **THEN** the command SHALL sample process state, print a diagnosis report, and SHALL NOT send signals to any process.

#### Scenario: User requests a quick snapshot
- **WHEN** the user runs `cc-monitor --once`
- **THEN** the command SHALL collect one process snapshot and print a diagnosis report without waiting for the default sampling duration.

### Requirement: Monitor attributes heat by process family
The system SHALL group process findings into process families that are meaningful for cc-reaper users.

#### Scenario: Known AI development processes are sampled
- **WHEN** sampled commands match Claude, Codex, MCP, agent-browser, Puppeteer, Chrome, cmux, editor, dev server, or system process patterns
- **THEN** the monitor SHALL assign each process to the matching family and include family totals in the report.

#### Scenario: Unknown processes are sampled
- **WHEN** a sampled command does not match a known process family
- **THEN** the monitor SHALL classify it as `other` and still include it in top contributor ranking when CPU usage is high enough.

### Requirement: Monitor classifies process safety
The system SHALL classify report findings as `SAFE_TO_REAP`, `ASK_BEFORE_KILL`, or `DO_NOT_KILL`.

#### Scenario: Existing cleanup criteria match
- **WHEN** a sampled process matches stale or orphaned agent-browser, Puppeteer, Codex, or MCP cleanup criteria used by cc-reaper
- **THEN** the monitor SHALL classify the finding as `SAFE_TO_REAP` and describe why existing cleanup can handle it.

#### Scenario: Active user tool is hot
- **WHEN** a sampled process belongs to an active user tool such as Cursor, cmux, an attached Codex or Claude session, an active dev server, or active browser automation
- **THEN** the monitor SHALL classify the finding as `ASK_BEFORE_KILL` and recommend inspection or a user-controlled stop action.

#### Scenario: System or protected process is hot
- **WHEN** a sampled process belongs to a protected system, security, UI, or normal browsing process such as WindowServer, Spotlight, Bitdefender, ChatGPT.app, or regular Chrome
- **THEN** the monitor SHALL classify the finding as `DO_NOT_KILL` and avoid recommending direct termination.

### Requirement: Monitor provides actionable reports
The system SHALL produce a human-readable report that explains the sample and recommends next actions without taking them automatically.

#### Scenario: Human report is requested
- **WHEN** the monitor completes sampling without `--json`
- **THEN** it SHALL print sampling duration, interval, top contributors, family totals, safe cleanup candidates, and suggested next actions.

#### Scenario: No safe cleanup candidate exists
- **WHEN** no sampled process is classified as `SAFE_TO_REAP`
- **THEN** the report SHALL explicitly say that no safe cleanup candidates were found.

### Requirement: Monitor supports structured output
The system SHALL support JSON output for future automation and analysis.

#### Scenario: JSON output is requested
- **WHEN** the user runs `cc-monitor --json`
- **THEN** the command SHALL output valid JSON containing sample metadata, findings, family totals, safe cleanup candidates, and suggested actions.

#### Scenario: JSON output is combined with quick mode
- **WHEN** the user runs `cc-monitor --once --json`
- **THEN** the command SHALL output valid JSON for a single snapshot and SHALL NOT print human-readable report text.

#### Scenario: JSON output includes command arguments
- **WHEN** a reported command contains common secret-like arguments such as access tokens, API keys, secrets, or passwords
- **THEN** the JSON output SHALL redact those argument values before printing the command field.
