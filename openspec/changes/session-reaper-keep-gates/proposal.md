## Why

The session reaper's gates miss four kinds of unfinished work, and each one can end a session that is not done:
- Subagents and workflows run inside the claude process. No child process shows them, so a session can read `idle` while one is still working.
- A relay or approval request filed for a claimed issue can still be waiting.
- A question to a person can still be on screen.
- A handoff named in the last message may never have been written.

Separately, when a session is reaped, the context needed to bring it back is only a log line.

## What Changes

- **New keep gates.** They only ever keep a session, so the reaper never reaps more than before:
  - `subagent-active`;
  - `handoff-pending:relay#N`;
  - `handoff-pending:prompt`;
  - `handoff-missing:<file>`.
- **A pre-exit record.** One JSON record per tmux name in `REAPED_DIR`, written before `/exit` and marked `reaped` or `aborted:<why>` afterwards. It holds the resume command.
- **Two report columns:**
  - "held only by background shells";
  - "kept only by new gates", which is the comparison an operator reads before trusting the gates.
- **Config:** `SUBAGENT_QUIET_MINUTES`, `PROMPT_RE`, `RELAY_DIR`, `RELAY_MAX_AGE_HOURS`, `HANDOFF_ROOT` and `REAPED_DIR`. The relay and handoff checks are off while their directory is empty.

## Not in this change

- Resuming a reaped session by its tmux name.
- A SessionEnd record for sessions that exit by themselves.
