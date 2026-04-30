#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failures=0

ok() { printf "ok - %s\n" "$1"; }
fail() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

expect_eq() {
  local name=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then ok "$name"; else
    printf "not ok - %s (expected %s, got %s)\n" "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

#######################################################
# Classification: protected + runaway → runaway/ASK_BEFORE_KILL
#######################################################
out=$(bash -c '
  source "$1"
  # Hot cloudflare MCP — protected and over both thresholds.
  _cc_monitor_is_runaway 102.0 09:07:51 && echo "is_runaway:yes" || echo "is_runaway:no"
  # Same MCP but only 30 minutes elapsed — below default 60-minute threshold.
  _cc_monitor_is_runaway 102.0 00:30:00 && echo "etime_short:yes" || echo "etime_short:no"
  # CPU below 80% threshold.
  _cc_monitor_is_runaway 50.0 09:07:51 && echo "cpu_low:yes" || echo "cpu_low:no"
  # Threshold override via env.
  CC_RUNAWAY_CPU=40 _cc_monitor_is_runaway 50.0 09:07:51 && echo "cpu_override:yes" || echo "cpu_override:no"
  CC_RUNAWAY_MIN=10 _cc_monitor_is_runaway 102.0 00:30:00 && echo "min_override:yes" || echo "min_override:no"
' _ "$ROOT_DIR/shell/cc-monitor.sh")
echo "$out" | grep -q "^is_runaway:yes$" && ok "is_runaway: hot+long → yes" || fail "is_runaway baseline"
echo "$out" | grep -q "^etime_short:no$" && ok "is_runaway: hot+short → no" || fail "is_runaway short etime"
echo "$out" | grep -q "^cpu_low:no$" && ok "is_runaway: cool+long → no" || fail "is_runaway low cpu"
echo "$out" | grep -q "^cpu_override:yes$" && ok "is_runaway: CC_RUNAWAY_CPU honored" || fail "CC_RUNAWAY_CPU"
echo "$out" | grep -q "^min_override:yes$" && ok "is_runaway: CC_RUNAWAY_MIN honored" || fail "CC_RUNAWAY_MIN"

#######################################################
# Report section: stuck/runaway present in human report when fixture has hot cloudflare MCP
#######################################################
fixture=$(mktemp)
# Hot cloudflare MCP — high avg CPU, long etime, parent != 1, no stale criteria.
printf "9594\t9370\t9594\tttys001\t09:07:51\t102.7\t348160\tnode /Users/quert/.npm/_npx/0a3d156e77e8dd08/node_modules/.bin/mcp-server-cloudflare run abc123\n" > "$fixture"
# Cool cmux — protected but cool, should stay DO_NOT_KILL.
printf "62199\t1\t62199\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" >> "$fixture"

out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway protected processes:" \
  && ok "human report has stuck/runaway section" \
  || fail "human report missing stuck/runaway section"
echo "$out" | grep -q "PID 9594" \
  && ok "stuck/runaway lists PID 9594" \
  || fail "stuck/runaway missing PID 9594"
echo "$out" | grep -q "suggested: kill 9594" \
  && ok "stuck/runaway prints kill command" \
  || fail "stuck/runaway no kill command"

#######################################################
# Report section: omitted when no runaway candidates
#######################################################
fixture_clean=$(mktemp)
printf "62199\t1\t62199\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" > "$fixture_clean"
out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture_clean" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway protected processes:" \
  && fail "report shows runaway section without candidates" \
  || ok "report omits runaway section without candidates"
rm "$fixture_clean"

#######################################################
# JSON: runaway_candidates array present and populated
#######################################################
out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture" bash "$ROOT_DIR/shell/cc-monitor.sh" --once --json 2>/dev/null)
echo "$out" | grep -q '"runaway_candidates":' \
  && ok "JSON has runaway_candidates key" \
  || fail "JSON missing runaway_candidates"
echo "$out" | grep -q '"pid": 9594' \
  && ok "JSON includes runaway PID" \
  || fail "JSON missing runaway PID 9594"

#######################################################
# Reclassification: family is runaway, classification is ASK_BEFORE_KILL
#######################################################
echo "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
runaway_findings = [f for f in data["findings"] if f["family"] == "runaway"]
assert any(f["pid"] == 9594 and f["classification"] == "ASK_BEFORE_KILL" for f in runaway_findings), \
  "expected PID 9594 family=runaway classification=ASK_BEFORE_KILL"
print("ok-runaway-classification")
' 2>&1 | grep -q "^ok-runaway-classification$" \
  && ok "JSON finding for PID 9594 is family=runaway / ASK_BEFORE_KILL" \
  || fail "JSON finding reclassification"

rm "$fixture"

#######################################################
# CC_RUNAWAY_DISABLE leaves cc-monitor classification untouched? No — disable is for claude-guard only.
# But threshold envs do affect monitor. Verify CC_RUNAWAY_CPU=99 gates out a 90% process.
#######################################################
fixture_borderline=$(mktemp)
printf "9594\t9370\t9594\tttys001\t09:07:51\t90.0\t348160\tnode /usr/local/bin/mcp-server-cloudflare run\n" > "$fixture_borderline"
out=$(CC_RUNAWAY_CPU=99 CC_MONITOR_SNAPSHOT_FILE="$fixture_borderline" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway protected processes:" \
  && fail "CC_RUNAWAY_CPU=99 still flagged 90% process" \
  || ok "CC_RUNAWAY_CPU=99 gates out 90% process"
rm "$fixture_borderline"

#######################################################
# claude-guard: --dry-run lists runaway candidates without killing
#######################################################
# We stub ps to inject a fake runaway protected process row, then verify
# claude-guard --dry-run reports it but does not invoke kill.
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-guard-stub.XXXXXX")
kill_log=$(mktemp "${TMPDIR:-/tmp}/cc-guard-killlog.XXXXXX")
cat > "$stub_dir/ps" <<'STUB'
#!/usr/bin/env bash
# Inject a fake runaway protected row when claude-guard asks for it.
# Real ps invocations from elsewhere fall through to /bin/ps.
case " $* " in
  *" -axo pid=,etime=,%cpu=,command= "*)
    echo "  9594 09:07:51 102.7 node /usr/local/bin/mcp-server-cloudflare run abc"
    return 0
    ;;
  *)
    exec /bin/ps "$@"
    ;;
esac
STUB
chmod +x "$stub_dir/ps"
cat > "$stub_dir/kill" <<STUB
#!/usr/bin/env bash
echo "KILL:\$*" >> "$kill_log"
STUB
chmod +x "$stub_dir/kill"

out=$(PATH="$stub_dir:/usr/bin:/bin" bash -c '
  source "$1"
  claude-guard --dry-run 2>&1
' _ "$ROOT_DIR/shell/claude-cleanup.sh")
echo "$out" | grep -q "Runaway protected processes" \
  && ok "claude-guard --dry-run shows runaway section" \
  || fail "claude-guard --dry-run no runaway section (out: $(echo "$out" | head -3))"
echo "$out" | grep -q "PID 9594" \
  && ok "claude-guard --dry-run lists PID 9594" \
  || fail "claude-guard --dry-run missing PID"
echo "$out" | grep -q "DRY-RUN" \
  && ok "claude-guard --dry-run says DRY-RUN" \
  || fail "claude-guard --dry-run no DRY-RUN tag"
[ ! -s "$kill_log" ] \
  && ok "claude-guard --dry-run did not call kill" \
  || fail "claude-guard --dry-run invoked kill (log: $(cat "$kill_log"))"
rm -rf "$stub_dir" "$kill_log"

#######################################################
# claude-guard: CC_RUNAWAY_DISABLE=1 skips phase
#######################################################
stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-guard-stub.XXXXXX")
kill_log=$(mktemp "${TMPDIR:-/tmp}/cc-guard-killlog.XXXXXX")
cat > "$stub_dir/ps" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -axo pid=,etime=,%cpu=,command= "*)
    echo "  9594 09:07:51 102.7 node /usr/local/bin/mcp-server-cloudflare run abc"
    return 0
    ;;
  *)
    exec /bin/ps "$@"
    ;;
esac
STUB
chmod +x "$stub_dir/ps"
out=$(PATH="$stub_dir:/usr/bin:/bin" CC_RUNAWAY_DISABLE=1 bash -c '
  source "$1"
  claude-guard --dry-run 2>&1
' _ "$ROOT_DIR/shell/claude-cleanup.sh")
echo "$out" | grep -q "Runaway protected processes" \
  && fail "CC_RUNAWAY_DISABLE=1 still showed runaway section" \
  || ok "CC_RUNAWAY_DISABLE=1 skips runaway phase"
rm -rf "$stub_dir" "$kill_log"

if [ "$failures" -gt 0 ]; then
  printf "\n%d failure(s)\n" "$failures" >&2
  exit 1
fi
echo "all tests passed"
