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
    # Only kill groups whose leader is a Claude session (stream-json subagent)
    # Skip intentional daemons (worker-service --daemon) and non-Claude leaders
    local leader_cmd
    leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)
    if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|claude.*--session-id"; then
      continue
    fi
    # Verify group contains Claude/MCP processes
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
  local mcp_count=$(ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[b]un.*worker-service" | grep -v grep | wc -l | tr -d ' ')

  if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ]; then
    echo "No orphan processes found."
    return 0
  fi

  [ "$pgid_kills" -gt 0 ] && echo "  PGID-based: killed $pgid_kills processes"
  [ "$orphan_count" -gt 0 ] || [ "$mcp_count" -gt 0 ] && echo "  Pattern fallback: $orphan_count subagents, $mcp_count MCP processes"

  # Pattern-based kills for stragglers
  ps aux | grep "[c]laude.*stream-json" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  ps aux | grep "[b]un.*worker-service" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
  # NOTE: claude-mem, chroma-mcp, context7, supabase, stripe are NOT killed —
  # they are long-running MCP servers shared across sessions.

  # PPID=1 fallback for any remaining orphans (excludes long-running MCP servers)
  ps -eo pid,ppid,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]px.*mcp-server|[w]orker-service\.cjs" | awk '{print $1}' | xargs kill 2>/dev/null

  sleep 1
  local remaining=$(ps aux | grep -E "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" | grep -v grep | wc -l | tr -d ' ')
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
  ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential-thinking|[w]orker-service|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service|[n]pm exec @supabase" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d processes, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Orphans (PPID=1) ---"
  ps -eo pid,ppid,rss,%cpu,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem" | awk '{sum+=$3; cpu+=$4; count++} END {printf "  %d orphans, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

  echo "--- Total ---"
  ps aux | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential-thinking|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3} END {printf "  %.0f MB (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

# Calculate tree RSS (MB) for a given PID: process + children + grandchildren
_claude_tree_rss() {
  local pid=$1
  local rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
  [ -z "$rss" ] && echo 0 && return
  local tree_mb=$((rss / 1024))

  local children=()
  while IFS= read -r cpid; do
    [ -z "$cpid" ] && continue
    children+=("$cpid")
    local crss=$(ps -p "$cpid" -o rss= 2>/dev/null | tr -d ' ')
    [ -n "$crss" ] && tree_mb=$((tree_mb + crss / 1024))
  done < <(pgrep -P "$pid" 2>/dev/null)

  for cpid in "${children[@]}"; do
    while IFS= read -r gcpid; do
      [ -z "$gcpid" ] && continue
      local gcrss=$(ps -p "$gcpid" -o rss= 2>/dev/null | tr -d ' ')
      [ -n "$gcrss" ] && tree_mb=$((tree_mb + gcrss / 1024))
    done < <(pgrep -P "$cpid" 2>/dev/null)
  done

  echo "$tree_mb"
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

    # Count descendant processes and calculate tree RAM
    local child_count=0
    local tree_ram=$(_claude_tree_rss "$pid")
    while IFS= read -r cpid; do
      [ -z "$cpid" ] && continue
      child_count=$((child_count + 1))
      while IFS= read -r gcpid; do
        [ -z "$gcpid" ] && continue
        child_count=$((child_count + 1))
      done < <(pgrep -P "$cpid" 2>/dev/null)
    done < <(pgrep -P "$pid" 2>/dev/null)

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

# Automatic session guard: kills bloated (RSS threshold) and idle sessions
# Usage: claude-guard [--dry-run]
# Config env vars:
#   CC_MAX_SESSIONS  — max allowed sessions (default: 3)
#   CC_IDLE_THRESHOLD — CPU% below which a session is idle (default: 1)
#   CC_MAX_RSS_MB    — tree RSS threshold in MB; sessions exceeding this are killed (default: 4096)
claude-guard() {
  local dry_run=false
  [ "$1" = "--dry-run" ] && dry_run=true

  # ─── Configuration ─────────────────────────────────────────────────────
  local max_sessions=${CC_MAX_SESSIONS:-3}
  local idle_threshold=${CC_IDLE_THRESHOLD:-1}
  local max_rss_mb=${CC_MAX_RSS_MB:-4096}

  # Validate CC_MAX_RSS_MB is numeric
  if ! echo "$max_rss_mb" | grep -qE '^[0-9]+$'; then
    echo "  WARNING: CC_MAX_RSS_MB='$max_rss_mb' is not numeric, using default 4096"
    max_rss_mb=4096
  fi

  echo "=== Claude Guard ==="
  echo "  Config: max_sessions=$max_sessions, idle_threshold=${idle_threshold}%, max_rss=${max_rss_mb} MB"
  echo ""

  # ─── Gather sessions ───────────────────────────────────────────────────
  local session_pids=()
  while IFS= read -r line; do
    session_pids+=("$line")
  done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

  local session_count=${#session_pids[@]}
  if [ "$session_count" -eq 0 ]; then
    echo "  No Claude Code sessions running."
    return 0
  fi

  # ─── Classify sessions ─────────────────────────────────────────────────
  local bloated_pids=()
  local bloated_rss=()
  local idle_pids=()
  local idle_etimes=()
  local live_count=0

  printf "  %-7s %8s %6s %-14s %s\n" "PID" "TREE_MB" "CPU%" "ELAPSED" "STATUS"
  printf "  %-7s %8s %6s %-14s %s\n" "-------" "--------" "------" "--------------" "--------"

  for pid in "${session_pids[@]}"; do
    local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue

    local cpu=$(echo "$info" | awk '{print $2}')
    local etime=$(echo "$info" | awk '{print $3}')
    local tree_mb=$(_claude_tree_rss "$pid")
    local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')

    # Determine status: bloated takes priority over idle
    local status="LIVE"
    if [ "$tree_mb" -ge "$max_rss_mb" ]; then
      status="[BLOATED]"
      bloated_pids+=("$pid")
      bloated_rss+=("$tree_mb")
    elif [ "$cpu_int" -lt "$idle_threshold" ]; then
      status="[IDLE]"
      idle_pids+=("$pid")
      idle_etimes+=("$etime")
    else
      live_count=$((live_count + 1))
    fi

    printf "  %-7s %7s %6s %-14s %s\n" "$pid" "${tree_mb}" "${cpu}%" "$etime" "$status"
  done

  echo ""
  echo "  Sessions: $session_count total, ${#bloated_pids[@]} bloated, ${#idle_pids[@]} idle, $live_count live"

  # ─── Phase 1: Kill bloated sessions (regardless of count) ──────────────
  local killed=0
  local freed_mb=0

  if [ ${#bloated_pids[@]} -gt 0 ]; then
    echo ""
    echo "  --- Killing bloated sessions (tree RSS > ${max_rss_mb} MB) ---"
    for i in "${!bloated_pids[@]}"; do
      local bpid=${bloated_pids[$i]}
      local brss=${bloated_rss[$i]}
      if $dry_run; then
        echo "  [DRY-RUN] Would kill PID $bpid (tree RSS: ${brss} MB, threshold: ${max_rss_mb} MB)"
      else
        # Get PGID for group kill
        local pgid=$(ps -o pgid= -p "$bpid" 2>/dev/null | tr -d ' ')
        if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
          kill -- -"$pgid" 2>/dev/null
        else
          kill "$bpid" 2>/dev/null
        fi
        echo "  Killed PID $bpid (tree RSS: ${brss} MB, threshold: ${max_rss_mb} MB)"
        killed=$((killed + 1))
        freed_mb=$((freed_mb + brss))
        # macOS desktop notification
        osascript -e "display notification \"Killed session PID $bpid — ${brss} MB (threshold: ${max_rss_mb} MB)\" with title \"Claude Guard\" subtitle \"Bloated session reaped\"" 2>/dev/null &
      fi
    done
  fi

  # ─── Phase 2: Kill idle sessions if over max_sessions ──────────────────
  local remaining=$((session_count - killed))
  if [ "$remaining" -gt "$max_sessions" ] && [ ${#idle_pids[@]} -gt 0 ]; then
    local to_kill=$((remaining - max_sessions))
    [ "$to_kill" -gt "${#idle_pids[@]}" ] && to_kill=${#idle_pids[@]}

    echo ""
    echo "  --- Killing $to_kill idle session(s) to reach limit of $max_sessions ---"
    for i in $(seq 0 $((to_kill - 1))); do
      local ipid=${idle_pids[$i]}
      local ietime=${idle_etimes[$i]}
      local irss=$(_claude_tree_rss "$ipid")
      if $dry_run; then
        echo "  [DRY-RUN] Would kill PID $ipid (idle ${ietime}, tree RSS: ${irss} MB)"
      else
        local pgid=$(ps -o pgid= -p "$ipid" 2>/dev/null | tr -d ' ')
        if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
          kill -- -"$pgid" 2>/dev/null
        else
          kill "$ipid" 2>/dev/null
        fi
        echo "  Killed PID $ipid (idle ${ietime}, tree RSS: ${irss} MB)"
        killed=$((killed + 1))
        freed_mb=$((freed_mb + irss))
      fi
    done
  fi

  # ─── Summary ───────────────────────────────────────────────────────────
  echo ""
  if [ "$killed" -gt 0 ]; then
    echo "  Reaped $killed session(s), freed ~${freed_mb} MB"
    # Summary notification
    if ! $dry_run; then
      osascript -e "display notification \"Reaped $killed session(s), freed ~${freed_mb} MB\" with title \"Claude Guard\" subtitle \"Cleanup complete\"" 2>/dev/null &
    fi
  elif $dry_run && [ ${#bloated_pids[@]} -eq 0 ] && [ "$remaining" -le "$max_sessions" ]; then
    echo "  All clear — no sessions to reap."
  elif ! $dry_run; then
    echo "  All clear — no sessions to reap."
  fi
}
