#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

export CC_AGENT_STALE_MINUTES=60

failures=0

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-rules-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
rules_file="$tmp_dir/process-rules.tsv"
export CC_REAPER_RULES_FILE="$rules_file"

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

expect_yes "agent-browser orphan candidate" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "00:10" \
  "/usr/local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64"

expect_yes "stale Chrome-for-Testing agent profile candidate" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "02:00:00" \
  "/Users/me/.agent-browser/browsers/chrome/Google Chrome for Testing --user-data-dir=/tmp/agent-browser-chrome-abc"

expect_no "recent Chrome-for-Testing agent profile is protected by age" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "00:10:00" \
  "/Users/me/.agent-browser/browsers/chrome/Google Chrome for Testing --user-data-dir=/tmp/agent-browser-chrome-abc"

expect_yes "stale Puppeteer temporary profile candidate" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "01-00:00:00" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/tmp/puppeteer_dev_chrome_profile-abc"

expect_no "normal Chrome profile is not a candidate" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "01-00:00:00" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Default"

expect_yes "orphan Codex CLI candidate" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "00:01:00" \
  "node /usr/local/bin/codex --yolo"

expect_no "Codex app-server is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "01-00:00:00" \
  "node /usr/local/bin/codex app-server"

expect_no "detached stale chrome-devtools MCP is now protected" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "chrome-devtools-mcp npm_config_legacy_peer_deps=true"

expect_no "react-scripts dev server is not a candidate" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "node /repo/web/default/node_modules/react-scripts/scripts/start.js"

expect_no "Supabase MCP child process is protected" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "node /Users/me/.npm/_npx/53c4795544aaa350/node_modules/.bin/mcp-server-supabase --access-token sbp_secret"

expect_no "ChatGPT app is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"

expect_no "cloudflare MCP is no longer whitelisted (deliberately reapable)" \
  _cc_reaper_is_protected_cmd "node /usr/local/bin/mcp-server-cloudflare run abc"

expect_no "bare node mcp-server-cloudflare is not a manual-cleanup candidate (no node-form branch here)" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "node /usr/local/bin/mcp-server-cloudflare run abc"

expect_no "@stripe/mcp is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "npm exec @stripe/mcp"

expect_no "sequential-thinking is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "node sequential-thinking"

printf "protect\tcustom-worker\n" > "$rules_file"
expect_no "user protect rule blocks otherwise eligible process" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "/opt/custom-worker --serve"

printf "cleanup\tcustom-worker\n" > "$rules_file"
expect_yes "user cleanup rule admits stale detached ordinary process" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "/opt/custom-worker --serve"
expect_no "user cleanup rule does not admit recent process" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "00:10:00" \
  "/opt/custom-worker --serve"
expect_no "user cleanup rule does not admit terminal-attached process" \
  _cc_reaper_is_agent_cleanup_candidate 123 "ttys003" "03:00:00" \
  "/opt/custom-worker --serve"

printf "cleanup\tchrome-devtools-mcp\n" > "$rules_file"
expect_yes "user cleanup rule can override ordinary built-in protection after safety checks" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "chrome-devtools-mcp npm_config_legacy_peer_deps=true"

printf "cleanup\tWindowServer\ncleanup\tCCReaper\n" > "$rules_file"
expect_no "system safety floor rejects user cleanup rule" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon"
expect_no "cc-reaper self safety floor rejects user cleanup rule" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "/Applications/CCReaper.app/Contents/MacOS/CCReaper"

printf "cleanup\tconflicted-worker\nprotect\tCONFLICTED-WORKER\n" > "$rules_file"
expect_no "protect wins an externally edited policy conflict" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "/opt/conflicted-worker --serve"

printf "cleanup\tworker.*\n" > "$rules_file"
expect_no "rule syntax is literal rather than regular expression" \
  _cc_reaper_is_agent_cleanup_candidate 123 "??" "03:00:00" \
  "/opt/worker-123 --serve"

protected_group_sends_no_signal() (
  local signal_file="$tmp_dir/signal-sent"
  printf "protect\tcustom-worker\n" > "$rules_file"
  ps() {
    case "$*" in
      "-eo pid,pgid") printf "900 700\n" ;;
      "-o command= -p 900") printf "/opt/custom-worker --serve\n" ;;
      *) command ps "$@" ;;
    esac
  }
  kill() { : > "$signal_file"; }
  _cc_reaper_kill_group_filtered 700 >/dev/null
  [ ! -e "$signal_file" ]
)

expect_yes "user protect rule blocks the group signal path" protected_group_sends_no_signal

protected_runaway_is_not_returned() (
  printf "protect\tchrome-devtools-mcp\n" > "$rules_file"
  ps() {
    if [ "$*" = "-axo pid=,etime=,%cpu=,command=" ]; then
      printf "901 03:00:00 99.0 node chrome-devtools-mcp\n"
    else
      command ps "$@"
    fi
  }
  [ -z "$(_cc_guard_runaway_protected_pids 80 60)" ]
)

expect_yes "user protect rule blocks the runaway guard path" protected_runaway_is_not_returned

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "agent process pattern validation passed\n"
