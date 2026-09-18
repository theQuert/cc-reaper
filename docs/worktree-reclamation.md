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
| Harness claim | Does any verified-live Claude session or Codex writer lock claim it by cwd or a structured tool call in its current two human user turns? | The desktop host can keep its registry and rollout open while its process cwd is `/` or the primary checkout. An unbounded transcript search pins every historical worktree forever; the two-turn window preserves a follow-up before its first tool call without doing that. Transcript files can exceed 100 MB, so inspect them backwards from the tail and stop at the second user boundary instead of rereading their whole history for every candidate. A stale PID file or unopened lock is history, not a claim; an open claim that cannot be mapped is uncertainty and keeps every worktree. |
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

A **detached HEAD** needs the ancestor proof specifically. Content and PR proofs put its
change on the base, not its commits, and nothing references those commits once the worktree
is gone.

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
  the process group. `gh` ignores `SIGALRM` and `lsof` resets its own alarms.

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
