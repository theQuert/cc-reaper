# Claude Code cleanup shell functions
# Add to ~/.zshrc or ~/.bashrc: source /path/to/claude-cleanup.sh

# Shared-service and user-process protections for agent cleanup.
_cc_reaper_protected_pattern() {
  echo "node.*(dev-server|http-server|next.*server)|pm2|npm exec @supabase|mcp-server-supabase|supabase.*mcp|npm exec @stripe|@stripe/mcp|mcp-server-stripe|stripe.*mcp|claude-mem|chroma-mcp|context7|context7-mcp|cloudflare/mcp-server|mcp-server-cloudflare|mcp-remote|sequentialthinking|codex.*mcp|ChatGPT\\.app|cmux\\.app|Bitdefender|mdworker|mds_stores"
}

_cc_reaper_is_protected_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "$(_cc_reaper_protected_pattern)"
}

_cc_reaper_agent_stale_seconds() {
  local minutes=${CC_AGENT_STALE_MINUTES:-360}
  if ! echo "$minutes" | grep -qE '^[0-9]+$' || [ "$minutes" -eq 0 ]; then
    minutes=360
  fi
  echo $((minutes * 60))
}

_cc_reaper_etime_to_seconds() {
  local etime=${1// /}
  local days=0
  local time_part=$etime
  if [[ "$time_part" == *-* ]]; then
    days=${time_part%%-*}
    time_part=${time_part#*-}
  fi

  local a=0 b=0 c=0
  IFS=: read -r a b c <<< "$time_part"
  if [ -n "$c" ]; then
    echo $((days * 86400 + a * 3600 + b * 60 + c))
  elif [ -n "$b" ]; then
    echo $((days * 86400 + a * 60 + b))
  else
    echo $((days * 86400 + a))
  fi
}

_cc_reaper_is_stale_etime() {
  local etime=$1
  local seconds=$(_cc_reaper_etime_to_seconds "$etime")
  [ "$seconds" -ge "$(_cc_reaper_agent_stale_seconds)" ]
}

_cc_reaper_is_detached_or_orphan() {
  local ppid=$1
  local tty=$2
  [ "$ppid" = "1" ] || [ "$tty" = "??" ] || [ "$tty" = "?" ]
}

_cc_reaper_is_agent_browser_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "agent-browser-darwin-arm64|Google Chrome for Testing.*agent-browser-chrome-|agent-browser-chrome-"
}

_cc_reaper_is_puppeteer_chrome_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "puppeteer_dev_chrome_profile-"
}

_cc_reaper_is_codex_agent_cmd() {
  local cmd=$1
  if echo "$cmd" | grep -qE "codex app-server|app-server-broker"; then
    return 1
  fi
  echo "$cmd" | grep -qE "node /usr/local/bin/codex( --yolo| resume|$)|@openai/codex.*/codex/codex( --yolo| resume|$)|/codex/codex( --yolo| resume|$)"
}

_cc_reaper_is_agent_mcp_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "npm exec @upstash/context7-mcp|context7-mcp|chrome-devtools-mcp|npm exec mcp-remote|mcp-remote|npm exec mcp-|npx.*mcp-server"
}

_cc_reaper_is_agent_cleanup_candidate() {
  local ppid=$1
  local tty=$2
  local etime=$3
  local cmd=$4

  _cc_reaper_is_protected_cmd "$cmd" && return 1

  if _cc_reaper_is_agent_browser_cmd "$cmd" || _cc_reaper_is_puppeteer_chrome_cmd "$cmd"; then
    [ "$ppid" = "1" ] || _cc_reaper_is_stale_etime "$etime"
    return
  fi

  if _cc_reaper_is_codex_agent_cmd "$cmd" || _cc_reaper_is_agent_mcp_cmd "$cmd"; then
    [ "$ppid" = "1" ] || { _cc_reaper_is_detached_or_orphan "$ppid" "$tty" && _cc_reaper_is_stale_etime "$etime"; }
    return
  fi

  return 1
}

_cc_reaper_kill_group_filtered() {
  local pgid=$1
  local killed=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local pid_cmd
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    _cc_reaper_is_protected_cmd "$pid_cmd" && continue
    kill "$pid" 2>/dev/null && killed=$((killed + 1))
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
  echo "$killed"
}

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
    if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|claude.*--session-id|node /usr/local/bin/codex( --yolo| resume|$)|@openai/codex.*/codex/codex( --yolo| resume|$)|/codex/codex( --yolo| resume|$)"; then
      continue
    fi
    # Verify group contains Claude/MCP processes
    local match_count
    match_count=$(ps -eo pgid,command 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid' | grep -cE "claude|codex|mcp|chroma|worker-service|agent-browser|Chrome for Testing|puppeteer_dev_chrome_profile" 2>/dev/null || echo 0)
    if [ "$match_count" -gt 0 ]; then
      local group_pids
      group_pids=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
      local group_size
      group_size=$(echo "$group_pids" | wc -l | tr -d ' ')
      echo "  Killing orphaned process group PGID=$pgid ($group_size processes)"
      local killed_in_group
      killed_in_group=$(_cc_reaper_kill_group_filtered "$pgid")
      pgid_kills=$((pgid_kills + killed_in_group))
    fi
  done

  # ─── Pattern-based fallback ──────────────────────────────────────────────
  # Catches processes that escaped their process group (e.g., called setsid())
  local orphan_count=$(ps aux | grep -E "[c]laude.*stream-json|[c]laude.*--dangerously.*\?\?" | grep -v grep | wc -l | tr -d ' ')
  local mcp_count=$(ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[b]un.*worker-service" | grep -v grep | wc -l | tr -d ' ')
  local agent_count=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local pid ppid tty etime cmd
    pid=$(echo "$line" | awk '{print $1}')
    ppid=$(echo "$line" | awk '{print $2}')
    tty=$(echo "$line" | awk '{print $3}')
    etime=$(echo "$line" | awk '{print $4}')
    cmd=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s ", $i; print ""}')

    if _cc_reaper_is_agent_cleanup_candidate "$ppid" "$tty" "$etime" "$cmd"; then
      echo "  Killing stale agent process PID=$pid ELAPSED=$etime CMD=$(echo "$cmd" | head -c 100)"
      kill "$pid" 2>/dev/null && agent_count=$((agent_count + 1))
    fi
  done < <(ps -eo pid=,ppid=,tty=,etime=,command= 2>/dev/null)

  if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ] && [ "$agent_count" -eq 0 ]; then
    echo "No orphan processes found."
    return 0
  fi

  [ "$pgid_kills" -gt 0 ] && echo "  PGID-based: killed $pgid_kills processes"
  [ "$orphan_count" -gt 0 ] || [ "$mcp_count" -gt 0 ] && echo "  Pattern fallback: $orphan_count subagents, $mcp_count MCP processes"
  [ "$agent_count" -gt 0 ] && echo "  Agent fallback: killed $agent_count stale browser/Codex processes"

  # PPID=1 fallback: remaining orphans matching target patterns
  # Protected-pattern whitelist applied — shared MCP services (context7, mcp-remote,
  # supabase, stripe, etc.) are skipped even if orphaned.
  ps -eo pid=,ppid=,command= 2>/dev/null | awk '$2 == 1' | while IFS= read -r line; do
    local _pid _cmd
    _pid=$(echo "$line" | awk '{print $1}')
    _cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
    if echo "$_cmd" | grep -qE "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[w]orker-service\.cjs.*--daemon|[b]un.*worker-service"; then
      _cc_reaper_is_protected_cmd "$_cmd" && continue
      kill "$_pid" 2>/dev/null
    fi
  done

  sleep 1
  local remaining=$(ps aux | grep -E "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[a]gent-browser-darwin-arm64|puppeteer_dev_chrome_profile|agent-browser-chrome-|[c]odex --yolo" | grep -v grep | wc -l | tr -d ' ')
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

# Count open file descriptors for a given PID (via lsof)
_claude_process_fds() {
  local pid=$1
  lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
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

# Show file descriptor usage for Claude Code processes
claude-fd() {
  echo "=== Claude Code File Descriptor Usage ==="
  echo ""

  # ─── System FD limits ─────────────────────────────────────────────────
  local sys_max=$(sysctl -n kern.maxfiles 2>/dev/null || echo "unknown")
  local proc_max=$(sysctl -n kern.maxfilesperproc 2>/dev/null || echo "unknown")
  local ulimit_n=$(ulimit -n 2>/dev/null || echo "unknown")
  echo "  System limits: kern.maxfiles=$sys_max  kern.maxfilesperproc=$proc_max  ulimit=$ulimit_n"
  echo ""

  # ─── Per-session FD count ──────────────────────────────────────────────
  local max_fd=${CC_MAX_FD:-10000}
  echo "--- CLI Sessions (FD threshold: $max_fd) ---"
  printf "  %-7s %8s %8s %6s %-14s %s\n" "PID" "FDs" "RSS(MB)" "CPU%" "ELAPSED" "STATUS"
  printf "  %-7s %8s %8s %6s %-14s %s\n" "-------" "--------" "--------" "------" "--------------" "--------"

  local session_pids=()
  while IFS= read -r line; do
    session_pids+=("$line")
  done < <(ps -eo pid,command | grep "[c]laude --dangerously" | awk '{print $1}')

  local total_fds=0
  local leak_count=0

  for pid in "${session_pids[@]}"; do
    local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue

    local rss=$(echo "$info" | awk '{print $1}')
    local cpu=$(echo "$info" | awk '{print $2}')
    local etime=$(echo "$info" | awk '{print $3}')
    local rss_mb=$((rss / 1024))
    local fds=$(_claude_process_fds "$pid")
    [ -z "$fds" ] && fds=0
    total_fds=$((total_fds + fds))

    local status=""
    if [ "$fds" -ge "$max_fd" ]; then
      status="[FD-LEAK]"
      leak_count=$((leak_count + 1))
    fi

    printf "  %-7s %8s %7s %6s %-14s %s\n" "$pid" "$fds" "${rss_mb}" "${cpu}%" "$etime" "$status"
  done

  if [ ${#session_pids[@]} -eq 0 ]; then
    echo "  No Claude Code sessions running."
  else
    echo ""
    echo "  Total: ${#session_pids[@]} sessions, $total_fds FDs, $leak_count leaking"
  fi

  # ─── VirtualMachine processes (read-only report) ───────────────────────
  echo ""
  echo "--- VirtualMachine Processes (read-only) ---"
  local vm_pids=()
  while IFS= read -r line; do
    vm_pids+=("$line")
  done < <(pgrep -f "com.apple.Virtualization.VirtualMachine" 2>/dev/null)

  if [ ${#vm_pids[@]} -eq 0 ]; then
    echo "  No VirtualMachine processes found."
  else
    printf "  %-7s %8s %8s %s\n" "PID" "FDs" "RSS(MB)" "NOTE"
    printf "  %-7s %8s %8s %s\n" "-------" "--------" "--------" "----"
    for pid in "${vm_pids[@]}"; do
      local fds=$(_claude_process_fds "$pid")
      local rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
      local rss_mb=$((${rss:-0} / 1024))
      local note=""
      [ "$fds" -ge "$max_fd" ] && note="WARNING: high FD count"
      printf "  %-7s %8s %7s  %s\n" "$pid" "$fds" "${rss_mb}" "$note"
    done
  fi

  # ─── Advice ────────────────────────────────────────────────────────────
  if [ "$leak_count" -gt 0 ]; then
    echo ""
    echo "  *** $leak_count session(s) exceeding FD threshold ($max_fd). ***"
    echo "  *** Run 'claude-guard' to auto-reap leaking sessions. ***"
  fi
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

# Kill a session's process group while preserving whitelisted MCP servers
# Usage: _claude_pgid_kill <pid>
_claude_pgid_kill() {
  local target_pid=$1
  local MCP_WHITELIST="supabase|@stripe/mcp|context7|claude-mem|chroma-mcp|chrome-devtools-mcp|mcp-remote|cloudflare/mcp-server|sequentialthinking|codex.*mcp"
  local pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
    while IFS= read -r pid; do
      [ -z "$pid" ] && continue
      local pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
      if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
        continue
      fi
      kill "$pid" 2>/dev/null
    done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
  else
    kill "$target_pid" 2>/dev/null
  fi
}

# Automatic session guard: kills bloated (RSS threshold) and idle sessions
# Usage: claude-guard [--dry-run]
# Config env vars:
#   CC_MAX_SESSIONS  — max allowed sessions (default: 3)
#   CC_IDLE_THRESHOLD — CPU% below which a session is idle (default: 1)
#   CC_MAX_RSS_MB    — tree RSS threshold in MB; sessions exceeding this are killed (default: 4096)
_cc_guard_etime_to_seconds() {
  echo "${1// /}" | awk '
    {
      days=0
      time_part=$0
      if (index(time_part, "-") > 0) {
        split(time_part, day_parts, "-")
        days=day_parts[1]+0
        time_part=day_parts[2]
      }
      split(time_part, parts, ":")
      if (length(parts[3]) > 0) {
        print days * 86400 + (parts[1]+0) * 3600 + (parts[2]+0) * 60 + (parts[3]+0)
      } else if (length(parts[2]) > 0) {
        print days * 86400 + (parts[1]+0) * 60 + (parts[2]+0)
      } else {
        print days * 86400 + (parts[1]+0)
      }
    }
  '
}

# Print TSV (pid, cpu, etime, command) for protected processes that have
# sustained CPU% >= cpu_threshold over etime >= min_minutes.
_cc_guard_runaway_protected_pids() {
  local cpu_threshold=$1
  local min_minutes=$2
  local protected_pattern
  protected_pattern=$(_cc_reaper_protected_pattern)
  local min_seconds=$((min_minutes * 60))
  ps -axo pid=,etime=,%cpu=,command= 2>/dev/null | while read -r pid etime cpu rest; do
    [ -z "$pid" ] && continue
    echo "$rest" | grep -qE "$protected_pattern" || continue
    awk -v a="$cpu" -v b="$cpu_threshold" 'BEGIN { exit !(a+0 >= b+0) }' || continue
    local secs
    secs=$(_cc_guard_etime_to_seconds "$etime")
    [ "$secs" -ge "$min_seconds" ] || continue
    printf "%s\t%s\t%s\t%s\n" "$pid" "$cpu" "$etime" "$rest"
  done
}

claude-guard() {
  local dry_run=false
  [ "$1" = "--dry-run" ] && dry_run=true

  # ─── Configuration ─────────────────────────────────────────────────────
  local max_sessions=${CC_MAX_SESSIONS:-3}
  local idle_threshold=${CC_IDLE_THRESHOLD:-1}
  local max_rss_mb=${CC_MAX_RSS_MB:-4096}
  local max_fd=${CC_MAX_FD:-10000}
  local runaway_cpu=${CC_RUNAWAY_CPU:-80}
  local runaway_min=${CC_RUNAWAY_MIN:-60}
  local runaway_grace=${CC_RUNAWAY_GRACE_SEC:-5}
  local runaway_disable=${CC_RUNAWAY_DISABLE:-0}

  # Validate numeric configs
  if ! echo "$max_rss_mb" | grep -qE '^[0-9]+$'; then
    echo "  WARNING: CC_MAX_RSS_MB='$max_rss_mb' is not numeric, using default 4096"
    max_rss_mb=4096
  fi
  if ! echo "$max_fd" | grep -qE '^[0-9]+$'; then
    echo "  WARNING: CC_MAX_FD='$max_fd' is not numeric, using default 10000"
    max_fd=10000
  fi
  echo "$runaway_cpu" | grep -qE '^[0-9]+([.][0-9]+)?$' || runaway_cpu=80
  echo "$runaway_min" | grep -qE '^[0-9]+$' || runaway_min=60
  echo "$runaway_grace" | grep -qE '^[0-9]+$' || runaway_grace=5

  echo "=== Claude Guard ==="
  echo "  Config: max_sessions=$max_sessions, idle_threshold=${idle_threshold}%, max_rss=${max_rss_mb} MB, max_fd=$max_fd, runaway=${runaway_cpu}%/${runaway_min}min"
  echo ""

  # ─── Phase 0.5: Runaway protected processes ───────────────────────────
  if [ "$runaway_disable" != "1" ]; then
    local runaway_lines
    runaway_lines=$(_cc_guard_runaway_protected_pids "$runaway_cpu" "$runaway_min")
    if [ -n "$runaway_lines" ]; then
      echo "  --- Runaway protected processes (CPU >= ${runaway_cpu}% for >= ${runaway_min} min) ---"
      printf '%s\n' "$runaway_lines" | awk -F '\t' '
        { printf "  PID %-7s  CPU %6s%%  ETIME %-14s  %s\n", $1, $2, $3, substr($4, 1, 80) }
      '
      if $dry_run; then
        echo "  [DRY-RUN] Would SIGTERM the above PIDs (PGID-aware)."
      else
        echo "  Sending SIGTERM in ${runaway_grace} seconds (Ctrl+C to abort)..."
        sleep "$runaway_grace"
        local rkilled=0 rfreed=0
        while IFS=$'\t' read -r rpid rcpu retime rrest; do
          [ -z "$rpid" ] && continue
          local rrss
          rrss=$(_claude_tree_rss "$rpid" 2>/dev/null || echo 0)
          _claude_pgid_kill "$rpid" >/dev/null 2>&1
          rkilled=$((rkilled + 1))
          rfreed=$((rfreed + ${rrss:-0}))
          osascript -e "display notification \"Reaped runaway PID $rpid (CPU ${rcpu}%, etime ${retime})\" with title \"Claude Guard\" subtitle \"Runaway protected process\"" 2>/dev/null &
        done <<< "$runaway_lines"
        echo "  Reaped $rkilled runaway protected process(es), freed ~${rfreed} MB"
      fi
      echo ""
    fi
  fi

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
  local fdleak_pids=()
  local fdleak_fds=()
  local bloated_pids=()
  local bloated_rss=()
  local idle_pids=()
  local idle_etimes=()
  local live_count=0

  printf "  %-7s %8s %6s %6s %-14s %s\n" "PID" "TREE_MB" "FDs" "CPU%" "ELAPSED" "STATUS"
  printf "  %-7s %8s %6s %6s %-14s %s\n" "-------" "--------" "------" "------" "--------------" "--------"

  for pid in "${session_pids[@]}"; do
    local info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
    [ -z "$info" ] && continue

    local cpu=$(echo "$info" | awk '{print $2}')
    local etime=$(echo "$info" | awk '{print $3}')
    local tree_mb=$(_claude_tree_rss "$pid")
    local cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
    local fds=$(_claude_process_fds "$pid")
    [ -z "$fds" ] && fds=0

    # Determine status: fd-leak > bloated > idle
    local status="LIVE"
    if [ "$fds" -ge "$max_fd" ]; then
      status="[FD-LEAK]"
      fdleak_pids+=("$pid")
      fdleak_fds+=("$fds")
    elif [ "$tree_mb" -ge "$max_rss_mb" ]; then
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

    printf "  %-7s %7s %6s %6s %-14s %s\n" "$pid" "${tree_mb}" "$fds" "${cpu}%" "$etime" "$status"
  done

  echo ""
  echo "  Sessions: $session_count total, ${#fdleak_pids[@]} fd-leak, ${#bloated_pids[@]} bloated, ${#idle_pids[@]} idle, $live_count live"

  # ─── Phase 0: Kill FD-leaking sessions (regardless of count) ──────────
  local killed=0
  local freed_mb=0

  if [ ${#fdleak_pids[@]} -gt 0 ]; then
    echo ""
    echo "  --- Killing FD-leaking sessions (FDs > $max_fd) ---"
    for i in "${!fdleak_pids[@]}"; do
      local fpid=${fdleak_pids[$i]}
      local ffds=${fdleak_fds[$i]}
      local frss=$(_claude_tree_rss "$fpid")
      if $dry_run; then
        echo "  [DRY-RUN] Would kill PID $fpid (FDs: $ffds, threshold: $max_fd)"
      else
        _claude_pgid_kill "$fpid"
        echo "  Killed PID $fpid (FDs: $ffds, threshold: $max_fd)"
        killed=$((killed + 1))
        freed_mb=$((freed_mb + frss))
        osascript -e "display notification \"Killed session PID $fpid — $ffds FDs (threshold: $max_fd)\" with title \"Claude Guard\" subtitle \"FD-leak session reaped\"" 2>/dev/null &
      fi
    done
  fi

  # ─── Phase 1: Kill bloated sessions (regardless of count) ──────────────

  if [ ${#bloated_pids[@]} -gt 0 ]; then
    echo ""
    echo "  --- Killing bloated sessions (tree RSS > ${max_rss_mb} MB) ---"
    for i in "${!bloated_pids[@]}"; do
      local bpid=${bloated_pids[$i]}
      local brss=${bloated_rss[$i]}
      if $dry_run; then
        echo "  [DRY-RUN] Would kill PID $bpid (tree RSS: ${brss} MB, threshold: ${max_rss_mb} MB)"
      else
        # Kill session group, preserving whitelisted MCP servers
        _claude_pgid_kill "$bpid"
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
        # Kill session group, preserving whitelisted MCP servers
        _claude_pgid_kill "$ipid"
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
