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
# Intercept "df -P" and "df -Pk" — pass through anything else.
#
# `-Pk` is listed because the janitor prices targets in KiB and POSIX `-P` alone is
# 512-byte blocks on macOS. It is also load-bearing for a second reason: the passthrough
# below must never be reached from a shape the janitor actually uses. `command df` skips
# shell functions but not PATH, and this stub *is* the first `df` on PATH, so an
# unintercepted flag re-executes this file and forks until the suite hangs. That is what
# `df -Pk` did before this line existed.
case "${1:-}" in
  -P|-Pk|-Pk*|-kP) intercept=1 ;;
  *) intercept=0 ;;
esac
if [ "$intercept" = "1" ]; then
  FREE="${FAKE_DF_FREE_PCT:-10}"
  USED=$((100 - FREE))
  # Columns: Filesystem 1024-blocks Used Available Use% Mounted
  printf "Filesystem     1024-blocks      Used Available Capacity Mounted on\n"
  printf "/dev/disk1s1   976490576 %d %d   %d%%  /\n" "$((USED * 1000))" "$((FREE * 1000))" "$USED"
else
  # Absolute path, never `command df`: this file is the first df on PATH.
  /bin/df "$@"
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
    # Never the machine's real /private/tmp. These runs exercise the cache targets,
    # and letting them enumerate the host's temp directory made the result depend on
    # whatever else was running - besides being slow and pointing a deletion path at
    # somebody's live scratch space.
    mkdir -p "$SANDBOX/tmp-empty"
    export CC_DJ_TMP_DIRS="$SANDBOX/tmp-empty"
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
  # The janitor appends its known tool directories to PATH so a LaunchAgent resolves the
  # same tools an interactive shell does. That is what defeats simulating an absent tool
  # through PATH alone - the real bun in /opt/homebrew/bin would resolve. Absence has to
  # be simulated at the layer where resolution happens.
  export CC_DJ_TOOL_DIRS=""
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
  mkdir -p "$SANDBOX/tmp-empty"
  export CC_DJ_TMP_DIRS="$SANDBOX/tmp-empty"
  # `|| true`: --clean now exits non-zero when any target failed, and this scenario
  # deliberately removes a tool. A skip is not a failure, but the guard keeps the
  # suite from dying here if that ever changes.
  /bin/bash "$ROOT_DIR/shell/disk-janitor.sh" --clean || true
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
# TEST 8: tool resolution does not depend on the caller's PATH
#
# Red-verified 2026-08-30 against the pre-change script: under launchd's default PATH all
# of go/yarn/brew/bun/docker resolved as absent and their targets were skipped, while all
# five were installed. The weekly clean logged "clean: finished" either way.
#
# The janitor is sourced through a path held in a variable rather than through "$0": its
# entry-point guard compares BASH_SOURCE[0] with $0, so sourcing it as $0 runs the CLI
# and prints usage instead of defining anything.
# ---------------------------------------------------------------------------
printf "\n# Test group 8: tool resolution\n"

LAUNCHD_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
DJ="$ROOT_DIR/shell/disk-janitor.sh"

# A fixture in a directory the script actually searches, rather than whatever the host
# happens to have installed. Conditioning on the ambient PATH proves only that a tool exists
# somewhere - under mise, say - while the assertion clears that PATH and exposes only the
# script's own directories, so the precondition can pass where the assertion cannot.
TOOLDIR="$SANDBOX/tooldir"
mkdir -p "$TOOLDIR"
printf '#!/bin/bash\nexit 0\n' > "$TOOLDIR/pretend-tool"
chmod +x "$TOOLDIR/pretend-tool"

expect_yes "tool resolution: a tool in CC_DJ_TOOL_DIRS resolves under launchd's PATH" \
  env -i HOME="$HOME" PATH="$LAUNCHD_PATH" CC_DJ_TOOL_DIRS="$TOOLDIR" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; command -v pretend-tool >/dev/null 2>&1'

expect_no "tool resolution: a tool in no searched directory stays unresolved" \
  env -i HOME="$HOME" PATH="$LAUNCHD_PATH" CC_DJ_TOOL_DIRS="$SANDBOX/empty" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; command -v pretend-tool >/dev/null 2>&1'

# The real defaults, asserted only for a tool this host really keeps in one of them: the
# point of the change is that the shipped list covers where things are actually installed.
for tool in go docker; do
  # `|| true`: this lookup is optional, and the file runs under `set -e`, so an absent
  # tool would abort the suite here instead of reaching the skip branch below - taking
  # every later test with it, on a host that simply does not have docker.
  loc="$(command -v "$tool" 2>/dev/null || true)"
  case "$loc" in
    /opt/homebrew/bin/*|/usr/local/bin/*|"$HOME"/.local/bin/*)
      expect_yes "tool resolution: $tool resolves under launchd's PATH" \
        env -i HOME="$HOME" PATH="$LAUNCHD_PATH" DJ="$DJ" TOOL="$tool" /bin/bash -c \
          'source "$DJ" >/dev/null 2>&1; command -v "$TOOL" >/dev/null 2>&1' ;;
    *)
      printf "ok - tool resolution: %s is not in a default tool dir here (%s), skipped\n" \
        "$tool" "${loc:-absent}" ;;
  esac
done

# An empty CC_DJ_TOOL_DIRS hands the whole answer back to PATH, which is how a sandbox
# simulates a tool that is genuinely not installed.
expect_no "tool resolution: empty CC_DJ_TOOL_DIRS leaves PATH authoritative" \
  env -i HOME="$HOME" PATH="$LAUNCHD_PATH" CC_DJ_TOOL_DIRS= DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; command -v go >/dev/null 2>&1'

# A caller's own PATH entry keeps priority, so a shimmed tool is never stepped over -
# the appended directories must not be able to reach past a test sandbox's stubs.
SHIM_DIR="$SANDBOX/shim-priority"
mkdir -p "$SHIM_DIR"
printf '#!/bin/bash\necho SHIMMED\n' > "$SHIM_DIR/go"
chmod +x "$SHIM_DIR/go"
expect_yes "tool resolution: caller's PATH entry wins over the appended dirs" \
  env -i HOME="$HOME" PATH="$SHIM_DIR:$LAUNCHD_PATH" DJ="$DJ" SHIM="$SHIM_DIR" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; [ "$(command -v go)" = "$SHIM/go" ]'

# ---------------------------------------------------------------------------
# TEST 9: no prune verb reaches docker, and a skipped run says so
# ---------------------------------------------------------------------------
printf "\n# Test group 9: docker cleanup shape and skip accounting\n"

expect_no "docker: no 'prune' invocation survives outside comments" \
  bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -q "docker.*prune"' _ "$DJ"

expect_no "docker: no volume removal survives outside comments" \
  bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -q "volume rm"' _ "$DJ"

# A directory target reports both numbers: `du` for how large it was, and the volume
# delta for how much came back. They diverge when a process holds a deleted file open,
# and reporting only `du` overstates the saving - the failure this accounting exists to
# prevent. Under the fixed `df` stub the delta is 0, so the `freed=` field must read 0B
# while `size=` still carries the du figure.
expect_yes "directory targets report a du size and a measured delta separately" \
  bash -c '
    line="$(grep "clean: removed .Spotify cache." "$1" | tail -1)"
    [ -n "$line" ] || exit 1
    printf "%s" "$line" | grep -q "size=[0-9]* bytes" || exit 1
    printf "%s" "$line" | grep -q "freed=0B"
  ' _ "$SANDBOX/dj-nobun.log"

expect_yes "skip accounting: a skipped run names the fact on its final line" \
  bash -c 'grep -q "SKIPPED=" "$1" && grep -q "a skipped target cleaned nothing" "$1"' \
    _ "$SANDBOX/dj-nobun.log"

expect_yes "freed bytes: no target reports an unknown" \
  bash -c '! grep -q "freed=?" "$1"' _ "$SANDBOX/dj-nobun.log"

# ---------------------------------------------------------------------------
# TEST 10: anonymous-volume selection
#
# The one behaviour that replaced `docker system prune -af`, so it is the one that has to
# be pinned by name. Verified against the live daemon on 2026-08-30 with a held volume, an
# orphan, and four named pretrieval-* data volumes present; only the orphan was selected.
# Reproduced here with stubs so the suite needs no daemon.
# ---------------------------------------------------------------------------
printf "\n# Test group 10: anonymous volume selection\n"

VOL_BIN="$SANDBOX/bin-vol"
mkdir -p "$VOL_BIN"
A_VOL=$(python3 -c "print('a'*64)")
B_VOL=$(python3 -c "print('b'*64)")
cat > "$VOL_BIN/docker" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "volume ls")  printf '%s\\n%s\\npretrieval-qdrant-data\\nnot-hex-but-64-chars-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' "$A_VOL" "$B_VOL" ;;
  "ps -aq")     echo c0ffee ;;
  "inspect c0ffee") printf '[{"Mounts":[{"Name":"%s"}]}]\\n' "$A_VOL" ;;
  "volume rm")  shift 2; for v in "\$@"; do echo "RM \$v"; done ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$VOL_BIN/docker"

VOL_OUT="$(PATH="$VOL_BIN:$SAFE_SYS_PATH" bash -c '
  source "$1" >/dev/null 2>&1
  _cc_dj_docker_report_dead_anon_volumes
' _ "$ROOT_DIR/shell/disk-janitor.sh")"

expect_no "volumes: nothing is removed, whatever the name looks like" \
  bash -c 'printf "%s" "$1" | grep -q "RM "' _ "$VOL_OUT"

expect_yes "volumes: the unreferenced volume is reported" \
  bash -c 'printf "%s" "$1" | grep -q "unreferenced volumes"' _ "$VOL_OUT"

expect_yes "volumes: a mounted volume is not counted as unreferenced" \
  bash -c 'printf "%s" "$1" | grep -q "^1 unreferenced volumes"' _ "$VOL_OUT"

expect_no "volumes: a named data volume is never selected" \
  bash -c 'printf "%s" "$1" | grep -q "pretrieval-qdrant-data"' _ "$VOL_OUT"

expect_no "volumes: a 64-character name that is not hex is never selected" \
  bash -c 'printf "%s" "$1" | grep -q "not-hex-but-64-chars"' _ "$VOL_OUT"

# The count has to be a count. The list is joined inside python, inside a shell
# single-quoted string, inside a command substitution; an escaped newline survives that
# stack as a literal backslash-n, collapsing the list to one physical line so the count
# read 1 however many volumes there were - wrong exactly when it starts to matter.
MULTI_BIN="$SANDBOX/bin-multivol"
mkdir -p "$MULTI_BIN"
cat > "$MULTI_BIN/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "volume ls") python3 -c "print('a'*64); print('b'*64); print('c'*64)" ;;
  "ps -aq")    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$MULTI_BIN/docker"

MULTI_OUT="$(PATH="$MULTI_BIN:$SAFE_SYS_PATH" bash -c '
  source "$1" >/dev/null 2>&1
  _cc_dj_docker_report_dead_anon_volumes
' _ "$DJ")"

expect_yes "volumes: three unreferenced volumes are counted as three" \
  bash -c 'printf "%s" "$1" | grep -q "^3 unreferenced volumes"' _ "$MULTI_OUT"

# ---------------------------------------------------------------------------
# TEST 11: free-space units, and docker failures reaching the caller
# ---------------------------------------------------------------------------
printf "\n# Test group 11: units and status propagation\n"

# `df -P` alone is 512-byte blocks on macOS. Reading it as KiB reported every saving at
# twice its size - a number confidently wrong by 2x is worse than the "freed=?" it replaced.
# Asserted against the real df rather than the stub, because the stub is what would have to
# agree with the bug for the bug to hide.
expect_yes "units: _cc_dj_free_kb agrees with df -Pk, not df -P" \
  bash -c '
    source "$1" >/dev/null 2>&1
    mine="$(_cc_dj_free_kb)"
    real="$(/bin/df -Pk "${CC_DJ_VOLUME:-/System/Volumes/Data}" | awk "NR==2{print \$4}")"
    [ -n "$mine" ] && [ -n "$real" ] || exit 1
    # Free space moves between the two calls; agreement within 1% is agreement on units,
    # while a 512-vs-1024 mistake is a clean factor of two.
    awk -v a="$mine" -v b="$real" "BEGIN{ d=(a>b?a-b:b-a); exit !(b>0 && d/b < 0.01) }"
  ' _ "$DJ"

# A docker command that fails must not be logged as a target that succeeded: that is the
# exact observability fault this change exists to remove, reintroduced one layer down.
DOCKFAIL="$SANDBOX/bin-dockfail"
mkdir -p "$DOCKFAIL"
cat > "$DOCKFAIL/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "images -f") echo deadbeef ;;
  "rmi "*|"rmi") echo "Error response from daemon: conflict: unable to delete" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$DOCKFAIL/docker"

expect_no "status: a failing docker rmi does not return success" \
  env PATH="$DOCKFAIL:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rmi_dangling >/dev/null 2>&1'

cat > "$DOCKFAIL/docker" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "images -f") echo deadbeef ;;
  "rmi "*|"rmi") echo "Deleted: deadbeef"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
expect_yes "status: a succeeding docker rmi returns success" \
  env PATH="$DOCKFAIL:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rmi_dangling >/dev/null 2>&1'

# ---------------------------------------------------------------------------
# TEST 12: an inventory that failed is not an empty inventory
# ---------------------------------------------------------------------------
printf "\n# Test group 12: inventory status\n"

DEADD="$SANDBOX/bin-deaddaemon"
mkdir -p "$DEADD"
cat > "$DEADD/docker" <<'STUB'
#!/bin/bash
# The daemon answered `info` and then went away: every later command fails silently.
[ "$1" = "info" ] && exit 0
exit 1
STUB
chmod +x "$DEADD/docker"

expect_no "inventory: a failing 'docker images' is not 'no dangling images'" \
  env PATH="$DEADD:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rmi_dangling >/dev/null 2>&1'

expect_no "inventory: a failing 'docker volume ls' is not 'no volumes'" \
  env PATH="$DEADD:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_report_dead_anon_volumes >/dev/null 2>&1'

# ---------------------------------------------------------------------------
# TEST 13: an unreadable container inventory must not authorise removal
#
# The failure mode here is not a missed cleanup. An empty reference set makes every
# anonymous volume look orphaned, so believing a failed `docker ps -aq` or a short
# `docker inspect` deletes volumes that are still mounted.
# ---------------------------------------------------------------------------
printf "\n# Test group 13: container inventory failures\n"

ANON_A=$(python3 -c "print('a'*64)")

make_inv_stub() {  # $1 = dir, $2 = which producer fails
  mkdir -p "$1"
  cat > "$1/docker" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "volume ls")  echo "$ANON_A" ;;
  "ps -aq")     [ "$2" = "ps" ] && exit 1; echo c0ffee ;;
  "inspect c0ffee") [ "$2" = "inspect" ] && exit 1; echo '[{"Mounts":[]}]' ;;
  "volume rm")  shift 2; for v in "\$@"; do echo "RM \$v"; done ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$1/docker"
}

make_inv_stub "$SANDBOX/bin-nops" ps
expect_no "inventory: a failing 'docker ps -aq' does not authorise removal" \
  env PATH="$SANDBOX/bin-nops:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_report_dead_anon_volumes >/dev/null 2>&1'

expect_no "inventory: nothing is reported when 'docker ps -aq' fails" \
  env PATH="$SANDBOX/bin-nops:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" 2>/dev/null; _cc_dj_docker_report_dead_anon_volumes 2>/dev/null | grep -q "unreferenced volumes"'

make_inv_stub "$SANDBOX/bin-noinspect" inspect
expect_no "inventory: a failing 'docker inspect' does not authorise removal" \
  env PATH="$SANDBOX/bin-noinspect:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_report_dead_anon_volumes >/dev/null 2>&1'

# A short inspect result describes fewer containers than were listed, so the reference
# set is incomplete and cannot authorise anything either.
SHORTDIR="$SANDBOX/bin-shortinspect"
mkdir -p "$SHORTDIR"
cat > "$SHORTDIR/docker" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "volume ls") echo "$ANON_A" ;;
  "ps -aq")    printf 'c0ffee\ndecade\n' ;;
  "inspect"*)  echo '[{"Mounts":[]}]' ;;
  "volume rm") shift 2; for v in "\$@"; do echo "RM \$v"; done ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SHORTDIR/docker"
expect_no "inventory: a short 'docker inspect' does not authorise removal" \
  env PATH="$SHORTDIR:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_report_dead_anon_volumes >/dev/null 2>&1'

# ---------------------------------------------------------------------------
# TEST 14: the default tool list covers where the targets actually install,
#          and the per-run counters are per run
# ---------------------------------------------------------------------------
printf "\n# Test group 14: tool-dir coverage and counter scope\n"

# Bun's own installer and the official Go macOS package land nowhere else, so a default
# list that omits them reproduces the bug this change exists to fix.
for d in "\$HOME/.bun/bin" "/usr/local/go/bin"; do
  expect_yes "tool dirs: default list covers $d" \
    bash -c 'grep -q -- "$2" "$1"' _ "$DJ" "$d"
done

# Counters are reset per run, not per source. The file supports being sourced, and a
# second _cc_dj_clean in the same shell reporting cumulative totals would make the
# accounting added to expose a skipped run wrong in exactly the same way.
COUNT_LOG="$SANDBOX/dj-twice.log"
env PATH="$FAKE_BIN_NOBUN:$SAFE_SYS_PATH" HOME="$FAKE_HOME" \
    CC_DJ_TOOL_DIRS="" FAKE_DF_FREE_PCT=80 FAKE_STAT_MTIME=0 \
    CC_DJ_LOG="$COUNT_LOG" CC_DJ_STATE_DIR="$SANDBOX/state" \
    CC_DJ_DISK_MIN_PCT=15 CC_DJ_COOLDOWN_SECS=3600 DJ="$DJ" \
    /bin/bash -c 'source "$DJ" >/dev/null 2>&1; _cc_dj_clean; _cc_dj_clean' >/dev/null 2>&1

# The two runs are not expected to be identical - the first one deletes the cache
# directories the second then reports as missing - so the invariant is the total number of
# targets attempted, which is fixed. Counters that accumulate across runs show it doubling.
expect_yes "counters: per-run totals do not accumulate across two runs in one shell" \
  bash -c '
    [ "$(grep -c "clean: finished" "$1")" = "2" ] || exit 1
    tot() {
      grep "clean: finished" "$1" | sed -n "$2p" \
        | grep -oE "(ran|SKIPPED|skipped)=[0-9]+" \
        | grep -oE "[0-9]+" | awk "{t+=\$1} END{print t+0}"
    }
    a="$(tot "$1" 1)"; b="$(tot "$1" 2)"
    [ "$a" -gt 0 ] && [ "$a" = "$b" ]
  ' _ "$COUNT_LOG"

# ---------------------------------------------------------------------------
# TEST 15: a missing python3 is a skip, not a silent failed target
#
# macOS does not ship python3 without Command Line Tools. Left to fail inside the target,
# it exits 127 and `_cc_dj_clean_target` counts a failed command as one that ran - so the
# summary reports `skipped=0` for a run whose volume inventory never happened.
# ---------------------------------------------------------------------------
printf "\n# Test group 15: declared dependencies\n"

NOPY="$SANDBOX/bin-nopython"
mkdir -p "$NOPY"
# docker present and healthy; python3 deliberately absent from every searched directory.
cat > "$NOPY/docker" <<'STUB'
#!/bin/bash
[ "$1" = "info" ] && exit 0
case "$1 $2" in
  "images -f") ;;
  "volume ls") ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$NOPY/docker"
# A PATH that genuinely lacks python3 while keeping everything else the janitor needs:
# a symlink farm over the system directories, minus python*. Shimming python3 to fail
# would not do - `command -v` would still find it, and the guard under test is exactly
# that lookup.
for d in /bin /usr/bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    case "$b" in python*) continue ;; esac
    [ -e "$NOPY/$b" ] || ln -s "$f" "$NOPY/$b" 2>/dev/null || true
  done
done
# `rm -f` before each copy, and never `cp -f` alone. The destination is already a symlink
# into a system directory from the loop above, and `cp -f` opens through the link rather
# than replacing it - it writes the stub into `/usr/bin/df`. Verified 2026-08-30 against a
# temporary target: `cp -f stub farm/df` replaced the contents of the real file, while
# `rm -f farm/df` first left it untouched. On a host where the runner can write to
# `/usr/bin`, which root-owned CI containers routinely can, this test would corrupt the
# machine it runs on.
for tool in df tmutil osascript stat du; do
  rm -f "$NOPY/$tool"
  cp "$FAKE_BIN/$tool" "$NOPY/$tool" 2>/dev/null || true
done

# A guard against reintroducing that by reordering: every stubbed entry must be a real
# file in the sandbox, not a link pointing out of it.
expect_yes "dependencies: stubbed tools are files in the sandbox, not links out of it" \
  bash -c '
    for t in df tmutil osascript stat du; do
      [ -e "$1/$t" ] || continue
      [ -L "$1/$t" ] && exit 1
    done
    exit 0
  ' _ "$NOPY"

expect_no "dependencies: the probe PATH really has no python3" \
  env PATH="$NOPY" /bin/bash -c 'command -v python3 >/dev/null 2>&1' 

NOPY_LOG="$SANDBOX/dj-nopython.log"
mkdir -p "$SANDBOX/tmp-empty"
# A sandbox temp root, and `|| true`. This run strips PATH to prove python3 is
# absent, which also takes lsof with it - so the stale-temp scan correctly reports
# itself blind and --clean now exits non-zero. That is the behaviour under test
# elsewhere; here it must not take the suite down with it.
env PATH="$NOPY" HOME="$FAKE_HOME" CC_DJ_TOOL_DIRS="" \
    FAKE_DF_FREE_PCT=80 FAKE_STAT_MTIME=0 \
    CC_DJ_LOG="$NOPY_LOG" CC_DJ_STATE_DIR="$SANDBOX/state" \
    CC_DJ_TMP_DIRS="$SANDBOX/tmp-empty" \
    CC_DJ_DISK_MIN_PCT=15 CC_DJ_COOLDOWN_SECS=3600 \
    /bin/bash "$DJ" --clean >/dev/null 2>&1 || true

expect_yes "dependencies: a missing python3 is logged as a SKIP" \
  bash -c 'grep -q "SKIP docker unreferenced volumes report (python3 not found)" "$1"' _ "$NOPY_LOG"

expect_no "dependencies: a run missing python3 does not report skipped=0" \
  bash -c 'grep "clean: finished" "$1" | grep -q "skipped=0"' _ "$NOPY_LOG"

# ---------------------------------------------------------------------------
# Stale temp checkouts: every gate is a reason to SKIP
# ---------------------------------------------------------------------------
#
# This is the only target here whose contents are somebody's abandoned work rather
# than a rebuildable cache, so being wrong deletes work. Measured 2026-08-31 on one
# host: twelve scratch checkouts, 484 MB to 1.3 GB, 5.7 GB in total, and no janitor
# looked at /private/tmp at all.

# ── the installer must not write through a symlinked hook destination ────────
#
# `cp src dst` follows a symlinked dst and rewrites the file it points at. This path
# is a symlink into another repository on at least one machine, and installing here
# silently modified that checkout - twice, the second time after the drift it caused
# had already been found.
# `launchctl` is stubbed, not just `HOME`. Overriding HOME alone does not isolate
# the launchd domain: `bootout`/`bootstrap` are addressed as `gui/<uid>/<label>`, so
# this test tore down the developer's REAL agents and replaced them with ones
# pointing into a temporary home - which the sandbox then deleted. Measured on the
# reporting host: after two runs, `gui/501/com.cc-reaper.disk-check` was loaded
# against `/var/folders/.../inst-home/.cc-reaper/disk-janitor.sh`, a path that no
# longer existed. The test that proves an installer does not damage things outside
# its target must not damage things outside its target.
INST_HOME="$SANDBOX/inst-home"
mkdir -p "$INST_HOME/.claude/hooks"
LC_STUB="$SANDBOX/stub-launchctl"
mkdir -p "$LC_STUB"
printf '#!/bin/sh\nexit 0\n' > "$LC_STUB/launchctl"
chmod +x "$LC_STUB/launchctl"

REAL_HOOK="$SANDBOX/other-repo-hook.sh"
printf '#!/bin/sh\n# the other repository owns this\n' > "$REAL_HOOK"
ln -sf "$REAL_HOOK" "$INST_HOME/.claude/hooks/stop-cleanup-orphans.sh"
BEFORE_SUM="$(shasum "$REAL_HOOK" | cut -d" " -f1)"
INST_OUT="$(printf 'b\n' | env PATH="$LC_STUB:$PATH" HOME="$INST_HOME" \
  bash "$ROOT_DIR/install.sh" 2>&1 || true)"
AFTER_SUM="$(shasum "$REAL_HOOK" | cut -d" " -f1)"

expect_yes "install does not write through a symlinked stop-hook path" \
  bash -c '[ "$1" = "$2" ]' _ "$BEFORE_SUM" "$AFTER_SUM"

expect_yes "install says why it left the symlink alone" \
  bash -c 'printf "%s\n" "$1" | grep -q "is a symlink to"' _ "$INST_OUT"

# The stub is the point, so prove it was actually the thing standing in.
expect_yes "the installer under test really used the stubbed launchctl" \
  bash -c 'command -v launchctl >/dev/null && [ -x "$1/launchctl" ]' _ "$LC_STUB"

printf "\n# Test group: stale temp checkouts\n"

TMPT="$SANDBOX/tmproot"
mkdir -p "$TMPT"
# 2 MB fixtures against a 1 MB floor, not 200 MB against 100. Ten 200 MB fixtures
# wrote about 2 GiB on every run of a suite this repository documents as lightweight,
# on the same developer disks the janitor exists to protect. The gate under test is
# `size >= floor`; the absolute numbers were never part of it.
FIXTURE_KB=2048
mkfile_kb() { dd if=/dev/zero of="$1" bs=1024 count="$2" >/dev/null 2>&1; }
# Age the WHOLE subtree. Ageing only the directory entry is the defect under test:
# a directory's mtime advances only when its direct entries change, so a container
# full of files being written right now still reads as stale.
age_tree() { find "$1" -exec touch -t 202001010000 {} + 2>/dev/null; }

# Big and old throughout: the one thing that should be collected.
mkdir -p "$TMPT/stale-checkout"
mkfile_kb "$TMPT/stale-checkout/blob" "$FIXTURE_KB"
age_tree "$TMPT/stale-checkout"

# Old container, live child. This is `/private/tmp/claude-501` on the reporting
# host: the scratchpad root for every running session, 720 MB, its own mtime moving
# only when a new project appears. Files are written and closed, not held open, so
# the lsof gate does not save it either.
mkdir -p "$TMPT/live-container/session"
mkfile_kb "$TMPT/live-container/session/blob" "$FIXTURE_KB"
touch -t 202001010000 "$TMPT/live-container"

# Old and big, but a linked worktree: git still has a record pointing here.
mkdir -p "$TMPT/linked-worktree"
mkfile_kb "$TMPT/linked-worktree/blob" "$FIXTURE_KB"
echo "gitdir: /somewhere/.git/worktrees/x" > "$TMPT/linked-worktree/.git"
age_tree "$TMPT/linked-worktree"

# Old and big, and a plain clone: `.git` is a DIRECTORY, and its commits may exist
# nowhere else. The gate keyed on `-f` matched only the gitfile above, so the one
# case whose loss is unrecoverable was the one that passed through.
mkdir -p "$TMPT/plain-clone/.git"
mkfile_kb "$TMPT/plain-clone/blob" "$FIXTURE_KB"
age_tree "$TMPT/plain-clone"

# Old but small: below the floor, not worth being wrong about.
mkdir -p "$TMPT/tiny"; mkfile_kb "$TMPT/tiny/blob" 16; age_tree "$TMPT/tiny"   # 16 KB: under the 1 MB floor

# Big but fresh.
mkdir -p "$TMPT/fresh"; mkfile_kb "$TMPT/fresh/blob" "$FIXTURE_KB"

# A glob character in the name. `/private/tmp` is world-writable, so nothing
# constrains these. Under the old `grep "^$path\(/\|$\)"` this became `fo` plus
# zero-or-more `o`, matched nothing, and a HELD directory was offered for deletion.
mkdir -p "$TMPT/glob*dir"; mkfile_kb "$TMPT/glob*dir/blob" "$FIXTURE_KB"; age_tree "$TMPT/glob*dir"

enumerate() {
  bash -c 'source "$1" >/dev/null 2>&1
           CC_DJ_TMP_DIRS="$2" CC_DJ_TMP_AGE_DAYS=3 CC_DJ_TMP_MIN_MB=1 _cc_dj_stale_tmp_dirs' \
    _ "$ROOT_DIR/shell/disk-janitor.sh" "$TMPT" 2>/dev/null
}
# Captured, then matched - never `enumerate | grep -q`. `grep -q` exits on its first
# match and closes the pipe, the writer takes SIGPIPE, and under this file's
# `set -o pipefail` the pipeline reports 141. Measured: every negative assertion in
# this block was passing because of the signal rather than because the path was
# absent, while every positive one failed with the enumerator emitting exactly what
# it should. The file's own `file_has` helper carries the same warning.
collects() {
  local out
  # `tr` because the enumerator's contract is NUL-delimited: a path may contain a
  # newline, which is the whole point. These fixtures are named tamely, so
  # translating for a substring test is fine - the newline case has its own,
  # NUL-aware assertion below.
  out="$(enumerate | tr '\0' '\n')"
  printf '%s\n' "$out" | grep -qF -- "$1"
}

expect_yes "a large stale checkout is collected"                collects "stale-checkout"

# The same root, spelled with a trailing slash. `find` emits `<root>/name`, so an
# unnormalised `<root>/` made the direct-child pattern `<root>//*` and every
# candidate was skipped without a word.
collects_with_trailing_slash() {
  local out
  out="$(bash -c 'source "$1" >/dev/null 2>&1
    CC_DJ_TMP_DIRS="$2" CC_DJ_TMP_AGE_DAYS=3 CC_DJ_TMP_MIN_MB=1 _cc_dj_stale_tmp_dirs' \
    _ "$ROOT_DIR/shell/disk-janitor.sh" "$TMPT/" 2>/dev/null | tr '\0' '\n')"
  printf '%s\n' "$out" | grep -qF -- "stale-checkout"
}
expect_yes "a root spelled with a trailing slash still finds its children" \
  collects_with_trailing_slash
expect_no  "an old container with a live child is NOT collected" collects "live-container"
expect_no  "a registered linked worktree is never collected"    collects "linked-worktree"
expect_no  "a plain clone is never collected"                   collects "plain-clone"
expect_no  "a directory under the size floor is not collected"  collects "/tiny"
expect_no  "a freshly touched directory is not collected"       collects "/fresh"

# ── the enumerator's stdout is a deletion list, so nothing else may go there ──
# In this shell, not `bash -c`: a fresh shell has never seen `enumerate`, so the
# loop read nothing and the assertion passed on an empty list.
check_only_dirs() {
  local l tmpf
  tmpf="$(mktemp)" || return 1
  enumerate > "$tmpf"
  while IFS= read -r -d '' l; do
    [ -n "$l" ] || continue
    [ -d "$l" ] || { rm -f "$tmpf"; return 1; }
  done < "$tmpf"
  rm -f "$tmpf"
}
expect_yes "every emitted line is an existing directory" check_only_dirs

# ── a root that cannot be used must say so, and collect nothing ──────────────
#
# Two traps this block already fell into, both of which made every assertion here
# fail for reasons unrelated to the code under test:
#
#   - `bash -c '<script>' "$path"` puts `$path` in $0, so `source "$0"` makes the
#     sourced file see BASH_SOURCE[0] == $0, conclude it was executed rather than
#     sourced, and run its own entry point instead of defining functions. `_` goes
#     in $0 and the real path in $1.
#   - `expect_yes ... bash -c '<uses a helper>'` runs a fresh shell that has never
#     seen the helper. Assertions are plain functions, invoked directly.
dj_run() {   # <extra-PATH|""> <root> <out|err>
  local extra="$1" root="$2" stream="$3"
  if [ "$stream" = err ]; then
    PATH="${extra:+$extra:}$PATH" bash -c 'source "$1" >/dev/null 2>&1
      CC_DJ_TMP_DIRS="$2" CC_DJ_TMP_AGE_DAYS=3 CC_DJ_TMP_MIN_MB=1 _cc_dj_stale_tmp_dirs' \
      _ "$ROOT_DIR/shell/disk-janitor.sh" "$root" 2>&1 >/dev/null
  else
    PATH="${extra:+$extra:}$PATH" bash -c 'source "$1" >/dev/null 2>&1
      CC_DJ_TMP_DIRS="$2" CC_DJ_TMP_AGE_DAYS=3 CC_DJ_TMP_MIN_MB=1 _cc_dj_stale_tmp_dirs' \
      _ "$ROOT_DIR/shell/disk-janitor.sh" "$root" 2>/dev/null
  fi
}

# ── a root that cannot be used must say so, and collect nothing ──────────────
unusable_root_is_named() { local o; o="$(dj_run "" "$SANDBOX/no-such-root" err)"; printf '%s\n' "$o" | grep -q "unusable"; }
expect_yes "an unusable root is named on stderr, not passed over in silence" \
  unusable_root_is_named

# ── a broken lsof must never read as "nothing is held" ───────────────────────
#
# This is what let the dead guard ship green: with a working lsof both branches
# behave identically, so only a stubbed failure can tell them apart.
LSOF_STUB="$SANDBOX/stub-lsof"
mkdir -p "$LSOF_STUB"
printf '#!/bin/sh\nexit 127\n' > "$LSOF_STUB/lsof"
chmod +x "$LSOF_STUB/lsof"

broken_lsof_collects_something() { local o; o="$(dj_run "$LSOF_STUB" "$TMPT" out | tr '\0' '\n')"; [ -n "$o" ]; }
broken_lsof_explains() { local o; o="$(dj_run "$LSOF_STUB" "$TMPT" err)"; printf '%s\n' "$o" | grep -q "lsof cannot report"; }
broken_lsof_collects_something_with_real_lsof() { local o; o="$(dj_run "" "$TMPT" out | tr '\0' '\n')"; [ -n "$o" ]; }

# ── a find that cannot answer must keep, not delete ──────────────────────────
#
# The staleness gate used `-newermt "-N days"`, a GNU extension. This host's `find`
# is bfs, which rejects it: the gate errored, emitted nothing, and empty read as
# "nothing recent here" - the answer that authorises deletion. Only the lsof gate
# behind it kept 720 MB of live session scratchpads. A stub that fails every
# invocation is the only way to tell a working probe from a silent one.
FIND_STUB="$SANDBOX/stub-find"
mkdir -p "$FIND_STUB"
printf '#!/bin/sh\necho "find: unrecognised primary" >&2\nexit 1\n' > "$FIND_STUB/find"
chmod +x "$FIND_STUB/find"

broken_find_collects_something() { local o; o="$(dj_run "$FIND_STUB" "$TMPT" out | tr '\0' '\n')"; [ -n "$o" ]; }
broken_find_explains()           { local o; o="$(dj_run "$FIND_STUB" "$TMPT" err)"; printf '%s\n' "$o" | grep -q "could not"; }

# ── git repositories, however they are shaped or wherever they sit ───────────
mkdir -p "$TMPT/nested-repo/inner/.git"
mkfile_kb "$TMPT/nested-repo/blob" "$FIXTURE_KB"
age_tree "$TMPT/nested-repo"

mkdir -p "$TMPT/bare-repo/objects" "$TMPT/bare-repo/refs"
: > "$TMPT/bare-repo/HEAD"
mkfile_kb "$TMPT/bare-repo/blob" "$FIXTURE_KB"
age_tree "$TMPT/bare-repo"

expect_no "a repository nested inside a candidate protects it" collects "nested-repo"
expect_no "a bare repository is recognised without a .git"     collects "bare-repo"

# A directory that merely holds a file called HEAD is not a bare repository.
mkdir -p "$TMPT/not-bare"; : > "$TMPT/not-bare/HEAD"
mkfile_kb "$TMPT/not-bare/blob" "$FIXTURE_KB"; age_tree "$TMPT/not-bare"
expect_yes "a stray HEAD file does not make a directory a repository" collects "not-bare"

# A bare repository BELOW the top level: no `.git` for the name search to find, and
# `_cc_dj_looks_bare "$d"` only ever looked at the candidate itself.
mkdir -p "$TMPT/nested-bare/session/repo.git/objects" "$TMPT/nested-bare/session/repo.git/refs"
: > "$TMPT/nested-bare/session/repo.git/HEAD"
mkfile_kb "$TMPT/nested-bare/blob" "$FIXTURE_KB"
age_tree "$TMPT/nested-bare"
expect_no "a bare repository nested inside a candidate protects it" collects "nested-bare"

# A nested bare repository NOT named `*.git`. `git init --bare repo` produces an
# ordinary `repo/`, which a name filter walks straight past.
mkdir -p "$TMPT/nested-bare-plain/session/repo/objects" "$TMPT/nested-bare-plain/session/repo/refs"
: > "$TMPT/nested-bare-plain/session/repo/HEAD"
mkfile_kb "$TMPT/nested-bare-plain/blob" "$FIXTURE_KB"
age_tree "$TMPT/nested-bare-plain"
expect_no "a nested bare repo without a .git suffix protects it" collects "nested-bare-plain"

# A held directory whose name lsof cannot represent. macOS lsof ESCAPES a newline
# rather than emitting it, so the reported path never equals the real one and the
# literal comparison reads "nothing holds this" - which, with deletion enabled, is
# the answer that removes a tree somebody has open.
NLHELD="$TMPT/$(printf 'held\nname')"
mkdir -p "$NLHELD"
mkfile_kb "$NLHELD/blob" "$FIXTURE_KB"
age_tree "$NLHELD"
expect_no "a name lsof cannot represent is never collected" collects "held"

# A function, not `bash -c`: a fresh shell has never seen `dj_run`, so the assertion
# would pass or fail on the helper being missing rather than on the message. This
# file has now made that mistake twice.
says_why_lsof_kept_it() {
  local o; o="$(dj_run "" "$TMPT" err)"
  printf '%s\n' "$o" | grep -q "cannot be matched against lsof"
}
expect_yes "and it says why it kept it" says_why_lsof_kept_it

# A newline in a directory name. `/private/tmp` is world-writable, and a
# line-delimited listing split this into two candidates - the second of them the
# bare relative path `Documents`.
NL_DIR="$TMPT/$(printf 'weird\nDocuments')"
mkdir -p "$NL_DIR"
mkfile_kb "$NL_DIR/blob" "$FIXTURE_KB"
age_tree "$NL_DIR"
only_absolute_children() {
  local l tmpf
  tmpf="$(mktemp)" || return 1
  enumerate > "$tmpf"
  while IFS= read -r -d '' l; do
    [ -n "$l" ] || continue
    case "$l" in "$TMPT"/*) ;; *) rm -f "$tmpf"; return 1 ;; esac
  done < "$tmpf"
  rm -f "$tmpf"
}
expect_yes "a newline in a name cannot produce a candidate outside the root" \
  only_absolute_children

# The two blind-clean assertions that stood here went with the deletion path they
# guarded: `_cc_dj_clean_stale_tmp_dirs` no longer exists, and `--check` reports
# rather than returning a status for anyone to act on. The enumerator gates they
# exercised are still covered above, from the reporting side.


expect_no  "a find that fails yields no deletion candidates" broken_find_collects_something
expect_yes "a find that fails says why it kept them"         broken_find_explains

expect_no  "a broken lsof does not yield deletion candidates" broken_lsof_collects_something
expect_yes "a broken lsof says why it collected nothing"      broken_lsof_explains

# Calibration: the stub must be what changes the answer, not something else.
expect_yes "the same root DOES yield candidates with a working lsof" \
  broken_lsof_collects_something_with_real_lsof
exec 9<"$TMPT/stale-checkout/blob"
expect_no "a directory a live process holds open is not collected" collects "stale-checkout"
exec 9<&-

# A held directory whose name contains a glob character. The regex form matched
# nothing here and emitted it for deletion; a literal prefix comparison does not.
exec 8<"$TMPT/glob*dir/blob"
expect_no "a held directory with a glob character in its name is not collected" \
  collects "glob*dir"
exec 8<&-
expect_yes "that same directory IS collected once nothing holds it" \
  collects "glob*dir"


# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$SANDBOX"

if [ "$failures" -gt 0 ]; then
  printf "\n%s test failure(s)\n" "$failures"
  exit 1
fi

printf "\ndisk-janitor validation passed\n"
