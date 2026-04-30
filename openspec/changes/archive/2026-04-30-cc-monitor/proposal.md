## Why

When a developer laptop gets hot during multiple AI coding sessions, cc-reaper can already clean stale process families, but it does not explain which active processes are causing heat before any cleanup decision. Users need a read-only diagnosis layer that separates safe cleanup candidates from active tools and system processes.

## What Changes

- Add a read-only `cc-monitor` command for short process sampling and one-shot snapshots.
- Attribute CPU pressure by process family, including editor, cmux, Codex, Claude, MCP, agent-browser, Chrome, dev server, system, and other.
- Classify findings as `SAFE_TO_REAP`, `ASK_BEFORE_KILL`, or `DO_NOT_KILL` with a short reason.
- Print a human-readable report with top contributors, family breakdown, safe cleanup candidates, and suggested next actions.
- Support optional JSON output with the same finding structure for future automation, redacting common secret-like command arguments.
- Keep cleanup behavior unchanged; process killing remains in existing cleanup/guard commands.

## Capabilities

### New Capabilities

- `cc-monitor`: Read-only heat attribution and process safety classification for cc-reaper.

### Modified Capabilities

- None.

## Impact

- Adds a new shell monitor script and lightweight validation tests.
- Updates setup and README guidance so users can run the monitor before choosing cleanup actions.
- Reuses existing cc-reaper safety boundaries and process family patterns where practical.
- Tightens shared MCP protection aliases that were already intended by the safety boundary.
- No database, network, daemon, or privileged sensor dependency is introduced.
