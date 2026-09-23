# Design

## Why sampling is rotated and budgeted

Measured 2026-09-23 on the reporting host: `du -sk` of one 91 GB worktree root at background
I/O priority ran for more than six minutes, and `docker system df -v` took more than two
minutes. A watch that walked every target every hour would cost more than the growth it
reports. So each key carries its own last-sampled time, a run measures only keys older than
the interval (six hours by default), oldest first, and stops starting measurements when its
budget is spent. A key never measured sorts first. A backlog, such as the first run, drains
over several hourly runs instead of one long one.

## Why glob targets are split into keys

Growth inside a worktree root or a scratchpad root is caused by one member: a single session
that exports hundreds of trees, a single worktree whose build output balloons. Sampling each
matched directory as its own key makes the alert name that member. The label total is the
sum of the members' latest samples, recorded only when every current member has a numeric
sample, so a member not yet measured cannot read as a fall and a member that disappeared
drops out instead of reading as a fall either.

## Baseline choice

Growth is `now - baseline`, where the baseline is the newest sample at least 24 hours old
(`CC_DJ_GROWTH_WINDOW_HOURS`), or, before a day of history exists, the oldest sample at
least three hours old. A key compared across less than three hours is too noisy to alert
on; a key whose baseline or current sample is a status carries no growth.

## Status values are not sizes

`denied` (a TCC-protected path under launchd), `absent`, `timeout` and `error` are recorded
as such. Zero would read as a fall followed by a rise, and a silent zero is how a monitor
reports success while seeing nothing.

## Owner labels

Each target row carries a free-text owner. The watch does not interpret it; it prints it on
the alert so the reader starts from the component that produces the growth - a CI volume,
a hook's scratchpad, a reclaimer's worktree root - rather than from a path.

## Python, not awk

Glob expansion, per-key timeouts, Docker's JSON and time arithmetic across keys are each a
few lines of Python's standard library and a page of shell. `python3` is already a counted
dependency of the volume report; without it the step logs a `SKIP` and counts it.
