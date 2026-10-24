## ADDED Requirements

### Requirement: Two pins on probation
The janitor SHALL recognise two ignored entries as discountable: a regular file, not a
symlink and not credential-shaped, at the top level of the worktree whose name ends in `.log`
(rule `top-level-log`); and a symlink at `.claude/skills` or `.claude/commands` whose target,
absolute or relative to `.claude/`, lies inside the repository's own primary checkout (rule
`primary-skills-link`). They SHALL be asked only after every built-in and declared discount has
declined the entry, after `archive:`.

When `CC_WJ_NEW_RULES_MODE` is exactly `auto`, the contents gate SHALL discount them, in the
inventory and in every recheck before a removal. Otherwise (`spotcheck`, the default) they SHALL
be pinned as before, and a worktree whose every pin is one of them SHALL be judged through every
other gate as if they were discounted, without changing its classification, its removal, or its
trim. Each removal or directory trim that judgement would make SHALL be appended to
`CC_WJ_SPOTCHECK_LOG` as one line naming the run id, phase, action, rule, path, bytes and holder
result, and the report SHALL add one `spotcheck:` line for that worktree.

#### Scenario: A log alone, in auto
- **WHEN** a landed, idle, unheld, unclaimed worktree's only undiscounted entry is `!! next-manual.log` and the mode is `auto`
- **THEN** it is REMOVABLE and `--apply` removes it, leaving its branch

#### Scenario: A log alone, in spotcheck
- **WHEN** the same worktree is judged with the mode unset
- **THEN** it is `KEEP(unrebuildable=1)` as before, nothing is removed, and the spot-check log has a `phase=removal action=would-remove rule=top-level-log` line for it

#### Scenario: A link outside the primary checkout
- **WHEN** `.claude/skills` links anywhere outside the repository's primary checkout
- **THEN** it keeps the worktree in either mode

#### Scenario: An unlanded tree's cache
- **WHEN** an unlanded, idle, unheld worktree whose only pin is a top-level log holds an ignored `node_modules`, under `--trim-regenerable --apply`
- **THEN** in `auto` the directory is trimmed and the worktree, its log and its commits remain; in `spotcheck` the directory remains and a `phase=trim action=would-trim` line names it

#### Scenario: Held during a spot check
- **WHEN** such a worktree is held by a process
- **THEN** it is kept, and nothing is logged for it

### Requirement: Names nothing may touch
The janitor SHALL keep, as `KEEP(deny-listed:<name>)`, every worktree whose directory name or
branch contains a name in the whitespace-separated `CC_WJ_DENY_NAMES`, or at or under which a
live Claude session registered under such a name stands, in the removal sweep and in the trim,
before any other gate is asked.

#### Scenario: Deny-listed by name
- **WHEN** a landed, clean, unheld worktree named `wt-homepage-bento` holds `node_modules` and `homepage` is listed
- **THEN** `--apply` keeps it and `--trim-regenerable --apply` keeps its `node_modules`

#### Scenario: Deny-listed by a session
- **WHEN** a live Claude session whose registry name is `uiux` stands in a worktree and `uiux` is listed
- **THEN** that worktree is `KEEP(deny-listed:session uiux)`

### Requirement: Nothing to trim is answered first
In the trim phase the janitor SHALL list a worktree's regenerable directories before its claim
lookups, git-state probe and idle walk, and SHALL move to the next worktree when the listing
succeeds and names none. A listing that fails SHALL take the full path, which keeps the
worktree with its reason.

#### Scenario: A tree with no cache under pressure
- **WHEN** the trim runs under disk pressure over a worktree with no regenerable directory
- **THEN** it reports `TRIM_RESULT count=0` and walks none of that worktree's files
