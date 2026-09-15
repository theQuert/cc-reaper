## ADDED Requirements

### Requirement: Scheduled monitor does not select by CPU
The LaunchAgent monitor SHALL NOT signal a process because it is orphaned and hot. Its candidates
SHALL come only from its process-family predicates and orphaned agent process groups. A stuck
`shared` service SHALL be left to claude-guard's runaway phase, which selects through the
protection classification.

#### Scenario: Hot test run started from a session
- **WHEN** the monitor runs and finds a PPID=1 `python -m pytest` at 99% CPU for ten minutes whose command line contains a `/private/tmp/claude-501/` scratchpad path
- **THEN** it SHALL NOT signal the process and SHALL NOT log a KILL for it

#### Scenario: Hot protected development server
- **WHEN** the monitor finds a PPID=1 `node next dev-server` at 99% CPU for an hour
- **THEN** it SHALL NOT signal the process

#### Scenario: Orphaned unprotected MCP server
- **WHEN** the monitor finds a PPID=1 `npm exec @cloudflare/mcp-server-cloudflare` at any CPU
- **THEN** it SHALL still signal it through the family sweep

#### Scenario: Stuck shared MCP server
- **WHEN** a PPID=1 `npx chrome-devtools-mcp` sustains CPU at or above `CC_RUNAWAY_CPU`
- **THEN** the monitor SHALL NOT signal it, and claude-guard's runaway phase SHALL select it once its elapsed time reaches `CC_RUNAWAY_MIN`

### Requirement: Installed shell functions outlive the checkout
`install.sh` SHALL configure the shell rc file to source the deployed copies of
`claude-cleanup.sh` and `cc-monitor.sh` under `~/.cc-reaper/`. Each line SHALL be guarded, so a
missing file produces no output. An update SHALL repair lines the installer generated earlier that
point anywhere else.

#### Scenario: Fresh install
- **WHEN** `install.sh` runs against an rc file that sources neither script
- **THEN** it SHALL append one guarded line for each, naming `$HOME/.cc-reaper/`, and no line naming the checkout it ran from

#### Scenario: Stale line from a removed checkout
- **WHEN** the rc file contains `source "/removed/worktree/shell/claude-cleanup.sh"` as a whole line
- **THEN** `install.sh` SHALL copy the rc file to a timestamped backup, replace that line with the guarded deployed-copy line, and leave every other line unchanged

#### Scenario: Line in another shape
- **WHEN** the rc file mentions `claude-cleanup.sh` in a line the installer did not generate
- **THEN** `install.sh` SHALL leave the line unchanged, SHALL NOT add a second line for that script, and SHALL print the line it left alone

#### Scenario: Repeated install
- **WHEN** `install.sh` runs twice
- **THEN** the rc file SHALL contain exactly one line for each script, and the second run SHALL create no backup

#### Scenario: Functions load in a new shell
- **WHEN** an interactive zsh starts with the installed rc file and the deployed copies present
- **THEN** `claude-cleanup` and `cc-monitor` SHALL be defined, and nothing SHALL be printed to stderr
