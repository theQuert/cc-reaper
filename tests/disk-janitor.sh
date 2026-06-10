#!/usr/bin/env bash
# TAP-style test harness for shell/disk-janitor.sh
# All destructive operations go through PATH-shimmed stubs in a mktemp sandbox.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failures=0

expect_yes() {
  local name=$1
  shift
  local rc=0
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

expect_no() {
  local name=$1
  shift
  local rc=0
  { "$@"; } 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf "ok - %s\n" "$name"
  else
    printf "not ok - %s\n" "$name"
    failures=$((failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# Sandbox setup
# ---------------------------------------------------------------------------

SANDBOX="$(mktemp -d)"
FAKE_HOME="$SANDBOX/home"
FAKE_BIN="$SANDBOX/bin"
mkdir -p "$FAKE_HOME" "$FAKE_BIN"

# Capture files for stubs
TM_DELETE_CAPTURE="$SANDBOX/tm_delete_calls"
OSASCRIPT_CAPTURE="$SANDBOX/osascript_calls"
DOCKER_CAPTURE="$SANDBOX/docker_calls"
GO_CAPTURE="$SANDBOX/go_calls"
YARN_CAPTURE="$SANDBOX/yarn_calls"
PIP3_CAPTURE="$SANDBOX/pip3_calls"
BREW_CAPTURE="$SANDBOX/brew_calls"
BUN_CAPTURE="$SANDBOX/bun_calls"
RM_CAPTURE="$SANDBOX/rm_calls"

touch "$TM_DELETE_CAPTURE" "$OSASCRIPT_CAPTURE" "$DOCKER_CAPTURE" \
      "$GO_CAPTURE" "$YARN_CAPTURE" "$PIP3_CAPTURE" "$BREW_CAPTURE" \
      "$BUN_CAPTURE" "$RM_CAPTURE"

# We set FREE_PCT via the df stub; default below-threshold
FREE_PCT="${FREE_PCT_OVERRIDE:-10}"

# ---------------------------------------------------------------------------
# PATH stubs
# ---------------------------------------------------------------------------

# df stub: returns controllable free percentage
cat > "$FAKE_BIN/df" <<'STUB'
#!/usr/bin/env bash
# Intercept "df -P <any volume>" — pass through anything else
if [ "${1:-}" = "-P" ]; then
  FREE="${FAKE_DF_FREE_PCT:-10}"
  USED=$((100 - FREE))
  # Columns: Filesystem 1024-blocks Used Available Use% Mounted
  printf "Filesystem     1024-blocks      Used Available Capacity Mounted on\n"
  printf "/dev/disk1s1   976490576 %d %d   %d%%  /\n" "$((USED * 1000))" "$((FREE * 1000))" "$USED"
else
  command df "$@"
fi
STUB
chmod +x "$FAKE_BIN/df"

# tmutil stub: canned snapshot list; deletelocalsnapshots captures calls
cat > "$FAKE_BIN/tmutil" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  listlocalsnapshots)
    printf "com.apple.TimeMachine.2026-06-08-040000.local\n"
    printf "com.apple.TimeMachine.2026-06-09-040000.local\n"
    printf "com.apple.os.update-A38BB437-17D2-4B88-9E50-0B04A72B34A3.local\n"
    ;;
  deletelocalsnapshots)
    echo "\$2" >> "$TM_DELETE_CAPTURE"
    ;;
  *)
    command tmutil "\$@" 2>/dev/null || true
    ;;
esac
STUB
chmod +x "$FAKE_BIN/tmutil"

# osascript stub
cat > "$FAKE_BIN/osascript" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$OSASCRIPT_CAPTURE"
STUB
chmod +x "$FAKE_BIN/osascript"

# docker stub
cat > "$FAKE_BIN/docker" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$DOCKER_CAPTURE"
STUB
chmod +x "$FAKE_BIN/docker"

# go stub
cat > "$FAKE_BIN/go" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$GO_CAPTURE"
STUB
chmod +x "$FAKE_BIN/go"

# yarn stub
cat > "$FAKE_BIN/yarn" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$YARN_CAPTURE"
STUB
chmod +x "$FAKE_BIN/yarn"

# pip3 stub
cat > "$FAKE_BIN/pip3" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$PIP3_CAPTURE"
STUB
chmod +x "$FAKE_BIN/pip3"

# brew stub
cat > "$FAKE_BIN/brew" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$BREW_CAPTURE"
STUB
chmod +x "$FAKE_BIN/brew"

# bun stub
cat > "$FAKE_BIN/bun" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$BUN_CAPTURE"
STUB
chmod +x "$FAKE_BIN/bun"

# stat stub: returns a mtime driven by FAKE_STAT_MTIME env var at runtime
cat > "$FAKE_BIN/stat" <<'STUB'
#!/usr/bin/env bash
# Only intercept stat -f '%m' <path>
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%m" ]; then
  echo "${FAKE_STAT_MTIME:-0}"
else
  command stat "$@"
fi
STUB
chmod +x "$FAKE_BIN/stat"

# du stub: returns a fixed block count
cat > "$FAKE_BIN/du" <<STUB
#!/usr/bin/env bash
# du -sk <path>
echo "1024	\${*: -1}"
STUB
chmod +x "$FAKE_BIN/du"

# ---------------------------------------------------------------------------
# Helper: run disk-janitor in a subshell with the fake environment.
# Usage: _run_dj <mode> [free_pct] [stat_mtime]
# ---------------------------------------------------------------------------
_run_dj() {
  local mode="$1"
  local free_pct="${2:-10}"
  local stat_mtime="${3:-0}"
  (
    export PATH="$FAKE_BIN:$PATH"
    export HOME="$FAKE_HOME"
    export FAKE_DF_FREE_PCT="$free_pct"
    export FAKE_STAT_MTIME="$stat_mtime"
    export CC_DJ_LOG="$SANDBOX/dj.log"
    export CC_DJ_STATE_DIR="$SANDBOX/state"
    export CC_DJ_DISK_MIN_PCT=15
    export CC_DJ_COOLDOWN_SECS=3600
    # Create fixture cache dirs so rm -rf hits the sandbox
    mkdir -p "$FAKE_HOME/Library/Caches/com.spotify.client"
    mkdir -p "$FAKE_HOME/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"
    mkdir -p "$FAKE_HOME/Library/Developer/CoreSimulator/Caches"
    /bin/bash "$ROOT_DIR/shell/disk-janitor.sh" "$mode"
  )
}

# ---------------------------------------------------------------------------
# Reset capture files between test groups
# ---------------------------------------------------------------------------
_reset_captures() {
  truncate -s 0 "$TM_DELETE_CAPTURE" "$OSASCRIPT_CAPTURE" "$DOCKER_CAPTURE" \
                "$GO_CAPTURE" "$YARN_CAPTURE" "$PIP3_CAPTURE" "$BREW_CAPTURE" \
                "$BUN_CAPTURE" "$RM_CAPTURE"
  rm -f "$SANDBOX/state/cooldown-disk" "$SANDBOX/dj.log"
}

# ---------------------------------------------------------------------------
# TEST 1: source safety — --volumes must NOT appear in script source
# ---------------------------------------------------------------------------
printf "\n# Test group 1: source safety\n"

expect_no "--volumes absent from disk-janitor.sh source" \
  grep -q -- '--volumes' "$ROOT_DIR/shell/disk-janitor.sh"

# ---------------------------------------------------------------------------
# TEST 2: --check below threshold → osascript called, NO deletion stubs called
# ---------------------------------------------------------------------------
printf "\n# Test group 2: --check below threshold\n"
_reset_captures

_run_dj --check 10 0   # free=10% < 15%, stat_mtime=0 (cooldown expired)

expect_yes "check below threshold: osascript called" \
  test -s "$OSASCRIPT_CAPTURE"

expect_no "check below threshold: tmutil deletelocalsnapshots NOT called" \
  test -s "$TM_DELETE_CAPTURE"

expect_no "check below threshold: docker NOT called" \
  test -s "$DOCKER_CAPTURE"

expect_no "check below threshold: go NOT called" \
  test -s "$GO_CAPTURE"

expect_no "check below threshold: yarn NOT called" \
  test -s "$YARN_CAPTURE"

expect_no "check below threshold: pip3 NOT called" \
  test -s "$PIP3_CAPTURE"

expect_no "check below threshold: brew NOT called" \
  test -s "$BREW_CAPTURE"

expect_no "check below threshold: bun NOT called" \
  test -s "$BUN_CAPTURE"

# ---------------------------------------------------------------------------
# TEST 3: --check above threshold → silent (no notify, no deletions)
# ---------------------------------------------------------------------------
printf "\n# Test group 3: --check above threshold\n"
_reset_captures

_run_dj --check 80 0   # free=80% >= 15%

expect_no "check above threshold: osascript NOT called" \
  test -s "$OSASCRIPT_CAPTURE"

expect_no "check above threshold: tmutil deletelocalsnapshots NOT called" \
  test -s "$TM_DELETE_CAPTURE"

# ---------------------------------------------------------------------------
# TEST 4: --clean runs all available targets, SKIP logged for missing tool,
#          freed bytes logged
# ---------------------------------------------------------------------------
printf "\n# Test group 4: --clean all targets present\n"
_reset_captures

_run_dj --clean 10 0

expect_yes "clean: go called" \
  test -s "$GO_CAPTURE"

expect_yes "clean: yarn called" \
  test -s "$YARN_CAPTURE"

expect_yes "clean: pip3 called" \
  test -s "$PIP3_CAPTURE"

expect_yes "clean: brew called" \
  test -s "$BREW_CAPTURE"

expect_yes "clean: bun called" \
  test -s "$BUN_CAPTURE"

expect_yes "clean: docker called" \
  test -s "$DOCKER_CAPTURE"

expect_yes "clean: log contains freed= bytes entry" \
  grep -q 'freed=' "$SANDBOX/dj.log"

# Test SKIP for a missing tool: put a 'bun' stub that always exits 127 so
# command -v bun returns false (command -v succeeds only when tool is executable
# and on PATH — use a wrapper that exists but has a name that won't match
# by using a separate bin dir where bun is absent and system PATH follows after).
printf "\n# Test group 4b: --clean SKIP logged for missing bun\n"
_reset_captures

# Build a no-bun bin dir: copy all stubs except bun, then put system bins after
FAKE_BIN_NOBUN="$SANDBOX/bin-nobun"
mkdir -p "$FAKE_BIN_NOBUN"
for f in df tmutil osascript docker go yarn pip3 brew stat du; do
  cp "$FAKE_BIN/$f" "$FAKE_BIN_NOBUN/$f"
done
# bun is intentionally absent from FAKE_BIN_NOBUN
# Use a restricted system PATH that has no bun installation dir
# Bun typically lives in ~/.bun/bin — exclude that by setting an explicit safe PATH
SAFE_SYS_PATH="/bin:/usr/bin:/usr/sbin:/sbin"

(
  export PATH="$FAKE_BIN_NOBUN:$SAFE_SYS_PATH"
  export HOME="$FAKE_HOME"
  export FAKE_DF_FREE_PCT=80       # above threshold so no TM thinning
  export FAKE_STAT_MTIME=0
  export CC_DJ_LOG="$SANDBOX/dj-nobun.log"
  export CC_DJ_STATE_DIR="$SANDBOX/state"
  export CC_DJ_DISK_MIN_PCT=15
  export CC_DJ_COOLDOWN_SECS=3600
  mkdir -p "$FAKE_HOME/Library/Caches/com.spotify.client"
  mkdir -p "$FAKE_HOME/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"
  mkdir -p "$FAKE_HOME/Library/Developer/CoreSimulator/Caches"
  /bin/bash "$ROOT_DIR/shell/disk-janitor.sh" --clean
)

expect_yes "clean: SKIP logged for missing bun" \
  grep -q 'SKIP bun' "$SANDBOX/dj-nobun.log"

# ---------------------------------------------------------------------------
# TEST 5: TM thinning only fires when below threshold AND only passes
#         TimeMachine date tokens (os.update names excluded)
# ---------------------------------------------------------------------------
printf "\n# Test group 5: TM snapshot thinning\n"
_reset_captures

_run_dj --clean 10 0   # free=10% < 15% → should thin

expect_yes "clean: TM snapshot date tokens deleted" \
  grep -q '2026-06-08-040000' "$TM_DELETE_CAPTURE"

expect_yes "clean: second TM snapshot deleted" \
  grep -q '2026-06-09-040000' "$TM_DELETE_CAPTURE"

expect_no "clean: os.update snapshot NOT deleted" \
  grep -q 'os.update' "$TM_DELETE_CAPTURE"

# Above threshold — no TM thinning
_reset_captures
_run_dj --clean 80 0   # free=80% >= 15%

expect_no "clean above threshold: TM snapshot NOT deleted" \
  test -s "$TM_DELETE_CAPTURE"

# ---------------------------------------------------------------------------
# TEST 6: cooldown suppresses repeat --check notification
# ---------------------------------------------------------------------------
printf "\n# Test group 6: cooldown\n"
_reset_captures

# stat_mtime = now - 60 (60 seconds ago) → within 3600s cooldown → suppress.
# The script only reads mtime when the state file EXISTS, so create it first.
mkdir -p "$SANDBOX/state"
touch "$SANDBOX/state/cooldown-disk"
NOW="$(date '+%s')"
RECENT_MTIME=$(( NOW - 60 ))

_run_dj --check 10 "$RECENT_MTIME"

expect_no "check: notification suppressed within cooldown" \
  test -s "$OSASCRIPT_CAPTURE"

# stat_mtime = 0 (epoch) → cooldown expired → notify
_reset_captures
_run_dj --check 10 0

expect_yes "check: notification sent after cooldown expired" \
  test -s "$OSASCRIPT_CAPTURE"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$SANDBOX"

if [ "$failures" -gt 0 ]; then
  printf "\n%s test failure(s)\n" "$failures"
  exit 1
fi

printf "\ndisk-janitor validation passed\n"
