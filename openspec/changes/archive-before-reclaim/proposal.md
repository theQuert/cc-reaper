# Copy a hand-written record out of a worktree, then reclaim it

## Why

Some ignored files are not byproducts. They are records a person wrote, and a command cannot
rebuild them. The stima-api repository requires one in every task worktree:
`.canary-window-plan`, which its staging preflight refuses to run without. The janitor is
right to count such a file as unrebuildable, so every task worktree is kept forever. On
2026-09-24, 14 landed worktrees were kept by that one file, about ten more were added each
day, and the file also blocked the `claude-task-done` reclaim for the same trees. Declaring
it regenerable would delete a record. Archiving the plans by hand, as was done for 12 of them
that day, is the toil the janitor exists to remove.

## What Changes

- **A new line form in `.worktree-regenerable`.** A line `archive:<pattern>` on the fetched
  base declares that a copy of an ignored file is enough. Whitespace and leading `/` after
  the prefix are ignored. The pattern follows the same rules as every other line, and one
  that names no path is dropped and reported with its prefix. An `archive:` line never
  declares anything regenerable.
- **Which files the pattern discounts.** An ignored entry git lists as a file is not counted
  as unrebuildable content when all of these hold:
  - it matches an `archive:` pattern (asked before any plain declaration, so a plain line
    naming the same file cannot delete it uncopied);
  - it is a regular file, not a symlink;
  - it is not credential-shaped;
  - its name holds no tab or newline;
  - it is no larger than `CC_WJ_ARCHIVE_MAX_BYTES` (default 1048576).

  A matching file that fails any of these still keeps the worktree, and the report names the
  condition it failed. A value of `CC_WJ_ARCHIVE_MAX_BYTES` that is not a number makes no
  file archivable.
- **What `--apply` does with them.** After every recheck, and immediately before a removal,
  the janitor copies each such file into a new directory,
  `<CC_WJ_ARCHIVE_DIR>/<repository name>/<worktree name>-<UTC time>.<random>/<relative path>`
  (default `~/.cc-reaper/archive`). The list of files comes from the same fresh status read
  as the recheck. The janitor then compares every copy byte for byte with its source and
  appends a row to `<CC_WJ_ARCHIVE_DIR>/index.tsv`. Any failure keeps the worktree and says
  so. The janitor never deletes anything from the archive.
- **The report.** A REMOVABLE worktree holding such files prints
  `    archive on removal: <paths>`.
- **Unchanged:**
  - plain declarations, except that a directory a plain line discounts whole is kept while an
    `archive:` pattern may name a path inside it; an `archive:` pattern discounts files only;
  - the credential rules;
  - every gate and every recheck before a removal;
  - branches, which are never deleted;
  - `--trim-regenerable`, which still removes only built-in regenerable directories and never
    touches an archive-declared file (such a file no longer stops a tree from being trimmed).
- **Older janitors.** An older janitor reads an `archive:` line as a pattern that names no
  path, drops it with a report line, and keeps the file counted.

## Impact

- `shell/worktree-janitor.sh`: `_cc_wj_prepare_base`, `_cc_wj_pins`,
  `_cc_wj_undiscounted_count`, a new `_cc_wj_archivable` and `_cc_wj_archive_files`, the
  report and the removal step, and the usage text.
- Tests: a new section in `tests/worktree-janitor.sh`. No existing case changes.
- Docs: `docs/worktree-reclamation.md` and `CHANGELOG.md`.
- Rollback: revert the commit. Any `archive:` line then keeps its files counted again.
  Existing archive copies stay where they are.
