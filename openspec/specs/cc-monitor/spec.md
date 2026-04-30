# cc-monitor Specification

## Purpose
TBD - created by archiving change cc-monitor. Update Purpose after archive.
## Requirements
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

### Requirement: Monitor optionally dispatches optimization modules
The system SHALL provide an opt-in path to apply a user-selected optimization module after the read-only report is printed, while preserving the default read-only behavior.

#### Scenario: TTY interactive menu with safe candidates
- **WHEN** the user runs `cc-monitor` on a controlling terminal (both stdin and stdout are TTYs), without `--json`, `--no-prompt`, or `--apply`, AND the report contains at least one `SAFE_TO_REAP` finding
- **THEN** the monitor SHALL print the human report and append a numbered menu listing the available optimization modules, mark a recommended option, and read the user's choice from the controlling TTY.

#### Scenario: TTY interactive menu with heat candidates only
- **WHEN** the user runs `cc-monitor` interactively, the report contains no `SAFE_TO_REAP` findings, AND family-level RSS or per-process CPU exceeds the recommendation thresholds
- **THEN** the monitor SHALL display the menu, mark `claude-guard --dry-run` as the recommended option (or fall back to `proc-janitor scan` when `claude-guard` is unavailable), and SHALL list the destructive modules as additional choices for users who deliberately opt in.

#### Scenario: TTY interactive menu without candidates
- **WHEN** the user runs `cc-monitor` interactively but the report contains no `SAFE_TO_REAP` findings AND no family-level heat above the recommendation thresholds
- **THEN** the monitor SHALL NOT display the menu and SHALL exit after printing the report without sending signals.

#### Scenario: Recommended module unavailable on PATH
- **WHEN** the menu is displayed and the module that the recommendation logic would pick is not available on PATH or as a sourced shell function, but other modules are available
- **THEN** the monitor SHALL fall back to recommending the first available preview-only module (`claude-guard --dry-run` or `proc-janitor scan`); if no preview-only module is available, no option is marked as recommended.

#### Scenario: Non-TTY suppresses menu
- **WHEN** stdin, stdout, or stderr is not a TTY (for example output or error stream is piped or redirected)
- **THEN** the monitor SHALL skip the menu, behave as a read-only report, and SHALL NOT prompt for input. (The stderr check exists because the menu and confirmation prompts render to stderr; redirecting stderr would otherwise produce an invisible prompt.)

#### Scenario: `--no-prompt` suppresses menu
- **WHEN** the user runs `cc-monitor --no-prompt`
- **THEN** the monitor SHALL skip the menu and SHALL NOT send signals, regardless of TTY state.

#### Scenario: `--json` suppresses menu unconditionally
- **WHEN** the user runs `cc-monitor --json` (with or without `--no-prompt`)
- **THEN** the monitor SHALL emit only the JSON report and SHALL NOT print or read any menu or confirmation text.

#### Scenario: User declines via Enter or skip
- **WHEN** the menu is displayed and the user presses Enter or selects the skip option
- **THEN** the monitor SHALL exit with status 0 without dispatching any module.

#### Scenario: User selects a destructive module interactively
- **WHEN** the menu is displayed and the user picks a destructive module (`claude-cleanup`, `claude-guard`, or `proc-janitor clean`)
- **THEN** the monitor SHALL print a confirmation prompt of the form `Run <module>? [y/N]` and SHALL only dispatch the module when the user answers `y` or `Y`; any other input or empty input SHALL be treated as decline.

#### Scenario: User selects a non-destructive module interactively
- **WHEN** the menu is displayed and the user picks a non-destructive module (`claude-guard --dry-run` or `proc-janitor scan`)
- **THEN** the monitor SHALL dispatch the module without an additional confirmation prompt.

#### Scenario: Module binary not on PATH (interactive)
- **WHEN** the menu is displayed and one or more module binaries are not available on PATH
- **THEN** the monitor SHALL omit the unavailable modules from the numbered menu and SHALL print a one-line install hint per missing module after the menu.

### Requirement: Monitor supports script-friendly module dispatch
The system SHALL accept a `--apply <module>` flag that runs sampling, prints the report, then dispatches the named module non-interactively.

#### Scenario: `--apply` dispatches module without confirmation
- **WHEN** the user runs `cc-monitor --apply claude-cleanup`
- **THEN** the monitor SHALL complete sampling, print the human report, dispatch `claude-cleanup`, and propagate the module's exit code; the monitor SHALL NOT print a confirmation prompt or interactive menu.

#### Scenario: `--apply` accepts canonical module names
- **WHEN** the user runs `cc-monitor --apply <name>` with `<name>` in {`claude-cleanup`, `claude-guard`, `claude-guard-dry`, `proc-janitor-scan`, `proc-janitor-clean`}
- **THEN** the monitor SHALL dispatch the corresponding command (`claude-cleanup`, `claude-guard`, `claude-guard --dry-run`, `proc-janitor scan`, `proc-janitor clean`).

#### Scenario: `--apply` rejects unknown module
- **WHEN** the user runs `cc-monitor --apply <unknown>`
- **THEN** the monitor SHALL exit with status 2 and print an error to stderr listing the valid module names.

#### Scenario: `--apply` rejects missing binary
- **WHEN** the user runs `cc-monitor --apply <module>` and the underlying binary is not available on PATH
- **THEN** the monitor SHALL exit with status 127 and print an error to stderr identifying the missing binary.

#### Scenario: `--apply` cannot be combined with `--json`
- **WHEN** the user runs `cc-monitor --apply <module> --json` (in any flag order)
- **THEN** the monitor SHALL exit with status 2 and print `--apply cannot be combined with --json` to stderr without sampling or dispatching.

#### Scenario: Dispatched module exits non-zero
- **WHEN** a dispatched module (whether via `--apply` or interactive menu) exits with a non-zero status
- **THEN** the monitor SHALL exit with the same status and SHALL preserve the module's stderr output.

#### Scenario: Dispatch banner separates report from action
- **WHEN** the monitor is about to dispatch a module (via either `--apply` or an interactive menu choice that has been confirmed)
- **THEN** the monitor SHALL print a banner of the form `=== Dispatching <module label> ===` to stderr before executing the module, so the read-only report and the destructive action are visually separated.

#### Scenario: Dispatch resolves sourced shell functions
- **WHEN** the user has installed cleanup modules by sourcing this repo's shell scripts (for example `source shell/claude-cleanup.sh` from `.zshrc`) and `cc-monitor` is invoked from the same shell
- **THEN** dispatching the module SHALL invoke the sourced shell function rather than searching only PATH, and SHALL NOT fail with `command not found` when no matching binary exists on PATH.

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

