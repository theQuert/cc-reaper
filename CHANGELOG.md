# Changelog

## [0.4.1] - 2026-03-10

### Fixed
- **MCP server false-positive kills** — Long-running MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp) were being killed by pattern-based fallback and proc-janitor, causing repeated disconnections across sessions
- **Overly broad patterns removed** — `node.*claude` and `node.*mcp` matched nearly any node-based MCP process; replaced with specific patterns that only target known short-lived orphans

### Changed
- Long-running MCP servers are now **whitelisted** in proc-janitor and excluded from pattern-based kill in stop hook and `claude-cleanup`
- PGID-based cleanup (primary) still handles session-scoped cleanup correctly — MCP servers are killed when their owning session ends, but not across sessions
- Updated README with explicit proc-janitor config update instructions

## [0.4.0] - 2026-03-10

### Added
- **PGID-based process group cleanup** — Primary detection method across all three layers
  - Stop hook uses session's PGID to kill all child processes (MCP servers, subagents) in one shot, catching unknown third-party servers without pattern maintenance
  - `claude-cleanup` finds orphaned process groups (PGID leader has PPID=1) and kills entire groups via `kill -- -$PGID`
  - LaunchAgent monitor uses PGID-first scanning with pattern-based fallback, avoids duplicate kills
- **Installer update mode** — Re-running `install.sh` detects existing installation and shows "Update" messaging; always overwrites hook/monitor scripts to latest version; shows config diff hint for proc-janitor

### Fixed
- **PGID group kill safety** — Previously matched groups by membership (any process containing "claude"), which killed Chrome and Cursor whose process groups contain `claude --chrome-native-host`. Now only kills groups whose **leader** matches `claude.*stream-json` (orphaned subagent) or `claude.*--session-id` (orphaned session)
- **`claude-cleanup` stream-json missing TTY filter** — Pattern-based fallback killed active sessions' subagents. Added `$7 == "??"` filter to only target detached processes
- **`node.*sequential` too broad** — Narrowed to `node.*sequential-thinking` across all layers to prevent matching unrelated node processes

### Changed
- All three cleanup layers now use a two-pass strategy: PGID-based (primary) → pattern-based (fallback for processes that escaped their group via `setsid()`)
- Stop hook excludes own PID and parent PID from group kill to ensure clean shutdown
- `claude-cleanup` output now shows separate counts for PGID-based and pattern-based kills

## [0.3.0] - 2026-03-09

### Added
- **LaunchAgent daemon** — Zero-dependency macOS native alternative to proc-janitor
  - `launchd/cc-reaper-monitor.sh` — Lightweight orphan monitor (PPID=1 detection)
  - `launchd/com.cc-reaper.orphan-monitor.plist` — LaunchAgent config (runs every 10 minutes)
  - Includes SIGKILL fallback for unresponsive processes and log rotation
- **PPID=1 orphan detection** in `claude-cleanup` — Catches orphans reparented to launchd after crashes, complementing existing TTY-based filtering
- **CPU metrics** in `claude-ram` — All sections now show CPU% alongside RAM
- **Orphans section** in `claude-ram` — New `--- Orphans (PPID=1) ---` section for quick visibility
- **Interactive daemon choice** in installer — Users choose between proc-janitor (feature-rich) and LaunchAgent (zero-dependency)

### Fixed
- **proc-janitor whitelist too broad** — `"node.*server"` was matching `node.*mcp-server`, preventing daemon from cleaning MCP server orphans. Narrowed to `"node.*(dev-server|http-server|next.*server)"` to only protect actual web dev servers

### Updated
- **Broader MCP pattern coverage** across all layers (shell, stop hook, proc-janitor):
  - `npx.*mcp-server` — Catches third-party MCP servers installed via npx (Cloudflare, GitHub, etc.)
- **Installer** now 5-step flow with input validation and context-aware help output

## [0.2.0] - 2026-03-08

### Added
- **`claude-sessions` command** — Lists all active Claude Code CLI sessions with per-session details:
  - PID, RSS, CPU%, elapsed time
  - Idle detection (CPU < 1% = `[IDLE]`)
  - Child process count and full process tree RAM
  - Warnings when ≥4 sessions are open
  - Tips to close idle sessions
- **Per-session breakdown in `claude-ram`** — Now shows individual session PID, RSS, CPU%, and elapsed time instead of just totals
- **Session count warning** — `claude-ram` warns when ≥3 sessions are open and suggests running `claude-sessions`

### Updated
- **New process patterns** across all three layers (shell, stop hook, proc-janitor):
  - `node.*claude-mem.*mcp-server` — claude-mem plugin MCP servers
  - `uv.*chroma-mcp` / `uvx.*chroma-mcp` / `python.*chroma-mcp` — uv/uvx-spawned chroma vector DB
  - `bun.*worker-service` — bun-based worker-service daemons
- **Stop hook** (`stop-cleanup-orphans.sh`) — Added cleanup rules for claude-mem MCP servers, uv/uvx chroma-mcp, and bun worker-service
- **proc-janitor config** (`config.toml`) — Added 5 new target patterns

## [0.1.0] - 2026-03-01

### Added
- Initial release: three-layer orphan process cleanup
- `claude-cleanup` — Kill orphan processes immediately
- `claude-ram` — Show RAM usage breakdown
- Stop hook for automatic cleanup on session end
- proc-janitor daemon config for continuous monitoring
- One-command installer (`install.sh`)
