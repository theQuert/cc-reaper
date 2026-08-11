## Why

cc-reaper exists to stop other tools leaking resources. Audited against its own scripts, it leaks three ways.

**Logs grow without bound.** Only `cc-reaper-monitor.sh` rotates, at 1 MB. Measured on this host:

| File | Size | Rotated |
|---|---|---|
| `launchd-guard-stdout.log` | 839 KB | no |
| `resource-watch.log` | 722 KB | no |
| `launchd-stderr.log` | 476 KB | no |
| `disk-janitor.log` | 318 KB | no |
| `launchd-disk-check-stdout.log` | 309 KB | no |
| `monitor.log` | 59 KB | yes, 1 MB |

2.6 MB total, with the rotated file the smallest — the mechanism works, it is simply not applied anywhere else. The `launchd-*.log` pair per agent is written by launchd itself via `StandardOutPath`/`StandardErrorPath`, so no script owns them today.

**Notifications are fired and abandoned.** Four `osascript … &` calls run in the background and are never waited on. Under launchd the runner exits first, so each guard run can leave reparented children — the exact shape of leak this project reaps.

**No script installs a `trap`.** `cc-monitor` creates a temp directory with `mktemp -d` and removes it only on the normal path. Its default sampling window is 60 seconds, so interrupting a run is ordinary, and every interrupted run leaves a directory behind.

Two deployment faults were found alongside:

**All five LaunchAgents are `disabled` in the launchd database.** `install.sh` uses `launchctl unload` followed by `launchctl load`, which cannot clear a `disabled` flag and reports nothing when the agent fails to start. The continuous-defence layer has been inert while appearing installed.

**The deployed `claude-cleanup.sh` had drifted 352 lines behind the checkout.** This is inherent, not accidental: `install.sh` copies rather than links because a launchd agent has no TCC access to a `~/Documents` checkout. Interactive shells source the checkout, agents source the copy, so the two diverge until `install.sh` runs again.

## What Changes

- Add `_cc_reaper_rotate_log`, applied to every log cc-reaper writes. Over 1 MB, the file moves to `.old`, keeping one generation — the rule `cc-reaper-monitor.sh` already used.
- Each launchd runner bounds its own `launchd-*.log` pair. Those are held open by launchd, so they are truncated in place rather than moved: moving them would leave launchd appending to the renamed inode.
- Add `_cc_reaper_notify`, which returns immediately without a controlling terminal. Notifications stay for interactive use and stop being spawned where nothing can display them.
- `cc-monitor` traps `EXIT`, `INT`, and `TERM` to remove its temp directory.
- `install.sh` enables, bootstraps, and then verifies each agent, reporting any that did not start.

Not in scope: the copy-versus-link split stays. TCC makes linking unavailable, and re-running `install.sh` is the intended way to resync.

## Capabilities

### Modified Capabilities

- `agent-process-reapers`: cc-reaper's own runners gain bounded logs, terminal-gated notifications, and temp-file cleanup on interrupt.

## Impact

- `shell/claude-cleanup.sh`: two helpers; four `osascript` sites routed through one of them.
- `shell/cc-monitor.sh`, `shell/resource-watch.sh`, `shell/disk-janitor.sh`, `shell/worktree-janitor.sh`, `launchd/cc-reaper-monitor.sh`: rotation, and a trap in `cc-monitor`.
- `install.sh`: agent activation becomes enable + bootstrap + verify.
- Behavior: logs are capped near 2 MB per file across one generation; notifications no longer appear from launchd-run agents; a previously silent install failure becomes a printed error.
