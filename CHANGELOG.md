# Changelog

## [Unreleased]

### Added
- **Runaway-CPU override in the LaunchAgent monitor** (`launchd/cc-reaper-monitor.sh`) — a final pass that reaps a PPID=1 orphan sustaining high CPU **regardless of the protected/MCP whitelist**. Closes a real gap: on 2026-06-13 an orphaned `@cloudflare/mcp-server-cloudflare` (whitelisted by name in **both** this monitor and `proc-janitor/config.toml`) burned a full core for ~9h and overheated the machine, because the name-based whitelist is CPU-blind. Four gates keep false kills near-impossible — PPID=1 (parent already dead), `ps %cpu >= CC_RUNAWAY_CPU` (default 80), `etime >= CC_RUNAWAY_ORPHAN_MIN_SEC` (default 180s, reuses the existing `etime_to_seconds` helper), and a 3-second re-sample still over threshold (a one-shot spike is not a runaway). Idle shared MCPs (~0% CPU) and freshly-spawned orphans are never touched. New env var `CC_RUNAWAY_ORPHAN_MIN_SEC` (seconds; distinct from minutes-based `CC_RUNAWAY_MIN`). Verified end-to-end: the daemon kills an aged synthetic runaway orphan under default config while leaving young/idle processes alone.
- **`install.sh` HOME-resolution guard** — an empty `$HOME` (e.g. under `sudo`) previously made `sed "s|__HOME__|$HOME_DIR|"` emit a broken `/.cc-reaper/...` path, installing a LaunchAgent that could never find its script and failed every run with `last exit code = 78 (EX_CONFIG)`. The installer now falls back to `dscl . -read .../NFSHomeDirectory` and fails fast if home is still unresolved, rather than silently installing a broken path.
- **Resource & disk janitor suite** — three system-level janitors beyond process hygiene (`shell/resource-watch.sh`, `shell/disk-janitor.sh`, `shell/worktree-janitor.sh` + three LaunchAgents, all `Nice 10` / `LowPriorityIO`):
  - `resource-watch` — 10-min single-pass load/CPU/memory/disk snapshot with threshold-gated macOS notifications (`CC_RW_*` env config, per-metric 60-min cooldown).
  - `disk-janitor` — hourly **read-only** `--check` (disk free % + Time Machine local-snapshot pin detection) and Sunday-04:00 `--clean` of rebuildable-only caches (go/yarn/pip/brew/bun/Spotify/ShipIt/CoreSimulator + `docker system prune -af`, never `--volumes`) plus gated TM snapshot thinning.
  - `worktree-janitor` — manual multi-repo git worktree inventory with dual safety gate (dirty or active-process-cwd ⇒ KEEP), dry-run by default, `--apply` to remove; branches/commits never deleted.
  - `install.sh` now installs the three scripts to `~/.cc-reaper/` and loads the three LaunchAgents.
  - **Hardening baked in before merge (2026-06-10 live-smoke + adversarial review)** — stubbed tests passed while live runs exposed environment-semantics bugs; all fixed with regression tests:
    - `resource-watch` memory metric read vm_stat's `Pages stored in compressor` (pre-compression — reported 56 GB on a 36 GB machine); now reads `Pages occupied by compressor` and honors vm_stat's own header page size over `hw.pagesize`.
    - `disk-janitor` measured `df -P /` — the sealed APFS system snapshot that reads ~93% free regardless of real usage; now measures `/System/Volumes/Data` (env-overridable via `CC_DJ_VOLUME`) for both threshold checks and TM-thinning freed-space accounting.
    - `worktree-janitor` ran one `lsof` per candidate pid; any vanished pid (routine pgrep→lsof race) was misread as failure, conservatively marking EVERY worktree `active`. Now one batched `lsof` per run, vanished pids simply absent, plus cwd dedup before symlink resolution.
    - Clean-target failures were swallowed by `| tee` (pipeline exit = tee's); exit codes are now captured before logging, so a failing `go clean`/`brew cleanup`/`docker prune` is logged as non-zero instead of success.
    - Healthy `resource-watch` runs leaked exit 1 from a false tail-test (`[ breach ] && notify`), making launchd record every 10-min run as failed; snapshot now returns 0 deterministically.
    - osascript notification strings escape embedded quotes/backslashes; `_cc_dj_init_dirs` fails loudly to stderr instead of silently dropping all logging; ~28 subshell forks removed from the 144×/day resource-watch hot path (builtin `read`/`[[ =~ ]]` instead of `echo | awk`/`echo | grep`).
- **Stop hook safety layers** — `hooks/stop-cleanup-orphans.sh` now defaults to **PPID=1 orphan-only** cleanup (replacing fragile TTY filtering that broke under SSH/Docker/tmux), walks the process tree from `$$` upward and protects every ancestor PID, and exposes two new env vars:
  - `CC_STOP_HOOK_DISABLE=1` — skip all cleanup (no-op).
  - `CC_STOP_HOOK_AGGRESSIVE=1` — skip the PPID=1 check and fall back to PGID-member cleanup (ancestors + MCP whitelist still protected).
- **Stop hook MCP whitelist parity** — Hook now shares the full protected set with `shell/claude-cleanup.sh`, `shell/cc-monitor.sh`, `launchd/cc-reaper-monitor.sh`, and `proc-janitor/config.toml` (added Stripe variants `npm exec @stripe` / `mcp-server-stripe` / `stripe.*mcp`, plus `context7-mcp`, `chrome-devtools-mcp`, `mcp-remote`, `mcp-server-cloudflare`, `sequential-thinking`).
- **`tests/ppid-fallback.sh`** — Mock-based regression for `_cc_reaper_ppid_fallback()` covering PPID=1 selection and whitelist exclusions.
- **`tests/stop-hook-env.sh`** — Mock-based regression for `CC_STOP_HOOK_DISABLE` and `CC_STOP_HOOK_AGGRESSIVE` behavior in the Stop hook.
- **`cc-monitor --apply <module>`** — One-shot dispatch flag that runs sampling, prints the report, then dispatches one of `claude-cleanup`, `claude-guard`, `claude-guard-dry`, `proc-janitor-scan`, or `proc-janitor-clean` non-interactively. Cannot be combined with `--json` (exit 2); module exit codes propagate.
- **`cc-monitor` interactive optimization menu** — On a TTY without `--json`/`--no-prompt`/`--apply`, when the report contains `SAFE_TO_REAP` candidates or family-level heat, `cc-monitor` appends a numbered menu listing available cleanup modules with a `(recommended)` marker; destructive choices require a `[y/N]` confirmation. Modules whose binary is missing on PATH are hidden with an install hint. `--no-prompt` opts out.
- **Runaway-protected detection** — `cc-monitor` reclassifies any protected process matching `CC_RUNAWAY_CPU` (default 80%) for `CC_RUNAWAY_MIN` (default 60 min) from `DO_NOT_KILL` to family `runaway` / `ASK_BEFORE_KILL` and prints a dedicated `Stuck/runaway protected processes:` section with a copy-pasteable `kill <pid>` per entry. JSON output gains a `runaway_candidates` array.
- **`claude-guard` Phase 0.5** — Detects runaway protected processes via the same thresholds, prints the list, waits `CC_RUNAWAY_GRACE_SEC` (default 5) seconds for `Ctrl+C`, then PGID-kills with desktop notifications. Honors `--dry-run` and `CC_RUNAWAY_DISABLE=1` opt-out.
- **`CC_RUNAWAY_*` environment variables** — `CC_RUNAWAY_CPU`, `CC_RUNAWAY_MIN`, `CC_RUNAWAY_GRACE_SEC`, and `CC_RUNAWAY_DISABLE` for runaway tuning.
- **Dispatch banner** — `cc-monitor` prints `=== Dispatching <module label> ===` to stderr before executing a chosen module so the read-only report and the destructive action are visually separated.
- **`cc-monitor` command** — Read-only heat attribution monitor that samples process state, groups CPU pressure by process family, classifies findings as `SAFE_TO_REAP`, `ASK_BEFORE_KILL`, or `DO_NOT_KILL`, and supports `--once` plus `--json` output.
- **Agent process cleanup coverage** — `claude-cleanup` and the LaunchAgent monitor now detect stale or orphaned agent-browser, Chrome-for-Testing, Puppeteer temporary Chrome profiles, and Codex CLI/native process families.
- **`CC_AGENT_STALE_MINUTES` environment variable** — Configurable stale-age threshold for browser automation and detached Codex/MCP cleanup, defaulting to 360 minutes.
- **Pattern validation script** — `tests/agent-process-patterns.sh` validates positive and negative cleanup candidates without spawning or killing processes.

### Changed
- Protected pattern in both `cc-monitor` and `claude-cleanup` now also matches the `mcp-server-cloudflare` cmd form (the path-style `cloudflare/mcp-server` already covered the `@cloudflare/...` install layout).
- Module list iteration in `cc-monitor` switched from word-splitting to newline-delimited reads so it is robust regardless of shell IFS.
- proc-janitor config now targets orphaned agent-browser, Puppeteer profile, and Codex process patterns while explicitly whitelisting user/system apps and shared services.
- Shared MCP protection now includes Supabase and Stripe child process aliases such as `mcp-server-supabase`.
- README and Claude guidance now document the expanded safety boundaries and validation command.

### Fixed
- `cc-monitor` interactive menu now selects the correct module under both bash and zsh; previously, zsh's 1-based array indexing caused the indexed-access path to pick the wrong entry or empty.
- `cc-monitor` dispatch now resolves cleanup modules installed as sourced shell functions (the canonical install via `.zshrc`); the previous `eval command <name>` bypassed function lookup and returned `127`.
- `.gitignore` extended to exclude `.env`, `.claude/`, and the large `2026-03-07_x-claude-*.json` research dumps so workspace artifacts are not staged with `git add -A`. GitHub push protection caught one such accident before it landed.
- `cc-monitor` human mode now prints sampling progress immediately, so the default 60-second sample no longer appears stuck.

## [0.6.0] - 2026-03-24

### Added
- **`claude-fd` command** — Read-only file descriptor usage report for Claude Code sessions and VirtualMachine processes
  - Shows system FD limits (kern.maxfiles, kern.maxfilesperproc, ulimit)
  - Per-session FD count with `[FD-LEAK]` warning when exceeding threshold
  - VirtualMachine process FD monitoring (read-only, no kill — these are system-level)
- **FD-leak detection in `claude-guard`** — New Phase 0 (highest priority) kills sessions whose open FD count exceeds `CC_MAX_FD`
  - Priority order: FD-leak > bloated (RSS) > idle
  - Guard output table now includes FDs column
  - macOS desktop notifications for FD-leak kills
- **`CC_MAX_FD` environment variable** — Configurable FD threshold (default: 10000) with non-numeric value fallback
- **`_claude_process_fds` helper** — Reusable FD counter via `lsof -p`

### Context
Addresses the widely reported file descriptor exhaustion issue ([#29888](https://github.com/anthropics/claude-code/issues/29888), [#28896](https://github.com/anthropics/claude-code/issues/28896), [#37482](https://github.com/anthropics/claude-code/issues/37482)) where Claude Code leaks ~6,200 FDs/hour via VM processes, eventually causing system-wide "Operation not permitted" errors. Normal sessions use ~200-500 FDs; the 10,000 default threshold catches leaks well before system exhaustion.

## [0.5.1] - 2026-03-12

### Fixed
- **PGID kill now whitelists long-running MCP servers** — Stop hook and `claude-guard` previously killed ALL processes in a session's PGID group, including shared MCP servers (Supabase, Stripe, context7, claude-mem, chroma-mcp). When a session ended, its MCP servers were killed even if other active sessions were still using them, causing "disabled" status in those sessions.
- **New `_claude_pgid_kill` helper** — Extracted whitelist-aware PGID kill logic into a shared function used by both `claude-guard` (Phase 1 bloated + Phase 2 idle) and the stop hook. Iterates group members individually, skipping whitelisted MCP servers instead of blind `kill -- -$PGID`.

## [0.5.0] - 2026-03-12

### Added
- **`claude-guard` automatic session reaper** — Two-phase guard that kills bloated sessions (tree RSS exceeds threshold) and evicts excess idle sessions
  - Phase 1: Kill sessions whose tree RSS (process + all children/grandchildren) exceeds `CC_MAX_RSS_MB` (default: 4096 MB), regardless of idle/active status
  - Phase 2: Kill oldest idle sessions if count exceeds `CC_MAX_SESSIONS`
  - PGID-based process group termination ensures all child processes are cleaned up
  - macOS desktop notifications when sessions are reaped
  - `--dry-run` flag to preview without killing
- **`CC_MAX_RSS_MB` environment variable** — Configurable RSS threshold (default: 4096 MB) with non-numeric value fallback and warning
- **`_claude_tree_rss` helper function** — Reusable tree RSS calculator (process + children + grandchildren), extracted from `claude-sessions`

### Changed
- `claude-sessions` refactored to use shared `_claude_tree_rss` helper, reducing code duplication

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
