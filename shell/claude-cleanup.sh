# Claude Code cleanup shell functions
# Add to ~/.zshrc or ~/.bashrc: source /path/to/claude-cleanup.sh

# Immediately kill orphan Claude Code processes
claude-cleanup() {
  echo "=== Claude Code Orphan Process Cleanup ==="

  # ─── PGID-based cleanup (primary) ────────────────────────────────────────
  # Find orphaned process groups: the PGID leader has PPID=1 (reparented to launchd)
  # and the group contains Claude-related processes. Kill entire group at once.
  local pgid_kills=0
  local orphan_pgids
  orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)
  for pgid in $orphan_pgids; do
    # Check if this group contains Claude/MCP processes
    local match_count
    match_count=$(ps -eo pgid,command 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid' | grep -cE "claude|mcp|chroma|worker-service" 2>/dev/null || echo 0)
    if [ "$match_count" -gt 0 ]; then
      local group_pids
      group_pids=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
      local group_size
      group_size=$(echo "$group_pids" | wc -l | tr -d ' ')
      echo "  Killing orphaned process group PGID=$pgid ($group_size processes)"
      kill -- -"$pgid" 2>/dev/null
      pgid_kills=$((pgid_kills + group_size))
    fi
  done

  # ─── Pattern-based fallback ──────────────────────────────────────────────
  # Catches processes that escaped their process group (e.g., called setsid())
  local orphan_count=$(ps aux | grep -E "[c]laude.*stream-json|[c]laude.*--dangerously.*\?\?" | grep -v grep | wc -l | tr -d ' ')
  local mcp_count=$(ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[u]v.*chroma-mcp|[u]vx.*chroma-mcp|[b]un.*worker-service|[n]ode.*claude-mem" | grep -v grep | wc -l | tr -d ' ')

  if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ]; then
    echo "No orphan processes found."
    return 0
  fi

  [ "$pgid_kills" -gt 0 ] && echo "  PGID-based: killed $pgid_kills processes"
  [ "$orphan_count" -gt 0 ] || [ "$mcp_count" -gt 0 ] && echo "  Pattern fallback: $orphan_count subagents, $mcp_count MCP processes"

  # Pattern-based kills for stragglers
  ps aux | grep "[c]laude.*stream-json" | awk '{print $2}' | xargs kill 2>/dev/null
  ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep "[n]ode.*claude-mem.*mcp-server" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep -E "[u]v.*chroma-mcp|[u]vx.*chroma-mcp|[p]ython.*chroma-mcp" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep "[b]un.*worker-service" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

  # PPID=1 fallback for any remaining orphans
  ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem" | awk '{print $1}' | xargs kill 2>/dev/null

  sleep 1
  local remaining=$(ps aux | grep -E "[c]laude.*stream-json|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" | grep -v grep | wc -l | tr -d ' ')
  echo "Cleaned. Remaining: $remaining processes"
}

# Show Claude Code RAM usage summary (read-only, no killing)
claude-ram() {
  echo "=== Claude Code RAM Usage ==="
  echo ""

  # --- Per-session breakdown ---
  echo "--- CLI Sessions (per-process) ---"
  printf "  %-7s %8s %6s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED"
  ps -eo pid,rss,%cpu,etime,command | grep "[c]laude --dangerously" | awk '{printf "  %-7s %7d %6s %s\n", $1, $2/1024, $3"%", $4}'
  local session_stats=$(ps aux | grep "[c]laude --dangerously" | awk '{sum+=$6; count++} END {printf "%d %d", count, sum/1024}')
  local session_count=$(echo "$session_stats" | awk '{print $1}')
  local session_mb=$(echo "$session_stats" | awk '{print $2}')
  echo "  Total: $session_count sessions, ${session_mb} MB"

  # Session count warning
  if [ "$session_count" -ge 3 ]; then
    echo ""
    echo "  *** WARNING: $session_count sessions open! Consider closing idle ones. ***"
    echo "  *** Run 'claude-sessions' for details. ***"
  fi

  echo ""
  echo "--- Subagents ---"
  ps aux | grep "[c]laude.*stream-json" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d subagents, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- MCP Servers ---"
  ps aux | grep -E "[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential|[w]orker-service|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d processes, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Orphans (PPID=1) ---"
  ps -eo pid,ppid,rss,%cpu,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem" | awk '{sum+=$3; cpu+=$4; count++} END {printf "  %d orphans, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Total ---"
  ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3} END {printf "  %.0f MB (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

# List all active Claude Code sessions with idle detection
claude-sessions() {
  echo "=== Claude Code Active Sessions ==="
  echo ""

  printf "  %-7s %8s %6s %-14s %-8s %s\n" "PID" "RSS(MB)" "CPU%" "ELAPSED" "STATUS" "CHILDREN"
  printf "  %-7s %8s %6s %-14s %-8s %s\n" "-------" "--------" "------" "--------------" "--------" "--------"

  # Use process substitution to avoid subshell variable loss

  # Get session PIDs into an array via process substitution
  local session_pids=()
  while IFS= read -r line; do
    session_pids+=("$line")
  done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

  local session_count=0
  local idle_count=0
  local total_mb=0

  for pid in "${session_pids[@]}"; do
    # Get process info
    local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
    if [ -z "$info" ]; then continue; fi

    local rss=$(echo "$info" | awk '{print $1}')
    local cpu=$(echo "$info" | awk '{print $2}')
    local etime=$(echo "$info" | awk '{print $3}')
    local rss_mb=$((rss / 1024))

    # Determine idle status: CPU < 1.0% = idle
    local proc_status="ACTIVE"
    local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
    if [ "$cpu_int" -lt 1 ]; then
      proc_status="[IDLE]"
      idle_count=$((idle_count + 1))
    fi

    # Count all descendant processes and their RAM
    local child_count=0
    local tree_ram=$rss_mb

    # Direct children
    local children=()
    while IFS= read -r cpid; do
      [ -z "$cpid" ] && continue
      children+=("$cpid")
      child_count=$((child_count + 1))
      local crss=$(ps -p "$cpid" -o rss= 2>/dev/null | tr -d ' ')
      [ -n "$crss" ] && tree_ram=$((tree_ram + crss / 1024))
    done < <(pgrep -P "$pid" 2>/dev/null)

    # Grandchildren
    for cpid in "${children[@]}"; do
      while IFS= read -r gcpid; do
        [ -z "$gcpid" ] && continue
        child_count=$((child_count + 1))
        local gcrss=$(ps -p "$gcpid" -o rss= 2>/dev/null | tr -d ' ')
        [ -n "$gcrss" ] && tree_ram=$((tree_ram + gcrss / 1024))
      done < <(pgrep -P "$cpid" 2>/dev/null)
    done

    printf "  %-7s %7s %6s %-14s %-8s %s (%s MB tree)\n" \
      "$pid" "${rss_mb}" "${cpu}%" "$etime" "$proc_status" "$child_count" "$tree_ram"

    session_count=$((session_count + 1))
    total_mb=$((total_mb + tree_ram))
  done

  echo ""
  echo "  Sessions: $session_count total, $idle_count idle"
  echo "  Total RAM (with children): ${total_mb} MB ($(awk "BEGIN {printf \"%.1f\", $total_mb/1024}")  GB)"

  if [ "$idle_count" -gt 0 ] && [ "$session_count" -gt 0 ]; then
    local idle_mb=$((total_mb * idle_count / session_count))
    echo ""
    echo "  TIP: Close idle sessions in their iTerm tabs to free ~${idle_mb} MB"
    echo "       Or use '/exit' in each idle Claude Code session."
  fi

  if [ "$session_count" -ge 4 ]; then
    echo ""
    echo "  WARNING: $session_count sessions is excessive. Each session + MCP servers = 400-900 MB."
    echo "  Consider keeping max 2-3 active sessions."
  fi
}
