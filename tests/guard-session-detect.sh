#!/usr/bin/env bash
# Pins the session-detection contract shared by claude-guard, claude-sessions,
# and claude-fd. See openspec/specs/agent-process-reapers/spec.md.
#
# A fixed process table is fed through CC_REAPER_PS_SNAPSHOT_FILE, which has the
# format of `ps -eo pid=,tty=,command=`, so no real process is inspected.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-session-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
snapshot="$tmp_dir/ps-snapshot.txt"
export CC_REAPER_PS_SNAPSHOT_FILE="$snapshot"

# Emit a single-process table and assert whether its PID is reported.
expect_session() {
  local name=$1 want=$2 line=$3
  printf '%s\n' "$line" > "$snapshot"
  local got
  got=$(_cc_reaper_session_pids)
  if [ "$got" = "$want" ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (want '%s', got '%s')\n" "$name" "$want" "$got"
    failures=$((failures + 1))
  fi
}

# ─── Included: terminal-attached top-level CLI sessions ─────────────────────

expect_session "interactive session with --session-id is found" "59516" \
  '59516 ttys006 /Users/me/.local/bin/claude --session-id 3ded1c38-baa6-4602-b83d-3329e634c676 --settings {"preferredNotifChannel":"terminal_bell"}'

expect_session "legacy --dangerously launch form still matches" "4242" \
  '4242 ttys001 /Users/me/.local/bin/claude --dangerously-skip-permissions'

expect_session "node-invoked claude is found" "777" \
  '777 ttys002 node /usr/local/bin/claude --session-id abc'

expect_session "Linux pts terminal is honoured" "888" \
  '888 pts/3 /home/me/.local/bin/claude --session-id def'

# ─── Excluded: everything that is not a user-visible terminal session ───────

expect_session "Desktop-hosted claude-code is excluded" "" \
  '66986 ?? /Users/me/Library/ClaudeCode/claude --output-format stream-json --verbose --input-format stream-json --session-id x'

expect_session "subagent without a terminal is excluded" "" \
  '35007 ?? node /usr/local/bin/claude --session-id abc stream-json'

expect_session "headless -p run on a terminal is excluded" "" \
  '5150 ttys003 /Users/me/.local/bin/claude -p "summarize" --session-id ghi --output-format stream-json'

expect_session "--print run on a terminal is excluded" "" \
  '5151 ttys003 /Users/me/.local/bin/claude --print --session-id ghi'

expect_session "claude mcp-server helper is excluded" "" \
  '6001 ttys004 /Users/me/.local/bin/claude mcp-server --session-id jkl'

expect_session "editor naming the source file is excluded" "" \
  '7001 ttys005 vim shell/claude-cleanup.sh --session-id nope'

expect_session "grep quoting the flag is excluded" "" \
  '7002 ttys005 grep claude --session-id log.txt'

expect_session "claude process with no session flag is excluded" "" \
  '7003 ttys005 /Users/me/.local/bin/claude doctor'

expect_session "Linux no-tty marker is excluded" "" \
  '7004 ? /home/me/.local/bin/claude --session-id mno'

expect_session "dash tty marker is excluded" "" \
  '7005 - /home/me/.local/bin/claude --session-id pqr'

# ─── Multi-line --settings JSON ────────────────────────────────────────────
# `ps` renders one process across several lines when an argument contains
# newlines. The PID must appear exactly once and no continuation token may leak.

cat > "$snapshot" <<'EOF'
59516 ttys006 /Users/me/.local/bin/claude --session-id 3ded1c38 --settings {"hooks":{
  "Stop": "echo done",
  "PreToolUse": "echo start"
}}
50159 ttys001 /Users/me/.local/bin/claude --session-id 87329e46
EOF
got=$(_cc_reaper_session_pids)
want=$(printf '59516\n50159')
if [ "$got" = "$want" ]; then
  printf "ok - multi-line settings JSON yields each PID exactly once\n"
else
  printf "not ok - multi-line settings JSON (want '%s', got '%s')\n" "$want" "$got"
  failures=$((failures + 1))
fi

# A continuation line that happens to start with a bare number must still be
# rejected, because its second field is not shaped like a TTY.
cat > "$snapshot" <<'EOF'
59516 ttys006 /Users/me/.local/bin/claude --session-id 3ded1c38 --settings {"retries":
2 attempts before giving up
}
EOF
got=$(_cc_reaper_session_pids)
if [ "$got" = "59516" ]; then
  printf "ok - numeric continuation line is rejected\n"
else
  printf "not ok - numeric continuation line (want '59516', got '%s')\n" "$got"
  failures=$((failures + 1))
fi

# ─── Empty host ────────────────────────────────────────────────────────────

: > "$snapshot"
if [ -z "$(_cc_reaper_session_pids)" ]; then
  printf "ok - empty process table yields no sessions\n"
else
  printf "not ok - empty process table yielded output\n"
  failures=$((failures + 1))
fi

# ─── claude-guard kill phases run to completion in bash and zsh ────────────
# The phase loops used to walk parallel arrays by numeric index. In zsh
# `${!arr[@]}` raises "bad substitution" and `${arr[0]}` is empty, so the
# FD-leak and bloated phases aborted and the idle phase named an empty PID.
# Nothing caught it because session detection was returning nothing at all.
#
# This drives the real function in --dry-run against a snapshot naming the test
# shell's own PID, so ps/tree-RSS/FD lookups all resolve to a live process and
# no signal is ever sent.
guard_phase_runs_under() {
  local shell_bin=$1 threshold_var=$2 expect=$3
  local script='
    source "'"$ROOT_DIR"'/shell/claude-cleanup.sh"
    snap="'"$tmp_dir"'/guard-snapshot-$$.txt"
    printf "%s ttys999 /Users/me/.local/bin/claude --session-id phase-test\n" "$$" > "$snap"
    printf "TESTPID=%s\n" "$$"
    CC_REAPER_PS_SNAPSHOT_FILE="$snap" \
    CC_RUNAWAY_DISABLE=1 \
    '"$threshold_var"' \
      claude-guard --dry-run 2>&1
    rm -f "$snap"
  '
  local out
  out=$("$shell_bin" -c "$script" 2>&1) || true
  if printf '%s' "$out" | grep -q 'bad substitution'; then
    printf "not ok - %s (bad substitution)\n" "$expect"
    failures=$((failures + 1))
    return
  fi
  # Assert the exact PID, so an index-based regression that prints "PID 0"
  # or an empty PID cannot pass.
  local testpid
  testpid=$(printf '%s\n' "$out" | sed -n 's/^TESTPID=//p')
  if [ -n "$testpid" ] && printf '%s' "$out" | grep -q "Would kill PID $testpid"; then
    printf "ok - %s\n" "$expect"
  else
    printf "not ok - %s (expected PID %s)\n" "$expect" "${testpid:-?}"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  fi
}

for sh_bin in bash zsh; do
  if ! command -v "$sh_bin" >/dev/null 2>&1; then
    printf "ok - %s not installed, phase checks skipped\n" "$sh_bin"
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
