#!/usr/bin/env bash
# claude-guard's runaway phase, run whole, the way the guard LaunchAgent runs it.
#
# Regression for reviews of 2026-09-15 and the audited host's guard log. A shared MCP
# server selected as runaway got its whole process group signalled: the Claude CLI that
# launched it, a stream-json subagent and a sibling MCP server. The phase had signalled
# ChatGPT.app, and cmux.app - the terminal the sessions ran in - on one CPU sample. The
# second review found eligibility still a substring test over the whole command line, so a
# session whose settings named claude-mem qualified, and heat still judged on `ps %cpu`,
# which decays over about a minute.
#
# `ps`, `kill`, `sleep` and `osascript` are functions, and every PID is above PID_MAX.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="${GUARD_SCRIPT:-$ROOT_DIR/shell/claude-cleanup.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-guard-runaway.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

# pid ppid pgid tty cpu-at-selection etime cputime rss cpu-at-recheck command...
T="$tmp/table"
cat > "$T" <<'EOF'
960001 960000 960001 ttys901 3.0 05:00:00 9:00.00 400000 3.0 claude --session-id 11111111-2222-3333-4444-555555555555
960002 960001 960001 ?? 95.0 04:59:00 250:00.00 200000 96.0 uvx chroma-mcp --client-type persistent
960003 960001 960001 ?? 0.1 04:59:00 0:30.00 90000 0.1 node /Users/me/.npm/_npx/abc/node_modules/.bin/mcp-server-github
960004 960001 960001 ?? 0.0 04:58:00 0:10.00 50000 0.0 claude --output-format stream-json --input-format stream-json --verbose
970001 1 970001 ?? 99.0 01:30:00 85:00.00 100000 99.0 node /repo/node_modules/.bin/next dev-server --port 3000
970002 1 970002 ?? 99.0 02:00:00 115:00.00 60000 99.0 pm2 God Daemon
970003 970010 970010 ?? 111.7 23:52:37 1500:00.00 900000 111.0 /Applications/ChatGPT.app/Contents/Resources/codex -c features.x=true
970004 1 970004 ?? 80.8 15-13:40:59 18000:00.00 800000 81.0 /Applications/cmux.app/Contents/MacOS/cmux
980001 1 980001 ?? 95.0 03:00:00 170:00.00 120000 4.0 npx chrome-devtools-mcp@latest --autoConnect
980002 1 980002 ?? 90.0 03:00:00 170:00.00 110000 90.0 npm exec @upstash/context7-mcp
980003 1 980003 ?? 92.0 03:00:00 170:00.00 70000 92.0 npx -y mcp-sequentialthinking-tools
980004 1 980004 ?? 93.0 03:00:00 170:00.00 80000 93.0 npx -y @stripe/mcp --tools=all
990001 1 990001 ?? 99.0 00:30:00 29:00.00 60000 99.0 npx chrome-devtools-mcp@latest --headless
990002 1 990002 ?? 99.0 2-00:00:00 60:00.00 150000 99.0 uvx chroma-mcp --client-type http
990011 990010 990011 ttys906 95.0 03:00:00 170:00.00 500000 95.0 claude --session-id 22222222-3333-4444-5555-666666666666 --settings {"hooks":{"Stop":[{"type":"command","command":"node /Users/me/.claude/plugins/claude-mem/scripts/summary-hook.js"}]}}
990012 990011 990011 ?? 95.0 03:00:00 170:00.00 300000 95.0 claude --output-format stream-json --input-format stream-json --mcp-config {"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}
990013 1 990013 ?? 95.0 03:00:00 170:00.00 300000 95.0 node /Users/me/GitHub/context7-docs-sync/node_modules/.bin/stryker run
990014 1 990014 ?? 95.0 03:00:00 170:00.00 200000 95.0 python -m pytest /private/tmp/claude-501/-Users-me-GitHub-supabase-mcp-bench/tests -q
990015 1 990015 ?? 95.0 03:00:00 170:00.00 200000 95.0 /Users/me/.local/bin/codex --yolo -c mcp_servers.github.command=npx
EOF
# At the re-check pause, 980002's PID comes to belong to another MCP server just as hot and a
# protect rule comes to cover 980003; 980004 has exited, so its signal is not delivered. Both
# changes land at the pause, so a PID read again before it would still be signalled.
: > "$tmp/now-cmd"
: > "$tmp/rules.tsv"
: > "$tmp/empty-snapshot"
: > "$tmp/calls"
mkdir -p "$tmp/cmds" "$tmp/home/.cc-reaper/logs"

(
  # The LaunchAgent runs with no shell options; this suite's `-u` must not leak in.
  set +euo pipefail
  export HOME="$tmp/home" CC_REAPER_RULES_FILE="$tmp/rules.tsv" \
    CC_REAPER_PS_SNAPSHOT_FILE="$tmp/empty-snapshot" CC_REAPER_PS_CMD_SNAPSHOT_DIR="$tmp/cmds"
  cmd_of() {
    local now
    now="$(awk -F '\t' -v p="$1" '$1 == p { print $2 }' "$tmp/now-cmd")"
    if [ -n "$now" ]; then printf '%s\n' "$now"; return; fi
    awk -v p="$1" '$1 == p { s = ""; for (i = 10; i <= NF; i++) s = s (i > 10 ? " " : "") $i; print s }' "$T"
  }
  ps() {
    case "$*" in
      "-axo pid=,etime=,time=,%cpu=") awk '{ print $1, $6, $7, $5 }' "$T" ;;
      # The previous selection's format too, so GUARD_SCRIPT can point this suite at it
      # and have it fail for the defect rather than for the format.
      "-axo pid=,etime=,%cpu=,command=")
        awk '{ printf "%s %s %s", $1, $6, $5; for (i = 10; i <= NF; i++) printf " %s", $i; print "" }' "$T" ;;
      "-o command= -p "*) cmd_of "${!#}" ;;
      "-o %cpu= -p "*) awk -v p="${!#}" '$1 == p { print $9 }' "$T" ;;
      "-o pgid= -p "*) awk -v p="${!#}" '$1 == p { print $3 }' "$T" ;;
      "-eo pid,pgid") awk 'BEGIN { print "  PID  PGID" } { print $1, $3 }' "$T" ;;
      "-o rss= -p "*) awk -v p="${!#}" '$1 == p { print $8 }' "$T" ;;
      *) printf '%s\n' "$*" >> "$tmp/unstubbed"; return 0 ;;
    esac
  }
  kill() {
    local a
    for a in "$@"; do
      case "$a" in -*) ;; *) printf '%s\n' "$a" >> "$tmp/signalled"; printf 'kill %s\n' "$a" >> "$tmp/calls" ;; esac
    done
    case " $* " in *" 980004 "*) return 1 ;; esac
    return 0
  }
  sleep() {
    printf 'sleep %s\n' "$1" >> "$tmp/calls"
    if [ "${1%%.*}" -ge 3 ] 2>/dev/null; then
      printf 'protect\tsequentialthinking\n' >> "$tmp/rules.tsv"
      printf '980002\tnpx chrome-devtools-mcp@latest --isolated\n' >> "$tmp/now-cmd"
    fi
  }
  osascript() { :; }
  # shellcheck disable=SC1090
  . "$CLEANUP"
  # guard-runner.sh's environment
  export CC_MAX_SESSIONS=99999 CC_MAX_RSS_MB=99999999 CC_MAX_FD=99999999 CC_RUNAWAY_GRACE_SEC=0
  claude-guard
) > "$tmp/guard.out" 2>&1

signalled() { grep -qx "$1" "$tmp/signalled" 2>/dev/null; }
expect_signalled()     { if signalled "$1"; then ok "$2"; else bad "$2"; fi; }
expect_not_signalled() { if signalled "$1"; then bad "$2"; else ok "$2"; fi; }

expect_signalled     960002 "the runaway MCP server itself is signalled"
expect_not_signalled 960001 "the Claude CLI that launched it is not signalled"
expect_not_signalled 960004 "its stream-json subagent is not signalled"
expect_not_signalled 960003 "its sibling MCP server is not signalled"
expect_not_signalled 970001 "a hot development server is not signalled"
expect_not_signalled 970002 "a hot process manager is not signalled"
expect_not_signalled 970003 "a hot ChatGPT.app process is not signalled"
expect_not_signalled 970004 "a hot cmux.app, the terminal sessions run in, is not signalled"
expect_not_signalled 980001 "a server that cooled by the re-check is not signalled"
expect_not_signalled 980002 "a PID running another command after the pause is not signalled"
expect_not_signalled 980003 "a PID a protect rule covers after the pause is not signalled"
expect_signalled     980004 "a second MCP server still hot at the re-check is signalled"
expect_not_signalled 990001 "a hot MCP server younger than CC_RUNAWAY_MIN is not signalled"
expect_not_signalled 990002 "a two-day-old MCP server in a burst, averaging 2% over its life, is not signalled"
expect_not_signalled 990011 "a session whose --settings names claude-mem is not signalled"
expect_not_signalled 990012 "a subagent whose --mcp-config names context7 is not signalled"
expect_not_signalled 990013 "a stryker run under a context7-named directory is not signalled"
expect_not_signalled 990014 "a pytest run under a supabase-mcp-named path is not signalled"
expect_not_signalled 990015 "a Codex CLI configured with MCP servers is not signalled"

if grep -qF 'Reaped 1 runaway protected process(es), freed ~195 MB' "$tmp/guard.out"; then
  ok "the summary counts the one delivery, and only its memory"
else
  bad "the summary counts the one delivery, and only its memory: $(grep 'Reaped' "$tmp/guard.out")"
fi
if awk '$1 == "sleep" { s += $2 } END { exit !(s >= 3) }' "$tmp/calls"; then
  ok "the re-check waits at least three seconds"
else
  bad "the re-check waits at least three seconds"
fi
if awk '$1 == "sleep" && $2 >= 3 { paused = 1 } $1 == "kill" { seen = 1; if (!paused) early = 1 }
        END { exit !(seen && !early) }' "$tmp/calls"; then
  ok "every signal follows that pause"
else
  bad "every signal follows that pause: $(tr '\n' ';' < "$tmp/calls")"
fi
if [ ! -s "$tmp/unstubbed" ]; then
  ok "every ps call the guard made is one the table answers"
else
  bad "unstubbed ps calls: $(tr '\n' ';' < "$tmp/unstubbed")"
fi

if [ "$failures" -eq 0 ]; then
  echo "guard-runaway: all tests passed"
else
  echo "guard-runaway: $failures failure(s)"
  exit 1
fi
