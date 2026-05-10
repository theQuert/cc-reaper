#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

export CC_AGENT_STALE_MINUTES=60

failures=0

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

expect_no "mcp-server-cloudflare is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "node /usr/local/bin/mcp-server-cloudflare run abc"

expect_no "@stripe/mcp is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "npm exec @stripe/mcp"

expect_no "sequential-thinking is protected" \
  _cc_reaper_is_agent_cleanup_candidate 1 "??" "03:00:00" \
  "node sequential-thinking"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "agent process pattern validation passed\n"
