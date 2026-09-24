## ADDED Requirements

### Requirement: An archive declaration copies a record out before a removal
The janitor SHALL read lines of the form `archive:<pattern>` from `.worktree-regenerable` on the
fetched base. It SHALL ignore whitespace and leading `/` after the prefix, and apply to the
pattern the rules every other line follows. A pattern that names no path SHALL be dropped and
reported with its `archive:` prefix. An `archive:` line SHALL NOT declare anything regenerable.

An ignored entry that git lists as a file SHALL NOT count as unrebuildable content only when
all of the following hold:
- it matches an `archive:` pattern, which is asked before any plain declaration naming the
  same file;
- it is a regular file, not a symlink;
- it is not credential-shaped;
- its name holds no tab or newline;
- its size is at most `CC_WJ_ARCHIVE_MAX_BYTES`, which defaults to 1048576.

A matching file that fails any of these SHALL keep the worktree, and the report SHALL name the
condition that failed. An ignored directory that a plain declaration would discount whole SHALL
keep the worktree when the text of some `archive:` pattern before its first wildcard is empty,
is a prefix of the directory's path followed by `/`, or begins with that path followed by `/`,
or when that cannot be determined, and the report SHALL say so. A value of `CC_WJ_ARCHIVE_MAX_BYTES` that is not a decimal integer SHALL
make no file archivable.

With `--apply`, after every recheck and immediately before removing a worktree, the janitor
SHALL copy each such file into a directory it creates for this removal:
`<CC_WJ_ARCHIVE_DIR>/<repository directory name>/<worktree directory name>-<UTC time>.<random>/<the file's relative path>`,
where the repository directory name is that of the repository's resolved path.
`CC_WJ_ARCHIVE_DIR` defaults to `~/.cc-reaper/archive`. The janitor SHALL take the list of
files from the same status read as the unrebuildable-content recheck. It SHALL compare every
copy byte for byte with its source, and SHALL append one row to
`<CC_WJ_ARCHIVE_DIR>/index.tsv` naming the time, the worktree, its branch, its HEAD and the
directory. If any step fails, the janitor SHALL keep the worktree and say so. The janitor SHALL
NOT delete anything from the archive.

For a REMOVABLE worktree holding such files, the report SHALL print
`    archive on removal: <paths>`.

#### Scenario: A worktree whose only content is a declared record
- **WHEN** a landed, clean, idle, unheld and unclaimed worktree's only ignored content is files matched by `archive:` patterns
- **THEN** it is classified REMOVABLE, and the report lists those files on an `archive on removal:` line
- **AND** `--apply` copies them into a new archive directory, the copies are byte-identical, `index.tsv` gains a row naming the worktree and that directory, the worktree is removed, and its branch remains

#### Scenario: A file that is not copied
- **WHEN** a file matched by an `archive:` pattern is larger than `CC_WJ_ARCHIVE_MAX_BYTES`, has a credential-shaped name, or is a symlink
- **THEN** the worktree is classified `KEEP(unrebuildable=<n>)`, and the report names the file and the condition it failed

#### Scenario: A record a plain declaration also names
- **WHEN** a plain pattern (`*.log`) and an `archive:` pattern (`keep.log`) both name an archivable ignored file
- **THEN** the file is copied before the removal, and a file only the plain pattern names is discounted without a copy

#### Scenario: A declared directory an archive: pattern may reach into
- **WHEN** a plain declaration names an ignored directory (`logs`) and an `archive:` pattern may name a path inside it (`logs/notes.md`, `*.md`)
- **THEN** the directory keeps the worktree, and the report says an `archive:` pattern may name a path inside it

#### Scenario: An unusable size limit
- **WHEN** `CC_WJ_ARCHIVE_MAX_BYTES` is not a decimal integer
- **THEN** no file is archivable, and the report says why

#### Scenario: A pattern that names no path
- **WHEN** an `archive:` line's pattern names no path (`archive:*`)
- **THEN** it is dropped, and the run reports it with its prefix

#### Scenario: A record written after the scan
- **WHEN** an archivable file appears in a REMOVABLE worktree between the inventory and the removal
- **THEN** it is copied with the others before the removal

#### Scenario: The copy cannot be made
- **WHEN** the archive directory cannot be created, or a copy differs from its source
- **THEN** the worktree is kept, and the report says archiving failed
