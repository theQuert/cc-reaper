# Design

## Worktree preservation

`--trim-regenerable` is separate from `--apply` worktree deletion. It never calls
`git worktree remove`, `git worktree prune`, or branch deletion. The candidate list comes from
`git status --porcelain --ignored -z`, so only ignored directories whose basename is in the
janitor's built-in regenerable set can be selected. Symlinks are excluded.

The mode does not require a branch to have landed: preserving the checkout makes this useful for
old or abandoned branches without destroying their authored state. It still refuses a worktree
whose git state is unknown or locked, and status failure is a keep result.

## Active-session boundary

The normal run takes one holder and harness activity snapshot. Before a trim pass starts, the
candidate is rejected when a process cwd or open file, verified live Claude/Codex claim, or
recent-session lease names it. In apply mode, the holder and activity snapshots are rebuilt before
each selected directory is removed. A new claim therefore leaves every remaining directory alone.

Credential-shaped files inside a selected cache veto that cache, using the existing shallow cache
credential probe. This avoids deleting a package tree that has become a secret transport while
not treating ordinary package certificate bundles as authored data.

## Observability

Report mode prints each `TRIM_CANDIDATE`, the byte estimate, and a dry-run summary. Apply mode
prints the actual trimmed count and bytes. A failed recheck prints a keep reason and contributes no
bytes to the result.

`disk-janitor --clean` invokes the apply mode only when the measured data-volume free percentage
is below `CC_DJ_DISK_MIN_PCT`. The target can be disabled with `CC_DJ_TRIM_WORKTREES=0`; a missing
installed worktree janitor is counted as skipped rather than reported as a successful cleanup.

## Monitor parsing

`etime_to_seconds` normalizes every non-empty day/hour/minute/second field through `10#` before
arithmetic. Empty optional fields remain zero, so `3`, `09:07`, `09:07:51`, and `1-09:07:51`
retain their existing shapes without octal interpretation.
