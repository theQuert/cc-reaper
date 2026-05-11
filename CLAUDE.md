# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cc-reaper is a shell-based utility that cleans up orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end. It uses a three-layer defense: Stop hook (immediate), proc-janitor daemon (continuous), and manual shell commands (on-demand).

## Repository Structure

- `install.sh` — Automated 4-stage installer (shell functions → stop hook → proc-janitor → daemon startup)
- `hooks/stop-cleanup-orphans.sh` — Claude Code Stop hook; kills orphans using PPID=1 filtering (only truly orphaned processes reparented to init)
- `shell/claude-cleanup.sh` — Shell functions: `claude-cleanup` (kill orphans), `claude-ram` (RAM report), `claude-fd` (FD usage report), `claude-sessions` (session list), `claude-guard` (auto-reaper with RSS/FD threshold + idle detection)
- `shell/cc-monitor.sh` — Read-only heat attribution monitor (`cc-monitor`, `cc-monitor --apply`)
- `proc-janitor/config.toml` — Daemon config with target patterns, whitelist, and grace period settings
- `launchd/` — macOS LaunchAgent scripts for zero-dependency background monitoring
- `tests/` — Lightweight bash validation scripts (mocked ps/kill for isolated testing)

## Development Notes

**No build system or linter.** This is a pure shell script project. Changes are validated with shell syntax checks (`bash -n`) and lightweight validation scripts under `tests/`.

**Process detection patterns** use grep bracket expressions (e.g., `[c]laude` instead of `claude`) to prevent grep from matching its own process. The stop hook uses **PPID=1 filtering** (not TTY filtering) to identify true orphans — processes reparented to init after their parent exited. This works correctly across macOS, Linux, containers, and SSH sessions. The manual `claude-cleanup` function is intentionally more aggressive (three-phase: PGID-based group kill → pattern fallback for detached processes → PPID=1 orphan sweep).

**Safety layers in the Stop hook**:
1. **Ancestor protection**: Walks the process tree from `$$` upward and never kills any ancestor PID (prevents SIGTERM-ing the Claude CLI when an intermediate shell sits between hook and CLI).
2. **PPID=1 filter** (default): Only kills processes whose parent has already exited. Active processes with a living parent are skipped.
3. **MCP whitelist**: Shared long-running MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp, Cloudflare, sequential-thinking) are always excluded.
4. **`CC_STOP_HOOK_AGGRESSIVE=1`**: Skips the PPID=1 check but still preserves ancestors and the MCP whitelist.

**proc-janitor** is an external Rust daemon (installed via Homebrew or Cargo). The config.toml here only configures its behavior — the daemon code lives at github.com/jhlee0409/proc-janitor.

**Installer idempotency**: `install.sh` checks for existing installations before modifying shell configs, copying hooks, or installing dependencies. It uses `sed` to replace `~` with the actual home path in the proc-janitor config.

## Key Commands (post-install)

```bash
# Read-only diagnostics
cc-monitor               # Sample CPU for 60s, explain heat contributors by family
cc-monitor --once        # Immediate single snapshot
cc-monitor --json        # Machine-readable JSON output
cc-monitor --apply claude-cleanup   # Run cleanup module after report (no prompt)
claude-ram               # Show RAM usage by process category
claude-fd                # Show file descriptor usage per session + VM processes
claude-sessions          # List active sessions with idle/bloated status

# Cleanup (destructive)
claude-cleanup           # Kill orphan processes (PGID → pattern → PPID fallback)
claude-guard             # Auto-reaper: kills bloated (>CC_MAX_RSS_MB) and excess idle sessions
claude-guard --dry-run   # Preview what claude-guard would kill

# Daemon
proc-janitor scan        # Dry-run orphan detection
proc-janitor clean       # Kill detected orphans
proc-janitor status      # Check daemon health
```

## Testing

All tests are standalone bash scripts that can be run directly. Tests under `tests/` mock `ps`/`kill` where needed to avoid side effects.

```bash
bash tests/agent-process-patterns.sh   # Validate cleanup-candidate matchers (browser/Codex/MCP)
bash tests/ppid-fallback.sh            # Validate _cc_reaper_ppid_fallback (PPID=1 + whitelist)
bash tests/cc-monitor-optimize.sh      # Validate cc-monitor optimization menu logic
bash tests/cc-monitor-runaway.sh       # Validate runaway protected process detection
bash -n shell/claude-cleanup.sh        # Syntax check
bash -n shell/cc-monitor.sh            # Syntax check
bash -n hooks/stop-cleanup-orphans.sh  # Syntax check
```

## Environment Variables

### claude-guard / claude-cleanup

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max allowed concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Tree RSS threshold (MB); sessions exceeding this are killed regardless of activity |
| `CC_MAX_FD` | 10000 | File descriptor threshold; sessions exceeding this are killed as FD-leak |
| `CC_AGENT_STALE_MINUTES` | 360 | Age threshold (minutes) for stale agent-browser, Puppeteer Chrome, and detached Codex/MCP cleanup |
| `CC_RUNAWAY_CPU` | 80 | CPU% above which a protected process is treated as stuck/runaway |
| `CC_RUNAWAY_MIN` | 60 | Minutes of elapsed time required before a hot protected process is runaway |
| `CC_RUNAWAY_GRACE_SEC` | 5 | Seconds claude-guard waits before SIGTERM-ing runaway protected processes |
| `CC_RUNAWAY_DISABLE` | 0 | Set to `1` to skip claude-guard's runaway phase |

### Stop hook

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_STOP_HOOK_DISABLE` | 0 | Set to `1` to skip all cleanup (hook becomes no-op) |
| `CC_STOP_HOOK_AGGRESSIVE` | 0 | Set to `1` to skip PPID=1 filtering. Still skips ancestors and MCP whitelist. |
