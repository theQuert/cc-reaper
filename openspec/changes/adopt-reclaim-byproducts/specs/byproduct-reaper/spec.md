## ADDED Requirements

### Requirement: The byproducts reaper is scheduled under one label
The byproducts reaper SHALL be installed by its own `--install-launchd` as `com.cc-reaper.reclaim-byproducts`, and SHALL refuse to install from a copy inside a git checkout. Before its probe it SHALL retire the skills-era `com.claude.reclaim-byproducts` agent: disable it, wait while it reports a running sweep, then unload it and move its plist to `~/.cc-reaper/state/retired-agents/`; it SHALL NOT delete it and SHALL NOT unload it while a sweep runs. Past `BYPRODUCT_LEGACY_WAIT_SECONDS` it SHALL re-enable it, change nothing and exit non-zero. An install that fails or is inconclusive after the retirement SHALL restore the legacy agent and load it again.

#### Scenario: Cut over from the skills-era agent
- **WHEN** `--install-launchd 3h` succeeds and `com.claude.reclaim-byproducts.plist` exists and is idle
- **THEN** the legacy agent is unloaded, its plist is under `retired-agents`, and the output says `retired`

#### Scenario: The old agent is mid-sweep
- **WHEN** the legacy agent reports `state = running` past the wait
- **THEN** it is not unloaded, its plist stays, nothing is installed, and the output says it is still running

#### Scenario: The new agent cannot start
- **WHEN** the legacy agent was retired and the probe produces no output
- **THEN** the legacy plist is back in `~/Library/LaunchAgents` and loaded

### Requirement: The reaper carries no machine identity
The scratchpad root SHALL default to `/tmp/claude-<the invoking uid>`. A root that is a symbolic link or not owned by the invoking user SHALL be refused with nothing reaped and the run marked failed, and a symbolic link at the project or scratchpad level SHALL never be treated as a scratchpad. The liveness gate SHALL default to the harness's `~/.claude/hooks/path-in-use.sh`, and a run that cannot read it SHALL reap nothing.

#### Scenario: Another user's machine
- **WHEN** the reaper runs as uid 502 with no overrides
- **THEN** it judges `/tmp/claude-502` and nothing under `/tmp/claude-501`

#### Scenario: Another account created the root first
- **WHEN** `/tmp/claude-<uid>` is a link or owned by someone else
- **THEN** nothing is reaped and the run does not stamp
