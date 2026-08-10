# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cc-reaper is a shell-based utility that cleans up orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end. It uses a three-layer defense: Stop hook (immediate), proc-janitor daemon (continuous), and manual shell commands (on-demand).

## Repository Structure

- `install.sh` — Automated 4-stage installer (shell functions → stop hook → proc-janitor → daemon startup)
- `hooks/stop-cleanup-orphans.sh` — Claude Code Stop hook; kills orphans using orphan-parent filtering (only truly orphaned processes — reparented to PID 1, or on Linux to the user's `systemd --user` manager)
- `shell/claude-cleanup.sh` — Shell functions: `claude-cleanup` (kill orphans), `claude-ram` (RAM report), `claude-fd` (FD usage report), `claude-sessions` (session list), `claude-guard` (auto-reaper with RSS/FD threshold + idle detection)
- `shell/cc-monitor.sh` — Read-only heat attribution monitor (`cc-monitor`, `cc-monitor --apply`)
- `proc-janitor/config.toml` — Daemon config with target patterns, whitelist, and grace period settings
- `launchd/` — macOS LaunchAgent scripts for zero-dependency background monitoring
- `tests/` — Lightweight bash validation scripts (mocked ps/kill for isolated testing)

## Development Notes

**No build system or linter.** This is a pure shell script project. Changes are validated with shell syntax checks (`bash -n`) and lightweight validation scripts under `tests/`.

**Process detection patterns** use grep bracket expressions (e.g., `[c]laude` instead of `claude`) to prevent grep from matching its own process. The stop hook uses **orphan-parent filtering** (not TTY filtering) to identify true orphans — processes whose session exited and were reparented. The orphan-parent set is PID 1 on macOS (launchd) and, on Linux, PID 1 **plus the invoking user's `systemd --user` manager** (the per-user reparent target — Linux orphans land there, not on PID 1). Only the current user's manager counts, matched by UID. This works correctly across macOS, Linux, containers, and SSH sessions. The manual `claude-cleanup` function is intentionally more aggressive (three-phase: PGID-based group kill → pattern fallback for detached processes → orphan-parent sweep).

**Safety layers in the Stop hook**:
1. **Ancestor protection**: Walks the process tree from `$$` upward and never kills any ancestor PID (prevents SIGTERM-ing the Claude CLI when an intermediate shell sits between hook and CLI).
2. **Orphan-parent filter** (default): Only kills processes whose parent has already exited — those reparented to PID 1, or (on Linux) to the invoking user's `systemd --user` manager. Active processes with a living parent are skipped. The `systemd --user` manager PID is itself a reparent target, never a kill candidate.
3. **MCP whitelist**: Shared long-running MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp, sequential-thinking) are always excluded. **Cloudflare's MCP server (`@cloudflare/mcp-server-cloudflare`) is deliberately NOT whitelisted** — it is prone to orphaning and pinning ~100% CPU for hours, so it is treated as a normal reap target.
4. **`CC_STOP_HOOK_AGGRESSIVE=1`**: Skips the orphan-parent check but still preserves ancestors and the MCP whitelist.

**What counts as a session**: `claude-guard`, `claude-sessions`, and `claude-fd` all resolve sessions through `_cc_reaper_session_pids`, which reports only **top-level `claude` CLI processes attached to a real terminal**. Three families are deliberately excluded, because `claude-guard` reaps whole process groups:

- **Desktop-hosted claude-code and `stream-json` subagents** — both run the same binary with the same `--output-format stream-json --input-format stream-json` flags, and only the parent chain separates them. Neither holds a terminal, so requiring one drops both. `cc-monitor` still reports them.
- **Headless `-p` / `--output-format` runs** — a batch job below the idle CPU threshold is indistinguishable from an abandoned session, and killing one destroys work with no visible tab.
- **Helper modes** such as `claude mcp-server`.

The matcher keys on the `claude` executable plus any known session flag (`--session-id` or the legacy `--dangerously…`) rather than a single flag, which is how the previous matcher went silently blind when Claude Code stopped putting `--dangerously…` on the command line.

Detection is split across two seams so that **no argument value can influence which PIDs exist**:

- `_cc_reaper_ps_pid_tty_comm` lists PID, TTY, and `comm` — the executable name, never the arguments. Candidate PIDs come only from here, so a `--settings` payload containing a line like `12345 ttys999 /path/claude --session-id injected` cannot forge a record. Parsing PIDs out of a `ps …,command=` table is unsafe for exactly this reason: `claude-guard` reaps whole process groups, so a forged PID that happens to be live and over a threshold would take its group with it.
- `_cc_reaper_is_session_cmd` judges one command line, fetched per PID. It first drops everything from the first `{` — the `--settings` payload — because a hook command in there may legitimately mention `--output-format` or `mcp-server`, and matching the whole line would hide the very session that owns it. The payload equally cannot *qualify* a session.

Tests drive the two seams separately via `CC_REAPER_PS_SNAPSHOT_FILE` (`pid tty comm`) and `CC_REAPER_PS_CMD_SNAPSHOT_FILE` (`pid<TAB>command`).

**zsh portability**: this project is installed into zsh, so `claude-guard`'s reaping paths must avoid two zsh traps that bash hides — `status` is a read-only variable (use `proc_status`), and arrays cannot be walked by numeric index (`${!arr[@]}` is `bad substitution`, `${arr[0]}` is empty). Kill candidates are carried as `pid<TAB>detail` records iterated by value. `zsh -n` belongs in the syntax check alongside `bash -n`.

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
bash tests/stop-hook-env.sh            # Validate CC_STOP_HOOK_DISABLE / CC_STOP_HOOK_AGGRESSIVE
bash tests/cc-monitor-optimize.sh      # Validate cc-monitor optimization menu logic
bash tests/cc-monitor-runaway.sh       # Validate runaway protected process detection
bash tests/guard-session-detect.sh     # Validate session detection + guard phases under bash and zsh
bash -n shell/claude-cleanup.sh        # Syntax check
bash -n shell/cc-monitor.sh            # Syntax check
bash -n hooks/stop-cleanup-orphans.sh  # Syntax check
zsh -n shell/claude-cleanup.sh         # zsh reaches code paths bash-only checks miss
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
| `CC_STOP_HOOK_AGGRESSIVE` | 0 | Set to `1` to skip orphan-parent filtering. Still skips ancestors and MCP whitelist. |
