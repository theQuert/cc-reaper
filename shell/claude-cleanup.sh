# Claude Code cleanup shell functions
# Add to ~/.zshrc or ~/.bashrc: source /path/to/claude-cleanup.sh

# Immediately kill orphan Claude Code processes
claude-cleanup() {
  echo "=== Claude Code Orphan Process Cleanup ==="
  local orphan_count=$(ps aux | grep -E "[c]laude.*stream-json|[c]laude.*--dangerously.*\?\?" | grep -v grep | wc -l | tr -d ' ')
  local mcp_count=$(ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]ode.*context7|[c]hroma-mcp" | grep -v grep | wc -l | tr -d ' ')

  if [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ]; then
    echo "No orphan processes found."
    return 0
  fi

  echo "Found: $orphan_count orphan subagents, $mcp_count MCP processes"

  # Kill orphan subagents (stream-json = subagent pattern)
  ps aux | grep "[c]laude.*stream-json" | awk '{print $2}' | xargs kill 2>/dev/null
  # Kill orphan MCP servers not attached to a TTY (background orphans)
  ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  # Kill orphan claude-mem worker-service daemons
  ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

  sleep 1
  local remaining=$(ps aux | grep -E "[c]laude.*stream-json|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-" | grep -v grep | wc -l | tr -d ' ')
  echo "Cleaned. Remaining: $remaining processes"
}

# Show Claude Code RAM usage summary (read-only, no killing)
claude-ram() {
  echo "=== Claude Code RAM Usage ==="
  echo "--- CLI sessions ---"
  ps aux | grep "[c]laude --dangerously" | awk '{sum+=$6; count++} END {printf "  %d sessions, %.0f MB\n", count, sum/1024}'
  echo "--- Subagents ---"
  ps aux | grep "[c]laude.*stream-json" | awk '{sum+=$6; count++} END {printf "  %d subagents, %.0f MB\n", count, sum/1024}'
  echo "--- MCP servers ---"
  ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential|[w]orker-service" | awk '{sum+=$6; count++} END {printf "  %d processes, %.0f MB\n", count, sum/1024}'
  echo "--- Total ---"
  ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential" | awk '{sum+=$6} END {printf "  %.0f MB (%.1f GB)\n", sum/1024, sum/1024/1024}'
}
