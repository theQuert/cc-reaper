# macos-menu-bar-companion Specification

## Purpose
Native macOS menu bar companion surfacing cc-reaper health read-only, with explicit user-initiated cleanup, user-managed process rules that cannot widen the engine's kill boundaries, and a reproducible local build workflow.

## Requirements
### Requirement: Native status surfaces
The system SHALL provide a macOS menu bar companion with a main dashboard and a dedicated settings window. The menu bar SHALL remain concise and SHALL route detailed review to the dashboard.

#### Scenario: User launches the companion
- **WHEN** the companion starts
- **THEN** it SHALL present a menu bar status item, make the dashboard available, and begin a read-only status refresh

#### Scenario: User requests details from the menu bar
- **WHEN** the user selects the review or dashboard action
- **THEN** the companion SHALL open and activate the main dashboard without running cleanup

#### Scenario: User opens settings
- **WHEN** the user selects the native settings action
- **THEN** the companion SHALL open a dedicated settings scene rather than navigating the dashboard away from status

### Requirement: Read-only health reporting
The companion SHALL obtain health evidence from the installed `cc-monitor --once --json` contract and SHALL display the report's freshness, CPU, memory, classifications, and safe cleanup candidate count without sending signals.

#### Scenario: Initial scan succeeds
- **WHEN** the companion receives valid monitor JSON
- **THEN** it SHALL display the decoded findings and family totals, record the refresh time, derive cleanup health from safe/runaway classifications, and expose manual-review/protected counts separately

#### Scenario: Monitor payload is not a read-only once sample
- **WHEN** the monitor exits successfully but the JSON has a mode other than `once`, `read_only` is false, or `sample_count` is not positive
- **THEN** the companion SHALL reject the payload as unavailable and SHALL NOT display it as a read-only sample

#### Scenario: User refreshes status
- **WHEN** the user selects refresh
- **THEN** the companion SHALL run another read-only monitor scan and SHALL NOT invoke a cleanup command

#### Scenario: Automatic refresh interval elapses
- **WHEN** the configured positive refresh interval elapses while the companion is running
- **THEN** it SHALL refresh through the same read-only monitor command

#### Scenario: Monitor evidence is unavailable
- **WHEN** the monitor script is missing, exits non-zero, or emits malformed JSON
- **THEN** the companion SHALL show an unavailable or error state with actionable detail and SHALL NOT report the system healthy

### Requirement: Explicit cleanup safety
The companion SHALL keep preview non-destructive and SHALL require explicit confirmation in the dashboard before invoking the existing `claude-cleanup` engine. It SHALL NOT implement an independent process termination policy.

#### Scenario: User requests a preview
- **WHEN** the user selects preview cleanup
- **THEN** the companion SHALL invoke the existing `claude-cleanup --dry-run` policy, display its output, and SHALL NOT send cleanup signals

#### Scenario: Cleanup review previews before confirmation
- **WHEN** the user selects cleanup review while safe candidates exist
- **THEN** the companion SHALL complete a successful same-engine dry-run first, display its output, and only then present confirmation with the sampled candidate count and PIDs

#### Scenario: User starts cleanup review from the menu bar
- **WHEN** the user selects the cleanup review action in the menu bar
- **THEN** the companion SHALL open the dashboard and SHALL NOT invoke cleanup directly from the menu bar

#### Scenario: User cancels cleanup
- **WHEN** the destructive confirmation is visible and the user cancels or dismisses it
- **THEN** the companion SHALL invoke no cleanup command

#### Scenario: User confirms cleanup
- **WHEN** the user explicitly confirms cleanup in the dashboard
- **THEN** the companion SHALL invoke the existing `claude-cleanup` function once, display its result, and then refresh the read-only monitor report

#### Scenario: Cleanup command fails
- **WHEN** the delegated cleanup command exits non-zero
- **THEN** the companion SHALL surface the failure and captured error without claiming cleanup succeeded or retrying automatically

#### Scenario: Cleanup review preview fails
- **WHEN** the same-engine dry-run exits non-zero
- **THEN** the companion SHALL show the preview failure and SHALL NOT present destructive confirmation

#### Scenario: Command exceeds its operation timeout
- **WHEN** monitor, preview, or cleanup does not exit before its operation-specific timeout
- **THEN** the companion SHALL terminate the child process, show a timeout error, and SHALL NOT retry automatically

### Requirement: User-managed process rules preserve safety boundaries
The companion SHALL let users manage case-insensitive literal command-substring rules through Settings and eligible finding rows, persist those rules atomically in `~/.cc-reaper/process-rules.tsv` with owner-only permissions, and share the resulting policy with the monitor and cleanup engines.

#### Scenario: User adds an Always Protect rule
- **WHEN** the user adds an `Always Protect` rule for a valid literal command substring
- **THEN** the companion SHALL persist the rule, refresh the report, classify matching commands as protected, and the cleanup engines SHALL reject those commands at candidate and signal boundaries

#### Scenario: User allows stale cleanup
- **WHEN** the user adds an `Allow Stale Cleanup` rule for an eligible non-immutable process
- **THEN** the matching process SHALL become a cleanup candidate only after it is stale and detached or orphaned, and cleanup SHALL still require same-engine preview and explicit confirmation

#### Scenario: Rule file contains conflicts or malformed entries
- **WHEN** externally edited rules contain malformed rows or both policies for the same case-insensitive literal
- **THEN** malformed rows SHALL be ignored and `Always Protect` SHALL win the conflict

#### Scenario: Finding row represents an immutable process
- **WHEN** a finding row represents a system, security, UI, normal Chrome, cc-reaper, or Codex Computer Use process
- **THEN** the companion SHALL withhold the finding-row cleanup-rule action

#### Scenario: Persisted cleanup literal matches an immutable process
- **WHEN** a cleanup rule saved through Settings matches an immutable process
- **THEN** the monitor and cleanup engines SHALL ignore its cleanup effect and preserve the immutable classification and signal denial

#### Scenario: Rules are saved or removed
- **WHEN** a valid rule between 3 and 128 characters without tabs or line breaks is saved
- **THEN** the store SHALL write it atomically with mode `0600`, replace an existing case-insensitive match, and remove the rules file when the final rule is deleted

### Requirement: Configurable local integration
The companion SHALL automatically resolve a complete local script root and SHALL provide persistent native settings for an explicit script-root override, monitor reporting threshold, and automatic refresh interval.

#### Scenario: Default installation is present
- **WHEN** the expected monitor and cleanup scripts exist under the default script root
- **THEN** the companion SHALL use those files without additional configuration

#### Scenario: Source canary has no complete default installation
- **WHEN** no script-root override is saved, the default installation is incomplete, and the app bundle is staged under a source checkout whose `shell` directory contains the expected monitor and cleanup scripts
- **THEN** the companion SHALL use that source `shell` directory without requiring the user to edit settings

#### Scenario: Both installed and source roots are complete
- **WHEN** no script-root override is saved and both the default installation and staged source roots contain the expected scripts
- **THEN** the companion SHALL prefer the default installation

#### Scenario: User supplies a different script root
- **WHEN** the user saves a non-default script root
- **THEN** subsequent commands SHALL resolve only the expected script filenames under that root and SHALL pass the resolved path as a process argument rather than interpolating it into shell source

#### Scenario: User clears the script-root override
- **WHEN** the user restores automatic script-root selection
- **THEN** the companion SHALL resume installed-then-source automatic resolution and SHALL show the active resolved path in Settings

#### Scenario: Script root is incomplete
- **WHEN** a required script is not a regular file under the configured root
- **THEN** the companion SHALL deny the affected action and show an installation or path correction hint

#### Scenario: Logs use the stable installed log root
- **WHEN** the user opens logs while the script root is an automatic source checkout or an explicit custom root
- **THEN** the companion SHALL open `~/.cc-reaper/logs` and SHALL show an in-app error when that directory is unavailable

### Requirement: Actionable finding review
The dashboard SHALL separate cleanup availability from general resource-review evidence and SHALL expose filtered findings and backend suggestions without changing cleanup policy.

#### Scenario: Busy machine has only manual-review or protected findings
- **WHEN** a report has no safe cleanup or runaway candidates but has manual-review or protected findings
- **THEN** the companion SHALL show a no-cleanup-needed status, display the separate review/protected counts, and SHALL NOT make the global cleanup status orange solely because of those findings

#### Scenario: User selects a finding filter
- **WHEN** the user chooses Cleanup, Review, Protected, or All findings
- **THEN** the dashboard SHALL show only findings matching that classification and preserve the decoded report counts

#### Scenario: Monitor provides suggested actions
- **WHEN** the report contains suggested actions or a finding-specific suggested action
- **THEN** the dashboard SHALL display those suggestions near the relevant review surface

#### Scenario: Busy report is shown in a bounded dashboard window
- **WHEN** the selected filter or suggested actions contain more content than fits in the current dashboard window
- **THEN** the dashboard SHALL preserve access to the status header, summary, findings, suggestions, and cleanup controls through bounded regions or scrolling without clipping content outside the window

### Requirement: Reproducible local app workflow
The repository SHALL provide a SwiftPM build and test workflow plus a single project-local script that stages and launches a valid macOS app bundle.

#### Scenario: Developer builds and tests
- **WHEN** the developer runs the standard SwiftPM build and test commands
- **THEN** the core library, app executable, parser tests, and command-delegation tests SHALL complete without requiring an Xcode project

#### Scenario: Developer runs the app entrypoint
- **WHEN** the developer runs `script/build_and_run.sh`
- **THEN** it SHALL stop a previous task-owned app process, build the current worktree, stage `dist/CCReaper.app`, and launch the staged bundle

#### Scenario: Automated launch verification runs beside other work
- **WHEN** the developer runs `script/build_and_run.sh --verify`
- **THEN** it SHALL launch the staged bundle without requesting foreground activation, confirm that a new verification process started, terminate only that verification process, and preserve any pre-existing cc-reaper process

#### Scenario: Developer supplies an unsupported run mode
- **WHEN** the developer supplies an unsupported argument to `script/build_and_run.sh`
- **THEN** it SHALL exit with usage status before stopping an app process or starting a build

#### Scenario: Codex Run action is used
- **WHEN** the repository is opened in Codex and the Run action is selected
- **THEN** the action SHALL invoke `./script/build_and_run.sh`
