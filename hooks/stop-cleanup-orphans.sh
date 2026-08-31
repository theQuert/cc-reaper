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

# ─── Orphan-parent set ───────────────────────────────────────────────────────
# A process is a true orphan when its parent has exited and it was reparented.
# On macOS that target is PID 1 (launchd). On Linux, a process whose Claude
# session exited is reparented to the invoking user's `systemd --user` manager,
# NOT PID 1 — so PID=1-only filtering misses every orphan on Linux. Build the
# set of orphan-parent PPIDs once: always PID 1, plus this user's
# `systemd --user` manager(s) if present (matched by UID so another user's
# manager is never included). macOS / no-systemd hosts resolve to exactly
# " 1 ", so behavior there is unchanged. Space-padded for `case`/awk matching.
#
# The manager is identified by its EXECUTABLE, not by its command line, and the
# probe does not run off Linux at all. Searching full command text for the
# string put every process that merely MENTIONED it into the set - a shell
# running `echo "... systemd --user ..."`, a grep for it, this hook's own
# ancestor - and every child of such a process then passed the orphan filter
# below and was killed. Verified on 2026-08-21: on macOS, which has no systemd
# at all, a harmless `bash -c 'echo "systemd --user"; sleep'` matched, and so
# did its parent shell. `comm` carries only the executable name, so a process
# that talks about systemd no longer impersonates it.
_uid=$(id -u 2>/dev/null)
#
# argv is excluded from the inventory entirely, and asked per candidate afterwards.
# A process controls its own argv, embedded newlines included, so a row of
# `<live-pid> <uid> systemd --user` inside somebody's arguments forges a line in this
# very listing - and every child of that forged PID then passes the orphan filter
# below and is killed. The authoritative pass reads only pid, uid and comm, none of
# which a process can choose; `--user` is then confirmed by asking about that one PID.
if [ "$(uname -s 2>/dev/null)" = Linux ]; then
  _systemd_user_pids=""
  for _cand in $(ps -eo pid=,uid=,comm= 2>/dev/null \
                 | awk -v uid="$_uid" '$2 == uid && $3 == "systemd" {print $1}'); do
    # uid, comm and args together, in ONE query. Asking only for args would trust a
    # PID that had exited and been reused between the two calls: if the new occupant
    # happens to carry `--user` anywhere in its arguments it joins the orphan-parent
    # set, and every child of it then passes the orphan filter and is killed. The
    # recheck costs one `ps` per candidate, and there is normally exactly one.
    _u=""; _c=""; _rest=""
    read -r _u _c _rest <<EOF
$(ps -o uid=,comm=,args= -p "$_cand" 2>/dev/null)
EOF
    if [ "$_u" = "$_uid" ] && [ "$_c" = "systemd" ]; then
      case " $_rest " in
        *" --user"*) _systemd_user_pids="$_systemd_user_pids$_cand " ;;
      esac
    fi
  done
else
  _systemd_user_pids=""
fi
ORPHAN_PPIDS=" 1 ${_systemd_user_pids}"

# Both kill paths below ask the same question, so they ask it through the same
# predicate. It was written out twice before, and only the copy in the PGID sweep
# was ever given the ancestor list — the pattern fallback killed the CLI this hook
# runs under whenever that CLI's PPID landed in the orphan-parent set.
is_ancestor() { echo "$_ancestors" | grep -qw "$1"; }

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
    is_ancestor "$pid" && continue

    # PPID filter: only kill truly orphaned processes — those reparented to an
    # orphan parent (PID 1, or this user's `systemd --user` manager on Linux).
    # Their session is gone, so they are safe to reap.
    if [ "${CC_STOP_HOOK_AGGRESSIVE:-0}" != "1" ]; then
      pid_ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      case "$ORPHAN_PPIDS" in *" $pid_ppid "*) ;; *) continue ;; esac
    fi

    # Skip whitelisted MCP servers (shared across sessions).
    # Fail CLOSED on an empty lookup, the same direction as the PPID check above:
    # ps answers nothing when the process just exited, when ps itself errored, or
    # when the PID has been reused — and an empty command can never match the
    # whitelist, so without this guard "we could not tell what this is" resolved to
    # "kill it". The direction matters because the two mistakes are not symmetric:
    # skipping wrongly leaks one process until the next sweep, killing wrongly
    # takes out a shared MCP server, or whatever now owns a recycled PID.
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [ -z "$pid_cmd" ] && continue
    if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
      continue
    fi

    kill "$pid" 2>/dev/null
  done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$SESSION_PGID" '$2 == pgid {print $1}')
fi

# ─── Pattern-based fallback ──────────────────────────────────────────────────
# Catches processes that escaped the process group (e.g., called setsid())
# Only targets orphans — processes reparented to an orphan parent (PID 1, or
# this user's `systemd --user` manager on Linux) — to avoid killing active
# processes. Target patterns are filtered through MCP_WHITELIST so shared MCP
# servers survive.
#
# CAVEAT: A user-managed daemon launched by launchd/systemd that matches one
# of the target patterns (e.g., `claude --stream-json` or
# `worker-service.cjs --daemon` started by a LaunchAgent or a `systemd --user`
# unit) is legitimately parented to an orphan parent by design and will be
# killed here. If you run such a daemon, either:
#   - export CC_STOP_HOOK_DISABLE=1 in the user environment, or
#   - extend MCP_WHITELIST above to include your daemon's command pattern.
ps -eo pid=,ppid=,command= 2>/dev/null | awk -v set="$ORPHAN_PPIDS" 'index(set, " " $2 " ")' | while IFS= read -r line; do
  _pid=$(echo "$line" | awk '{print $1}')
  _cmd=$(echo "$line" | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
  # Never kill an orphan parent itself (e.g. the `systemd --user` manager) —
  # it is a reparent target, not an orphan.
  case "$ORPHAN_PPIDS" in *" $_pid "*) continue ;; esac
  # Same ancestor protection the PGID sweep gets: a `claude … --stream-json`
  # matched here can be the CLI this hook is running under.
  is_ancestor "$_pid" && continue
  if echo "$_cmd" | grep -qE "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[w]orker-service\.cjs.*--daemon|[b]un.*worker-service"; then
    echo "$_cmd" | grep -qE "$MCP_WHITELIST" && continue
    kill "$_pid" 2>/dev/null
  fi
done

echo "[cleanup] Orphan Claude processes cleaned up."
exit 0
