## ADDED Requirements

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
| Runaway selection | never selected | selected | not selected — the phase only considers protected processes |
| Runaway signalling | n/a | signalled, for the selected PID only | n/a |

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
NOT be signalled by cc-reaper under any threshold.

#### Scenario: Security software is stuck hot
- **WHEN** `Bitdefender` sustains CPU ≥ `CC_RUNAWAY_CPU` for etime ≥ `CC_RUNAWAY_MIN`
- **THEN** it SHALL NOT be selected, listed, or signalled

#### Scenario: Spotlight indexing is stuck hot
- **WHEN** `mdworker` or `mds_stores` meets the same thresholds
- **THEN** neither SHALL be selected

#### Scenario: Application is stuck hot
- **WHEN** a `shared` application such as `ChatGPT.app` meets the thresholds
- **THEN** it SHALL still be selected and signalled, because it is not `immutable`

### Requirement: Runaway signals the process it selected
When the runaway phase selects a PID, the signal stage SHALL signal that PID even when its class
would otherwise exempt it. The exemption SHALL continue to apply to every other member of its
process group.

#### Scenario: Runaway shared MCP is terminated
- **WHEN** `chrome-devtools-mcp` is selected as a runaway candidate
- **THEN** it SHALL be signalled, rather than skipped as a shared service

#### Scenario: Group siblings keep their protection
- **WHEN** the selected runaway PID shares a process group with `context7-mcp`, which is not itself runaway
- **THEN** `context7-mcp` SHALL NOT be signalled

#### Scenario: User protect rule still wins
- **WHEN** a user `protect` rule covers a process that meets the runaway thresholds
- **THEN** it SHALL NOT be selected or signalled

### Requirement: Runaway counters report deliveries
The reaped count and freed total SHALL include only processes to which a signal was actually
sent. A candidate that survives the signal stage SHALL NOT be counted, SHALL NOT contribute to
the freed total, and SHALL NOT raise a notification claiming it was reaped.

#### Scenario: Every candidate is signalled
- **WHEN** two runaway candidates are selected and both are signalled
- **THEN** the summary SHALL report two reaped

#### Scenario: A candidate is exempted at the signal stage
- **WHEN** a candidate is spared by a user `protect` rule discovered at the signal stage
- **THEN** the summary SHALL NOT count it, and its tree RSS SHALL NOT be added to the freed total

#### Scenario: Nothing is delivered
- **WHEN** every candidate is spared at the signal stage
- **THEN** the summary SHALL report zero reaped rather than a non-zero count

## MODIFIED Requirements

### Requirement: Protection covers the matched process, not its descendants
Every protection test SHALL be applied to a process's own command line. Ancestry SHALL NOT be
consulted: it neither protects a process nor exposes one. A process whose command matches a
protected pattern is exempt no matter who spawned it, and a process spawned by a protected
application gains no protection from that parent.

Losing a parent's protection is not the same as becoming reapable. A process is reaped only when
it also satisfies a path's own eligibility test — a family predicate, a user `cleanup` rule, or
membership in an orphaned group. A helper matching none of those is left alone however detached
and stale it is.

Protection itself SHALL come from the single classification in "One protection classification
owns all three paths". The three paths differ only in eligibility and in how they treat the
`shared` class, never in what they consider protected.

#### Scenario: Live descendant of a protected application
- **WHEN** a `shared` application has spawned MCP servers that are still attached to it and below the stale threshold, and no orphaned group covers them
- **THEN** they SHALL NOT be signalled, because they satisfy no family predicate on their own merits

#### Scenario: Leaked descendant of a protected application
- **WHEN** a `shared` application has leaked `npx`-spawned MCP servers that are detached, older than `CC_AGENT_STALE_MINUTES`, and classify as `none`
- **THEN** they SHALL be reaped, because a leaked helper carries no marker of its parent

#### Scenario: Leaked descendant is itself a shared service
- **WHEN** the leaked descendant classifies as `shared` and no user rule covers it
- **THEN** it SHALL be exempt from pattern-based and process-group cleanup, and SHALL be reachable only by the runaway phase
