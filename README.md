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
| Agent browser sessions | `agent-browser-darwin-arm64`, Chrome-for-Testing with `agent-browser-chrome-*` profiles | 100-600 MB each |
| Puppeteer headless Chrome | Chrome/Chrome Helper with `puppeteer_dev_chrome_profile-*` profiles | Can pin CPU/GPU |
| Codex background sessions | `node /usr/local/bin/codex`, `@openai/codex/.../codex --yolo` | Session + MCP tree |

| File descriptors | VM processes, settings.json, MCP stdio pipes | ~6,200 FDs/hr leak rate |

> **Not killed**: User apps and system services such as ChatGPT.app, cmux.app, Bitdefender, Spotlight (`mdworker`/`mds_stores`), normal Chrome browsing, and web dev servers are protected. Long-running MCP servers shared across sessions (Supabase, Stripe, claude-mem, chroma-mcp, sequential-thinking variants) are also protected. (Cloudflare's MCP server is **not** protected — it tends to orphan and pin ~100% CPU, so it is reaped like any other orphan.) Stale browser/Codex cleanup only targets orphaned or old automation processes.

## Solution: Three-Layer Defense

PGID-based process group cleanup is used by proc-janitor and manual tools. The Stop hook defaults to **PPID=1 orphan-only cleanup** for safety; `CC_STOP_HOOK_AGGRESSIVE=1` restores broad PGID group cleanup. Pattern-based detection is kept as a fallback for edge cases.

```
Session ends normally
  └── Stop hook — primary pass kills orphaned processes (reparented to PID 1, or on Linux to the user's `systemd --user` manager) in session's PGID; secondary pattern sweep catches orphans that escaped the group (e.g., via setsid). With `CC_STOP_HOOK_AGGRESSIVE=1`, skips the orphan-parent check but still protects ancestors and MCP whitelist.

Session crashes / terminal force-closed
  └── proc-janitor daemon — scans every 30s, kills orphans after 60s grace
  └── OR: LaunchAgent — zero-dependency macOS native, PGID group kill + PPID=1 fallback

Manual intervention needed
  └── cc-monitor — explain current CPU heat by process family before cleanup
  └── macOS companion app — menu bar status, dashboard, process rules, and confirmed cleanup
  └── claude-cleanup — finds orphaned PGIDs and stale agent-browser/Puppeteer/Codex stragglers
  └── claude-ram — check RAM/CPU usage breakdown with orphan visibility
```

### Why PGID?

Claude Code sessions are process group leaders (PGID = session PID). All spawned MCP servers, subagents, and their children inherit this PGID. For proc-janitor and manual tools (`claude-cleanup`, `claude-guard`), one `kill -- -$PGID` reliably cleans up everything in the group — including third-party MCP servers that pattern matching might miss. The Stop hook defaults to a safer PPID=1 orphan-only mode to avoid accidentally killing the active Claude CLI.

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

On macOS 14 or later, build and open the optional local companion after installation:

```bash
./script/build_and_run.sh
```

See [macOS Companion App (local)](#macos-companion-app-local) for its dashboard, process rules, safety behavior, and background verification mode.

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
source /path/to/cc-reaper/shell/cc-monitor.sh
```

Commands available after restart:

- `cc-monitor` — explain current CPU heat contributors by process family before cleanup (read-only)
- `cc-monitor --once` — take one process snapshot and return immediately
- `cc-monitor --json` — emit structured JSON for future automation
- `cc-monitor --apply <module>` — sample, print report, then dispatch a cleanup module (skips menu/confirm; cannot combine with `--json`)
- `cc-monitor --no-prompt` — disable the interactive optimization menu on a TTY
- `claude-ram` — show RAM/CPU usage breakdown with per-session details and orphan visibility (read-only)
- `claude-fd` — show file descriptor usage per session and VirtualMachine processes (read-only)
- `claude-sessions` — list all active sessions with idle detection and process tree RAM
- `claude-cleanup` — kill orphan processes immediately (PGID group kill + pattern fallback, plus stale agent-browser/Puppeteer/Codex cleanup)
- `claude-guard` — automatic session reaper: kills FD-leaking, bloated (RSS > threshold), and excess idle sessions
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

> **⚠️ Safety**: The Stop hook now includes built-in safety mechanisms:
> - **Orphan-only filtering**: By default, only kills processes whose parent has already exited — those reparented to an *orphan parent*. On macOS that is PID 1 (launchd); on Linux it is PID 1 **or the invoking user's `systemd --user` manager** (the per-user reparent target — Linux orphans land there, not on PID 1). This is the definitive indicator of orphan status — unlike TTY filtering, it works correctly in SSH, Docker, tmux, and all terminal environments. Active Claude sessions, subagents, and shared MCP servers (still parented by a live process) are never killed.
> - **Ancestor protection**: Walks the full process tree (`$$` → PID 1) and never kills any ancestor process. This prevents accidental termination of the Claude CLI when an intermediate shell is involved.
> - **Environment variables**: See [Stop Hook Configuration](#stop-hook-configuration) for tuning options.

### 3. Background Daemon (choose one)

#### Option A: LaunchAgent (zero-dependency, macOS only)

Native macOS approach — no Homebrew or Rust required. Runs every 10 minutes, detects orphans by PPID=1. As a final pass it also reaps a PPID=1 orphan that is **sustaining high CPU** (`CC_RUNAWAY_CPU`, default 80%) past `CC_RUNAWAY_ORPHAN_MIN_SEC` (default 180s) **even if its name is whitelisted** — a stuck shared MCP pegging a core is exactly what the name-based whitelist must not protect.

> **Install gotcha:** the `sed` below must resolve `$HOME` to a real path. If it expands empty (e.g. under `sudo`), the plist gets a broken `/.cc-reaper/...` `ProgramArguments` and the agent silently fails every run with `last exit code = 78` — verify with `launchctl print gui/$(id -u)/com.cc-reaper.orphan-monitor | grep program`. `install.sh` now fails fast rather than installing a broken path.

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

`claude-guard` is an automatic session reaper that prevents runaway resource consumption. It operates in three phases:

1. **FD-leak session kill** — Sessions whose open file descriptor count exceeds `CC_MAX_FD` are killed immediately. This addresses the [widely reported FD exhaustion issue](https://github.com/anthropics/claude-code/issues/29888) where VM processes leak ~6,200 FDs/hour, eventually causing system-wide "Operation not permitted" errors.
2. **Bloated session kill** — Sessions whose tree RSS (process + all children) exceeds `CC_MAX_RSS_MB` are killed immediately via PGID, regardless of whether they're idle or active. This addresses the [~42 GB/hr memory leak](https://github.com/anthropics/claude-code/issues/4953#issuecomment-4043206738) caused by unreleased streaming ArrayBuffers.
3. **Idle session eviction** — If session count still exceeds `CC_MAX_SESSIONS`, the oldest idle sessions are killed.

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
| `CC_MAX_FD` | 10000 | File descriptor threshold; sessions exceeding this are killed as FD-leak |
| `CC_AGENT_STALE_MINUTES` | 360 | Age threshold for stale agent-browser, Puppeteer Chrome, and detached Codex/MCP cleanup |
| `CC_RUNAWAY_CPU` | 80 | CPU% above which a process is treated as stuck/runaway (combined with `CC_RUNAWAY_MIN`). Shared by both tools |
| `CC_RUNAWAY_MIN` | **30** in `cc-monitor`, **60** in `claude-guard` | Minutes of elapsed time before a hot process is treated as runaway. The two defaults differ on purpose — the monitor only reports, the guard signals — and setting this env var overrides both at once |
| `CC_RUNAWAY_GRACE_SEC` | 5 | Seconds `claude-guard` waits (Ctrl+C to abort) before SIGTERM-ing runaway protected processes |
| `CC_RUNAWAY_DISABLE` | 0 | Set to `1` to skip `claude-guard`'s runaway phase entirely |
| `CC_RUNAWAY_ORPHAN_MIN_SEC` | 180 | LaunchAgent monitor only: minimum **seconds** a PPID=1 orphan must have lived before its sustained-CPU burn (`CC_RUNAWAY_CPU`) can trigger the whitelist-override reap. Distinct from `CC_RUNAWAY_MIN` (minutes, for live protected processes). |

Example: lower the thresholds for constrained machines:

```bash
export CC_MAX_RSS_MB=2048
export CC_MAX_FD=5000
export CC_AGENT_STALE_MINUTES=120
claude-guard
claude-cleanup
```

`CC_AGENT_STALE_MINUTES` is used by `claude-cleanup` and the LaunchAgent monitor. Lower it only if browser automation frequently leaks on your machine; the default is intentionally conservative.

### Stop Hook Configuration

These environment variables control the [Stop hook](#2-claude-code-stop-hook) behavior. They are checked each time the hook runs.

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_STOP_HOOK_DISABLE` | 0 | Set to `1` to skip all cleanup (the hook becomes a no-op). Useful if the hook interferes with your workflow. |
| `CC_STOP_HOOK_AGGRESSIVE` | 0 | Set to `1` to skip orphan-parent filtering and kill PGID members (still skips ancestor PIDs and MCP whitelist). By default, the hook only kills truly orphaned processes. |

**Why orphan-parent filtering?**

A process is *orphaned* once its original parent has exited and the OS reparents it. macOS reparents to PID 1 (launchd). Linux reparents a process whose login/session scope is gone to the invoking user's **`systemd --user` manager**, not PID 1 — so a PID=1-only check misses every orphan on Linux. cc-reaper builds an **orphan-parent set** once per run: PID 1, plus this user's `systemd --user` manager(s) if present (matched by UID, so another user's manager is never included; the manager PID itself is a reparent target, never a kill candidate). A process whose `PPID` is in that set is truly orphaned and safe to reap. TTY filtering is not used because:

- In SSH, Docker, and remote terminal environments, **all** processes have TTY=`?` — TTY filtering would be a no-op (kill nothing) or dangerous (kill everything including the Claude CLI).
- On macOS, orphans show TTY=`??` while on Linux they show TTY=`?` — handling both requires platform-specific code.
- Orphan-parent filtering is **universal**: works identically on macOS, Linux, in containers, and over SSH. On macOS / hosts without a `systemd --user` manager the set is exactly `{1}`, so behavior is unchanged.

**When to disable the Stop hook:**

```bash
# Option A: Disable temporarily for the current terminal session
export CC_STOP_HOOK_DISABLE=1

# Option B: Add to ~/.zshrc or ~/.bashrc for permanent disable
echo 'export CC_STOP_HOOK_DISABLE=1' >> ~/.zshrc

# Option C: Remove from settings.json entirely (see manual setup section)
```

**When to use aggressive mode:**

If you notice active subagents or MCP servers still parented by a dying session that are not being cleaned up (because their PPID != 1 while the parent is in the process of exiting), enable aggressive mode:

```bash
export CC_STOP_HOOK_AGGRESSIVE=1
```

This restores the original PGID cleanup that kills PGID members regardless of orphan status (ancestors and MCP whitelist still protected).

**Caveat: user-managed daemons (LaunchAgent / systemd):**

The pattern-based fallback in the Stop hook also sweeps orphan-parent processes globally (not scoped to the session's PGID). Shared MCP servers are protected by `MCP_WHITELIST`, but if you run a long-lived daemon under `launchctl` / systemd whose command matches one of the cleanup patterns — e.g., a headless `claude --stream-json` workflow or a `worker-service.cjs --daemon`, whether started by a LaunchAgent or a `systemd --user` unit — it is legitimately parented to an orphan parent and will be killed when any Stop hook fires.

If this applies to you, choose one:

```bash
# Easiest: disable the Stop hook entirely (other layers — proc-janitor / LaunchAgent — still clean up orphans)
export CC_STOP_HOOK_DISABLE=1

# Or: extend MCP_WHITELIST in hooks/stop-cleanup-orphans.sh to include your daemon's command pattern.
```

## Heat Diagnostics

Run `cc-monitor` when the laptop is hot and you want to understand the cause before cleaning anything:

```bash
cc-monitor              # sample for 60s at 5s intervals; progress prints to stderr
cc-monitor --once       # immediate snapshot
cc-monitor --json       # machine-readable output
```

The monitor is read-only. It groups processes into families such as editor, cmux, Codex, Claude, MCP, agent-browser, Chrome, dev server, system, and other. Each finding is classified as:

| Classification | Meaning |
|---|---|
| `SAFE_TO_REAP` | Stale or orphaned process that matches existing cc-reaper cleanup criteria |
| `ASK_BEFORE_KILL` | Active user tool or recent automation; inspect before stopping |
| `DO_NOT_KILL` | System, security, UI, or normal browsing process |

JSON output includes command strings for automation, with common token/key/secret/password argument values redacted.

### Optimize after monitoring

After printing the report, `cc-monitor` can dispatch the right cleanup module so you don't have to switch commands.

**Interactive mode** (default on a TTY when the report has `SAFE_TO_REAP` candidates or family-level heat):

```text
$ cc-monitor --once
=== cc-monitor: heat attribution ===
... report ...

Optimization options:
  1. claude-cleanup (kill all stale orphans) (recommended)
  2. claude-guard --dry-run (preview only)
  3. proc-janitor scan (preview only)
  4. skip
> 1
Run claude-cleanup (kill all stale orphans)? [y/N] y
```

The recommended option is `claude-cleanup` when stale/orphan candidates exist, otherwise `claude-guard --dry-run` when family RSS or per-process CPU is high. The menu is skipped when no candidates exist, on `--json`, when stdin/stdout is not a TTY, or when `--no-prompt` is passed. Modules whose binary is not on `PATH` are hidden from the menu and listed below with an install hint.

**Script-friendly mode** with `--apply`:

```bash
cc-monitor --once --apply claude-cleanup        # kill stale orphans
cc-monitor --once --apply claude-guard-dry      # preview-only
cc-monitor --once --apply proc-janitor-scan     # preview-only via daemon
```

`--apply` skips the confirmation prompt — the flag is itself the explicit opt-in. It cannot be combined with `--json` (exit 2). Module exit codes propagate.

### Stuck/runaway processes

Long-running MCP servers, dev servers, and security daemons are intentionally `protected` — `claude-cleanup` will never kill them. But "protected" is not absolute: a process pinned at high CPU for hours is broken, regardless of category.

Runaway is a claim about behaviour, so since 2026-08-30 **any** non-immutable process can be identified as one — not only those already on the protection list, which was backwards: the processes that run away are the ones nobody listed. Protection still decides what may be *done* about it.

**Reporting and reaping use different floors, deliberately.**

| | threshold | acts on |
|---|---|---|
| `cc-monitor` (reports, never kills) | CPU ≥ `CC_RUNAWAY_CPU` (`80`) for ≥ `CC_RUNAWAY_MIN` minutes (**`30`**) | any non-immutable process |
| `claude-guard` (SIGTERMs) | CPU ≥ `CC_RUNAWAY_CPU` (`80`) for ≥ `CC_RUNAWAY_MIN` minutes (**`60`**) | whitelisted protected MCP servers only |

Reporting earlier than the reaper acts is the point: the report costs a line an operator ignores, while the old shared floor meant a stuck loop held a core for a full hour before it could be named. `claude-guard`'s selection is a separate implementation with its own whitelist and its own default; nothing about which processes can be signalled changed.

`cc-monitor` reclassifies the finding to family `runaway` / `ASK_BEFORE_KILL` and prints a dedicated section with a copy-pasteable kill line. The suggested action differs by protection status, because `claude-guard` filters through its whitelist and suggesting it for an unlisted process would name a remedy that does nothing:

```text
Stuck/runaway processes:
  PID 9594    node    avg 102.70% etime 09:07:51 — appears stuck (sustained high CPU over long elapsed time); review and kill if not actively serving
    suggested: kill 9594
```

A process carrying an Always Protect user rule is still labelled a runaway; its suggested action stays the Always Protect wording.

`claude-guard` adds a Phase 0.5 that reaps these PIDs in PGID-aware mode after `CC_RUNAWAY_GRACE_SEC` (default 5) seconds, so you can `Ctrl+C` if the report surprises you:

```text
=== Claude Guard ===
  Config: max_sessions=3, idle_threshold=1%, max_rss=4096 MB, max_fd=10000, runaway=80%/60min

  --- Runaway protected processes (CPU >= 80% for >= 60 min) ---
  PID 9594    CPU 102.7%  ETIME 09:07:51   node /Users/.../mcp-server-cloudflare run abc
  Sending SIGTERM in 5 seconds (Ctrl+C to abort)...
  Reaped 1 runaway protected process(es), freed ~340 MB
```

Set `CC_RUNAWAY_DISABLE=1` to skip the runaway phase entirely. JSON consumers see runaway entries in the existing `findings` array (with `family: "runaway"`) plus a dedicated `runaway_candidates` array.

Example:

```text
=== cc-monitor: heat attribution ===
Sample: once, snapshots: 1
Mode: read-only (no signals sent)

Top contributors:
   1. cmux                     pid 62199   avg  93.00% max  93.00% rss   561 MB  ASK_BEFORE_KILL  cmux
   2. WindowServer             pid 384     avg  14.90% max  14.90% rss   128 MB  DO_NOT_KILL      system

Safe cleanup candidates:
  PID 37915   agent-browser  avg   0.00% max   0.00% - stale or orphaned browser automation matches cc-reaper cleanup criteria
```

## Resource & Disk Janitor

Beyond process hygiene, cc-reaper ships three system-level janitors (added after a real incident: Load 31 on 12 cores / 95% disk, resolved manually then scripted). All background agents run with `Nice 10` + `LowPriorityIO` — near-zero foreground impact.

| Script | Schedule | What it does |
|---|---|---|
| `resource-watch.sh` | every 10 min (launchd) | Single-pass snapshot (load / CPU idle / memory / disk) to `~/.cc-reaper/logs/resource-watch.log`; macOS notification when load > 2× cores, disk free < 15%, or memory is critically tight. Per-metric 60-min cooldown. |
| `disk-janitor.sh --check` | hourly (launchd) | **Read-only**: disk free % + Time Machine local-snapshot pin detection (snapshots holding freed space hostage after big deletes), plus a **report** of stale scratch checkouts under `/private/tmp` — directories nothing has open, holding no git repository, older than `CC_DJ_TMP_AGE_DAYS` and over `CC_DJ_TMP_MIN_MB`. It names them and never removes them: `/private/tmp` is world-writable and age plus size does not establish that something is abandoned. Alerts, never deletes. |
| `disk-janitor.sh --clean` | Sunday 04:00 (launchd) | Cleans **rebuildable-only** targets: go-build / yarn / pip / brew / bun caches, Spotify / ShipIt / CoreSimulator caches, docker **dangling images** (by explicit id — no `prune` verb, and tagged images are never removed) plus a **report** of unreferenced volumes with docker-generated-looking names, which are never deleted, TM snapshot thinning (dated `com.apple.TimeMachine.*` only, only when disk is below threshold). Tools are resolved from a known directory list, not the caller's `PATH`, because launchd supplies neither Homebrew nor Docker. |
| `worktree-janitor.sh` | manual | Inventories git worktrees under every root in `CC_WJ_ROOT` (colon-separated; defaults to `~/Documents/GitHub:~/GitHub:~/Documents`) or `--repo <path>`; classifies KEEP/REMOVABLE with a **triple safety gate** (uncommitted changes, an active process cwd inside, **or a detached HEAD** ⇒ KEEP — the branch survives, so only a detached HEAD loses commits). "Uncommitted" is measured with `--ignored`, because ignored content goes with the checkout and plain `--porcelain` shows none of it; entries on `CC_WJ_REGENERABLE` / `CC_WJ_REGENERABLE_FILES` are discounted as rebuildable and **anything else keeps the worktree**, so an ignored `.env` or a local database is never silently lost. **Dry-run by default** — only `--apply` removes; branches are never deleted. A root that exists and cannot be read is reported and **fails the run**: an unreadable root and an empty one used to print the same line and return the same status, which under launchd is the difference between "nothing to clean" and "denied by TCC and swept nothing". |

Safety boundaries (hard): never touches user data (`~/Documents`, `~/Downloads`, `~/Desktop`), never runs any `docker prune`, never removes a tagged image, never removes **any** volume, never kills processes, scheduled runs never delete worktrees or prune their administrative records.

What the docker step *does* remove, changed 2026-08-30: dangling images — no tag points at them — by explicit id, computed from the current inventory, and skipped entirely if any inventory command fails. It previously ran `docker system prune -af`, which reaches every unused tagged image including ones that take hours to rebuild; that is not "rebuildable-only" and is gone. **Unused tagged images now survive.**

Volumes are reported and never removed. A 64-hex name looks docker-generated but does not prove it — `docker volume create` accepts such a name from anyone, and `docker volume inspect` exposes no flag that separates the two — so the janitor prints a count and the command to review them, and leaves the decision to you.

Config via env: `CC_RW_LOAD_FACTOR` / `CC_RW_DISK_MIN_PCT` / `CC_RW_MEM_MIN_PCT` / `CC_RW_COOLDOWN_SECS` (watch), `CC_DJ_DISK_MIN_PCT` / `CC_DJ_COOLDOWN_SECS` / `CC_DJ_TMP_DIRS` / `CC_DJ_TMP_AGE_DAYS` / `CC_DJ_TMP_MIN_MB` (disk — the stale temp **report**), `CC_WJ_ROOT` / `CC_WJ_NOTIFY_MIN_GB` (worktree).

## macOS Companion App (local)

cc-reaper includes a native SwiftUI menu bar app for status visibility and safe manual actions. It reads the existing `cc-monitor --once --json` contract and delegates cleanup to the existing shell engine; process discovery, classification, and termination policy remain in the tested shell scripts.

Requirements: macOS 14 or later and the Swift toolchain from current Xcode or Xcode Command Line Tools.

### Install the runtime scripts

Run the interactive installer once, or rerun it after updating cc-reaper:

```bash
cd /path/to/cc-reaper
./install.sh
```

The installer deploys `cc-monitor.sh`, `claude-cleanup.sh`, and the supporting scripts under `~/.cc-reaper/`, then installs or refreshes the selected background daemon and LaunchAgents. It does **not** copy the GUI into `/Applications`.

### Build and open the app

From the repository root:

```bash
swift test
./script/build_and_run.sh
```

`build_and_run.sh` builds the current checkout, stages an unsigned bundle at `dist/CCReaper.app`, stops only a previous app process from that staged bundle, and opens the current build. Once it has been built, it can also be opened directly:

```bash
open /path/to/cc-reaper/dist/CCReaper.app
```

The normal launch opens the dashboard and adds **cc-reaper** to the macOS menu bar.

### App surfaces

| Surface | Available actions |
|---|---|
| Menu bar | View current cleanup/review/runaway counts, refresh status, preview cleanup, start cleanup review, open the dashboard or Settings, and quit the app. |
| Dashboard | View CPU/memory and process findings, filter by Cleanup/Review/Protected/All, inspect suggested actions, open logs, preview cleanup, and explicitly confirm eligible cleanup. |
| Settings | Inspect or override the active script root, configure monitor/refresh preferences, and add or remove custom process rules. |

Refresh is read-only. **Preview Cleanup** runs the same `claude-cleanup --dry-run` policy without sending signals. Actual cleanup is available only from the dashboard after a successful preview and an explicit destructive confirmation, then delegates once to the existing `claude-cleanup` function.

The app prefers a complete installed root at `~/.cc-reaper/`. A bundle staged under `dist/` falls back to the checkout's `shell/` directory when the installation is incomplete, and an explicit Settings override takes precedence over both. Missing scripts, invalid JSON, incompatible monitor output, timeouts, and command failures display an unavailable/error state instead of reporting the system healthy.

### Custom process rules

The companion's **Settings → Process Rules** pane and each finding row's action menu can add a case-insensitive literal command match as either:

- **Always Protect** — matching processes are excluded from cleanup and guard termination paths.
- **Allow Stale Cleanup** — a matching ordinary process may become a cleanup candidate only when it is both stale and detached/orphaned. System/security/UI processes, normal Chrome, cc-reaper, and the Codex Computer Use helper remain immutable; preview and explicit cleanup confirmation are still required.

Rules are stored in `~/.cc-reaper/process-rules.tsv` with owner-only permissions. `protect` wins conflicts, invalid externally edited rows are ignored, and removing the final rule removes the file. The match is literal text, not a regular expression or wildcard.
Always Protect rules are re-read by manual cleanup, guard paths, and the scheduled LaunchAgent before both TERM and SIGKILL, so changing a rule does not require reloading the agent.

Immutable findings do not offer **Allow Stale Cleanup** in their finding-row menu. Settings can persist any otherwise valid literal, but the monitor and cleanup engines still ignore cleanup effects that match an immutable process.

### Background verification

For automated launch checks while continuing other work, run `./script/build_and_run.sh --verify`. Verification launches with background activation, confirms a new app process, stops only that verification process, and leaves both the foreground application and any pre-existing cc-reaper instance alone.

This local app is currently unsigned and repository-staged. Packaging into `/Applications`, code signing, notarization, and automatic updates are not included yet.

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
│   └── stop-cleanup-orphans.sh     # Claude Code Stop hook (PPID=1 orphan filtering + pattern fallback)
├── launchd/
│   ├── cc-reaper-monitor.sh        # LaunchAgent monitor script (PGID + PPID=1 fallback)
│   ├── com.cc-reaper.orphan-monitor.plist  # LaunchAgent config (10-min interval)
│   ├── com.cc-reaper.resource-watch.plist  # System snapshot agent (10-min interval)
│   ├── com.cc-reaper.disk-check.plist      # Read-only disk check agent (hourly)
│   └── com.cc-reaper.weekly-clean.plist    # Rebuildable-cache clean agent (Sun 04:00)
├── proc-janitor/
│   └── config.toml                 # proc-janitor daemon config (alternative to LaunchAgent)
├── shell/
│   ├── cc-monitor.sh               # Read-only heat attribution monitor
│   ├── claude-cleanup.sh           # Shell functions (claude-ram, claude-fd, claude-cleanup, claude-sessions, claude-guard)
│   ├── resource-watch.sh           # System snapshot + threshold alerting
│   ├── disk-janitor.sh             # Disk check (--check) / rebuildable-cache clean (--clean)
│   └── worktree-janitor.sh         # Git worktree inventory + gated removal (dry-run default)
├── tests/
│   ├── agent-process-patterns.sh   # Cleanup-candidate matcher validation
│   ├── cc-monitor-optimize.sh      # cc-monitor optimization menu tests
│   ├── cc-monitor-runaway.sh       # Runaway protected process detection tests
│   ├── ppid-fallback.sh            # PPID=1 fallback kill + whitelist validation
│   ├── resource-watch.sh           # Snapshot / threshold / cooldown tests (stubbed)
│   ├── disk-janitor.sh             # Read-only check / forbidden-flag / thinning tests (stubbed)
│   └── worktree-janitor.sh         # Fixture-repo gate + apply tests
└── README.md
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Related Issues

- [anthropics/claude-code#20369](https://github.com/anthropics/claude-code/issues/20369) — Orphaned subagent process leaks memory
- [anthropics/claude-code#22554](https://github.com/anthropics/claude-code/issues/22554) — Subagent processes not terminating on macOS
- [anthropics/claude-code#25545](https://github.com/anthropics/claude-code/issues/25545) — Excessive RAM when idle
- [thedotmack/claude-mem#650](https://github.com/thedotmack/claude-mem/issues/650) — worker-service spawns subagents that don't exit
- [anthropics/claude-code#29888](https://github.com/anthropics/claude-code/issues/29888) — VM process FD leak (~6,200/hr)
- [anthropics/claude-code#28896](https://github.com/anthropics/claude-code/issues/28896) — settings.json FD leak (1 per tool call)
- [anthropics/claude-code#37482](https://github.com/anthropics/claude-code/issues/37482) — MCP server stdio pipe breaks (orphaned FDs)

## License

Apache 2.0
