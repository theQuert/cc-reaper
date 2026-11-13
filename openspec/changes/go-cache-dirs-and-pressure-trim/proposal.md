# The go build cache cap sees executable directories; idle worktree build output is given back

## Why

The Mac mini lost 39 GB in 6.5 hours on 2026-11-13 and a session's tests were refused at 22.6 GiB
free (stima-api#8198, evidence on stima-api#5886).

- The go build cache was 26.7 GiB by `du`, but every Go cache selector here matched regular
  `-a`/`-d` files two levels down only. Since go1.24 `go run` and `go tool` cache their executable
  as `<xx>/<hash>-d/<name>`, a directory: 284 of them held 19.6 GiB, and the cap resource-watch runs
  every round never listed one. Its log line "what remains was modified within 60m" was asserted
  after any shortfall, not measured, so the log looked healthy.
- Worktree build output (`node_modules`, `.next`) grew 18 GB in a day. 129 of the last 300
  classifications were `KEEP(unrebuildable=N)` (a tree with uncommitted files, waiting 168 h), the
  shorter `dirty-pressure` wait was a rule on probation that only logged, and
  `CC_WJ_DENY_NAMES` kept a named tree out of the trim tier as well as out of removal.

## What Changes

- One selector per script lists both Go cache entry forms: the regular `-a`/`-d` files and the
  `<hash>-d` directories, a directory aged by its newest member's mtime, sized by `du`, removed as
  one unit. `go_lru_victims` and `reap_go_cache` (reclaim-byproducts.sh) and both Go selectors in
  disk-janitor.sh (the `go-build-age` step and the `--clean` age trim) use it. The cap keeps its
  numbers (over 20 GB, down to 12 GB, nothing modified within `CC_GO_CACHE_MIN_AGE_MIN`, 60) and,
  after deleting, logs what it measured remaining inside the window.
- The `go-build-age` step treats a directory as held when a process holds anything inside it (a
  running `go run` executable is open as `<hash>-d/<name>`).
- `dirty-pressure` is added to `CC_WJ_PROMOTED_RULES` and `CC_WJ_TRIM_DIRTY_IDLE_HOURS_PRESSURE`
  is set to 6 in `config/worktree-janitor.conf`.
- `CC_WJ_DENY_NAMES` keeps a tree for removal only. A trim keeps the tree too, so a named tree
  goes through the trim phase under every gate any tree meets (holder, live session, inbound link,
  idle window).
- The trim summary prints the volume's `df` free-space change beside its `du` figure.
- Trim order is unchanged: `CC_WJ_ORDER=largest` already examines trees by their last known size
  with no extra pass.

## Impact

- `shell/reclaim-byproducts.sh`, `shell/disk-janitor.sh`, `shell/worktree-janitor.sh`,
  `config/worktree-janitor.conf` and their tests. The installed copies under `~/.cc-reaper` change
  only by the installer. Rollback: revert, or remove `dirty-pressure` from `CC_WJ_PROMOTED_RULES`.
