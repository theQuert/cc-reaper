#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.
#
# Safety:
#   CC_STOP_HOOK_DISABLE=1     — Skip all cleanup (no-op)
#   CC_STOP_HOOK_AGGRESSIVE=1  — Skip TTY filtering, kill all PGID members
#                                (original behavior, default: only detached TTY)

[ "${CC_STOP_HOOK_DISABLE:-0}" = "1" ] && exit 0

# ─── Ancestor PID whitelist ──────────────────────────────────────────────────
# Walk the process tree from $$ upward to PID 1, collecting all ancestor PIDs.
# These are NEVER killed — prevents accidentally killing the Claude CLI when an
# intermediate shell (sh -c, bash -c) sits between us and the CLI.
_ancestors=""
_pid=$$
while [ "$_pid" -gt 1 ] 2>/dev/null; do
  _ancestors="$_ancestors $_pid"
  _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
done

# ─── PGID-based cleanup (primary) ────────────────────────────────────────────
# This hook inherits the Claude session's process group (PGID).
# Kill all processes in our group — catches ALL children including unknown
# third-party MCP servers, without needing pattern maintenance.
#
# WHITELIST: Long-running MCP servers shared across sessions are excluded.
# They survive session ends so other sessions can continue using them.
# Pattern-based fallback below also excludes these (see NOTE comment).
#
# TTY FILTER: By default, only detached processes (TTY="?" or "??") are killed,
# preventing accidental termination of active terminal sessions. Set
# CC_STOP_HOOK_AGGRESSIVE=1 to skip this check and kill all group members.
MCP_WHITELIST="supabase|@stripe/mcp|context7|claude-mem|chroma-mcp|chrome-devtools-mcp|mcp-remote|cloudflare/mcp-server|sequentialthinking|codex.*mcp"

SESSION_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
if [ -n "$SESSION_PGID" ] && [ "$SESSION_PGID" != "0" ] && [ "$SESSION_PGID" != "1" ]; then
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue

    # Never kill any ancestor process (Claude CLI, intermediate shells, init)
    if echo "$_ancestors" | grep -qw "$pid"; then
      continue
    fi

    # Skip whitelisted MCP servers (shared across sessions)
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
      continue
    fi

    # TTY filter: only kill detached processes by default
    # (processes without a controlling terminal — TTY = "?" or "??")
    if [ "${CC_STOP_HOOK_AGGRESSIVE:-0}" != "1" ]; then
      pid_tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
      # Skip if process has a real controlling terminal (pts/0, ttys000, etc.)
      if [ -n "$pid_tty" ] && ! echo "$pid_tty" | grep -qE '^\?+$'; then
        continue
      fi
    fi

    kill "$pid" 2>/dev/null
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$SESSION_PGID" '$2 == pgid {print $1}')
fi

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped the process group (e.g., called setsid())
# Only targets detached processes (TTY="??") to avoid killing active sessions.
ps aux | grep "[c]laude.*stream-json" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
ps aux | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking" | grep -vE "$MCP_WHITELIST" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
ps aux | grep "[w]orker-service.cjs.*--daemon" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null
# NOTE: claude-mem, chroma-mcp, context7 are NOT killed here — they are
# long-running MCP servers shared across sessions. PGID cleanup (above)
# handles same-session processes; these survive for other sessions.
ps aux | grep "[b]un.*worker-service" | awk '$7 == "??" {print $2}' | xargs kill 2>/dev/null

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
