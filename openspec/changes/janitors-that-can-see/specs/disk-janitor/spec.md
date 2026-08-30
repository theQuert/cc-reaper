## ADDED Requirements

### Requirement: Tool resolution is independent of the caller's environment
The janitor SHALL resolve its cleanup tools from a known set of installation directories
prepended to `PATH` before any target runs, so that a LaunchAgent and an interactive shell
resolve the same tools.

launchd hands an agent `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else unless the plist
sets it. Homebrew and Docker Desktop install outside that set. Resolving through the
inherited environment therefore reports every such tool as absent, which is a property of
the caller and not of the machine.

#### Scenario: Agent runs with launchd's default PATH
- **WHEN** the weekly clean runs from a LaunchAgent whose plist sets no `PATH`
- **THEN** tools installed under the known directories SHALL resolve, and their targets SHALL run

#### Scenario: A tool is genuinely absent
- **WHEN** a tool is installed nowhere on the machine
- **THEN** its target SHALL be skipped and counted as skipped, and the run SHALL NOT fail

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

## MODIFIED Requirements

### Requirement: Rebuildable-only cleanup targets
The janitor SHALL clean only artifacts that rebuild automatically on next use: go-build
cache (`go clean -cache`), Yarn cache, pip cache, Homebrew cleanup, bun install cache,
Spotify cache, ShipIt updater cache, CoreSimulator caches, and dangling docker images — those
no tag points at.

The janitor SHALL NOT invoke any `prune` verb. `docker system prune -af` removes every
image not currently held by a running container, which on a development host includes
images that take hours to rebuild and pinned versions kept deliberately; a tool whose
stated contract is "rebuilds automatically on next use" cannot reach them. Docker
artifacts SHALL be removed by explicit id or name, computed from the current inventory.

The janitor SHALL NEVER touch user-data paths (`~/Documents`, `~/Downloads`, `~/Desktop`)
or editor state (`~/.cursor/extensions`).

#### Scenario: Weekly deep clean runs
- **WHEN** the weekly launchd agent fires the janitor in clean mode
- **THEN** each available target is cleaned, each skipped target is logged as `SKIP` and counted, and per-target freed bytes are measured and logged

#### Scenario: Docker daemon not running
- **WHEN** docker is not reachable
- **THEN** the docker step logs `SKIP docker (daemon unreachable)`, counts as skipped, and the remaining targets still run

#### Scenario: An image is unused but expensive
- **WHEN** an image carries a tag and is held by no container
- **THEN** it SHALL be left alone, because only dangling images are removable

#### Scenario: A volume looks docker-generated and is unreferenced
- **WHEN** a volume's name is a 64-character hex string and no container references it
- **THEN** it SHALL be reported with the command to review it, and SHALL NOT be removed — `docker volume create` accepts such a name from anyone and `docker volume inspect` exposes no flag separating a daemon-created volume from a user-created one, so the name cannot establish provenance and an unreferenced volume is not an abandoned one

#### Scenario: Any volume at all
- **WHEN** the docker cleanup target runs
- **THEN** no code path SHALL invoke `docker volume rm`

#### Scenario: Forbidden verbs are structurally absent
- **WHEN** the janitor source is inspected
- **THEN** no code path SHALL produce a `docker` invocation containing `prune`, and no cleanup target SHALL resolve inside user-data paths

### Requirement: Per-target freed bytes are measured
Each cleanup target SHALL report the space it actually freed, measured from the volume's
free-space delta across the target. A target that freed nothing SHALL be distinguishable in
the log from a target that freed gigabytes.

#### Scenario: Target frees space
- **WHEN** a target completes and free space increased
- **THEN** the log line for that target SHALL carry the measured delta

#### Scenario: Target frees nothing
- **WHEN** a target completes and free space did not increase
- **THEN** the log line SHALL report zero rather than an unknown
