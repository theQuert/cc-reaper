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

#### Scenario: Stale registry artifact
- **WHEN** a Claude PID record is dead or reused, or a Codex lock file exists but is not open
- **THEN** that artifact alone does not claim a worktree

#### Scenario: Archived Codex task
- **WHEN** the app archives a Codex task without dispatching SessionEnd and its writer lock is no longer open
- **THEN** its `archived_at` or later activity starts a recent-session lease, and the worktree is `KEEP(recent-session)` for the configured grace period

#### Scenario: Archived task after old worktree activity
- **WHEN** a worktree's files have been idle longer than 48 hours but a mapped task was archived less than `CC_WJ_SESSION_GRACE_HOURS` ago
- **THEN** the recent-session lease keeps the worktree even though its file-idle gate already holds

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
- **THEN** it removes nothing in that repository, logs that another sweep holds the lock, and the run exits non-zero; a lock whose pid is dead or no longer runs the command that took it, or untouched for more than 60 minutes, is taken over, and a sweep refreshes its lock on every removal

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
