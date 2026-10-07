#!/bin/bash
# The hook kills processes, so nothing here may touch the real process table.
# `ps` is replaced by a fixture table on PATH and `kill` is shadowed by a function
# that only records its argument, so every case asserts on what WOULD have been
# signalled. Fixture PIDs are deliberately above any reachable pid_max (macOS caps
# at 99998, Linux defaults to 4194304), so even a stub that failed to load could
# not name a live process.
#
# HOOK_UNDER_TEST points the whole file at a different copy of the hook — that is
# how each case is observed failing against the pre-fix hook before it passes here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$ROOT/hooks/stop-cleanup-orphans.sh}"
FAILURES=0

fail() { echo "FAIL: $1" >&2; FAILURES=1; }

PGID=9000900   # the session process group the hook believes it is in

setup() {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  TABLE="$TMP/proctable"; : > "$TABLE"
  KILLED="$TMP/killed"; : > "$KILLED"
  DRIVER_PPID=1   # default: the hook's own parent is init, so it has no ancestors but itself

  # Fake process table rows are `pid|ppid|pgid|command`. An EMPTY command field is
  # the process the hook cannot identify: `ps` answers nothing for it, exactly as
  # it does when the process just exited or the lookup errored.
  cat > "$BIN/ps" <<EOS
#!/bin/bash
TABLE="$TABLE"
args="\$*"
col() { awk -F'|' -v p="\${args##* }" -v c="\$1" '\$1 == p { print \$c }' "\$TABLE"; }
case "\$args" in
  "-o ppid= -p "*)    col 2 ;;
  "-o pgid= -p "*)    col 3 ;;
  "-o command= -p "*) col 4 ;;
  "-eo pid,pgid")     echo "  PID  PGID"; awk -F'|' '{print \$1, \$3}' "\$TABLE" ;;
  "-eo pid=,ppid=,command=") awk -F'|' '{print \$1, \$2, \$4}' "\$TABLE" ;;
  *) exit 0 ;;   # e.g. the Linux \`systemd --user\` probe: no match, empty set
esac
EOS
  chmod +x "$BIN/ps"

  # `kill` is a bash builtin, so a stub on PATH would never be consulted. A shell
  # function is the only shadow the hook's bare `kill` cannot walk past.
  cat > "$TMP/driver.sh" <<'EOS'
#!/bin/bash
kill() {
  for a in "$@"; do
    case "$a" in -*) ;; *) echo "$a" >> "$KILLED" ;; esac
  done
}
# The hook reads its own $$, so its row can only be written from inside the driver.
printf '%s|%s|%s|%s\n' "$$" "$DRIVER_PPID" "$DRIVER_PGID" "bash test-driver" >> "$PROCTABLE"
source "$HOOK"
EOS
}

teardown() { rm -rf "$TMP"; }

proc() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$TABLE"; }

run_hook() {
  PATH="$BIN:$PATH" KILLED="$KILLED" PROCTABLE="$TABLE" HOOK="$HOOK" \
    DRIVER_PPID="$DRIVER_PPID" DRIVER_PGID="$PGID" bash "$TMP/driver.sh" 2>&1
}

was_killed() { grep -qx "$1" "$KILLED" 2>/dev/null; }

# ─── Defect 1: the fallback loop had no ancestor protection ──────────────────
# The ancestor list exists so the hook cannot kill the CLI it is running under.
# The PGID sweep consulted it; the pattern fallback did not, so a `claude
# --stream-json` ancestor whose PPID is 1 was killed by the second loop.
case_ancestor_matching_the_fallback_pattern_is_spared() {
  setup
  DRIVER_PPID=9000001
  proc 9000001 1 9000777 "claude --print --output-format stream-json"
  out="$(run_hook)"
  was_killed 9000001 && fail "the hook killed the CLI it is running under: $out"
  teardown
}

# The same process without the ancestry: the fallback's actual job, which the fix
# must not have disarmed.
case_non_ancestor_matching_the_fallback_pattern_is_killed() {
  setup
  proc 9000002 1 9000777 "claude --print --output-format stream-json"
  out="$(run_hook)"
  was_killed 9000002 || fail "an orphaned stream-json process survived the fallback: $out"
  teardown
}

# ─── Defect 2: an unidentifiable process was killed by default ───────────────
# With no command text the whitelist grep cannot match, so the process fell
# through to the kill. "I could not tell what this is" must not mean "kill it".
case_unidentifiable_process_is_spared() {
  setup
  proc 9000003 1 "$PGID" ""
  out="$(run_hook)"
  was_killed 9000003 && fail "a process ps could not identify was killed anyway: $out"
  teardown
}

# The refactor moved the sweep's own ancestor check onto the shared predicate, so
# that path needs its own binding: green before and after, red if the sweep loses it.
case_ancestor_in_the_session_group_is_spared() {
  setup
  DRIVER_PPID=9000006
  proc 9000006 1 "$PGID" "some-daemon --serve"
  out="$(run_hook)"
  was_killed 9000006 && fail "the PGID sweep killed an ancestor of the hook: $out"
  teardown
}

case_whitelisted_mcp_server_is_spared() {
  setup
  proc 9000004 1 "$PGID" "npx -y chrome-devtools-mcp@latest"
  out="$(run_hook)"
  was_killed 9000004 && fail "a whitelisted MCP server was killed: $out"
  teardown
}

# Also the fixture's own self-check: if the `ps` stub or the `kill` shadow were not
# in effect, nothing would be recorded here and this case goes red.
case_plain_orphan_is_killed() {
  setup
  proc 9000005 1 "$PGID" "node /leftover/worker.js"
  out="$(run_hook)"
  was_killed 9000005 || fail "an unprotected orphan in the session group survived: $out"
  teardown
}

for c in case_ancestor_matching_the_fallback_pattern_is_spared \
         case_non_ancestor_matching_the_fallback_pattern_is_killed \
         case_unidentifiable_process_is_spared \
         case_ancestor_in_the_session_group_is_spared \
         case_whitelisted_mcp_server_is_spared \
         case_plain_orphan_is_killed; do
  "$c"
done

[ "$FAILURES" -eq 0 ] && echo "stop-cleanup-orphans hook tests passed"
exit "$FAILURES"
