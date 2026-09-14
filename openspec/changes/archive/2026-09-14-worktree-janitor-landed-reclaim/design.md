## Decisions

### Session mode reports unless opted in
`--session` runs at every session end without anyone reading its output. The main spec says
an unattended invocation never removes, and that property is what lets a user install the
hook without first auditing every repository they open. Removal is one environment variable
away (`CC_WJ_SESSION_APPLY=1`); any other value reports and says it was not `1`, so `true` or
`yes` cannot be mistaken for consent in either direction.

### Landed is required even though the branch survives
Before this change removal was justified by "the branch keeps the commits". That protects the
commits and not the person: an unlanded worktree is the checkout somebody is working in, and
the gates that would show it unused (cwd, age) are exactly the ones a remote-driven session
defeats. Landed is the one fact that makes "nobody needs this checkout" likely rather than
merely possible.

### The base is fetched in report mode
A report computed against a stale tracking ref is wrong in the dangerous direction (a unique
HEAD looks landed when the base was force-pushed) and the useless one (everything merged
since the last fetch looks unlanded). The fetch writes only
`refs/remotes/origin/<base>` through an explicit refspec, so a custom `remote.origin.fetch`
cannot redirect it. `git worktree prune` stays gated on `--apply`; a tracking-ref update is
not a removal.

### Scan failure keeps, everywhere
Every probe distinguishes "ran and found nothing" from "did not run": an lsof that fails or
returns no lines (a live system always has at least this shell's cwd), a `find` that exits
non-zero, a `git status` that fails, a `merge-tree` git is too old for, a `gh` that is absent
or times out. Each keeps the worktree with a reason naming the probe.

### Timeouts belong to a process group
`gh` (Go) ignores `SIGALRM` and `lsof` resets its own alarms, so `alarm; exec` bounds neither.
The bounded command runs in its own process group while perl keeps the clock, then TERM and
KILL go to the group. Without perl the command runs unbounded, which only matters detached.

### Fork before setsid
The detached sweep must never be observable as an orphan still inside the session's process
group, because `stop-cleanup-orphans.sh` runs beside it at session end and kills exactly that.
perl forks in the foreground, the child calls `setsid()` and only then releases the parent.
