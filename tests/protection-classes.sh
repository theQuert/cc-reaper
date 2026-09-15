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

# Rows are pid etime cputime %cpu command. The listing the guard reads carries no command
# column, and each command is read per PID. The previous selection's format is answered too,
# so this suite can be pointed at it and fail for the defect rather than the format.
runaway_with() {
  local table=$1
  ( ps() {
      case "$*" in
        "-axo pid=,etime=,time=,%cpu=") printf '%s' "$table" | awk '{ print $1, $2, $3, $4 }' ;;
        "-o command= -p "*) printf '%s' "$table" | awk -v p="${!#}" '$1 == p { sub(/^[^ ]+ [^ ]+ [^ ]+ [^ ]+ /, ""); print }' ;;
        "-axo pid=,etime=,%cpu=,command=") printf '%s' "$table" | awk '{ $3 = ""; print }' ;;
        *) command ps "$@" ;;
      esac
    }
    _cc_guard_runaway_protected_pids 80 60 )
}

out=$(runaway_with "901 03:00:00 170:00.00 99.0 /Library/Bitdefender/AVP/product/bin/BDLDaemon
")
[ -z "$out" ] && pass "runaway skips Bitdefender" || fail "runaway selected Bitdefender"

out=$(runaway_with "902 03:00:00 170:00.00 99.0 /System/Library/x/mdworker_shared
")
[ -z "$out" ] && pass "runaway skips mdworker" || fail "runaway selected mdworker"

out=$(runaway_with "903 03:00:00 170:00.00 99.0 npx chrome-devtools-mcp@latest --autoConnect
")
printf '%s' "$out" | grep -q '^903' && pass "runaway selects a shared MCP" || fail "runaway missed a shared MCP"

# Applications, dev servers and process managers classify shared, but the phase runs
# unattended and each is something a person is using. On the audited host it had
# signalled ChatGPT.app and cmux.app, the terminal the sessions ran in.
for row in "904 03:00:00 170:00.00 99.0 /Applications/ChatGPT.app/Contents/Resources/codex -c x" \
           "907 15-13:40:59 18000:00.00 80.8 /Applications/cmux.app/Contents/MacOS/cmux" \
           "908 03:00:00 170:00.00 99.0 node /repo/node_modules/.bin/next dev-server --port 3000" \
           "909 03:00:00 170:00.00 99.0 pm2 God Daemon"; do
  out=$(runaway_with "$row
")
  [ -z "$out" ] && pass "runaway never selects: ${row#* * * * }" || fail "runaway selected: ${row#* * * * }"
done

out=$(runaway_with "910 03:00:00 170:00.00 99.0 npx -y @supabase/mcp-server-supabase@0.5.10 --read-only
")
printf '%s' "$out" | grep -q '^910' && pass "runaway selects a shared MCP launched through npx -y" \
  || fail "runaway missed a shared MCP launched through npx -y"

out=$(runaway_with "905 03:00:00 170:00.00 99.0 node /x/.bin/mcp-server-tauri
")
[ -z "$out" ] && pass "runaway ignores an unprotected process" || fail "runaway selected an unprotected process"

printf 'protect\tchrome-devtools-mcp\n' > "$rules_file"
out=$(runaway_with "906 03:00:00 170:00.00 99.0 npx chrome-devtools-mcp@latest
")
[ -z "$out" ] && pass "user protect rule keeps a process out of runaway" || fail "user protect rule ignored by runaway"
: > "$rules_file"

# Hot over its life but cool now: the signal stage would skip it, and the listing, which is
# also what --dry-run prints, must not name it either.
out=$(runaway_with "912 03:00:00 170:00.00 4.0 npx chrome-devtools-mcp@latest --autoConnect
")
[ -z "$out" ] && pass "runaway skips a server hot over its life but cool now" || fail "runaway selected a server that is cool now"

# ─── Runaway eligibility: what the process runs, not names in its arguments ────
# Review of 2026-09-15 reproduced the first five "not eligible" rows being signalled. The
# class is a substring test over the whole command line, which errs safe for protection
# and unsafe for a kill path; every row below classifies shared.
eligible() {
  if _cc_guard_runaway_eligible "$1"; then pass "eligible: ${1:0:64}"; else fail "should be eligible: ${1:0:64}"; fi
}
not_eligible() {
  if _cc_guard_runaway_eligible "$1"; then fail "should not be eligible: ${1:0:64}"; else pass "not eligible: ${1:0:64}"; fi
}

eligible "uvx chroma-mcp --client-type persistent"
eligible "npx -y @supabase/mcp-server-supabase@0.5.10 --read-only"
eligible "npm exec @upstash/context7-mcp"
eligible "npm exec mcp-sequentialthinking-tools"
eligible "npx -y @stripe/mcp --tools=all"
eligible "node /Users/me/.npm/_npx/9f/node_modules/@stripe/mcp/dist/index.js"
eligible "node /Users/me/.npm/_npx/9f/node_modules/.bin/mcp-sequentialthinking-tools"
eligible "npx mcp-remote@0.1.29 https://mcp.example.com/sse"
eligible "/Users/me/.local/bin/chroma-mcp --client-type persistent"
eligible "/Users/me/.cache/uv/archive-v0/x1/bin/python /Users/me/.cache/uv/archive-v0/x1/bin/chroma-mcp"
eligible "codex mcp-server"
eligible "node /Users/me/.npm/_npx/9f/node_modules/@openai/codex/bin/codex.js mcp-server"

not_eligible 'claude --session-id 2222 --settings {"hooks":{"Stop":[{"type":"command","command":"node /Users/me/.claude/plugins/claude-mem/scripts/summary-hook.js"}]}}'
not_eligible 'claude --output-format stream-json --mcp-config {"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}'
not_eligible "node /Users/me/GitHub/context7-docs-sync/node_modules/.bin/stryker run"
not_eligible "python -m pytest /private/tmp/claude-501/-Users-me-GitHub-supabase-mcp-bench/tests"
not_eligible "/Users/me/.local/bin/codex --yolo -c mcp_servers.github.command=npx"
not_eligible "node /Users/me/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js --mcp-config /Users/me/mcp/context7-mcp"
not_eligible "/Applications/Claude.app/Contents/Resources/node /x/node_modules/@upstash/context7-mcp/dist/index.js"
not_eligible "node /Users/me/GitHub/context7-mcp/dist/index.js"
not_eligible "node /repo/node_modules/.bin/next dev-server --port 3000"
# A path argument ending in a server's name is a checkout, not the server.
not_eligible "python -m pytest /Users/me/GitHub/chroma-mcp"
not_eligible "uv run --directory /Users/me/GitHub/chroma-mcp pytest"
not_eligible "rg --files /Users/me/GitHub/context7-mcp"
not_eligible "node /repo/scripts/bench.js --server mcp-remote"
# A tool pointed at a server is not the server; only a package runner's operand counts.
not_eligible "sample chroma-mcp 60 -file /tmp/chroma.sample"

# ─── Argument text cannot add a runaway candidate ──────────────────────────────
# A payload can carry a line shaped like a listing row, or like the TSV record the signal
# stage reads. Only the listing without a command column names candidates, and each command
# is flattened to one line.
forged_runaway() (
  ps() {
    case "$*" in
      "-axo pid=,etime=,time=,%cpu=") printf '911 03:00:00 170:00.00 99.0\n' ;;
      "-o command= -p 911") printf 'npx chrome-devtools-mcp@latest --payload {"a":"\n912 03:00:00 99.0 npx chrome-devtools-mcp@latest\n913\t99.0\t03:00:00\tnpx chrome-devtools-mcp@latest"}\n' ;;
      "-axo pid=,etime=,%cpu=,command=") printf '911 03:00:00 99.0 npx chrome-devtools-mcp@latest --payload {"a":"\n912 03:00:00 99.0 npx chrome-devtools-mcp@latest\n913\t99.0\t03:00:00\tnpx chrome-devtools-mcp@latest"}\n' ;;
      *) command ps "$@" ;;
    esac
  }
  _cc_guard_runaway_protected_pids 80 60
)
forged_out=$(forged_runaway)
if [ "$(printf '%s\n' "$forged_out" | grep -c .)" = 1 ] && printf '%s\n' "$forged_out" | grep -q '^911'; then
  pass "argument text shaped like a row or a record adds no runaway candidate"
else
  fail "argument text shaped like a row or a record adds no runaway candidate: $(printf '%s\n' "$forged_out" | cut -c1-4 | tr '\n' ' ')"
fi

# ─── Process-group signalling ──────────────────────────────────────────────
# Group 500 holds two shared MCP servers (500, 501) and an unprotected one (502). The
# runaway phase never uses this path: see tests/guard-runaway.sh.

kill_with() {
  local target=$1
  ( ps() { case "$*" in
        "-o command= -p 500") echo "npx chrome-devtools-mcp@latest --autoConnect" ;;
        "-o command= -p 501") echo "npm exec @upstash/context7-mcp" ;;
        "-o command= -p 502") echo "node /x/.bin/mcp-server-tauri" ;;
        "-o pgid= -p "*)      echo " 500" ;;
        "-o rss= -p 500")     echo " 102400" ;;
        "-o rss= -p 501")     echo " 204800" ;;
        "-o rss= -p 502")     echo "  51200" ;;
        "-eo pid,pgid")       printf "500 500\n501 500\n502 500\n" ;;
        *) command ps "$@" ;; esac; }
    _CC_REAPER_DRY_RUN=1 _claude_pgid_kill "$target" 2>&1 || true )
}

out=$(kill_with 500)
if ! printf '%s' "$out" | grep -q 'Would kill PID 500' \
   && ! printf '%s' "$out" | grep -q 'Would kill PID 501'; then
  pass "group cleanup spares every shared member, the target included"
else
  fail "group cleanup signalled a shared member: $(printf '%s' "$out" | tr '\n' ' ')"
fi

printf '%s' "$out" | grep -q 'Would kill PID 502' \
  && pass "unprotected group member is still signalled" \
  || fail "unprotected group member was spared"

# ─── Delivery counting ─────────────────────────────────────────────────────

count_of() { printf '%s' "$1" | tail -1 | awk '{print $1}'; }
freed_of() { printf '%s' "$1" | tail -1 | awk '{print $2}'; }

out=$(kill_with 500)
[ "$(count_of "$out")" = 1 ] && pass "count reports the one delivery" || fail "count wrong: $(count_of "$out")"

# Only 502 (50 MB) is signalled; the spared 500 (100 MB) and 501 (200 MB) must not
# appear in the freed total.
[ "$(freed_of "$out")" = 50 ] \
  && pass "freed total counts only signalled processes" \
  || fail "freed total wrong: $(freed_of "$out") (want 50)"

printf 'protect\tchrome-devtools-mcp\n' > "$rules_file"
out=$(kill_with 500 || true)
[ "$(count_of "$out")" = 0 ] && pass "protected target reports zero deliveries" || fail "protected target counted: $(count_of "$out")"
: > "$rules_file"

kill_immutable() {
  ( ps() { case "$*" in
        "-o command= -p 600") echo "/System/Library/x/mdworker_shared" ;;
        *) command ps "$@" ;; esac; }
    _CC_REAPER_DRY_RUN=1 _claude_pgid_kill 600 2>&1 || true )
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
