## 1. Bounded logs

- [x] 1.1 Add one `_cc_*_bound_log <file> [max_bytes]` — copy to `.old`, then truncate, so the inode survives whoever holds it open
- [x] 1.2 Use it in each runner for its own log and its `launchd-*.log` pair
- [x] 1.3 Apply rotation to `resource-watch.log`, `disk-janitor.log`, `worktree-janitor.log`, and `monitor.log`
- [x] 1.4 Keep each launchd runner self-contained — no new sourcing dependency between deployed scripts

## 2. Notifications

- [x] 2.1 Add `_cc_reaper_notify`, skipping without a controlling terminal
- [x] 2.2 Route all four `osascript` sites through it and drop the background `&`

## 3. Temp cleanup

- [x] 3.1 Trap `EXIT`/`INT`/`TERM` in `cc-monitor` to remove its temp directory, preserving the run's exit status

## 4. Agent installation

- [x] 4.1 `install.sh`: enable, bootstrap, then verify each agent; report failures by label

## 5. Proof

- [x] 5.1 Bounding: over cap, under cap, missing file, inode preserved, and an already-open descriptor
- [x] 5.2 Notification: with and without a terminal, and with the tool failing
- [x] 5.3 Temp cleanup: interrupted run leaves nothing, exit status preserved
- [x] 5.4 Existing suite green under bash and zsh
- [x] 5.5 Confirm no orphan is left by a non-interactive guard run
