## Why

cc-reaper's three scheduled janitors all ran on time this month. The machine still
filled to 84% and a runaway process held a core at 99% for 35 minutes. Each janitor
failed in the same shape: it could not see the thing it exists to act on, and reported
success anyway.

**disk-janitor cleans nothing that matters, because launchd's PATH hides its tools.**
`launchctl getenv PATH` is empty, so a LaunchAgent inherits `/usr/bin:/bin:/usr/sbin:/sbin`.
None of the five plists set `EnvironmentVariables`. Every high-yield target lives outside
that list. From this host's own log, the weekly clean of 2026-08-30 04:08:

```
SKIP go clean -cache (go not found)          # /opt/homebrew/bin/go
SKIP yarn cache clean (yarn not found)       # /usr/local/bin/yarn
SKIP brew cleanup -s (brew not found)        # /opt/homebrew/bin/brew
SKIP bun pm cache rm (bun not found)         # /opt/homebrew/bin/bun
SKIP docker system prune (docker not found)  # /usr/local/bin/docker
clean: finished — disk free=16%
```

Five of nine targets skipped. The go build cache alone was 21 GB that morning. What the
run did delete was 0.3 GB of Spotify cache, and it logged `clean: finished` either way.

The diagnosis in the log is also wrong in a way that costs an operator the afternoon:
`(go not found)` states the tool is not installed. It is installed. A message that names
the wrong cause is worse than no message, because it closes the investigation.

**Nothing measures what a target freed.** `_cc_dj_clean_target` logs `done (freed=?)` for
every target, so a target that freed 21 GB and a target that did nothing produce the same
line. That is why five skipped targets survived weeks of weekly runs unnoticed. The spec
already requires per-target freed bytes; the implementation never did it.

**`docker system prune -af` is a mine that PATH happened to defuse.** It sits inside a
requirement titled *rebuildable-only cleanup targets*, and `-af` removes every image not
currently held by a container. On this host that is two 9.5 GB images that take about 1.5
hours to rebuild, and four pinned qdrant versions. "Rebuildable" is doing no work in that
sentence. Fixing PATH without removing this would arm it on the next Sunday at 04:00 —
the fix and the removal cannot be separated.

**worktree-janitor has no LaunchAgent at all.** It exists, it defaults to scanning
`~/Documents/GitHub`, and it is the only piece of tooling here that crosses repositories —
the reclaim hook derives its root from the session's working directory, so it only ever
sweeps the repository someone happened to be sitting in. 83 live worktrees accumulated in
one repository while a working cross-repo janitor sat unscheduled on disk.

**cc-monitor can see a runaway, but may only call it one if it is already protected.**
The first reading of this — that detection is orphan-first and a process with a live parent
is invisible — is wrong, and the fixture built to prove it passed against the unfixed
source. `_cc_monitor_is_detached_or_orphan` accepts a controlling terminal of `??`, which
today's process had, and the row was reported all along.

What it was reported as is the defect. The runaway test sits inside
`if _cc_monitor_is_protected_cmd`, so a process can be identified as a runaway only if it
already appears on the protection list — and the processes that actually run away are the
ones nobody listed. Measured today, replayed through the report: a Python process at 99%
CPU for 51 minutes under a live session, classified `family=other`, where the same row
after the fix is `family=runaway`. Its loop was
`for c in iter(lambda: gzip.open(p,'rb').read(), b'')`; the lambda reopens the file on every
call and can never return the sentinel, so it could not have terminated.

Runaway is a claim about behaviour. Protection is a claim about identity, and it belongs on
what may be done about a process, not on whether the process may be named.

The 60-minute floor compounds it: nothing can be called a runaway during its first hour,
which is most of the window in which noticing is worth anything.

## What Changes

- disk-janitor prepends the known tool directories to `PATH` before resolving anything, so
  a LaunchAgent and an interactive shell resolve the same tools.
- A target whose tool does not resolve is reported by absence *and* counted. The run
  summary names how many targets ran and how many were skipped, so a run that skipped most
  of its work cannot end on a line that reads like success.
- Each target's freed bytes are measured from free-space deltas rather than logged as `?`.
- `docker system prune -af` is replaced by removal of dangling images and of anonymous
  volumes no container references, each named explicitly. No `prune` verb remains.
- worktree-janitor stays manual, and the installer now says why rather than leaving the
  absence to read as an oversight. A LaunchAgent cannot read `~/Documents` — measured with
  a probe agent on 2026-08-30: `ls ~/Documents/GitHub` returned `DENIED`, and `git rev-parse`
  in a repository there returned `Operation not permitted` — and `_cc_wj_root` defaults to
  `$HOME/Documents/GitHub`, so a schedule would traverse nothing and report nothing. A
  silent empty report is the failure shape this change exists to remove, so shipping one
  would have been worse than shipping nothing.
- Report mode stops running a prune. Removing administrative records is a removal, and this
  tool's own contract is that removal needs `--apply`.
- cc-monitor's existing sustained-CPU test moves out of the protected-command branch, so any
  process can be identified as a runaway. Classification stays `ASK_BEFORE_KILL` and this
  path still kills nothing: a live session's child at 100% CPU may be a legitimate long build.
- The reporting floor drops from 60 minutes to 30. The killing path is a different
  implementation — `_cc_guard_runaway_protected_pids` in `claude-cleanup.sh`, which the guard
  agent drives — with its own 60-minute default and its own whitelist, and it is untouched.
  The set of processes that can be signalled does not change.
- The report's section heading and reason text stop saying "protected", which stopped being
  true of what they list.

Not in scope: `docker builder prune` (a `prune` verb, and 566 MB on this host); migrating
repositories from npm to pnpm; any change to the reclaim hook's removal criteria.

## Capabilities

### Modified Capabilities

- `disk-janitor`: tool resolution stops depending on the caller's environment; skips and
  freed bytes become observable; docker cleanup stops being able to delete expensive images.
- `worktree-janitor`: report mode stops mutating the repository; the cross-repository gap
  it was meant to close is recorded as still open, with the measurement that closes off the
  scheduled approach.
- `cc-monitor`: runaway identification stops requiring the process to be on the protection list; the reporting floor drops to 30 minutes while the reaper keeps 60.

## Impact

- `shell/disk-janitor.sh`: PATH prelude, `_cc_dj_clean_target` measurement and skip
  accounting, docker target rewritten.
- `shell/cc-monitor.sh`: one additional check.
- `install.sh`: states that the worktree inventory is manual, and why.
- Behavior: the weekly clean starts actually deleting the caches it always claimed to; it
  stops being able to delete docker images; the worktree report stops pruning; no new agent.
