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
  consecutive literal characters: `*`, `*.*` and `a*` are dropped and reported, and so is any
  bracket expression. Counting what is left after stripping brackets was bypassed twice:
  `[[:alpha:]][[:alpha:]]*` and `[!]][!]]*` both pass that count and match everything.
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

- **Not from a LaunchAgent on macOS**, if any repository lives under `~/Documents`, `~/Desktop`
  or `~/Downloads`. TCC grants are per executable, launchd spawns `/bin/bash`, and every
  scheduled run is denied while reporting success. Granting Full Disk Access to the terminal
  does nothing for it; granting it to `/bin/bash` grants it to every bash script.
- **From a SessionEnd hook, detached.** The session's processes carry its terminal's grant.
  But every SessionEnd hook shares a deadline of at most 60 seconds, and a sweep of a large
  repository took 258. Fork, `setsid()` in the child, then let the parent exit — in that
  order, or an orphan reaper running beside the hook can see the sweep as an orphan still in
  the session's process group and kill it.
- **Under a per-repository lock**, so a session-end sweep and a manual run do not race. Record
  the holder's full command line with its pid; a name match mistakes a recycled pid for a sweep.
- **Keeping the session's own checkout** - both `CLAUDE_PROJECT_DIR` and the `cwd` in the hook's
  JSON input, since a session that worked in a linked worktree may report either. Read that
  input with a short bound (`read -t 2`), and when it names a `cwd` you cannot parse, only
  report: the one worktree you must not touch is then unknown.
- **With every external command bounded** — `lsof`, `git fetch`, `gh` — by a timeout that kills
  the process group. `gh` ignores `SIGALRM` and `lsof` resets its own alarms.

With cc-reaper:

```json
{
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "\"$HOME\"/.cc-reaper/worktree-janitor.sh --session" } ] }
    ]
  }
}
```

It reports to `~/.cc-reaper/logs/worktree-janitor-session.log` and removes nothing until you
set `CC_WJ_SESSION_APPLY=1`. Read a few reports first.

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
5. **A second clone.** `git worktree list` only enumerates the repository you ask. A worktree
   belonging to another clone of the same project — an IDE's or an agent app's own checkout —
   is not kept with a reason; it is absent from the report. There is no log line for this; the
   tell is arithmetic:

   ```sh
   ls ~/src/project-worktrees | wc -l     # 103
   git -C ~/src/project worktree list | wc -l   # 80
   cat ~/src/project-worktrees/<surplus>/.git   # gitdir: <the clone that owns it>
   ```

## What this does not do

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
