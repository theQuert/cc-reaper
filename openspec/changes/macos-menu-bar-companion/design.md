## Context

`cc-reaper` is currently a shell-first project. Its `cc-monitor --once --json` command is the authoritative read-only health contract, while `claude-guard --dry-run` remains a standalone guard diagnostic and `claude-cleanup` owns orphan cleanup. The macOS companion must improve visibility without duplicating process classification, changing cleanup eligibility, or silently escalating a read-only interaction into process termination.

The initial app is a local SwiftPM macOS application. It is a development and source-distributed companion, not yet a signed/notarized release artifact.

## Goals / Non-Goals

**Goals:**

- Provide concise menu bar status plus an on-demand dashboard and native settings scene.
- Parse the existing monitor JSON into a testable typed model and expose freshness, CPU, memory, and cleanup-candidate evidence.
- Keep refresh and preview read-only and require explicit in-app confirmation before delegating cleanup.
- Fail closed when the deployed scripts are missing, JSON is invalid, or a subprocess exits non-zero.
- Provide a single reproducible build/test/run entrypoint for the new macOS app.

**Non-Goals:**

- Reimplementing process discovery, classification, or cleanup policy in Swift.
- Automatically deleting worktrees, Time Machine snapshots, caches, or processes from a background GUI timer.
- Replacing the current shell installer or LaunchAgents in this iteration.
- App Store distribution, code signing, notarization, privileged helpers, or automatic updates.

## Decisions

1. **Use SwiftPM with a core library and a SwiftUI executable.** `CCReaperCore` owns decoding, command execution, settings inputs, and observable app state; `CCReaperApp` owns macOS scenes and views. This keeps command behavior unit-testable without launching UI and avoids introducing an Xcode project solely for the MVP.

2. **Use `MenuBarExtra`, `WindowGroup`, and `Settings`.** The menu bar provides small status and review entry points, the main window carries findings and confirmations, and preferences use the native settings scene. The main app remains a regular foreground app for first-run discoverability rather than silently shipping as a no-Dock accessory.

3. **Treat the same existing cleanup engine as the preview and execution boundary.** A scan executes `/bin/bash <root>/cc-monitor.sh --once --json --min-cpu <value>`. Preview and cleanup source `<root>/claude-cleanup.sh` through a fixed Bash program with the script path passed as a positional argument, then call `claude-cleanup --dry-run` or `claude-cleanup`. Dry-run traverses the same candidate policy but routes every signal through a no-op reporter. User-controlled paths are never interpolated into shell source text.

4. **Resolve the engine root automatically and keep an explicit override.** A saved settings override wins. Otherwise the app prefers a complete `~/.cc-reaper` installation and, for a bundle staged under the repository's `dist/` directory, falls back to that checkout's complete `shell/` directory. `install.sh` deploys `cc-monitor.sh` beside the existing cleanup script. Missing files in every eligible root produce an unavailable state with an install hint.

5. **Keep destructive intent in the dashboard and preview before confirmation.** The menu bar can refresh and open the dashboard, but it does not terminate processes directly. Cleanup review first runs the same-engine dry-run and displays its output; only a successful preview may present a destructive confirmation that includes the current candidate count and PIDs. Cancel sends no cleanup command. After confirmed cleanup the app refreshes its read-only report.

6. **Use an injected, bounded asynchronous command runner.** Production uses `Process`; tests substitute a runner that records executable/arguments and returns fixture output. stdout and stderr are captured separately, non-zero status is preserved, scan/preview/cleanup receive explicit timeouts, timed-out children are terminated, and decoding never falls back to fabricated healthy data. A decoded monitor payload is accepted only when it confirms `mode: once`, `read_only: true`, and a positive sample count.

7. **Use one project-local run loop.** `script/build_and_run.sh` builds the SwiftPM product, stages `dist/CCReaper.app`, and supports run/debug/log/telemetry/verify modes. `.codex/environments/environment.toml` points its Run action to that script.

8. **Keep automated verification in the background.** The verify mode launches the staged bundle with macOS background activation and a dedicated app argument that suppresses foreground activation. It records and terminates only the verification process it created, preserving any pre-existing cc-reaper process and the user's current foreground application.

9. **Separate cleanup state from resource-review evidence.** App health is critical for runaway findings, attention for safe cleanup candidates, and otherwise healthy/no-cleanup-needed. Manual-review and protected findings remain visible as independent counts and selectable filters rather than forcing the global menu bar status orange. The dashboard defaults to the cleanup filter and exposes backend suggested actions in a compact secondary section.

10. **Keep engine and log roots distinct.** The configurable script root locates executable policy scripts. Logs continue to live under `~/.cc-reaper/logs`, matching the existing shell and LaunchAgent contract; opening a missing log directory reports an in-app error rather than silently asking Finder to open an invalid path.

11. **Bound dense dashboard regions instead of allowing report volume to drive window layout.** The dashboard keeps its cleanup controls in a stable footer, places the main report surface in an outer scroll region, gives findings a bounded list height, and limits the visible suggestion stack with an explicit expansion control. Long process labels and actions truncate or wrap within their assigned columns rather than widening or vertically displacing the window.

## Risks / Trade-offs

- [The monitor JSON contract changes] → Decode required top-level evidence strictly, tolerate additive fields, and cover a representative fixture in tests.
- [A configured script root is malicious or incorrect] → Require expected regular files, pass paths as process arguments rather than shell interpolation, and show command failures instead of retrying destructively.
- [The GUI appears authoritative while data is stale] → Display last refresh time, refresh on launch and at the configured interval, and distinguish loading/error/unknown from healthy.
- [Cleanup runs longer than expected] → Keep process execution asynchronous, disable overlapping actions, apply operation-specific timeouts, terminate a timed-out child, and display the timeout without retrying.
- [Dry-run and cleanup drift] → Implement both modes in the same `claude-cleanup` function and route all process signals through one dry-run-aware helper covered by shell tests.
- [A busy real Mac produces many protected findings] → Default the dashboard to cleanup-relevant evidence, preserve explicit Review/Protected/All filters, and keep all decoded evidence available without treating it as cleanup urgency.
- [A busy report overflows the default window] → Keep the footer stable, bound nested finding/action regions, and verify the default and minimum window sizes against real report volume.
- [SwiftPM app bundling differs from a release build] → Keep the bundle staging script deterministic; defer signing/notarization to a separate distribution change.

## Migration Plan

1. Install or update cc-reaper so `~/.cc-reaper/cc-monitor.sh` and `claude-cleanup.sh` are present.
2. Build and launch the companion through the project run script.
3. Existing CLI, Stop hook, and LaunchAgent behavior remain unchanged when the app is absent or closed.
4. Roll back by quitting/removing the local app bundle; no data or configuration migration is required.

## Open Questions

None. Signing, notarization, app installation, and update delivery are intentionally deferred.
