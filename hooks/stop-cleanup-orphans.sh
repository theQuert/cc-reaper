#!/bin/bash
# Stop hook: Clean up orphan Claude subagent and MCP processes
# Runs when a Claude Code session ends
#
# Install: Copy to ~/.claude/hooks/ and add to ~/.claude/settings.json
# See README.md for setup instructions.
#
# Safety:
#   CC_STOP_HOOK_DISABLE=1     — Skip all cleanup (no-op)
#   CC_STOP_HOOK_AGGRESSIVE=1  — Skip PPID filtering, kill all PGID members
#                                (default: only PPID=1 — truly orphaned)

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

# ─── Shared MCP whitelist ────────────────────────────────────────────────────
MCP_WHITELIST="supabase|@stripe/mcp|context7|claude-mem|chroma-mcp|chrome-devtools-mcp|mcp-remote|cloudflare/mcp-server|sequentialthinking|codex.*mcp"

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
# Uses ps -eo for cross-platform compatibility (macOS "??" vs Linux "?")
ps -eo pid=,ppid=,command= 2>/dev/null | grep "[c]laude.*stream-json" | awk '$2 == 1 {print $1}' | xargs kill 2>/dev/null
ps -eo pid=,ppid=,command= 2>/dev/null | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking" | awk -v wl="$MCP_WHITELIST" '$2 == 1 && $0 !~ wl {print $1}' | xargs kill 2>/dev/null
ps -eo pid=,ppid=,command= 2>/dev/null | grep "[w]orker-service.cjs.*--daemon" | awk '$2 == 1 {print $1}' | xargs kill 2>/dev/null
# NOTE: claude-mem, chroma-mcp, context7 are NOT killed here — they are
# long-running MCP servers shared across sessions. PGID cleanup (above)
# handles same-session processes; these survive for other sessions.
ps -eo pid=,ppid=,command= 2>/dev/null | grep "[b]un.*worker-service" | awk '$2 == 1 {print $1}' | xargs kill 2>/dev/null

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
