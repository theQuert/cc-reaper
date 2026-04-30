#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/shell/cc-monitor.sh"

export CC_AGENT_STALE_MINUTES=60

failures=0

expect_eq() {
  local name=$1
  local actual=$2
  local expected=$3
  if [ "$actual" = "$expected" ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s (expected %s, got %s)\n" "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

expect_contains() {
  local name=$1
  local file=$2
  local pattern=$3
  if grep -qE -- "$pattern" "$file"; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

classify_cmd() {
  local ppid=$1
  local tty=$2
  local etime=$3
  local cmd=$4
  local family
  family=$(_cc_monitor_family "$cmd")
  printf "%s/%s" "$family" "$(_cc_monitor_classification "$ppid" "$tty" "$etime" "$cmd" "$family")"
}

expect_eq "Cursor renderer asks before kill" \
  "$(classify_cmd 10 ttys001 00:10:00 "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)")" \
  "editor/ASK_BEFORE_KILL"

expect_eq "cmux asks before kill" \
  "$(classify_cmd 1 "??" 02:00:00 "/Applications/cmux.app/Contents/MacOS/cmux")" \
  "cmux/ASK_BEFORE_KILL"

expect_eq "WindowServer is do-not-kill" \
  "$(classify_cmd 1 "??" 18-00:00:00 "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon")" \
  "system/DO_NOT_KILL"

expect_eq "normal Chrome is do-not-kill" \
  "$(classify_cmd 689 "??" 01:00:00 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Default")" \
  "chrome/DO_NOT_KILL"

expect_eq "stale agent-browser is safe to reap" \
  "$(classify_cmd 123 "??" 02:00:00 "/usr/local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64")" \
  "agent-browser/SAFE_TO_REAP"

expect_eq "recent agent-browser asks before kill" \
  "$(classify_cmd 123 "??" 00:05:00 "/usr/local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64")" \
  "agent-browser/ASK_BEFORE_KILL"

expect_eq "orphan Codex is safe to reap" \
  "$(classify_cmd 1 "??" 00:05:00 "node /usr/local/bin/codex --yolo")" \
  "codex/SAFE_TO_REAP"

expect_eq "dev server asks before kill" \
  "$(classify_cmd 200 ttys002 03:00:00 "node /repo/web/default/node_modules/react-scripts/scripts/start.js")" \
  "dev-server/ASK_BEFORE_KILL"

expect_eq "shared Supabase MCP is do-not-kill" \
  "$(classify_cmd 123 "??" 03:00:00 "node /Users/me/.npm/_npx/53c4795544aaa350/node_modules/.bin/mcp-server-supabase --access-token sbp_secret")" \
  "mcp/DO_NOT_KILL"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

raw_file="$tmp_dir/raw.tsv"
agg_file="$tmp_dir/agg.tsv"
snapshot_file="$tmp_dir/snapshot.tsv"
json_file="$tmp_dir/report.json"

{
  printf "201\t10\t10\tttys001\t00:01:00\t10.0\t10240\tpython worker.py\n"
  printf "201\t10\t10\tttys001\t00:01:05\t30.0\t20480\tpython worker.py\n"
} > "$raw_file"

_cc_monitor_aggregate_samples "$raw_file" "$agg_file"
agg_line=$(grep "python worker.py" "$agg_file")
agg_avg=$(echo "$agg_line" | awk -F '\t' '{print $1}')
agg_max=$(echo "$agg_line" | awk -F '\t' '{print $2}')
agg_rss=$(echo "$agg_line" | awk -F '\t' '{print $9}')

expect_eq "aggregation average CPU" "$agg_avg" "20.00"
expect_eq "aggregation max CPU" "$agg_max" "30.00"
expect_eq "aggregation RSS MB rounds max" "$agg_rss" "20"

{
  printf "101\t10\t10\tttys001\t00:10:00\t120.0\t512000\t/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)\n"
  printf "102\t1\t102\t??\t02:00:00\t0.2\t20480\t/usr/local/lib/node_modules/agent-browser/bin/agent-browser-darwin-arm64\n"
  printf "103\t1\t103\t??\t18-00:00:00\t40.0\t100000\t/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon\n"
  printf "104\t555\t555\tttys002\t00:05:00\t18.0\t150000\tnode /repo/web/default/node_modules/react-scripts/scripts/start.js\n"
  printf "105\t689\t689\t??\t01:00:00\t15.0\t300000\t/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Default\n"
  printf "106\t123\t123\t??\t03:00:00\t2.0\t30000\tnode /Users/me/.npm/_npx/53c4795544aaa350/node_modules/.bin/mcp-server-supabase --access-token sbp_secret\n"
} > "$snapshot_file"

CC_MONITOR_SNAPSHOT_FILE="$snapshot_file" bash "$ROOT_DIR/shell/cc-monitor.sh" --once --json > "$json_file"

if command -v python3 >/dev/null 2>&1; then
  if python3 -m json.tool "$json_file" >/dev/null; then
    printf "ok - json output is valid\n"
  else
    printf "not ok - json output is valid\n"
    failures=$((failures + 1))
  fi
fi

expect_contains "json includes sample count" "$json_file" '"sample_count": 1'
expect_contains "json includes ask-before-kill" "$json_file" '"classification": "ASK_BEFORE_KILL"'
expect_contains "json includes safe-to-reap" "$json_file" '"classification": "SAFE_TO_REAP"'
expect_contains "json includes do-not-kill" "$json_file" '"classification": "DO_NOT_KILL"'
expect_contains "json includes family totals" "$json_file" '"family_totals"'
expect_contains "json redacts access tokens" "$json_file" '--access-token \[redacted\]'

if [ "$failures" -gt 0 ]; then
  printf "%s validation failure(s)\n" "$failures"
  exit 1
fi

printf "cc-monitor validation passed\n"
