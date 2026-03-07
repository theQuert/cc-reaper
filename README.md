# cc-reaper

Automated cleanup for orphan Claude Code processes (subagents, MCP servers, plugins) that leak memory after sessions end.

## The Problem

Claude Code spawns subagent processes and MCP servers for each session. When sessions end (especially abnormally), these processes become orphans (PPID=1) and keep consuming RAM — often 200-400 MB each. With multiple sessions over a day, this can accumulate to 7+ GB of wasted memory.

This is a [widely reported issue](https://github.com/anthropics/claude-code/issues/20369) affecting macOS and Linux users.

### What leaks

| Process Type | Pattern | Typical Size |
|---|---|---|
| Subagents | `claude --output-format stream-json` | 180-300 MB each |
| MCP servers | `npm exec @supabase/mcp-server-supabase`, `context7-mcp`, etc. | 40-110 MB each |
| claude-mem MCP | `node claude-mem/mcp-server.cjs` | 35-75 MB each |
| claude-mem worker | `worker-service.cjs --daemon` (bun) | 100 MB |
| chroma-mcp | `chroma-mcp --client-type persistent` (via uv/uvx) | 350-950 MB |

## Solution: Three-Layer Defense

```
Session ends normally
  └── Stop hook (stop-cleanup-orphans.sh) — immediate cleanup

Session crashes / terminal force-closed
  └── proc-janitor daemon — scans every 30s, kills orphans after 60s grace

Manual intervention needed
  └── claude-cleanup — on-demand cleanup
  └── claude-ram — check RAM usage breakdown
```

## Quick Start

```bash
git clone https://github.com/theQuert/cc-reaper.git
cd cc-reaper
chmod +x install.sh
./install.sh
```

## Manual Setup

### 1. Shell Functions

Add to `~/.zshrc` or `~/.bashrc`:

```bash
source /path/to/cc-reaper/shell/claude-cleanup.sh
```

Commands available after restart:

- `claude-ram` — show RAM usage breakdown with per-session details (read-only)
- `claude-sessions` — list all active sessions with idle detection and process tree RAM
- `claude-cleanup` — kill orphan processes immediately

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

### 3. proc-janitor Daemon

Install:

```bash
# macOS
brew install jhlee0409/tap/proc-janitor

# Or via Cargo
cargo install proc-janitor
```

Copy config:

```bash
mkdir -p ~/.config/proc-janitor
cp proc-janitor/config.toml ~/.config/proc-janitor/config.toml
chmod 600 ~/.config/proc-janitor/config.toml
```

Edit `~/.config/proc-janitor/config.toml` and replace `~` in the log path with your actual home directory.

Start daemon:

```bash
# macOS (auto-start on boot)
brew services start jhlee0409/tap/proc-janitor

# Manual
proc-janitor start
```

Useful commands:

```bash
proc-janitor scan     # dry run — show orphans without killing
proc-janitor clean    # kill detected orphans
proc-janitor status   # check daemon health
```

## Dependencies

| Tool | Required | Install |
|---|---|---|
| [proc-janitor](https://github.com/jhlee0409/proc-janitor) | Recommended | `brew install jhlee0409/tap/proc-janitor` |
| bash/zsh | Required | Pre-installed on macOS/Linux |
| Claude Code | — | The tool this project cleans up after |

## File Structure

```
cc-reaper/
├── install.sh                      # One-command installer
├── hooks/
│   └── stop-cleanup-orphans.sh     # Claude Code Stop hook
├── proc-janitor/
│   └── config.toml                 # Daemon config with Claude-specific patterns
├── shell/
│   └── claude-cleanup.sh           # Shell functions (claude-ram, claude-cleanup)
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
