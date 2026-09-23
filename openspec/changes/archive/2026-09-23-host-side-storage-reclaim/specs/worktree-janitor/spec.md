## ADDED Requirements

### Requirement: Tools resolve under a minimal PATH
When executed, the janitor SHALL append each directory in `CC_WJ_TOOL_DIRS` (default
`/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`) that exists and is not already on PATH, and
SHALL NOT prepend them. When `gh` still does not resolve, the run SHALL say once that landing by
a merged pull request cannot be proven. Sourcing the file SHALL NOT change the caller's PATH.

#### Scenario: Scheduled run under launchd
- **WHEN** the LaunchAgent runs the janitor with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and `gh` is installed in a listed directory
- **THEN** `gh` resolves, and a worktree whose exact head a merged pull request delivered can be shown `landed=pr`

#### Scenario: gh is not installed
- **WHEN** `gh` resolves nowhere
- **THEN** the run prints one line saying landing by a merged pull request cannot be proven, and such worktrees stay kept

#### Scenario: The caller's tool comes first
- **WHEN** PATH already holds a `gh` ahead of the listed directories
- **THEN** that `gh` is the one used

## MODIFIED Requirements

### Requirement: Session mode
`worktree-janitor --session` SHALL return immediately and run the inventory detached for the
repository containing the hook payload cwd, `CODEX_PROJECT_DIR`, `CLAUDE_PROJECT_DIR`, or the
working directory, so that one deployed entrypoint can serve Claude and Codex SessionEnd.

#### Scenario: Detaching
- **WHEN** `--session` is invoked
- **THEN** the invoking process exits 0 without waiting for the sweep, and the sweep runs in a new session whose process group is not the caller's

#### Scenario: Hook input
- **WHEN** the launcher's stdin is not a terminal
- **THEN** it reads the hook input until end of input or a two-second stall, keeping what arrived before a stall and at most 8192 characters; unless the input fits that bound and contains exactly one `"cwd"` whose value parses to an absolute path that still resolves, the sweep reports only and says why

#### Scenario: The session's own checkout
- **WHEN** the session's project directory, or the `cwd` its SessionEnd hook input names, is at or under a linked worktree
- **THEN** that worktree is classified KEEP with reason `this-session`

#### Scenario: Concurrent sweeps
- **WHEN** a removal sweep of a repository starts while another live `worktree-janitor` holds that repository's lock
- **THEN** it removes nothing in that repository and logs that it deferred to the sweep holding the lock, and that deferral alone does not make the run exit non-zero; a lock that cannot be taken for any other reason still does. A lock whose pid is dead or no longer runs the command that took it, or untouched for more than 60 minutes, is taken over, and a sweep refreshes its lock on every removal

#### Scenario: Run record
- **WHEN** a session sweep runs
- **THEN** its log records a start line with an ISO-8601 time and the repository, and an end line with elapsed seconds and the data volume's free space before and after

#### Scenario: Not a repository
- **WHEN** the session's directory is not inside a git repository
- **THEN** the sweep logs that and exits without scanning
