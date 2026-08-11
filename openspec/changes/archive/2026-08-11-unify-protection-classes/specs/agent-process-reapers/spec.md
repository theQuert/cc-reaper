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

The freed total SHALL be summed from the signalled processes themselves. A candidate's pre-kill
tree RSS SHALL NOT be used, because the tree includes members the signal stage deliberately
spares — a runaway target with a `shared` descendant would otherwise report memory that is still
in use.

#### Scenario: Every candidate is signalled
- **WHEN** two runaway candidates are selected and both are signalled
- **THEN** the summary SHALL report two reaped

#### Scenario: A candidate is exempted at the signal stage
- **WHEN** a candidate is spared by a user `protect` rule discovered at the signal stage
- **THEN** the summary SHALL NOT count it, and its tree RSS SHALL NOT be added to the freed total

#### Scenario: Nothing is delivered
- **WHEN** every candidate is spared at the signal stage
- **THEN** the summary SHALL report zero reaped rather than a non-zero count

#### Scenario: Runaway target has a spared descendant
- **WHEN** a runaway target is signalled but a `shared` process in its group is spared
- **THEN** the freed total SHALL exclude that spared process's RSS
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
- **THEN** the runaway phase SHALL signal it after the grace window, because the whitelist protects an application that is working, not one that is stuck
- **AND** a `shared` MCP server reaches the same outcome, since the runaway phase signals whatever it selected

#### Scenario: User protect rule during the runaway phase
- **WHEN** a process covered by a user `protect` rule meets the runaway thresholds
- **THEN** it SHALL NOT be selected, because a user rule outranks the built-in exception
