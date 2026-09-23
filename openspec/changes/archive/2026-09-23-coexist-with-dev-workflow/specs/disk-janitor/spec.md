## MODIFIED Requirements

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
