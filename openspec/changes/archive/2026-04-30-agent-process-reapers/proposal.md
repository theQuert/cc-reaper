## Why

Recent local debugging left several non-Claude-but-agent-owned processes running for hours or days: runaway headless Chrome/Puppeteer GPU helpers, stale agent-browser Chrome-for-Testing trees, and old Codex/Claude background sessions with MCP subprocesses. cc-reaper already handles many Claude Code orphan cases, but these adjacent agent processes can still keep CPU/GPU usage high after the owning session is gone.

## What Changes

- Extend manual cleanup to detect and reap stale or orphaned headless browser automation processes owned by agent workflows.
- Extend LaunchAgent monitoring to cover stale agent-browser, Chrome-for-Testing, Puppeteer headless Chrome, and Codex background process groups.
- Extend proc-janitor target and whitelist coverage for these process families.
- Preserve conservative safety rules so normal Chrome tabs, dev servers, cmux/ChatGPT apps, Bitdefender, Spotlight, and active sessions are not killed.
- Document the expanded coverage and the safety boundaries.

## Capabilities

### New Capabilities

- `agent-process-reapers`: Cleanup coverage for stale agent browser, headless Chrome, and Codex/Claude background processes while preserving active user and system processes.

### Modified Capabilities

- None. No existing living specs are present in `openspec/specs/`.

## Impact

- Affected files:
  - `shell/claude-cleanup.sh`
  - `launchd/cc-reaper-monitor.sh`
  - `proc-janitor/config.toml`
  - `README.md`
  - optional validation script(s) for shell/pattern checks
- No new runtime dependency is required.
- No API, schema, or install-time breaking change is expected.
