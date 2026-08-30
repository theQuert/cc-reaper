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
  # Hot supabase MCP — protected and over both thresholds.
  _cc_monitor_is_runaway 102.0 09:07:51 && echo "is_runaway:yes" || echo "is_runaway:no"
  # Same MCP, well under the duration floor. Deliberately not a value that sits on the
  # default: the previous 00:30:00 encoded a 60-minute floor into a test whose stated
  # intent is only "hot but short is not a runaway", so lowering the default failed it for
  # no behavioural reason.
  _cc_monitor_is_runaway 102.0 00:12:00 && echo "etime_short:yes" || echo "etime_short:no"
  # Exactly at the floor counts, so the boundary is pinned rather than implied.
  CC_RUNAWAY_MIN=30 _cc_monitor_is_runaway 102.0 00:30:00 && echo "etime_at_floor:yes" || echo "etime_at_floor:no"
  CC_RUNAWAY_MIN=30 _cc_monitor_is_runaway 102.0 00:29:59 && echo "etime_below_floor:yes" || echo "etime_below_floor:no"
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
echo "$out" | grep -q "^etime_at_floor:yes$" && ok "is_runaway: elapsed exactly at floor → yes" || fail "is_runaway floor boundary"
echo "$out" | grep -q "^etime_below_floor:no$" && ok "is_runaway: one second below floor → no" || fail "is_runaway below floor"

#######################################################
# Report section: stuck/runaway present in human report when fixture has hot cloudflare MCP
#######################################################
fixture=$(mktemp)
# Hot supabase MCP — high avg CPU, long etime, parent != 1, no stale criteria.
printf "9594\t9370\t9594\tttys001\t09:07:51\t102.7\t348160\tnode /Users/quert/.npm/_npx/0a3d156e77e8dd08/node_modules/.bin/mcp-server-supabase run abc123\n" > "$fixture"
# Cool cmux — protected but cool, should stay DO_NOT_KILL.
printf "62199\t1\t62199\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" >> "$fixture"
# Unprotected runaway under a LIVE parent, taken from the real 2026-08-30 incident: a
# Homebrew Python at 99% CPU for 51 minutes, PPID a live zsh, no controlling terminal, and
# matching no protected pattern. Before the runaway test was hoisted out of the
# protected-command branch this row was never labelled, because being on the protection
# list was a precondition for being called a runaway.
printf "53630\t53620\t53620\t??\t00:51:40\t99.1\t14000\t/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python -c import gzip,hashlib\n" >> "$fixture"

out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway processes:" \
  && ok "human report has stuck/runaway section" \
  || fail "human report missing stuck/runaway section"
echo "$out" | grep -q "PID 9594" \
  && ok "stuck/runaway lists PID 9594" \
  || fail "stuck/runaway missing PID 9594"
# The hoisted runaway test. Asserting the row is *present* proves nothing: before the
# hoist it was already listed, as family "other" with ASK_BEFORE_KILL. What was missing
# was the identification, so the assertion is on the label.
echo "$out" | sed -n '/^Stuck\/runaway/,/^$/p' | grep -q "PID 53630" \
  && ok "unprotected runaway with a live parent lands in the runaway section" \
  || fail "unprotected runaway with a live parent lands in the runaway section"
echo "$out" | grep -q "suggested: kill 9594" \
  && ok "stuck/runaway prints kill command" \
  || fail "stuck/runaway no kill command"

#######################################################
# Report section: omitted when no runaway candidates
#######################################################
fixture_clean=$(mktemp)
printf "62199\t1\t62199\t??\t02:00:00\t1.0\t51200\t/Applications/cmux.app/Contents/MacOS/cmux\n" > "$fixture_clean"
out=$(CC_MONITOR_SNAPSHOT_FILE="$fixture_clean" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway processes:" \
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
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
f = next((x for x in d.get("findings", []) if x.get("pid") == 53630), None)
sys.exit(0 if f and f.get("family") == "runaway" and f.get("classification") == "ASK_BEFORE_KILL" else 1)
' && ok "unprotected runaway is family=runaway / ASK_BEFORE_KILL" \
  || fail "unprotected runaway is family=runaway / ASK_BEFORE_KILL"

# An Always Protect rule says what may be done to a process, not how it is behaving.
# Suppressing the label for one hid the case a user most wants to see: their own protected
# service pinned hot for hours. The rule must still govern the action.
RULES_FILE="$(mktemp "${TMPDIR:-/tmp}/ccr-rules.XXXXXX")"
printf 'protect\tmcp-server-supabase\n' > "$RULES_FILE"
ruled_out=$(CC_REAPER_RULES_FILE="$RULES_FILE" CC_MONITOR_SNAPSHOT_FILE="$fixture" \
  bash "$ROOT_DIR/shell/cc-monitor.sh" --once --json 2>/dev/null)
printf '%s' "$ruled_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
f = next((x for x in d.get("findings", []) if x.get("pid") == 9594), None)
sys.exit(0 if f and f.get("family") == "runaway"
         and "Always Protect" in (f.get("suggested_action") or "") else 1)
' && ok "a user-protected runaway is still labelled, with the Always Protect action" \
  || fail "a user-protected runaway is still labelled, with the Always Protect action"
rm -f "$RULES_FILE"

# The suggested action has to be applicable. claude-guard reaps through its own protected-
# process whitelist, so telling an operator to run it for a process that is not on that list
# names a remedy that does nothing - which is what the label change would have produced if
# the action had been left keyed on the old protected-only assumption.
printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
by = {x.get("pid"): x for x in d.get("findings", [])}
un, pr = by.get(53630), by.get(9594)
ok = (un and "claude-guard will not reap it" in (un.get("suggested_action") or "")
      and pr and "claude-guard" in (pr.get("suggested_action") or "")
      and "will not reap" not in (pr.get("suggested_action") or ""))
sys.exit(0 if ok else 1)
' && ok "runaway action distinguishes protected from report-only candidates" \
  || fail "runaway action distinguishes protected from report-only candidates"

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
printf "9594\t9370\t9594\tttys001\t09:07:51\t90.0\t348160\tnode /usr/local/bin/mcp-server-supabase run\n" > "$fixture_borderline"
out=$(CC_RUNAWAY_CPU=99 CC_MONITOR_SNAPSHOT_FILE="$fixture_borderline" bash "$ROOT_DIR/shell/cc-monitor.sh" --once 2>/dev/null)
echo "$out" | grep -q "Stuck/runaway processes:" \
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
    echo "  9594 09:07:51 102.7 node /usr/local/bin/mcp-server-supabase run abc"
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
    echo "  9594 09:07:51 102.7 node /usr/local/bin/mcp-server-supabase run abc"
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
