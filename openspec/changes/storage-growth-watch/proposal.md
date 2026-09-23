# Storage growth watch

## Why

The host this runs on loses disk to a handful of places that grow in bursts: task worktrees
(91 GB under one root on 2026-09-22), session scratchpads (one session's 592 export trees
reached 163.8 GiB and stalled every CI runner on 2026-09-15), package and build caches, and
Docker volumes (the CI cache volume measured 21.7 GB against an intended 8 GB cap). The
existing signals say only that free space fell: `disk-janitor --check` compares a percentage
with a floor, and `resource-watch` flags a 10 GB fall in 30 minutes. Neither says which path
grew, so every incident starts with a manual `du` hunt, and the owner of the growth (CI, a
hook, a reclaimer, a session) is guessed.

## What Changes

- `disk-janitor --check` samples configured growth targets: directories, glob-expanded
  directories sampled one key per match, and Docker categories and volumes. Each key is
  measured at most once per interval, oldest first, at low priority, within a per-run time
  budget, so the hourly check stays cheap and a large tree is never walked twice in a day.
- Samples go to `state/growth-samples.tsv` (14 days). An unreadable, vanished or timed-out
  target is recorded as that status, never as zero.
- Growth is computed per key and per label total against a sample about a day old. A key or
  total that grew by its alert threshold logs `ALERT:growth` with the target's owner label
  and posts one cooldown-gated notification; every sampling run logs its top growers.
- `config/growth-targets.tsv` ships generic defaults (harness worktrees and scratchpads,
  caches, temp, transcripts, Docker) and an installer that keeps an operator-edited copy.

## Impact

- Read-only: nothing is removed. The cost is bounded by the budget and the interval.
- `python3` is required for the watch; without it the step is a counted `SKIP`.
- Consumers: the monitoring loop reads `ALERT:growth` and the owner label to decide whether
  CI, a hook, a reclaimer or a session caused the growth.
