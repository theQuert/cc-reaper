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
- **THEN** the monitor SHALL NOT signal it, and claude-guard's runaway phase SHALL select it once it has averaged `CC_RUNAWAY_CPU` over a life of at least `CC_RUNAWAY_MIN` minutes, and signal it if it is still over the threshold when re-checked

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

### Requirement: Runaway selects a shared MCP server by what it runs
The runaway phase SHALL select a process only when the process itself is a known shared MCP
server: its executable names one or, when its executable is a package runner or interpreter, the
first word that is neither an option nor a subcommand does - compared whole, as a package with
any version dropped, a program in a `bin` directory, or a package directory under `node_modules`.
No other argument SHALL make a process eligible, so a name inside a JSON payload, a path to a
checkout named after a server, and an argument of a Claude or Codex CLI do not; `codex mcp-server`
is the one Codex form that is an MCP server. A command inside an `.app` bundle belongs to the
application and SHALL NOT be eligible. Candidate PIDs SHALL come from a process listing that
carries no argument text, with each command read per PID as one line, so no argument can add a
candidate. cc-monitor SHALL name claude-guard as the remedy for a runaway only when it is
eligible by the same test.

#### Scenario: Session whose settings name a protected service
- **WHEN** a terminal-attached `claude --session-id … --settings {…claude-mem…}` meets the runaway thresholds
- **THEN** it SHALL NOT be selected or signalled

#### Scenario: Subagent whose MCP configuration names a protected server
- **WHEN** `claude --output-format stream-json … --mcp-config {"mcpServers":{"context7":…}}` meets the runaway thresholds
- **THEN** it SHALL NOT be selected or signalled

#### Scenario: Work in or under a directory named after a protected server
- **WHEN** `node ~/GitHub/context7-docs-sync/node_modules/.bin/stryker run`, `python -m pytest ~/GitHub/chroma-mcp` or `uv run --directory ~/GitHub/chroma-mcp pytest` meets the runaway thresholds
- **THEN** none SHALL be selected or signalled

#### Scenario: Codex CLI configured with MCP servers
- **WHEN** `codex --yolo -c mcp_servers.github.command=npx` meets the runaway thresholds
- **THEN** it SHALL NOT be selected or signalled

#### Scenario: Argument text shaped like a listing row
- **WHEN** a hot shared MCP server's arguments contain a line shaped like a process listing row, or like the record the signal stage reads, naming another PID
- **THEN** that PID SHALL NOT become a runaway candidate

#### Scenario: Shared MCP server started through a package runner
- **WHEN** `npx -y @supabase/mcp-server-supabase@0.5.10`, `npm exec mcp-sequentialthinking-tools` or `uvx chroma-mcp` meets the runaway thresholds
- **THEN** it SHALL be selected

### Requirement: Runaway is measured over the process's life
The runaway phase SHALL select a process only when its elapsed time is at least `CC_RUNAWAY_MIN`
minutes and the CPU time it has used is at least `CC_RUNAWAY_CPU` percent of that elapsed time.
`ps %cpu` decays over about a minute, so a reading, or two a few seconds apart, SHALL NOT stand in
for time spent hot; it only confirms, at the re-check, that the process is still hot.

#### Scenario: A burst in a long-lived server
- **WHEN** a shared MCP server two days old, which has used one hour of CPU time, reads 99% during a burst
- **THEN** it SHALL NOT be selected

#### Scenario: A server pinned for most of its life
- **WHEN** a shared MCP server three hours old has used more than 80% of that time as CPU time and reads over the threshold
- **THEN** it SHALL be selected

#### Scenario: A hot server younger than the floor
- **WHEN** a shared MCP server thirty minutes old has been pinned for all of them
- **THEN** it SHALL NOT be selected

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
- **THEN** `install.sh` SHALL replace that line with the guarded deployed-copy line, print the line it replaced, leave every other line unchanged, and keep the file's mode and extended attributes

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

#### Scenario: Line in another shape beside a stale line
- **WHEN** the rc file has both a stale installer line and a line in another shape for `claude-cleanup.sh`
- **THEN** `install.sh` SHALL remove the stale line, SHALL leave the other line unchanged and print it, and SHALL NOT add the guarded line

#### Scenario: No rc file yet
- **WHEN** the rc file does not exist
- **THEN** `install.sh` SHALL create it with the guarded lines, and SHALL NOT back up the file it created

#### Scenario: An rc file that cannot be changed in place
- **WHEN** the rc file needs any change and is a symlink, has more than one hard link, or cannot be read or written
- **THEN** `install.sh` SHALL leave it unchanged, not even appending to it, SHALL print the change to make by hand, and SHALL complete the installation

#### Scenario: The backup cannot be written
- **WHEN** the rc file needs a change and its backup cannot be written
- **THEN** `install.sh` SHALL leave it unchanged, SHALL print the change to make by hand, and SHALL complete the installation

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
| Runaway selection | never selected | selected only when the process is itself a known shared MCP server that has averaged over the threshold for its life; applications, development servers and process managers never are | not selected - the phase only considers protected processes |
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
cc-monitor SHALL still report them, and SHALL NOT name claude-guard as the remedy for one.

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

#### Scenario: cc-monitor reports a stuck application
- **WHEN** cc-monitor reports `cmux.app`, a `next dev-server` or a Claude session as a runaway
- **THEN** its suggested action SHALL say that claude-guard will not reap it

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

### Requirement: Protection covers the matched process, not its descendants
Every protection test SHALL be applied to a process's own command line. Ancestry SHALL NOT be consulted: it neither protects a process nor exposes one. A process whose command matches a protected pattern is exempt no matter who spawned it, and a process spawned by a protected application gains no protection from that parent.

Losing a parent's protection is not the same as becoming reapable. A process is reaped only when it also satisfies a path's own eligibility test — a family predicate, a user `cleanup` rule, or membership in an orphaned group. A helper matching none of those is left alone however detached and stale it is.

This is deliberate. A protected application's leaked helpers are exactly what cc-reaper exists to reclaim: they carry no marker of their parent, and once detached and past `CC_AGENT_STALE_MINUTES` they are indistinguishable from any other orphaned MCP server. Extending protection along the parent chain would place a leaking app's garbage permanently out of reach, leaving no recovery short of quitting the app.

Protection itself comes from the single classification in "One protection classification owns all three paths". The paths differ only in eligibility and in how they treat the `shared` class, never in what they consider protected.

Candidacy for **pattern-based** cleanup is decided first-match against the process's own command line:

1. **Immutable** — system processes, cc-reaper's own scripts and app binary, ordinary Chrome, and Codex UI helpers. No user rule can override this rung.
2. **User `protect` rule** — exempt. Outranks a `cleanup` rule for the same process.
3. **User `cleanup` rule** — reapable once detached and stale, **overriding built-in protection**. This is how a user reclaims a shared service the built-in whitelist would otherwise spare.
4. **Built-in protected pattern** — exempt.
5. **Family matchers** — agent browser, Puppeteer Chrome, Codex, and agent MCP.

"cc-reaper's own scripts and app binary" means processes whose command matches `claude-cleanup.sh`, `cc-monitor.sh`, or the `CCReaper` binary — not everything cc-reaper spawned, since this rung matches commands rather than walking the tree.

The eligibility test is **not** shared across those rungs. Once a rung claims a process, that rung's own predicate decides:

| Rung | Eligible when |
|---|---|
| User `cleanup` rule | detached **and** stale — an orphan parent alone is not enough |
| Agent browser, Puppeteer Chrome | orphan parent **or** stale — an old process still attached to a terminal qualifies |
| Codex, agent MCP | orphan parent **or** (detached **and** stale) |

An orphaned parent is therefore sufficient on its own for the two family rungs, however young the process: a ten-second-old agent-browser reparented to PID 1 is already a candidate. It is not sufficient for a user `cleanup` rule, which always requires age as well.

#### Scenario: Unmatched helper spawned by a protected application
- **WHEN** a protected application has spawned a helper that matches no protected pattern, no agent family, and no user `cleanup` rule, and no orphaned group covers it
- **THEN** it SHALL NOT be reaped even when detached and long-running, because losing the parent's protection does not by itself make a process eligible

#### Scenario: Freshly orphaned agent browser
- **WHEN** an agent-browser process has been reparented to an orphan parent ten seconds ago
- **THEN** it SHALL be a candidate, because the orphan parent alone satisfies that family's predicate

#### Scenario: Old agent browser still attached to a terminal
- **WHEN** an agent-browser process has a living parent, holds a terminal, and is older than `CC_AGENT_STALE_MINUTES`
- **THEN** it SHALL be a candidate, because that family's predicate accepts staleness without requiring detachment

#### Scenario: Old agent MCP still attached to a terminal
- **WHEN** an agent-MCP process has a living parent, holds a terminal, and is older than `CC_AGENT_STALE_MINUTES`
- **THEN** it SHALL NOT be a candidate, because that family requires detachment alongside staleness

#### Scenario: Freshly orphaned process under a user cleanup rule
- **WHEN** a user `cleanup` rule covers a process that was reparented to an orphan parent ten seconds ago
- **THEN** it SHALL NOT be a candidate, because a user rule requires staleness as well

#### Scenario: Live descendant of a protected application
- **WHEN** a `shared` application has spawned MCP servers that are still attached to it and below the stale threshold, and no orphaned group covers them
- **THEN** they SHALL NOT be signalled, because they satisfy no family predicate on their own merits

#### Scenario: Leaked descendant of a protected application
- **WHEN** a `shared` application has leaked `npx`-spawned MCP servers that are detached, older than `CC_AGENT_STALE_MINUTES`, and whose **own** command lines match no protected pattern
- **THEN** they SHALL be reaped, because a leaked helper carries no marker of its parent and is indistinguishable from any other orphan

#### Scenario: Leaked descendant is itself a shared service
- **WHEN** the leaked descendant classifies as `shared`
- **AND** no user rule covers it
- **THEN** it SHALL be exempt and survive; ancestry neither condemns nor saves it

#### Scenario: Reaping a leaked descendant does not disturb the application
- **WHEN** those leaked helpers are reaped
- **THEN** the whitelisted application itself SHALL remain running

#### Scenario: User cleanup rule overrides built-in protection
- **WHEN** a user `cleanup` rule covers a built-in protected service such as `chrome-devtools-mcp`, and the process is detached and stale
- **THEN** pattern-based cleanup SHALL reap it, because a user rule is evaluated before the built-in whitelist

#### Scenario: User protect rule outranks a user cleanup rule
- **WHEN** both a `protect` and a `cleanup` rule match the same process
- **THEN** it SHALL be exempt

#### Scenario: No user rule can reach an immutable process
- **WHEN** a user `cleanup` rule matches a system process such as `WindowServer`, one of cc-reaper's own scripts, ordinary Chrome, or a Codex UI helper
- **THEN** it SHALL still be exempt from pattern-based cleanup, because immutability is evaluated before any user rule

#### Scenario: Child spawned by cc-reaper with an unrelated command
- **WHEN** a process cc-reaper started is detached and stale, and its own command line matches an agent family or a user `cleanup` rule
- **THEN** it SHALL be reapable, because self-immutability matches commands rather than walking the tree

#### Scenario: Group member that is not itself stale
- **WHEN** an orphaned Claude or Codex process group is reaped, and one member is recent and still attached but matches no immutable pattern, no built-in protected pattern, and no user `protect` rule
- **THEN** it SHALL be signalled on group membership alone

#### Scenario: User cleanup rule during process-group cleanup
- **WHEN** a user `cleanup` rule names a built-in protected service that is a member of an orphaned group
- **THEN** that member SHALL still be spared, because the `cleanup` override applies to pattern-based candidacy only

#### Scenario: Protected application is stuck hot
- **WHEN** a `shared` application such as `ChatGPT.app` or `cmux.app` meets the runaway thresholds (CPU ≥ `CC_RUNAWAY_CPU` over etime ≥ `CC_RUNAWAY_MIN`)
- **THEN** the runaway phase SHALL NOT select or signal it, because signalling an application ends the work running inside it
- **AND** a `shared` MCP server meeting the same thresholds SHALL be signalled, alone, if it is still over the threshold when re-checked

#### Scenario: User protect rule during the runaway phase
- **WHEN** a process covered by a user `protect` rule meets the runaway thresholds
- **THEN** it SHALL NOT be selected, because a user rule outranks the built-in exception

### Requirement: claude-guard reaps stuck protected processes
The system SHALL detect runaway protected processes (sustained high CPU over a long elapsed time) and SHALL terminate them after an explicit grace window, treating them as a distinct phase before existing FD-leak / bloated / idle phases.

#### Scenario: Runaway protected process detected
- **WHEN** `claude-guard` runs and one or more protected processes meet the runaway thresholds (CPU time of at least `CC_RUNAWAY_CPU` percent of an elapsed time of at least `CC_RUNAWAY_MIN` minutes; defaults 80 and 60)
- **THEN** claude-guard SHALL print a "Runaway protected processes" section listing each PID, command, CPU, and etime, SHALL wait `CC_RUNAWAY_GRACE_SEC` seconds (default 5) for the user to Ctrl+C, AND SHALL then re-check each PID and send a termination signal to each one that passes, to that PID alone and never to its process group.

#### Scenario: --dry-run preserves runaway protected processes
- **WHEN** `claude-guard --dry-run` runs and runaway processes are detected
- **THEN** claude-guard SHALL print the runaway list and the actions it would take, but SHALL NOT send any signals.

#### Scenario: Runaway phase is opt-out
- **WHEN** the user sets `CC_RUNAWAY_DISABLE=1`
- **THEN** claude-guard SHALL skip the runaway phase entirely and proceed directly to the FD-leak / bloated / idle phases as before.

#### Scenario: No runaway candidates
- **WHEN** no protected process meets the runaway thresholds
- **THEN** claude-guard SHALL skip the runaway phase silently and continue with the existing phases.

### Requirement: Runaway counters report deliveries
The reaped count and freed total SHALL include only processes to which a signal was actually
sent. A candidate that is not signalled, or whose signal fails, SHALL NOT be counted, SHALL NOT
contribute to the freed total, and SHALL NOT raise a notification claiming it was reaped.

The freed total SHALL be the resident size of each signalled PID, read just before its signal.
No other process is signalled, so no other process's memory is counted.

#### Scenario: Every candidate is signalled
- **WHEN** two runaway candidates are selected and both are signalled
- **THEN** the summary SHALL report two reaped

#### Scenario: A candidate is exempted at the signal stage
- **WHEN** a candidate is spared by a user `protect` rule discovered at the signal stage
- **THEN** the summary SHALL NOT count it, and its RSS SHALL NOT be added to the freed total

#### Scenario: Nothing is delivered
- **WHEN** every candidate is spared at the signal stage
- **THEN** the summary SHALL report zero reaped rather than a non-zero count

#### Scenario: Runaway target has a spared descendant
- **WHEN** a runaway target is signalled and another process in its process group, or below it, is not
- **THEN** the freed total SHALL exclude that process's RSS

#### Scenario: A signal that is not delivered
- **WHEN** the signal to a selected PID fails because the process has already exited
- **THEN** the summary SHALL NOT count it, and its RSS SHALL NOT be added to the freed total
