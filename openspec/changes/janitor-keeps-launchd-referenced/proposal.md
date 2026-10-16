# Keep a worktree that a launchd agent names

## Why

On 2026-10-15 16:08 the janitor, under disk pressure (idle window shrunk to 2 hours), removed a
pushed, idle task worktree that the launchd agent `tech.stima.event-gateway-feed` ran a script
from every 60 seconds (`StartInterval`). Between ticks no process holds the path, so the lsof
holder scan saw nothing and the job then failed about 1,230 times over 16 hours.

## What Changes

- The holder scan also counts every absolute path string in the launchd agent plists of the
  directories in `CC_WJ_LAUNCHD_DIRS` (colon-separated; default `~/Library/LaunchAgents`; empty
  disables). A worktree at or under such a path is held, with the existing `active-session`
  keep reason.
- A plist that cannot be read names nothing. The scan only gains holders, so it never fails
  or frees a worktree because of a plist.
