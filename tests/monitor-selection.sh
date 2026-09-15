#!/usr/bin/env bash
# What the LaunchAgent monitor signals when its whole body runs.
#
# Regression for 2026-09-10/11: all six kills in a live monitor.log were test runs and
# session scratchpad scripts. The runaway override selected any hot PPID=1 process
# whose command line merely contained `claude`, `node`, `mcp`, `bun`, `codex` or `npx`
# anywhere - and a Claude Code scratchpad path is /private/tmp/claude-501/...
#
# `ps`, `kill` and `sleep` are replaced by functions before the script is sourced, so
# the real body runs against a fixed process table and signals nothing real.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MON="${MON_SCRIPT:-$ROOT_DIR/launchd/cc-reaper-monitor.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor-selection.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

# One process per line: pid ppid tty cpu mem etime command...
# Run the monitor body once against the table in $1; print the pids it signalled.
run_monitor() {
  local table="$1"
  (
    # The LaunchAgent runs the script with no shell options; this suite's `-u` would
    # abort it at its first empty array and make every case pass for the wrong reason.
    set +euo pipefail
    export HOME="$tmp/home" CC_REAPER_RULES_FILE="$tmp/no-rules.tsv"
    mkdir -p "$HOME"
    ps() {
      case "$*" in
        "-eo pid,ppid,pgid") awk 'BEGIN { print "PID PPID PGID" } { print $1, $2, $1 + 100000 }' "$table" ;;
        "-eo pid=,ppid=,tty=,%cpu=,%mem=,etime=,command=") cat "$table" ;;
        "-eo pid=,ppid=,%cpu=,etime=,command=")
          awk '{ $3 = ""; $5 = ""; print }' "$table" | tr -s ' ' ;;
        "-eo pid,pgid") awk '{ print $1, $1 + 100000 }' "$table" ;;
        "-o command= -p "*) awk -v p="${!#}" '$1 == p { $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print }' "$table" ;;
        "-o %cpu= -p "*) awk -v p="${!#}" '$1 == p { print $4 }' "$table" ;;
        "-o pgid= -p "*) awk -v p="${!#}" '$1 == p { print $1 + 100000 }' "$table" ;;
        "-eo pid,pgid,%cpu,%mem,command") awk '{ print $1, $1 + 100000, $4, $5, $7 }' "$table" ;;
        *) return 0 ;;
      esac
    }
    kill() {
      local a
      for a in "$@"; do case "$a" in -*) ;; *) printf '%s\n' "$a" >> "$tmp/signalled" ;; esac; done
      return 0
    }
    sleep() { :; }
    # shellcheck disable=SC1090
    source "$MON"
  ) >/dev/null 2>&1
  sort -u "$tmp/signalled" 2>/dev/null
  rm -f "$tmp/signalled"
}

T="$tmp/table"
cat > "$T" <<'EOF'
501 1 ?? 99.0 1.0 10:16 /Users/me/.cache/uv/builds-v0/.tmpX/bin/python -m pytest paper3/tests -q -x --basetemp=/private/tmp/claude-501/-Users-me-GitHub-research/abc/scratchpad/pt
502 1 ?? 99.0 1.0 16:08 /private/tmp/claude-501/-Users-me-GitHub-research/abc/scratchpad/sweep.sh --grid 40
503 1 ?? 99.0 1.0 01:00:00 node /repo/node_modules/.bin/next dev-server --port 3000
504 1 ?? 99.0 1.0 45:00 bun test --watch /Users/me/GitHub/app
505 1 ?? 0.0 0.1 02:00:00 npm exec @cloudflare/mcp-server-cloudflare@latest
506 1 ?? 99.0 1.0 03:00:00 npx chrome-devtools-mcp@latest --autoConnect
EOF

signalled="$(run_monitor "$T")"
has() { printf '%s\n' "$signalled" | grep -qx "$1"; }

has 501 && bad "a hot test run carrying a scratchpad path is not signalled" || ok "a hot test run carrying a scratchpad path is not signalled"
has 502 && bad "a hot scratchpad script is not signalled" || ok "a hot scratchpad script is not signalled"
has 503 && bad "a hot protected dev server is not signalled" || ok "a hot protected dev server is not signalled"
has 504 && bad "a hot bun test watcher is not signalled" || ok "a hot bun test watcher is not signalled"
has 505 && ok "an orphaned unprotected MCP server is still signalled by the family sweep" \
  || bad "an orphaned unprotected MCP server is still signalled by the family sweep"
has 506 && bad "a stuck shared MCP is left to claude-guard's runaway phase" \
  || ok "a stuck shared MCP is left to claude-guard's runaway phase"

if grep -vE '^[[:space:]]*#' "$MON" | grep -q 'CC_RUNAWAY_ORPHAN_MIN_SEC'; then
  bad "no code reads CC_RUNAWAY_ORPHAN_MIN_SEC"
else
  ok "no code reads CC_RUNAWAY_ORPHAN_MIN_SEC"
fi

if [ "$failures" -eq 0 ]; then
  echo "monitor-selection: all tests passed"
else
  echo "monitor-selection: $failures failure(s)"
  exit 1
fi
