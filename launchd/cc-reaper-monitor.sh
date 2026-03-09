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

# Find orphaned Claude/MCP processes (PPID=1)
# Uses bracket expressions to prevent matching grep itself
orphans=$(ps -eo pid,ppid,%cpu,%mem,etime,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem|[n]ode.*claude.*subagent")

if [ -z "$orphans" ]; then
  exit 0
fi

count=0
kill_pids=()
while IFS= read -r line; do
  pid=$(echo "$line" | awk '{print $1}')
  cpu=$(echo "$line" | awk '{print $3}')
  mem=$(echo "$line" | awk '{print $4}')
  etime=$(echo "$line" | awk '{print $5}')
  cmd=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | head -c 80)

  log "KILL orphan PID=$pid CPU=${cpu}% MEM=${mem}% ELAPSED=$etime CMD=$cmd"
  kill "$pid" 2>/dev/null
  kill_pids+=("$pid")

  count=$((count + 1))
done <<< "$orphans"

# Wait briefly then SIGKILL any survivors
if [ ${#kill_pids[@]} -gt 0 ]; then
  sleep 3
  for pid in "${kill_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
      log "SIGKILL PID=$pid (did not respond to SIGTERM)"
    fi
  done
fi

log "Cleaned $count orphan process(es)"
