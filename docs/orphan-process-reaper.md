# Orphan process reaper

`shell/orphan-process-reaper.py`, run hourly by `disk-janitor.sh --check` beside the dev-server reaper
(stima-api#9007). It stops two things and nothing else.

Why it exists: on 2026-11-18 the Mac mini ran at 0% CPU with a 5-minute load of 98 to 127. A read-only
inventory found dev servers, proxies and `until` shells whose Claude Code session was dead, and 23 Bash-tool
shells of one live session stuck in wait loops (two with no `sleep`, 22 hours and 2 days old). No existing
reaper could reach them: the monitor matches `claude ... stream-json`, `dev-server-reaper.py` judges launchers
by argv[0] inside a linked worktree, `session-reaper.py` closes tmux panes and skips `kind:bg`.

## What it stops

1. **A process tree reparented to launchd whose owning session is dead.**
   - Owner, in this order: `CLAUDE_CODE_SESSION_ID` in the environment of any process in the tree (one
     `ps eww -axo pid=,command=` for the host; only that one key is kept, no environment value is printed or
     logged), then a `/tmp/claude-<uid>/<project>/<session id>/` path in the root's command line or working
     directory, then the `claude-task-worktree` marker of the root's linked worktree. The marker names the
     creator, a weaker owner: a live claim on the worktree (`worktree-janitor.sh --claims`) keeps the tree.
   - Dead means all of: no live pid in `~/.claude/sessions/*.json`; no live `pid` or `replPid` in the
     daemon roster `~/.claude/daemon/roster.json` (a hosted session is live while either is); not in the
     fresh session state file; the host has a record of the id (a transcript under `~/.claude/projects` or a
     job directory) and its transcript was not written in the last hour.
   - Several owners in one tree: it goes only when every one is dead.
   - Unknown owner, an id the host has no record of, an unreadable registry, roster or probe: kept, logged
     `KEEP(unknown-owner)` (or the probe's own reason). An unreadable registry or roster ends the run without
     a decision.
2. **A live session's own Bash-tool shell that waits.** The command contains
   `shell-snapshots/snapshot-zsh-`, its parent is that session's claude process, and it is an
   `until`/`while` ... `done` loop older than `CC_DJ_ORPHAN_PROC_LOOP_HOURS` (6); or the loop body runs
   nothing (`do :; done`, `do true`) and it is older than `CC_DJ_ORPHAN_PROC_SPIN_MINUTES` (10). The 6 hour
   bound sits above `gh run watch` and a 30-minute suite; the first Mac mini report run (2026-11-19) listed 22
   such shells of one session, 25 to 37 hours old, every one an `until grep ... ; do sleep N; done` on a file or
   process that never appeared. A loop whose shell has a descendant older than 10 minutes other than `sleep` or `tail`
(or one whose start time cannot be read) has already ended and the shell runs something: `KEEP(long-child)`. A
tool shell holding a live lease or listening with a connection is kept like a tree of rule 1 (`KEEP(lease)`,
`KEEP(serving)`), spin loops included.

## What it never stops

Kept even when the owner cannot be resolved: the tmux server; any launchd job whose label starts with
`tech.stima.` or `com.cc-reaper.` (the `ci-runner-macos` and `gce-jit-broker` families, `run-loop.sh`,
`Runner.Listener`); docker and OrbStack; a `claude daemon`, `bg-pty-host` or `bg-spare`; a pid the
registry or roster lists as live; any claude or codex process in the tree; a tree whose pid owns a live
`with_local_resource.py` lease (its `owner_pid` alive, not past its `ttl`); a tree that listens on a port something
is connected to (`KEEP(serving)`); a never-kill pid (`CC_NEVER_KILL_PIDS`) and its descendants; the
reaper's own process tree.

## Stopping

SIGTERM to every process of the tree, children first, each only while its start time still matches the scan
(right before the signal the tree is read again: the root must be unchanged and no protected process may have joined it); `grace` seconds (10) later it
lists the survivors as `SURVIVOR pid=...`. There is no SIGKILL: a survivor is for a person, or a later
version.

## Switch and log

`CC_DJ_ORPHAN_PROC_REAP=off|report|apply` (default `report`) in `config/disk-janitor.conf`, with the two age
bounds `CC_DJ_ORPHAN_PROC_LOOP_HOURS` and `CC_DJ_ORPHAN_PROC_SPIN_MINUTES`. Each decision is one line in
`~/.cc-reaper/logs/disk-janitor.log`, prefixed `orphan processes:`:

```
CANDIDATE pid=48381 owner=147badd3 cmd='...' (its session ended; 1 processes)    # report
STOPPED   pid=... owner=... cmd='...' (...)                                        # apply
KEEP(owner-live|owner-recent|owner-claimed|unknown-owner|lease|serving|protected: ...) pid=...
SURVIVOR  pid=... (still running 10s after SIGTERM; not killed)
orphan processes: stopped=0/25 kept=18 (report only)                               # one summary per run
```

Command lines are logged cut to 100 characters with `token|key|secret|password=` values masked, and the
session id as its first 8 characters. A failure of the reaper is logged and never fails the janitor.

Rollout (SCRIPT-SAFE-RULE): ships in `report`; after five clean scheduled runs, spot-checked against the
process table, the host's `disk-janitor.conf` sets `apply`. Rollback is `CC_DJ_ORPHAN_PROC_REAP=off`.

Tests: `tests/orphan-process-reaper.sh` (fixture `ps`, `lsof`, `launchctl` on PATH, a recording `kill`, a
sandbox HOME) and the `--check` contract in `tests/disk-janitor.sh`.
