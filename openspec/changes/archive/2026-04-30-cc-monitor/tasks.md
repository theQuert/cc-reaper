## 1. Monitor CLI And Sampling

- [x] 1.1 Create `shell/cc-monitor.sh` with CLI parsing, defaults, usage, and read-only execution path.
- [x] 1.2 Implement process snapshot parsing and sample aggregation for average/max CPU and RSS.
- [x] 1.3 Implement family and safety classification using conservative cc-reaper-compatible patterns.

## 2. Reports And Integration

- [x] 2.1 Implement human report sections for sample metadata, top contributors, family totals, safe candidates, and suggested actions.
- [x] 2.2 Implement `--json` output with valid structured metadata, findings, family totals, suggested actions, and secret redaction.
- [x] 2.3 Wire the monitor into shell setup and user-facing command documentation.

## 3. Verification And Delivery

- [x] 3.1 Add lightweight tests for classifier behavior, aggregation, and JSON output.
- [x] 3.2 Run shell syntax checks, monitor tests, OpenSpec validation, and diff checks.
- [x] 3.3 Review the completed change for simplification before commit/push.
