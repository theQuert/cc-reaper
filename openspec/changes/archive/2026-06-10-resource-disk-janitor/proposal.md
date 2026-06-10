# Proposal: resource-disk-janitor

## Why

cc-reaper today covers **process hygiene** (orphan subagents, MCP servers, stale browser automation) but has no answer for the other two resource drains that took a machine to Load 31 / 95% disk on 2026-06-10: **system-level overload going unnoticed** (load/memory/disk creep with no alerting) and **disk exhaustion from rebuildable artifacts** (build caches, docker build cache, TM-snapshot-pinned space, accumulated git worktrees). That incident was resolved manually (Load 31→2.7, disk free 43G→216G); this change scripts those exact operations so they run continuously in the background at near-zero cost.

## What Changes

- New `resource-watch` script: lightweight system snapshot (load avg, CPU idle, memory pressure, disk free) in a single pass (<1s CPU), threshold-gated macOS notification + log line.
- New `disk-janitor` script: safe cleanup of **rebuildable-only** targets — go-build / yarn / pip / brew / bun caches, Spotify / ShipIt caches, CoreSimulator caches, `docker system prune -af` (NEVER `--volumes`) — plus **TM local-snapshot pin detection** (freed space that `df` doesn't show) with thinning.
- New `worktree-janitor` script: generalizes the 2026-06-10 manual procedure — inventories all git worktrees of configured repos, classifies `dirty=0` + no-active-session-cwd as removable, **default dry-run report**; deletion only on explicit `--apply`.
- Three launchd agents (all `Nice` + `LowPriorityIO`): 10-min resource snapshot, 1-hour disk threshold check, weekly (Sunday) deep cache clean.
- `install.sh` integration: new step installs the three plists and creates `~/.cc-reaper/logs/`.
- Notification cooldown so repeated threshold breaches don't spam Notification Center.

## Capabilities

### New Capabilities
- `resource-watch`: system-level load/CPU/memory/disk snapshotting, thresholds, alerting with cooldown, logging.
- `disk-janitor`: safe rebuildable-cache cleanup, docker build-cache prune, TM snapshot pin detection/thinning, weekly deep-clean schedule.
- `worktree-janitor`: multi-repo git worktree inventory, dirty/active-session safety gates, dry-run-by-default removal.

### Modified Capabilities

<!-- none — cc-monitor and agent-process-reapers requirements are untouched; this is additive -->

## Impact

- New files: `shell/resource-watch.sh`, `shell/disk-janitor.sh`, `shell/worktree-janitor.sh`, `launchd/com.cc-reaper.resource-watch.plist`, `launchd/com.cc-reaper.disk-check.plist`, `launchd/com.cc-reaper.weekly-clean.plist`, tests for each script.
- Modified: `install.sh` (new install step), `README.md` (new section), `CHANGELOG.md`.
- No changes to existing reaper/monitor code paths; no shared state with cc-monitor beyond the `~/.cc-reaper/logs/` directory convention.
- Safety boundaries (hard): never touch user data (Documents/Downloads/WG), never `docker system prune --volumes`, never kill processes (existing cc-reaper scope), never touch any database, never remove a worktree that is dirty or hosts an active process cwd.
