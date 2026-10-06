# Bound a janitor sweep so it finishes, yields, and still frees disk under load

## Why

On 2026-10-06, with host load 50-70 and 37 GiB free, scheduled sweeps took 1667 s, 5913 s and
more than 80 minutes. A sweep holds the repository lock the whole time, so every SessionEnd sweep
in that window logged "deferred to it and removed nothing". Nothing bounds a sweep's total time:
each bounded call (`git fetch` 180 s, machine-wide `lsof` up to 180 s, several `gh` proofs of
30 s) is multiplied by the worktree count. The pressure trim runs only after the removal sweep,
so the slower the sweep, the later the disk is freed, and it re-runs the machine-wide holder and
session scans before every cache directory. The `lsof` timeouts are hardcoded, so a scan that
needs 70 s at load 60 fails and the janitor keeps everything.

## What Changes

- **Sweep budget.** `CC_WJ_SWEEP_BUDGET_SECONDS` (default 1800, `0` = unbounded) bounds each
  phase of a run. Past it, the sweep stops examining worktrees, releases the lock, logs how many
  were left unexamined, and exits 0. Unexamined worktrees are kept.
- **Rotation.** A per-repository cursor under `~/.cc-reaper/state/` makes the next sweep start
  after the last worktree examined, so a bounded sweep does not re-examine the same head of the
  list every time.
- **Trim first under pressure.** A scheduled run under disk pressure runs the trim phase before
  the removal phase; each phase gets its own budget.
- **Fewer rescans in trim.** Before a later cache directory in the same worktree, a holder and
  session snapshot younger than `CC_WJ_RECHECK_FRESH_SECONDS` (default 120) is reused instead of
  rescanning the machine. Removal keeps its fresh rescan.
- **Configurable scan timeouts, one retry.** `CC_WJ_LSOF_TIMEOUT_SECONDS` (default 120) bounds the
  machine-wide scans and `CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS` (default 30) the Codex lock registry
  scan; a timed-out scan is retried once before it counts as failed.
- **Lock heartbeat.** The lock is refreshed at every worktree boundary.

## Non-goals

- No gate is weakened: a failed scan still keeps every worktree and every cache directory.
- No change to which worktrees are removable.

## Capabilities

- Modified: `worktree-janitor`.
