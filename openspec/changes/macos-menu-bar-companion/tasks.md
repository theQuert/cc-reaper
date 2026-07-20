## 1. Lock the native integration contract

- [x] 1.1 Add SwiftPM core/app/test targets and red tests for monitor JSON decoding, unavailable evidence, and safe command delegation.
- [x] 1.2 Implement typed report models, the injected asynchronous command runner, script-root validation, and observable health state until the core tests pass.

## 2. Deliver the macOS companion surfaces

- [x] 2.1 Add the regular macOS app scene with concise `MenuBarExtra`, main dashboard, native settings, and launch/read-only refresh behavior.
- [x] 2.2 Add preview output, dashboard-only destructive confirmation, confirmed existing-engine cleanup, post-action refresh, error states, and log-folder access.

## 3. Make the app reproducible and shippable from source

- [x] 3.1 Update installation to deploy `cc-monitor.sh`, document the companion workflow, and add the canonical `script/build_and_run.sh` plus Codex Run action.
- [x] 3.2 Run strict OpenSpec validation, Swift build/tests, shell regression checks, app-bundle plist validation, and `--verify` launch evidence; inspect the final diff and destructive denial paths.
- [x] 3.3 Make `--verify` background-only and process-scoped so automated GUI checks do not steal focus or terminate a pre-existing cc-reaper instance; prove launch-mode parsing, process cleanup, and unchanged foreground identity.
- [x] 3.4 Run a background-only UI/UX canary against the real monitor contract, inspect the dashboard accessibility tree and screenshot, confirm the foreground application remains unchanged, and remove the isolated canary bundle/settings/process.
- [x] 3.5 Reject unsupported run modes before any process or build mutation, and verify the failure is side-effect-free.
