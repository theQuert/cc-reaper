#!/usr/bin/env bash
# Verify cc-reaper-monitor's is_existing_orphan_cmd matches the npm-exec MCP form.
#
# Regression for 2026-06-29: 4× `npm exec @cloudflare/mcp-server-cloudflare`
# orphans (PPID=1) pinned ~100% CPU for hours and evaded the reaper because the
# matcher only knew `npx.*mcp-server`, not the `npm exec @scope/mcp-server-*`
# form. We can't source the monitor (its body runs kills at load), so extract
# the regex from the function and test it directly.
set -euo pipefail

MON="$(cd "$(dirname "$0")/.." && pwd)/launchd/cc-reaper-monitor.sh"
# Grab the regex inside `grep -qE "..."` (skip the earlier "$cmd" quotes).
pat=$(awk '/^is_existing_orphan_cmd\(\)/{f=1}
           f && /grep -qE/ { line=$0; sub(/.*grep -qE "/, "", line); sub(/".*/, "", line); print line; exit }' "$MON")

[ -n "$pat" ] || { echo "not ok - could not extract is_existing_orphan_cmd regex"; exit 1; }

fail=0
check() { # name cmd expected(match|nomatch)
  local got
  if echo "$2" | grep -qE "$pat"; then got=match; else got=nomatch; fi
  if [ "$got" = "$3" ]; then printf "ok - %s\n" "$1"
  else printf "not ok - %s (got %s)\n" "$1" "$got"; fail=1; fi
}

check "npm-exec cloudflare orphan (the wrapper) matches" \
  "npm exec @cloudflare/mcp-server-cloudflare@latest" match
check "node mcp-server child matches" \
  "node /Users/me/.npm/_npx/abc/node_modules/.bin/mcp-server-cloudflare run" match
check "npx mcp-server form still matches" \
  "npx -y mcp-server-foo" match
check "plain npm install is not a match" \
  "npm install express" nomatch
check "a normal node app is not a match" \
  "node /repo/server.js" nomatch

[ "$fail" = 0 ] && echo "cc-reaper-monitor npm-exec matcher passed" || exit 1
