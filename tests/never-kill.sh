#!/usr/bin/env bash
# The never-kill list: CC_NEVER_KILL_PIDS names processes cc-reaper never signals, nor any
# process descended from one, on every path that signals (EL-T24-STORAGE-LOAD-REAPER).
#
# Every case reads a fixture ppid table (CC_NEVER_KILL_PPID_FILE) and shadows `kill` with a
# function that only records, so nothing here can signal a real process, and the pids that are
# signalled at all are above any pid_max. The default list's pids are only ever asked about,
# never handed to a kill path.
#
# Also here: guard-runner.sh always spares a runaway MCP server a live session is using, and the
# Claude/Codex CLI matcher that decides what "a live session" is.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="$ROOT_DIR/shell/claude-cleanup.sh"
MONITOR="$ROOT_DIR/launchd/cc-reaper-monitor.sh"
HOOK="$ROOT_DIR/hooks/stop-cleanup-orphans.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-never-kill.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

# ─── One rule, three copies ───────────────────────────────────────────────────
block() { awk '/^# BEGIN never-kill/ { on = 1 } on { print } /^# END never-kill/ { on = 0 }' "$1"; }
block "$CLEANUP" > "$tmp/a"; block "$MONITOR" > "$tmp/b"; block "$HOOK" > "$tmp/c"
if [ -s "$tmp/a" ] && cmp -s "$tmp/a" "$tmp/b" && cmp -s "$tmp/a" "$tmp/c"; then
  ok "the never-kill helper is byte-identical in claude-cleanup, the monitor and the stop hook"
else
  bad "the never-kill helper copies differ: $(diff "$tmp/a" "$tmp/b" | head -3; diff "$tmp/a" "$tmp/c" | head -3)"
fi

# ─── The rule itself ──────────────────────────────────────────────────────────
# pid ppid: 9100001 is listed; 9100002 is its child and 9100003 its grandchild; 9100004 is not
# related; 9100005's parent is not in the table.
cat > "$tmp/table" <<'EOF'
9100001 1
9100002 9100001
9100003 9100002
9100004 1
9100005 9100099
70987 1
4565 1
EOF
: > "$tmp/empty"
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { ok "$sh is not installed; its leg is skipped"; continue; }
  opt=""; [ "$sh" = zsh ] && opt=-f
  # Each line: list (or UNSET), table, pid, expected exit status of _cc_reaper_never_kill.
  while IFS='|' read -r list table pid want why; do
    [ -n "$pid" ] || continue
    got=$(CLEANUP="$CLEANUP" LIST="$list" TABLE="$tmp/$table" PID="$pid" \
      env -u BASH_ENV -u ENV "$sh" $opt -c '
        . "$CLEANUP" >/dev/null 2>&1
        [ "$LIST" = UNSET ] && unset CC_NEVER_KILL_PIDS || export CC_NEVER_KILL_PIDS="$LIST"
        CC_NEVER_KILL_PPID_FILE="$TABLE" _cc_reaper_never_kill "$PID"; echo $?')
    [ "$got" = "$want" ] && ok "$sh: $why" || bad "$sh: $why (exit $got, want $want)"
  done <<'EOF'
9100001|table|9100001|0|a listed pid is protected
9100001|table|9100002|0|its child is protected
9100001|table|9100003|0|its grandchild is protected
9100001|table|9100004|1|an unrelated pid is not
9100001|table|9100005|1|a pid whose parent is unknown is not
9100001,9100004|table|9100004|0|a comma-separated list is read
9100001|empty|9100004|0|an unreadable process table protects every pid
|table|9100001|1|an empty list protects nothing
UNSET|table|70987|0|unset, the default list protects 70987
UNSET|table|4565|0|unset, the default list protects 4565
UNSET|table|9100004|1|unset, the default list protects nothing else
EOF
done

# ─── claude-cleanup: every signal goes through _cc_reaper_kill_pid ────────────
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  opt=""; [ "$sh" = zsh ] && opt=-f
  : > "$tmp/signalled"
  CLEANUP="$CLEANUP" TABLE="$tmp/table" OUT="$tmp/signalled" \
    env -u BASH_ENV -u ENV "$sh" $opt -c '
      kill() { local a; for a in "$@"; do case "$a" in -*) ;; *) echo "$a" >> "$OUT" ;; esac; done; return 0; }
      . "$CLEANUP" >/dev/null 2>&1
      export CC_NEVER_KILL_PIDS=9100001 CC_NEVER_KILL_PPID_FILE="$TABLE"
      _cc_reaper_kill_pid 9100003; echo "rc3=$?"
      _cc_reaper_kill_pid 9100004; echo "rc4=$?"
      _CC_REAPER_DRY_RUN=1 _cc_reaper_kill_pid 9100002; echo "rc2=$?"' > "$tmp/out" 2> "$tmp/err"
  if [ "$(tr '\n' ' ' < "$tmp/signalled")" = "9100004 " ] &&
     grep -qx 'rc3=1' "$tmp/out" && grep -qx 'rc4=0' "$tmp/out" && grep -qx 'rc2=1' "$tmp/out" &&
     grep -qx 'never-kill 9100003' "$tmp/err" && grep -qx 'never-kill 9100002' "$tmp/err"; then
    ok "$sh: claude-cleanup signals the unlisted pid only, and names each refusal on stderr, dry run too"
  else
    bad "$sh: claude-cleanup kill path: signalled [$(tr '\n' ' ' < "$tmp/signalled")] out [$(tr '\n' ' ' < "$tmp/out")] err [$(tr '\n' ' ' < "$tmp/err")]"
  fi
done

# ─── The orphan monitor: its one signal boundary ──────────────────────────────
mkdir -p "$tmp/home"
: > "$tmp/signalled"
( set +euo pipefail
  export HOME="$tmp/home" CC_REAPER_RULES_FILE="$tmp/no-rules.tsv" CC_REAPER_MONITOR_SOURCE_ONLY=1
  export CC_NEVER_KILL_PIDS=9100001 CC_NEVER_KILL_PPID_FILE="$tmp/table"
  kill() { local a; for a in "$@"; do case "$a" in -*) ;; *) echo "$a" >> "$tmp/signalled" ;; esac; done; return 0; }
  ps() { return 0; }
  # shellcheck disable=SC1090
  . "$MONITOR"
  terminate_unless_user_protected 9100002 -9; echo "rc2=$?"
  terminate_unless_user_protected 9100004; echo "rc4=$?"
) > "$tmp/out" 2>&1
if [ "$(tr '\n' ' ' < "$tmp/signalled")" = "9100004 " ] && grep -qx 'rc2=1' "$tmp/out" &&
   grep -q 'never-kill 9100002' "$tmp/home/.cc-reaper/logs/monitor.log"; then
  ok "the monitor spares a listed pid's child, SIGKILL included, and logs never-kill"
else
  bad "monitor: signalled [$(tr '\n' ' ' < "$tmp/signalled")] out [$(tr '\n' ' ' < "$tmp/out")] log [$(cat "$tmp/home/.cc-reaper/logs/monitor.log" 2>/dev/null)]"
fi

# ─── guard-runner: in-use runaway servers are spared, whatever the environment ─
cat > "$tmp/fake-cleanup.sh" <<'EOF'
_cc_reaper_bound_log() { :; }
claude-guard() { echo "spare=${CC_RUNAWAY_SPARE_IN_USE:-unset}"; }
EOF
out="$(CC_REAPER_CLEANUP="$tmp/fake-cleanup.sh" CC_RUNAWAY_SPARE_IN_USE=0 HOME="$tmp/home" \
  bash "$ROOT_DIR/shell/guard-runner.sh")"
[ "$out" = "spare=1" ] && ok "guard-runner always sets CC_RUNAWAY_SPARE_IN_USE=1" \
  || bad "guard-runner passed CC_RUNAWAY_SPARE_IN_USE as: $out"

# ─── What counts as a Claude or Codex session ─────────────────────────────────
# Each line: expected (0 = an agent CLI) | command line.
while IFS='|' read -r want cmd; do
  [ -n "$want" ] || continue
  got=$(CLEANUP="$CLEANUP" CMD="$cmd" bash -c '. "$CLEANUP" >/dev/null 2>&1; _cc_reaper_is_agent_cli_cmd "$CMD"; echo $?')
  [ "$got" = "$want" ] && ok "agent CLI $want: $cmd" || bad "agent CLI: $cmd (exit $got, want $want)"
done <<'EOF'
0|claude --session-id 11111111-2222-3333-4444-555555555555
0|/Users/me/.local/bin/claude --output-format stream-json --input-format stream-json
0|node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume
0|/Users/me/.local/bin/codex --yolo
0|node /usr/local/bin/codex resume
1|claude mcp-server
1|codex mcp-server
1|uvx chroma-mcp --client-type http
1|node /Users/me/.claude/plugins/claude-mem/scripts/save-hook.js
1|python -m pytest /private/tmp/claude-501/x/tests --claude
1|bash -c claude --session-id x
EOF

if [ "$failures" -eq 0 ]; then
  echo "never-kill: all tests passed"
else
  echo "never-kill: $failures failure(s)"
  exit 1
fi
