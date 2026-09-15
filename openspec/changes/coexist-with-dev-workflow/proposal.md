## Why

An audit of a live install (a shared Mac mini running Claude Code sessions, a dev-workflow
harness and four CI runner slots) found cc-reaper working against the work it runs beside.

**The LaunchAgent monitor kills legitimate work.** Every one of the six kills in
`~/.cc-reaper/logs/monitor.log` was a false positive:

```
2026-09-10 10:57:24 KILL runaway (whitelist-override) PID=25332 CPU=94.9%->94.0% ELAPSED=09:16 CMD=/Users/stimaclaw/.cache/uv/builds-v0/.tmpbFywum/bin/python -m pytest paper3/tests -q -x --no-header
2026-09-11 01:31:36 KILL runaway (whitelist-override) PID=58233 CPU=99.1%->99.4% ELAPSED=03:17 CMD=/private/tmp/claude-501/-Users-stimaclaw-GitHub-research/.../scratc
```

Four test runs and two scripts from a session scratchpad. The override's selection is "PPID=1,
CPU at least 80%, older than 180 seconds, and the command line contains `node`, `npx`, `mcp`,
`bun`, `codex` or `claude` anywhere". Background commands started from Claude Code are
reparented to launchd. Their command lines carry `/private/tmp/claude-501/...` scratchpad paths.
Tests, builds and experiments are hot for minutes by nature. The age gate also fails open: the
octal bug in `etime_to_seconds` (open PR #27) makes `09:16` unparseable, and `[ "" -lt 180 ]`
does not skip.

The override duplicates a better owner. `claude-guard`'s runaway phase runs every 10 minutes
from the guard LaunchAgent, which `install.sh` installs on every macOS install. It selects only
`shared`-class processes through the single protection classification, after
`CC_RUNAWAY_MIN` (60) minutes. The monitor's own name list is the drift the protection-class work
removed from every other path.

**Installed shell functions point at a checkout that no longer exists.** `install.sh` writes
`source "$SCRIPT_DIR/shell/claude-cleanup.sh"`: the checkout it ran from. Under a
worktree-per-session workflow that is a task worktree, and reclamation removes it. On the audited
host `~/.zshrc` sources a reclaimed worktree, so every interactive shell prints two
`no such file or directory` errors, and `claude-cleanup`, `claude-guard` and `cc-monitor` are
missing. Re-running the installer does not repair it: an rc file that mentions
`claude-cleanup.sh` is treated as done.

**The weekly clean removes docker images on a shared host.** `disk-janitor --clean` runs
`docker rmi` on dangling images. Those images belong to whoever built them: CI runner image
rebuilds, other sessions' local stacks. Removing another user's resources on a shared host is
what the operator's policy forbids, and the target freed 0 B on its last run.

## What Changes

- **BREAKING (behavior):** remove the monitor's runaway-CPU override. `CC_RUNAWAY_ORPHAN_MIN_SEC`
  no longer has any effect. Stuck shared services remain claude-guard's runaway phase's to
  signal.
- The installer sources the deployed copies under `~/.cc-reaper/`, guarded so a missing file
  prints nothing. On update it rewrites rc lines in its own generated shape that point anywhere
  else, after backing the rc file up. Lines in any other shape are left alone and named.
- `disk-janitor --clean` reports dangling docker images (count and a review command) and removes
  none. No code path in the janitor runs `docker rmi` or any `prune`.
- The repository's stop hook gains the documented blind spot that the deployed copy on the
  audited host already carries: a `nohup`-started server lives in the tool call's process group,
  not the session's. Documentation only.

## Not changing

- **A CI-runner "job active" gate on the weekly clean.** The runner slots run each job in an
  ephemeral container (`~/ci-runner/run-loop.sh`), so host-side tool caches are not what a job
  reads. `docker rmi` without `-f` already refuses an image a container uses.
- **Per-tool "in use" gates for cache purges.** There is no observed failure, and a
  process-name probe cannot tell a build from a long-lived dev server.
- **The deployed stop hook.** On the audited host it is a symlink into another repository, which
  owns that copy and removed `codex` from its whitelist on purpose. The installer already refuses
  to write through a symlink.

## Impact

- `launchd/cc-reaper-monitor.sh`, `install.sh`, `shell/disk-janitor.sh`,
  `hooks/stop-cleanup-orphans.sh` (comment only)
- Tests: a new monitor main-body test with stubbed `ps`/`kill`, installer rc-file tests in a
  sandbox HOME, and a disk-janitor docker report test
- README, CHANGELOG
- Rollback: revert the merge commit. Deployed copies are replaced by rename, and the previous
  versions are kept under `~/.cc-reaper/state/`.
