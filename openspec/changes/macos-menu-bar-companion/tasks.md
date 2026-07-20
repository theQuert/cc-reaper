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
- [x] 3.6 Make source-built canaries automatically resolve the checkout's complete `shell/` directory when `~/.cc-reaper` is incomplete, preserve installed and explicit-override precedence, show the active root in Settings, and rerun the user-visible canary.
- [x] 4.1 Make cleanup preview and confirmed cleanup use the same `claude-cleanup` policy, add dry-run denial tests, and gate confirmation on a successful preview.
- [x] 4.2 Bound monitor/preview/cleanup subprocesses, terminate timed-out children, and reject monitor payloads that are not `once` + read-only with positive samples.
- [x] 4.3 Separate cleanup health from manual-review/protected evidence, add filters and suggested actions, and show candidate details before confirmation.
- [x] 4.4 Exclude the companion/sampler process tree and protect known UI automation helpers without broadening cleanup eligibility.
- [x] 4.5 Use the stable log root with visible missing-directory errors, then rerun full tests and a background real UI canary.
- [x] 4.6 Bound the dashboard's findings and suggested-action regions, keep cleanup controls stable, and verify default/minimum-window overflow behavior with a real UI canary.

## 5. Add user-managed process policy

- [x] 5.1 Add red Core and shell tests for persistent literal protect/cleanup rules, protect precedence, malformed-file handling, and immutable cleanup denial.
- [x] 5.2 Implement the atomic mode-0600 rule store plus shared monitor/cleanup rule evaluation, preserving stale/detached requirements and same-engine preview/confirmation.
- [x] 5.3 Add native Settings rule management and finding-row actions, refresh the monitor after changes, and prevent immutable findings from being added to cleanup.
- [x] 5.4 Run strict OpenSpec validation, full Swift/shell regression tests, destructive denial proof, diff review, and a background-only default/minimum-window UI/UX canary without changing the user's foreground app.
