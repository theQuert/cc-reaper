#!/usr/bin/env bash
# claude-guard's runaway phase, run whole, the way the guard LaunchAgent runs it.
#
# Regression for review of 2026-09-15 and the audited host's guard log. A shared MCP
# server selected as runaway got its whole process group signalled: the Claude CLI that
# launched it, a stream-json subagent and a sibling MCP server. The phase had also
# signalled ChatGPT.app, and cmux.app - the terminal the sessions ran in - on one CPU
# sample.
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

# pid ppid pgid tty cpu-at-selection etime rss cpu-at-recheck command...
T="$tmp/table"
cat > "$T" <<'EOF'
960001 960000 960001 ttys901 3.0 05:00:00 400000 3.0 claude --session-id 11111111-2222-3333-4444-555555555555
960002 960001 960001 ?? 95.0 04:59:00 200000 96.0 uvx chroma-mcp --client-type persistent
960003 960001 960001 ?? 0.1 04:59:00 90000 0.1 node /Users/me/.npm/_npx/abc/node_modules/.bin/mcp-server-github
960004 960001 960001 ?? 0.0 04:58:00 50000 0.0 claude --output-format stream-json --input-format stream-json --verbose
970001 1 970001 ?? 99.0 01:30:00 100000 99.0 node /repo/node_modules/.bin/next dev-server --port 3000
970002 1 970002 ?? 99.0 02:00:00 60000 99.0 pm2 God Daemon
970003 970010 970010 ?? 111.7 23:52:37 900000 111.0 /Applications/ChatGPT.app/Contents/Resources/codex -c features.x=true
970004 1 970004 ?? 80.8 15-13:40:59 800000 81.0 /Applications/cmux.app/Contents/MacOS/cmux
980001 1 980001 ?? 95.0 03:00:00 120000 4.0 npx chrome-devtools-mcp@latest --autoConnect
980002 1 980002 ?? 90.0 03:00:00 110000 90.0 npm exec @upstash/context7-mcp
980003 1 980003 ?? 92.0 03:00:00 70000 92.0 npx -y mcp-sequentialthinking-tools
980004 1 980004 ?? 93.0 03:00:00 80000 93.0 npx -y @stripe/mcp --tools=all
EOF
# By the re-check, 980002's PID belongs to another MCP server just as hot, a protect rule
# covers 980003, and 980004 has exited, so its signal is not delivered.
printf '980002\tnpx chrome-devtools-mcp@latest --isolated\n' > "$tmp/now-cmd"
: > "$tmp/rules.tsv"
: > "$tmp/empty-snapshot"
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
    awk -v p="$1" '$1 == p { s = ""; for (i = 9; i <= NF; i++) s = s (i > 9 ? " " : "") $i; print s }' "$T"
  }
  ps() {
    case "$*" in
      "-axo pid=,etime=,%cpu=,command=")
        awk '{ printf "%s %s %s", $1, $6, $5; for (i = 9; i <= NF; i++) printf " %s", $i; print "" }' "$T" ;;
      "-o command= -p "*) cmd_of "${!#}" ;;
      "-o %cpu= -p "*) awk -v p="${!#}" '$1 == p { print $8 }' "$T" ;;
      "-o pgid= -p "*) awk -v p="${!#}" '$1 == p { print $3 }' "$T" ;;
      "-eo pid,pgid") awk 'BEGIN { print "  PID  PGID" } { print $1, $3 }' "$T" ;;
      "-o rss= -p "*) awk -v p="${!#}" '$1 == p { print $7 }' "$T" ;;
      *) printf '%s\n' "$*" >> "$tmp/unstubbed"; return 0 ;;
    esac
  }
  kill() {
    local a
    for a in "$@"; do case "$a" in -*) ;; *) printf '%s\n' "$a" >> "$tmp/signalled" ;; esac; done
    case " $* " in *" 980004 "*) return 1 ;; esac
    return 0
  }
  # Selection is over before the first pause, so this rule is one the signal stage has to
  # discover for itself.
  sleep() {
    printf '%s\n' "$1" >> "$tmp/slept"
    printf 'protect\tsequentialthinking\n' >> "$tmp/rules.tsv"
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
expect_not_signalled 980002 "a PID running another command at the re-check is not signalled"
expect_not_signalled 980003 "a PID a protect rule covers by the re-check is not signalled"
expect_signalled     980004 "a second MCP server still hot at the re-check is signalled"

if grep -qF 'Reaped 1 runaway protected process(es), freed ~195 MB' "$tmp/guard.out"; then
  ok "the summary counts the one delivery, and only its memory"
else
  bad "the summary counts the one delivery, and only its memory: $(grep 'Reaped' "$tmp/guard.out")"
fi
if awk '{ s += $1 } END { exit !(s >= 3) }' "$tmp/slept" 2>/dev/null; then
  ok "the re-check waits at least three seconds"
else
  bad "the re-check waits at least three seconds"
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
