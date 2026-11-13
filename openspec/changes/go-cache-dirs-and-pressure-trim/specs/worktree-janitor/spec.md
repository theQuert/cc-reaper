## ADDED Requirements

### Requirement: Disk pressure trims a dirty idle tree after six hours
The shipped configuration SHALL list `dirty-pressure` in `CC_WJ_PROMOTED_RULES` and set
`CC_WJ_TRIM_DIRTY_IDLE_HOURS_PRESSURE` to 6. Under disk pressure a worktree with uncommitted files that
no process holds, no live session claims, no inbound `node_modules` link points into, and that has
had no write outside its regenerable directories for six hours SHALL lose those regenerable
directories to `--trim-regenerable --apply`. Its uncommitted files, the worktree and its branch SHALL
remain. The trim summary SHALL report the free-space change of the volume (`df-freed`) beside the `du`
figure it reclaimed.

#### Scenario: Dirty, idle, unheld
- **WHEN** a tree with an uncommitted file has been idle for eight hours under pressure
- **THEN** its `node_modules` is removed and its file, worktree and branch remain

#### Scenario: Held or linked
- **WHEN** a process holds the tree, or another worktree's `node_modules` link resolves into it
- **THEN** its regenerable directories are kept

### Requirement: A deny-listed tree is kept for removal and trimmed like any other
`CC_WJ_DENY_NAMES` SHALL keep a named tree from being removed. It SHALL NOT keep the tree out of
`--trim-regenerable`, which keeps the worktree, its branch and every authored file: the trim asks every
gate it asks of any tree, and a live session of a deny-listed name is a holder there.

#### Scenario: Named tree, no holder
- **WHEN** a tree whose name contains a deny-listed name has no holder and a trim runs
- **THEN** its regenerable directories are removed and the removal report still says `KEEP(deny-listed:<name>)`

#### Scenario: Named tree, live session
- **WHEN** a live session of a deny-listed name stands in the tree
- **THEN** its regenerable directories are kept
