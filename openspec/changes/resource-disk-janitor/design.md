# Design: resource-disk-janitor (Lite)

## Architecture

Three standalone bash scripts under `shell/`, mirroring the existing cc-reaper style (self-contained, sourceable functions, `--help`, env-var config, testable via function extraction). Three launchd plists under `launchd/`, mirroring `com.cc-reaper.orphan-monitor.plist` conventions, all with `Nice` (10) and `LowPriorityIO` (true).

```
launchd (10min)  → shell/resource-watch.sh        → snapshot + threshold alert
launchd (1h)     → shell/disk-janitor.sh --check  → read-only disk/snapshot-pin check + alert
launchd (Sun 4am)→ shell/disk-janitor.sh --clean  → rebuildable cache clean + snapshot thinning
manual           → shell/worktree-janitor.sh [--apply] → report (default) / gated removal
launchd (1h, piggyback on disk check) → worktree-janitor report mode (notify if big REMOVABLE total)
```

## Key decisions

1. **Shared helpers in each script, not a new lib file** — cc-reaper's existing scripts are self-contained; follow that convention. The only shared surface is `~/.cc-reaper/logs/` + `~/.cc-reaper/state/` (cooldown files).
2. **Notification = osascript `display notification`** with per-metric cooldown state files (`state/cooldown-<metric>`， mtime-based). No third-party notifier dependency.
3. **Worktree janitor never schedules deletion** — launchd runs report mode only; `--apply` is human-invoked. This encodes the 2026-06-10 session's human-confirm flow.
4. **Active-session detection**: enumerate candidate pids (`pgrep -f 'claude|codex|node|bun'` + shells), resolve each cwd via `lsof -p <pid> -a -d cwd`, match prefix against worktree path. Conservative: lsof failure ⇒ treat as active (KEEP).
5. **TM snapshot thinning only deletes dated `com.apple.TimeMachine.*` snapshots**, never `com.apple.os.update-*`.
6. **Config via env with defaults** (consistent with cc-monitor's `CC_MONITOR_*` pattern): `CC_RW_*` for watch thresholds, `CC_DJ_*` for disk janitor, `CC_WJ_*` for worktree janitor.

## Testing

Follow `tests/*.sh` existing pattern (pure-bash test harnesses invoking extracted functions with fixture data / stubbed commands). Stub `top`/`df`/`tmutil`/`docker`/`git`/`lsof` via PATH-shimming in tests; no destructive ops in CI.
