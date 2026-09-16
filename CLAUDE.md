# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

cc-reaper is a shell-based utility that cleans up orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end. It uses a three-layer defense: Stop hook (immediate), proc-janitor daemon (continuous), and manual shell commands (on-demand).

## Repository Structure

- `install.sh` — Automated 4-stage installer (shell functions → stop hook → proc-janitor → daemon startup)
- `hooks/stop-cleanup-orphans.sh` — Claude Code Stop hook; kills orphans using orphan-parent filtering (only truly orphaned processes — reparented to PID 1, or on Linux to the user's `systemd --user` manager)
- `shell/claude-cleanup.sh` — Shell functions: `claude-cleanup` (kill orphans), `claude-ram` (RAM report), `claude-fd` (FD usage report), `claude-sessions` (session list), `claude-guard` (auto-reaper with RSS/FD threshold + idle detection)
- `shell/cc-monitor.sh` — Read-only heat attribution monitor (`cc-monitor`, `cc-monitor --apply`)
- `shell/worktree-janitor.sh` — Worktree inventory and gated removal (clean, unheld, landed, idle); `--session` for a SessionEnd hook. The method is in `docs/worktree-reclamation.md`
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
- `_cc_reaper_is_session_cmd` judges one command line, fetched per PID. `_cc_reaper_strip_brace_args` first cuts out every balanced `{…}` region — the `--settings` payload — because a hook command in there may legitimately mention `--output-format` or `mcp-server`, and matching the whole line would hide the very session that owns it. The payload equally cannot *qualify* a session. It is cut **out**, not truncated **at**: top-level flags written after `--settings` still count, in either direction (`--settings={} --output-format json` is still headless; `--settings={} --session-id x` is still a session). Braces inside JSON strings don't affect the pairing, and an unbalanced line is rejected outright — a missed session is inert, a false one hands `claude-guard` the wrong process group.

Tests drive the two seams separately via `CC_REAPER_PS_SNAPSHOT_FILE` (`pid tty comm`) and `CC_REAPER_PS_CMD_SNAPSHOT_DIR` (one file per PID, so fixtures can hold the embedded newlines a real `--settings` argument produces).

**zsh portability**: this project is installed into zsh, so `claude-guard`'s reaping paths must avoid two zsh traps that bash hides — `status` is a read-only variable (use `proc_status`), and arrays cannot be walked by numeric index (`${!arr[@]}` is `bad substitution`, `${arr[0]}` is empty). Kill candidates are carried as `pid<TAB>detail` records iterated by value. `zsh -n` belongs in the syntax check alongside `bash -n`, and `tests/guard-session-detect.sh` and `tests/guard-runaway.sh` each run their phases under both shells — a syntax check passes a `status` local, so only a run of the kill branch under zsh catches one.

**Protection classes**: `_cc_reaper_protection_class` is the single owner of how protected a process is, returning `immutable`, `shared`, or `none` for a command line. All three cleanup paths consult it, which is what keeps them from disagreeing:

| Path | `immutable` | `shared` | `none` |
|------|-------------|----------|--------|
| Pattern-based cleanup | never | exempt, unless a user `cleanup` rule covers it | family predicates decide |
| Process-group cleanup | never | skipped | signalled on membership |
| Runaway phase | never selected | selected only if the process is itself a known shared MCP server that has used at least `CC_RUNAWAY_CPU` percent of every interval between guard runs for `CC_RUNAWAY_MIN` minutes; that PID alone is signalled, after a re-check | not selected |

They previously carried three separate lists (`_cc_reaper_protected_pattern`, `_cc_reaper_is_direct_cleanup_protected`, and an `MCP_WHITELIST` local to `_claude_pgid_kill`) that had drifted apart: a runaway shared MCP was selected by one and skipped by another, `mcp-server-stripe` was protected where `@stripe/mcp` was not, and a stuck system scanner was reachable by the runaway phase.

**Runaway phase specifics**: it never selects `immutable`, so cc-reaper does not SIGTERM security software or a Spotlight reindex however hot they get. It *does* signal the `shared` MCP server it selected — that is the point of the phase — and only that PID, through `_cc_reaper_kill_pid`, never its process group: a shared MCP server started by a Claude CLI is in that CLI's group, and group signalling ended the session. Three rules keep selection to what the phase is for:

- **Identity, not a substring.** The protection class is a substring test over the whole command line — right for protection, wrong for a kill path: a session whose `--settings` named `claude-mem` classified `shared`. `_cc_reaper_mcp_server_program` asks whether the process itself is a known shared MCP server: its executable, or the first word a package runner or interpreter (`npx`, `npm exec`, `uvx`, `node`, `python`) runs, compared whole as a package with any version dropped, a program in a `bin` directory, or a package directory under `node_modules`. No other argument counts. Claude and Codex CLIs never qualify (except `codex mcp-server`), nor does anything run from inside an `.app` bundle (an `.app` in a URL does not count). `cc-monitor.sh` carries a byte-identical copy, compared by `tests/cc-monitor-runaway.sh`, so the monitor names `claude-guard` only for a known shared MCP server.
- **Heat across runs.** Each guard run records the CPU time of every process at or above `CC_RUNAWAY_CPU` in `~/.cc-reaper/state/runaway-samples.tsv` (`CC_RUNAWAY_SAMPLES_FILE`), keyed by PID and start time read under `LC_ALL=C TZ=UTC`. An interval of at least a minute extends a process's hot streak only if it used at least `CC_RUNAWAY_CPU` percent of it, and the process is selected once the streak reaches `CC_RUNAWAY_MIN`; an interval over 20 minutes starts the streak over, since a multi-threaded server could idle through much of it and still average hot. `ps %cpu` decays over about a minute, and a lifetime average of CPU time sums threads, so neither stands in for the streak; `ps %cpu` only confirms a candidate is still hot — at selection, and on a re-check after at least three seconds that also requires the command to be unchanged. A dry run records nothing, and zero thresholds fall back to the defaults. The known ceiling: a stall is signalled 60 to 70 minutes after a run first sees it; `cc-monitor` reports it sooner.
- **Candidates from a listing without argument text.** PIDs come from `ps -axo pid=,lstart=,etime=,time=,%cpu=`, and each command is read per PID and flattened to one line — the seam session detection uses — so a payload line shaped like a row cannot add a PID.

Reported counts are deliveries, not intentions: a candidate spared at the signal stage is not counted, adds nothing to the freed total, and raises no notification.

**Tree RSS** (`_claude_tree_rss`) sums the whole descendant tree in kilobytes and converts once, from a single `ps` walked in awk. Truncating each member first cost ~0.5 MB per process, and stopping at grandchildren missed anything behind a wrapper chain; the single-pass form is also ~5x faster than the two-level version it replaced.

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
bash tests/protection-classes.sh       # Validate protection classes, runaway selection/signalling, tree RSS
bash tests/monitor-selection.sh        # LaunchAgent monitor body: what it signals (no CPU-based selection)
bash tests/guard-runaway.sh            # claude-guard runaway phase run whole under bash and zsh: known MCP servers, CPU sampled across runs, each re-checked PID alone
bash tests/install-rc-source.sh        # install.sh rc lines source the deployed copies; a stale one is repaired only when nothing else names the script
bash tests/worktree-janitor.sh         # Validate worktree gates, landing proofs, declarations, session mode, lock
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
| `CC_RUNAWAY_CPU` | 80 | CPU, as a percent of each interval between claude-guard runs, at or above which a known shared MCP server stays hot; it must also read at least this hot now |
| `CC_RUNAWAY_MIN` | 60 | Minutes a process must stay hot across claude-guard runs before it is runaway |
| `CC_RUNAWAY_GRACE_SEC` | 5 | Seconds claude-guard waits before SIGTERM-ing runaway protected processes |
| `CC_RUNAWAY_DISABLE` | 0 | Set to `1` to skip claude-guard's runaway phase |
| `CC_RUNAWAY_SAMPLES_FILE` | `~/.cc-reaper/state/runaway-samples.tsv` | CPU-time samples `claude-guard`'s runaway phase measures streaks from; losing the file only restarts streaks, and a path with no directory part is a file in the directory the guard runs from |

### Stop hook

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_STOP_HOOK_DISABLE` | 0 | Set to `1` to skip all cleanup (hook becomes no-op) |
| `CC_STOP_HOOK_AGGRESSIVE` | 0 | Set to `1` to skip orphan-parent filtering. Still skips ancestors and MCP whitelist. |
