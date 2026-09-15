## ADDED Requirements

### Requirement: Scheduled monitor does not select by CPU
The LaunchAgent monitor SHALL NOT signal a process because it is orphaned and hot. Its candidates
SHALL come only from its process-family predicates and orphaned agent process groups. A stuck
shared MCP service SHALL be left to claude-guard's runaway phase.

#### Scenario: Hot test run started from a session
- **WHEN** the monitor runs and finds a PPID=1 `python -m pytest` at 99% CPU for ten minutes whose command line contains a `/private/tmp/claude-501/` scratchpad path
- **THEN** it SHALL NOT signal the process and SHALL NOT log a KILL for it

#### Scenario: Hot protected development server
- **WHEN** the monitor finds a PPID=1 `node next dev-server` at 99% CPU for an hour
- **THEN** it SHALL NOT signal the process

#### Scenario: Orphaned MCP server named by a family predicate
- **WHEN** the monitor finds a PPID=1 `npm exec @cloudflare/mcp-server-cloudflare` at any CPU
- **THEN** it SHALL still signal it through the family sweep

#### Scenario: Stuck shared MCP server
- **WHEN** a PPID=1 `npx chrome-devtools-mcp` sustains CPU at or above `CC_RUNAWAY_CPU`
- **THEN** the monitor SHALL NOT signal it, and claude-guard's runaway phase SHALL select it once its elapsed time reaches `CC_RUNAWAY_MIN` and its CPU is still over the threshold when re-sampled

### Requirement: Runaway re-checks before signalling
Before signalling a selected PID, the runaway phase SHALL wait at least three seconds and read
that PID again. It SHALL signal only when the PID still runs the command it was selected for,
still classifies as a runaway-eligible service, and its CPU is still at or above
`CC_RUNAWAY_CPU`. A PID that fails any of these SHALL NOT be signalled or counted.

#### Scenario: A burst that has passed
- **WHEN** a shared MCP server read 95% CPU at selection and reads 4% on the re-sample
- **THEN** it SHALL NOT be signalled, and the summary SHALL report it as not reaped

#### Scenario: The PID now belongs to something else
- **WHEN** the selected PID runs a different command at the re-check
- **THEN** it SHALL NOT be signalled

#### Scenario: Still hot
- **WHEN** the selected MCP server is still at or above the threshold on the re-sample
- **THEN** it SHALL be signalled and counted

### Requirement: Installed shell functions outlive the checkout
`install.sh` SHALL configure the shell rc file to source the deployed copies of
`claude-cleanup.sh` and `cc-monitor.sh` under `~/.cc-reaper/`. Each line SHALL be guarded, so a
missing file produces no output. An update SHALL repair lines the installer generated earlier that
point anywhere else. No outcome of rc configuration SHALL stop the rest of the installation.

#### Scenario: Fresh install
- **WHEN** `install.sh` runs against an rc file that sources neither script
- **THEN** it SHALL append one guarded line for each, naming `$HOME/.cc-reaper/`, and no line naming the checkout it ran from

#### Scenario: Stale line from a removed checkout
- **WHEN** the rc file contains `source "/removed/worktree/shell/claude-cleanup.sh"` as a whole line
- **THEN** `install.sh` SHALL replace that line with the guarded deployed-copy line, print the line it replaced, and leave every other line unchanged

#### Scenario: Backup precedes every change
- **WHEN** `install.sh` changes the rc file in any way, by appending or by rewriting
- **THEN** a timestamped backup SHALL exist first, and it SHALL be byte-identical to the rc file as it was before the run

#### Scenario: Stale and current lines both present
- **WHEN** the rc file contains the guarded line and a stale installer line for the same script
- **THEN** the stale line SHALL be removed and the guarded line SHALL appear exactly once

#### Scenario: Stale line commented out
- **WHEN** the only mention of a script is a commented-out line
- **THEN** `install.sh` SHALL add the guarded line, because a comment sources nothing

#### Scenario: Line in another shape
- **WHEN** the rc file mentions `claude-cleanup.sh` in an uncommented line the installer did not generate
- **THEN** `install.sh` SHALL leave the line unchanged, SHALL NOT add a second line for that script, and SHALL print the line it left alone

#### Scenario: An rc file that cannot be rewritten in place
- **WHEN** the rc file needs a repair and is a symlink, has more than one hard link, or cannot be read or written
- **THEN** `install.sh` SHALL leave it unchanged, SHALL print the replacement to make by hand, and SHALL complete the installation

#### Scenario: Repeated install
- **WHEN** `install.sh` runs twice
- **THEN** the rc file SHALL contain exactly one line for each script, and the second run SHALL create no backup

#### Scenario: Functions load in a new shell
- **WHEN** an interactive zsh starts with the installed rc file and the deployed copies present
- **THEN** `claude-cleanup` and `cc-monitor` SHALL be defined, and nothing SHALL be printed to stderr

### Requirement: Deployed scripts are replaced by rename
`install.sh` SHALL install every script it deploys - the stop hook, the monitor, and the scripts
under `~/.cc-reaper/` - by writing a temporary file in the destination directory and renaming it
over the destination. A process already reading the previous version SHALL keep reading it.

#### Scenario: A deployed script is replaced
- **WHEN** `install.sh` runs over an existing `~/.cc-reaper/claude-cleanup.sh`
- **THEN** the path SHALL name a new inode with the repository's content, and no temporary file SHALL remain

## MODIFIED Requirements

### Requirement: One protection classification owns all three paths
The system SHALL classify a command line into exactly one protection class via
`_cc_reaper_protection_class`, and every cleanup path SHALL consult that classification rather
than its own list.

| Class | Meaning |
|---|---|
| `immutable` | System processes, cc-reaper's own scripts and app binary, ordinary Chrome, Codex UI helpers. Never signalled by any path. |
| `shared` | Long-running services other work depends on: shared MCP servers, dev servers, process managers, and whitelisted applications. |
| `none` | Everything else. |

Each path SHALL apply the class as follows:

| Path | `immutable` | `shared` | `none` |
|---|---|---|---|
| Pattern-based cleanup | never | exempt, unless a user `cleanup` rule covers it | family predicates decide |
| Process-group cleanup | never | skipped | signalled on membership |
| Runaway selection | never selected | selected only when it is a shared MCP service; applications, development servers and process managers are never selected | not selected - the phase only considers protected processes |
| Runaway signalling | n/a | signalled, for the selected PID only; no other process is signalled | n/a |

A user `protect` rule SHALL exempt a process on every path, and SHALL outrank a user `cleanup`
rule.

#### Scenario: Same service launched two ways
- **WHEN** `npx -y @stripe/mcp` and `node …/.bin/mcp-server-stripe` are both running
- **THEN** both SHALL classify as `shared`, and every path SHALL treat them identically

#### Scenario: Dev server in an orphaned group
- **WHEN** an orphaned process group contains a `pm2` or `next-server` process
- **THEN** it SHALL classify as `shared` and SHALL be skipped by process-group cleanup, matching how pattern-based cleanup already spares it

#### Scenario: Classification is total
- **WHEN** any command line is classified
- **THEN** exactly one of `immutable`, `shared`, or `none` SHALL be returned

### Requirement: Runaway never selects immutable processes
Runaway selection SHALL exclude processes classified `immutable`. A stuck system scanner SHALL
NOT be signalled by cc-reaper under any threshold. Runaway selection SHALL also exclude
applications (a command inside an `.app` bundle), development servers and process managers, even
though they classify `shared`: each is something a person is using, and the phase runs unattended.
cc-monitor SHALL still report them.

#### Scenario: Security software is stuck hot
- **WHEN** `Bitdefender` sustains CPU ≥ `CC_RUNAWAY_CPU` for etime ≥ `CC_RUNAWAY_MIN`
- **THEN** it SHALL NOT be selected, listed, or signalled

#### Scenario: Spotlight indexing is stuck hot
- **WHEN** `mdworker` or `mds_stores` meets the same thresholds
- **THEN** neither SHALL be selected

#### Scenario: Application is stuck hot
- **WHEN** a `shared` application such as `ChatGPT.app` or the `cmux.app` terminal meets the thresholds
- **THEN** it SHALL NOT be selected or signalled, because signalling it ends the work running inside it

#### Scenario: Development server is stuck hot
- **WHEN** a `node … next dev-server` or `pm2` process meets the thresholds
- **THEN** it SHALL NOT be selected or signalled

### Requirement: Runaway signals the process it selected
When the runaway phase selects a PID, the signal stage SHALL signal that PID even when its class
would otherwise exempt it, and SHALL signal no other process: not its process group, its parent,
or its siblings, whatever their class.

#### Scenario: Runaway shared MCP is terminated
- **WHEN** `chrome-devtools-mcp` is selected as a runaway candidate
- **THEN** it SHALL be signalled, rather than skipped as a shared service

#### Scenario: Group siblings keep their protection
- **WHEN** the selected runaway PID shares a process group with `context7-mcp`, which is not itself runaway
- **THEN** `context7-mcp` SHALL NOT be signalled

#### Scenario: MCP server inside a live session's process group
- **WHEN** the selected MCP server shares its process group with the Claude CLI that launched it, a stream-json subagent and another MCP server
- **THEN** only the selected MCP server SHALL be signalled

#### Scenario: User protect rule still wins
- **WHEN** a user `protect` rule covers a process that meets the runaway thresholds
- **THEN** it SHALL NOT be selected or signalled
