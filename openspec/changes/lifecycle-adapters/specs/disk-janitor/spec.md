## MODIFIED Requirements

### Requirement: Builder cache cleanup uses an external drain proof

The janitor SHALL reject builder-cache cleanup unless a fresh proof is bound to the current
host and Docker context, declares `scope=builder-cache`, and states `drained=1`.

#### Scenario: Missing or stale proof

- **WHEN** the proof is missing, malformed, expired, older than the configured maximum age,
  or names another host/context
- **THEN** the janitor logs a skip
- **AND** it does not invoke a Docker prune command

#### Scenario: Protected container appears

- **WHEN** a configured protected-container filter returns a running container immediately
  before cleanup
- **THEN** the janitor logs a skip
- **AND** it does not prune builder cache, images, containers or volumes

### Requirement: Lifecycle adapter is bounded

The lifecycle hook SHALL accept only the supported stage vocabulary and SHALL delegate to
existing janitors without bypassing their holder, claim, landed, idle or credential checks.
