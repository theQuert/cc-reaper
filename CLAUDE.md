# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cc-reaper is a shell-based utility that cleans up orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end. It uses a three-layer defense: Stop hook (immediate), proc-janitor daemon (continuous), and manual shell commands (on-demand).

## Repository Structure

- `install.sh` — Automated 4-stage installer (shell functions → stop hook → proc-janitor → daemon startup)
- `hooks/stop-cleanup-orphans.sh` — Claude Code Stop hook; kills orphans using TTY-based filtering (`$7 == "??"`)
- `shell/claude-cleanup.sh` — Shell functions: `claude-cleanup` (kill orphans), `claude-ram` (RAM report), `claude-fd` (FD usage report), `claude-sessions` (session list), `claude-guard` (auto-reaper with RSS/FD threshold + idle detection)
- `proc-janitor/config.toml` — Daemon config with target patterns, whitelist, and grace period settings

## Development Notes

**No build system, tests, or linters.** This is a pure shell script project. Changes are validated manually.

**Process detection patterns** use grep bracket expressions (e.g., `[c]laude` instead of `claude`) to prevent grep from matching its own process. The stop hook uses TTY filtering (`awk '$7 == "??"'`) to only kill processes without a controlling terminal (true orphans). The manual `claude-cleanup` function is intentionally more aggressive (no TTY filter).

**proc-janitor** is an external Rust daemon (installed via Homebrew or Cargo). The config.toml here only configures its behavior — the daemon code lives at github.com/jhlee0409/proc-janitor.

**Installer idempotency**: `install.sh` checks for existing installations before modifying shell configs, copying hooks, or installing dependencies. It uses `sed` to replace `~` with the actual home path in the proc-janitor config.

## Key Commands (post-install)

```bash
claude-ram              # Show RAM usage by process category
claude-fd               # Show file descriptor usage per session + VM processes
claude-sessions         # List active sessions with idle/bloated status
claude-cleanup          # Kill orphan processes immediately
claude-guard            # Auto-reaper: kills bloated (>CC_MAX_RSS_MB) and excess idle sessions
claude-guard --dry-run  # Preview what claude-guard would kill
proc-janitor scan       # Dry-run orphan detection
proc-janitor clean      # Kill detected orphans
proc-janitor status     # Check daemon health
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max allowed concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Tree RSS threshold (MB); sessions exceeding this are killed regardless of activity |
| `CC_MAX_FD` | 10000 | File descriptor threshold; sessions exceeding this are killed as FD-leak |
