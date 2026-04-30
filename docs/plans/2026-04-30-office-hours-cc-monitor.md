# Office Hours: cc-monitor Explain-First Heat Diagnostics

Date: 2026-04-30

## Core Problem

When the laptop gets hot, cc-reaper can already clean known stale processes, but the user first needs to understand what is causing the heat and which actions are safe before killing anything.

## Target User

Developers running multiple AI coding sessions, browser automation, local dev servers, editors, and MCP services on macOS.

The recurring situation is: the machine gets hot, fan/thermal pressure rises, and the developer cannot quickly tell whether the cause is stale orphans, active agent work, an editor renderer, browser GPU work, Spotlight/antivirus, or a legitimate local dev server. This happens during active development sessions, often multiple times per day.

## Assumptions

- Users trust cc-reaper more if it explains before it kills.
- Most heat incidents are caused by a mix of active processes and stale leftovers, not only orphans.
- A short sampling window gives better signal than a single `ps` snapshot.
- The first version should work without sudo and without a new daemon.
- `powermetrics` or privileged thermal sampling can be optional later, but should not block the MVP.
- Process attribution by family is more useful than raw PID lists.

## Selected Option

Build **B: `cc-monitor`**, a read-only monitor script that samples process state over a short period, classifies heat contributors, and prints a human-readable diagnosis plus optional JSON output.

This is the right direction because the latest heat snapshot showed active Cursor, cmux, WindowServer, agent-browser, React dev server, and Codex/MCP processes. Killing more aggressively would not solve the core product problem: the user needs an explain-first decision layer that separates "safe to reap" from "ask first" from "do not kill".

## Scope

### Included

- New read-only command, `cc-monitor`.
- Default sampling run, with configurable duration and interval.
- A quick mode, `cc-monitor --once`, for an immediate snapshot.
- Human-readable report with:
  - Top processes by average CPU.
  - Process family breakdown: editor, cmux, Codex, Claude, MCP, agent-browser, Chrome, dev server, system, other.
  - Classification per finding:
    - `SAFE_TO_REAP`: stale/orphan candidates that existing cleanup can remove.
    - `ASK_BEFORE_KILL`: active user tools such as cmux, Cursor renderer, dev server, or active agent-browser.
    - `DO_NOT_KILL`: system/security/UI processes such as WindowServer, Spotlight, Bitdefender, normal Chrome.
  - Suggested next actions, not automatic actions.
- Optional `--json` output for future automation.
- Reuse existing cc-reaper process family patterns where possible.

### Non-Goals

- No process killing in the default monitor command.
- No always-on daemon in the first version.
- No sudo requirement.
- No direct temperature sensor dependency.
- No changes to ChatGPT.app, cmux.app, Cursor, Chrome, Bitdefender, Spotlight, or macOS settings.
- No auto-kill policy for active dev servers or editor renderers.

## Risks

- **False confidence from a short sample**: a spike can be missed or over-weighted.
  Mitigation: report sampling duration and average/max CPU, not only a single value.
- **Over-broad family matching**: command regexes may misclassify unrelated processes.
  Mitigation: reuse validation fixtures with positive and negative examples.
- **Diagnosis without action feels weak**: users may still want one command to fix it.
  Mitigation: include explicit suggested commands, for example `claude-cleanup --dry-run` once available, or targeted stop suggestions, but keep default read-only.
- **Monitor becomes another background load**: a daemon could create the problem it diagnoses.
  Mitigation: MVP is foreground and short-lived.
- **System processes dominate CPU**: WindowServer, Spotlight, or antivirus may be top offenders but not safely actionable.
  Mitigation: classify them as `DO_NOT_KILL` and explain the reason.

## Product Shape

Example output:

```text
=== cc-monitor: heat attribution ===
Sample: 60s, interval: 5s

Top contributors:
  1. Cursor Helper Renderer     avg 118% max 142%   ASK_BEFORE_KILL
  2. cmux                       avg 82%  max 96%    ASK_BEFORE_KILL
  3. WindowServer               avg 41%  max 55%    DO_NOT_KILL
  4. agent-browser Chrome tree  avg 24%  max 33%    ASK_BEFORE_KILL
  5. react-scripts start        avg 18%  max 29%    ASK_BEFORE_KILL

Safe cleanup candidates:
  none

Suggested actions:
  - Close or restart the hot Cursor window if it is not needed.
  - Inspect cmux panes; close idle panes before killing cmux itself.
  - If agent-browser is not actively testing, run: claude-cleanup
  - Stop unused dev server: PID 10129 react-scripts start
```

JSON output should preserve the same structure.
