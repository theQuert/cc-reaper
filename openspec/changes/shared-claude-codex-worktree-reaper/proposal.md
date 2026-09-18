# Why

Worktree cleanup is currently split between a Claude global settings file, Claude-owned
hook scripts, and a Codex repository adapter that calls those Claude paths.  The deployed
idle window is six hours, Codex worktrees are deliberately excluded from the inventory,
and neither harness's active-session registry is an independent veto.  A session can work
in a linked worktree through an absolute tool workdir while its process cwd remains in the
primary checkout, so process holders alone do not prove the worktree is unused.

The policy must be portable between machines and must survive either harness being absent.
`cc-reaper` is the durable installation and scheduling boundary; Claude and Codex hooks
should only trigger it.

# What Changes

- Make 48 hours the worktree settlement window.
- Treat verified live Claude session records and open Codex writer locks as independent
  worktree claims.  Also protect worktrees named by structured tool calls in those live
  sessions, because the session cwd may remain in the primary checkout.
- Fail closed when a live claim exists but its cwd or transcript cannot be mapped.
- Re-scan session claims immediately before removal.
- Keep a mapped worktree for 48 hours after recent Claude transcript activity or Codex
  update/archive time, so releasing a live lock cannot make an old checkout immediately
  removable; expose live claims and these leases through a read-only `--claims` diagnostic.
- Add a shared SessionEnd hook entrypoint for Claude and Codex.
- Install a six-hour LaunchAgent sweep.  Scheduled deletion is controlled by the cc-reaper
  config, not by Claude `settings.json`; the installed policy opts in after the same content,
  holder, landing, git-state, and idle gates pass.
- Discover repositories owned by either harness in addition to ordinary source roots, so a
  second harness clone is not invisible.
- Keep hook integration thin: project/global hook configuration invokes the deployed
  cc-reaper entrypoint and carries no cleanup policy.

# Capabilities

## Modified Capabilities

- `worktree-janitor`: shared Claude/Codex live claims and bounded recent-session leases,
  read-only claim diagnostics, 48-hour defaults, scheduled apply, harness repository
  discovery, and a harness-neutral SessionEnd entrypoint.

# Impact

- `shell/worktree-janitor.sh`: policy and active-session detection.
- `hooks/worktree-session-end.sh`: common fast hook entrypoint.
- `config/worktree-janitor.conf`: cross-device policy source.
- `launchd/com.cc-reaper.worktree-janitor.plist`: six-hour guarantee layer.
- `install.sh`: deploys the configuration, entrypoint, and LaunchAgent without storing the
  policy in Claude settings.
- `tests/worktree-janitor.sh` and installer tests: regression coverage.
