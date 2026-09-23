# Design

## Builder cache: the property the drain proof protected, carried across

The drain proof existed so that a running build would not lose cache it was using. The
daemon already guarantees that: BuildKit prunes only records with no active reference, and
`until=168h` is the daemon's unused-for duration (`unused-for` is its deprecated synonym), so
anything used within the last week stays. The proof added nothing a producer ever supplied,
and the `ci-runner-*` gate made the path unreachable on the one host that needed it.

The command keeps its reviewed shape, `docker builder prune --force --filter until=168h`,
without `--all`, which prunes only dangling unused records, the narrower of the two sets.
Widening to `--all` is a follow-up if the weekly log shows too little reclaimed. It runs in
the weekly `--clean`, the agent that already owns rebuildable caches, not in the hourly
read-only check.

## Tool directories: appended, and only when executed

Same rule as disk-janitor: appended, never prepended, so a caller's toolchain and a test's
stubs keep priority. worktree-janitor is sourced by its tests and from zsh, so the append
happens at the executed entry point and a sourcing shell's PATH is untouched. The session
hook re-executes the script, so session sweeps get it too.

## A deferral is not a failure

Only apply sweeps take the lock, so a live holder is sweeping the same repository behind the
same gates. Exiting non-zero for that made launchd and the session log report a failure that
had not happened, and buried the real ones. Base-preparation failures, a lock that cannot be
taken, denied roots and activity blindness still fail the run.

## Drop alert: a sample file, not the human log

The log's timestamps are local time, and macOS awk has no `mktime`. A state file of
`<epoch> <free GB>` lines, trimmed to the last 12 (two hours at the ten-minute cadence), is
simple to read and to test. The 25 to 45 minute window absorbs launchd jitter. After sleep
there is no comparable sample, so nothing is compared and nothing false is raised.
