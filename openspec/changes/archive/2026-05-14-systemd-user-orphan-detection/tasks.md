# Tasks: systemd-user-orphan-detection

## 1. Shared orphan-parent helpers (claude-cleanup.sh)

- [x] 1.1 Add `_cc_reaper_orphan_ppids` to `shell/claude-cleanup.sh`: scan `ps -eo pid=,uid=,command=` for `systemd --user` processes owned by `id -u`, return `1` plus any matches; memoize in a script-scope var so repeated calls in loops do one `ps` scan
- [x] 1.2 Add `_cc_reaper_is_orphan_ppid` predicate: return true when a given PPID is in the orphan-parent set (used by per-process checks)

## 2. Route claude-cleanup.sh call sites through the set

- [x] 2.1 Update `_cc_reaper_is_detached_or_orphan` to test PPID membership via `_cc_reaper_is_orphan_ppid` instead of the literal `[ "$ppid" = "1" ]`
- [x] 2.2 Update the two agent-candidate checks (`_cc_reaper_is_agent_cleanup_candidate` browser path + codex/mcp path) so their `[ "$ppid" = "1" ]` shortcuts use `_cc_reaper_is_orphan_ppid`
- [x] 2.3 Update `_cc_reaper_ppid_fallback` and the `orphan_pgids` scan in `claude-cleanup` so their `awk '$2 == 1'` / `$2 == 1` clauses match any PID in the orphan-parent set; ensure a `systemd --user` manager PID is never itself selected as a candidate
- [x] 2.4 Update the "Orphans (PPID=1)" report scan so it lists processes parented to any orphan parent; keep the section heading accurate for both platforms

## 3. Inline detection in the Stop hook

- [x] 3.1 Add an inline orphan-parent computation near the top of `hooks/stop-cleanup-orphans.sh` (cannot source the shell library); compute the set once per hook run
- [x] 3.2 Replace the PGID-cleanup PPID filter (`[ "$pid_ppid" != "1" ] && continue`) with an orphan-parent membership test
- [x] 3.3 Replace the pattern-based fallback `awk '$2 == 1'` with an orphan-parent membership test; never let a `systemd --user` manager PID match the kill patterns

## 4. Tests

- [x] 4.1 Update `tests/ppid-fallback.sh`: confirm the existing PID=1 fixture still resolves as an orphan and still gets reaped (no regression)
- [x] 4.2 [P] Create `tests/systemd-user-orphan.sh`: mock `ps` so a `systemd --user` PID exists and an MCP process is parented to it → detected as orphan; macOS-style fixture with no `systemd --user` → orphan-parent set is exactly `{1}` (no-op vs old behavior)
- [x] 4.3 [P] Add cases to `tests/systemd-user-orphan.sh`: a `systemd --user` owned by a different UID is NOT in the set; the `systemd --user` manager PID itself is never returned as a cleanup candidate

## 5. Docs

- [x] 5.1 Update `CLAUDE.md` Stop hook safety-layer section: PPID filter covers PID 1 **and** the Linux `systemd --user` reparent target
- [x] 5.2 Update `README.md` orphan-detection description to mention Linux `systemd --user` coverage

## 6. Validation

- [x] 6.1 `bash -n hooks/stop-cleanup-orphans.sh && bash -n shell/claude-cleanup.sh`
- [x] 6.2 `bash tests/ppid-fallback.sh` passes
- [x] 6.3 `bash tests/systemd-user-orphan.sh` passes
- [x] 6.4 `bash tests/stop-hook-env.sh` and `bash tests/agent-process-patterns.sh` still pass (no regression)
