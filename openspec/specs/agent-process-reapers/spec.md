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
- **WHEN** a scanner in the built-in protected pattern — `Bitdefender`, `mdworker`, `mds_stores` — sustains CPU ≥ `CC_RUNAWAY_CPU` for etime ≥ `CC_RUNAWAY_MIN`
- **THEN** the runaway phase SHALL select it, which is the single exception to the scenario above
- **AND** a user `protect` rule covering it SHALL still exempt it

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

Three cleanup paths exist and they do not share one rule. They differ both in what protects a process and in what makes it eligible in the first place:

| Path | Protection applied | What makes a process eligible |
|---|---|---|
| Pattern-based candidacy | full precedence chain below, including the user `cleanup` override | per-branch predicate, see below |
| Process-group cleanup | immutable, user `protect`, or built-in protected pattern | group membership alone |
| Runaway phase | built-in protected pattern selects processes *into* it; a user `protect` rule exempts at selection, and the group-kill MCP whitelist exempts again at the signal stage | CPU ≥ `CC_RUNAWAY_CPU` and etime ≥ `CC_RUNAWAY_MIN` |

Three consequences are easy to miss.

Process-group cleanup signals every member that is not directly protected on membership alone, so a recent, still-attached member of an orphaned group is reaped without its own staleness being consulted, and a user `cleanup` rule has no effect there.

The runaway phase consults only the built-in protected pattern at selection, so immutability does not reach it: a system scanner that appears in both sets is a runaway candidate once it is hot and old enough.

Selection and signalling are separate stages, and they apply different lists. The runaway phase selects on the protected pattern but signals through the group-kill path, which skips members matching its own MCP whitelist. A shared MCP server that goes runaway — `chrome-devtools-mcp`, `context7-mcp`, `sequential-thinking` — is therefore selected, waited on through the grace window, and then not signalled. The counters do not model this: the phase reports the candidate as reaped and adds its tree RSS to the freed total either way.

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
- **WHEN** a whitelisted application has spawned MCP servers that are still attached to it and below the stale threshold, and no orphaned group covers them
- **THEN** they SHALL NOT be signalled, because they satisfy no family predicate on their own merits

#### Scenario: Leaked descendant of a protected application
- **WHEN** a whitelisted application has leaked `npx`-spawned MCP servers that are detached, older than `CC_AGENT_STALE_MINUTES`, and whose **own** command lines match no protected pattern
- **THEN** they SHALL be reaped, because a leaked helper carries no marker of its parent and is indistinguishable from any other orphan

#### Scenario: Leaked descendant is itself a whitelisted service
- **WHEN** the leaked descendant's own command line matches a protected pattern — `chrome-devtools-mcp`, `context7-mcp`, `sequential-thinking`, or another shared service
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
- **WHEN** a whitelisted application such as `ChatGPT.app` or `cmux.app` meets the runaway thresholds (CPU ≥ `CC_RUNAWAY_CPU` over etime ≥ `CC_RUNAWAY_MIN`)
- **THEN** the runaway phase SHALL signal it after the grace window, because the whitelist protects an application that is working, not one that is stuck
- **AND** this holds because applications are absent from the group-kill MCP whitelist; a runaway MCP server in that list reaches the opposite outcome, below

#### Scenario: User protect rule during the runaway phase
- **WHEN** a process covered by a user `protect` rule meets the runaway thresholds
- **THEN** it SHALL NOT be selected, because a user rule outranks the built-in exception

#### Scenario: Runaway candidate is a whitelisted MCP server
- **WHEN** a shared MCP server such as `chrome-devtools-mcp` meets the runaway thresholds
- **THEN** it SHALL be selected and listed, and SHALL NOT be signalled, because the group-kill path skips members matching its MCP whitelist
- **AND** the reported reaped count and freed total SHALL still include it, since the phase does not observe whether a signal was delivered

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
- **WHEN** `claude-guard` runs and one or more protected processes meet runaway thresholds (CPU ≥ `CC_RUNAWAY_CPU` percent over etime ≥ `CC_RUNAWAY_MIN` minutes; defaults 80 and 60)
- **THEN** claude-guard SHALL print a "Runaway protected processes" section listing each PID, command, CPU, and etime, SHALL wait `CC_RUNAWAY_GRACE_SEC` seconds (default 5) for the user to Ctrl+C, AND SHALL then send PGID-aware termination signals to those processes (preserving non-runaway protected services within the same group).

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
