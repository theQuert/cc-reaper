# disk-janitor Specification (delta)

## ADDED Requirements

### Requirement: Rebuildable-only cleanup targets
The janitor SHALL clean only artifacts that rebuild automatically on next use: go-build cache (`go clean -cache`), Yarn cache, pip cache, Homebrew cleanup, bun install cache, Spotify cache, ShipIt updater cache, CoreSimulator caches, and docker build cache via `docker system prune -af`. The janitor SHALL NEVER pass `--volumes` to docker prune, and SHALL NEVER touch user-data paths (`~/Documents`, `~/Downloads`, `~/Desktop`) or editor state (`~/.cursor/extensions`).

#### Scenario: Weekly deep clean runs
- **WHEN** the weekly launchd agent fires the janitor in clean mode
- **THEN** each available target is cleaned, each skipped target (tool not installed) is logged as `SKIP`, and per-target freed bytes are logged

#### Scenario: Docker daemon not running
- **WHEN** docker is not reachable
- **THEN** the docker step logs `SKIP docker (daemon unreachable)` and the remaining targets still run

#### Scenario: Forbidden flags are structurally absent
- **WHEN** the janitor source is inspected
- **THEN** no code path can produce `docker system prune` with `--volumes`, and no cleanup target resolves inside user-data paths

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
