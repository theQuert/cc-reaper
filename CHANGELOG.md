# Changelog

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
