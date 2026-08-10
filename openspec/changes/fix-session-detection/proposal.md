## Why

`claude-guard`, `claude-sessions`, and `claude-fd` all locate sessions with the same matcher:

```sh
ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}'
```

Claude Code no longer launches with `--dangerously…` on the command line. A current
interactive session looks like:

```
/Users/me/.local/bin/claude --session-id 3ded1c38-… --settings {"preferredNotifChannel":…}
```

So the matcher finds nothing. `claude-guard` returns at "No Claude Code sessions running."
before any classification runs, which silently disables all three of its defenses — the
`CC_MAX_RSS_MB` bloat ceiling, the `CC_MAX_FD` leak ceiling, and `CC_MAX_SESSIONS` idle
eviction. `claude-sessions` and `claude-fd` report empty for the same reason.

The failure is silent and fails safe (nothing is killed), so it survived unnoticed: the
runaway phase added in `agent-process-reapers` still worked because it scans protected
processes directly instead of going through session detection.

A second defect sits in the same line. The `--settings` argument carries JSON that can
contain newlines, so `ps` emits a session as several lines. `awk '{print $1}'` reads the
first token of every continuation line, which can yield a non-PID token or a PID belonging
to an unrelated process. `cc-monitor` already solved this in `_cc_monitor_snapshot` by
validating field shapes and dropping rows that do not parse; session detection never got
the same guard.

## What Changes

- Add `_cc_reaper_session_pids`, one helper that owns "what counts as a Claude Code
  session", and route `claude-guard`, `claude-sessions`, and `claude-fd` through it.
- Define a session as a **top-level `claude` CLI process attached to a real terminal**.
  Desktop-hosted claude-code, headless `-p`/`--output-format` runs, and `stream-json`
  subagents are deliberately excluded.
- Drop `ps` continuation lines by validating the PID and TTY field shapes, reusing the
  approach already proven in `_cc_monitor_snapshot`.
- Add a mocked-`ps` regression test that pins each inclusion and exclusion case.

Not in scope: threshold defaults, `_claude_pgid_kill`, the MCP whitelist, and the
`ChatGPT.app` protected-pattern behavior are all unchanged.

## Why terminal-attached only

Command line alone cannot separate a Desktop-hosted session from a subagent — both run the
`claude` binary with `--output-format stream-json --input-format stream-json`, and the
existing reaper patterns already claim `[c]laude.*stream-json` as the subagent signature.
Only the parent chain distinguishes them, and `claude-guard` kills whole process groups, so
a wrong call here terminates live work.

A terminal-attached top-level process is the one shape that is unambiguous, user-visible,
and recoverable: it maps one-to-one to a terminal tab the user can see and reopen. Headless
runs are excluded because a batch job sitting below the idle CPU threshold is
indistinguishable from an abandoned session, and killing one destroys work with no visible
tab to explain it.

The cost is accepted: sessions hosted inside the Claude desktop app are not counted and not
reaped. `cc-monitor` still reports them, so they remain visible.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `agent-process-reapers`: session detection becomes an explicit, tested contract shared by
  `claude-guard`, `claude-sessions`, and `claude-fd`.

## Impact

- `shell/claude-cleanup.sh`: new `_cc_reaper_session_pids`; three call sites replaced.
- `tests/guard-session-detect.sh`: new mocked-`ps` regression test.
- Behavior: `claude-guard` starts reaping again. On a host with more than `CC_MAX_SESSIONS`
  idle terminal sessions, or any session over `CC_MAX_RSS_MB`/`CC_MAX_FD`, it will now kill
  processes where it previously did nothing. This restores the documented contract rather
  than extending it, but it is a live behavior change and `--dry-run` should be run first
  on any host that has been relying on the broken behavior.
