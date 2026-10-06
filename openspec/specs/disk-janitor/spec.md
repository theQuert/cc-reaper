# disk-janitor Specification

## Purpose

Disk hygiene: hourly read-only free-space + TM-snapshot-pin checks, weekly cleanup of rebuildable-only caches, and gated Time Machine local-snapshot thinning. Chrome code-sign clones are reclaimed behind a separate fail-closed gate, builder cache unused for a week is pruned by the weekly clean, and the hourly check samples configured growth targets within a time budget and flags abnormal growth with the owner of the path that grew.

## Requirements

### Requirement: Chrome code-sign clones are reclaimed only when unheld
The janitor SHALL inspect only directories named `code_sign_clone.<token>` beneath Chrome's exact code-sign clone root. It SHALL keep recent clones, clones with an open handle, and every clone when `lsof` cannot prove a usable inventory. Clean mode SHALL recheck identity and open handles immediately before removal.

#### Scenario: A clone is recent, open, or unprovable
- **WHEN** a clone is recent, has an open handle, or `lsof` cannot prove a usable inventory
- **THEN** it is kept, and clean mode rechecks identity and open handles immediately before removing any other clone

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

### Requirement: TM snapshot pin detection
The janitor SHALL detect when local Time Machine snapshots are pinning freed space (snapshots exist AND disk free % is below the alert threshold) and SHALL surface the finding; thinning (`tmutil deletelocalsnapshots`) runs only in clean mode, never in check mode.

#### Scenario: Hourly check finds pinned space
- **WHEN** the hourly disk check runs, disk free is below threshold, and `tmutil listlocalsnapshots /` returns dated snapshots
- **THEN** a notification suggests snapshot thinning and the snapshot list is logged; nothing is deleted

#### Scenario: Weekly clean thins snapshots
- **WHEN** the weekly clean runs with snapshots present and disk free below threshold
- **THEN** dated local snapshots are deleted via `tmutil deletelocalsnapshots <date>` and freed space is logged

#### Scenario: Disk has ample space
- **WHEN** disk free is above threshold
- **THEN** snapshots are left alone regardless of count

### Requirement: Tool resolution is independent of the caller's environment
The janitor SHALL resolve its cleanup tools from a known set of installation directories
**appended** to `PATH` before any target runs, so that a LaunchAgent and an interactive
shell resolve the same tools. The list SHALL cover where the targets actually install,
including `$HOME/.bun/bin` and `/usr/local/go/bin`, which nothing else covers.

launchd hands an agent `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else unless the plist
sets it. Homebrew and Docker Desktop install outside that set. Resolving through the
inherited environment therefore reports every such tool as absent, which is a property of
the caller and not of the machine.

Appended and not prepended, because whatever the caller put on `PATH` must keep priority:
an operator with their own toolchain, and a test sandbox shimming `docker` so a suite
cannot reach the real daemon. Prepending would step over both, which is the same class of
fault as the one being fixed. Setting `CC_DJ_TOOL_DIRS` empty makes `PATH` the whole
answer, which is how a test simulates a tool that is genuinely not installed.

#### Scenario: Agent runs with launchd's default PATH
- **WHEN** the weekly clean runs from a LaunchAgent whose plist sets no `PATH`
- **THEN** tools installed under the known directories SHALL resolve, and their targets SHALL run

#### Scenario: A tool is genuinely absent
- **WHEN** a tool is installed nowhere on the machine
- **THEN** its target SHALL be skipped and counted as skipped, and the run SHALL NOT fail

#### Scenario: The caller has already put a tool on PATH
- **WHEN** a directory earlier on `PATH` provides a tool that also exists in the known list
- **THEN** the caller's entry SHALL win, so a test stub is never stepped over

#### Scenario: A target's helper interpreter is absent
- **WHEN** a target needs `python3` and macOS has shipped without it
- **THEN** the dependency SHALL be checked before the target runs, and the target SHALL be counted as skipped — a command that exits 127 inside the target is counted as one that ran, so the summary would report `skipped=0` for a run that did not happen

### Requirement: A run that skipped its work cannot report success
The janitor SHALL count targets run and targets skipped, and SHALL state both counts in its
final line. When any target was skipped, the final line SHALL name that fact.

A clean that skipped five of nine targets and a clean that ran all nine both ended on
`clean: finished — disk free=16%`. The distinction an operator needs is exactly the one the
line omitted, and the omission survived weeks of weekly runs.

#### Scenario: Some targets skipped
- **WHEN** a clean finishes having skipped at least one target
- **THEN** the final line SHALL report the run and skip counts

#### Scenario: No targets skipped
- **WHEN** every target resolved and ran
- **THEN** the final line SHALL report a skip count of zero

### Requirement: Per-target freed bytes are measured
Each cleanup target SHALL report the space it actually freed, measured from the volume's
free-space delta across the target — directory removals included, not only command targets.
A target that freed nothing SHALL be distinguishable in the log from a target that freed
gigabytes.

A directory removal SHALL additionally report the directory's `du` size. The two diverge
when a process still holds a deleted file open, because those blocks are not reclaimed until
it closes, and the gap between them is the only place that shows it. Reporting the `du`
figure alone overstates the saving.

#### Scenario: Target frees space
- **WHEN** a target completes and free space increased
- **THEN** the log line for that target SHALL carry the measured delta

#### Scenario: Target frees nothing
- **WHEN** a target completes and free space did not increase
- **THEN** the log line SHALL report zero rather than an unknown

#### Scenario: A removed directory's blocks are still held open
- **WHEN** a directory target removes files another process still holds open
- **THEN** the log SHALL report the `du` size and the measured delta separately, so the unreclaimed blocks are visible rather than counted as freed

### Requirement: Weekly clean prunes long-unused builder cache
When the Docker daemon is reachable, `--clean` SHALL run exactly
`docker builder prune --force --filter until=168h`, which removes only build cache the daemon
reports unused for at least 168 hours and never an image, container or volume. No other code
path SHALL invoke a `docker` command containing `prune`. There SHALL be no separate
builder-cleanup mode, drain proof or protected-container gate.

#### Scenario: Weekly clean with a reachable daemon
- **WHEN** the weekly clean runs and `docker info` succeeds
- **THEN** the janitor invokes `docker builder prune --force --filter until=168h` once and logs its freed bytes like any other target

#### Scenario: Builds are running
- **WHEN** builds hold build cache while the clean runs
- **THEN** the prune still runs, and cache in use or used within the last 168 hours remains

#### Scenario: Daemon unreachable
- **WHEN** docker is not installed or `docker info` fails
- **THEN** the docker step, builder prune included, is logged as skipped and counted, and no docker command runs beyond the reachability probe

### Requirement: Growth targets are sampled within a budget
`--check` SHALL sample the targets in `CC_DJ_GROWTH_TARGETS` (default
`~/.cc-reaper/growth-targets.tsv`, rows `label<TAB>path<TAB>owner[<TAB>alert GB]`). A path
MAY contain glob wildcards, and each matching directory SHALL be its own key; `docker:<type>`
SHALL read that category from one `docker system df` call and `docker:volumes/*` SHALL read
each volume from one `docker system df -v` call. A key SHALL be measured at most once per
`CC_DJ_GROWTH_INTERVAL_HOURS` (default 6), never-measured and oldest keys first, at low
priority, and no measurement SHALL start after `CC_DJ_GROWTH_BUDGET_SECONDS` (default 240)
have elapsed in the run. Each sample SHALL be appended to `state/growth-samples.tsv` as
`<epoch>\t<key>\t<KiB or status>`, and samples older than 14 days SHALL be dropped.

#### Scenario: A due key is measured
- **WHEN** a key's newest sample is older than the interval and budget remains
- **THEN** it is measured and one sample line is appended

#### Scenario: The budget runs out
- **WHEN** the budget is spent with due keys remaining
- **THEN** no further measurement starts, and the run logs how many keys wait for a later run

#### Scenario: A target cannot be read
- **WHEN** a path is denied, vanished, or its measurement exceeds the per-key timeout
- **THEN** the sample records `denied`, `absent` or `timeout`, never a size of zero

#### Scenario: No targets are configured
- **WHEN** the targets file is missing or empty
- **THEN** the step measures nothing and logs that no growth targets are configured

### Requirement: Abnormal growth is flagged with its owner
After sampling, for every key and every label total with a numeric current sample, growth
SHALL be computed against the newest numeric sample at least `CC_DJ_GROWTH_WINDOW_HOURS`
(default 24) old, or, when none exists, the oldest numeric sample at least 3 hours old. A
label total SHALL be recorded only when every current member has a numeric sample. When
growth reaches the row's alert GB (default `CC_DJ_GROWTH_ALERT_GB`, 5), the janitor SHALL
log `ALERT:growth key=<key> owner=<owner> +<GB>GB in <hours>h now=<GB>GB` and post one
`growth` notification per cooldown. Every run that sampled SHALL log its three largest
growers.

#### Scenario: One worktree grows by six gigabytes in a day
- **WHEN** a worktree key measured 2 GB a day ago measures 8 GB now
- **THEN** an `ALERT:growth` line names that key, its owner and `+6.0GB`, and one notification is posted unless one was within the cooldown

#### Scenario: Growth under the threshold
- **WHEN** every key and total grew by less than its alert GB
- **THEN** no alert is logged and the top growers are still logged

#### Scenario: No comparable baseline
- **WHEN** a key has no numeric sample at least 3 hours old
- **THEN** no growth is computed for it and no alert is raised

#### Scenario: A member of a total is not yet measured
- **WHEN** a glob target has a member with no numeric sample
- **THEN** no total is recorded for that label in this run

#### Scenario: python3 is unavailable
- **WHEN** `python3` cannot be found
- **THEN** the growth step is logged as `SKIP` and counted, and the rest of the check runs

### Requirement: The go build cache is trimmed by age, never emptied
The weekly clean SHALL delete only go build cache entries - files named `*-a` or `*-d` in the two-hex-digit subdirectories of the directory `go env GOCACHE` reports - whose modification time is older than `CC_DJ_GO_CACHE_TRIM_DAYS` days (default 3). Go refreshes an entry's modification time when it uses the entry, so this is the rule Go applies itself after five days, applied sooner. The janitor SHALL NOT run `go clean -cache`, and SHALL NOT delete the cache's top-level files (`README`, `trim.txt`, `testexpire.txt`). While a `go build`, `go test`, `go run`, `go vet`, `go install` or `go generate`, or a toolchain `compile`, `link`, `asm` or `cgo` process is running, the target SHALL remove nothing and be logged as `SKIP` and counted.

#### Scenario: Old and recent entries
- **WHEN** the weekly clean runs, no go build is running, and the cache holds entries last used 10 days and 1 hour ago
- **THEN** the 10-day-old entries are deleted, the recent entries and the top-level files are kept, and freed bytes are logged

#### Scenario: A build is running
- **WHEN** a go build or test process is running as the clean starts
- **THEN** no cache entry is deleted, and the target is logged as `SKIP` and counted

#### Scenario: The cache cannot be located
- **WHEN** `go` is absent, or `go env GOCACHE` does not print an absolute path (for example `off`)
- **THEN** nothing is deleted and the target is logged as `SKIP` and counted

#### Scenario: An unusable retention
- **WHEN** `CC_DJ_GO_CACHE_TRIM_DAYS` is not a positive whole number and not `off`
- **THEN** nothing is deleted and the target is logged as `SKIP` naming the value

#### Scenario: Another reclaimer owns the cache
- **WHEN** `CC_DJ_GO_CACHE_TRIM_DAYS` is `off`
- **THEN** nothing is deleted, `go` is not run, and the janitor logs that another reclaimer owns the cache; it is not a `SKIP`

### Requirement: The hourly check reclaims only proved-abandoned host temp items
The hourly check SHALL measure, alert and then reclaim only the items the requirements below name. It SHALL NOT remove images, containers, volumes, or any path outside the user's temp directory, Chrome's code-sign clone root and the wrangler log directory. `CC_DJ_HOST_TEMP_REAP=0` SHALL turn off the host temp step.

#### Scenario: Disk below threshold at hourly check
- **WHEN** the hourly check finds disk free < threshold
- **THEN** it posts one (cooldown-gated) notification recommending `disk-janitor --clean`, logs the measurement, and still runs the reclaim steps

#### Scenario: The host temp step is turned off
- **WHEN** `CC_DJ_HOST_TEMP_REAP=0`
- **THEN** the host temp reclaimer does not run

### Requirement: An orphaned headless Chrome is stopped only when abandoned
The reclaimer SHALL send `SIGTERM`, and nothing stronger, only to a process for which all of the following hold:
- it is the Chrome browser binary, not a Helper;
- it runs with `--headless` and `--remote-debugging-port`;
- its `--user-data-dir` is directly under the user's temp directory;
- its parent is launchd;
- it has run for at least the idle limit;
- `lsof` shows it listening and shows no established connection on any of those ports.

It SHALL recheck the pid's command immediately before signalling. A failed or inconclusive probe SHALL keep the process.

#### Scenario: A launcher died and left its browser
- **WHEN** a headless Chrome with a temp profile is reparented to launchd, has run for two hours, and has no DevTools client
- **THEN** it receives `SIGTERM`

#### Scenario: A browser still in use
- **WHEN** the browser's launcher is alive, or a DevTools client is connected, or it is younger than the idle limit, or its profile is not in the temp directory
- **THEN** it is not signalled

#### Scenario: The pid changed between scan and signal
- **WHEN** the pid's command differs at the recheck
- **THEN** it is not signalled

### Requirement: Unreferenced cdp profiles and idle wrangler logs are removed
The reclaimer SHALL remove a directory named `cdp-` plus six alphanumerics, directly under the user's temp directory and not a symlink, only when all of these hold:
- no running process names it as `--user-data-dir`;
- `lsof` shows no holder;
- it has not changed for the idle limit.

It SHALL remove a file named `wrangler-<timestamp>.log` in `~/Library/Preferences/.wrangler/logs` only when it has not been written for the idle limit and `lsof` shows no holder. The idle limit SHALL be at least 30 minutes.

#### Scenario: A profile whose browser is gone
- **WHEN** a `cdp-XXXXXX` profile is two hours old, unnamed and unheld
- **THEN** it is removed

#### Scenario: A profile or log still in use
- **WHEN** a profile is named by a running process, held open, or recently changed, or a log is being written or held open
- **THEN** it is kept

### Requirement: Builder cache unused for a day is pruned at most once a day
Once per 24 hours, and only when the daemon answers, the hourly check SHALL run `docker builder prune --force --filter until=<CC_DJ_BUILDER_PRUNE_UNTIL>` (default `24h`). `off` SHALL turn it off.

#### Scenario: Two checks on the same day
- **WHEN** the check runs twice within 24 hours
- **THEN** the builder prune runs only on the first

### Requirement: Code-sign clones are reclaimed after one day
Both the hourly check and the weekly clean SHALL remove unheld code-sign clones older than `CC_DJ_CHROME_CLONE_MIN_AGE_DAYS` (default 1).

#### Scenario: A day-old unheld clone
- **WHEN** a clone is older than one day and no process holds it
- **THEN** the next hourly check removes it

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
