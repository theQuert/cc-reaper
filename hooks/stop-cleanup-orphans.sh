#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.
#
# Safety:
#   CC_STOP_HOOK_DISABLE=1     — Skip all cleanup (no-op)
#   CC_STOP_HOOK_AGGRESSIVE=1  — Skip PPID filtering, kill PGID members (ancestors + MCP whitelist still protected)
#                                (default: only PPID=1 — truly orphaned)

[ "${CC_STOP_HOOK_DISABLE:-0}" = "1" ] && exit 0

# ─── Ancestor PID whitelist ──────────────────────────────────────────────────
# Walk the process tree from $$ upward, collecting all ancestor PIDs.
# The loop stops at PID 1 (init/systemd), which is never included because the
# kernel protects init from SIGTERM. These ancestors are NEVER killed by us —
# this prevents accidentally killing the Claude CLI when an intermediate shell
# (sh -c, bash -c) sits between the hook and the CLI process.
_ancestors=""
_pid=$$
while [ "$_pid" -gt 1 ] 2>/dev/null; do
  _ancestors="$_ancestors $_pid"
  _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
done

# ─── Shared MCP whitelist ────────────────────────────────────────────────────
MCP_WHITELIST="supabase|npm exec @stripe|@stripe/mcp|mcp-server-stripe|stripe.*mcp|context7|context7-mcp|claude-mem|chroma-mcp|chrome-devtools-mcp|mcp-remote|cloudflare/mcp-server|mcp-server-cloudflare|sequentialthinking|sequential-thinking|codex.*mcp"

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# This hook inherits the Claude session's process group (PGID).
# Kill processes in our group — catches ALL children including unknown
# third-party MCP servers, without needing pattern maintenance.
#
# PPID=1 FILTER: By default, ONLY processes whose parent has already exited
# (PPID=1, reparented to init) are killed. This prevents accidental termination
# of:
#   - The Claude CLI itself (would have PPID=shell != 1)
#   - Active subagents still processing (PPID=Claude CLI != 1)
#   - MCP servers that might be shared with other sessions (PPID != 1)
#
# Processes with PPID=1 are truly orphaned — their parent died, and they would
# leak until the next LaunchAgent/proc-janitor sweep. Killing them here is safe.
#
# WHITELIST: Long-running MCP servers shared across sessions are also excluded.
# CC_STOP_HOOK_AGGRESSIVE=1 skips the PPID=1 check (original behavior).

SESSION_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$SESSION_PGID" ] && [ "$SESSION_PGID" != "0" ] && [ "$SESSION_PGID" != "1" ]; then
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue

    # Never kill any ancestor process (Claude CLI, intermediate shells, init)
    if echo "$_ancestors" | grep -qw "$pid"; then
      continue
    fi

    # PPID filter: only kill truly orphaned processes (PPID=1)
    # Their parent is already dead, so they are safe to reap.
    if [ "${CC_STOP_HOOK_AGGRESSIVE:-0}" != "1" ]; then
      pid_ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$pid_ppid" != "1" ] && continue
    fi

    # Skip whitelisted MCP servers (shared across sessions)
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
      continue
    fi

    kill "$pid" 2>/dev/null
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$SESSION_PGID" '$2 == pgid {print $1}')
fi

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped the process group (e.g., called setsid())
# Only targets orphans (PPID=1) to avoid killing active processes.
# Target patterns are filtered through MCP_WHITELIST so shared MCP servers
# survive.
#
# CAVEAT: A user-managed daemon launched by launchd/systemd that matches one
# of the target patterns (e.g., `claude --stream-json` or
# `worker-service.cjs --daemon` started by a LaunchAgent) is legitimately
# PPID=1 by design and will be killed here. If you run such a daemon, either:
#   - export CC_STOP_HOOK_DISABLE=1 in the user environment, or
#   - extend MCP_WHITELIST above to include your daemon's command pattern.
ps -eo pid=,ppid=,command= 2>/dev/null | awk '$2 == 1' | while IFS= read -r line; do
  _pid=$(echo "$line" | awk '{print $1}')
  _cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
  if echo "$_cmd" | grep -qE "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[w]orker-service\.cjs.*--daemon|[b]un.*worker-service"; then
    echo "$_cmd" | grep -qE "$MCP_WHITELIST" && continue
    kill "$_pid" 2>/dev/null
  fi
done

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
