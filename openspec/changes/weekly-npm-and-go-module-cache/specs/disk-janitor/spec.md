## ADDED Requirements

### Requirement: The weekly clean empties the npm content cache unless an install is running
The weekly clean SHALL run `npm cache clean --force` with the user's npm. While an `npm install`,
`npm i`, `npm ci`, `npm update` or `npm add` process is running, it SHALL run nothing and log the
target as `SKIP` and count it. `CC_DJ_NPM_CACHE=off` SHALL turn the target off without a `SKIP`.

#### Scenario: No install running
- **WHEN** the weekly clean runs and no npm install is running
- **THEN** `npm cache clean --force` runs and freed bytes are logged

#### Scenario: An install is running
- **WHEN** an `npm ci` process is running as the clean starts
- **THEN** the npm cache is not touched and the target is logged as `SKIP` and counted

#### Scenario: npm is absent
- **WHEN** `npm` cannot be resolved
- **THEN** nothing is removed and the target is logged as `SKIP` and counted

### Requirement: Unused npx installs are removed by age
The weekly clean SHALL remove a direct child of `~/.npm/_npx` only when nothing under it was
modified within `CC_DJ_NPX_TRIM_DAYS` days (default 14) and no running process's command line or
working directory contains its path. A process listing that fails SHALL remove nothing. A value
that is not a positive whole number and not `off` SHALL remove nothing and log `SKIP` naming it.

#### Scenario: An old, unused install
- **WHEN** an `_npx` entry was last modified 30 days ago and no process names it
- **THEN** it is removed and freed bytes are logged

#### Scenario: A long-running MCP server uses an old install
- **WHEN** an `_npx` entry is 30 days old and a running process's command line contains its path
- **THEN** it is kept

#### Scenario: A recent install
- **WHEN** an `_npx` entry was modified within the window
- **THEN** it is kept

### Requirement: The Go module cache is emptied only under disk pressure while no Go build runs
The weekly clean SHALL run `go clean -modcache` only when the data volume's free space is below
`CC_DJ_DISK_MIN_PCT` percent and no `go build`, `go test`, `go run`, `go vet`, `go install`,
`go generate`, `go mod`, or toolchain `compile`, `link`, `asm` or `cgo` process is running. Above
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
