## ADDED Requirements

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
- **THEN** the builder prune is logged as skipped and counted, and no other docker command runs
