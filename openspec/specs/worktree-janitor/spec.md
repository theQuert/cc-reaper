# worktree-janitor Specification

## Purpose

Multi-repo git worktree inventory and gated removal shared by Claude and Codex: content,
holder, active-harness, landing, 48-hour idle and git-state gates; direct runs are dry-run by
default, and branches and commits are never deleted.

## Requirements

### Requirement: Multi-repo worktree inventory
The janitor SHALL discover git worktrees from configurable ordinary source roots and from
the Claude and Codex harness worktree roots, deduplicate them by git common directory, and
classify each worktree as KEEP or REMOVABLE with a stated reason.

#### Scenario: Inventory run
- **WHEN** the janitor runs in report mode
- **THEN** every non-primary worktree is listed with: dirty file count, branch, ahead-of-origin/main count, push state, active-process state, and final classification

#### Scenario: Harness-owned second clone
- **WHEN** a harness-owned checkout is not registered under an ordinary source root
- **THEN** it is still present in the report and evaluated by the same gates

### Requirement: Dual safety gate for removal
A worktree SHALL be classified REMOVABLE only when every gate below holds, and each gate
that cannot be evaluated SHALL keep the worktree with a reason naming the gate. Branches and
commits are never deleted - only the working directory.

1. **Contents:** `git status --porcelain --ignored` succeeds and every entry is discounted as
   regenerable (built-in cache lists, or the repository's `.worktree-regenerable`).
2. **Holders:** machine-wide scans of every process's working directory and of every open
   file both succeed and name nothing at or under the worktree.
3. **Harness claims:** no verified-live Claude session or open Codex writer lock claims the
   worktree by cwd or by a structured tool-call input in its current two human user turns,
   and no Claude/Codex session activity mapped to that worktree falls within
   `CC_WJ_SESSION_GRACE_HOURS` (48 by default).
4. **Landed:** against a base branch fetched during this run, HEAD is an ancestor, or merging
   HEAD into the base produces the base's own tree, or a merged pull request whose head is
   HEAD and whose base is the base branch has a merge commit contained in the fetched base.
5. **Idle:** nothing under the worktree - followed through a symlinked worktree path - and
   none of its git administrative files (`HEAD`, `index`, `logs/`) was modified within
   `CC_WJ_IDLE_HOURS` hours (48 by default).
6. **Detached:** a detached HEAD is additionally landed by ancestry.
7. **Not locked, no populated submodule:** `git worktree lock` is an explicit request to keep
   a worktree, and a populated submodule carries state the outer status does not show.

#### Scenario: Dirty worktree
- **WHEN** a worktree has any uncommitted, untracked, or undiscounted ignored entry
- **THEN** it is classified KEEP with reason `unrebuildable=<n>`, and the report names up to three of those entries with their porcelain codes

#### Scenario: Worktree status scan reaches its bound
- **WHEN** `git status --ignored` does not finish within the positive configurable per-worktree timeout
- **THEN** the janitor terminates that status process group, keeps the worktree with a timeout reason, and continues examining later worktrees

#### Scenario: Active session in clean worktree
- **WHEN** any process's cwd resolves at or under the worktree
- **THEN** it is classified KEEP with reason `active-session`

#### Scenario: A process holds a file open inside the worktree
- **WHEN** no process's cwd is inside the worktree but a process holds a file under it open
- **THEN** it is classified KEEP with reason `active-session`

#### Scenario: Active Claude or Codex claim
- **WHEN** a verified-live Claude session or open Codex writer lock maps to the worktree by cwd, or its structured tool calls name the worktree
- **THEN** it is classified KEEP with a reason that identifies the harness and claim

#### Scenario: Codex state row lags a live writer lock
- **WHEN** an open Codex writer lock has no task row yet but exactly one active rollout has a matching session id and an absolute cwd in its `session_meta`
- **THEN** the rollout maps the live claim without waiting for an unbounded state update, and the worktree is classified KEEP
- **AND** a missing, duplicate, unreadable, mismatched, or unsafe rollout makes the activity scan fail closed and removes nothing

#### Scenario: Stale registry artifact
- **WHEN** a Claude PID record is dead or reused, or a Codex lock file exists but is not open
- **THEN** that artifact alone does not claim a worktree

#### Scenario: Archived Codex task
- **WHEN** the app archives a Codex task without dispatching SessionEnd and its writer lock is no longer open
- **THEN** its `archived_at` or later activity starts a recent-session lease, and the worktree is `KEEP(recent-session)` for the configured grace period

#### Scenario: Archived task after old worktree activity
- **WHEN** a worktree's files have been idle longer than 48 hours but a mapped task was archived less than `CC_WJ_SESSION_GRACE_HOURS` ago
- **THEN** the recent-session lease keeps the worktree even though its file-idle gate already holds

#### Scenario: Many recent Codex tasks
- **WHEN** the local Codex state contains many tasks inside the grace window
- **THEN** the janitor evaluates their transcript claims by most recent activity first without dropping any task from the safety scan

#### Scenario: Recent Claude transcript
- **WHEN** a non-live Claude transcript was updated within the session grace window and its last recorded cwd maps to the worktree
- **THEN** the worktree is `KEEP(recent-session)` until that transcript activity ages past the grace window

#### Scenario: Recent session used another tool workdir
- **WHEN** a recent inactive Claude or Codex session cwd is outside the worktree but a structured tool call in its current two human user turns names the worktree
- **THEN** the same recent-session lease keeps that worktree and reports `scope=structured-tool-call`

#### Scenario: Session grace expires
- **WHEN** no live claim exists and every mapped session activity is older than `CC_WJ_SESSION_GRACE_HOURS`
- **THEN** session history does not keep the worktree, and every other removal gate still applies

#### Scenario: Session grace malformed
- **WHEN** `CC_WJ_SESSION_GRACE_HOURS` is not a whole number below 100000
- **THEN** the run exits non-zero before classifying anything and removes nothing

### Requirement: Observable harness claims
The janitor SHALL expose a read-only `--claims` diagnostic and SHALL include the winning
session claim or lease in ordinary inventory output without reading transcript message text
into the report.

#### Scenario: Inspect claims after archive
- **WHEN** an operator runs `worktree-janitor --claims` after a Codex task was archived
- **THEN** the output identifies its harness, session id, cwd, archived status, last-activity time, age, and remaining grace

#### Scenario: Inspect claims by worktree path
- **WHEN** an operator runs `worktree-janitor --claims PATH`
- **THEN** direct cwd claims and structured tool claims in the current two human user turns that name PATH are printed without transcript message text

#### Scenario: Inventory explains recent retention
- **WHEN** a recent-session lease keeps a worktree
- **THEN** the inventory prints `KEEP(recent-session)` and the lease that won

#### Scenario: Claims diagnostic is read-only
- **WHEN** `--claims` is run under any apply configuration
- **THEN** it does not fetch, prune, remove a worktree, or change harness state

#### Scenario: Live claim cannot be mapped
- **WHEN** a verified-live claim cannot be parsed or mapped uniquely to cwd and transcript
- **THEN** no worktree is removed and the run exits non-zero

#### Scenario: Harness claim appears before removal
- **WHEN** a claim appears after classification but before removal
- **THEN** the pre-removal claim refresh keeps the worktree

#### Scenario: A path the holder scan escapes
- **WHEN** lsof prints a name with its own escaping (`\xNN` for a byte it will not print, `\\` for a backslash)
- **THEN** the scan decodes those escapes before matching, in every locale, so a held worktree whose path contains non-ASCII, invisible or format characters is matched and kept

#### Scenario: A path the holder scan cannot decode
- **WHEN** a worktree's path contains a control character, or contains a byte outside ASCII while the decoder is unavailable
- **THEN** it is classified KEEP with reason `active-session`

#### Scenario: A path the inventory cannot carry
- **WHEN** a worktree's path contains a tab or a newline
- **THEN** it is classified KEEP with reason `unsafe-path` and never removed

#### Scenario: A holder scan cannot run
- **WHEN** `lsof` is absent, fails, or returns no lines for either scan
- **THEN** every worktree is classified KEEP with reason `active-session`

#### Scenario: Recently modified worktree
- **WHEN** a clean, unheld, landed worktree contains a file modified within `CC_WJ_IDLE_HOURS`, or its `HEAD`, `index` or `logs/` changed within it
- **THEN** it is classified KEEP with reason `recent-activity`

#### Scenario: Worktree reached through a symlink
- **WHEN** the path git records for a worktree is a symlink to its directory
- **THEN** the idle test examines the directory the link names

#### Scenario: Idle window malformed
- **WHEN** `CC_WJ_IDLE_HOURS` is not a whole number below 100000
- **THEN** the run exits non-zero before classifying anything and removes nothing

#### Scenario: Unlanded branch
- **WHEN** a clean, unheld, idle worktree's HEAD satisfies none of the three landed proofs
- **THEN** it is classified KEEP with reason `unlanded`

#### Scenario: Squash-merged branch
- **WHEN** a branch's change reached the base as a different commit and merging HEAD into the base changes nothing
- **THEN** the landed gate holds by content

#### Scenario: Merged pull request whose content later changed on the base
- **WHEN** content and ancestry both fail, and `gh` reports a merged PR with this exact head SHA into the base branch whose merge commit is on the fetched base
- **THEN** the landed gate holds by PR; a PR for the same branch name at a different head SHA SHALL NOT count

#### Scenario: Base cannot be fetched
- **WHEN** the repository has no `origin`, its default branch cannot be resolved, or the fetch fails or times out
- **THEN** the run says so once for the repository and every worktree in it is classified KEEP with reason `base-unfetched`

#### Scenario: Low-priority base fetch needs more than one minute
- **WHEN** the scheduled agent's base fetch exceeds one minute but completes within the positive configurable fetch budget
- **THEN** the fetched base is used normally instead of permanently disabling reclamation for that repository

#### Scenario: Detached HEAD landed by content only
- **WHEN** a detached HEAD is landed by content or PR but not by ancestry
- **THEN** it is classified KEEP with reason `detached-head`

#### Scenario: Locked worktree
- **WHEN** a worktree's git directory holds a `locked` file - as Claude Code's own agent worktrees do
- **THEN** it is classified KEEP with reason `locked`, whatever the other gates say

#### Scenario: Populated submodule
- **WHEN** a worktree's git directory has a `modules` directory, or a gitlink in its index points at a checked-out path
- **THEN** it is classified KEEP with reason `submodule`

#### Scenario: Git state cannot be read
- **WHEN** the worktree's git directory cannot be resolved or its index cannot be listed
- **THEN** it is classified KEEP with reason `git-state-unknown`

#### Scenario: Changed between the scan and the removal
- **WHEN** a REMOVABLE worktree, immediately before removal, is held, holds undiscounted content, is no longer idle, has a different HEAD, or has become locked or gained a submodule
- **THEN** it is kept and the report says it changed between the scan and the removal

#### Scenario: Clean idle worktree
- **WHEN** every gate holds
- **THEN** it is classified REMOVABLE, the report shows which landed proof held, and removal uses `git worktree remove` without `--force`, followed by `git worktree prune`; a removal git refuses is reported and the worktree kept

### Requirement: Dry-run by default
The janitor SHALL default to report-only mode; deletion SHALL occur only with an explicit
`--apply` flag, in session mode with `CC_WJ_SESSION_APPLY=1` exactly, or in scheduled mode
with `CC_WJ_SCHEDULE_APPLY=1` exactly. Any unattended invocation without its opt-in SHALL
run report mode.

#### Scenario: Default invocation
- **WHEN** the janitor runs with no flags
- **THEN** it prints the classification report and removes nothing; it MAY fetch the base branch into `refs/remotes/origin/<base>`, with git's automatic maintenance disabled so the fetch cannot prune worktree records

#### Scenario: Worktrees cannot be listed
- **WHEN** `git worktree list --porcelain -z` fails for a repository - an unreadable repository, or git older than 2.36
- **THEN** the run names the repository, lists nothing for it, and exits non-zero

#### Scenario: Explicit apply
- **WHEN** the user runs `worktree-janitor --apply`
- **THEN** only REMOVABLE worktrees are removed, each removal is logged, and a summary (removed count, reclaimed bytes, kept count) is printed

#### Scenario: Scheduled run
- **WHEN** the LaunchAgent invokes `--scheduled` at its default six-hour interval or an installer-selected interval from 300 through 604800 seconds
- **THEN** it applies only when `CC_WJ_SCHEDULE_APPLY=1`, otherwise it reports only

#### Scenario: Custom schedule interval
- **WHEN** an operator installs with `CC_REAPER_WORKTREE_INTERVAL_SECONDS` set to a whole number from 300 through 604800
- **THEN** only the installed worktree LaunchAgent uses that interval, and every cleanup safety gate remains unchanged

#### Scenario: Session mode without opt-in
- **WHEN** `--session` runs and `CC_WJ_SESSION_APPLY` is unset or anything other than `1`
- **THEN** it reports only, and names the value when one was set

### Requirement: Repository-declared regenerable content
The janitor SHALL read `.worktree-regenerable` from the fetched base branch - never from the
worktree being judged - and discount ignored entries it declares. One pattern per line,
repository-relative, shell glob in which `*` also matches `/`, `#` comments at line start or
after whitespace, leading and trailing `/` ignored. Negation (`!`) is not supported. A declared directory covers everything below it; an ignored directory
git collapses is discounted when every file inside it (at most 200) is declared.

#### Scenario: Declared byproduct
- **WHEN** a worktree's only undiscounted content is an ignored file matching a declared pattern on the base
- **THEN** the content gate holds

#### Scenario: Declaration only on the branch
- **WHEN** `.worktree-regenerable` exists in the worktree but not on the fetched base
- **THEN** it SHALL NOT discount anything

#### Scenario: Pattern that names no path
- **WHEN** a pattern containing a wildcard lacks two consecutive literal characters (`*`, `*.*`, `a*`), or contains any character other than letters, digits, `.`, `_`, `/`, `+`, `@`, `-`, space, `*` and `?` - a bracket expression (`[!]][!]]*`) or alternation (`(*|ab)`)
- **THEN** it is ignored and the run reports it as dropped

#### Scenario: A declaration file with a negation
- **WHEN** any line of `.worktree-regenerable` starts with `!`
- **THEN** no line of the file is applied, and the run says the file uses an unsupported negation

#### Scenario: Credential inside discounted content
- **WHEN** a declared directory, at any depth outside `node_modules` and `site-packages`, or a built-in cache directory within two levels, holds a credential-shaped file (`.env`, `.env.*` except example/sample/template/dist, `*.pem`, `*.key`, `*.p12`, `*.keystore`, `id_rsa`, `id_ed25519`, `credentials.json`)
- **THEN** that directory is not discounted and the report names it

#### Scenario: Unmatched ignored content
- **WHEN** an ignored entry is neither built-in nor declared
- **THEN** the report names it and says it can be declared in `.worktree-regenerable` on `origin/<base>`

### Requirement: Session mode
`worktree-janitor --session` SHALL return immediately and run the inventory detached for the
repository containing the hook payload cwd, `CODEX_PROJECT_DIR`, `CLAUDE_PROJECT_DIR`, or the
working directory, so that one deployed entrypoint can serve Claude and Codex SessionEnd.

#### Scenario: Detaching
- **WHEN** `--session` is invoked
- **THEN** the invoking process exits 0 without waiting for the sweep, and the sweep runs in a new session whose process group is not the caller's

#### Scenario: Hook input
- **WHEN** the launcher's stdin is not a terminal
- **THEN** it reads the hook input until end of input or a two-second stall, keeping what arrived before a stall and at most 8192 characters; unless the input fits that bound and contains exactly one `"cwd"` whose value parses to an absolute path that still resolves, the sweep reports only and says why

#### Scenario: The session's own checkout
- **WHEN** the session's project directory, or the `cwd` its SessionEnd hook input names, is at or under a linked worktree
- **THEN** that worktree is classified KEEP with reason `this-session`

#### Scenario: Concurrent sweeps
- **WHEN** a removal sweep of a repository starts while another live `worktree-janitor` holds that repository's lock
- **THEN** it removes nothing in that repository and logs that it deferred to the sweep holding the lock, and that deferral alone does not make the run exit non-zero; a lock that cannot be taken for any other reason still does. A lock whose pid is dead or no longer runs the command that took it, or untouched for more than 60 minutes, is taken over, and a sweep refreshes its lock on every removal

#### Scenario: Run record
- **WHEN** a session sweep runs
- **THEN** its log records a start line with an ISO-8601 time and the repository, and an end line with elapsed seconds and the data volume's free space before and after

#### Scenario: Not a repository
- **WHEN** the session's directory is not inside a git repository
- **THEN** the sweep logs that and exits without scanning

### Requirement: Bounded external commands
`lsof`, `git fetch`, `git ls-remote` and `gh` SHALL run under a timeout that ends the
command's whole process group, and a timed-out command SHALL be treated as a failed probe.

#### Scenario: A hung command
- **WHEN** a bounded command exceeds its timeout
- **THEN** it and its descendants are terminated and the caller receives exit status 124

### Requirement: The worktree inventory stays manual, and says why
The inventory SHALL NOT be installed as a LaunchAgent, and the installer SHALL state the
reason rather than leaving its absence to look like an oversight.

A LaunchAgent cannot read `~/Documents`. Measured 2026-08-30 with a probe agent loaded
through `launchctl bootstrap`: `ls ~/Documents/GitHub` returned `DENIED`, and
`git -C ~/Documents/GitHub/stima-api rev-parse` returned `fatal: Unable to read current
working directory: Operation not permitted`. `_cc_wj_root` defaults to
`$HOME/Documents/GitHub`, so a scheduled run would traverse nothing and report nothing —
a silent empty report, which is the failure shape this whole change exists to remove.

The gap it was meant to close stays open and is recorded as such: the reclaim hook
derives its root from the session's working directory, so nothing sweeps a repository
nobody is sitting in. On this host that left 83 live worktrees in one repository. Closing
it needs a TCC-capable host process, which this project does not have.

#### Scenario: Installing cc-reaper
- **WHEN** `install.sh` runs
- **THEN** it SHALL NOT install a worktree-report agent, and SHALL print that the inventory is manual and why

#### Scenario: An operator wants the inventory
- **WHEN** an operator runs `~/.cc-reaper/worktree-janitor.sh`
- **THEN** it SHALL report, and SHALL remove nothing without `--apply`

### Requirement: Report-only mode does not mutate the repository
Report mode SHALL NOT run `git worktree prune`. Removing administrative records is a
removal, and this tool's own contract is that removal requires `--apply`.

The report already prints `[cue: git worktree prune]` for a missing directory, so the
finding survives; only the unrequested action does not. Left ungated, the scheduled agent —
which never passes `--apply` — deleted metadata daily under the name "report-only".

#### Scenario: A worktree directory is missing during a report
- **WHEN** the inventory runs without `--apply` and finds a registered worktree whose directory is gone
- **THEN** it SHALL report the finding and the administrative record SHALL survive

#### Scenario: The same repository under --apply
- **WHEN** the inventory runs with `--apply`
- **THEN** the stale record SHALL be pruned, so the capability is gated rather than removed

### Requirement: The runner bounds any launchd log pair written on its behalf
The runner SHALL bound the `launchd-worktree-report-{stdout,stderr}.log` pair, at the top of
every run, on the same terms as every other cc-reaper runner.

Kept although the agent that would write them is not installed: the bounding is where a
future scheduled or user-installed invocation needs it, and it costs two `stat` calls. It is
placed at the top of `_cc_wj_run` because a report-only run never reaches `_cc_wj_log_write`,
where bounding it would be unreachable for the only caller that produces those files.

#### Scenario: Either file crosses the cap
- **WHEN** the inventory runs and either file exceeds the cap
- **THEN** it SHALL be bounded the same way the runner bounds its own log

#### Scenario: Inventory finds reclaimable worktrees
- **WHEN** the report identifies worktrees above the notification threshold
- **THEN** it SHALL surface them, and SHALL leave removal to an operator running `--apply`

### Requirement: Attached-resource reapers share landed policy

The system SHALL expose a read-only single-worktree query that uses the same ancestry,
content-equivalence, and exact-head merged-PR proofs as worktree reclamation.

#### Scenario: A squash-merged stack is no longer retained by ancestry-only logic
- **WHEN** a resource reaper queries a worktree whose content landed with a different commit
- **THEN** the query succeeds and reports `content`
- **AND** the query does not remove the worktree

### Requirement: Active harness session veto

No verified active Claude or Codex session may claim a removable worktree by cwd or by a
structured tool-call input in its current two human user turns. Stale registry artifacts SHALL NOT become claims, and an
unmappable verified-live claim SHALL make the destructive run fail closed.

#### Scenario: Active Claude session
- **WHEN** a live PID-named Claude session record maps to a worktree, or its unique transcript contains a structured tool call naming that worktree
- **THEN** the worktree is kept with an active Claude reason

#### Scenario: Active Codex task
- **WHEN** an open Codex thread writer lock maps to a worktree, or its rollout contains a structured tool call naming that worktree
- **THEN** the worktree is kept with an active Codex reason

#### Scenario: Stale registry artifact
- **WHEN** a Claude PID record is dead or reused, or a Codex lock file exists but is not open
- **THEN** that artifact alone does not claim a worktree

#### Scenario: Live claim cannot be mapped
- **WHEN** a verified live record cannot be parsed or mapped uniquely to cwd and transcript
- **THEN** no worktree is removed and the run states which claim was unknowable

#### Scenario: Session starts during a sweep
- **WHEN** a session claim appears after classification but before removal
- **THEN** the janitor's pre-removal refresh keeps the worktree

#### Scenario: Codex task archives while its claim is inspected
- **WHEN** a Codex writer lock closes and its rollout moves to the archive while the janitor is inspecting it
- **THEN** the janitor remaps the task through current Codex state
- **AND** only the task's cwd or current-two-turn structured tool paths receive its bounded recent-session protection
- **AND** a missing or renamed recorded cwd does not discard current structured tool-path evidence for another existing worktree
- **AND** unrelated worktrees are not reported as actively claimed by that task

#### Scenario: Transcript evidence is shared across candidates
- **WHEN** several candidate worktrees are judged from the same activity snapshot
- **THEN** each transcript's current-two-user-turn window is indexed at most once for that snapshot
- **AND** its normalized structured tool inputs are materialized at most once for that snapshot
- **AND** matching another candidate does not start another interpreter for that transcript
- **AND** malformed relevant evidence still uses the exact parser and fails closed
- **AND** non-UTF-8 filesystem path bytes round-trip through normalized evidence
- **AND** cache-key collisions and projection lookup failures cannot answer no-claim
- **AND** normal completion or an interrupt removes the private projection directory
- **AND** interruption restores and runs the invoking Bash caller's existing signal and exit cleanup
- **AND** a later start removes a private projection directory whose owner was force-killed
- **AND** early-return and sourced/background invocations still recover dead-owner projections
- **AND** the pre-removal activity refresh builds a new snapshot before destructive action
- **AND** structured active and recent transcript matching is skipped when a cheaper gate already keeps the worktree

#### Scenario: Unchanged transcript evidence is reused across scheduled sweeps
- **WHEN** a later scheduled sweep sees the same transcript path, device, inode, size, and modification time
- **THEN** it reuses the offset-only persistent index without rereading the transcript window
- **AND** any identity or content change rebuilds the evidence before it can authorize removal

#### Scenario: Cleanup task inventories another worktree
- **WHEN** the task running the janitor names a target in its own structured tool call
- **THEN** that self-reference does not claim the target
- **AND** the task's verified cwd still protects its actual checkout

### Requirement: Installed unattended cleanup policy

The installed cc-reaper policy SHALL use a 48-hour idle window. Direct invocation SHALL
remain report-only without `--apply`; `--session` and `--scheduled` MAY apply only when
their separate cc-reaper config switches are exactly `1`.

#### Scenario: Scheduled guarantee
- **WHEN** the installed LaunchAgent runs every six hours with `CC_WJ_SCHEDULE_APPLY=1`
- **THEN** it removes only worktrees that pass every existing gate and have been idle at least 48 hours

#### Scenario: Legacy destructive schedule exists
- **WHEN** the shared policy is installed over a Claude-owned worktree LaunchAgent
- **THEN** the legacy agent is unloaded and moved to a recoverable migration archive
- **AND** only the shared policy remains scheduled to remove worktrees

#### Scenario: Missing scheduled opt-in
- **WHEN** `--scheduled` runs without `CC_WJ_SCHEDULE_APPLY=1`
- **THEN** it reports only

#### Scenario: Scheduled run evidence is bounded and delimited
- **WHEN** the LaunchAgent starts a scheduled sweep
- **THEN** the actual LaunchAgent stdout and stderr files are bounded
- **AND** stdout records start time, end time, elapsed seconds, pid, and exit status for that run

### Requirement: Harness-neutral SessionEnd trigger

`worktree-janitor --session` SHALL accept SessionEnd payloads from Claude or Codex through
one deployed cc-reaper entrypoint.

#### Scenario: Either harness ends a session
- **WHEN** Claude or Codex invokes `worktree-session-end.sh <harness>`
- **THEN** the hook returns promptly, the detached sweep logs the harness, and the same policy implementation runs

### Requirement: Harness-owned repository discovery

The janitor SHALL discover repositories in ordinary configured source roots and in the
Claude and Codex harness worktree roots, deduplicating clones/worktrees by git common
directory.

#### Scenario: Harness-owned second clone
- **WHEN** a harness-owned checkout is not registered under an ordinary source root
- **THEN** it is still present in the report and evaluated by the same gates

### Requirement: Worktree-preserving regenerable trim

The janitor SHALL support an explicit `--trim-regenerable` mode that reports, and only with
`--apply` removes, ignored directories from the built-in regenerable set while retaining the
worktree, branch, tracked content, untracked authored content, and non-regenerable ignored content.

#### Scenario: Trim report is read-only

- **WHEN** the janitor runs with `--trim-regenerable` without `--apply`
- **THEN** it lists candidate directories and byte estimates
- **AND** it does not remove a directory, worktree, branch, or git administrative record

#### Scenario: Active worktree is never trimmed

- **WHEN** a process holder, verified live Claude/Codex claim, recent-session lease, locked state,
  or unreadable safety probe names the worktree
- **THEN** the janitor keeps every regenerable directory in that worktree

#### Scenario: Apply trims only selected regenerable directories

- **WHEN** `--trim-regenerable --apply` has a clean, unlocked worktree with successful holder and
  harness scans and an ignored built-in regenerable directory without a credential-shaped file
- **THEN** that directory may be removed
- **AND** the worktree and branch remain present
- **AND** tracked, untracked authored, and non-regenerable ignored content remain present

#### Scenario: Claim appears before a later directory

- **WHEN** a holder or live/recent session claim appears after one cache directory was trimmed but
  before another selected directory is removed
- **THEN** the janitor keeps the remaining directory and reports the recheck reason

### Requirement: Tools resolve under a minimal PATH
When executed, the janitor SHALL append each directory in `CC_WJ_TOOL_DIRS` (default
`/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`) that exists and is not already on PATH, and
SHALL NOT prepend them. When `gh` still does not resolve, the run SHALL say once that landing by
a merged pull request cannot be proven. Sourcing the file SHALL NOT change the caller's PATH.

#### Scenario: Scheduled run under launchd
- **WHEN** the LaunchAgent runs the janitor with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and `gh` is installed in a listed directory
- **THEN** `gh` resolves, and a worktree whose exact head a merged pull request delivered can be shown `landed=pr`

#### Scenario: gh is not installed
- **WHEN** `gh` resolves nowhere
- **THEN** the run prints one line saying landing by a merged pull request cannot be proven, and such worktrees stay kept

#### Scenario: The caller's tool comes first
- **WHEN** PATH already holds a `gh` ahead of the listed directories
- **THEN** that `gh` is the one used
