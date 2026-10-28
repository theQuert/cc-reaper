# Reclaiming git worktrees without losing anyone's work

AI coding sessions create a git worktree per task, and most of them never remove it. A
session ends at the wrong moment, or an agent merges and moves on, and the checkout stays on
disk with its `node_modules`, build output and logs. On the machines this was measured on,
that reached 34 GB in one repository and 98% of a disk in another.

Removing a worktree is not reversible for anything the branch does not hold: ignored files,
uncommitted edits, and the fact that somebody was working there. This page is the method
cc-reaper's `worktree-janitor` uses, and the failures that shaped it. It is written to be
useful whether or not you use cc-reaper.

## The rule

A worktree may go only when **all** of these hold, and a check that cannot run keeps it:

| Gate | Question | Why the obvious version is not enough |
|---|---|---|
| Contents | Does `git status --porcelain --ignored` show only things a command rebuilds? | Plain `--porcelain` hides ignored files, and removal deletes them: a `.env`, a local database, proof logs. |
| Holders | Does any process have its cwd in the worktree, **or any file in it open**? | A session edits a task worktree through `git -C` and absolute paths while its own cwd is elsewhere. A cwd-only check sees nobody. And lsof escapes names: `\xNN` for a byte it will not print, `\\` for a backslash. No locale avoids it - under en_US.UTF-8 it still escapes a zero-width space - so scan with `LC_ALL=C`, decode the escapes back to bytes, and compare byte for byte. A path with a control character cannot be matched that way; count it as held. |
| Harness claim | Does any verified-live Claude session or Codex writer lock claim it by cwd or a structured tool call in its current two human user turns? | The desktop host can keep its registry and rollout open while its process cwd is `/` or the primary checkout. An unbounded transcript search pins every historical worktree forever; the two-turn window preserves a follow-up before its first tool call without doing that. Transcript files can exceed 100 MB, so inspect them backwards from the tail and stop at the second user boundary instead of rereading their whole history for every candidate. A stale PID file or unopened lock is history, not a claim; an open claim that cannot be mapped is uncertainty and keeps the worktrees it could be about (below, "A record that cannot be read"). |
| Landed | Has the work reached the **freshly fetched** base branch? | "Clean" says nothing about "finished". And in a squash-merging repository a landed branch is never an ancestor of its base. |
| Idle | Was nothing in the worktree, **or its `HEAD`, `index` and `logs/`**, modified within the last N hours? | Clean, unheld and landed are all true one minute after a commit, and a `git switch` touches only the administrative files. Use `find -H`: BSD find does not follow a worktree path that is a symlink. Run your own `git status` with `--no-optional-locks`, or it rewrites the index you are judging. |
| Git's own state | Is the worktree locked, or does it hold a populated submodule? | `git worktree lock` is an explicit request to keep, and Claude Code locks the worktrees it creates for agents. A submodule's dirty state is invisible to the outer status. |

Then remove the worktree, **without `--force`**, and **leave the branch**. What stops a plain removal - an untracked file, a lock, a submodule - is exactly what force would destroy. The branch is the claim: if the judgement
was wrong, `git worktree add <path> <branch>` brings the checkout back.

### Clean and merged is not unused

Those two facts describe the filesystem and the branch graph. Neither says whether a process
is working in the directory right now. Check holders before tidiness, not after. And a clean
tree can mean the opposite of finished: an abandoned worktree whose uncommitted diff is the
only copy of sixty files of work is also "not merged".

### A task someone accepted need not wait out the windows

The idle window and the session lease exist because a clean, landed tree can still be work
somebody is about to resume. A dev loop that knows the task was accepted and is live can say
so. It writes `claude-task-done` into the worktree's own git dir
(`git -C <wt> rev-parse --absolute-git-dir`), beside the `claude-task-worktree` marker, as
key=value lines of which only `head=` is read:

```
issue=2548
head=<40-hex sha>
state=done
at=2026-09-24T04:00:00Z
```

For that worktree cc-reaper then skips the session lease, uses an idle window of 0 hours and
prints `done: claude-task-done at HEAD <sha>`. It counts only when the tree is clean and the
file holds exactly one well-formed `head=` naming the current HEAD, on a branch: an
annotation left from an earlier commit says nothing about the work in the tree now. A stale,
malformed or detached one is ignored. Everything else still decides: holders, live claims,
contents, landing, git state, and the rechecks before removal, which read the annotation
again. Waiving a lease never hides a live claim, even one read after the lease.

## Proving "landed"

Against a base fetched in the same run, through an explicit refspec
(`+refs/heads/main:refs/remotes/origin/main`) so a custom `remote.origin.fetch` cannot leave
the ref you compare against stale, and with `--no-auto-maintenance`: the gc a fetch may start
prunes worktree records, which is a removal even in a run that promised to remove nothing. Any one of three proofs is enough:

1. **Ancestor** — `git merge-base --is-ancestor HEAD origin/main`. Covers merge commits and
   fast-forwards. Reclaims nothing in a squash-merging repository.
2. **Content** — merging HEAD into the base would change nothing:

   ```sh
   [ "$(git merge-tree --write-tree origin/main HEAD | head -1)" = \
     "$(git rev-parse 'origin/main^{tree}')" ]
   ```

   Covers squash merges and rebases that left the local HEAD behind. Three-way, so later edits
   on the base to other lines of the same files do not turn landed work back into unlanded
   work. Needs git 2.38.
3. **Pull request** — a merged PR whose head SHA is **this** HEAD, into the base branch, whose
   merge commit is still on the fetched base:

   ```sh
   gh api "repos/$slug/commits/$head/pulls" --paginate \
     --jq ".[] | select(.merged_at != null and .base.ref == \"main\" and .head.sha == \"$head\") | .merge_commit_sha"
   ```

   Ask by commit, not branch name: names get reused. Compare the head SHA, because the
   endpoint also returns PRs whose head later moved past this commit. Check the merge commit
   against the base, because a force-push can undo a merge the API still reports. Name the
   repository from `remote.origin.url` yourself, or `$GH_REPO` can make another repository's
   PR authorise this removal.

A **detached HEAD** needs the ancestor proof, or a ref that contains it. Content and PR
proofs put its change on the base, not its commits. When a branch, tag or remote-tracking
ref contains the HEAD it may be removed, after the abandon window when it has not landed,
and the HEAD is first pinned as `refs/cc-reaper/detached/<sha>`: a remote-tracking ref can
be pruned or force-pushed away, and the pin is what keeps the commits afterwards.

A **branch one push behind its own pushed head** has landed when that pushed head passes the
merged-PR proof: every local commit is in what merged. Asked only when HEAD is a strict
ancestor of `refs/remotes/origin/<branch>`.

A worktree with an **operation in progress** (`rebase-merge`, `rebase-apply`, `BISECT_LOG`,
`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD` in its git dir) is kept: that state exists
nowhere else.

## A launchd job is a holder between runs

A job that runs a script from a worktree has no process most of the time, so the `lsof` and
session scans cannot see it; it fails every run once the checkout is gone. Every
`*.plist` in `CC_WJ_LAUNCHAGENTS_DIRS` (default `~/Library/LaunchAgents`, `/Library/LaunchAgents`,
`/Library/LaunchDaemons`; `*.disabled*` skipped) is read with `plutil`, and a worktree containing
any absolute path a string value names, as written or with symlinks resolved, is
`KEEP(launchd-target:<Label>)`. The match is on whole path components (`wt-1` is not `wt-10`) and is
made again right before a removal. A plist that cannot be parsed is `KEEP(launchd-scan-unknown)`
for every worktree in the run. A program or interpreter script that does not exist is only
printed, as `launchd-missing-program:<Label> <path>`.

A string is read the way a shell reads a command line: a path ends at a blank, `=`, `:`, a quote,
`;`, `&`, `|`, `(`, `)`, `<`, `>` or a backtick, a value that runs over several lines is one value, and a
leading `~/`, `$HOME/` or `${HOME}/` is the home of the plist's `UserName` (from `dscl`), else the
janitor's own `$HOME`.

## Work origin already holds

Landing is not the only way work is safe: a commit origin lists in a branch is on another
machine. `CC_WJ_RECLAIM_PUSHED` (default 1) adds two outcomes, and every other gate (holders,
harness claims, idle window, git state) is asked unchanged:

| Classification | When | Before the removal |
|---|---|---|
| `REMOVABLE(pushed)` | clean, HEAD contained in a branch tip origin lists now | nothing |
| `REMOVABLE(wip-pushed)` | only tracked edits or untracked non-ignored files stand in the way, and HEAD is landed or pushed | a snapshot (HEAD plus those files, built in a private index) is sent to `refs/wip/<label>/<worktree>-<UTC stamp>`, read back with `ls-remote`, and re-taken to prove the tree did not change; the checkout is then removed with a single `--force` |

Things that are easy to get wrong:

- **Pushed is asked of origin, not of `origin/<branch>`.** The run fetches only the base, so a
  remote-tracking ref can name a branch deleted or rewritten since. One `ls-remote` per
  repository per run; if it fails nothing counts as pushed.
- **A report sends nothing.** It prints `would push wip: N entries to <ref>`; only `--apply`
  makes the ref, right before the removal, so a refused or failed push keeps the worktree.
- **A snapshot holds no ignored file.** An ignored file nothing rebuilds (`.env`, a local
  database) keeps the tree as before. A nested repository would be recorded as a bare commit
  id, so it fails the snapshot and keeps the tree.
- **Snapshots are never garbage-collected.** `wip-backup.sh` leaves refs named `*-<stamp>`
  alone; they are the only copy of what was removed. Delete one by hand when you are done.
- The single `--force` lets git drop the verified edits; it does not override a lock
  (`git_keep` already keeps locked trees). Branches are still never deleted.

## Byproducts only the repository knows about

Built-in lists cover what every project has (`node_modules`, `.venv`, `.next`,
`__pycache__`, …). They cannot know that one API opens `data/parsed/logs/api.log` at import,
or that one test suite leaves `model/one-api.db`. Let the repository say so in
`.worktree-regenerable`, one glob per line:

```
# written by the API on import
logs/*.log
model/one-api.db*
/build/
```

Three rules make this safe:

- **Read it from the fetched base, never from the worktree being judged.** Every existing
  worktree benefits the moment the declaration lands, and a branch cannot declare its own
  content disposable on its way to being deleted.
- **Reject patterns that name nothing in particular.** A wildcard pattern must spell two
  consecutive literal characters: `*`, `*.*` and `a*` are dropped and reported. Allow only
  plain name characters plus `*` and `?`: counting literals around richer syntax was bypassed
  by `[[:alpha:]][[:alpha:]]*`, `[!]][!]]*` and, in zsh, `(*|ab)` - each matches everything.
- **It is a shell glob, not a .gitignore.** `*` matches across `/`, and there is no negation. A
  file containing a `!` line is not applied at all: dropping only that line would still delete
  the file its author meant to protect.
- **A declaration does not cover a credential.** A declared directory is still searched for
  credential-shaped files (`.env`, `*.pem`, `*.key`, `id_rsa`, …), because builds copy them
  into their output; so is a cache directory, two levels deep, because that is where people
  park them.

And **name what keeps a worktree**. A report that says "unrebuildable=1" sent someone on a
separate investigation to find the 0-byte log that was holding 45 worktrees.

### Records a person wrote: `archive:`

Some ignored files are records, not byproducts. stima-api's staging preflight refuses to run
without a hand-written `.canary-window-plan` in the worktree. Nothing rebuilds one, so the
janitor rightly keeps the worktree: 14 of them on 2026-09-24, and ten more a day. Declaring
the file regenerable would delete the record. Declare it `archive:` instead:

```
archive:.canary-window-plan
```

With `--apply`, after every recheck and right before the removal, the janitor:

- copies each such file into
  `~/.cc-reaper/archive/<repository>/<worktree>-<UTC time>.<random>/` (set with
  `CC_WJ_ARCHIVE_DIR`);
- compares every copy with its source, byte for byte;
- appends a row to `index.tsv` in the archive directory.

If any step fails, the worktree stays. It takes the list of files from the same fresh read
as the recheck, so a file written after the inventory is copied too. A dry run shows
`archive on removal:` for each removable worktree that holds such files.

It copies only a regular file that is not a symlink, is not credential-shaped, and is no
larger than `CC_WJ_ARCHIVE_MAX_BYTES` (1 MiB), because the archive is for what a person
wrote. A file that fails one of these keeps its worktree, and the report says which
condition it failed. An `archive:` line is asked before a plain one, so `*.log` beside
`archive:keep.log` still copies `keep.log` out. A directory git lists collapsed (`logs/`,
`.codex/evidence/`) that an `archive:` pattern may name a path inside (`logs/notes.md`, `*.md`,
`.codex/evidence`) is walked, and each file in it is judged the same way. A subdirectory a
plain line declares (`.codex/evidence/*/venv`) is discounted whole when the only `archive:`
patterns reaching it are wildcard-free ancestors. The walk stops at the first file that keeps
the worktree and names it, and a walk that fails or passes 1000 files keeps it. The janitor never
deletes anything from the archive; that is yours to do. An older janitor drops the line as a
pattern that names no path, so the file goes on keeping its worktree.

### Two pins on probation, checked before they decide

On 2026-10-24 the sweep kept 50 worktrees (30.9 GB) as `unrebuildable`, many of them for one
of two entries that are not work:

- **a top-level ignored `*.log` file** (`next-manual.log`, `routing-snapshot-redis.log`,
  `.build-main.log`): output a dev server or build wrote. Only a regular file at the top
  level counts; `sub/run.log`, a symlink or a credential-shaped name still keeps the tree.
- **a `.claude/skills` or `.claude/commands` symlink into the repository's own primary
  checkout**, absolute or relative, as an older `new-task-worktree.sh` made them. Removing a
  link removes nothing it names. A link anywhere else still keeps the tree.

Either may stop keeping a worktree, but only once someone has looked at what that would do.
`CC_WJ_NEW_RULES_MODE` is `spotcheck` by default (and for any value but `auto`): every
decision stays exactly as before, and each removal or trim the rules *would* have made is
appended to `CC_WJ_SPOTCHECK_LOG` (`~/.cc-reaper/logs/spotcheck-worktree-janitor.log`), one
line with the sweep's run id, phase, rule, path, bytes and the holder result from the
sweep's snapshot:

```
[2026-10-24T13:00:00+0800] run=20261024T050000Z-4242 phase=trim action=would-trim rule=top-level-log path=<wt>/web/next/node_modules bytes=1610612736 holder=none(sweep-snapshot) worktree=<wt>
```

A tree is spot-checked only when those entries are *all* that keeps it; it is then judged
through every other gate as the rule would judge it (holders, claims, landed, idle, git
state), and the report adds a `spotcheck:` line under the unchanged classification. Set
`auto` and the same trees go through the ordinary path, including every recheck right before
the removal or the trim. Nothing about landing changes: an unlanded tree is still never
removed, and the trim never asked for landing; what a log changed for the trim is that it
made the tree dirty, and a dirty tree is trimmed only after `CC_WJ_TRIM_DIRTY_IDLE_HOURS`
(168).

### Two more rules on probation: `pushed-idle` and `dirty-pressure`

Both obey `CC_WJ_NEW_RULES_MODE` like the two pins above: `spotcheck` (the default) logs
`rule=pushed-idle` or `rule=dirty-pressure` to the spot-check log and changes no decision; `auto` lets
them decide.

- **`pushed-idle`** (removal phase). A clean tree whose only reason to be kept is `KEEP(unlanded)`, whose
  HEAD a `refs/remotes/origin/*` ref of this clone already contains (fetched state, no network), and
  which has sat idle for `CC_WJ_PUSHED_IDLE_HOURS` (default 72, never shorter than the ordinary window;
  0 turns the rule off). It is the case "Work origin already holds" cannot see: origin's live listing no
  longer names the branch (deleted after a merge, or the listing failed) but the tracking ref still does.
  Holders, live and recent sessions, claims, the deny list, task markers and the recheck before removal
  all still decide, and removal takes the checkout only: the branch and its commits stay. A tree with
  edits to snapshot (`wip`) is not reached, and `CC_WJ_RECLAIM_PUSHED=0` turns the rule off.
- **`dirty-pressure`** (trim phase). Under disk pressure a dirty tree waits
  `CC_WJ_TRIM_DIRTY_IDLE_HOURS_PRESSURE` (default 24; never longer than `CC_WJ_TRIM_DIRTY_IDLE_HOURS`;
  0 turns it off) instead of 168 before its ignored regenerable directories are trimmed. Only those
  directories are ever listed, so the uncommitted files stay. The ordinary knob at 0 still means never.

### Names nothing may touch

`CC_WJ_DENY_NAMES` (whitespace-separated; the installed config sets
`homepage uiux verify-signin-redesign`) keeps a worktree as `KEEP(deny-listed:<name>)` in the
removal sweep and the trim alike when its directory name or branch contains a name, or when a
live Claude session registered under that name stands at or under it. A live session's tool
calls already veto through the ordinary claim gate; this one holds whatever the claim windows
say.

### A record that cannot be read keeps the trees it could be about

Until 2026-10-24 one session record the janitor could not read kept every worktree on the
machine: a torn `53453.json`, a Codex claim whose task was not yet in `state_5.sqlite`, a
transcript `find` that failed on a full disk. That day eight such records each blinded a sweep,
and the 10:35 run kept all ~120 trees and freed 0 B.

With `CC_WJ_UNKNOWN_SESSION_SCOPE=tree` (the default) such a record keeps only the worktrees it
could be about. What can still be read of it attributes it:

| Record | Attributed by |
|---|---|
| a live Claude registry record (`<pid>.json`) that will not parse, has a bad session id, or a cwd that does not resolve | the cwd of that pid (`lsof -p <pid> -d cwd`), any `"cwd"` string in its raw text, and the transcript of the session id its raw text (or else the pid's command line) carries |
| a live Claude registry record with no valid pid, or a pid other than the live one its file is named for | every tree: it is not bound to the live process, so its session id may be another session's |
| a live Claude session whose transcript cannot be located, is not unique or is unreadable | its cwd (already a claim), the project directories of its transcripts, and each transcript that can be read |
| a recent Claude transcript that cannot be opened, has no activity time or no cwd | its project directory under `~/.claude/projects`, which encodes the cwd it started in (every byte but `[A-Za-z0-9]` becomes `-`); a prefix match, so a sibling whose name extends the tree's is kept too; and the transcript, when it can be read |
| an active Codex writer lock with no single task row or rollout | every cwd its state rows name, the `cwd` in its rollout's first record, the cwd of each process holding the lock, and each rollout its rows or `~/.codex/sessions` name; a rollout path with a space, a glob character or no leading `/` is left unsearched, so it keeps every tree |
| a recent Codex row that cannot be used | its `cwd` column, and its rollout when it can be read |
| a transcript that fails to parse when a candidate asks it | its own session's cwd claims, for Claude its project directory, and the transcript itself; it is then dropped from the lists, so later candidates do not ask it again |

Every cwd is matched as written and as resolved (`cd -P` on its deepest existing ancestor, the
rest appended), with and without `/private`, so a cwd given through a symlink names the tree it
points into. A transcript is searched as raw text, since its records could not be parsed: every
spelling of the tree's path (as given, physical, with and without `/private`, also with JSON's
`\/`) as a fixed string in its current two human user turns, the same window the readable path
reads for tool calls, widened by any record that does not parse. A mention keeps the tree; a
transcript that cannot be read or a path JSON might spell otherwise keeps it too.

A live record - a `<pid>.json` of a live pid, an active Codex claim, the transcript of a live
session - may be a session working in any tree by absolute path from a cwd elsewhere, which no
cwd, project directory or recency check sees (the session grace and the idle window are both
48 hours). So a live record whose transcript cannot be found or read keeps every tree, as
`global` would. Only a record no live session holds (a recent transcript or Codex row whose id no
live registry entry carries) is attributed by its cwd, project directory and recency alone.

Whether Claude shortens a long project directory name is not established here, so a project
directory attribution keeps every tree when its name, or the name of the tree's path, is longer
than 200 characters.

Whatever could not be read may still name any path (a tool call can), so every such record
also keeps each tree whose own recent signals - an entry at its top level, its git index,
`HEAD` or `HEAD` reflog - changed within the session grace (at least one hour). An older tree
nothing names is judged by its other gates as usual. Every other keep gate still applies to
every tree: holders, the deny-list, launchd targets, landing, git state, dirty and unpushed
work. A tree whose edits would first go to `refs/wip` stays kept while any record is unknown,
since a snapshot taken while an unreadable session may be writing it proves nothing. A registry
that cannot be listed at all, or a missing `jq` or `sqlite3`, still keeps every worktree: no
record of it was read, so none can be attributed.

A tree kept this way reads `KEEP(session-unknown:<record>)`, with records named like
`claude-session:53453.json`, `claude-transcript:<session id>` or `codex-claim:<thread id>`. Each
record is logged once per phase, to stderr and the janitor log, with what attributed it and the
trees it kept:

```
worktree-janitor: KEEP(session-unknown:claude-transcript:b627c13d-...) scope=tree: recent Claude transcript b627c13d-....jsonl is unreadable (Permission denied); about: projdir=-Users-me-GitHub-repo--claude-worktrees-a, and trees active within the session grace; kept 2 worktree(s): /Users/me/GitHub/repo/.claude/worktrees/a /Users/me/GitHub/repo/.claude/worktrees/c
```

The run still exits 1 when a record could not be read. The same per-tree question is asked
again against the fresh scans right before each removal and each trimmed directory.

The rule changes which trees may be removed, so it is on probation like the two pins above:
under `CC_WJ_NEW_RULES_MODE=spotcheck` (the default) every decision stays as `global` makes it,
and each tree the per-tree rule would free is appended to `CC_WJ_SPOTCHECK_LOG` with
`rule=session-unknown-per-tree`, with a `spotcheck:` line under its unchanged
`KEEP(active-session)`. `auto` lets it decide. `CC_WJ_UNKNOWN_SESSION_SCOPE=global` (or any value
but `tree`) is the old behaviour: the first record that cannot be read keeps every worktree,
whatever `CC_WJ_NEW_RULES_MODE` says.

## Where to run it

- **From cc-reaper's six-hour LaunchAgent** for repositories under the installed `~/GitHub`
  root and either harness's worktree root. If you configure `~/Documents`, `~/Desktop` or
  `~/Downloads`, remember that TCC grants are per executable: launchd spawns `/bin/bash`.
  A denial is reported and makes the run fail; granting Full Disk Access to the terminal does
  nothing for it, while granting it to `/bin/bash` grants it to every bash script.
- **From either harness's SessionEnd hook, detached.** The session's processes carry its terminal's grant.
  But every SessionEnd hook shares a deadline of at most 60 seconds, and a sweep of a large
  repository took 258. Fork, `setsid()` in the child, then let the parent exit — in that
  order, or an orphan reaper running beside the hook can see the sweep as an orphan still in
  the session's process group and kill it. Treat this as best-effort: app-level archive may
  release a Codex writer lock without dispatching the repository hook. The LaunchAgent is
  the guarantee layer that later evaluates the now-unclaimed worktree. Releasing the lock
  starts a bounded recent-session lease from Codex update/archive time; recent Claude
  transcript activity supplies the equivalent lease. This is separate from file idleness,
  so an old worktree cannot become removable immediately after an accidental archive.
  If archive moves a Codex rollout while a sweep is reading it, the sweep remaps the task
  through current Codex state and applies that lease only to the archived task's cwd or
  current-two-turn tool paths. The move does not pin unrelated worktrees.
- **Under a per-repository lock**, so a session-end sweep and a manual run do not race. Record
  the holder's full command line with its pid; a name match mistakes a recycled pid for a sweep.
- **Keeping the session's own checkout** - `CODEX_PROJECT_DIR`/`CLAUDE_PROJECT_DIR` and the
  `cwd` in the hook's JSON input, since a session that worked in a linked worktree may report either. Bound the
  read, but not with bash 3.2's `read -t -d ''`, which discards everything it read when it
  times out on a pipe left open. Unless exactly one `cwd` parses to an absolute path that
  still resolves, only report: the one worktree you must not touch is then unknown.
- **With every external command bounded** — `lsof`, `git fetch`, `gh` — by a timeout that kills
  the process group. `gh` ignores `SIGALRM` and `lsof` resets its own alarms. The
  machine-wide `lsof` scans take `CC_WJ_LSOF_TIMEOUT_SECONDS` (120) and the Codex lock
  registry scan `CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS` (30); a scan that times out is retried once
  before it counts as failed, and a failed scan still keeps everything.
- **With the sweep itself bounded.** Bounding each command does not bound their product with
  the worktree count: at load 50-70 one scheduled sweep ran 5913 s, holding the lock, so every
  SessionEnd sweep meanwhile deferred and removed nothing. Each phase of an apply run (the
  removal sweep, the scheduled trim) stops examining worktrees after
  `CC_WJ_SWEEP_BUDGET_SECONDS` (1800; `0` is unbounded), finishes the worktree it started,
  releases the lock, logs `budget exhausted` with the elapsed seconds and how many it left,
  and exits 0. The first worktree of a phase is examined whatever the clock says, so a phase
  whose setup alone outlasts the budget still makes progress. A per-repository, per-phase
  cursor under `~/.cc-reaper/state/` (`CC_WJ_STATE_DIR`) makes the next apply run start
  after the last worktree examined, in path order, wrapping round, and a per-phase repository
  cursor makes it start with the repository after the last one in which it examined a
  worktree before the budget ran out, so a large
  first repository cannot starve the rest; report runs neither read nor write either. The
  lock is refreshed at every worktree boundary.
- **Largest first** (`CC_WJ_ORDER=largest`, the default; stima-api #5886). Within a
  repository the worktrees are examined by their last known size, largest first, so a sweep
  the budget cuts short has spent it where the bytes are. Nothing is measured for the order:
  the sizes are growth-watch's samples (`growth-samples.tsv`, keyed under the glob rows of
  `growth-targets.tsv`) and the janitor's own `du` of a worktree (a report's estimate, a
  spot-check, a removal), kept as `path<TAB>bytes<TAB>measured_at` in
  `worktree-sizes.tsv` under `CC_WJ_STATE_DIR`; the newest measurement wins, a removal
  forgets the row, a trim subtracts what it freed, and rows 30 days old drop. In this mode the
  worktree cursor holds the worktrees examined in the current cycle: those go after the rest,
  and once all are in it a new cycle starts. Trees of unknown size go after the known ones,
  in path order, since an unmeasured tree is almost always a new one still in use. The order
  never decides anything: every gate applies to every tree. `CC_WJ_ORDER=path` restores the
  path order and its resume-after-the-last cursor, and reads and writes no sizes.
- **Rechecking a trim without rescanning for every cache.** The scheduled trim under disk
  pressure runs after the removal phase, with its own budget: trimming first would bump the
  worktree's mtime and make the same run keep a landed tree as recently active. Before a
  later cache directory of the same worktree the trim reuses a holder and session snapshot younger than
  `CC_WJ_RECHECK_FRESH_SECONDS` (120) instead of rescanning the machine; every claim, holder
  and content check is still asked against it. Removal always rescans.
- **Answering "nothing to trim" first.** The holder scan is machine-wide and taken once per
  phase (two `lsof` calls, about 4 s on 2026-10-24), plus once more before each removal or
  trimmed worktree; it does not grow with the number of worktrees. What does is the rest:
  per tree, the recent-session lookup took 2-5 s, the git-state probe 1.5 s and the idle walk
  up to 4 s, and on 2026-10-24 the trim phase spent them on all 132 trees it examined, every
  one answering `count=0`, and ran 3240 s against its 1800 s budget. The trim now reads a
  tree's regenerable directories first (one `git status`) and moves on when there are none.

The common hook command is:

```json
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "\"$HOME\"/.cc-reaper/worktree-session-end.sh codex" } ] }
    ]
  }
}
```

Use `claude` instead of `codex` in Claude's global hook. `install.sh` migrates that global
Claude entry automatically; Codex entries are repository-owned and should be checked in.
Both trigger the same deployed script, report to
`~/.cc-reaper/logs/worktree-janitor-session.log`, and take their 48-hour/session/schedule
policy from `~/.cc-reaper/worktree-janitor.conf`.

Observe the exact evidence without changing git or harness state:

```bash
~/.cc-reaper/worktree-janitor.sh --claims <session-id-or-path>
~/.cc-reaper/worktree-janitor.sh --repo /path/to/primary-checkout
```

The first command lists live claims and recent leases with state, last activity, age, and
remaining grace. The second is a report-only inventory; a lease prints
`KEEP(recent-session)` and a `session lease:` line. `CC_WJ_SESSION_GRACE_HOURS` controls
this lease and defaults to 48 independently of `CC_WJ_IDLE_HOURS`.

A cleanup task's own structured tool calls are not activity claims: inventorying a target
necessarily names it. Its verified cwd still protects the checkout it actually uses, while
all other live Claude and Codex claims remain vetoes.

Within one activity snapshot, each transcript's current-two-user-turn window is indexed
once as byte ranges and reused across candidate worktrees. The first query also materializes
normalized structured-tool input into a private, ephemeral search projection, so later
candidates do not start another interpreter for the same transcript. Malformed relevant
records bypass that fast path and retain exact fail-closed parsing. The persistent index
contains only file identity and byte ranges; the temporary projection is discarded with the
run, including when a scheduled sweep is interrupted. Filesystem bytes outside UTF-8 are
round-tripped rather than rewritten. The destructive recheck starts a fresh snapshot, so this avoids repeated decoding
without weakening the final race gate.

## Five ways a reclaimer silently reclaims nothing

Each was observed on a real machine, and each produced output that looked like a clean sweep.

1. **A malformed setting.** An idle window set to `off` made `find` fail, which printed
   nothing, which read as "nothing idle". 78 worktrees accumulated behind one word. Validate
   numeric settings and refuse to run on a bad one.
2. **An ownership marker nobody writes.** A reclaimer that only touches worktrees carrying a
   marker never touches the ones created by hand or before the marker existed. That is
   correct, and it has to be reported as a count, or it looks like there is nothing to do.
3. **A byproduct nobody declared.** See above: 45 landed worktrees, 35 GB, kept by files the
   report did not name, on a disk at 98%.
4. **The hook deadline.** A sweep killed a quarter of the way through every time, with its
   report on a pipe nobody reads.
5. **A second clone.** `git worktree list` only enumerates the repository you ask. cc-reaper
   now searches `~/.claude/worktrees` and `~/.codex/worktrees` in addition to configured source
   roots, but an arbitrary second clone outside all of them is still invisible. A worktree
   belonging to another clone of the same project — an IDE's or an agent app's own checkout —
   is not kept with a reason; it is absent from the report. There is no log line for this; the
   tell is arithmetic:

   ```sh
   ls ~/src/project-worktrees | wc -l     # 103
   git -C ~/src/project worktree list | wc -l   # 80
   cat ~/src/project-worktrees/<surplus>/.git   # gitdir: <the clone that owns it>
   ```

## What this does not do

An attached-resource reaper that must stop a service before the process-holder gate can
pass can call `worktree-janitor.sh --landed PATH`. This read-only query returns the same
`ancestor`, `content`, or exact-head merged-PR proof as the janitor and returns non-zero
for `no` or `unfetched`. That prevents an ancestry-only stack policy from retaining
squash-merged work forever.

- **End processes holding a worktree.** A dev server left running after its session is a
  holder, and the worktree is kept. cc-reaper's orphan reapers end those processes; the next
  sweep then sees the worktree unheld.
- **Delete branches**, or **commit uncommitted work** to preserve it. A dirty worktree is kept.
- **See edits hidden by `assume-unchanged` or `skip-worktree`**, or dirty state inside a
  submodule configured `ignore=all`. Git's status omits both, and so does removal's check.
- **See holders lsof cannot**: another user's processes, or a container or VM using the
  worktree through a bind mount. Stop those before sweeping, or keep such worktrees locked.
- **Notice a moved default branch.** The base comes from `origin/HEAD` as the clone recorded
  it; set `CC_WJ_BASE_BRANCH` if the trunk has changed since.
