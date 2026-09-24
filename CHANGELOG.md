# Changelog

## [Unreleased]

### Changed
- **The growth targets template no longer lists `~/.Trash`.** macOS privacy protection
  denies it to a LaunchAgent without Full Disk Access, so the first scheduled run recorded
  `denied` for it and would have every six hours after; an interactive `du` of the same
  path prints a silent 0.
- **`CC_DJ_GO_CACHE_TRIM_DAYS=off` leaves the go build cache to another reclaimer.** One
  cache, one owner: where a faster reclaimer already trims it (on the reporting host, the
  skills repository's `reclaim-byproducts`, every three hours), the weekly clean logs that
  and does not run `go` at all. It is not counted as a `SKIP`.
- **`disk-janitor --clean` trims the go build cache by age instead of emptying it.** The
  weekly `go clean -cache` removed 28.6 GB on 2026-09-13 and 10.8 GB on 2026-09-20 on one
  host, and every session rebuilt from cold: three days later 14 GB of the 27 GB cache was
  that rebuild, never used again, against a 6 GB hot set. It also ran beside builds in
  progress and removed the subdirectories they write into. The target now deletes only
  entries (`<hash>-a`, `<hash>-d` in the two-hex-digit subdirectories of `go env GOCACHE`)
  unused for `CC_DJ_GO_CACHE_TRIM_DAYS` days, default 3 - the files Go's own five-day trim
  removes, sooner - keeps the top-level files, and is a counted `SKIP` while a go build,
  test or toolchain process runs, or when `go`, the cache path or the retention is unusable.
- **Scheduled worktree sweeps can prove landing by merged PR.** launchd starts agents with
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, where `gh` is not installed, so the six-hourly sweep
  never proved a squash-merged worktree landed by PR: 0 `landed=pr` in scheduled logs against 54
  from session sweeps on one day. An executed run now appends `CC_WJ_TOOL_DIRS` (default
  `/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`) to PATH, never prepending, and a run that
  still cannot find `gh` says so once. Sourcing the script leaves PATH alone. With `gh` found,
  the scheduled sweep also applies the abandoned rule (unlanded, clean, idle 168 hours, no pull
  request ever opened) across every root; until now only session sweeps could, in their own
  repository. Removal keeps the branch.
- **A sweep that defers to a live sweep exits 0.** Removal and trim sweeps take the same
  per-repository lock; a run that finds a live holder removes nothing there and leaves the
  repository to the next sweep. Counting that as a failure put 14 false `status=1` lines in
  one day's session log. A lock that cannot be taken, including one whose parent directory is
  missing or unwritable, still fails the run.
- **`disk-janitor --clean` prunes builder cache unused for a week.** It runs
  `docker builder prune --force --filter until=168h` when the daemon is reachable. BuildKit never
  prunes a record a running build holds, and anything used within 168 hours stays. This replaces
  `--orbstack-clean`, which required a runner-drain proof nothing produced and refused while any
  `ci-runner-*` container existed, which on the host that needed it was always. `--orbstack-clean`,
  the drain-proof and protected-container settings, and `hooks/lifecycle-reclaim.sh`, which nothing
  called, are removed; the installer deletes a deployed `lifecycle-reclaim.sh`.
- **LaunchAgent replacement and private-temp recovery are fail-observable.** Installer updates now
  wait until an asynchronously retiring old job is actually absent before registering its
  replacement. Each janitor run also removes dead-owner transcript projection directories left
  when launchd escalates past shell traps; fresh unmarked and live-owner directories are retained.
- **Transcript claim matching now scales with transcripts, not transcript/worktree pairs.** The first candidate query in an activity snapshot materializes a private normalized tool-input projection; later candidates use fixed-string matching without starting another Python interpreter. Persistent indexes remain offset-only, pre-removal refreshes still rebuild activity state, malformed relevant records retain the exact fail-closed parser, non-UTF-8 path bytes round-trip, and signal/exit cleanup removes projections from interrupted runs.
- **`worktree-janitor` reclaims only landed, idle, unheld, unclaimed worktrees.** The previous gate (clean + no process cwd from a `pgrep` subset + not detached) classified a worktree REMOVABLE while a session was editing it through `git -C`, and removed checkouts whose work had never reached the base. Now: machine-wide `lsof` of every cwd **and every open file**, each bounded and each failing closed on an empty or failed scan; verified-live Claude and Codex registry/tool-call claims as an independent veto; `CC_WJ_IDLE_HOURS` (default 48, a malformed value refuses the run); landing proven against a freshly fetched base by ancestry, `git merge-tree` content, or a merged PR at this exact head SHA whose merge commit is still on the base; a detached HEAD needs ancestry. Harness claims, holders, contents and idleness are asked again immediately before each removal. Superseded: "an unpushed branch is still removable".
- **The LaunchAgent monitor no longer selects by CPU.** Its runaway-CPU override killed any PPID=1 process at 80% CPU for three minutes whose command line contained `node`, `npx`, `mcp`, `bun`, `codex` or `claude` anywhere. All six kills in a live `monitor.log` (2026-09-10/11) were pytest runs and session scratchpad scripts - background work Claude Code reparents to launchd, carrying `/private/tmp/claude-501/` paths - and its age gate failed open on an etime it could not parse. Orphans the family sweep names (`mcp-server`, `npm exec mcp-`, stream-json, Codex CLI, agent-browser, Puppeteer) are still reaped; a hot orphan it does not name, such as a bare `node …/index.js` MCP server or `npm exec @playwright/mcp`, is no longer reaped by any scheduled path. `CC_RUNAWAY_ORPHAN_MIN_SEC` is gone.
- **`claude-guard`'s runaway phase signals each re-checked MCP server alone.** It signalled the selected PID's whole process group - a shared MCP server started by a Claude CLI took the CLI, its stream-json subagents and sibling servers with it - on one CPU sample, reading process age as time spent hot, and it selected applications and dev servers: on one host its LaunchAgent signalled ChatGPT.app and cmux.app, the terminal the sessions ran in. Now it selects a process only when the process itself is a known shared MCP server - its executable, or what a package runner or interpreter runs, never a name somewhere in its arguments (a session whose `--settings` named `claude-mem` qualified) - and only once it has used at least `CC_RUNAWAY_CPU` percent of every interval between guard runs for `CC_RUNAWAY_MIN` minutes, measured from CPU-time samples kept in `~/.cc-reaper/state/runaway-samples.tsv` (`CC_RUNAWAY_SAMPLES_FILE`) and a process listing that carries no argument text; a gap of more than 20 minutes between runs starts a streak over. It re-reads each PID after at least three seconds, signals only if the command is unchanged and still over `CC_RUNAWAY_CPU`, and signals that PID alone. A stall is signalled 60 to 70 minutes after a run first sees it; `cc-monitor` reports it sooner. `--dry-run` records no samples, and a zero `CC_RUNAWAY_CPU` or `CC_RUNAWAY_MIN` falls back to its default. `_claude_pgid_kill` loses its `force_target` argument, and `cc-monitor` names `claude-guard` as the remedy only for a known shared MCP server. A sample dated after the run reading it, or whose streak starts after the sample was taken, is refused, so a clock set back starts the streak over. A run that cannot record this run's samples - it cannot create the file, cannot write it to the end, or cannot put it in place - keeps the previous samples, prints `WARNING: cannot record runaway samples at <path>; selecting nothing.` on stderr and says the same in its own report, and selects nothing: a measurement that could not be taken authorises no kill. A `CC_RUNAWAY_SAMPLES_FILE` with no directory part names a file where claude-guard runs, not a directory to create.
- **`install.sh` sources the deployed copies, and never stops over the rc file.** Shell rc lines read `[ -r "$HOME/.cc-reaper/claude-cleanup.sh" ] && source ...` instead of naming the checkout the installer ran from, which under worktree-per-session was a task worktree that reclamation removed - every shell printed errors and the commands were missing. An update replaces a line in the old generated shape in place (printing it) when nothing else names the script; beside the current line, a second stale line or any other line naming the script it changes nothing and prints the change, because removing a line can change what the lines around it mean. It adds the current line when the old one is commented out, leaves a commented-out current line off, and backs the rc file up before any change - never a file the run itself created - keeping its mode, ACL and extended attributes on a rewrite. A symlinked, hard-linked, unreadable or unwritable rc file is left alone with the change printed, and the installation completes.
- **`install.sh` deploys every script by rename.** The stop hook, the monitor and the scripts under `~/.cc-reaper/` were overwritten in place with `cp`, which can hand a run already reading one a mix of old and new bytes; each is now written beside the destination and renamed over it.
- **`disk-janitor --clean` removes no docker image.** Dangling images are reported (count and review command), like unreferenced volumes. On a shared host an untagged image is another user's build.
- **`.worktree-regenerable`** - a repository declares its own runtime byproducts, read from the fetched base (never the worktree), with patterns that name no path dropped and reported, and credential-shaped files inside declared directories or caches still keeping the worktree. The report names what keeps each one.

### Added
- **`archive:` lines in `.worktree-regenerable` let a hand-written record leave with its
  worktree.** stima-api's staging preflight requires an ignored, hand-written
  `.canary-window-plan` in every task worktree. Nothing rebuilds it, so it kept 14 landed
  worktrees on 2026-09-24, and ten more each day. A file named by `archive:<pattern>` no
  longer keeps its worktree when it is a regular file, is not credential-shaped, and is at
  most `CC_WJ_ARCHIVE_MAX_BYTES` (1 MiB). Before `--apply` removes the worktree, the janitor
  copies the file into a new directory under `CC_WJ_ARCHIVE_DIR` (default
  `~/.cc-reaper/archive`), compares the copy byte for byte, and records it in `index.tsv`.
  Any failure keeps the worktree. The list comes from the same fresh read as the recheck
  before the removal. `archive:` is asked before a plain declaration, and a directory a plain
  line discounts whole keeps its worktree while an `archive:` pattern may name a path inside it. An older janitor drops the line as a pattern that names no path.
- **An accepted task's worktree is reclaimed without the idle and session windows.** A dev
  loop that knows a task was accepted and is live writes `claude-task-done` into the
  worktree's git dir, beside `claude-task-worktree`; only its `head=` line is read. When the
  tree is clean and the file holds exactly one well-formed `head=` naming the current HEAD, on
  a branch, the sweep does not ask for the recent-session lease and uses an idle window of 0
  hours, and the report prints `done: claude-task-done at HEAD <sha>`. Holders, live claims
  (including one read after a lease answer), contents, landing, git state and the rechecks
  before removal still decide, and the annotation is read again before removal. A stale,
  malformed or detached annotation is ignored. The branch is kept.
- **`disk-janitor --check` says which path grew.** A fall in disk free named no path, so
  every incident began with a manual `du` hunt. The hourly check now runs `growth-watch.py`
  over the targets in `~/.cc-reaper/growth-targets.tsv` (label, path, owner, optional alert
  GB): directories, glob-expanded directories sampled one key per match, and Docker
  categories and volumes from one `docker system df` call each. A key is measured at most
  once per `CC_DJ_GROWTH_INTERVAL_HOURS` (6), oldest first, under `nice`, within
  `CC_DJ_GROWTH_BUDGET_SECONDS` (240) per run; samples stay 14 days in
  `state/growth-samples.tsv`, and a target that cannot be read records its status, never
  zero. A key or label total that grew by its threshold (default 5 GB) against a day-old
  sample logs `ALERT:growth` with the owner and posts one cooldown-gated notification; each
  sampling run logs its top three growers. Without `python3` the step is a counted `SKIP`.
  The installer ships a generic targets file and keeps an edited copy.
- **`resource-watch` flags a sudden fall in disk free.** Each run records `<epoch> <free GB>` in
  `~/.cc-reaper/state/disk-free-samples`, keeping the last 12, and when free space fell by at
  least `CC_RW_DISK_DROP_GB` (default 10; `0` disables) against the newest sample 25 to 45
  minutes old, it logs `ALERT:disk-drop` and notifies under the per-metric cooldown. Fast growth
  is flagged before the percentage floor is reached.
- **Recent-session lease and `--claims` observability** — releasing a Claude pid or Codex writer lock no longer makes an already-old worktree immediately removable. Codex `updated_at`/`archived_at` and Claude transcript activity create a separate 48-hour lease (`CC_WJ_SESSION_GRACE_HOURS`), reported as `KEEP(recent-session)`. `worktree-janitor --claims [id|path]` shows live claims and recent leases with state, age, and remaining grace without fetching or changing anything.
- **Shared Claude/Codex worktree policy** — `~/.cc-reaper/worktree-janitor.conf` owns the 48-hour window and separate SessionEnd/scheduled apply switches; `worktree-session-end.sh` is the thin hook for both harnesses. A low-priority LaunchAgent runs `--scheduled` every six hours plus at load. The installer migrates Claude's global hook, boots out and archives the legacy Claude worktree LaunchAgent, and can configure explicit Codex repositories through `CC_REAPER_CODEX_REPOS`; checked-in Codex hooks remain the preferred integration. `--landed PATH` exposes the same ancestry/content/exact-PR proof read-only to attached-resource reapers, and the cleanup task's own inventory tool calls no longer pin every path it examines (its cwd remains protected).
- **`worktree-janitor --session`** - a SessionEnd hook that sweeps the session's repository detached (fork, then `setsid`), under a per-repository lock, with a run record (start, elapsed, free space before and after). Keeps the session's own checkout; reports unless `CC_WJ_SESSION_APPLY=1`. Closes the gap `janitors-that-can-see` recorded as needing a TCC-capable process: the session is one.
- **`docs/worktree-reclamation.md`** - the method, the three landing proofs, and five ways a reclaimer silently reclaims nothing.
- **Runaway-CPU override in the LaunchAgent monitor** (`launchd/cc-reaper-monitor.sh`) — a final pass that reaps a PPID=1 orphan sustaining high CPU **regardless of the protected/MCP whitelist**. Closes a real gap: on 2026-06-13 an orphaned `@cloudflare/mcp-server-cloudflare` (whitelisted by name in **both** this monitor and `proc-janitor/config.toml`) burned a full core for ~9h and overheated the machine, because the name-based whitelist is CPU-blind. Four gates keep false kills near-impossible — PPID=1 (parent already dead), `ps %cpu >= CC_RUNAWAY_CPU` (default 80), `etime >= CC_RUNAWAY_ORPHAN_MIN_SEC` (default 180s, reuses the existing `etime_to_seconds` helper), and a 3-second re-sample still over threshold (a one-shot spike is not a runaway). Idle shared MCPs (~0% CPU) and freshly-spawned orphans are never touched. New env var `CC_RUNAWAY_ORPHAN_MIN_SEC` (seconds; distinct from minutes-based `CC_RUNAWAY_MIN`). Verified end-to-end: the daemon kills an aged synthetic runaway orphan under default config while leaving young/idle processes alone.
- **`install.sh` HOME-resolution guard** — an empty `$HOME` (e.g. under `sudo`) previously made `sed "s|__HOME__|$HOME_DIR|"` emit a broken `/.cc-reaper/...` path, installing a LaunchAgent that could never find its script and failed every run with `last exit code = 78 (EX_CONFIG)`. The installer now falls back to `dscl . -read .../NFSHomeDirectory` and fails fast if home is still unresolved, rather than silently installing a broken path.
- **Resource & disk janitor suite** — three system-level janitors beyond process hygiene (`shell/resource-watch.sh`, `shell/disk-janitor.sh`, `shell/worktree-janitor.sh` + four LaunchAgents, all `Nice 10` / `LowPriorityIO`):
  - `resource-watch` — 10-min single-pass load/CPU/memory/disk snapshot with threshold-gated macOS notifications (`CC_RW_*` env config, per-metric 60-min cooldown).
  - `disk-janitor` — hourly **read-only** `--check` (disk free % + Time Machine local-snapshot pin detection) and Sunday-04:00 `--clean` of rebuildable-only caches (go/yarn/pip/brew/bun/Spotify/ShipIt/CoreSimulator + `docker system prune -af`, never `--volumes`) plus gated TM snapshot thinning.
  - `worktree-janitor` — manual multi-repo git worktree inventory with dual safety gate (dirty or active-process-cwd ⇒ KEEP), dry-run by default, `--apply` to remove; branches/commits never deleted.
  - `install.sh` now installs the three scripts to `~/.cc-reaper/` and loads the four LaunchAgents.
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
