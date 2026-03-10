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

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# Find orphaned process groups whose leader has PPID=1 and contain Claude processes.
# Kill entire group at once — catches siblings that pattern matching might miss.
killed_pgids=()
orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)
for pgid in $orphan_pgids; do
  # SAFETY: Only kill groups whose leader is a Claude CLI session (stream-json subagent).
  # Never match by group membership — that risks killing Chrome, Cursor, or other apps
  # whose process groups happen to contain a "claude" or "mcp" subprocess.
  leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null)
  if ! echo "$leader_cmd" | grep -qE "claude.*stream-json"; then
    continue
  fi
  group_info=$(ps -eo pid,pgid,%cpu,%mem,command 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {printf "PID=%s CPU=%s%% MEM=%s%% ", $1, $3, $4}')
  log "KILL group PGID=$pgid ($group_info)"
  kill -- -"$pgid" 2>/dev/null
  killed_pgids+=("$pgid")
done

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped their process group (e.g., called setsid())
orphans=$(ps -eo pid,ppid,%cpu,%mem,etime,command | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem|[n]ode.*claude.*subagent")

count=${#killed_pgids[@]}
kill_pids=()

if [ -n "$orphans" ]; then
  while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    cpu=$(echo "$line" | awk '{print $3}')
    mem=$(echo "$line" | awk '{print $4}')
    etime=$(echo "$line" | awk '{print $5}')
    cmd=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | head -c 80)

    # Skip if already killed via PGID
    already_killed=false
    if [ ${#killed_pgids[@]} -gt 0 ]; then
      pid_pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      for kpgid in "${killed_pgids[@]}"; do
        [ "$pid_pgid" = "$kpgid" ] && already_killed=true && break
      done
    fi
    $already_killed && continue

    log "KILL orphan PID=$pid CPU=${cpu}% MEM=${mem}% ELAPSED=$etime CMD=$cmd"
    kill "$pid" 2>/dev/null
    kill_pids+=("$pid")
    count=$((count + 1))
  done <<< "$orphans"
fi

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
