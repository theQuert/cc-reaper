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
  loc="$(command -v "$tool" 2>/dev/null)"
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
  _cc_dj_docker_rm_dead_anon_volumes
' _ "$ROOT_DIR/shell/disk-janitor.sh")"

expect_yes "volumes: the unreferenced anonymous volume is removed" \
  bash -c 'printf "%s" "$1" | grep -q "RM $2"' _ "$VOL_OUT" "$B_VOL"

expect_no "volumes: a volume a container still mounts is left alone" \
  bash -c 'printf "%s" "$1" | grep -q "RM $2"' _ "$VOL_OUT" "$A_VOL"

expect_no "volumes: a named data volume is never selected" \
  bash -c 'printf "%s" "$1" | grep -q "pretrieval-qdrant-data"' _ "$VOL_OUT"

expect_no "volumes: a 64-character name that is not hex is never selected" \
  bash -c 'printf "%s" "$1" | grep -q "not-hex-but-64-chars"' _ "$VOL_OUT"

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
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rm_dead_anon_volumes >/dev/null 2>&1'

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
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rm_dead_anon_volumes >/dev/null 2>&1'

expect_no "inventory: nothing is removed when 'docker ps -aq' fails" \
  env PATH="$SANDBOX/bin-nops:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" 2>/dev/null; _cc_dj_docker_rm_dead_anon_volumes 2>/dev/null | grep -q "^RM "'

make_inv_stub "$SANDBOX/bin-noinspect" inspect
expect_no "inventory: a failing 'docker inspect' does not authorise removal" \
  env PATH="$SANDBOX/bin-noinspect:$SAFE_SYS_PATH" DJ="$DJ" /bin/bash -c \
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rm_dead_anon_volumes >/dev/null 2>&1'

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
    'source "$DJ" >/dev/null 2>&1; _cc_dj_docker_rm_dead_anon_volumes >/dev/null 2>&1'

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
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$SANDBOX"

if [ "$failures" -gt 0 ]; then
  printf "\n%s test failure(s)\n" "$failures"
  exit 1
fi

printf "\ndisk-janitor validation passed\n"
