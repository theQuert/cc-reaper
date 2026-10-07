## ADDED Requirements

### Requirement: The byproducts reaper is scheduled under one label
The byproducts reaper SHALL be installed by its own `--install-launchd` as `com.cc-reaper.reclaim-byproducts`. After the new agent is installed, or found already installed and loaded, it SHALL retire the skills-era `com.claude.reclaim-byproducts` agent by unloading it and moving its plist to `~/.cc-reaper/state/retired-agents/`, and SHALL NOT delete it. While that agent reports a running sweep it SHALL NOT be unloaded; past `BYPRODUCT_LEGACY_WAIT_SECONDS` it SHALL be left loaded and named in the output. An install whose probe fails or is inconclusive SHALL leave the legacy agent untouched.

#### Scenario: Cut over from the skills-era agent
- **WHEN** `--install-launchd 3h` succeeds and `com.claude.reclaim-byproducts.plist` exists and is idle
- **THEN** the legacy agent is unloaded, its plist is under `retired-agents`, and the output says `retired`

#### Scenario: The old agent is mid-sweep
- **WHEN** the legacy agent reports `state = running` past the wait
- **THEN** it is not unloaded, its plist stays, and the output says it is still running

### Requirement: The reaper carries no machine identity
The scratchpad root SHALL default to `/tmp/claude-<the invoking uid>`. The liveness gate SHALL default to the harness's `~/.claude/hooks/path-in-use.sh`, and a run that cannot read it SHALL reap nothing.

#### Scenario: Another user's machine
- **WHEN** the reaper runs as uid 502 with no overrides
- **THEN** it judges `/tmp/claude-502` and nothing under `/tmp/claude-501`
