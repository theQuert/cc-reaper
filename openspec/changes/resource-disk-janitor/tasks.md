# Tasks: resource-disk-janitor

## 1. resource-watch

- [x] 1.1 [P] `shell/resource-watch.sh` — single-pass snapshot (load/CPU/mem/disk) + log line to `~/.cc-reaper/logs/resource-watch.log`
- [x] 1.2 Threshold evaluation + osascript notification + per-metric cooldown state files (depends 1.1)
- [x] 1.3 [P] `launchd/com.cc-reaper.resource-watch.plist` — 600s interval, Nice+LowPriorityIO
- [x] 1.4 `tests/resource-watch.sh` — stubbed top/df; threshold + cooldown scenarios (depends 1.2)

## 2. disk-janitor

- [x] 2.1 [P] `shell/disk-janitor.sh` — `--check` mode: disk free %, TM snapshot pin detection, alert (read-only)
- [x] 2.2 `--clean` mode: rebuildable cache targets + docker prune (no --volumes) + snapshot thinning, per-target SKIP/freed logging (depends 2.1)
- [x] 2.3 [P] `launchd/com.cc-reaper.disk-check.plist` (1h) + `launchd/com.cc-reaper.weekly-clean.plist` (Sun 04:00), Nice+LowPriorityIO
- [x] 2.4 `tests/disk-janitor.sh` — stubbed tmutil/docker/df; check-is-readonly + forbidden-flag + thinning scenarios (depends 2.2)

## 3. worktree-janitor

- [x] 3.1 [P] `shell/worktree-janitor.sh` — repo discovery + inventory + dual-gate classification (dirty / active-cwd)
- [x] 3.2 Report mode output + `--apply` removal path (`git worktree remove` → force-fallback → prune) + summary (depends 3.1)
- [x] 3.3 `tests/worktree-janitor.sh` — fixture git repos w/ worktrees; dirty-keep, active-keep, clean-remove, apply-gating scenarios (depends 3.2)

## 4. Integration

- [x] 4.1 `install.sh` — install/update step for 3 plists + `~/.cc-reaper/{logs,state}` dirs (depends 1.3, 2.3)
- [x] 4.2 README.md new section + CHANGELOG entry (depends 4.1)
- [x] 4.3 End-to-end smoke on this machine: load plists, verify snapshot log line, verify check-mode alert path, verify worktree report against live repos (depends 4.1)
