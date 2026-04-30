# Tasks: runaway-protected-detection

## 1. cc-monitor classification

- [x] 1.1 Add `_cc_monitor_is_runaway` helper accepting (avg_cpu, etime) and reading `CC_RUNAWAY_CPU` / `CC_RUNAWAY_MIN` env vars with default fallbacks (80, 60)
- [x] 1.2 Update `_cc_monitor_classification` (and family detection) so a protected command meeting runaway thresholds is reclassified to family `runaway` + classification `ASK_BEFORE_KILL`
- [x] 1.3 Add reason text for `ASK_BEFORE_KILL:runaway` describing CPU% × elapsed time
- [x] 1.4 Add suggested-action text for `ASK_BEFORE_KILL:runaway` recommending `kill <pid>` with PGID note
- [x] 1.5 Wire the avg-CPU and etime values through `_cc_monitor_enrich_findings` so the classifier receives them (avg_cpu is already in row; etime already in row)

## 2. cc-monitor report sections

- [x] 2.1 Add a "Stuck/runaway protected processes:" section to `_cc_monitor_human_report` after "Safe cleanup candidates"; print PID, label, avg CPU, etime, and a `kill <pid>` line per finding
- [x] 2.2 Add `runaway_candidates` array to `_cc_monitor_json_report` mirroring `safe_cleanup_candidates` shape

## 3. claude-guard runaway phase

- [x] 3.1 Add helpers in `shell/claude-cleanup.sh` to enumerate runaway protected processes from a `ps` snapshot using the same thresholds (80% / 60min, env-overridable)
- [x] 3.2 Insert "Phase 0.5: Runaway protected" before existing Phase 0 (FD-leak); honor `CC_RUNAWAY_DISABLE=1` opt-out and `--dry-run`
- [x] 3.3 Print runaway list, sleep `CC_RUNAWAY_GRACE_SEC` seconds (default 5), then call `_claude_pgid_kill` per PID
- [x] 3.4 Aggregate freed memory and notify via `osascript` desktop notification (mirror existing phases)

## 4. Tests

- [x] 4.1 Extend `tests/cc-monitor.sh` with classification cases: protected + runaway → runaway/ASK_BEFORE_KILL; protected + cool → DO_NOT_KILL
- [x] 4.2 [P] Create `tests/cc-monitor-runaway.sh` covering: report has "Stuck/runaway" section when fixture has a hot protected process; section is omitted when none
- [x] 4.3 [P] Add JSON output tests for `runaway_candidates` array
- [x] 4.4 [P] Add claude-guard test: `--dry-run` lists runaway candidates without killing; `CC_RUNAWAY_DISABLE=1` skips the phase

## 5. Docs

- [x] 5.1 Add `CC_RUNAWAY_CPU`, `CC_RUNAWAY_MIN`, `CC_RUNAWAY_GRACE_SEC`, `CC_RUNAWAY_DISABLE` to README env var table and CLAUDE.md table
- [x] 5.2 Add a short "Stuck/runaway processes" subsection to README explaining behavior

## 6. Validation

- [x] 6.1 `bash -n shell/cc-monitor.sh && bash -n shell/claude-cleanup.sh`
- [x] 6.2 `bash tests/cc-monitor.sh` passes
- [x] 6.3 `bash tests/cc-monitor-optimize.sh` still passes (no regression)
- [x] 6.4 `bash tests/cc-monitor-runaway.sh` passes
