## Why

`worktree-janitor` classifies a worktree REMOVABLE when it is clean (ignored content
included), no process has its working directory inside it, and HEAD is not detached. Each
of those is true of a worktree that is in use right now:

- **A session rarely stands in the worktree it edits.** Claude Code and Codex drive a task
  worktree through `git -C <wt>` and absolute paths while their own working directory is the
  primary checkout. The only holder check is `lsof -d cwd` over a `pgrep` subset, so a
  worktree that was committed to a minute ago, with an editor or dev server holding files in
  it, reads as idle and `--apply` removes it.
- **Clean says nothing about finished.** A branch whose commits have never reached the base
  is somebody's work in progress; the branch survives the removal, but the checkout they were
  working in does not. The spec's own test for "safe" never asked whether the work landed.

The companion harness in `theQuert/skills` (`hooks/reclaim-worktrees.sh`) has run the other
half of this problem in production since 2026-08-31 and measured where each naive gate fails:

- In a squash-merging repository a landed branch is never an ancestor of its base, so an
  ancestry-only "merged" test reclaims nothing while reporting normally.
- On 2026-09-11 the stima-api disk was at 98% and 45 landed worktrees (35 GB) were kept by
  runtime byproducts - a 0-byte log opened on import, Go's daily logs, a test SQLite database
  - that no global list can know about, with a report that named none of them.
- A SessionEnd hook shares a deadline of at most 60 seconds; a sweep of a large repository
  took 258 seconds and was killed a quarter of the way through, every time.

And one gap is recorded as open in this repository: `janitors-that-can-see` measured that a
LaunchAgent cannot read `~/Documents`, and concluded that closing the inventory gap "needs a
TCC-capable host process, which this project does not have." A Claude Code session is such a
process - its SessionEnd hook runs with the terminal's grant.

## What Changes

- **Holders are every process on the machine, and open files count.** One `lsof -d cwd` and
  one `lsof` of all open files, each bounded by a timeout, replace the `pgrep` subset. A scan
  that fails or comes back empty keeps every worktree.
- **Idle is measured.** Anything under the worktree modified within `CC_WJ_IDLE_HOURS`
  (default 6) keeps it. A malformed value refuses the run instead of silently disabling the
  gate.
- **Landed is required, proven three ways against a freshly fetched base:** HEAD is an
  ancestor; merging HEAD into the base changes nothing (`git merge-tree --write-tree`); or a
  merged pull request whose head is this exact HEAD, whose base is the integration branch,
  and whose merge commit is still on the fetched base (`gh api`, when available). A base that
  cannot be resolved or fetched keeps every worktree and says so once.
- **A detached HEAD is removable only when landed by ancestry** - the one proof under which
  its commits stay reachable without the worktree.
- **A repository can declare its own regenerable byproducts** in `.worktree-regenerable`,
  read from the fetched base rather than from the worktree being judged. Patterns that name
  no path (`*`, `*.*`) are dropped and reported. A declared directory holding a
  credential-shaped file still keeps the worktree, and so does a built-in cache directory
  with one parked two levels inside it.
- **The report names what keeps a worktree**, up to three paths with their porcelain codes,
  and says where a declaration would release an ignored one.
- **`--session`** runs the inventory for the repository a Claude Code session stood in,
  detached from the session (fork, then `setsid`) so the SessionEnd deadline and the Stop
  hook's orphan sweep cannot end it, under a per-repository lock, logging to
  `~/.cc-reaper/logs/worktree-janitor-session.log` with start time, elapsed seconds and free
  space before and after. The session's own checkout is always kept. **It reports unless
  `CC_WJ_SESSION_APPLY=1`.**
- **`docs/worktree-reclamation.md`** writes the method down for anyone reclaiming worktrees,
  including the five ways a reclaimer silently reclaims nothing.

## Non-goals

- **Ending processes that hold a worktree.** The skills hook SIGTERMs stale orphan holders;
  this project's worktree janitor never signals anything. cc-reaper's orphan reapers already
  end those processes, after which the next sweep sees the worktree unheld.
- **Deleting branches.** The branch remains the claim, and the recovery path is
  `git worktree add <path> <branch>`.
- **Preserving uncommitted work to an archive tag.** Dirty worktrees stay kept.
- **Task-ownership markers.** A public tool cannot assume a marker-writing workflow; the
  landed, idle and holder gates are the ownership evidence here.
- **Registering the SessionEnd hook automatically.** The installer prints the snippet, as it
  does for the Stop hook.

## Supersedes

- The main spec's *Dual safety gate for removal* (clean + no active cwd ⇒ REMOVABLE) is
  replaced by the gates above. In particular the tested claim "an unpushed branch is still
  removable - the branch keeps the commits" no longer holds: the branch still keeps them, but
  unlanded work now keeps its checkout too.
- `janitors-that-can-see`'s statement that closing the inventory gap needs a TCC-capable host
  process this project does not have: `--session` is that process. Its requirement that the
  inventory is not installed as a LaunchAgent stands unchanged.

## Capabilities

### Modified Capabilities
- `worktree-janitor`: removal gates, report contents, session mode.

## Impact

- `shell/worktree-janitor.sh`, `tests/worktree-janitor.sh`
- `install.sh` (printed guidance only), `README.md`, `CHANGELOG.md`, `CLAUDE.md`
- `docs/worktree-reclamation.md` (new)
- Report mode now runs one `git fetch` of the base branch per repository, updating only
  `refs/remotes/origin/<base>`, and may query the GitHub API through `gh`.
