# Design

## One policy owner

`~/.cc-reaper/worktree-janitor.conf` owns the idle window and unattended-apply switches.
Both harnesses invoke `~/.cc-reaper/worktree-session-end.sh`; that script identifies the
harness for logging and delegates to the same deployed janitor.  No deletion criterion is
duplicated in Claude or Codex configuration.

## Activity proof

The holder scan remains necessary but is not sufficient.  Before classification the
janitor builds a snapshot from:

- live PID-named Claude session records whose process command still contains the recorded
  session id, plus that session's unique transcript;
- Codex thread writer-lock files that are actually open, mapped to cwd and rollout path by
  the Codex state database.

Only structured tool-call inputs from the current two human user turns of verified-live
transcripts count. The two-turn window covers a follow-up arriving before its first tool call
without letting a long-lived session pin every worktree it ever touched. User prose, older
turns, historical transcripts, and merely existing stale lock files do not pin a worktree. An
unreadable or ambiguous live record makes the destructive run fail closed.  The snapshot
is rebuilt immediately before removal to close the session-start race. The cleanup task's
own tool-call mentions are excluded because inventory names its targets; its verified cwd
claim still protects the checkout it actually uses.

The current-two-turn window is indexed once per transcript and activity snapshot. The first
candidate query decodes that window and writes a normalized, NUL-delimited search projection
inside the run's private temporary directory; later candidates use fixed-string matching
instead of starting another Python interpreter. A malformed canonical tool record, or a
malformed slash-bearing record that might name a path, bypasses the projection and retains
the exact target-specific parser's fail-closed behavior. A pre-removal refresh starts a new
snapshot so these files optimize repeated reads, not permission to rely on stale activity.
Scheduled sweeps also retain an offset-only index under cc-reaper state. Reuse requires the
same transcript path, device, inode, size, and nanosecond modification time; a changed file
is reread before its evidence can participate in a destructive decision. The persistent
index and per-run offset file contain byte ranges and file identity only, never transcript
records or tool-call content. Only the ephemeral search projection contains normalized tool
input text, and it is discarded with the private run directory.
Installed bash runs register signal and exit cleanup immediately after that directory is
created, before any projection is written. Projection encoding uses surrogate escapes so a
non-UTF-8 filesystem byte remains the same byte the shell passes to fixed-string matching.
Unsupported lone surrogates mark the projection unsafe and retain exact parsing. The shell fast
path validates an exact mode/path/device/inode/size/mtime identity rather than trusting its
checksum filename, and any projection lookup error fails closed. Signal cleanup runs the
caller-owned signal action without resuming the interrupted body, then exits through the caller's
existing EXIT cleanup.
Because launchd may escalate past shell traps, each run also records its owner PID and scavenges
dead-owner private directories on the next start; unmarked directories receive a five-minute
creation grace so concurrent starts cannot remove one between `mktemp` and owner registration.
Scavenging precedes every argument/config/discovery early return, and sourced/background runs
derive the OS process actually executing the function instead of trusting Bash 3.2's inherited
`$$` value.
If a Codex writer lock closes while its captured rollout is being read, the janitor remaps
that task through current Codex state. An archived task becomes bounded recent-session
evidence for only its mapped cwd and structured tool paths; the expected rollout move does
not turn into an active claim on every unrelated worktree.

Attached-resource reapers use the read-only `--landed PATH` query. This lets a local stack
stop before the process-holder gate without duplicating, or weakening to ancestry-only,
the worktree janitor's content-equivalence and exact-head PR proofs.

The Codex database is a private implementation surface.  The adapter is intentionally
small, paths are configurable for tests, and schema/read failures keep worktrees rather
than authorizing deletion.

Releasing a live claim does not erase recent intent. A second, bounded session lease uses
Codex `max(updated_at, archived_at)` and Claude transcript mtime plus its last recorded cwd.
The default lease is 48 hours. It is independent of file idleness, so archiving a task whose
worktree files were already old cannot make that worktree immediately removable. Recent
transcripts use the same current-two-user-turn structured-tool-call matcher as live claims,
covering a task whose DB cwd stayed in the primary checkout while tools operated a linked
worktree. The lease expires instead of permanently treating archived/notLoaded tasks as active.

`--claims` reads only these registries and prints live claims plus recent leases with ids,
paths, state, age, and remaining grace. Ordinary inventory names the winning lease as
`KEEP(recent-session)`, giving operators and tests the same evidence the remover uses.

## Trigger and guarantee layers

SessionEnd is the best-effort low-latency trigger. App archive may release a task without
dispatching that repository hook. The LaunchAgent is the guarantee layer and runs every
six hours by default plus at load.  The installer accepts a bounded interval override
from 300 through 604800 seconds and writes that value into the installed plist; the source
template remains a valid six-hour plist. The scheduled command uses `--scheduled`; only
`CC_WJ_SCHEDULE_APPLY=1` turns that invocation into `--apply`.  The installed config sets
that switch and `CC_WJ_SESSION_APPLY=1`, while a missing config remains report-only.

Repository discovery keeps the existing top-level source roots and additionally searches
the shallow harness worktree roots.  Repositories are deduplicated by their absolute git
common directory before a sweep.

Claude and Codex retain ownership of lifecycle dispatch. cc-reaper owns the portable
`Stop` process cleanup and `SessionEnd` worktree cleanup implementations. The hook installer
migrates the former Claude-private process-hook path to the turn-level `Stop` event, and
installs both shared commands for explicitly selected Codex repositories.

## Safety invariants

- A scheduled or hook-triggered apply still needs every existing content, holder, landed,
  idle, lock, submodule, and pre-removal recheck gate.
- Branches are never deleted and worktree removal never uses `--force`.
- A malformed config, activity registry, live-claim mapping, transcript, or database keeps
  worktrees and produces a non-zero status for direct/scheduled runs.
- Existing user config is not overwritten by installer updates.
