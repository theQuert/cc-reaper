# disk-janitor Specification

## Purpose

Disk hygiene: hourly read-only free-space + TM-snapshot-pin checks, weekly cleanup of rebuildable-only caches, and gated Time Machine local-snapshot thinning. Chrome code-sign clones are reclaimed behind a separate fail-closed gate, and builder cache unused for a week is pruned by the weekly clean.

## Requirements

### Requirement: Chrome code-sign clones are reclaimed only when unheld
The janitor SHALL inspect only directories named `code_sign_clone.<token>` beneath Chrome's exact code-sign clone root. It SHALL keep recent clones, clones with an open handle, and every clone when `lsof` cannot prove a usable inventory. Clean mode SHALL recheck identity and open handles immediately before removal.

#### Scenario: A clone is recent, open, or unprovable
- **WHEN** a clone is recent, has an open handle, or `lsof` cannot prove a usable inventory
- **THEN** it is kept, and clean mode rechecks identity and open handles immediately before removing any other clone

### Requirement: Rebuildable-only cleanup targets
The janitor SHALL clean only artifacts that rebuild automatically on next use: go-build cache (`go clean -cache`), Yarn cache, pip cache, Homebrew cleanup, bun install cache, Spotify cache, ShipIt updater cache, and CoreSimulator caches. Docker images and volumes SHALL be reported and never removed. No code path SHALL run `docker rmi`, `docker image rm` or `docker volume rm`, and no `docker` invocation SHALL contain `prune` other than the weekly `docker builder prune --force --filter until=168h`, which removes only build cache unused for a week. `docker system prune -af` removes every image not held by a running container, which on a development host includes images that take hours to rebuild and pinned versions kept deliberately; a tool whose stated contract is "rebuilds automatically on next use" cannot reach them. The janitor SHALL NEVER touch user-data paths (`~/Documents`, `~/Downloads`, `~/Desktop`) or editor state (`~/.cursor/extensions`).

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

### Requirement: Hourly threshold check is read-only
The hourly disk check SHALL only measure and alert (disk free %, top growable dirs summary, snapshot pin state); it SHALL NOT delete anything.

#### Scenario: Disk below threshold at hourly check
- **WHEN** the hourly check finds disk free < threshold
- **THEN** it posts one (cooldown-gated) notification recommending `disk-janitor --clean` and logs the measurement, deleting nothing

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
