## ADDED Requirements

### Requirement: A path a launchd agent names is held
The janitor SHALL add to the holder scan every absolute path that appears as a string value in a
`*.plist` file of the directories named by `CC_WJ_LAUNCHD_DIRS` (colon-separated, default
`$HOME/Library/LaunchAgents`, empty for none), by either its written or its physical spelling.
A worktree at or under such a path SHALL be held. A plist that cannot be read, or a missing
`plutil`, SHALL add nothing and SHALL NOT fail the scan.

#### Scenario: A scheduled job's script lives in the worktree
- **WHEN** a landed, clean, idle worktree contains a path that a launchd agent plist names, and no process currently holds it
- **THEN** it is classified KEEP with reason `active-session`

#### Scenario: The plist names another path
- **WHEN** the same worktree is judged and the plist names a path outside it
- **THEN** it is classified REMOVABLE, as before

#### Scenario: An unreadable plist
- **WHEN** a plist in the directory is not a valid property list
- **THEN** the holder scan still succeeds and the worktree is judged as if the plist were absent
