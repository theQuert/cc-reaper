## Why

Claude Code sessions leak memory at up to ~42 GB/hr due to unreleased streaming ArrayBuffers (see anthropics/claude-code#4953, @saif97's heapdump analysis). The existing `claude-guard` function only kills **idle** sessions, but active sessions can also balloon to multi-GB RSS in minutes. Users need a hard ceiling to prevent a single session from consuming all system memory.

## What Changes

- Add RSS threshold checking to `claude-guard` in `shell/claude-cleanup.sh`
- New `CC_MAX_RSS_MB` environment variable (default: 4096 MB) to configure the ceiling
- Sessions exceeding the threshold are marked `[BLOATED]` and killed via PGID regardless of idle/active status
- macOS desktop notification when a session is killed for exceeding RSS threshold
- `claude-guard --dry-run` output updated to show bloated sessions

## Capabilities

### New Capabilities
- `rss-threshold-reaper`: Automatic termination of Claude Code sessions whose tree RSS (session + all child processes) exceeds a configurable threshold, with PGID-based process group cleanup and user notification

### Modified Capabilities

## Impact

- `shell/claude-cleanup.sh`: `claude-guard` function gains RSS threshold logic alongside existing idle detection
- User environment: new optional `CC_MAX_RSS_MB` env var
- No breaking changes — existing idle-based behavior is preserved; RSS threshold is additive
