#!/usr/bin/env bash
# Pins the session-detection contract shared by claude-guard, claude-sessions,
# and claude-fd. See openspec/specs/agent-process-reapers/spec.md.
#
# Two seams are covered separately:
#   _cc_reaper_is_session_cmd  — pure predicate over one command line
#   _cc_reaper_session_pids    — walks the process table, fed by
#                                CC_REAPER_PS_SNAPSHOT_FILE (pid tty comm) and
#                                CC_REAPER_PS_CMD_SNAPSHOT_DIR (one file per PID)
# so no real process is inspected and nothing is ever signalled.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-session-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
tty_snapshot="$tmp_dir/ps-tty.txt"
cmd_dir="$tmp_dir/ps-cmd"
mkdir -p "$cmd_dir"

pass() { printf "ok - %s\n" "$1"; }
fail() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

expect_cmd() {
  local name=$1 want=$2 cmd=$3
  if _cc_reaper_is_session_cmd "$cmd"; then
    [ "$want" = yes ] && pass "$name" || fail "$name (matched, expected no match)"
  else
    [ "$want" = no ] && pass "$name" || fail "$name (no match, expected match)"
  fi
}

# ─── Command predicate: included ───────────────────────────────────────────

expect_cmd "interactive session with --session-id" yes \
  '/Users/me/.local/bin/claude --session-id 3ded1c38 --settings {"preferredNotifChannel":"terminal_bell"}'
expect_cmd "legacy --dangerously launch form" yes \
  '/Users/me/.local/bin/claude --dangerously-skip-permissions'
expect_cmd "node-invoked claude" yes \
  'node /usr/local/bin/claude --session-id abc'
expect_cmd "--session-id= equals form" yes \
  '/Users/me/.local/bin/claude --session-id=abc'

# ─── Command predicate: excluded ───────────────────────────────────────────

expect_cmd "Desktop-hosted claude-code" no \
  '/Users/me/Library/ClaudeCode/claude --output-format stream-json --input-format stream-json --session-id x'
expect_cmd "subagent stream-json form" no \
  'node /usr/local/bin/claude --session-id abc --output-format stream-json'
expect_cmd "headless -p run" no \
  '/Users/me/.local/bin/claude -p "summarize" --session-id ghi'
expect_cmd "--print run" no \
  '/Users/me/.local/bin/claude --print --session-id ghi'
expect_cmd "claude mcp-server helper" no \
  '/Users/me/.local/bin/claude mcp-server --session-id jkl'
expect_cmd "editor naming the source file" no \
  'vim shell/claude-cleanup.sh --session-id nope'
expect_cmd "grep quoting the flag" no \
  'grep claude --session-id log.txt'
expect_cmd "claude with no session flag" no \
  '/Users/me/.local/bin/claude doctor'

# ─── --settings payload must not drive the decision ────────────────────────
# Regression: matching the whole line let a hook command inside the JSON hide
# the session that owns it.

expect_cmd "hook mentioning --output-format inside settings" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"Stop":"claude -p x --output-format json"}'
expect_cmd "hook mentioning mcp-server inside settings" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"Stop":"claude mcp-server"}'
expect_cmd "settings payload cannot supply the session flag" no \
  '/Users/me/.local/bin/claude doctor --settings {"x":"--session-id fake"}'
expect_cmd "--settings= equals form still drops the payload" yes \
  '/Users/me/.local/bin/claude --session-id real --settings={"Stop":"claude -p x --output-format json"}'

# Multi-line payloads are flattened before matching, never split into records.
expect_cmd "multi-line settings payload" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"hooks":{
  "Stop": "claude -p done --output-format json"
}}'

# ─── Top-level flags after the payload still count ─────────────────────────
# Regression: truncating at the first `{` discarded every later argument, so a
# headless run reading `--settings={} --output-format json` was classified as a
# session and became reapable, while `--settings={} --session-id x` went unseen.

expect_cmd "exclusion flag after an inline payload" no \
  '/Users/me/.local/bin/claude --session-id real --settings={} --output-format json'
expect_cmd "session flag after an inline payload" yes \
  '/Users/me/.local/bin/claude --settings={} --session-id real'
expect_cmd "flag after a nested payload" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"hooks":{"Stop":"x"}} --verbose'
expect_cmd "exclusion flag after a nested payload" no \
  '/Users/me/.local/bin/claude --session-id real --settings {"hooks":{"Stop":"x"}} --print'

# Braces inside JSON strings must not unbalance the scan.
expect_cmd "braces inside a JSON string" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"a":"}{"}'
expect_cmd "escaped quote inside a JSON string" yes \
  '/Users/me/.local/bin/claude --session-id real --settings {"a":"say \"hi\" }"} --verbose'

# Unbalanced braces mean the line cannot be parsed with confidence. Fail closed:
# a missed session leaves the reaper inert, a false one hands claude-guard the
# wrong process group.
expect_cmd "unbalanced braces are rejected" no \
  '/Users/me/.local/bin/claude --session-id real --settings {"truncated":'

# ─── Process-table walker ──────────────────────────────────────────────────

expect_walk() {
  local name=$1 want=$2
  local got
  got=$(CC_REAPER_PS_SNAPSHOT_FILE="$tty_snapshot" \
        CC_REAPER_PS_CMD_SNAPSHOT_DIR="$cmd_dir" \
        _cc_reaper_session_pids | tr '\n' ' ')
  got=${got% }
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name (want '$want', got '$got')"; fi
}

reset_fixtures() { : > "$tty_snapshot"; rm -rf "$cmd_dir"; mkdir -p "$cmd_dir"; }

# A session's own arguments carry a forged process record, newline and all, as
# `ps -o command=` would render it. PIDs come from the comm table, which holds
# no argument text, so the forged record can never become a reap target.
reset_fixtures
printf '59516 ttys006 /Users/me/.local/bin/claude\n' > "$tty_snapshot"
cat > "$cmd_dir/59516" <<'EOF'
/Users/me/.local/bin/claude --session-id real --settings {"hook":"
12345 ttys999 /path/claude --session-id injected
"}
EOF
expect_walk "forged record inside --settings is not emitted" "59516"

# TTY filtering.
reset_fixtures
cat > "$tty_snapshot" <<'EOF'
100 ttys006 /Users/me/.local/bin/claude
200 ?? /Users/me/.local/bin/claude
300 ? /home/me/.local/bin/claude
400 - /home/me/.local/bin/claude
500 pts/3 /home/me/.local/bin/claude
EOF
for p in 100 200 300 400 500; do
  printf '/Users/me/.local/bin/claude --session-id s%s\n' "$p" > "$cmd_dir/$p"
done
expect_walk "only terminal-attached PIDs are emitted" "100 500"

# Non-claude executables never reach the command lookup.
reset_fixtures
cat > "$tty_snapshot" <<'EOF'
600 ttys006 /bin/zsh
700 ttys006 /Users/me/.local/bin/claude
EOF
printf '/bin/zsh --session-id nope\n' > "$cmd_dir/600"
printf '/Users/me/.local/bin/claude --session-id yes\n' > "$cmd_dir/700"
expect_walk "non-claude executable is skipped" "700"

reset_fixtures
expect_walk "empty process table yields no sessions" ""

# ─── claude-guard kill phases run to completion in bash and zsh ────────────
# The phase loops used to walk parallel arrays by numeric index. In zsh
# `${!arr[@]}` raises "bad substitution" and `${arr[0]}` is empty, so the
# FD-leak and bloated phases aborted and the idle phase named an empty PID.
# Nothing caught it because session detection was returning nothing at all.
#
# This drives the real function in --dry-run against a table naming the test
# shell's own PID, so ps/tree-RSS/FD lookups resolve to a live process and no
# signal is ever sent.
guard_phase_runs_under() {
  local shell_bin=$1 threshold_var=$2 expect=$3
  local script='
    source "'"$ROOT_DIR"'/shell/claude-cleanup.sh"
    tty_snap="'"$tmp_dir"'/guard-tty-$$.txt"
    cmd_dir="'"$tmp_dir"'/guard-cmd-$$"; mkdir -p "$cmd_dir"
    printf "%s ttys999 /Users/me/.local/bin/claude\n" "$$" > "$tty_snap"
    printf "/Users/me/.local/bin/claude --session-id phase-test\n" > "$cmd_dir/$$"
    printf "TESTPID=%s\n" "$$"
    CC_REAPER_PS_SNAPSHOT_FILE="$tty_snap" \
    CC_REAPER_PS_CMD_SNAPSHOT_DIR="$cmd_dir" \
    CC_RUNAWAY_DISABLE=1 \
    '"$threshold_var"' \
      claude-guard --dry-run 2>&1
    rm -rf "$tty_snap" "$cmd_dir"
  '
  local out
  out=$("$shell_bin" -c "$script" 2>&1) || true
  if printf '%s' "$out" | grep -q 'bad substitution'; then
    fail "$expect (bad substitution)"
    return
  fi
  # Assert the exact PID, so an index-based regression that prints "PID 0"
  # or an empty PID cannot pass.
  local testpid
  testpid=$(printf '%s\n' "$out" | sed -n 's/^TESTPID=//p')
  if [ -n "$testpid" ] && printf '%s' "$out" | grep -q "Would kill PID $testpid"; then
    pass "$expect"
  else
    fail "$expect (expected PID ${testpid:-?})"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

for sh_bin in bash zsh; do
  if ! command -v "$sh_bin" >/dev/null 2>&1; then
    pass "$sh_bin not installed, phase checks skipped"
    continue
  fi
  guard_phase_runs_under "$sh_bin" "CC_MAX_RSS_MB=1" "$sh_bin: bloated phase names a real PID"
  guard_phase_runs_under "$sh_bin" "CC_MAX_FD=1" "$sh_bin: fd-leak phase names a real PID"
  guard_phase_runs_under "$sh_bin" "CC_MAX_SESSIONS=0 CC_IDLE_THRESHOLD=100" "$sh_bin: idle phase names a real PID"
done

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "guard session detection validation passed\n"
