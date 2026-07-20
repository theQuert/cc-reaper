## Why

`cc-reaper` already exposes safe diagnostics, structured monitor output, and explicit cleanup commands, but users must open a terminal to discover current health, inspect candidates, or verify that automation is working. A lightweight macOS companion can make those existing safety contracts visible and approachable without moving cleanup policy into a second implementation.

## What Changes

- Add a native macOS menu bar companion with an on-demand dashboard and dedicated settings window.
- Read current process health through `cc-monitor --once --json` and show candidate, CPU, memory, and freshness evidence.
- Keep refresh and preview read-only; route destructive cleanup through the existing `claude-cleanup` engine only after explicit confirmation.
- Make cleanup preview exercise the same `claude-cleanup` policy as confirmation, bound command execution, and require a successful preview before destructive confirmation.
- Separate cleanup availability from general resource-review findings, reduce monitor self-noise, and provide filtered actionable views with the backend's suggested actions.
- Keep dense findings and suggested actions usable at the default and minimum dashboard sizes without clipping the header, metrics, or cleanup controls.
- Let users persist literal process-command rules from Settings or a finding row: `Always Protect` or `Allow Stale Cleanup`, instead of requiring every user-specific process family to be hardcoded.
- Keep an immutable safety floor for system, security, UI, and cc-reaper processes; a user cleanup rule only makes a matching non-system process eligible after the existing stale and detached/orphan checks, and cleanup still requires same-engine preview and explicit confirmation.
- Surface unavailable scripts, malformed output, and command failures as visible unknown/error states rather than reporting the system healthy.
- Add a reproducible SwiftPM build/test/run path and install the existing monitor script alongside the other deployed cc-reaper scripts.

## Capabilities

### New Capabilities

- `macos-menu-bar-companion`: Native menu bar status, dashboard review, settings, read-only preview, and confirmed delegation to existing cc-reaper commands.

### Modified Capabilities

- `cc-monitor`: Exclude the monitor/app sampling process tree and protect known companion/UI automation services from misleading manual-kill classification.

## Impact

- Adds a SwiftPM macOS executable and testable core module under `Sources/` and `tests/`.
- Adds a project-local app bundle build/run script and Codex Run action.
- Updates `install.sh` so `cc-monitor.sh` is available at the stable deployed script root used by the app.
- Extends `claude-cleanup` with a non-destructive dry-run mode while preserving the existing cleanup policy and normal invocation.
- Adds a mode-0600 `~/.cc-reaper/process-rules.tsv` policy file shared by the app, monitor, and cleanup engine; missing or malformed entries fail closed.
- Refines monitor presentation classification only for task-owned sampler/app processes; it does not broaden deletion eligibility.
