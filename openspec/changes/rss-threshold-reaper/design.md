## Context

`claude-guard` in `shell/claude-cleanup.sh` currently monitors session count and idle status. It kills idle sessions when the total count exceeds `CC_MAX_SESSIONS`. The existing `claude-sessions` function already calculates per-session tree RSS (session + children + grandchildren). The RSS threshold feature reuses this calculation pattern.

## Goals / Non-Goals

**Goals:**
- Add RSS-based kill trigger to `claude-guard` alongside existing idle detection
- Reuse existing PGID kill and tree RSS calculation patterns from `claude-cleanup` and `claude-sessions`
- Keep configuration simple (one env var)

**Non-Goals:**
- RSS growth rate detection (future work)
- Session max age / TTL enforcement (future work)
- Modifying proc-janitor daemon config (separate concern)
- Auto-setting `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (quality tradeoff unclear)

## Decisions

**1. Kill order: bloated first, then idle**
Bloated sessions are an immediate threat (42 GB/hr growth). Kill them before applying idle session eviction. Rationale: a 6 GB active session is more urgent to kill than a 200 MB idle session.

**2. Tree RSS, not process RSS**
Use sum of session + all descendants, matching `claude-sessions` logic. A session spawning heavy MCP servers should count their memory too. Alternative: per-process RSS only — rejected because child processes (MCP servers, subagents) are the session's responsibility.

**3. Single env var configuration**
`CC_MAX_RSS_MB` with default 4096. No config file needed — this project uses env vars for all user-facing config (`CC_MAX_SESSIONS`, `CC_IDLE_THRESHOLD`). Alternative: add to proc-janitor config.toml — rejected because this is shell function logic, not daemon logic.

**4. Always kill bloated, ignore session count**
A bloated session is killed even if total count is under `CC_MAX_SESSIONS`. The session count limit and RSS limit are independent safety nets.

## Risks / Trade-offs

- [Risk] Killing an active session mid-work → Mitigation: 4 GB default is generous; user can raise via env var. Desktop notification ensures visibility.
- [Risk] Tree RSS calculation adds overhead to guard scan → Mitigation: Already done in `claude-sessions`; adds ~50ms per session for `ps` + `pgrep` calls.
- [Trade-off] No grace period for RSS spikes → Acceptable: if a session hits 4 GB, it's already problematic. The leak rate (42 GB/hr) means waiting is costly.
