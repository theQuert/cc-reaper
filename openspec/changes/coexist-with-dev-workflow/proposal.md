## Why

An audit of a live install found cc-reaper working against the work it runs beside. The host is
a shared Mac mini running Claude Code sessions, a dev-workflow harness and four CI runner slots.

**The LaunchAgent monitor kills legitimate work.** All six kills in
`~/.cc-reaper/logs/monitor.log` were false positives:

```
2026-09-10 10:57:24 KILL runaway (whitelist-override) PID=25332 CPU=94.9%->94.0% ELAPSED=09:16 CMD=/Users/stimaclaw/.cache/uv/builds-v0/.tmpbFywum/bin/python -m pytest paper3/tests -q -x --no-header
2026-09-11 01:31:36 KILL runaway (whitelist-override) PID=58233 CPU=99.1%->99.4% ELAPSED=03:17 CMD=/private/tmp/claude-501/-Users-stimaclaw-GitHub-research/.../scratc
```

Four were test runs and two were scripts from a session scratchpad. The override selected a
process when it was PPID=1, at 80% CPU or more, older than 180 seconds, and its command line
contained `node`, `npx`, `mcp`, `bun`, `codex` or `claude` anywhere. Background commands started
from Claude Code are reparented to launchd, and their command lines carry
`/private/tmp/claude-501/...` paths. The age gate also failed open on an etime it could not parse
(the octal bug in open PR #27).

**claude-guard's runaway phase ends whole sessions and applications.** Independent review
reproduced it with stubbed `ps` and `kill`. A shared MCP server at 95% CPU inside a live Claude
CLI's process group got the CLI, a stream-json subagent and another MCP server signalled with
it, because the signal stage walks the selected PID's process group. The phase selects on a
single CPU sample and uses process age as if it were time spent hot. It also selects
applications and dev servers. The guard LaunchAgent on the audited host has already selected
and signalled `ChatGPT.app` with its Codex framework processes (reported "freed ~2374 MB") and
`cmux.app` (etime 15 days, 80.8%), which is the terminal the Claude sessions run in. Review of
the first fix found eligibility still a substring test over the whole command line: a Claude
session whose `--settings` named `claude-mem`, or a test run under a directory named after a
server, qualified. Review of the second found its lifetime CPU average let a multi-threaded
server that was busy early qualify on a later burst.

**Installed shell functions point at a checkout that no longer exists.** `install.sh` writes
`source "$SCRIPT_DIR/shell/claude-cleanup.sh"`. Under a worktree-per-session workflow that
checkout is a task worktree, and reclamation removes it. Every interactive shell on the audited
host prints two `no such file or directory` errors, and `claude-cleanup`, `claude-guard` and
`cc-monitor` are missing. Re-running the installer does not repair it.

**The weekly clean removes docker images on a shared host.** `disk-janitor --clean` runs
`docker rmi` on dangling images. Those images belong to whoever built them. The target freed 0 B
on its last run.

## What Changes

- **BREAKING (behavior):** the monitor's runaway-CPU override is removed and
  `CC_RUNAWAY_ORPHAN_MIN_SEC` no longer has any effect. A hot PPID=1 process that no family
  predicate names is no longer reaped by any scheduled path. That includes a bare
  `node …/index.js` MCP server or `npm exec @playwright/mcp`, and equally pytest, `codex exec`
  and `claude -p`.
- **BREAKING (behavior):** claude-guard's runaway phase selects only a process that is itself a
  known shared MCP server, never one whose arguments merely name one, and only once it has used
  at least `CC_RUNAWAY_CPU` percent of every interval between guard runs for `CC_RUNAWAY_MIN`
  minutes, from CPU-time samples kept in `~/.cc-reaper/state/`. It re-reads
  each PID after at least three seconds, signals only a PID still running the same command and
  still hot, and signals that PID alone. Applications, development servers and process managers
  are never selected; cc-monitor still reports them, and names claude-guard only for a known
  shared MCP server.
- `install.sh`:
  - Sources the deployed copies under `~/.cc-reaper/`, guarded.
  - Repairs a line in its old generated shape in place when nothing else names the script;
    otherwise it changes nothing and prints the change, and it never removes a line.
  - Backs the rc file up before any change, keeps its mode, ACL and extended attributes on a
    rewrite, and creates a missing one without a backup.
  - Never changes a symlinked, hard-linked, unreadable or unwritable rc file, not even by
    appending; it prints the change instead.
  - Never stops the installation over rc configuration.
  - Deploys every script by temporary file and rename.
- `disk-janitor --clean` reports dangling docker images and removes none.
- The repository's stop hook documents the tool-call process-group blind spot.
- README documents that a manual Option A install has no runaway coverage without the guard
  LaunchAgent.

## Not changing

- **No CI-runner "job active" gate on the weekly clean.** Runner slots run each job in an
  ephemeral container (`~/ci-runner/run-loop.sh`), so host tool caches are not what a job reads.
- **No per-tool "in use" gates for cache purges.** There is no observed failure.
- **The deployed stop hook.** On the audited host it is a symlink into another repository, which
  owns that copy, and the installer already refuses to write through it.
- **The octal etime bug in the monitor.** That is PR #27, and nothing here depends on it.

## Impact

- **Code:** `launchd/cc-reaper-monitor.sh`, `shell/claude-cleanup.sh` (runaway phase),
  `shell/cc-monitor.sh` (runaway suggested action), `install.sh`, `shell/disk-janitor.sh`,
  `hooks/stop-cleanup-orphans.sh` (comment only).
- **Tests:** new `tests/monitor-selection.sh`, `tests/guard-runaway.sh` and
  `tests/install-rc-source.sh`; updated `tests/protection-classes.sh`,
  `tests/cc-monitor-runaway.sh` and `tests/disk-janitor.sh`.
- **Docs:** README, CHANGELOG, CLAUDE.md.
- **Rollback:** revert the merge commit and run the reverted `install.sh`, which copies each
  script over the deployed one in place rather than by rename, so run it when no LaunchAgent job
  is mid-run. It keeps no previous copy. The rc file is backed up as
  `~/.zshrc.cc-reaper-backup-<timestamp>` before any change, and the repaired rc lines load
  whichever version is deployed.
