# agent-process-reapers Specification

## Purpose
Reaping of leaked agent automation: orphan-parent detection shared across the Stop hook, `claude-cleanup`, and the orphan report; stale browser/Puppeteer/Codex process families; the runaway-protected-process phase; and the definition of a Claude Code session that `claude-guard`, `claude-sessions`, and `claude-fd` reap against. Safety boundaries here decide what cc-reaper may never signal.

## Requirements

### Requirement: Cross-platform orphan parent detection

The system SHALL recognize a process as orphaned not only when its parent is
PID 1 but also when its parent is the invoking user's `systemd --user` manager,
which is the Linux per-user reparent target for processes whose session has
exited. The Stop hook, `claude-cleanup`, and the orphan report SHALL all use
this shared orphan-parent definition.

#### Scenario: macOS or host with no systemd --user manager

- **WHEN** cc-reaper runs on a host where the invoking user has no
  `systemd --user` manager process (e.g. macOS)
- **THEN** the orphan-parent set SHALL contain only PID 1, and orphan detection
  SHALL behave identically to the prior PID=1-only behavior.

#### Scenario: Linux host with a systemd --user manager

- **WHEN** cc-reaper runs on a Linux host where the invoking user has a
  `systemd --user` manager process, and a Claude subagent or MCP server has
  been reparented to that manager after its session exited
- **THEN** the orphan-parent set SHALL include both PID 1 and that manager's
  PID, and the reparented process SHALL be detected as an orphan by the Stop
  hook, `claude-cleanup`, and the orphan report.

#### Scenario: Multiple systemd --user managers exist

- **WHEN** more than one `systemd --user` process exists on the host (e.g.
  several logged-in users each have their own manager)
- **THEN** cc-reaper SHALL include only the manager(s) owned by the invoking
  user in the orphan-parent set, and SHALL NOT treat another user's manager as
  an orphan parent.

#### Scenario: systemd --user manager is never a cleanup candidate

- **WHEN** orphan cleanup runs and a `systemd --user` manager PID is part of
  the orphan-parent set
- **THEN** cc-reaper SHALL NOT terminate the manager process itself — it is a
  reparent target, not an orphan.

### Requirement: Manual cleanup reaps stale agent browser processes
The system SHALL allow `claude-cleanup` to reap detached or stale agent-browser and Chrome-for-Testing processes that remain after an agent/browser automation session ends.

#### Scenario: Orphaned agent-browser process is found
- **WHEN** an `agent-browser-darwin-arm64` process or its Chrome-for-Testing child is detached from its owning session or has been reparented to an orphan parent (PID 1, or the invoking user's `systemd --user` manager on Linux)
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

#### Scenario: Stale Chrome-for-Testing profile is found
- **WHEN** a Chrome-for-Testing process uses an `agent-browser-chrome-*` profile and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

### Requirement: Manual cleanup reaps stale Puppeteer headless Chrome processes
The system SHALL allow `claude-cleanup` to reap runaway Puppeteer/headless Chrome processes that use temporary automation profiles.

#### Scenario: Runaway Puppeteer Chrome is found
- **WHEN** a Chrome or Chrome Helper process uses a `puppeteer_dev_chrome_profile-*` profile, runs in headless mode, and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates and terminate it.

#### Scenario: Regular Chrome is running
- **WHEN** a Chrome process does not use a Puppeteer or agent-browser automation profile
- **THEN** `claude-cleanup` SHALL NOT terminate it because of this capability.

### Requirement: Manual cleanup reaps stale Codex background processes
The system SHALL allow `claude-cleanup` to reap stale or orphaned Codex CLI background sessions and their short-lived MCP subprocesses.

#### Scenario: Orphaned Codex process group is found
- **WHEN** a process group leader is a Codex CLI/native process and the leader has been reparented to an orphan parent (PID 1, or the invoking user's `systemd --user` manager on Linux)
- **THEN** `claude-cleanup` SHALL terminate the process group unless a member matches a shared-service whitelist.

#### Scenario: Codex MCP subprocess is detached
- **WHEN** a Codex-owned `chrome-devtools-mcp`, `context7-mcp`, `mcp-remote`, or npm MCP subprocess is detached and exceeds the configured stale age threshold
- **THEN** `claude-cleanup` SHALL include it in cleanup candidates unless it matches a shared-service whitelist.

### Requirement: Scheduled monitor covers agent process families
The LaunchAgent monitor SHALL apply the same stale/orphan cleanup coverage to agent-browser, Puppeteer headless Chrome, and Codex process families.

#### Scenario: Monitor finds stale browser automation
- **WHEN** `cc-reaper-monitor.sh` runs and finds stale agent-browser, Chrome-for-Testing, or Puppeteer headless Chrome processes
- **THEN** it SHALL log the candidate details and terminate the stale processes.

#### Scenario: Monitor finds orphaned Codex group
- **WHEN** `cc-reaper-monitor.sh` runs and finds an orphaned process group whose leader is a Codex process
- **THEN** it SHALL log the group and terminate the group using the existing SIGTERM then SIGKILL fallback behavior.

### Requirement: proc-janitor configuration includes agent process targets
The proc-janitor configuration SHALL include target patterns for stale/orphan agent-browser, Puppeteer headless Chrome, and Codex background process families.

#### Scenario: proc-janitor scans orphan targets
- **WHEN** proc-janitor scans reparented processes
- **THEN** its targets SHALL match agent-browser, Chrome-for-Testing automation profiles, Puppeteer temporary headless profiles, and Codex background CLI/native processes.

#### Scenario: proc-janitor protects shared services
- **WHEN** proc-janitor scans processes that match shared MCP services or common development servers
- **THEN** its whitelist SHALL prevent those processes from being killed by these new patterns.

### Requirement: Safety boundaries protect user and system processes
The system SHALL keep explicit safety boundaries for processes that are not part of stale agent automation cleanup. `claude-guard` SHALL additionally never treat a process as a reapable session unless it satisfies the terminal-attached top-level Claude CLI definition, so that Desktop-hosted sessions, headless batch runs, and subagents are out of reach of RSS, FD, and idle reaping.

#### Scenario: User apps and system scanners are running
- **WHEN** stale/orphan cleanup or process-group cleanup runs while ChatGPT.app, cmux.app, Bitdefender, Spotlight, normal Chrome browsing, or a frontend/backend dev server is running
- **THEN** cc-reaper SHALL NOT target those processes through this capability.

#### Scenario: Scanner is stuck hot during the runaway phase
- **WHEN** a scanner such as `Bitdefender`, `mdworker`, or `mds_stores` sustains CPU ≥ `CC_RUNAWAY_CPU` for etime ≥ `CC_RUNAWAY_MIN`
- **THEN** it SHALL NOT be selected, because it classifies `immutable`; see "Runaway never selects immutable processes"

#### Scenario: Active session is running
- **WHEN** a Codex or Claude process is still attached to an active terminal/session and does not exceed stale/orphan criteria
- **THEN** cc-reaper SHALL NOT terminate it through this capability.

#### Scenario: Headless batch run is active during guard
- **WHEN** `claude-guard` runs while a headless `claude -p` batch job sits at 0% CPU
- **THEN** the batch job SHALL NOT be counted toward `CC_MAX_SESSIONS` and SHALL NOT be signalled

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
- **WHEN** a `shared` application such as `ChatGPT.app` or `cmux.app` stays over `CC_RUNAWAY_CPU` across guard runs for `CC_RUNAWAY_MIN` minutes
- **THEN** the runaway phase SHALL NOT select or signal it, because signalling an application ends the work running inside it
- **AND** a known shared MCP server the runaway phase selects SHALL be signalled, alone, if it is still over the threshold when re-checked

#### Scenario: User protect rule during the runaway phase
- **WHEN** a process covered by a user `protect` rule meets the runaway thresholds
- **THEN** it SHALL NOT be selected, because a user rule outranks the built-in exception

### Requirement: Stale threshold is configurable
The system SHALL expose configurable stale-age thresholds for browser automation and agent background cleanup with conservative defaults.

#### Scenario: User sets a lower stale threshold
- **WHEN** the user sets the stale threshold environment variable to a positive integer
- **THEN** manual cleanup and the scheduled monitor SHALL use that threshold for stale-process detection.

#### Scenario: User does not configure thresholds
- **WHEN** no stale threshold environment variable is set
- **THEN** cc-reaper SHALL use a conservative default that avoids killing recent active automation.

### Requirement: claude-guard reaps stuck protected processes
The system SHALL detect runaway protected processes (sustained high CPU over a long elapsed time) and SHALL terminate them after an explicit grace window, treating them as a distinct phase before existing FD-leak / bloated / idle phases.

#### Scenario: Runaway protected process detected
- **WHEN** `claude-guard` runs and one or more protected processes meet the runaway thresholds (CPU time of at least `CC_RUNAWAY_CPU` percent of every interval between claude-guard runs, for at least `CC_RUNAWAY_MIN` minutes; defaults 80 and 60)
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

### Requirement: Shared Claude Code session detection
The system SHALL locate Claude Code sessions through a single helper,
`_cc_reaper_session_pids`, which emits one PID per line. `claude-guard`,
`claude-sessions`, and `claude-fd` SHALL all obtain their session list from that helper so
that the three commands can never disagree about what a session is.

#### Scenario: All three commands agree
- **WHEN** `claude-guard`, `claude-sessions`, and `claude-fd` run against the same process table
- **THEN** each SHALL classify exactly the same set of PIDs as sessions

#### Scenario: Helper emits nothing on an idle host
- **WHEN** no Claude Code process is running
- **THEN** `_cc_reaper_session_pids` SHALL emit no output and exit without error

### Requirement: A session is a terminal-attached top-level Claude CLI process
The system SHALL treat a process as a Claude Code session only when it runs the `claude`
CLI executable **and** is attached to a real controlling terminal. Processes with no
controlling terminal SHALL NOT be treated as sessions.

The matcher SHALL recognise the session by the `claude` executable together with a session
flag (`--session-id`, or the legacy `--dangerously…` form), and SHALL NOT depend on any
single flag remaining in future Claude Code releases.

#### Scenario: Interactive CLI session is found
- **WHEN** `/Users/me/.local/bin/claude --session-id 3ded1c38-… --settings {…}` runs on `ttys006`
- **THEN** its PID SHALL be reported as a session

#### Scenario: Legacy launch form still matches
- **WHEN** a session runs as `claude --dangerously-skip-permissions` on a terminal
- **THEN** its PID SHALL be reported as a session

#### Scenario: Desktop-hosted claude-code is excluded
- **WHEN** `…/Claude/claude-code/2.1.222/claude.app/Contents/MacOS/claude --output-format stream-json --input-format stream-json …` runs with no controlling terminal
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Subagent is excluded
- **WHEN** a `claude … stream-json` process runs with no controlling terminal as the child of another `claude` process
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Headless run on a terminal is excluded
- **WHEN** `claude -p "summarize" --output-format stream-json` runs on `ttys003`
- **THEN** its PID SHALL NOT be reported as a session, because a batch run below the idle CPU threshold is indistinguishable from an abandoned session

#### Scenario: Helper process on a terminal is excluded
- **WHEN** `claude mcp-server …` runs on a terminal
- **THEN** its PID SHALL NOT be reported as a session

#### Scenario: Unrelated process naming claude is excluded
- **WHEN** `vim shell/claude-cleanup.sh` or `grep claude --session-id log.txt` runs on a terminal
- **THEN** its PID SHALL NOT be reported as a session, because neither runs the `claude` executable

### Requirement: Record boundaries never derive from process arguments
The system SHALL obtain the candidate PID and TTY from a process listing that carries the
executable name only and no argument text, so that no value a session was launched with can
forge a process record. The full command line SHALL be fetched per PID, never parsed out of
a concatenated table.

A session started with a `--settings` JSON argument containing newlines SHALL be reported
exactly once, and no token from that argument SHALL ever be emitted as a PID.

#### Scenario: Session arguments carry a forged process record
- **WHEN** a session's `--settings` payload contains the text `12345 ttys999 /path/claude --session-id injected` on its own line
- **THEN** the helper SHALL emit only the real session's PID, and SHALL NOT emit `12345`

#### Scenario: Forged PID belongs to a live process
- **WHEN** the forged PID names a live, unrelated process that exceeds an FD, RSS, or idle threshold
- **THEN** that process SHALL NOT be classified as a session, so `claude-guard` cannot reap its process group

#### Scenario: Session carries multi-line JSON settings
- **WHEN** a session's `--settings` argument contains embedded newlines
- **THEN** the helper SHALL emit that session's PID exactly once

### Requirement: Only the CLI's own arguments decide session status
The system SHALL ignore the `--settings` payload when testing for session and exclusion
flags. Every balanced `{…}` region of the command line is user-supplied data and SHALL NOT
qualify or disqualify a session.

The payload SHALL be cut out rather than truncated at, so top-level arguments written after
it still count. Braces inside JSON strings SHALL NOT affect the pairing. When the braces
never balance, the command SHALL be rejected: a missed session leaves the reaper inert,
while trusting a half-parsed line could hand `claude-guard` the wrong process group.

#### Scenario: Exclusion flag written after the payload
- **WHEN** `claude --session-id real --settings={} --output-format json` runs on a terminal
- **THEN** it SHALL NOT be reported, because `--output-format` is a top-level argument even though it follows the payload

#### Scenario: Session flag written after the payload
- **WHEN** `claude --settings={} --session-id real` runs on a terminal
- **THEN** it SHALL be reported

#### Scenario: Braces inside a JSON string
- **WHEN** the payload is `{"a":"}{"}`
- **THEN** the region SHALL still be treated as balanced and the session reported

#### Scenario: Braces never balance
- **WHEN** the command line ends mid-payload, as in `--settings {"truncated":`
- **THEN** the command SHALL NOT be reported as a session

#### Scenario: Hook command inside settings names an exclusion flag
- **WHEN** an interactive session's `--settings` JSON contains a hook such as `claude -p x --output-format json`
- **THEN** the session SHALL still be reported, because `--output-format` there belongs to the payload rather than to the CLI's own arguments

#### Scenario: Payload cannot qualify a non-session
- **WHEN** a non-session command such as `claude doctor --settings {"x":"--session-id fake"}` runs on a terminal
- **THEN** it SHALL NOT be reported, because the session flag appears only inside the payload

#### Scenario: Equals form of the settings flag
- **WHEN** the payload is passed as `--settings={…}` rather than `--settings {…}`
- **THEN** the payload SHALL be excluded from matching just the same

#### Scenario: Genuine headless run is still excluded
- **WHEN** `claude -p "summarize" --session-id ghi` runs on a terminal with the flags in its own arguments
- **THEN** it SHALL NOT be reported as a session

### Requirement: claude-guard runs identically under bash and zsh
`claude-guard` SHALL classify and report the same sessions whether sourced into bash or zsh.
Its kill phases SHALL NOT depend on array index numbering, because `${!arr[@]}` raises
`bad substitution` in zsh and `${arr[0]}` is empty there. Each candidate SHALL carry its own
detail alongside its PID rather than relying on a second array walked by the same index.

The reserved variable name `status` SHALL NOT be declared, since it is read-only in zsh.

#### Scenario: FD-leak phase under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with a session above `CC_MAX_FD`
- **THEN** the phase SHALL name that session's PID and SHALL NOT abort with `bad substitution`

#### Scenario: Bloated phase under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with a session above `CC_MAX_RSS_MB`
- **THEN** the phase SHALL name that session's PID

#### Scenario: Idle eviction under zsh
- **WHEN** `claude-guard --dry-run` runs under zsh with more idle sessions than `CC_MAX_SESSIONS`
- **THEN** each eviction line SHALL name a real PID, never an empty one

#### Scenario: Session table renders under zsh
- **WHEN** `claude-guard` or `claude-fd` prints a session's status column under zsh
- **THEN** it SHALL not fail with `read-only variable: status`

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
| Runaway selection | never selected | selected only when the process is itself a known shared MCP server that has stayed over the threshold for `CC_RUNAWAY_MIN` minutes across guard runs; applications, development servers and process managers never are | not selected - the phase only considers protected processes |
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
applications (a process run from inside an `.app` bundle), development servers and process managers, even
though they classify `shared`: each is something a person is using, and the phase runs unattended.
cc-monitor SHALL still report them, and SHALL NOT name claude-guard as the remedy for one.

#### Scenario: Security software is stuck hot
- **WHEN** `Bitdefender` stays over `CC_RUNAWAY_CPU` for longer than `CC_RUNAWAY_MIN` minutes
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

### Requirement: cc-reaper bounds its own logs
Every log file cc-reaper writes SHALL be size-bounded. When a log exceeds its cap — 1 MB by
default — the current contents SHALL be copied to a single `.old` generation and the live file
truncated, so a file pair never exceeds roughly twice the cap.

The live file SHALL keep its inode. Renaming would leave a descriptor another process already
holds — such as the one launchd opens for `StandardOutPath` — appending to the moved inode, which
grows the rotated copy while the live path stays empty. Copy-then-truncate keeps one mechanism for
every log, whoever holds it open.

#### Scenario: Log crosses the cap
- **WHEN** a runner starts and its log exceeds the cap
- **THEN** its contents SHALL be copied to `<log>.old`, replacing any previous generation, and the live file SHALL be emptied

#### Scenario: Log is under the cap
- **WHEN** a runner starts and its log is below the cap
- **THEN** the file SHALL be left untouched

#### Scenario: A descriptor is already open on the log
- **WHEN** a log is bounded while another process holds it open for appending
- **THEN** that descriptor SHALL keep writing to the live file, because the inode is preserved

#### Scenario: Log does not exist yet
- **WHEN** a runner starts before any log has been written
- **THEN** rotation SHALL succeed silently and create nothing

### Requirement: Notifications require a controlling terminal
Desktop notifications SHALL be raised only when the reaper is attached to a terminal. Without one
the notification SHALL be skipped rather than spawned, and no background process SHALL be left
behind by the attempt.

#### Scenario: Interactive run
- **WHEN** `claude-guard` reaps a session from a terminal
- **THEN** a notification SHALL be raised

#### Scenario: launchd run
- **WHEN** the guard agent reaps a session with no controlling terminal
- **THEN** no notification process SHALL be started, and the run SHALL leave no child behind

#### Scenario: Notification tooling is unavailable
- **WHEN** the notification command is missing or fails
- **THEN** the reaper SHALL continue and its exit status SHALL be unaffected

### Requirement: Interrupted runs clean up their temp files
Any script creating a temporary directory SHALL remove it on `EXIT`, `INT`, and `TERM`, not only
on the successful path. `cc-monitor` samples for 60 seconds by default, so interruption is an
ordinary outcome rather than an edge case.

#### Scenario: Sampling is interrupted
- **WHEN** `cc-monitor` is interrupted during its sampling window
- **THEN** its temp directory SHALL be removed

#### Scenario: Sampling completes
- **WHEN** `cc-monitor` finishes normally
- **THEN** its temp directory SHALL be removed exactly once, and the exit status SHALL be the one the run produced

### Requirement: Agent installation is verified
`install.sh` SHALL clear any `disabled` state before loading an agent, and SHALL confirm the agent
is loaded afterwards. An agent that fails to start SHALL be reported by name rather than passed
over silently.

#### Scenario: Agent was previously disabled
- **WHEN** `install.sh` runs and an agent is marked `disabled` in the launchd database
- **THEN** it SHALL be enabled and loaded, because `launchctl load` alone cannot clear that flag

#### Scenario: Agent fails to load
- **WHEN** an agent is still absent after installation
- **THEN** `install.sh` SHALL print the failing label

#### Scenario: Every agent loads
- **WHEN** all agents load
- **THEN** `install.sh` SHALL report them as active

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
- **THEN** the monitor SHALL NOT signal it, and claude-guard's runaway phase SHALL select it once it has stayed over `CC_RUNAWAY_CPU` for `CC_RUNAWAY_MIN` minutes across its runs, and signal it if it is still over the threshold when re-checked

### Requirement: Runaway re-checks before signalling
Before signalling a selected PID, the runaway phase SHALL wait at least three seconds and read
that PID again. It SHALL signal only when the PID still has the sampled start time and runs the command it was selected for,
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

#### Scenario: PID reused for an identical command during the pause
- **WHEN** a selected PID has a different start time or its start time cannot be read at the re-check, even though its command is unchanged
- **THEN** it SHALL NOT be signalled or counted

### Requirement: Runaway selects a shared MCP server by what it runs
The runaway phase SHALL select a process only when the process itself is a known shared MCP
server: its executable names one or, when its executable is a package runner or interpreter, the
unambiguous executable operand does - compared whole, as a package with
any version dropped, a program in a `bin` directory, or a package directory under `node_modules`.
No other argument SHALL make a process eligible, so a name inside a JSON payload, a path to a
checkout named after a server, and an argument of a Claude or Codex CLI do not; `codex mcp-server`
is the one Codex form that is an MCP server. A process run from inside an `.app` bundle - its
executable, or what its runner runs - belongs to the application and SHALL NOT be eligible; an
`.app` elsewhere in its arguments, such as in a URL, does not count. Candidate PIDs SHALL come
from a process listing that
carries no argument text, with each command read per PID as one line, so no argument can add a
candidate. cc-monitor SHALL name claude-guard as the remedy for a runaway only when it is
eligible by the same test.

#### Scenario: Interpreter option value names a known server
- **WHEN** `node --conditions mcp-remote /repo/build.js` or `python -X chroma-mcp /repo/benchmark.py` meets the runaway thresholds
- **THEN** neither SHALL be eligible; unknown options that may consume a value SHALL fail closed

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

#### Scenario: A URL on an .app domain
- **WHEN** `npx -y mcp-remote https://mcp.linear.app/sse` meets the runaway thresholds
- **THEN** it SHALL be selected

#### Scenario: A server inside an application bundle
- **WHEN** `node /Applications/Claude.app/Contents/Resources/app.asar.unpacked/node_modules/@upstash/context7-mcp/dist/index.js`, whose runner's operand is inside the bundle, or `/Applications/ChatGPT.app/Contents/Resources/codex mcp-server`, whose executable is, meets the runaway thresholds
- **THEN** neither SHALL be selected

### Requirement: Runaway is measured across guard runs
The runaway phase SHALL select a process only after it has stayed hot for at least
`CC_RUNAWAY_MIN` minutes, measured across claude-guard's runs. Each run SHALL record, for every
process at or above `CC_RUNAWAY_CPU` %cpu, the CPU time it has used, keyed by PID and process
start time. An interval of at least a minute since the previous sample SHALL extend the
process's hot streak only when the CPU time used in it is at least `CC_RUNAWAY_CPU` percent of
the interval; otherwise the streak SHALL start over, as it SHALL for a process below the
threshold at a run or across an interval longer than 20 minutes, inside whose average an idle
stretch could hide. A lifetime average of CPU time, or `ps %cpu` alone, SHALL NOT stand in for
the streak. A dry run SHALL record nothing. A `CC_RUNAWAY_CPU` or `CC_RUNAWAY_MIN` that is not a
positive number SHALL be replaced by its default.

A sample dated later than the run reading it, or whose streak starts after the sample was taken,
SHALL NOT count, so a clock set back starts the streak over. A run that records its samples (so
not `--dry-run`) and cannot - because it cannot create the file, cannot write it to the end, or
cannot put it in place
- SHALL leave the previous samples in place, SHALL say so both on standard error and in the report
claude-guard prints, and SHALL select nothing. A samples path with no directory part SHALL name a
file where claude-guard runs, not a directory to create.

#### Scenario: Stuck for an hour after a long idle life
- **WHEN** a shared MCP server a day old, whose lifetime average is 5%, has used at least 80% of every interval between samples for the last 65 minutes and reads over the threshold
- **THEN** it SHALL be selected

#### Scenario: Busy early, then a burst
- **WHEN** a multi-threaded server used 56 minutes of CPU time in its first minutes, then idled, and reads 95% at a run 65 minutes after it started
- **THEN** it SHALL NOT be selected, because the interval since its previous sample was not hot

#### Scenario: A burst after an idle interval
- **WHEN** a server two days old, pinned for most of them, used 2% of the interval since its previous sample and reads 99% now
- **THEN** it SHALL NOT be selected, and its streak SHALL start over

#### Scenario: First sample
- **WHEN** a hot shared MCP server has no earlier sample
- **THEN** it SHALL NOT be selected, and a sample SHALL be recorded

#### Scenario: A reused PID
- **WHEN** the sample recorded for a PID carries a different process start time
- **THEN** that sample SHALL NOT count toward the process now holding the PID

#### Scenario: Runs less than a minute apart
- **WHEN** claude-guard runs less than a minute after a process's previous sample
- **THEN** that sample SHALL be kept unchanged, and the streak SHALL be judged as of it

#### Scenario: Below the threshold at a run
- **WHEN** a process with a two-hour streak reads below `CC_RUNAWAY_CPU` at a run
- **THEN** its sample SHALL be dropped, and its next hot run SHALL start a new streak

#### Scenario: The clock is set back
- **WHEN** a process's sample is dated later than the run reading it
- **THEN** that sample SHALL NOT count, and the streak SHALL start over

#### Scenario: A streak that starts after its own sample
- **WHEN** a process's sample carries a streak starting later than the sample was taken
- **THEN** that sample SHALL NOT count, and the streak SHALL start over

#### Scenario: Samples cannot be written completely
- **WHEN** recording a run's samples fails part way, as when the disk is full
- **THEN** the previous samples SHALL be left in place, the run SHALL say so, and it SHALL select nothing

#### Scenario: Samples cannot be recorded at all
- **WHEN** a recording run's samples file cannot be created or put in place, as when its directory is read-only
- **THEN** the previous samples SHALL be left in place, the run SHALL say so on standard error and in its report, and it SHALL select nothing

#### Scenario: A samples path with no directory
- **WHEN** `CC_RUNAWAY_SAMPLES_FILE` names a file with no directory part
- **THEN** claude-guard SHALL read and rewrite that file in the directory it runs from

#### Scenario: A long gap between runs
- **WHEN** the previous sample of a hot shared MCP server is 25 minutes old, however hot the interval
- **THEN** its streak SHALL start over, and it SHALL NOT be selected

#### Scenario: A streak shorter than the floor
- **WHEN** a shared MCP server has been hot for 55 minutes across runs
- **THEN** it SHALL NOT be selected

#### Scenario: Dry run
- **WHEN** `claude-guard --dry-run` runs
- **THEN** it SHALL NOT change the recorded samples

#### Scenario: Zero thresholds
- **WHEN** `CC_RUNAWAY_CPU` and `CC_RUNAWAY_MIN` are 0
- **THEN** claude-guard SHALL use 80 and 60, and SHALL NOT select an idle server or one without a streak

### Requirement: Installed shell functions outlive the checkout
`install.sh` SHALL configure the shell rc file to source the deployed copies of
`claude-cleanup.sh` and `cc-monitor.sh` under `~/.cc-reaper/`. Each line SHALL be guarded, so a
missing file produces no output. An update SHALL repair a line the installer generated earlier that
points anywhere else, and SHALL change the rc file only where the result is certain: it SHALL
never remove a line, since removing one can change what the lines around it mean. No outcome of
rc configuration SHALL stop the rest of the installation.

#### Scenario: Fresh install
- **WHEN** `install.sh` runs against an rc file that sources neither script
- **THEN** it SHALL append one guarded line for each, naming `$HOME/.cc-reaper/`, and no line naming the checkout it ran from

#### Scenario: Stale line from a removed checkout
- **WHEN** the rc file contains `source "/removed/worktree/shell/claude-cleanup.sh"` as a whole line, and no other line names the script
- **THEN** `install.sh` SHALL replace that line with the guarded deployed-copy line, print the line it replaced, leave every other line unchanged, and keep the file's mode and extended attributes

#### Scenario: Backup precedes every change
- **WHEN** `install.sh` changes the rc file in any way, by appending or by rewriting
- **THEN** a timestamped backup SHALL exist first, and it SHALL be byte-identical to the rc file as it was before the run

#### Scenario: Stale and current lines both present
- **WHEN** the rc file contains the guarded line and a stale installer line for the same script
- **THEN** `install.sh` SHALL leave the rc file unchanged and SHALL print the stale line to remove

#### Scenario: Stale line commented out
- **WHEN** the only mention of a script is a commented-out stale line
- **THEN** `install.sh` SHALL add the guarded line, because a comment sources nothing

#### Scenario: Current line commented out
- **WHEN** the only mention of a script is the guarded line, commented out
- **THEN** `install.sh` SHALL leave it commented out and SHALL NOT add the guarded line

#### Scenario: A line that only names the script, beside a stale line
- **WHEN** an uncommented line such as `alias cc-edit='vim ~/.cc-reaper/claude-cleanup.sh'` sits beside a stale line
- **THEN** `install.sh` SHALL leave the rc file unchanged and SHALL print the change to make by hand

#### Scenario: More than one stale line
- **WHEN** the rc file has two stale lines for the same script
- **THEN** `install.sh` SHALL leave the rc file unchanged and SHALL print both lines to remove

#### Scenario: A rewrite that cannot be renamed into place
- **WHEN** the rewritten copy cannot replace the rc file, as when the file's ACL denies delete
- **THEN** the rc file SHALL be unchanged, no copy of it SHALL remain, and `install.sh` SHALL print the change to make by hand

#### Scenario: Line in another shape
- **WHEN** the rc file mentions `claude-cleanup.sh` in an uncommented line the installer did not generate
- **THEN** `install.sh` SHALL leave the line unchanged, SHALL NOT add a second line for that script, and SHALL print the line it left alone

#### Scenario: Line in another shape beside a stale line
- **WHEN** the rc file has both a stale installer line and a line in another shape for `claude-cleanup.sh`
- **THEN** `install.sh` SHALL leave the rc file unchanged, and SHALL print the other line, the stale line to remove, and the guarded line to add unless the other line sources the script

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

### Requirement: MCP command identity owns its hot streak
Only eligible shared MCP commands SHALL be sampled. A changed command or a legacy sample without command identity SHALL start a new streak even when PID and process start time remain unchanged.

#### Scenario: A build execs an MCP server
- **WHEN** a hot build execs a known MCP server while retaining its PID, start time, and CPU time
- **THEN** the MCP server SHALL NOT inherit the build hot streak

### Requirement: Unknown rc link count preserves the file
The installer SHALL use the platform file link-count operation, including GNU stat when BSD stat is unsupported. If neither operation can establish the link count, it SHALL leave the rc unchanged and report why while continuing script deployment.

#### Scenario: GNU stat on a hard-linked rc
- **WHEN** the rc file has multiple hard links and the platform rejects BSD stat flags
- **THEN** GNU link-count inspection SHALL preserve the file and its links

#### Scenario: Link count cannot be read
- **WHEN** both platform link-count operations fail or return nonnumeric output
- **THEN** the rc file SHALL remain unchanged
