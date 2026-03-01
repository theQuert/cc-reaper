#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.

# Kill orphan subagents (stream-json pattern)
ps aux | grep "[c]laude.*stream-json" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan MCP servers not attached to any TTY (background orphans)
ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]ode.*context7|[n]ode.*sequential" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan claude-mem worker-service daemons (background)
ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan chroma-mcp (background python process)
ps aux | grep "[c]hroma-mcp.*persistent" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
