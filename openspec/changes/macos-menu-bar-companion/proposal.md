## Why

`cc-reaper` already exposes safe diagnostics, structured monitor output, and explicit cleanup commands, but users must open a terminal to discover current health, inspect candidates, or verify that automation is working. A lightweight macOS companion can make those existing safety contracts visible and approachable without moving cleanup policy into a second implementation.

## What Changes

- Add a native macOS menu bar companion with an on-demand dashboard and dedicated settings window.
- Read current process health through `cc-monitor --once --json` and show candidate, CPU, memory, and freshness evidence.
- Keep refresh and preview read-only; route destructive cleanup through the existing `claude-cleanup` engine only after explicit confirmation.
- Surface unavailable scripts, malformed output, and command failures as visible unknown/error states rather than reporting the system healthy.
- Add a reproducible SwiftPM build/test/run path and install the existing monitor script alongside the other deployed cc-reaper scripts.

## Capabilities

### New Capabilities

- `macos-menu-bar-companion`: Native menu bar status, dashboard review, settings, read-only preview, and confirmed delegation to existing cc-reaper commands.

### Modified Capabilities

<!-- none -->

## Impact

- Adds a SwiftPM macOS executable and testable core module under `Sources/` and `Tests/`.
- Adds a project-local app bundle build/run script and Codex Run action.
- Updates `install.sh` so `cc-monitor.sh` is available at the stable deployed script root used by the app.
- Reuses the existing JSON and cleanup command contracts; it does not change process classification or deletion policy.
