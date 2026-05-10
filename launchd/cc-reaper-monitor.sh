#!/bin/bash
# cc-reaper orphan monitor — lightweight alternative to proc-janitor
# Runs periodically via macOS LaunchAgent to detect and kill orphaned
# Claude Code processes (PPID=1, reparented to launchd).
#
# Zero dependencies — no Homebrew, no Rust, just bash + launchd.

LOG_DIR="$HOME/.cc-reaper/logs"
LOG_FILE="$LOG_DIR/monitor.log"
mkdir -p "$LOG_DIR"

# Rotate log if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

protected_pattern() {
  echo "node.*(dev-server|http-server|next.*server)|pm2|npm exec @supabase|mcp-server-supabase|supabase.*mcp|npm exec @stripe|@stripe/mcp|mcp-server-stripe|stripe.*mcp|claude-mem|chroma-mcp|context7|context7-mcp|chrome-devtools-mcp|cloudflare/mcp-server|mcp-server-cloudflare|mcp-remote|sequentialthinking|sequential-thinking|codex.*mcp|ChatGPT\\.app|cmux\\.app|Bitdefender|mdworker|mds_stores"
}

is_protected_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "$(protected_pattern)"
}

agent_stale_seconds() {
  local minutes=${CC_AGENT_STALE_MINUTES:-360}
  if ! echo "$minutes" | grep -qE '^[0-9]+$' || [ "$minutes" -eq 0 ]; then
    minutes=360
  fi
  echo $((minutes * 60))
}

etime_to_seconds() {
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

is_stale_etime() {
  local etime=$1
  local seconds=$(etime_to_seconds "$etime")
  [ "$seconds" -ge "$(agent_stale_seconds)" ]
}

is_detached_or_orphan() {
  local ppid=$1
  local tty=$2
  [ "$ppid" = "1" ] || [ "$tty" = "??" ] || [ "$tty" = "?" ]
}

is_agent_browser_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "agent-browser-darwin-arm64|Google Chrome for Testing.*agent-browser-chrome-|agent-browser-chrome-"
}

is_puppeteer_chrome_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "puppeteer_dev_chrome_profile-"
}

is_codex_agent_cmd() {
  local cmd=$1
  if echo "$cmd" | grep -qE "codex app-server|app-server-broker"; then
    return 1
  fi
  echo "$cmd" | grep -qE "node /usr/local/bin/codex( --yolo| resume|$)|@openai/codex.*/codex/codex( --yolo| resume|$)|/codex/codex( --yolo| resume|$)"
}

is_agent_mcp_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "npm exec @upstash/context7-mcp|context7-mcp|chrome-devtools-mcp|npm exec mcp-remote|mcp-remote|npm exec mcp-|npx.*mcp-server"
}

is_existing_orphan_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "claude.*stream-json|node.*mcp-server|npx.*mcp-server|worker-service\.cjs|bun.*worker-service|node.*claude.*subagent"
}

is_cleanup_candidate() {
  local ppid=$1
  local tty=$2
  local etime=$3
  local cmd=$4

  is_protected_cmd "$cmd" && return 1

  if is_existing_orphan_cmd "$cmd"; then
    [ "$ppid" = "1" ] && return 0
  fi

  if is_agent_browser_cmd "$cmd" || is_puppeteer_chrome_cmd "$cmd"; then
    [ "$ppid" = "1" ] || is_stale_etime "$etime"
    return
  fi

  if is_codex_agent_cmd "$cmd" || is_agent_mcp_cmd "$cmd"; then
    [ "$ppid" = "1" ] || { is_detached_or_orphan "$ppid" "$tty" && is_stale_etime "$etime"; }
    return
  fi

  return 1
}

kill_group_filtered() {
  local pgid=$1
  local killed=0
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    local pid_cmd
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    is_protected_cmd "$pid_cmd" && continue
    kill "$pid" 2>/dev/null && killed=$((killed + 1))
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
  echo "$killed"
}

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# Find orphaned process groups whose leader has PPID=1 and contain Claude/Codex processes.
# Kill entire group at once — catches siblings that pattern matching might miss.
killed_pgids=()
orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)
for pgid in $orphan_pgids; do
  # SAFETY: Only kill groups whose leader is a Claude/Codex agent process.
  # Never match by group membership — that risks killing Chrome, Cursor, or other apps
  # whose process groups happen to contain a "claude" or "mcp" subprocess.
  leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)
  if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|node /usr/local/bin/codex( --yolo| resume|$)|@openai/codex.*/codex/codex( --yolo| resume|$)|/codex/codex( --yolo| resume|$)"; then
    continue
  fi
  group_info=$(ps -eo pid,pgid,%cpu,%mem,command 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {printf "PID=%s CPU=%s%% MEM=%s%% ", $1, $3, $4}')
  log "KILL group PGID=$pgid ($group_info)"
  killed_in_group=$(kill_group_filtered "$pgid")
  if [ "$killed_in_group" -gt 0 ]; then
    killed_pgids+=("$pgid")
  fi
done

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped their process group (e.g., called setsid())
count=${#killed_pgids[@]}
kill_pids=()

while IFS= read -r line; do
  [ -z "$line" ] && continue
  pid=$(echo "$line" | awk '{print $1}')
  ppid=$(echo "$line" | awk '{print $2}')
  tty=$(echo "$line" | awk '{print $3}')
  cpu=$(echo "$line" | awk '{print $4}')
  mem=$(echo "$line" | awk '{print $5}')
  etime=$(echo "$line" | awk '{print $6}')
  cmd=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}')

  if is_cleanup_candidate "$ppid" "$tty" "$etime" "$cmd"; then
    # Skip if already killed via PGID
    already_killed=false
    if [ ${#killed_pgids[@]} -gt 0 ]; then
      pid_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      for kpgid in "${killed_pgids[@]}"; do
        [ "$pid_pgid" = "$kpgid" ] && already_killed=true && break
      done
    fi
    $already_killed && continue

    short_cmd=$(echo "$cmd" | head -c 100)
    log "KILL agent/orphan PID=$pid CPU=${cpu}% MEM=${mem}% ELAPSED=$etime CMD=$short_cmd"
    kill "$pid" 2>/dev/null
    kill_pids+=("$pid")
    count=$((count + 1))
  fi
done < <(ps -eo pid=,ppid=,tty=,%cpu=,%mem=,etime=,command= 2>/dev/null)

if [ "$count" -eq 0 ]; then
  exit 0
fi

# Wait briefly then SIGKILL any survivors
sleep 3
for pgid in "${killed_pgids[@]}"; do
  # Check if any process in the group survived
  survivors=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
  for pid in $survivors; do
    kill -9 "$pid" 2>/dev/null
    log "SIGKILL PID=$pid from group PGID=$pgid"
  done
done
for pid in "${kill_pids[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    log "SIGKILL PID=$pid (did not respond to SIGTERM)"
  fi
done

log "Cleaned $count orphan process group(s)/process(es)"
