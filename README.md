# cc-reaper

Automated cleanup for orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end.

## The Problem

Claude Code spawns subagent processes and MCP servers for each session. When sessions end (especially abnormally), these processes become orphans (PPID=1) and keep consuming RAM and CPU — often 200-400 MB each, with some (like Cloudflare's MCP server) hitting 550%+ CPU. With multiple sessions over a day, this can accumulate to 7+ GB of wasted memory.

This is a [widely reported issue](https://github.com/anthropics/claude-code/issues/20369) affecting macOS and Linux users.

### What leaks

| Process Type | Pattern | Typical Size |
|---|---|---|
| Subagents | `claude --output-format stream-json` | 180-300 MB each |
| MCP servers (short-lived) | `npx mcp-server-cloudflare`, `npm exec mcp-*`, etc. | 40-110 MB each |
| claude-mem worker | `worker-service.cjs --daemon` (bun) | 100 MB |

> **Not killed**: Long-running MCP servers shared across sessions (Supabase, Stripe, context7, claude-mem, chroma-mcp) are whitelisted across all cleanup layers — including PGID group kills. When a session ends, its stop hook and `claude-guard` skip whitelisted MCP servers so other sessions can continue using them.

## Solution: Three-Layer Defense

All layers use **PGID-based process group cleanup** as the primary method — killing entire process groups spawned by a Claude session with a single `kill -- -$PGID`. Pattern-based detection is kept as a fallback for edge cases.

```
Session ends normally
  └── Stop hook — kills session's process group via PGID (catches all children)

Session crashes / terminal force-closed
  └── proc-janitor daemon — scans every 30s, kills orphans after 60s grace
  └── OR: LaunchAgent — zero-dependency macOS native, PGID group kill + PPID=1 fallback

Manual intervention needed
  └── claude-cleanup — finds orphaned PGIDs (leader has PPID=1), kills entire groups
  └── claude-ram — check RAM/CPU usage breakdown with orphan visibility
```

### Why PGID?

Claude Code sessions are process group leaders (PGID = session PID). All spawned MCP servers, subagents, and their children inherit this PGID. This means one `kill -- -$PGID` reliably cleans up everything — including third-party MCP servers that pattern matching might miss.

**Safety**: PGID cleanup only targets groups whose **leader** is a Claude CLI session (`claude.*stream-json`). It never matches by group membership — other apps like Chrome and Cursor have `claude` subprocesses in their process groups, so matching by membership would kill them.

## Quick Start

```bash
git clone https://github.com/theQuert/cc-reaper.git
cd cc-reaper
chmod +x install.sh
./install.sh
```

**Updating:**

```bash
git pull
./install.sh
```

The installer auto-updates hook and shell functions. For proc-janitor users, manually sync the config:

```bash
cp proc-janitor/config.toml ~/.config/proc-janitor/config.toml
# Edit the log path: replace ~ with your actual home directory
```

## Manual Setup

### 1. Shell Functions

Add to `~/.zshrc` or `~/.bashrc`:

```bash
source /path/to/cc-reaper/shell/claude-cleanup.sh
```

Commands available after restart:

- `claude-ram` — show RAM/CPU usage breakdown with per-session details and orphan visibility (read-only)
- `claude-sessions` — list all active sessions with idle detection and process tree RAM
- `claude-cleanup` — kill orphan processes immediately (PGID group kill + pattern fallback)
- `claude-guard` — automatic session reaper: kills bloated sessions (RSS > threshold) and excess idle sessions
- `claude-guard --dry-run` — preview what claude-guard would kill without actually killing

### 2. Claude Code Stop Hook

Copy the hook script:

```bash
mkdir -p ~/.claude/hooks
cp hooks/stop-cleanup-orphans.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/stop-cleanup-orphans.sh
```

Add to `~/.claude/settings.json` in the `"Stop"` hooks array:

```json
{
  "type": "command",
  "command": "\"$HOME\"/.claude/hooks/stop-cleanup-orphans.sh",
  "timeout": 15
}
```

<details>
<summary>Full settings.json example</summary>

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME\"/.claude/hooks/stop-cleanup-orphans.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

</details>

### 3. Background Daemon (choose one)

#### Option A: LaunchAgent (zero-dependency, macOS only)

Native macOS approach — no Homebrew or Rust required. Runs every 10 minutes, detects orphans by PPID=1.

```bash
mkdir -p ~/.cc-reaper/logs
cp launchd/cc-reaper-monitor.sh ~/.cc-reaper/
chmod +x ~/.cc-reaper/cc-reaper-monitor.sh

# Install and replace __HOME__ with actual path
sed "s|__HOME__|$HOME|g" launchd/com.cc-reaper.orphan-monitor.plist \
  > ~/Library/LaunchAgents/com.cc-reaper.orphan-monitor.plist
launchctl load ~/Library/LaunchAgents/com.cc-reaper.orphan-monitor.plist
```

Useful commands:

```bash
launchctl list | grep cc-reaper           # check if running
cat ~/.cc-reaper/logs/monitor.log         # view cleanup log
launchctl unload ~/Library/LaunchAgents/com.cc-reaper.orphan-monitor.plist  # stop
```

#### Option B: proc-janitor (feature-rich)

Rust-based daemon with grace period, whitelist, and detailed logging. Requires Homebrew or Cargo.

```bash
# Install
brew install jhlee0409/tap/proc-janitor   # or: cargo install proc-janitor

# Copy config
mkdir -p ~/.config/proc-janitor
cp proc-janitor/config.toml ~/.config/proc-janitor/config.toml
chmod 600 ~/.config/proc-janitor/config.toml
```

Edit `~/.config/proc-janitor/config.toml` and replace `~` in the log path with your actual home directory.

Start daemon:

```bash
brew services start jhlee0409/tap/proc-janitor   # auto-start on boot
proc-janitor start                                # or manual
```

Useful commands:

```bash
proc-janitor scan     # dry run — show orphans without killing
proc-janitor clean    # kill detected orphans
proc-janitor status   # check daemon health
```

## Automatic Session Guard

`claude-guard` is an automatic session reaper that prevents runaway memory consumption. It operates in two phases:

1. **Bloated session kill** — Sessions whose tree RSS (process + all children) exceeds `CC_MAX_RSS_MB` are killed immediately via PGID, regardless of whether they're idle or active. This addresses the [~42 GB/hr memory leak](https://github.com/anthropics/claude-code/issues/4953#issuecomment-4043206738) caused by unreleased streaming ArrayBuffers.
2. **Idle session eviction** — If session count still exceeds `CC_MAX_SESSIONS`, the oldest idle sessions are killed.

```bash
claude-guard            # run the guard (kills bloated + excess idle)
claude-guard --dry-run  # preview without killing
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max allowed concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Tree RSS threshold (MB); sessions exceeding this are killed regardless of activity |

Example: lower the threshold to 2 GB for memory-constrained machines:

```bash
export CC_MAX_RSS_MB=2048
claude-guard
```

## Dependencies

| Tool | Required | Install |
|---|---|---|
| bash/zsh | Required | Pre-installed on macOS/Linux |
| macOS LaunchAgent | Option A (recommended) | Built-in, zero dependencies |
| [proc-janitor](https://github.com/jhlee0409/proc-janitor) | Option B | `brew install jhlee0409/tap/proc-janitor` |
| Claude Code | — | The tool this project cleans up after |

## File Structure

```
cc-reaper/
├── install.sh                      # One-command installer/updater (interactive daemon choice)
├── hooks/
│   └── stop-cleanup-orphans.sh     # Claude Code Stop hook (PGID + pattern fallback)
├── launchd/
│   ├── cc-reaper-monitor.sh        # LaunchAgent monitor script (PGID + PPID=1 fallback)
│   └── com.cc-reaper.orphan-monitor.plist  # LaunchAgent config (10-min interval)
├── proc-janitor/
│   └── config.toml                 # proc-janitor daemon config (alternative to LaunchAgent)
├── shell/
│   └── claude-cleanup.sh           # Shell functions (claude-ram, claude-cleanup, claude-sessions, claude-guard)
└── README.md
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Related Issues

- [anthropics/claude-code#20369](https://github.com/anthropics/claude-code/issues/20369) — Orphaned subagent process leaks memory
- [anthropics/claude-code#22554](https://github.com/anthropics/claude-code/issues/22554) — Subagent processes not terminating on macOS
- [anthropics/claude-code#25545](https://github.com/anthropics/claude-code/issues/25545) — Excessive RAM when idle
- [thedotmack/claude-mem#650](https://github.com/thedotmack/claude-mem/issues/650) — worker-service spawns subagents that don't exit

## License

Apache 2.0
