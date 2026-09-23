# Host-side storage reclaim that actually runs

## Why

The storage takeover of 2026-09-23 found four paths that were deployed, passed their own
tests, and never did their job on the host they were built for:

- The scheduled worktree janitor runs under launchd's `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
  `gh` is installed in `/opt/homebrew/bin`, so `landed=pr` had never once succeeded in a
  scheduled sweep: 0 in the scheduled log against 54 in session sweeps. Session sweeps cover
  only the repository a session stood in, so a squash-merged worktree anywhere else stays
  "unlanded" forever.
- A sweep that finds another live sweep holding the repository lock exits non-zero, so the
  session log's `status=1` lines (14 of them) mostly record a concurrent sweep doing the work.
- Builder-cache pruning needs a drain proof that nothing produces, and refuses while any
  `ci-runner-*` container exists, which is always. `lifecycle-reclaim.sh` was never called:
  CI runners are ephemeral containers without `~/.cc-reaper`, and on 2026-09-23 the founder
  decided not to wire CI or workflows into it.
- The only growth monitor was an LLM heartbeat aimed at the wrong thread, which never ran.
  Nothing deterministic flags a sudden drop in free space.

## What Changes

- worktree-janitor, when executed, appends the tool directories disk-janitor already appends,
  and says once per run when `gh` still does not resolve.
- A sweep that defers to a live concurrent sweep logs the deferral and does not fail the run.
- `disk-janitor --clean` prunes Docker builder cache the daemon reports unused for at least
  168 hours. `--orbstack-clean`, the drain proof and the protected-container filters go away.
- `hooks/lifecycle-reclaim.sh`, its installer entry, docs and tests go away; the installer
  deletes a previously deployed copy.
- resource-watch marks a free-space drop of at least `CC_RW_DISK_DROP_GB` (default 10) against
  a sample 25 to 45 minutes old with `ALERT:disk-drop` and a cooldown-gated notification.

## Supersedes

- `lifecycle-adapters`, unarchived: withdrawn in full, and its code is removed here.
- The `disk-janitor` spec's "OrbStack builder cleanup requires runner drain proof", which sat
  outside `## Requirements` and so was never parsed; it is deleted with the Purpose line that
  described it.
- The "no `prune` verb" rule pending in `janitors-that-can-see` and the drained-builder
  scenario pending in `coexist-with-dev-workflow`. Both deltas now allow exactly
  `docker builder prune --force --filter until=168h`. The rule existed because
  `docker system prune -af` removes tagged images that take hours to rebuild; builder cache
  rebuilds on next use, and this command touches nothing else.
- The `worktree-janitor` "Concurrent sweeps" scenario's non-zero exit on a live holder.

## Non-goals

No CI or workflow integration. No change to the worktree removal gates (content, holder,
claim, lease, landed, idle, git state). No volume, image or container removal. No LaunchAgent
change.

## Capabilities

- `disk-janitor`
- `worktree-janitor`
- `resource-watch`
