#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0
kill_log=$(mktemp)
trap 'rm -f "$kill_log"' EXIT

expect_yes() {
  local name=$1
  shift
  if "$@"; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

expect_no() {
  local name=$1
  shift
  if "$@"; then
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  else
    printf "ok - %s\n" "$name"
  fi
}

# Mock ps: return fake process list
ps() {
  if [ "$1" = "-eo" ] && [ "$2" = "pid=,ppid=,command=" ]; then
    cat <<'EOF'
100 1 node /usr/local/bin/claude --dangerously-allow-all --session-id abc stream-json
200 1 npm exec @upstash/context7-mcp
300 1 npm exec mcp-remote
400 1 npx mcp-server-foo
500 1 node sequential-thinking
600 1 worker-service.cjs --daemon
700 1 bun run worker-service
800 2 node /usr/local/bin/claude --dangerously-allow-all --session-id def stream-json
900 1 node /usr/local/bin/mcp-server-cloudflare run xyz
EOF
  elif [ "$1" = "-eo" ] && [ "$2" = "pid=,uid=,command=" ]; then
    # No `systemd --user` manager → orphan-parent set resolves to exactly "1",
    # keeping this PID=1 regression fixture deterministic across platforms.
    :
  else
    command ps "$@"
  fi
}

# Mock kill: record killed PIDs to temp file (works across subshells)
kill() {
  echo "$1" >> "$kill_log"
}

# Run the fallback
_cc_reaper_ppid_fallback

# Verify: non-protected PPID=1 orphans were killed
expect_yes "orphan claude stream-json killed" \
  grep -q "^100$" "$kill_log"

expect_yes "orphan npx mcp-server killed" \
  grep -q "^400$" "$kill_log"

expect_no "protected sequential-thinking NOT killed" \
  grep -q "^500$" "$kill_log"

expect_yes "orphan worker-service.cjs killed" \
  grep -q "^600$" "$kill_log"

expect_yes "orphan bun worker-service killed" \
  grep -q "^700$" "$kill_log"

# Verify: protected PPID=1 orphans were NOT killed
expect_no "protected context7-mcp NOT killed" \
  grep -q "^200$" "$kill_log"

expect_no "protected mcp-remote NOT killed" \
  grep -q "^300$" "$kill_log"

# Verify: PPID != 1 was NOT processed
expect_no "PPID=2 claude NOT killed" \
  grep -q "^800$" "$kill_log"

# Verify: newly-whitelisted MCPs are NOT killed
expect_no "protected mcp-server-cloudflare NOT killed" \
  grep -q "^900$" "$kill_log"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "ppid fallback validation passed\n"
