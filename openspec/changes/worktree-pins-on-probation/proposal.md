# Two trivial pins on probation, a deny-list, and nothing-to-trim answered first

## Why

On 2026-10-24 (stima-api#5886) the last sweep kept 50 worktrees (30.9 GB) as unrebuildable,
many of them for a top-level ignored `*.log` file or an old absolute `.claude/skills` link into
the primary checkout. Its trim phase ran 3240 s against an 1800 s budget, and all 132 trees it
examined answered `count=0`. The cost per tree came from the recent-session lookup (2-5 s), the
git-state probe (1.5 s) and the idle walk (up to 4 s), not from the holder scan: that is taken
once per phase (about 4 s) and again only before each removal or trimmed worktree.

## What Changes

- Under `CC_WJ_NEW_RULES_MODE=auto` the contents gate also discounts a top-level ignored `*.log`
  regular file and a `.claude/skills` or `.claude/commands` symlink into the repository's own
  primary checkout. Under `spotcheck`, the default and any other value, no decision changes,
  and each removal or trim these rules would have made is appended to `CC_WJ_SPOTCHECK_LOG`.
- `CC_WJ_DENY_NAMES` keeps a named worktree from every removal and trim.
- The trim phase lists a tree's regenerable directories before its claim lookups, git-state
  probe and idle walk, and moves on when there are none.
- Unchanged: every other gate, every recheck before a removal or a trim, the landed proofs, the
  dirty-tree trim window, the holder scans and their failure modes. Branches are never deleted.

## Impact

- `shell/worktree-janitor.sh`, `config/worktree-janitor.conf`, `docs/worktree-reclamation.md`,
  `tests/worktree-janitor-newrules.sh`.
- Rollback: revert the commit, or leave `CC_WJ_NEW_RULES_MODE` at `spotcheck`.
