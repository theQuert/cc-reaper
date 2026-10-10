# Reap finished Claude Code sessions in tmux

## Why

Interactive Claude Code sessions run in tmux on a shared host and are never closed when their
work ends. On 2026-10-10 one host had 17 such sessions, several idle for 12 to 22 hours; nobody
could tell from `tmux ls` who was still working, and each idle session holds memory and
processes. Closing them by hand depends on someone remembering, and the hand-written record of
one such sweep already disagreed with what was still running.

## What Changes

- `shell/session-reaper.py` and the LaunchAgent `com.cc-reaper.session-reaper` (every 30 minutes,
  no model calls). Report-only unless the deployed config sets `APPLY=1`.
- A session is reaped only when every gate holds: idle for `IDLE_MINUTES`, no background shell,
  loop or scheduled task, done (a `SESSION-DONE:` line, an explicit topic-end phrase, or every
  claimed issue closed), its worktrees clean and pushed, not waiting on a person, not protected.
- Reaping types `/exit` at a verified empty prompt; if the background-task menu appears it
  selects Stay and skips the session. The tmux session is killed only after claude has exited.
- Every reap is verified: the snapshotted process tree, the tmux session and the session file
  are gone, and no worktree is locked. A failure notifies, comments on a tracking issue, and
  exits non-zero.
- No Stop hook: the session file and transcript give the sweep every signal a hook could mark.

## Impact

- New: `shell/session-reaper.py`, `tests/session-reaper.py`,
  `launchd/com.cc-reaper.session-reaper.plist`, `config/session-reaper.conf`; README, CHANGELOG.
- Installed by hand on the one host that runs tmux sessions, like the WIP backup; `install.sh`
  is unchanged.
