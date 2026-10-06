## ADDED Requirements

### Requirement: An orphaned esbuild service is stopped
In `apply` mode the dev-server reaper SHALL stop a process for which all of the following hold,
and in `report` mode SHALL report it and signal nothing:
- its executable path ends in `/node_modules/…/@esbuild/<platform>/bin/esbuild` or
  `/node_modules/.bin/esbuild`, and its arguments include `--service`;
- its parent is launchd;
- it has no child process and no listening or connected socket;
- no other live process shares its process group, or none that does is an agent or a launcher;
- it has run for at least the reaper's minimum age;
- its working directory is inside a linked worktree, not a primary checkout, and that worktree
  has no live claim.

It SHALL be signalled by pid with the reaper's existing stop path, which rechecks the process
start time before each signal. A failed or inconclusive probe SHALL keep the process.

#### Scenario: A wrangler dev died and left its esbuild
- **WHEN** an esbuild `--service` process in a linked worktree is reparented to launchd, older than the minimum age, alone in its process group, with no socket
- **THEN** in `apply` mode it is stopped, and in `report` mode it is reported and not signalled

#### Scenario: Its dev server is still alive
- **WHEN** the esbuild service's parent is not launchd, or a launcher or agent shares its process group
- **THEN** it is not signalled

#### Scenario: Not abandoned enough
- **WHEN** it is younger than the minimum age, has a socket, has a child, runs in a primary checkout, or its worktree has a live claim
- **THEN** it is not signalled

#### Scenario: A probe fails
- **WHEN** the process, socket, working-directory or claim probe fails or times out
- **THEN** it is not signalled
