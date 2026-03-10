#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# This hook inherits the Claude session's process group (PGID).
# Kill all processes in our group — catches ALL children including unknown
# third-party MCP servers, without needing pattern maintenance.
SESSION_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$SESSION_PGID" ] && [ "$SESSION_PGID" != "0" ] && [ "$SESSION_PGID" != "1" ]; then
  # Kill group members except this script and the Claude CLI parent
  ps -eo pid,pgid 2>/dev/null | awk -v pgid="$SESSION_PGID" -v me="$$" -v parent="$PPID" \
    '$2 == pgid && $1 != me && $1 != parent {print $1}' | xargs kill 2>/dev/null
fi

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped the process group (e.g., called setsid())
# Only targets detached processes (TTY="??") to avoid killing active sessions.
ps aux | grep "[c]laude.*stream-json" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
# NOTE: claude-mem, chroma-mcp, context7 are NOT killed here — they are
# long-running MCP servers shared across sessions. PGID cleanup (above)
# handles same-session processes; these survive for other sessions.
ps aux | grep "[b]un.*worker-service" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
