#!/usr/bin/env bash
# claude-guard's runaway phase, run whole, the way the guard LaunchAgent runs it.
#
# Regression for reviews of 2026-09-15 and the audited host's guard log. A shared MCP
# server selected as runaway got its whole process group signalled: the Claude CLI that
# launched it, a stream-json subagent and a sibling MCP server. The phase had signalled
# ChatGPT.app, and cmux.app - the terminal the sessions ran in - on one CPU sample. The
# second review found eligibility still a substring test over the whole command line, so a
# session whose settings named claude-mem qualified, and heat still judged on `ps %cpu`,
# which decays over about a minute. The third found the lifetime average that replaced it
# wrong both ways: CPU time sums threads, so a multi-threaded server busy early qualified on
# a later burst, and a stall late in a long life was never caught.
#
# `ps`, `kill`, `sleep`, `date` and `osascript` are functions, and every PID is above PID_MAX.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLEANUP="${GUARD_SCRIPT:-$ROOT_DIR/shell/claude-cleanup.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-guard-runaway.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

NOW=2000000000
S="Mon Sep 14 00:00:00 2026"
R="Tue Sep 15 09:00:00 2026"

# pid ppid pgid tty cpu-now start etime cputime rss cpu-at-recheck command...
# start is S or R, the process start times above.
T="$tmp/table"
cat > "$T" <<'EOF'
960001 960000 960001 ttys901 3.0 S 05:00:00 9:00.00 400000 3.0 claude --session-id 11111111-2222-3333-4444-555555555555
960002 960001 960001 ?? 95.0 S 04:59:00 250:00.00 200000 96.0 uvx chroma-mcp --client-type persistent
960003 960001 960001 ?? 0.1 S 04:59:00 0:30.00 90000 0.1 node /Users/me/.npm/_npx/abc/node_modules/.bin/mcp-server-github
960004 960001 960001 ?? 0.0 S 04:58:00 0:10.00 50000 0.0 claude --output-format stream-json --input-format stream-json --verbose
960005 960001 960001 ?? 0.0 S 04:58:00 0:05.00 40000 0.0 npm exec @upstash/context7-mcp
970001 1 970001 ?? 99.0 S 03:00:00 170:00.00 100000 99.0 node /repo/node_modules/.bin/next dev-server --port 3000
970002 1 970002 ?? 99.0 S 03:00:00 170:00.00 60000 99.0 pm2 God Daemon
970003 970010 970010 ?? 111.7 S 23:52:37 1500:00.00 900000 111.0 /Applications/ChatGPT.app/Contents/Resources/codex -c features.x=true
970004 1 970004 ?? 80.8 S 15-13:40:59 18000:00.00 800000 81.0 /Applications/cmux.app/Contents/MacOS/cmux
980001 1 980001 ?? 95.0 S 03:00:00 170:00.00 120000 4.0 npx chrome-devtools-mcp@latest --autoConnect
980002 1 980002 ?? 90.0 S 03:00:00 170:00.00 110000 90.0 npm exec @upstash/context7-mcp
980003 1 980003 ?? 92.0 S 03:00:00 170:00.00 70000 92.0 npx -y mcp-sequentialthinking-tools
980004 1 980004 ?? 93.0 S 03:00:00 170:00.00 80000 93.0 npx -y @stripe/mcp --tools=all
990001 1 990001 ?? 99.0 S 03:00:00 170:00.00 60000 99.0 npx chrome-devtools-mcp@latest --headless
990002 1 990002 ?? 99.0 S 2-00:00:00 2700:00.00 150000 99.0 uvx chroma-mcp --client-type http
990003 1 990003 ?? 95.0 S 01:05:00 56:00.00 250000 95.0 /Users/me/.cache/uv/x1/bin/python /Users/me/.cache/uv/x1/bin/chroma-mcp
990004 1 990004 ?? 99.0 S 3-00:00:00 4000:00.00 90000 99.0 npx -y mcp-remote https://mcp.notion.com/mcp
990005 1 990005 ?? 99.0 R 03:00:00 170:00.00 90000 99.0 npm exec @upstash/context7-mcp
990006 1 990006 ?? 99.0 S 03:00:00 170:00.00 90000 99.0 uvx chroma-mcp --client-type ephemeral
990007 1 990007 ?? 97.0 S 1-02:00:00 75:00.00 150000 97.0 npx -y @supabase/mcp-server-supabase@0.5.10 --read-only
990008 1 990008 ?? 99.0 S 05:00:00 280:00.00 90000 99.0 uvx chroma-mcp --client-type cloud
990011 990010 990011 ttys906 95.0 S 03:00:00 170:00.00 500000 95.0 claude --session-id 22222222-3333-4444-5555-666666666666 --settings {"hooks":{"Stop":[{"type":"command","command":"node /Users/me/.claude/plugins/claude-mem/scripts/summary-hook.js"}]}}
990012 990011 990011 ?? 95.0 S 03:00:00 170:00.00 300000 95.0 claude --output-format stream-json --input-format stream-json --mcp-config {"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"]}}}
990013 1 990013 ?? 95.0 S 03:00:00 170:00.00 300000 95.0 node /Users/me/GitHub/context7-docs-sync/node_modules/.bin/stryker run
990014 1 990014 ?? 95.0 S 03:00:00 170:00.00 200000 95.0 python -m pytest /private/tmp/claude-501/-Users-me-GitHub-supabase-mcp-bench/tests -q
990015 1 990015 ?? 95.0 S 03:00:00 170:00.00 200000 95.0 /Users/me/.local/bin/codex --yolo -c mcp_servers.github.command=npx
EOF

# The samples an earlier run left: pid, the start it was recorded under, seconds since that
# sample, the percent of those seconds the process used, and its hot streak in minutes as of that
# sample. 990004 has none, and neither has anything that is not hot now.
cat > "$tmp/prior" <<'EOF'
960002 S 600 95 70
970001 S 600 99 120
970002 S 600 99 120
970003 S 600 110 120
970004 S 600 81 120
980001 S 600 95 120
980002 S 600 90 120
980003 S 600 92 120
980004 S 600 93 120
990001 S 600 99 45
990002 S 600 2 120
990003 S 600 1 5
990005 S 600 99 120
990006 S 30 99 59.5
990007 S 600 99 55
990008 S 1500 99 120
990011 S 600 95 120
990012 S 600 95 120
990013 S 600 95 120
990014 S 600 95 120
990015 S 600 95 120
EOF
awk -v now="$NOW" -v S="$S" -v R="$R" '
  function secs(t,   n, p, s) { n = split(t, p, ":"); s = p[n] + 0; if (n >= 2) s += p[n - 1] * 60; if (n >= 3) s += p[n - 2] * 3600; return s }
  FNR == NR { used[$1] = secs($8); next }
  { printf "%s\t%s\t%d\t%.2f\t%d\n", $1, ($2 == "R" ? R : S), now - $3, used[$1] - $4 * $3 / 100, now - $3 - $5 * 60 }
' "$T" "$tmp/prior" > "$tmp/samples.before"
mkdir -p "$tmp/cmds" "$tmp/home/.cc-reaper/logs"
: > "$tmp/empty-snapshot"
: > "$tmp/calls"

guard() (
  # The LaunchAgent runs with no shell options; this suite's `-u` must not leak in.
  set +euo pipefail
  export HOME="$tmp/home" CC_REAPER_RULES_FILE="$tmp/rules.tsv" CC_RUNAWAY_SAMPLES_FILE="$tmp/samples.tsv" \
    CC_REAPER_PS_SNAPSHOT_FILE="$tmp/empty-snapshot" CC_REAPER_PS_CMD_SNAPSHOT_DIR="$tmp/cmds"
  cmd_of() {
    local now
    now="$(awk -F '\t' -v p="$1" '$1 == p { print $2 }' "$tmp/now-cmd")"
    if [ -n "$now" ]; then printf '%s\n' "$now"; return; fi
    awk -v p="$1" '$1 == p { s = ""; for (i = 11; i <= NF; i++) s = s (i > 11 ? " " : "") $i; print s }' "$T"
  }
  ps() {
    local s=$S r=$R
    case "$*" in
      "-axo pid=,lstart=,etime=,time=,%cpu=")
        # Start times read in another locale or zone print differently, so a sample recorded by
        # the guard agent would never match a run from an interactive shell.
        if [ "${LC_ALL:-}" != C ] || [ "${TZ:-}" != UTC ]; then s="Mon 14 Sep 08:00:00 2026" r="Tue 15 Sep 17:00:00 2026"; fi
        awk -v S="$s" -v R="$r" '{ print $1, ($6 == "R" ? R : S), $7, $8, $5 }' "$T" ;;
      # The previous selection's format too, so GUARD_SCRIPT can point this suite at it
      # and have it fail for the defect rather than for the format.
      "-axo pid=,etime=,time=,%cpu=") awk '{ print $1, $7, $8, $5 }' "$T" ;;
      "-o command= -p "*) cmd_of "${!#}" ;;
      "-o %cpu= -p "*) awk -v p="${!#}" '$1 == p { print $10 }' "$T" ;;
      "-o pgid= -p "*) awk -v p="${!#}" '$1 == p { print $3 }' "$T" ;;
      "-eo pid,pgid") awk 'BEGIN { print "  PID  PGID" } { print $1, $3 }' "$T" ;;
      "-o rss= -p "*) awk -v p="${!#}" '$1 == p { print $9 }' "$T" ;;
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
  # At the re-check pause, 980002's PID comes to belong to another MCP server just as hot and a
  # protect rule comes to cover 980003; 980004 has exited, so its signal is not delivered. Both
  # changes land at the pause, so a PID read again before it would still be signalled.
  sleep() {
    printf 'sleep %s\n' "$1" >> "$tmp/calls"
    if [ "${1%%.*}" -ge 3 ] 2>/dev/null; then
      printf 'protect\tsequentialthinking\n' >> "$tmp/rules.tsv"
      printf '980002\tnpx chrome-devtools-mcp@latest --isolated\n' >> "$tmp/now-cmd"
    fi
  }
  date() { if [ "$*" = "+%s" ]; then echo "$NOW"; else command date "$@"; fi; }
  osascript() { :; }
  # shellcheck disable=SC1090
  . "$CLEANUP"
  # guard-runner.sh's environment
  export CC_MAX_SESSIONS=99999 CC_MAX_RSS_MB=99999999 CC_MAX_FD=99999999 CC_RUNAWAY_GRACE_SEC=0
  claude-guard "$@"
)

: > "$tmp/rules.tsv"; : > "$tmp/now-cmd"
cp "$tmp/samples.before" "$tmp/samples.tsv"
guard > "$tmp/guard.out" 2>&1

signalled() { grep -qx "$1" "$tmp/signalled" 2>/dev/null; }
expect_signalled()     { if signalled "$1"; then ok "$2"; else bad "$2"; fi; }
expect_not_signalled() { if signalled "$1"; then bad "$2"; else ok "$2"; fi; }

expect_signalled     960002 "the runaway MCP server itself is signalled"
expect_not_signalled 960001 "the Claude CLI that launched it is not signalled"
expect_not_signalled 960004 "its stream-json subagent is not signalled"
expect_not_signalled 960003 "its sibling MCP server is not signalled"
expect_not_signalled 960005 "an idle MCP server in its group is not signalled"
expect_not_signalled 970001 "a hot development server is not signalled"
expect_not_signalled 970002 "a hot process manager is not signalled"
expect_not_signalled 970003 "a hot ChatGPT.app process is not signalled"
expect_not_signalled 970004 "a hot cmux.app, the terminal sessions run in, is not signalled"
expect_not_signalled 980001 "a server that cooled by the re-check is not signalled"
expect_not_signalled 980002 "a PID running another command after the pause is not signalled"
expect_not_signalled 980003 "a PID a protect rule covers after the pause is not signalled"
expect_signalled     980004 "a second MCP server still hot at the re-check is signalled"
expect_not_signalled 990001 "a server hot for 55 minutes across runs is not signalled"
expect_not_signalled 990002 "a burst after an idle interval is not signalled, however hot the server's past"
expect_not_signalled 990003 "a multi-threaded server busy early is not signalled on a later burst"
expect_not_signalled 990004 "a hot server seen for the first time is not signalled"
expect_not_signalled 990005 "a PID sampled under another process start is not signalled"
expect_not_signalled 990006 "a streak short of the floor at a sample under a minute old is not signalled"
expect_signalled     990007 "a server idle for a day, then hot across runs for 65 minutes, is signalled"
expect_not_signalled 990008 "a streak carried across a 25-minute gap between runs is not signalled"
expect_not_signalled 990011 "a session whose --settings names claude-mem is not signalled"
expect_not_signalled 990012 "a subagent whose --mcp-config names context7 is not signalled"
expect_not_signalled 990013 "a stryker run under a context7-named directory is not signalled"
expect_not_signalled 990014 "a pytest run under a supabase-mcp-named path is not signalled"
expect_not_signalled 990015 "a Codex CLI configured with MCP servers is not signalled"

if grep -qF 'Reaped 2 runaway protected process(es), freed ~341 MB' "$tmp/guard.out"; then
  ok "the summary counts the two deliveries, and only their memory"
else
  bad "the summary counts the two deliveries, and only their memory: $(grep 'Reaped' "$tmp/guard.out")"
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

# What the run recorded: start, sample time, streak start.
sample() { awk -F '\t' -v p="$1" '$1 == p { print $2 "|" $3 "|" $5 }' "$tmp/samples.tsv"; }
expect_sample() { if [ "$(sample "$1")" = "$2" ]; then ok "$3"; else bad "$3: $(sample "$1")"; fi; }
expect_sample 960002 "$S|$NOW|$((NOW - 4800))" "a hot interval extends the streak and moves the sample to this run"
expect_sample 990003 "$S|$NOW|$NOW" "an interval below the threshold starts the streak over"
expect_sample 990004 "$S|$NOW|$NOW" "a first sample is recorded, with no streak"
expect_sample 990005 "$R|$NOW|$NOW" "a reused PID is recorded under its own start, with no streak"
expect_sample 990006 "$S|$((NOW - 30))|$((NOW - 3600))" "a sample less than a minute old is kept as it was"
expect_sample 990008 "$S|$NOW|$NOW" "a gap of more than 20 minutes starts the streak over"
expect_sample 960001 "" "a process not hot now has no sample"

# A dry run with zero thresholds: the defaults apply, and nothing is recorded.
: > "$tmp/rules.tsv"; : > "$tmp/now-cmd"
cp "$tmp/samples.before" "$tmp/samples.tsv"
CC_RUNAWAY_CPU=0 CC_RUNAWAY_MIN=0 guard --dry-run > "$tmp/dry.out" 2>&1
listed="$(awk '$1 == "PID" { print $2 }' "$tmp/dry.out" | sort -n | tr '\n' ' ')"
if [ "$listed" = "960002 980001 980002 980003 980004 990007 " ] && grep -qF 'CPU >= 80% across runs for >= 60 min' "$tmp/dry.out"; then
  ok "zero thresholds fall back to 80% and 60 minutes"
else
  bad "zero thresholds fall back to 80% and 60 minutes: listed $listed"
fi
if cmp -s "$tmp/samples.tsv" "$tmp/samples.before"; then
  ok "a dry run records no samples"
else
  bad "a dry run records no samples"
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
