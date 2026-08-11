#!/usr/bin/env bash
# Pins the single protection classification and the runaway corrections it
# enables. See openspec/specs/agent-process-reapers/spec.md.
#
# Every kill path is exercised through _CC_REAPER_DRY_RUN, so no signal is ever
# sent; `ps` is stubbed where a fixed process table is needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/claude-cleanup.sh"

failures=0
pass() { printf "ok - %s\n" "$1"; }
fail() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-class-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
rules_file="$tmp_dir/process-rules.tsv"
: > "$rules_file"
export CC_REAPER_RULES_FILE="$rules_file"

# ─── Classification ────────────────────────────────────────────────────────

expect_class() {
  local want=$1 cmd=$2
  local got
  got=$(_cc_reaper_protection_class "$cmd")
  if [ "$got" = "$want" ]; then
    pass "$want: ${cmd:0:52}"
  else
    fail "${cmd:0:52} (want $want, got $got)"
  fi
}

expect_class immutable "/Library/Bitdefender/AVP/product/bin/BDLDaemon"
expect_class immutable "/System/Library/.../Support/mdworker_shared"
expect_class immutable "/System/Library/.../Support/mds_stores"
expect_class immutable "/x/shell/claude-cleanup.sh"
expect_class immutable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
expect_class immutable "/Users/me/.codex/computer-use/Codex Computer Use.app/x/SkyComputerUseService"

expect_class shared "/Applications/ChatGPT.app/Contents/Resources/codex -c x"
expect_class shared "/Applications/cmux.app/Contents/MacOS/cmux"
expect_class shared "npx chrome-devtools-mcp@latest --autoConnect"
expect_class shared "npm exec @upstash/context7-mcp"
expect_class shared "npx -y @supabase/mcp-server-supabase@0.5.10 --read-only"
expect_class shared "npx -y mcp-sequentialthinking-tools"
expect_class shared "node /x/next-server --port 3000"
expect_class shared "pm2 God Daemon"

# Regression: the same service launched two ways classified differently before,
# because the group-kill list held `@stripe/mcp` but not `mcp-server-stripe`.
expect_class shared "npx -y @stripe/mcp"
expect_class shared "node /x/node_modules/.bin/mcp-server-stripe"

expect_class none "node /x/_npx/a/node_modules/.bin/mcp-server-tauri"
expect_class none "/opt/unrelated-helper --serve"

# ─── The three paths agree on protection ───────────────────────────────────

for cmd in "/Library/Bitdefender/AVP/product/bin/BDLDaemon" \
           "npx chrome-devtools-mcp@latest" \
           "node /x/.bin/mcp-server-tauri"; do
  class=$(_cc_reaper_protection_class "$cmd")
  direct=$(_cc_reaper_is_direct_cleanup_protected "$cmd" && echo protected || echo open)
  want=$([ "$class" = none ] && echo open || echo protected)
  if [ "$direct" = "$want" ]; then
    pass "group-kill protection agrees with class ($class): ${cmd:0:40}"
  else
    fail "group-kill disagrees with class ($class): ${cmd:0:40}"
  fi
done

# ─── Runaway selection ─────────────────────────────────────────────────────

runaway_with() {
  local table=$1
  ( ps() {
      if [ "$*" = "-axo pid=,etime=,%cpu=,command=" ]; then printf '%s' "$table"; else command ps "$@"; fi
    }
    _cc_guard_runaway_protected_pids 80 60 )
}

out=$(runaway_with "901 03:00:00 99.0 /Library/Bitdefender/AVP/product/bin/BDLDaemon
")
[ -z "$out" ] && pass "runaway skips Bitdefender" || fail "runaway selected Bitdefender"

out=$(runaway_with "902 03:00:00 99.0 /System/Library/x/mdworker_shared
")
[ -z "$out" ] && pass "runaway skips mdworker" || fail "runaway selected mdworker"

out=$(runaway_with "903 03:00:00 99.0 npx chrome-devtools-mcp@latest --autoConnect
")
printf '%s' "$out" | grep -q '^903' && pass "runaway selects a shared MCP" || fail "runaway missed a shared MCP"

out=$(runaway_with "904 03:00:00 99.0 /Applications/ChatGPT.app/Contents/Resources/codex
")
printf '%s' "$out" | grep -q '^904' && pass "runaway selects a shared application" || fail "runaway missed a shared application"

out=$(runaway_with "905 03:00:00 99.0 node /x/.bin/mcp-server-tauri
")
[ -z "$out" ] && pass "runaway ignores an unprotected process" || fail "runaway selected an unprotected process"

printf 'protect\tchrome-devtools-mcp\n' > "$rules_file"
out=$(runaway_with "906 03:00:00 99.0 npx chrome-devtools-mcp@latest
")
[ -z "$out" ] && pass "user protect rule keeps a process out of runaway" || fail "user protect rule ignored by runaway"
: > "$rules_file"

# ─── Runaway signalling ────────────────────────────────────────────────────
# Group 500 holds the runaway MCP (500) and an idle sibling MCP (501).

kill_with() {
  local target=$1 force=$2
  ( ps() { case "$*" in
        "-o command= -p 500") echo "npx chrome-devtools-mcp@latest --autoConnect" ;;
        "-o command= -p 501") echo "npm exec @upstash/context7-mcp" ;;
        "-o command= -p 502") echo "node /x/.bin/mcp-server-tauri" ;;
        "-o pgid= -p "*)      echo " 500" ;;
        "-eo pid,pgid")       printf "500 500\n501 500\n502 500\n" ;;
        *) command ps "$@" ;; esac; }
    _CC_REAPER_DRY_RUN=1 _claude_pgid_kill "$target" "$force" 2>&1 || true )
}

out=$(kill_with 500 1)
if printf '%s' "$out" | grep -q 'Would kill PID 500' \
   && ! printf '%s' "$out" | grep -q 'Would kill PID 501'; then
  pass "runaway target is signalled, shared sibling is spared"
else
  fail "runaway force-target behaviour wrong: $(printf '%s' "$out" | tr '\n' ' ')"
fi

printf '%s' "$out" | grep -q 'Would kill PID 502' \
  && pass "unprotected group member is still signalled" \
  || fail "unprotected group member was spared"

out=$(kill_with 500 0)
printf '%s' "$out" | grep -q 'Would kill PID 500' \
  && fail "shared target signalled without force" \
  || pass "shared target is spared when not forced"

# ─── Delivery counting ─────────────────────────────────────────────────────

count_of() { printf '%s' "$1" | tail -1; }

out=$(kill_with 500 1)
[ "$(count_of "$out")" = 2 ] && pass "count reports two deliveries" || fail "count wrong: $(count_of "$out")"

printf 'protect\tchrome-devtools-mcp\n' > "$rules_file"
out=$(kill_with 500 1 || true)
[ "$(count_of "$out")" = 0 ] && pass "protected target reports zero deliveries" || fail "protected target counted: $(count_of "$out")"
: > "$rules_file"

kill_immutable() {
  ( ps() { case "$*" in
        "-o command= -p 600") echo "/System/Library/x/mdworker_shared" ;;
        *) command ps "$@" ;; esac; }
    _CC_REAPER_DRY_RUN=1 _claude_pgid_kill 600 1 2>&1 || true )
}
out=$(kill_immutable)
[ "$(count_of "$out")" = 0 ] && pass "immutable target reports zero deliveries" || fail "immutable target counted"

# ─── Tree RSS ──────────────────────────────────────────────────────────────

rss_table() {
  ( ps() {
      if [ "$*" = "-eo pid=,ppid=,rss=" ]; then printf '%s' "$TABLE"; else command ps "$@"; fi
    }
    _claude_tree_rss "$1" )
}

# 4095 MB + 1023 KB parent, 1 KB child: truncating each member first gives 4095.
TABLE="1000 1 4194303
1001 1000 1
"
got=$(rss_table 1000)
[ "$got" = 4096 ] && pass "members are summed before conversion" || fail "fractional sum wrong: $got"

# Great-grandchild must be counted.
TABLE="2000 1 1048576
2001 2000 1048576
2002 2001 1048576
2003 2002 1048576
"
got=$(rss_table 2000)
[ "$got" = 4096 ] && pass "full depth is walked" || fail "deep tree wrong: $got"

# An unrelated tree must not leak in.
TABLE="3000 1 1048576
3001 3000 1048576
4000 1 1048576
"
got=$(rss_table 3000)
[ "$got" = 2048 ] && pass "unrelated processes are excluded" || fail "unrelated tree leaked: $got"

TABLE="5000 1 1024
"
got=$(rss_table 9999)
[ "$got" = 0 ] && pass "missing PID yields zero" || fail "missing PID wrong: $got"

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "protection class validation passed\n"
