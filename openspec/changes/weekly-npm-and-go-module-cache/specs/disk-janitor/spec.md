## ADDED Requirements

### Requirement: The weekly clean empties the npm content cache unless an install is running
The weekly clean SHALL run `npm cache clean --force` with the user's npm. While an npm process
that reifies (`install`, `i`, `ci`, `update`, `add`, and their aliases `it`, `cit`, `install-test`,
`install-ci-test`, `clean-install`, `ic`, `up`, `upgrade`) is running, or any process holds a file
open under `~/.npm/_cacache`, or the open-file listing fails, it SHALL run nothing and log the
target as `SKIP` and count it. `CC_DJ_NPM_CACHE=off` SHALL turn the target off without a `SKIP`.

#### Scenario: No install running
- **WHEN** the weekly clean runs and no npm install is running
- **THEN** `npm cache clean --force` runs and freed bytes are logged

#### Scenario: An install is running
- **WHEN** an `npm ci` process is running as the clean starts
- **THEN** the npm cache is not touched and the target is logged as `SKIP` and counted

#### Scenario: An npx cold start is writing the cache
- **WHEN** an `npm exec` process holds a file open under `~/.npm/_cacache`
- **THEN** the npm cache is not touched and the target is logged as `SKIP` and counted

#### Scenario: npm is absent
- **WHEN** `npm` cannot be resolved
- **THEN** nothing is removed and the target is logged as `SKIP` and counted

### Requirement: Unused npx installs are removed by age
The weekly clean SHALL remove a direct child of `~/.npm/_npx` only when nothing under it was
modified within `CC_DJ_NPX_TRIM_DAYS` days (default 14) and no running process's command line,
working directory or open file is inside it. Each entry SHALL be rechecked immediately before
it is removed, and removed by first renaming it out of `~/.npm/_npx` in one step, so a later
npx sees it absent rather than half removed. A process or open-file listing that fails SHALL
remove nothing. A value
that is not a positive whole number and not `off` SHALL remove nothing and log `SKIP` naming it.

#### Scenario: An old, unused install
- **WHEN** an `_npx` entry was last modified 30 days ago and no process names it
- **THEN** it is removed and freed bytes are logged

#### Scenario: A long-running MCP server uses an old install
- **WHEN** an `_npx` entry is 30 days old and a running process's command line contains its path
- **THEN** it is kept

#### Scenario: A native binary from the install is running
- **WHEN** an `_npx` entry is 30 days old and a running process has a file inside it open, though no command line names it
- **THEN** it is kept

#### Scenario: A recent install
- **WHEN** an `_npx` entry was modified within the window
- **THEN** it is kept

### Requirement: The Go module cache is emptied only under disk pressure while no Go build runs
The weekly clean SHALL run `go clean -modcache` only when the data volume's free space is below
`CC_DJ_DISK_MIN_PCT` percent and no `go build`, `go test`, `go run`, `go vet`, `go install`,
`go generate`, `go mod`, `go get`, `go list` or `go work` process (also with `-C <dir>` before the
subcommand), no `gopls`, and no toolchain `compile`, `link`, `asm` or `cgo` process is running. Above
the threshold the target SHALL do nothing and log why, not as a `SKIP`. While such a process is
running it SHALL do nothing and log the target as `SKIP` and count it. `CC_DJ_GO_MODCACHE=off`
SHALL turn the target off.

#### Scenario: Pressure and no build
- **WHEN** free space is below the threshold and no Go process is running
- **THEN** `go clean -modcache` runs and freed bytes are logged

#### Scenario: No pressure
- **WHEN** free space is at or above the threshold
- **THEN** the module cache is not touched

#### Scenario: A build is running under pressure
- **WHEN** free space is below the threshold and a `go test` process is running
- **THEN** the module cache is not touched and the target is logged as `SKIP` and counted

## MODIFIED Requirements

### Requirement: Rebuildable-only cleanup targets
The janitor SHALL clean only artifacts that rebuild automatically on next use: go-build cache entries unused for `CC_DJ_GO_CACHE_TRIM_DAYS` days (never the whole cache), Yarn cache, pip cache, Homebrew cleanup, bun install cache, the npm content cache, npx installs unused for `CC_DJ_NPX_TRIM_DAYS` days, the Go module cache under disk pressure, Spotify cache, ShipIt updater cache, and CoreSimulator caches. Docker images and volumes SHALL be reported and never removed. No code path SHALL run `docker rmi`, `docker image rm` or `docker volume rm`, and no `docker` invocation SHALL contain `prune` other than the weekly `docker builder prune --force --filter until=168h`, which removes only build cache unused for a week. `docker system prune -af` removes every image not held by a running container, which on a development host includes images that take hours to rebuild and pinned versions kept deliberately; a tool whose stated contract is "rebuilds automatically on next use" cannot reach them. The janitor SHALL NEVER touch user-data paths (`~/Documents`, `~/Downloads`, `~/Desktop`) or editor state (`~/.cursor/extensions`).

#### Scenario: Weekly deep clean runs
- **WHEN** the weekly launchd agent fires the janitor in clean mode
- **THEN** each available target is cleaned, each skipped target is logged as `SKIP` and counted, and per-target freed bytes are measured and logged

#### Scenario: Docker daemon not running
- **WHEN** docker is not reachable
- **THEN** the docker step logs `SKIP docker (daemon unreachable)`, counts as skipped, and the remaining targets still run

#### Scenario: Dangling images present on a shared host
- **WHEN** the clean runs and `docker images -f dangling=true` lists images
- **THEN** it logs how many there are and the command that lists them, and removes none

#### Scenario: Image inventory fails
- **WHEN** `docker images` exits non-zero
- **THEN** the report says nothing was examined, and the target is not reported as clean

#### Scenario: An image is unused but expensive
- **WHEN** an image carries a tag and is held by no container
- **THEN** it SHALL be left alone, as every image is

#### Scenario: A volume looks docker-generated and is unreferenced
- **WHEN** a volume's name is a 64-character hex string and no container references it
- **THEN** it SHALL be reported with the command to review it, and SHALL NOT be removed — `docker volume create` accepts such a name from anyone and `docker volume inspect` exposes no flag separating a daemon-created volume from a user-created one, so the name cannot establish provenance and an unreferenced volume is not an abandoned one

#### Scenario: Any volume at all
- **WHEN** the docker cleanup target runs
- **THEN** no code path SHALL invoke `docker volume rm`

#### Scenario: Forbidden flags are structurally absent
- **WHEN** the janitor source is inspected
- **THEN** it contains no `docker rmi`, `docker image rm` or `docker volume rm`, no `docker` invocation containing `prune` other than `docker builder prune --force --filter until=168h`, and no cleanup target resolving inside user-data paths

#### Scenario: Weekly builder cache prune
- **WHEN** the weekly clean runs with a reachable daemon
- **THEN** only builder cache unused for at least 168 hours is pruned, through `docker builder prune --force --filter until=168h`, and no image, container or volume is removed
