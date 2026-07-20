## Context

`cc-reaper` is currently a shell-first project. Its `cc-monitor --once --json` command is the authoritative read-only health contract, while `claude-guard --dry-run` and `claude-cleanup` are the existing preview and cleanup engines. The macOS companion must improve visibility without duplicating process classification, changing cleanup eligibility, or silently escalating a read-only interaction into process termination.

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

3. **Treat existing shell commands as the policy boundary.** A scan executes `/bin/bash <root>/cc-monitor.sh --once --json --min-cpu <value>`. Preview and cleanup source `<root>/claude-cleanup.sh` through a fixed Bash program with the script path passed as a positional argument, then call `claude-guard --dry-run` or `claude-cleanup`. User-controlled paths are never interpolated into shell source text.

4. **Resolve the engine root automatically and keep an explicit override.** A saved settings override wins. Otherwise the app prefers a complete `~/.cc-reaper` installation and, for a bundle staged under the repository's `dist/` directory, falls back to that checkout's complete `shell/` directory. `install.sh` deploys `cc-monitor.sh` beside the existing cleanup script. Missing files in every eligible root produce an unavailable state with an install hint.

5. **Keep destructive intent in the dashboard.** The menu bar can refresh, preview, and open the dashboard, but it does not terminate processes directly. The dashboard presents a destructive confirmation that names the action; cancel sends no command. After confirmed cleanup the app refreshes its read-only report.

6. **Use an injected asynchronous command runner.** Production uses `Process`; tests substitute a runner that records executable/arguments and returns fixture output. stdout and stderr are captured separately, non-zero status is preserved, and decoding never falls back to fabricated healthy data.

7. **Use one project-local run loop.** `script/build_and_run.sh` builds the SwiftPM product, stages `dist/CCReaper.app`, and supports run/debug/log/telemetry/verify modes. `.codex/environments/environment.toml` points its Run action to that script.

8. **Keep automated verification in the background.** The verify mode launches the staged bundle with macOS background activation and a dedicated app argument that suppresses foreground activation. It records and terminates only the verification process it created, preserving any pre-existing cc-reaper process and the user's current foreground application.

## Risks / Trade-offs

- [The monitor JSON contract changes] → Decode required top-level evidence strictly, tolerate additive fields, and cover a representative fixture in tests.
- [A configured script root is malicious or incorrect] → Require expected regular files, pass paths as process arguments rather than shell interpolation, and show command failures instead of retrying destructively.
- [The GUI appears authoritative while data is stale] → Display last refresh time, refresh on launch and at the configured interval, and distinguish loading/error/unknown from healthy.
- [Cleanup runs longer than expected] → Keep process execution asynchronous, disable overlapping actions, display captured progress/result text, and allow a later cancellation feature without changing command policy.
- [SwiftPM app bundling differs from a release build] → Keep the bundle staging script deterministic; defer signing/notarization to a separate distribution change.

## Migration Plan

1. Install or update cc-reaper so `~/.cc-reaper/cc-monitor.sh` and `claude-cleanup.sh` are present.
2. Build and launch the companion through the project run script.
3. Existing CLI, Stop hook, and LaunchAgent behavior remain unchanged when the app is absent or closed.
4. Roll back by quitting/removing the local app bundle; no data or configuration migration is required.

## Open Questions

None. Signing, notarization, app installation, and update delivery are intentionally deferred.
