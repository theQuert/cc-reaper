# Change: runaway-protected-detection

## Why

`cc-monitor` and `claude-cleanup` deliberately mark long-running MCP servers, dev servers, and security daemons as "protected" to avoid accidentally killing critical or shared services. But "protected" is currently absolute: a process can be stuck at 100% CPU for 9+ hours and the tooling still classifies it as `DO_NOT_KILL`.

This actually happened on 2026-04-30: an `mcp-server-cloudflare` process pinned a CPU core for 9 hours; cc-monitor flagged it as `DO_NOT_KILL`; the user had to manually `kill 9594` after diagnosing it by reading the report. The signal "this protected process is objectively stuck" was visible (avg CPU 102% × etime 9h) but no module surfaced or acted on it.

## What Changes

- Add **runaway detection** to `cc-monitor`: a process matching the protected pattern is reclassified as `ASK_BEFORE_KILL` when its average CPU is ≥ `CC_RUNAWAY_CPU` (default 80) for an etime ≥ `CC_RUNAWAY_MIN` minutes (default 60).
- Add a dedicated **"Stuck/runaway processes"** section at the end of the human report listing each runaway PID with a copy-pasteable `kill <pid>` line.
- Add a new **Phase 0.5 to `claude-guard`**: detect runaway protected processes and kill them in PGID-aware mode after a 5-second Ctrl+C grace window. `CC_RUNAWAY_DISABLE=1` opts out entirely.
- Preserve existing semantics: `claude-cleanup` still never touches protected processes (clear contract). The runaway path requires the explicit `claude-guard` invocation or a deliberate manual kill from the cc-monitor suggestion.

## Impact

- **Affected specs**: `cc-monitor`, `agent-process-reapers` (additive — new requirements, no scenario removals)
- **Affected code**: `shell/cc-monitor.sh` (new helper + classification path + report section); `shell/claude-cleanup.sh` (new claude-guard phase)
- **Tests**: extend `tests/cc-monitor.sh` with runaway-classification cases; add `tests/cc-monitor-runaway.sh` for end-to-end fixture-driven tests of the report section and claude-guard phase
- **Docs**: `README.md` (new env vars + behavior note)
- **Out of scope**: changing protected pattern itself; auto-killing all protected processes without thresholds; per-family runaway thresholds
