#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.

# Kill orphan subagents (stream-json pattern)
ps aux | grep "[c]laude.*stream-json" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan MCP servers not attached to any TTY (background orphans)
# Includes generic mcp-server-* pattern to catch third-party MCP servers (Cloudflare, GitHub, etc.)
ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[n]ode.*sequential" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan claude-mem worker-service daemons (background)
ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan claude-mem MCP servers (background)
ps aux | grep "[n]ode.*claude-mem.*mcp-server" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan chroma-mcp (background python process, including uv/uvx spawned)
ps aux | grep -E "[c]hroma-mcp.*persistent|[u]v.*chroma-mcp|[p]ython.*chroma-mcp" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

# Kill orphan bun worker-service processes (background)
ps aux | grep "[b]un.*worker-service" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
