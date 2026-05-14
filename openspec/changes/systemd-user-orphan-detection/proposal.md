# Change: systemd-user-orphan-detection

## Why

cc-reaper identifies a "true orphan" as a process whose parent is PID 1 — its
session exited and the kernel reparented it to init. This is correct on macOS,
where orphans land on `launchd` (PID 1).

On Linux it is wrong. When a Claude Code session exits, its leaked MCP servers
and subagents are reparented to the invoking user's `systemd --user` manager
(the per-user service manager), **not** PID 1. Their `PPID` is the
`systemd --user` PID, so every PID=1-only check in cc-reaper silently skips
them — Layer 1 cleanup (the Stop hook) and `claude-cleanup`'s orphan paths
both miss the entire class of leak on Linux.

This was reported with hard data in anthropics/claude-code#1935: 80 orphaned
`lark-mcp` node processes (~1 GB RSS each) accumulated on Ubuntu 24.04, all
reparented to `systemd --user`, none of which cc-reaper's PPID=1 logic would
catch.

## What Changes

- Add a shared **orphan-parent set** concept: the set of PPIDs that mark a
  process as orphaned. On macOS / hosts with no `systemd --user` manager the
  set is exactly `{1}` (behavior identical to today). On Linux it is
  `{1, <current user's systemd --user PID(s)>}`.
- Add `_cc_reaper_orphan_ppids` + `_cc_reaper_is_orphan_ppid` helpers to
  `shell/claude-cleanup.sh`; route all six PID=1 checks (`_cc_reaper_is_detached_or_orphan`,
  the agent-candidate checks, `_cc_reaper_ppid_fallback`, `orphan_pgids`, the
  orphan report) through them.
- Inline the equivalent detection in `hooks/stop-cleanup-orphans.sh` (the hook
  cannot source the shell library): compute the orphan-parent set once, use it
  in the PGID-cleanup PPID filter and the pattern-based fallback.
- The `systemd --user` manager PID is a reparent **target**, never a cleanup
  candidate — it is filtered out so cleanup never signals it.
- Only the invoking user's `systemd --user` manager(s) count; another user's
  manager is never treated as an orphan parent.

## Impact

- **Affected specs**: `agent-process-reapers` — one ADDED requirement
  (cross-platform orphan parent detection); two MODIFIED requirements
  (agent-browser + Codex scenarios that currently say "reparented to PID 1").
- **Affected code**: `hooks/stop-cleanup-orphans.sh` (inline detection + 2 call
  sites); `shell/claude-cleanup.sh` (2 new helpers + 6 call sites).
- **Tests**: update `tests/ppid-fallback.sh` (existing PID=1 fixture still
  passes); add `tests/systemd-user-orphan.sh` (Linux `systemd --user` fixture
  detected; macOS-style no-systemd fixture is a no-op; foreign-user manager not
  matched; manager PID itself never killed).
- **Docs**: `README.md` and `CLAUDE.md` — note Linux `systemd --user` orphan
  coverage in the Stop hook safety-layer description.
- **Out of scope**:
  - `proc-janitor` — external Rust daemon; it does its own reparent detection
    and is only configured here, not coded here.
  - `launchd/cc-reaper-monitor.sh` — macOS-only LaunchAgent infrastructure;
    `systemd --user` never exists on the only platform it runs on, so adding
    the detection there would be dead code.
  - Non-systemd Linux init systems (OpenRC, runit, s6) — they do not reparent
    to a per-user manager, so PID 1 detection already covers them.
  - No new environment variables.
