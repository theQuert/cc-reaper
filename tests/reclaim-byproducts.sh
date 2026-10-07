#!/usr/bin/env bash
# Calibration for reclaim-byproducts.sh.
#
# Every case below is paired with a mutation that breaks exactly the rule it is meant to
# exercise. A case that stays green under its own mutation was decided by some other
# guard, and proves nothing about the one it names - the shape this repository has been
# caught by more than once.
#
# The case that matters most is `named_volume_is_never_reaped`. Measured 2026-09-11 at
# 03:0x on the real daemon, `docker volume ls -f dangling=true` listed stima-ci-work-1,
# -2 and -3: three live CI slots between jobs, whose containers run-loop.sh removes at
# the top of each loop. Anything keyed on that filter deletes the machine's own CI state.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Overridable so a rule can be sed'd out of a COPY and the whole suite run against it,
# which is how every case below is shown to be load-bearing rather than decorative.
SCRIPT="${BYPRODUCT_SCRIPT:-$REPO_ROOT/shell/reclaim-byproducts.sh}"
FAILURES=0; PASSED=0
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok: $1"; PASSED=$((PASSED + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-byproducts.XXXXXX")" || exit 1
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

HEX_FREE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEX_REFD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEX_YOUNG=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
HEX_NODATE=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
# Six hours old: the age an --ephemeral CI runner's volume reaches by lunchtime. It sits
# between the two knobs on purpose - too old to be a container being created right now,
# far too young for the 24h a scratchpad needs - so which knob decides is visible.
HEX_MID=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
OLD_TS="$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '40 days ago' +%Y%m%d%H%M)"
THREE_H_AGO="$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)"

# ---------------------------------------------------------------- fixtures

build_fixture() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root/bin" "$root/scratch/proj" "$root/archive"
  mkdir -p "$root/home/.claude/logs" "$root/home/Library/LaunchAgents"

  # Scratchpads. The three idle ones differ only in what the liveness gate says.
  mkdir -p "$root/scratch/proj/11111111-1111-1111-1111-111111111111"   # free
  mkdir -p "$root/scratch/proj/22222222-2222-2222-2222-222222222222"   # in use
  mkdir -p "$root/scratch/proj/33333333-3333-3333-3333-333333333333"   # unknown
  mkdir -p "$root/scratch/proj/44444444-4444-4444-4444-444444444444"   # recent
  mkdir -p "$root/scratch/proj/not-a-session"
  local old="$OLD_TS"
  local d
  for d in 1 2 3; do
    touch -t "$old" "$root/scratch/proj/${d}${d}${d}${d}${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}"
  done
  touch -t "$old" "$root/scratch/proj/not-a-session"
  # The recent one carries a file touched now; everything else is 40 days old.
  touch "$root/scratch/proj/44444444-4444-4444-4444-444444444444/just-written"

  # Archives.
  mkdir -p "$root/archive/20200101" "$root/archive/$(date +%Y%m%d)" "$root/archive/notadate"
  touch -t "$old" "$root/archive/20200101"

  # path-in-use stub: exit code by session id.
  cat > "$root/bin/path-in-use.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  *11111111-*) echo "free      $1"; exit 0 ;;
  *22222222-*) echo "IN USE    $1"; echo "  a live process has it as its working directory"; exit 1 ;;
  *33333333-*) echo "UNKNOWN   $1"; echo "  the open-file scan could not complete"; exit 2 ;;
esac
echo "free      $1"; exit 0
STUB
  chmod +x "$root/bin/path-in-use.sh"

  # Caches. `codex-runtimes` is supplied explicitly below as a fixture for a machine
  # owner that has proved it dead; the other four are the ones it refuses by name,
  # created as real directories under the fixture's HOME so that "it was refused"
  # and "it is still there" are both askable.
  mkdir -p "$root/home/.cache/codex-runtimes" "$root/home/.cache/huggingface/hub" \
           "$root/home/.cache/qmd" "$root/home/Library/Caches/CloudKit" \
           "$root/home/Library/Caches/go-build" \
           "$root/home/.cache/qm" "$root/home/.cache/qmd-old"
  # Two names that merely SHARE a prefix with the protected `.cache/qmd`, one from each
  # side: `qm` is a prefix OF it, `qmd-old` has it as a prefix. Both are real dead paths
  # and must still be reaped. They are the only probes on this list that can tell a
  # path comparison from a bare startswith - `.cacheXYZ` cannot, because `$HOME/.cache`
  # is itself not protected, only two of its children are.
  touch "$root/home/.cache/qm/leftover" "$root/home/.cache/qmd-old/leftover" \
        "$root/home/.cache/huggingface/hub/blob"
  touch "$root/home/.cache/codex-runtimes/runtime.tar" "$root/home/.cache/huggingface/model.bin" \
        "$root/home/.cache/qmd/index.sqlite" "$root/home/Library/Caches/CloudKit/db" \
        "$root/home/Library/Caches/go-build/entry"
  # uv and pip stand in for the two tools whose own subcommands decide what is dead. They
  # record the call so a case can tell "the reaper ran it" from "the reaper skipped it",
  # and they never touch the fixture - what those tools do is their business, not this
  # suite's, and running the real ones would empty the user's caches.
  local t
  for t in uv pip; do
    cat > "$root/bin/$t" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$root/$t-calls"
exit 0
STUB
    chmod +x "$root/bin/$t"
  done

  # Go cache: two entries 40 days old, one written now. The top-level files and a fuzz
  # corpus are as old, and are not entries: Go's own trim never takes them.
  mkdir -p "$root/gocache/aa" "$root/gocache/bb" "$root/gocache/fuzz/pkg"
  touch -t "$old" "$root/gocache/aa/old-one-d" "$root/gocache/bb/old-two-d"
  touch "$root/gocache/aa/fresh-d"
  touch -t "$old" "$root/gocache/README" "$root/gocache/trim.txt" "$root/gocache/testexpire.txt" \
    "$root/gocache/fuzz/pkg/corpus-d"

  # docker stub.
  cat > "$root/bin/docker" <<STUB
#!/usr/bin/env bash
NOW_OLD="\$(date -v-40d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '40 days ago' +%Y-%m-%dT%H:%M:%S)+08:00"
NOW_NEW="\$(date +%Y-%m-%dT%H:%M:%S)+08:00"
NOW_MID="\$(date -v-6H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '6 hours ago' +%Y-%m-%dT%H:%M:%S)+08:00"
case "\$1 \$2" in
  "info ") exit 0 ;;
  "ps -aq") echo cont1; exit 0 ;;
  "ps -a") printf '%s\n' "in-use-image:v1" "apertis-prepared:inuse"; exit 0 ;;
  "inspect cont1") printf '%s\n' "$HEX_REFD"; exit 0 ;;
  "volume ls") printf '%s\n' "stima-ci-work-1" "$HEX_FREE" "$HEX_REFD" "$HEX_YOUNG" "$HEX_MID" "$HEX_NODATE"; exit 0 ;;
  "images -f") printf '%s\n' img1; exit 0 ;;
  "images --format") printf '%s\n' "apertis-prepared:deadbeef" "apertis-prepared:young" "apertis-prepared:inuse" "postgres:17" "locally-built:v1" "pulled-but-young:v1" "in-use-image:v1"; exit 0 ;;
esac
if [ "\$1 \$2" = "images -q" ]; then printf 'id-%s\n' "\$3"; exit 0; fi
if [ "\$1 \$2" = "image inspect" ]; then
  case "\$5" in
    *Created*) case "\$3" in
        pulled-but-young:v1|apertis-prepared:young) printf '%s' "\$NOW_NEW" ;;
        *) printf '%s' "\$NOW_OLD" ;;
      esac ;;
    *RepoDigests*) case "\$3" in
        locally-built:v1|apertis-prepared:*) printf '0' ;;
        *) printf '1' ;;
      esac ;;
  esac
  exit 0
fi
if [ "\$1 \$2" = "volume inspect" ]; then
  case "\$3" in
    "$HEX_YOUNG") printf '%s' "\$NOW_NEW" ;;
    "$HEX_MID") printf '%s' "\$NOW_MID" ;;
    "$HEX_NODATE") printf '' ;;
    *) printf '%s' "\$NOW_OLD" ;;
  esac
  exit 0
fi
exit 0
STUB
  chmod +x "$root/bin/docker"
}

# One environment for every invocation. HOME is redirected into the fixture and so is
# launchctl: no case can reach the user's LaunchAgents, logs or stamp even by mistake.
# Each seam is a *_OVERRIDE shell variable read here, so a case bends exactly one knob.
_run() {
  local root="$1" script="$2"; shift 2
  HOME="$root/home" \
  BYPRODUCT_LAUNCHCTL="$root/bin/launchctl" \
  BYPRODUCT_LAUNCHD_PROBE_SECONDS="${PROBE_SECONDS_OVERRIDE:-5}" \
  BYPRODUCT_SCRATCH_ROOT="$root/scratch" \
  BYPRODUCT_ARCHIVE_ROOT="$root/archive" \
  BYPRODUCT_DOCKER_BIN="$root/bin/docker" \
  BYPRODUCT_GO_CACHE_DIR="$root/gocache" \
  BYPRODUCT_GO_CACHE_TRIM_DAYS=3 \
  BYPRODUCT_GO_CACHE_MAX_GB="${GO_MAX_OVERRIDE:-99999}" \
  PATH="${PATH_PREFIX_OVERRIDE:+$PATH_PREFIX_OVERRIDE:}$PATH" \
  BYPRODUCT_GO_BUSY="${GO_BUSY_OVERRIDE:-0}" \
  BYPRODUCT_FREE_GB="${FREE_GB_OVERRIDE:-9999}" \
  PATH_IN_USE_BIN="$root/bin/path-in-use.sh" \
  BYPRODUCT_IDLE_HOURS=24 \
  BYPRODUCT_DOCKER_VOLUME_AGE_HOURS="${VOLUME_AGE_OVERRIDE:-24}" \
  BYPRODUCT_ARCHIVE_RETENTION_DAYS=30 \
  BYPRODUCT_STAMP="$root/stamp" \
  BYPRODUCT_MIN_HOURS="${MIN_HOURS_OVERRIDE:-12}" \
  BYPRODUCT_MIN_MINUTES="${MIN_MINUTES_OVERRIDE:-}" \
  BYPRODUCT_LOG="${LOG_OVERRIDE:-$root/home/.claude/logs/reclaim-byproducts.log}" \
  BYPRODUCT_LOG_MAX_BYTES="${LOG_MAX_OVERRIDE:-1048576}" \
  BYPRODUCT_DATA_VOLUME="$root" \
  BYPRODUCT_UV_BIN="${UV_OVERRIDE:-$root/bin/uv}" \
  BYPRODUCT_PIP_BIN="${PIP_OVERRIDE:-$root/bin/pip}" \
  BYPRODUCT_DEAD_CACHE_PATHS="${DEAD_CACHES_OVERRIDE:-$root/home/.cache/codex-runtimes}" \
  BYPRODUCT_EXTRA_NEVER_CACHE_PATHS="${EXTRA_NEVER_OVERRIDE:-}" \
    bash "$script" "$@" 2>&1
}
run()       { _run "$1" "$2" --dry-run; }
run_real()  { _run "$1" "$2"; }
run_stale() { _run "$1" "$2" --if-stale; }

# Runners for the staleness cases, each setting up the one precondition it is about.
run_stale_fresh()  { : > "$1/stamp"; _run "$1" "$2" --if-stale; }
run_stale_old()    { : > "$1/stamp"; touch -t "$OLD_TS" "$1/stamp"; _run "$1" "$2" --if-stale; }
run_stale_absent() { rm -f "$1/stamp"; _run "$1" "$2" --if-stale; }
run_hand_fresh()   { : > "$1/stamp"; _run "$1" "$2" --dry-run; }
# Makes the scratchpad reap fail the way the fixture case does, so its mutation proves
# WHERE the stamp is written and not merely that it is.
run_fail() {
  chmod 555 "$1/scratch/proj"
  local out; out="$(_run "$1" "$2")"
  chmod 755 "$1/scratch/proj"
  printf '%s' "$out"
}

# name | grep pattern that must be PRESENT | grep pattern that must be ABSENT
check() {
  local label="$1" out="$2" want="$3" unwant="${4:-}"
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -q "$want"; then
    fail "$label: expected to see /$want/"; return
  fi
  if [ -n "$unwant" ] && printf '%s' "$out" | grep -q "$unwant"; then
    fail "$label: did not expect /$unwant/"; return
  fi
  pass "$label"
}

# ---------------------------------------------------------------- baseline

build_fixture "$WORK/f"
OUT="$(run "$WORK/f" "$SCRIPT")"

check "an idle scratchpad the gate calls free is reaped" "$OUT" \
  "scratchpad WOULD be reaped: .*11111111-"
check "named_volume_is_never_reaped" "$OUT" "" \
  "volume WOULD be reaped: stima-ci-work-1"
check "a scratchpad the gate calls IN USE is kept" "$OUT" \
  "scratchpad kept: .*22222222-" "WOULD be reaped: .*22222222-"
check "UNKNOWN keeps the scratchpad" "$OUT" \
  "scratchpad kept: .*33333333-" "WOULD be reaped: .*33333333-"
check "a scratchpad touched inside the window is kept without asking the gate" "$OUT" \
  "scratchpad kept: .*44444444-.*touched within" "WOULD be reaped: .*44444444-"
check "a directory that is not a session id is left alone" "$OUT" "" \
  "not-a-session"
check "an old unreferenced anonymous volume is reaped" "$OUT" \
  "volume WOULD be reaped: $HEX_FREE"
check "a referenced anonymous volume is kept" "$OUT" "" \
  "volume WOULD be reaped: $HEX_REFD"
check "an anonymous volume younger than the gate is kept" "$OUT" "" \
  "volume WOULD be reaped: $HEX_YOUNG"
check "a volume whose age cannot be read is kept" "$OUT" "" \
  "volume WOULD be reaped: $HEX_NODATE"
check "a six-hour-old volume is kept at the default volume age" "$OUT" "" \
  "volume WOULD be reaped: $HEX_MID"

# ------------------------------------------------- one knob was gating two questions
#
# BYPRODUCT_IDLE_HOURS was the scratchpad's idle threshold AND the anonymous volume's
# minimum age. They are different questions with different answers: a scratchpad idle for
# seven hours may belong to a session that is thinking, and 24h there is not negotiable;
# an --ephemeral runner's volume is dead the moment its container exits, and 24h there
# left ~150 of them (15.8 GB/day) standing around. The second case below is the one that
# matters - it is what makes this a SPLIT rather than a rename.
OUT_VOL="$(VOLUME_AGE_OVERRIDE=1 run "$WORK/f" "$SCRIPT")"
check "lowering the volume age reaps a volume the default kept" "$OUT_VOL" \
  "volume WOULD be reaped: $HEX_MID"
scratch_verdicts() { printf '%s\n' "$1" | grep '^scratchpad' | sort; }
# The -n guard is the point: two empty verdict sets compare equal and would pass this
# case while proving nothing at all about either knob.
if [ -n "$(scratch_verdicts "$OUT")" ] &&
   [ "$(scratch_verdicts "$OUT_VOL")" = "$(scratch_verdicts "$OUT")" ]; then
  pass "and moves no scratchpad verdict: the volume knob is not the scratchpad knob"
else
  fail "the volume knob moved a scratchpad verdict; the two are still one knob"
fi
# A running go build does not stop the age trim (2026-10-05: on a host that always
# builds, the sweep stood down every run while the cache grew past its ceiling). The seam
# forced busy, without disk pressure.
OUT_BUSY="$(GO_BUSY_OVERRIDE=1 run "$WORK/f" "$SCRIPT")"
check "a running go build does not stop the age trim" "$OUT_BUSY" \
  "go cache WOULD trim 2 entr" "reaping nothing"

check "a stale go cache entry is trimmed and a fresh one is not" "$OUT" \
  "go cache WOULD trim 2 entr"
# The real path, on disk: entries go, the top-level files and the fuzz corpus stay.
build_fixture "$WORK/gt"
run_real "$WORK/gt" "$SCRIPT" >/dev/null
if [ ! -e "$WORK/gt/gocache/aa/old-one-d" ] && [ -e "$WORK/gt/gocache/aa/fresh-d" ] \
   && [ -e "$WORK/gt/gocache/testexpire.txt" ] && [ -e "$WORK/gt/gocache/trim.txt" ] \
   && [ -e "$WORK/gt/gocache/README" ] && [ -e "$WORK/gt/gocache/fuzz/pkg/corpus-d" ]; then
  pass "a real trim deletes stale entries and keeps testexpire.txt, the other top-level files and fuzz/"
else
  fail "a real trim took the wrong files: $(cd "$WORK/gt/gocache" && find . -type f | sort | tr '\n' ' ')"
fi
check "a disposable built image (apertis-prepared) is reaped" "$OUT" \
  "tagged image WOULD be reaped: apertis-prepared:deadbeef"
check "an old unreferenced PULLED image is kept: its age is upstream's, not the pull's" "$OUT" "" \
  "tagged image WOULD be reaped: postgres:17"
check "a disposable image younger than the age gate is kept" "$OUT" "" \
  "tagged image WOULD be reaped: apertis-prepared:young"
check "a disposable image a container references is kept" "$OUT" "" \
  "tagged image WOULD be reaped: apertis-prepared:inuse"
check "builder cache is not pruned here (cc-reaper's weekly prune owns it)" "$OUT" "" \
  "builder"
check "a locally BUILT image is never reaped" "$OUT" "" \
  "tagged image WOULD be reaped: locally-built:v1"
check "a pulled image younger than the age gate is kept" "$OUT" "" \
  "tagged image WOULD be reaped: pulled-but-young:v1"
check "an image a container references is kept" "$OUT" "" \
  "tagged image WOULD be reaped: in-use-image:v1"
check "an archive past retention is reaped" "$OUT" \
  "archive WOULD be reaped: .*20200101"
check "an archive inside retention is kept" "$OUT" "" \
  "archive WOULD be reaped: .*$(date +%Y%m%d)"
check "a non-date directory in the archive root is left alone" "$OUT" "" \
  "archive WOULD be reaped: .*notadate"

# ---------------------------------------------------------------- the run ledger
#
# Measured 2026-09-13: ~/.claude/logs/reclaim-byproducts.log was 147 lines holding TWO
# sweeps run straight into each other - no separator, no timestamp on any line, and no
# record of what any of it returned. "How often did it fire, and how much did it reclaim"
# had no answer on the machine the reaper was installed to protect.

check "a sweep opens with an ISO-8601 timestamp and the mode it is running in" "$OUT" \
  "^== byproducts sweep started [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][-+][0-9]\{4\} (dry-run,"
check "and closes with a timestamp and the seconds it took" "$OUT" \
  "^== byproducts sweep ended [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][-+][0-9]\{4\} after [0-9][0-9]*s;"
# The end line's other half, and the only number in the whole log that answers the
# question the log exists for: a run that reaped nothing and one that returned 20 GB were
# indistinguishable before this.
check "and says what the volume's free space actually did" "$OUT" \
  "free on .* -> .*GB ([-+][0-9.]*GB)"
check "the scratchpad section totals the bytes it took" "$OUT" \
  "^scratchpads: .*, would free [0-9.]*MB$"
check "the archive section totals the bytes it took" "$OUT" \
  "^archives: .*, would free [0-9.]*MB$"

# A firing that skipped is still a firing, so the ledger has to open ABOVE the staleness
# gate. Otherwise the one thing the log can never show is the schedule working.
build_fixture "$WORK/led"
: > "$WORK/led/stamp"
check "a scheduled firing that skips is still recorded as a firing" \
  "$(run_stale "$WORK/led" "$SCRIPT")" \
  "^== byproducts sweep started .* (scheduled,"

# Bounded, and never by a silent truncate - a sweep that destroys the evidence of the
# sweeps before it is the defect this section is about, wearing housekeeping's clothes.
LEDLOG="$WORK/led/home/.claude/logs/reclaim-byproducts.log"
mkdir -p "$(dirname "$LEDLOG")"
{ printf 'OLD-SWEEP-SENTINEL\n'; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$LEDLOG"
OUT_ROT="$(LOG_MAX_OVERRIDE=2048 run "$WORK/led" "$SCRIPT")"
if grep -q 'OLD-SWEEP-SENTINEL' "$LEDLOG.1" 2>/dev/null && [ ! -s "$LEDLOG" ]; then
  pass "a log past its size cap is rotated to a previous generation, not truncated"
else
  fail "a log past its size cap is rotated to a previous generation, not truncated"
fi
check "and the rotation says how much it moved" "$OUT_ROT" \
  "rotated the previous [0-9][0-9]* bytes to .*\.log\.1"
printf 'LIVE-SWEEP-SENTINEL\n' > "$LEDLOG"; rm -f "$LEDLOG.1"
run "$WORK/led" "$SCRIPT" >/dev/null
if grep -q 'LIVE-SWEEP-SENTINEL' "$LEDLOG" 2>/dev/null && [ ! -e "$LEDLOG.1" ]; then
  pass "a log under the cap is left exactly as it was"
else
  fail "a log under the cap was rotated anyway"
fi

# ---------------------------------------------------------------- caches
#
# ~20.9 GB with no reaper at all until 2026-09-13. The section takes only what a tool can
# say is dead - uv's and pip's own subcommands - plus a NAMED list of leftovers from
# applications that have been removed from the machine.

if grep -Eq '^CACHE_DEAD_PATHS="\$\{BYPRODUCT_DEAD_CACHE_PATHS:-\}"$' "$SCRIPT"; then
  pass "Codex runtime cache is not dead by default"
else
  fail "Codex runtime cache is still classified dead by default"
fi

check "the cache reaper runs uv's own prune rather than deleting its directory" "$OUT" \
  "caches: WOULD run uv cache prune"
check "and not pip's purge, which cc-reaper owns" "$OUT" "" "pip cache purge"
check "a dead application's leftovers are reaped" "$OUT" \
  "dead-application cache WOULD be reaped: .*codex-runtimes"

# --dry-run: nothing removed AND neither tool invoked. The second half is the one a
# report cannot fake - the stubs record every call they get.
build_fixture "$WORK/cd"
run "$WORK/cd" "$SCRIPT" >/dev/null
if [ -d "$WORK/cd/home/.cache/codex-runtimes" ] && [ ! -e "$WORK/cd/uv-calls" ] && [ ! -e "$WORK/cd/pip-calls" ]; then
  pass "--dry-run removes nothing in the cache section and runs neither tool"
else
  fail "--dry-run touched the cache section"
fi

# The four refusals, asked the hard way: every one of them is handed to the reaper AS a
# path to reap, beside a path it really may take. A guard that only holds while nobody
# edits the list is not a guard.
build_fixture "$WORK/c"
PROTECTED="$WORK/c/home/Library/Caches/CloudKit
$WORK/c/home/.cache/huggingface
$WORK/c/home/.cache/qmd
$WORK/c/home/Library/Caches/go-build"
OUT_PROT="$(DEAD_CACHES_OVERRIDE="$PROTECTED
$WORK/c/home/.cache/codex-runtimes" run_real "$WORK/c" "$SCRIPT")"
gone=""
while IFS= read -r p; do [ -d "$p" ] || gone="$gone $p"; done <<< "$PROTECTED"
if [ -z "$gone" ] && ! printf '%s' "$OUT_PROT" \
     | grep -qE 'cache (WOULD be reaped|reaped): .*(CloudKit|huggingface|qmd|go-build)'; then
  pass "the four protected caches are never passed to a removal and survive a real sweep"
else
  fail "a protected cache was passed to a removal or is gone:$gone"
fi
check "and the refusal names the path it refused" "$OUT_PROT" "cache REFUSED: .*CloudKit"

# The refusal is about PATHS, not about four literal strings, and this is the edit that
# will actually happen: the next dead application leaves several subdirectories behind and
# somebody lists their parent. With an exact-string predicate `$HOME/.cache` is not on the
# never-reap list, so the rm -rf underneath it takes huggingface, qmd and the uv cache.
build_fixture "$WORK/cpar"
OUT_CPAR="$(DEAD_CACHES_OVERRIDE="$WORK/cpar/home/.cache" run_real "$WORK/cpar" "$SCRIPT")"
if [ -d "$WORK/cpar/home/.cache/huggingface" ] && [ -d "$WORK/cpar/home/.cache/qmd" ]; then
  pass "an ANCESTOR of a protected path is refused, so the protected child survives"
else
  fail "a protected child was removed through its parent: $OUT_CPAR"
fi
check "and the refusal names the ancestor that was handed in" "$OUT_CPAR" \
  "cache REFUSED: .*/\.cache — on the never-reap list"

# The list side of the trailing-slash strip, which nothing could reach before. As the file
# ships the four protected entries are literals with no trailing slash, so the state that
# line defends against is unreachable at runtime and the whole suite stayed green with it
# deleted - measured, 145/0. That makes it defensive code for the next edit to the list,
# which is precisely the edit no test would have warned anybody about.
#
# BYPRODUCT_EXTRA_NEVER_CACHE_PATHS is how the suite expresses that edit. The probe path
# sits under none of the four literals, so nothing but the seam can decide it: if the seam
# were ignored the case would go red too, which is what stops it proving only itself.
build_fixture "$WORK/lnorm"
mkdir -p "$WORK/lnorm/home/.cache/listnorm/inside"
touch "$WORK/lnorm/home/.cache/listnorm/inside/blob"
OUT_LNORM="$(EXTRA_NEVER_OVERRIDE="$WORK/lnorm/home/.cache/listnorm/" \
  DEAD_CACHES_OVERRIDE="$WORK/lnorm/home/.cache/listnorm/inside
$WORK/lnorm/home/.cache/qmd" run_real "$WORK/lnorm" "$SCRIPT")"
if [ -d "$WORK/lnorm/home/.cache/listnorm/inside" ]; then
  pass "a protected entry written WITH a trailing slash still protects what is inside it"
else
  fail "a trailing slash on a list entry stopped it protecting its children: $OUT_LNORM"
fi
# And the seam only ever ADDS. A knob that could empty this list would be a knob for
# turning the guard off, so the same run asks whether a literal is still refused while it
# is set - which a substituting seam would answer the other way.
if [ -d "$WORK/lnorm/home/.cache/qmd" ]; then
  pass "and the extra entries widen the never-reap list rather than replacing it"
else
  fail "setting the extra paths dropped the built-in refusals: $OUT_LNORM"
fi

# The same mistake from the other end, plus the two ways a string comparison gets paths
# wrong. Asked in one run because each is a different candidate against the same list.
build_fixture "$WORK/cpath"
OUT_CPATH="$(DEAD_CACHES_OVERRIDE="$WORK/cpath/home/.cache//
$WORK/cpath/home/.cache/huggingface/hub
$WORK/cpath/home/.cache/qm
$WORK/cpath/home/.cache/qmd-old" run_real "$WORK/cpath" "$SCRIPT")"
if [ -d "$WORK/cpath/home/.cache/qmd" ] && [ -d "$WORK/cpath/home/.cache/huggingface" ]; then
  pass "trailing slashes are normalised, so an ancestor spelled with them is still one"
else
  fail "an ancestor spelled with trailing slashes reaped its protected children: $OUT_CPATH"
fi
if [ -d "$WORK/cpath/home/.cache/huggingface/hub" ]; then
  pass "a path INSIDE a protected one is refused too"
else
  fail "a path inside a protected one was reaped: $OUT_CPATH"
fi
# And the two guards that stop the fix over-reaching, one per direction: sharing a prefix
# is not being inside. `qm` is a prefix of the protected `qmd`, `qmd-old` has it as a
# prefix, and neither is inside it - a startswith on either side refuses a real dead path
# for ever, and a reaper that has quietly stopped reaping looks like one with nothing left.
if [ ! -d "$WORK/cpath/home/.cache/qm" ] \
   && printf '%s' "$OUT_CPATH" | grep -q "dead-application cache reaped: .*/\.cache/qm$"; then
  pass "a dead path that is a PREFIX of a protected one is still reaped"
else
  fail "a dead path was refused because a protected name starts with it: $OUT_CPATH"
fi
if [ ! -d "$WORK/cpath/home/.cache/qmd-old" ] \
   && printf '%s' "$OUT_CPATH" | grep -q "dead-application cache reaped: .*qmd-old"; then
  pass "a dead path whose name STARTS with a protected one is still reaped"
else
  fail "a dead path was refused because its name starts like a protected one: $OUT_CPATH"
fi
check "while the dead-application path listed beside them is still reaped" "$OUT_PROT" \
  "dead-application cache reaped: .*codex-runtimes"
if grep -q 'cache prune' "$WORK/c/uv-calls" 2>/dev/null && [ ! -e "$WORK/c/pip-calls" ]; then
  pass "a real sweep runs uv cache prune and never pip"
else
  fail "a real sweep runs uv cache prune and never pip"
fi

# A machine without uv or pip is not a machine whose sweep failed. Asked on the REAL path
# so the verdict is the stamp, which is what a failure would have withheld.
build_fixture "$WORK/nouv"
OUT_NOUV="$(UV_OVERRIDE="$WORK/nouv/bin/no-such-uv" PIP_OVERRIDE="$WORK/nouv/bin/no-such-pip" \
  run_real "$WORK/nouv" "$SCRIPT")"; RC_NOUV=$?
if [ "$RC_NOUV" -eq 0 ] && [ -f "$WORK/nouv/stamp" ]; then
  pass "an absent cache tool is a skip, not a failure"
else
  fail "an absent cache tool failed the sweep (rc=$RC_NOUV)"
fi
check "and the skip says which tool was missing" "$OUT_NOUV" \
  "caches: no .*no-such-uv on PATH"

# And a real failure inside the section still withholds the stamp, exactly as one in the
# scratchpad reaper does - otherwise the next scheduled firing skips work nobody did.
build_fixture "$WORK/cf"
chmod 555 "$WORK/cf/home/.cache"
OUT_CF="$(run_real "$WORK/cf" "$SCRIPT")"; RC_CF=$?
chmod 755 "$WORK/cf/home/.cache"
if [ "$RC_CF" -eq 1 ] && [ ! -e "$WORK/cf/stamp" ]; then
  pass "a failure inside the cache section is not recorded as a completed reap"
else
  fail "a failure inside the cache section was stamped as complete (rc=$RC_CF)"
fi

# The two refusals. Both must reap NOTHING, not reap partially.
OUT_OFF="$(BYPRODUCT_SCRATCH_ROOT="$WORK/f/scratch" BYPRODUCT_ARCHIVE_ROOT="$WORK/f/archive" \
  BYPRODUCT_DOCKER_BIN="$WORK/f/bin/docker" PATH_IN_USE_BIN="$WORK/f/bin/path-in-use.sh" \
  BYPRODUCT_LOG="$WORK/f/stray.log" \
  BYPRODUCT_IDLE_HOURS=off bash "$SCRIPT" --dry-run 2>&1)"; RC_OFF=$?
if [ "$RC_OFF" -eq 2 ] && ! printf '%s' "$OUT_OFF" | grep -q "WOULD be reaped"; then
  pass "a non-numeric idle window refuses and reaps nothing"
else
  fail "a non-numeric idle window refuses and reaps nothing (rc=$RC_OFF)"
fi

# The new knob decides WHAT is deleted, so it refuses like the one it was split from
# rather than defaulting like the staleness window.
OUT_VOLBAD="$(BYPRODUCT_SCRATCH_ROOT="$WORK/f/scratch" BYPRODUCT_ARCHIVE_ROOT="$WORK/f/archive" \
  BYPRODUCT_DOCKER_BIN="$WORK/f/bin/docker" PATH_IN_USE_BIN="$WORK/f/bin/path-in-use.sh" \
  BYPRODUCT_LOG="$WORK/f/stray.log" \
  BYPRODUCT_DOCKER_VOLUME_AGE_HOURS=-5 bash "$SCRIPT" --dry-run 2>&1)"; RC_VOLBAD=$?
if [ "$RC_VOLBAD" -eq 2 ] && ! printf '%s' "$OUT_VOLBAD" | grep -q "WOULD be reaped"; then
  pass "a non-numeric volume age refuses and reaps nothing"
else
  fail "a non-numeric volume age refuses and reaps nothing (rc=$RC_VOLBAD)"
fi

OUT_NOGATE="$(BYPRODUCT_SCRATCH_ROOT="$WORK/f/scratch" BYPRODUCT_ARCHIVE_ROOT="$WORK/f/archive" \
  BYPRODUCT_DOCKER_BIN="$WORK/f/bin/docker" PATH_IN_USE_BIN="$WORK/f/bin/does-not-exist" \
  BYPRODUCT_LOG="$WORK/f/stray.log" BYPRODUCT_DEAD_CACHE_PATHS="$WORK/f/nothing" \
  bash "$SCRIPT" 2>&1)"; RC_NOGATE=$?
if [ "$RC_NOGATE" -eq 1 ] && ! printf '%s' "$OUT_NOGATE" | grep -q "reaped:"; then
  pass "a missing liveness gate refuses the whole run"
else
  fail "a missing liveness gate refuses the whole run (rc=$RC_NOGATE)"
fi

# --self-test has to find tests/ when the script is reached through the symlink every
# installed hook actually is. `dirname $BASH_SOURCE` answers ~/.claude/hooks there, where
# tests/ does not exist -- measured: "No such file or directory", which reads as the suite
# having no cases rather than as a broken path. A stub repo stands in so this does not
# recurse into itself.
selftest_through_symlink() {
  local repo="$WORK/stub-repo"
  rm -rf "$repo"; mkdir -p "$repo/shell" "$repo/tests" "$WORK/elsewhere"
  cp "$SCRIPT" "$repo/shell/reclaim-byproducts.sh"
  printf '#!/usr/bin/env bash\necho STUB-SUITE-RAN\n' > "$repo/tests/reclaim-byproducts.sh"
  chmod +x "$repo/tests/reclaim-byproducts.sh"
  ln -sfn "$repo/shell/reclaim-byproducts.sh" "$WORK/elsewhere/reclaim-byproducts.sh"
  bash "$WORK/elsewhere/reclaim-byproducts.sh" --self-test 2>&1
}
OUT_ST="$(selftest_through_symlink)"
if printf '%s' "$OUT_ST" | grep -q 'STUB-SUITE-RAN'; then
  pass "--self-test resolves tests/ through the installed symlink"
else
  fail "--self-test resolves tests/ through the installed symlink (got: $OUT_ST)"
fi

# ---------------------------------------------------------------- the staleness gate
#
# A LaunchAgent loads at LOGIN, not at boot, and FileVault rules out an automatic login:
# after a reboot the 04:00 firing is missed and never caught up. RunAtLoad closes that,
# and fires again on every `launchctl load` - which is what the stamp is for. Everything
# below runs the reaper FOR REAL against the fixture, because a dry run is precisely the
# path that must leave no stamp behind.

check "a dry run says nothing about a stamp" "$OUT" "" "stamped "
if [ -e "$WORK/f/stamp" ]; then fail "a dry run writes no stamp"; else pass "a dry run writes no stamp"; fi

build_fixture "$WORK/s"
OUT_REAL="$(run_real "$WORK/s" "$SCRIPT")"
if [ -f "$WORK/s/stamp" ] && printf '%s' "$OUT_REAL" | grep -q "stamped "; then
  pass "a completed reap records when it finished"
else
  fail "a completed reap records when it finished"
fi

# And says so about ITSELF. $GATE is this process's window: a hand-run has no
# BYPRODUCT_MIN_MINUTES and falls back to 12h, while the installed agent carries 90m in
# its plist and the minutes win - so "a scheduled run inside the next 12h will skip",
# which is what this printed until 2026-09-13, was false about the only subject it named,
# in a log the two processes share. Asked here with the minutes unset, which is exactly
# the hand-run that produced the measured line.
check "the stamp line describes this run's own gate, not another process's" "$OUT_REAL" \
  "stamped .*; a run with the same gate inside the next 12h will skip" \
  "a scheduled run inside the next"

check "--if-stale skips while that record is inside the window" \
  "$(run_stale "$WORK/s" "$SCRIPT")" "a reap completed less than 12h ago" "scratchpads:"
check "--if-stale reaps once the record is older than the window" \
  "$(run_stale_old "$WORK/s" "$SCRIPT")" "scratchpads:" "a reap completed less than"
check "a missing record means the reap runs" \
  "$(run_stale_absent "$WORK/s" "$SCRIPT")" "scratchpads:" "a reap completed less than"
# The hand-run. Nobody reclaiming disk right now is told the job ran recently, so there
# is nothing they need a way past.
check "a hand-run ignores the record however fresh it is" \
  "$(run_hand_fresh "$WORK/s" "$SCRIPT")" "scratchpads:" "a reap completed less than"

# A bad window is defaulted, not refused: it decides WHEN the job runs, not what it
# deletes, and refusing would stop the daily reclamation outright. Fresh stamp, so the
# fallback is visible in the gate's behaviour and not only in the warning.
OUT_BADMIN="$(MIN_HOURS_OVERRIDE=off run_stale_fresh "$WORK/s" "$SCRIPT")"
check "a non-numeric window falls back to the default" "$OUT_BADMIN" "using 12"
check "and the gate is still enforced at that default" "$OUT_BADMIN" \
  "a reap completed less than 12h ago" "scratchpads:"

# A window a sub-daily schedule can actually express. Whole hours cannot: the schedule the
# agent now installs fires every three, and the smallest hour count below three is two,
# which is a 33% margin where the gate wants room for a firing that lands early.
run_stale_3h() { : > "$1/stamp"; touch -t "$THREE_H_AGO" "$1/stamp"; _run "$1" "$2" --if-stale; }
check "a scheduled run three hours on is thrown away by the twelve-hour window" \
  "$(run_stale_3h "$WORK/s" "$SCRIPT")" "a reap completed less than 12h ago" "scratchpads:"
check "and is not, once the window is the schedule's own 90 minutes" \
  "$(MIN_MINUTES_OVERRIDE=90 run_stale_3h "$WORK/s" "$SCRIPT")" "scratchpads:" \
  "a reap completed less than"
# Minutes win over hours when both are set, which is the installed agent's situation: its
# plist carries the minutes and BYPRODUCT_MIN_HOURS keeps whatever it had. Asked in the
# direction where the two disagree AND neither is the default, so no other reading of the
# result is available: at 1h the three-hour-old stamp is stale, at 720m it is not.
check "the minutes window wins over the hours one" \
  "$(MIN_HOURS_OVERRIDE=1 MIN_MINUTES_OVERRIDE=720 run_stale_3h "$WORK/s" "$SCRIPT")" \
  "a reap completed less than 12h ago" "scratchpads:"
# Bad minutes fall back to the hours, exactly as bad hours fall back to 12 - never to
# "no gate at all", which would make every login a full sweep. On the three-hour stamp
# again, so that the fallback is visible as a VERDICT and not only as a warning line.
OUT_BADMINM="$(MIN_MINUTES_OVERRIDE=off run_stale_3h "$WORK/s" "$SCRIPT")"
check "a non-numeric minutes window falls back to the hours one" "$OUT_BADMINM" \
  "BYPRODUCT_MIN_MINUTES=off .*using 12h"
check "and the gate is still enforced there too" "$OUT_BADMINM" \
  "a reap completed less than 12h ago" "scratchpads:"

# A run that failed left work behind. Stamping it would suppress the next firing that
# could have finished the job - the same silent skipped day this whole change is about.
build_fixture "$WORK/x"
chmod 555 "$WORK/x/scratch/proj"
OUT_FAIL="$(run_real "$WORK/x" "$SCRIPT")"; RC_FAIL=$?
chmod 755 "$WORK/x/scratch/proj"
if [ "$RC_FAIL" -eq 1 ] && [ ! -e "$WORK/x/stamp" ]; then
  pass "a reap that failed is not recorded as a completed one"
else
  fail "a reap that failed is not recorded as a completed one (rc=$RC_FAIL)"
fi

# ---------------------------------------------------------------- launchd install
#
# launchctl is a stub that answers the two questions the installer asks - does the job
# load, does firing it produce output - and honours RunAtLoad on `load`, because "a reload
# must not re-reap" is the point of the plist change and asserting on the plist's TEXT
# would not have tested it. $HOME is the fixture's, so the plist is never the user's.
install_fixture() {
  local root="$1" script="$2"
  build_fixture "$root"
  mkdir -p "$root/hook"
  # The plist names $HERE/reclaim-byproducts.sh, so a mutant has to be installed under
  # that name or the agent would point back at the unmutated original.
  cp "$script" "$root/hook/reclaim-byproducts.sh"
  cat > "$root/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
PLIST="$HOME/Library/LaunchAgents/com.cc-reaper.reclaim-byproducts.plist"
fire() {
  [ -f "$PLIST" ] || return 0
  local logf a args=()
  logf="$(sed -n 's|.*<key>StandardOutPath</key><string>\(.*\)</string>.*|\1|p' "$PLIST" | head -1)"
  [ -n "$logf" ] || return 0
  # Real launchd hands the job the plist's EnvironmentVariables, so this does too. That is
  # not decoration: the interval schedule carries its staleness gate there, and a stub that
  # dropped it would leave "the schedule is not cancelled by the gate" provable only against
  # the plist's TEXT - which is the thing the RunAtLoad comment above says proves nothing.
  # PATH is skipped; the fixture's tools are reached by the absolute paths each case passes.
  local k v
  while IFS= read -r k; do
    IFS= read -r v || break
    case "$k" in ''|PATH) continue ;; esac
    export "$k=$v"
  done <<EOF
$(grep '<key>PATH</key>' "$PLIST" | head -1 | tr '<' '\n' | sed -n -e 's|^key>\(.*\)$|\1|p' -e 's|^string>\(.*\)$|\1|p')
EOF
  # Every <string> sits on one line inside <array>, so each has to be split off rather
  # than matched with a greedy .* that would only ever see the last one.
  while IFS= read -r a; do [ -n "$a" ] && args+=("$a"); done <<EOF
$(sed -n '/ProgramArguments/,/<\/array>/p' "$PLIST" | tr '<' '\n' | sed -n 's|^string>\(.*\)$|\1|p')
EOF
  [ "${#args[@]}" -gt 0 ] || return 0
  "${args[@]}" >> "$logf" 2>&1
}
# Whether a job is loaded is a real question the installer now asks, so the stub keeps a
# real answer to it instead of saying yes to everything: identical plist content with the
# job NOT loaded has to still install, and a stub that could not say "not loaded" would
# make that case unwritable.
case "${1:-}" in
  load) touch "$HOME/.launchd-loaded"; grep -q '<key>RunAtLoad</key><true/>' "$PLIST" 2>/dev/null && fire ;;
  # The skills-era agent is a different job: its own loaded flag, and a "running" state a
  # case can set to stand for a sweep in progress.
  unload|bootout)
    case "${2:-}" in
      *com.claude.reclaim-byproducts*) printf '%s\n' "$*" >> "$HOME/.legacy-calls" ;;
      *) rm -f "$HOME/.launchd-loaded" ;;
    esac ;;
  print)
    case "${2:-}" in
      */com.claude.reclaim-byproducts)
        [ -f "$HOME/Library/LaunchAgents/com.claude.reclaim-byproducts.plist" ] || exit 1
        [ -f "$HOME/.legacy-running" ] && echo "state = running"; exit 0 ;;
    esac
    [ -f "$HOME/.launchd-loaded" ] || exit 1 ;;
  kickstart) fire ;;
esac
exit 0
STUB
  chmod +x "$root/bin/launchctl"
}
run_install() { _run "$1" "$1/hook/reclaim-byproducts.sh" --install-launchd "${2:-04:00}"; }
fire_load()   { _run "$1" "$1/bin/launchctl" load; }
agent_logfile() { printf '%s' "$1/home/.claude/logs/reclaim-byproducts.log"; }
agent_log()   { cat "$(agent_logfile "$1")" 2>/dev/null; }
agent_plist() { printf '%s' "$1/home/Library/LaunchAgents/com.cc-reaper.reclaim-byproducts.plist"; }

# Nothing has reaped yet: installing must load the agent, RunAtLoad must fire it, and that
# firing must be a real reap. That is the boot catch-up, exercised end to end.
install_fixture "$WORK/i" "$SCRIPT"
OUT_INST="$(run_install "$WORK/i")"
check "--install-launchd still installs" "$OUT_INST" "installed com.cc-reaper.reclaim-byproducts"
if grep -q '<key>RunAtLoad</key><true/>' "$(agent_plist "$WORK/i")" 2>/dev/null; then
  pass "the installed agent carries RunAtLoad"
else
  fail "the installed agent carries RunAtLoad"
fi
if [ -f "$WORK/i/stamp" ]; then
  pass "loading the agent fires it and that firing reaps"
else
  fail "loading the agent fires it and that firing reaps"
fi
: > "$(agent_logfile "$WORK/i")"
fire_load "$WORK/i" >/dev/null
check "reloading it inside the window reaps nothing" "$(agent_log "$WORK/i")" \
  "a reap completed less than" "scratchpads:"

check "and the daily form still writes a wall-clock schedule" \
  "$(cat "$(agent_plist "$WORK/i")")" "<key>StartCalendarInterval</key>" "<key>StartInterval</key>"
check "and says which schedule it installed" "$OUT_INST" "installed .* at 04:00 and at every login"

# ------------------------------------------------- the skills-era agent is retired
#
# The reaper moved from the skills repository to cc-reaper on 2026-10-07 under a new label.
# Two agents running one sweep would race each other over the same directories, so the old
# one goes once the new one is installed - but never by signalling a sweep in progress.
legacy_plist() { printf '%s' "$1/home/Library/LaunchAgents/com.claude.reclaim-byproducts.plist"; }
install_fixture "$WORK/lg" "$SCRIPT"
mkdir -p "$WORK/lg/home/Library/LaunchAgents"; echo '<plist/>' > "$(legacy_plist "$WORK/lg")"
OUT_LG="$(run_install "$WORK/lg" 3h)"
check "installing retires the skills-era agent" "$OUT_LG" "retired com.claude.reclaim-byproducts"
if [ ! -e "$(legacy_plist "$WORK/lg")" ] && ls "$WORK/lg/home/.cc-reaper/state/retired-agents/"com.claude.reclaim-byproducts.*.plist >/dev/null 2>&1 \
   && grep -q 'unload' "$WORK/lg/home/.legacy-calls" 2>/dev/null; then
  pass "its plist is unloaded and kept aside, not deleted"
else
  fail "its plist is unloaded and kept aside, not deleted"
fi

install_fixture "$WORK/lr" "$SCRIPT"
mkdir -p "$WORK/lr/home/Library/LaunchAgents"; echo '<plist/>' > "$(legacy_plist "$WORK/lr")"
touch "$WORK/lr/home/.legacy-running"
OUT_LR="$(BYPRODUCT_LEGACY_WAIT_SECONDS=0 run_install "$WORK/lr" 3h 2>&1)"
if [ -e "$(legacy_plist "$WORK/lr")" ] && [ ! -e "$WORK/lr/home/.legacy-calls" ] \
   && printf '%s' "$OUT_LR" | grep -q 'still running'; then
  pass "a sweep in progress under the old agent is never signalled"
else
  fail "a sweep in progress under the old agent is never signalled (got: $OUT_LR)"
fi

# ------------------------------------------------- installing what is already installed
#
# Measured 2026-09-13: a second session re-ran the installer. It rewrote the plist at
# 10:19:34, which reset launchd's `runs` counter to 1 and truncated the log - so nothing
# left on the machine could show that the 3-hour timer had ever fired at all. An installer
# that destroys the evidence its own schedule works is worse than one that does nothing.
install_fixture "$WORK/id" "$SCRIPT"
run_install "$WORK/id" 3h >/dev/null
ID_PLIST="$(agent_plist "$WORK/id")"
ID_BEFORE="$(stat -f '%Fm %z' "$ID_PLIST" 2>/dev/null)"
printf 'EARLIER-SWEEP-SENTINEL\n' > "$(agent_logfile "$WORK/id")"
OUT_ID="$(run_install "$WORK/id" 3h)"
ID_AFTER="$(stat -f '%Fm %z' "$ID_PLIST" 2>/dev/null)"
# Sub-second mtime and size together: two installs land inside the same second, and a
# whole-second mtime would call a rewrite unchanged.
if [ -n "$ID_BEFORE" ] && [ "$ID_BEFORE" = "$ID_AFTER" ]; then
  pass "a second install of the same agent does not rewrite the plist"
else
  fail "the plist was rewritten ($ID_BEFORE -> $ID_AFTER): $OUT_ID"
fi
if grep -q 'EARLIER-SWEEP-SENTINEL' "$(agent_logfile "$WORK/id")" 2>/dev/null; then
  pass "and does not truncate the log that proves the schedule fires"
else
  fail "the second install truncated the log: $OUT_ID"
fi
check "and says it changed nothing" "$OUT_ID" \
  "already installed .* and loaded; nothing changed"

# The other half, twice over, because "never write" would pass the two cases above. A
# different schedule is a different agent and must be installed; identical content whose
# job is NOT loaded is a plist somebody left behind, and leaving it alone leaves the
# machine with no reaper running at all.
OUT_ID2="$(run_install "$WORK/id" 6h)"
check "but a plist that would differ is still written" "$OUT_ID2" \
  "installed .* every 6h and at every login"
rm -f "$WORK/id/home/.launchd-loaded"
OUT_ID3="$(run_install "$WORK/id" 6h)"
check "and so is an identical one whose job is not loaded" "$OUT_ID3" \
  "installed com.cc-reaper.reclaim-byproducts"

# ------------------------------------------------- the interval schedule
#
# Every three hours, because this machine's four CI runners leave ~150 anonymous volumes a
# day and a once-daily reaper never catches up. StartInterval is the only launchd key that
# repeats on a period; the daily form above keeps StartCalendarInterval, and both keep
# RunAtLoad for the login after a reboot.
install_fixture "$WORK/iv" "$SCRIPT"
OUT_IV="$(run_install "$WORK/iv" 3h)"
IV_PLIST="$(agent_plist "$WORK/iv")"
check "--install-launchd Nh installs and says so" "$OUT_IV" \
  "installed .* every 3h and at every login"
check "the interval agent repeats on the interval and carries no wall-clock time" \
  "$(cat "$IV_PLIST" 2>/dev/null)" "<key>StartInterval</key><integer>10800</integer>" \
  "StartCalendarInterval"
check "it still carries RunAtLoad" "$(cat "$IV_PLIST" 2>/dev/null)" \
  "<key>RunAtLoad</key><true/>"
check "it still passes --if-stale" "$(cat "$IV_PLIST" 2>/dev/null)" \
  "<string>--if-stale</string>"
check "and the plist says why it will not skip" "$(cat "$IV_PLIST" 2>/dev/null)" \
  "<key>BYPRODUCT_MIN_MINUTES</key><string>90</string>"

# The load-bearing one. RunAtLoad has already fired this agent once and it stamped; move
# that stamp back one whole period and fire the schedule again. With the gate the plist
# carries this is a reap. With the shipped 12h gate it is the word "skipping", three
# firings in four, for ever, and nothing anywhere reports a failure.
touch -t "$THREE_H_AGO" "$WORK/iv/stamp"
: > "$(agent_logfile "$WORK/iv")"
fire_load "$WORK/iv" >/dev/null
check "a firing one period on is not thrown away by the staleness gate" \
  "$(agent_log "$WORK/iv")" "scratchpads:" "a reap completed less than"

# And the reload the gate exists for still costs nothing: RunAtLoad fires at every login,
# and one that lands inside the period must not re-sweep docker and the Go cache.
: > "$(agent_logfile "$WORK/iv")"
fire_load "$WORK/iv" >/dev/null
check "while a reload inside the period still reaps nothing" "$(agent_log "$WORK/iv")" \
  "a reap completed less than 90m ago" "scratchpads:"

# A machine that reaped an hour ago. The probe must keep producing real reaper output or
# the installer rejects a perfectly good job.
install_fixture "$WORK/j" "$SCRIPT"
: > "$WORK/j/stamp"
OUT_INST_B="$(run_install "$WORK/j")"
check "a fresh stamp does not make the installer reject the job" "$OUT_INST_B" \
  "installed com.cc-reaper.reclaim-byproducts"
check "and the probe reached the reapers" "$(agent_log "$WORK/j")" "scratchpads:"

# A probe whose log arrives in two pieces, which is how every real one arrives: the
# section header is printed at once and the reaper summary only when that reaper has
# finished - 358 seconds later on this machine, because the liveness gate is nearly the
# whole run. The fixture stub above fires the script synchronously, so its log is complete
# before the installer looks at it; that is a fine stand-in for every other question and
# the one thing it cannot reproduce is this one. A stub that writes both pieces at once
# cannot tell an installer that waits for the summary apart from one that waits for the
# file to stop being empty - and the second of those is the code that, on 2026-09-12,
# refused a working install and deleted the live agent on its way out.
delayed_install_fixture() {
  local root="$1" script="$2" tail_text="$3"
  build_fixture "$root"
  mkdir -p "$root/hook"
  cp "$script" "$root/hook/reclaim-byproducts.sh"
  cat > "$root/bin/launchctl" <<STUB
#!/usr/bin/env bash
logf="\$HOME/.claude/logs/reclaim-byproducts.log"
case "\${1:-}" in
  kickstart)
    printf -- '-- scratchpads\n' > "\$logf"
    [ -n "$tail_text" ] && ( sleep 2; printf '%s\n' "$tail_text" >> "\$logf" ) >/dev/null 2>&1 & ;;
esac
exit 0
STUB
  chmod +x "$root/bin/launchctl"
}

# The exact log the defect was measured against: `-- scratchpads` and nothing else yet.
delayed_install_fixture "$WORK/late" "$SCRIPT" "scratchpads: 0 reaped, 5 kept"
OUT_LATE="$(run_install "$WORK/late")"
check "the probe waits for the reaper summary, not for the log's first line" "$OUT_LATE" \
  "installed com.cc-reaper.reclaim-byproducts"
if [ -s "$(agent_plist "$WORK/late")" ]; then
  pass "and a slow but healthy run keeps its agent"
else
  fail "a healthy install was refused and its plist removed: $OUT_LATE"
fi

# Nothing after the header, ever. The probe cannot answer, and an answer it cannot give is
# not the answer "no": the job PRINTED, so the failure the two checks above it exist to
# catch is already disproved. Refusing here is what took the agent down.
delayed_install_fixture "$WORK/incon" "$SCRIPT" ""
printf '%s\n' '<!-- SENTINEL-PREVIOUS-AGENT -->' > "$(agent_plist "$WORK/incon")"
OUT_INCON="$(PROBE_SECONDS_OVERRIDE=2 run_install "$WORK/incon")"
if grep -q 'SENTINEL-PREVIOUS-AGENT' "$(agent_plist "$WORK/incon")" 2>/dev/null; then
  pass "a probe that started and never finished leaves the installed agent exactly as it was"
else
  fail "an inconclusive probe destroyed the agent that was already installed: $OUT_INCON"
fi
# Leaving the PROBE plist loaded is the quieter version of the same outage: it carries
# --dry-run, so the schedule would fire every night and reap nothing for ever.
if grep -q -- '--dry-run' "$(agent_plist "$WORK/incon")" 2>/dev/null; then
  fail "the probe plist was left in place of the agent; the schedule would reap nothing"
else
  pass "and the probe plist, which carries --dry-run, is not what was left behind"
fi

# The other half, and why this is not simply "never delete anything": with no agent there
# before, installing one whose only probe never finished claims the proof this branch is
# admitting it does not have.
delayed_install_fixture "$WORK/inconf" "$SCRIPT" ""
OUT_INCONF="$(PROBE_SECONDS_OVERRIDE=2 run_install "$WORK/inconf")"
if [ ! -e "$(agent_plist "$WORK/inconf")" ]; then
  pass "with nothing installed before, an inconclusive probe leaves nothing installed"
else
  fail "an unproven agent was installed: $OUT_INCONF"
fi
check "and says so rather than reading as a refusal" "$OUT_INCONF" \
  "nothing was installed before either"

# ---------------------------------------------------------------- the go cache ceiling

# Sizes are in whole GB, so no fixture could cross a ceiling with real bytes. A `du` stub
# weighs every cache entry at 1GB and hands every other call to the real one; a `go` stub
# records `go clean -cache` instead of running it, and says so when GOCACHE does not name
# the fixture - the real one would empty whatever cache Go resolves on this machine.
# Entries sit at 48h, 20h, 10h, 5h and 2h idle, one per halving of the 3d horizon
# (2160m, 1080m, 540m, 270m) and one under the 180m floor, beside build_fixture's fresh
# entry and its two 40-day ones.
hours_ago() { date -v-"$1"H +%Y%m%d%H%M 2>/dev/null || date -d "$1 hours ago" +%Y%m%d%H%M; }
go_ceiling_fixture() {
  local root="$1" h
  mkdir -p "$root/gobin" "$root/gocache/cc"
  for h in 48 20 10 5 2; do touch -t "$(hours_ago "$h")" "$root/gocache/cc/h$h-d"; done
  cat > "$root/gobin/du" <<STUB
#!/usr/bin/env bash
if [ "\$1" = -sm ] && [ "\$2" = "$root/gocache" ]; then
  n="\$(/usr/bin/find "$root/gocache" -mindepth 2 -maxdepth 2 -path '$root/gocache/[0-9a-f][0-9a-f]/*' -name '*-[ad]' -type f | wc -l)"
  printf '%s\t%s\n' "\$((n * 1024))" "\$2"; exit 0
fi
exec /usr/bin/du "\$@"
STUB
  cat > "$root/gobin/go" <<STUB
#!/usr/bin/env bash
echo "go \$* GOCACHE=\${GOCACHE:-}" >> "$root/go-calls"
[ "\${GOCACHE:-}" = "$root/gocache" ] || echo "go-stub: wrong GOCACHE" >> "$root/go-calls"
exit 0
STUB
  chmod +x "$root/gobin/du" "$root/gobin/go"
}
# What a ceiling run leaves, as text a case (or a mutation) can grep.
go_ceiling_run() {
  local root="$1" script="$2" max="$3"
  go_ceiling_fixture "$root"
  GO_MAX_OVERRIDE="$max" PATH_PREFIX_OVERRIDE="$root/gobin" run_real "$root" "$script" | grep '^go cache'
  echo "left: $(cd "$root/gocache" && find . -path './[0-9a-f][0-9a-f]/*' -name '*-d' -type f | sort | tr '\n' ' ')"
  cat "$root/go-calls" 2>/dev/null
}
run_ceiling_fits()  { go_ceiling_run "$1" "$2" 4; }
run_ceiling_floor() { go_ceiling_run "$1" "$2" 1; }

# Six entries after the age trim against a 4GB ceiling: 36h, 18h and 9h take the three
# idlest and the cache fits at 3GB, so the 5h and 2h entries and the fresh one stay and
# nothing is emptied.
build_fixture "$WORK/gc"
OUT_FITS="$(run_ceiling_fits "$WORK/gc" "$SCRIPT")"
check "over the ceiling, the idlest entries go first" "$OUT_FITS" \
  "idle over 540m (-> 3GB)"
check "and the trim stops once the cache fits" "$OUT_FITS" \
  "left: ./aa/fresh-d ./cc/h2-d ./cc/h5-d $" "idle over 270m"
check "and a cache brought under the ceiling is not emptied" "$OUT_FITS" "" \
  "go clean"

# A 1GB ceiling the idle trim cannot reach: it halves down to 270m and no further, so the
# 2h entry survives it, and only then is the cache emptied - the one GO_CACHE_DIR names.
build_fixture "$WORK/gf"
OUT_FLOOR="$(run_ceiling_floor "$WORK/gf" "$SCRIPT")"
check "the idle horizon never goes below 180m" "$OUT_FLOOR" \
  "left: ./aa/fresh-d ./cc/h2-d $" "idle over 135m"
check "a cache still over the ceiling at the floor is emptied" "$OUT_FLOOR" \
  "go clean -cache GOCACHE=$WORK/gf/gocache" "go-stub: wrong GOCACHE"

# Disk pressure lowers the ceiling by what the volume is short of the 30GB floor. Six
# entries after the age trim, 26GB free: 4GB short, so a 3GB ceiling (the loop runs while at or above it) - the
# halving takes everything down to the 270m step and leaves the 2h entry, and the cache is
# not emptied, because emptying stays the fixed ceiling's call.
build_fixture "$WORK/gp"
OUT_PRESS="$(FREE_GB_OVERRIDE=26 go_ceiling_run "$WORK/gp" "$SCRIPT" 99999)"
check "a disk under the free floor lowers the ceiling for that run" "$OUT_PRESS" \
  "26GB free is under the 30GB floor; ceiling 3GB"
check "and trims idle-first down to the horizon floor, without emptying" "$OUT_PRESS" \
  "left: ./aa/fresh-d ./cc/h2-d $" "go clean"
# 1GB short takes only the idlest entry.
build_fixture "$WORK/gq"
OUT_PRESS1="$(FREE_GB_OVERRIDE=29 go_ceiling_run "$WORK/gq" "$SCRIPT" 99999)"
check "a small shortfall trims only as far as it needs" "$OUT_PRESS1" \
  "left: ./aa/fresh-d ./cc/h10-d ./cc/h2-d ./cc/h20-d ./cc/h5-d $"
# At the floor nothing changes.
build_fixture "$WORK/gr"
OUT_PRESS0="$(FREE_GB_OVERRIDE=30 go_ceiling_run "$WORK/gr" "$SCRIPT" 99999)"
check "a disk at the free floor leaves the ceiling alone" "$OUT_PRESS0" \
  "left: ./aa/fresh-d ./cc/h10-d ./cc/h2-d ./cc/h20-d ./cc/h48-d ./cc/h5-d $" "under the"
# Under pressure a running go build no longer stops the idle trims, but it still stops
# the full clear: 26GB free, a build running, and a 1GB fixed ceiling the trim cannot
# reach - entries go down to the horizon floor and the cache is not emptied.
build_fixture "$WORK/gb"
OUT_PRESS_BUSY="$(FREE_GB_OVERRIDE=26 GO_BUSY_OVERRIDE=1 go_ceiling_run "$WORK/gb" "$SCRIPT" 1)"
check "under pressure a running build does not stop the idle trims" "$OUT_PRESS_BUSY" \
  "left: ./aa/fresh-d ./cc/h2-d $" "reaping nothing"
check "but it still stops the full clear" "$OUT_PRESS_BUSY" \
  "leaving the ceiling alone" "go clean"
# Without pressure too: a build running, plenty free, a 1GB ceiling - the idle halving
# still runs to the horizon floor, and only the clear stands down.
build_fixture "$WORK/gn"
OUT_BUSY_IDLE="$(GO_BUSY_OVERRIDE=1 go_ceiling_run "$WORK/gn" "$SCRIPT" 1)"
check "a running build does not stop the idle trims without pressure either" "$OUT_BUSY_IDLE" \
  "left: ./aa/fresh-d ./cc/h2-d $" "reaping nothing"
check "and still stops the full clear" "$OUT_BUSY_IDLE" \
  "leaving the ceiling alone" "go clean"

# --go-cache runs that section alone: no scratchpad sweep, no stamp.
build_fixture "$WORK/gg"
OUT_GO_ONLY="$(go_ceiling_fixture "$WORK/gg"; FREE_GB_OVERRIDE=26 PATH_PREFIX_OVERRIDE="$WORK/gg/gobin" _run "$WORK/gg" "$SCRIPT" --go-cache; ls "$WORK/gg/stamp" 2>&1)"
check "--go-cache trims the go cache under pressure" "$OUT_GO_ONLY" \
  "ceiling 3GB" "scratchpad"
check "--go-cache writes no stamp" "$OUT_GO_ONLY" "No such file"

# ---------------------------------------------------------------- mutations

# Each entry: label | sed program applied to a copy of the script | pattern that must
# appear in the mutant's output and does NOT appear in the baseline's.
mutate() {
  local label="$1" prog="$2" want="$3" runner="${4:-run}"
  local m="$WORK/mutant.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return; fi
  build_fixture "$WORK/m"
  local out; out="$("$runner" "$WORK/m" "$m")"
  if printf '%s' "$out" | grep -q "$want"; then
    pass "mutation caught: $label"
  else
    fail "mutation NOT caught: $label (expected /$want/ once the rule is broken)"
  fi
}

mutate "anonymous-only volume names" \
  's|^  \[ "${#1}" -eq 64 \] .*|  :|; s|^  case "$1" in \*\[!0-9a-f\]\*) return 1 ;; esac|  :|; s|^    \[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\[0-9a-f\]\*) ;;|    *) ;;|' \
  "volume WOULD be reaped: stima-ci-work-1"

mutate "a non-zero liveness verdict keeps the scratchpad" \
  's|^    if \[ "$rc" -ne 0 \]; then|    if false; then|' \
  "scratchpad WOULD be reaped: .*22222222-"

mutate "the idle window is checked before the gate" \
  's|^    if ! tree_is_idle "$d" "$((window \* 60))"; then|    if false; then|' \
  "scratchpad WOULD be reaped: .*44444444-"

mutate "only a session-id directory is a scratchpad" \
  's|^    if ! is_session_id "$sid"; then kept=$((kept + 1)); continue; fi|    :|' \
  "not-a-session"

mutate "a referenced volume is skipped" \
  's#^    if printf .*grep -Fxq .*#    :#' \
  "volume WOULD be reaped: $HEX_REFD"

mutate "the volume age gate" \
  's|^    if \[ -z "$created_epoch" \] \|\| \[ "$created_epoch" -ge "$cutoff" \]; then|    if false; then|' \
  "volume WOULD be reaped: $HEX_YOUNG"

# The split itself. Put the volume cutoff back on the scratchpad's knob and the volume
# knob stops deciding anything - which is an ABSENCE, so this one cannot go through
# mutate() and is written out the way the go-guard mutation below is.
M_VOL="$WORK/mutant-volage.sh"
sed 's|cutoff=$((now - DOCKER_VOLUME_AGE_HOURS \* 3600))|cutoff=$((now - IDLE_HOURS * 3600))|' "$SCRIPT" > "$M_VOL"
if cmp -s "$M_VOL" "$SCRIPT"; then
  fail "mutation the volume age has its own knob: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  if printf '%s' "$(VOLUME_AGE_OVERRIDE=1 run "$WORK/m" "$M_VOL")" \
       | grep -q "volume WOULD be reaped: $HEX_MID"; then
    fail "mutation NOT caught: the volume age has its own knob"
  else
    pass "mutation caught: the volume age has its own knob"
  fi
fi

# Its validation. The probe is -5 rather than `off` because `off` is caught by a DIFFERENT
# guard: set -u makes $((now - off * 3600)) an unbound-variable death, so an `off` mutant
# proves the refusal only by accident. -5 survives the arithmetic, which leaves the case
# block as the only thing standing between it and a cutoff in the future.
run_volage_bad() { VOLUME_AGE_OVERRIDE=-5 _run "$1" "$2" --dry-run; }
mutate "a bad volume age refuses instead of reaping on it" \
  's|BYPRODUCT_DOCKER_VOLUME_AGE_HOURS=$DOCKER_VOLUME_AGE_HOURS is not a whole number of hours below 100000; reaping nothing" >&2; exit 2|BYPRODUCT_DOCKER_VOLUME_AGE_HOURS is not a number; carrying on" >\&2|' \
  "volume WOULD be reaped: $HEX_MID" run_volage_bad

# The one guard left: the full clear waits for a running build. Its mutation runs against
# a BUSY ceiling run, so it needs its own runner.
M_GB="$WORK/mutant-gobusy.sh"
sed 's|^    if go_is_running; then|    if false; then|' "$SCRIPT" > "$M_GB"
if cmp -s "$M_GB" "$SCRIPT"; then
  fail "mutation the go guard blocks the clear: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  if printf '%s' "$(GO_BUSY_OVERRIDE=1 go_ceiling_run "$WORK/m" "$M_GB" 1)" | grep -q "go clean -cache"; then
    pass "mutation caught: the go guard blocks the clear"
  else
    fail "mutation NOT caught: the go guard blocks the clear"
  fi
fi

mutate "the ceiling trims by idleness before it empties the cache" \
  's|^        && \[ \$((GO_TRIM_MINUTES / 2)) -ge 180 \]; do|        \&\& false; do|' \
  "go clean -cache" run_ceiling_fits

mutate "the idle trim stops once the cache fits" \
  's|^  while \[ -n "\$after" \] && \[ "\$after" -ge "\$ceiling" \] 2>/dev/null \\$|  while [ -n "$after" ] \\|' \
  "idle over 270m" run_ceiling_fits

mutate "the idle horizon has a 180m floor" \
  's|\[ \$((GO_TRIM_MINUTES / 2)) -ge 180 \]|[ $((GO_TRIM_MINUTES / 2)) -ge 1 ]|' \
  "idle over 135m" run_ceiling_floor

mutate "emptying the cache names the cache it measured" \
  's|^    GOCACHE="\$GO_CACHE_DIR" go clean -cache|    go clean -cache|' \
  "go-stub: wrong GOCACHE" run_ceiling_floor

mutate "the go cache age gate" \
  's|-type f -mmin +"$GO_TRIM_MINUTES"|-type f|g' \
  "go cache WOULD trim 3 entr"

mutate "an image a container references is skipped" \
  's|^    if image_referenced .*|    :|' \
  "tagged image WOULD be reaped: apertis-prepared:inuse"

mutate "the tagged-image age gate" \
  's|^    if \[ -z "$created_e" \].*|    :|' \
  "tagged image WOULD be reaped: apertis-prepared:young"

mutate "only a disposable name opts a tagged image in" \
  's|^    if ! printf .*DISPOSABLE_IMAGE_RE.*|    :|' \
  "tagged image WOULD be reaped: postgres:17"

mutate "the go trim takes entries only" \
  's|-mindepth 2 -maxdepth 2 -path "$GO_CACHE_DIR/\[0-9a-f\]\[0-9a-f\]/\*" .*|-type f -mmin +"$GO_TRIM_MINUTES" "$@" 2>/dev/null|; /^    \\( -name .*-type f -mmin/d' \
  "go cache WOULD trim 6 entr"

mutate "the archive retention window" \
  's|^    if \[ -n "$("$FIND" "$d" -maxdepth 0 -mtime -"$ARCHIVE_DAYS" 2>/dev/null)" \]; then|    if false; then|' \
  "archive WOULD be reaped: .*$(date +%Y%m%d)"

# The symlink case has no fixture to mutate, so its mutation is on the script: put the
# unresolved path back and the stub suite is never reached.
M="$WORK/mutant-st.sh"
sed 's|"$REPO_HERE/../tests/reclaim-byproducts.sh"|"$HERE/../tests/reclaim-byproducts.sh"|' "$SCRIPT" > "$M"
if cmp -s "$M" "$SCRIPT"; then
  fail "mutation the self-test path is resolved: changed nothing (anchor is stale)"
else
  SCRIPT_SAVE="$SCRIPT"; SCRIPT="$M"
  OUT_STM="$(selftest_through_symlink)"
  SCRIPT="$SCRIPT_SAVE"
  if printf '%s' "$OUT_STM" | grep -q 'STUB-SUITE-RAN'; then
    fail "mutation NOT caught: the self-test path is resolved"
  else
    pass "mutation caught: the self-test path is resolved"
  fi
fi

mutate "the staleness gate suppresses a scheduled run" \
  's|^if \[ "$CHECK_STALE" -eq 1 \] && ran_recently; then|if false; then|' \
  "scratchpads:" run_stale_fresh

mutate "a hand-run is never gated" \
  's|^if \[ "$CHECK_STALE" -eq 1 \] && ran_recently; then|if ran_recently; then|' \
  "a reap completed less than" run_hand_fresh

mutate "a missing stamp is not recent" \
  's#^  \[ -f "$STAMP" \] || return 1#  [ -f "$STAMP" ] || return 0#' \
  "a reap completed less than" run_stale_absent

mutate "the stamp's age is measured, not assumed" \
  's|-mmin -"$MIN_MINUTES"|-mmin -999999|' \
  "a reap completed less than" run_stale_old

# Ignore the minutes and fall back on the hours, which is the gate the plist was written
# to override. At a 3h cadence that is the whole defect wearing the schedule's clothes.
run_minutes_3h() { MIN_MINUTES_OVERRIDE=90 run_stale_3h "$1" "$2"; }
mutate "the minutes window is read, not the hours" \
  's|MIN_MINUTES=$((10#$MIN_MINUTES_SET))|MIN_MINUTES=$((MIN_HOURS * 60))|' \
  "a reap completed less than" run_minutes_3h

# And a bad minutes value must fall back to the HOURS, not to some window of its own -
# the failure mode that reads as a working schedule while the gate it installed is not the
# one anybody configured. Mutated to one minute, which is a gate in name only.
run_minutes_bad() { MIN_MINUTES_OVERRIDE=off run_stale_3h "$1" "$2"; }
mutate "a bad minutes window falls back to the hours window" \
  's|MIN_MINUTES=$((MIN_HOURS \* 60)) ;;|MIN_MINUTES=1 ;;|' \
  "scratchpads:" run_minutes_bad

mutate "the stamp line does not speak for a process it cannot see" \
  's|a run with the same gate inside the next|a scheduled run inside the next|' \
  "a scheduled run inside the next" run_real

mutate "a dry run leaves no stamp" \
  's|^\[ "$DRY" -eq 1 \] \|\| write_stamp|write_stamp|' \
  "stamped "

mutate "a failed reap leaves no stamp" \
  's|^\[ "$FAILED" -eq 0 \] .*|:|' \
  "stamped " run_fail

# The three launchd mutations need the installer's fixture, not the reaper's.
install_mutant() {
  local label="$1" prog="$2" root="$3"
  local m="$WORK/mutant-launchd.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return 1; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return 1; fi
  install_fixture "$root" "$m"
  return 0
}

# Without RunAtLoad the agent still loads and still fires at 04:00 - and the first login
# after a reboot does nothing, which is the whole defect.
if install_mutant "RunAtLoad fires the agent when it loads" 's|  <key>RunAtLoad</key><true/>||' "$WORK/m1"; then
  run_install "$WORK/m1" >/dev/null
  if [ -e "$WORK/m1/stamp" ]; then
    fail "mutation NOT caught: RunAtLoad fires the agent when it loads"
  else
    pass "mutation caught: RunAtLoad fires the agent when it loads"
  fi
fi

# Without --if-stale in the scheduled arguments, RunAtLoad makes every `launchctl load`
# a full docker and Go-cache sweep.
if install_mutant "the scheduled agent runs --if-stale" 's|write_plist .<string>--if-stale</string>.|write_plist ""|' "$WORK/m2"; then
  run_install "$WORK/m2" >/dev/null
  : > "$(agent_logfile "$WORK/m2")"
  fire_load "$WORK/m2" >/dev/null
  if printf '%s' "$(agent_log "$WORK/m2")" | grep -q "scratchpads:"; then
    pass "mutation caught: the scheduled agent runs --if-stale"
  else
    fail "mutation NOT caught: the scheduled agent runs --if-stale"
  fi
fi

# And the probe must not be answerable by the stamp: given --if-stale on a machine that
# reaped an hour ago it would print a skip line, which is output, which the emptiness
# check would have taken for proof that the job runs.
if install_mutant "the install probe reaches the reapers" 's|write_plist .<string>--dry-run</string>.|write_plist "<string>--if-stale</string>"|' "$WORK/m3"; then
  : > "$WORK/m3/stamp"
  if printf '%s' "$(run_install "$WORK/m3")" | grep -q "never reached the reapers"; then
    pass "mutation caught: the install probe reaches the reapers"
  else
    fail "mutation NOT caught: the install probe reaches the reapers"
  fi
fi

# The interval schedule's two rules. Neither is visible in the reaper's output, so both
# are read off the installed agent - the first from the plist it wrote, the second from
# what that agent DID when the schedule fired.
if install_mutant "an interval schedule repeats on the interval" \
     's|schedule="  <key>StartInterval</key><integer>$((every \* 3600))</integer>"|schedule="  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer></dict>"|' \
     "$WORK/m7"; then
  run_install "$WORK/m7" 3h >/dev/null
  if grep -q '<key>StartInterval</key>' "$(agent_plist "$WORK/m7")" 2>/dev/null; then
    fail "mutation NOT caught: an interval schedule repeats on the interval"
  else
    pass "mutation caught: an interval schedule repeats on the interval"
  fi
fi

# The coupling. Drop the gate from the plist and the agent inherits the 12h default, so
# three firings in four print "skipping" and the 3h cadence quietly is not one.
if install_mutant "the interval plist carries a gate smaller than its period" \
     's|      gate_env="<key>BYPRODUCT_MIN_MINUTES</key><string>$((every \* 30))</string>"|      gate_env=""|' \
     "$WORK/m8"; then
  run_install "$WORK/m8" 3h >/dev/null
  touch -t "$THREE_H_AGO" "$WORK/m8/stamp"
  : > "$(agent_logfile "$WORK/m8")"
  fire_load "$WORK/m8" >/dev/null
  if printf '%s' "$(agent_log "$WORK/m8")" | grep -q "a reap completed less than"; then
    pass "mutation caught: the interval plist carries a gate smaller than its period"
  else
    fail "mutation NOT caught: the interval plist carries a gate smaller than its period"
  fi
fi

# The three launchd mutations above need a log that is complete when the installer reads
# it; these three need one that is not, which is a different stub.
delayed_mutant() {
  local label="$1" prog="$2" root="$3" tail_text="$4"
  local m="$WORK/mutant-probe.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return 1; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return 1; fi
  delayed_install_fixture "$root" "$m" "$tail_text"
  return 0
}

# The wait put back the way it shipped: stop as soon as the log is not empty. The verdict
# that follows is then rendered against one line, which is the whole defect.
if delayed_mutant "the probe waits for the summary, not for the first byte" \
     's|^    grep -q .scratchpads:. "$logf" 2>/dev/null && break$|    [ -s "$logf" ] \&\& break|' \
     "$WORK/m4" "scratchpads: 0 reaped, 5 kept"; then
  if printf '%s' "$(run_install "$WORK/m4")" | grep -q "never reached the reapers"; then
    pass "mutation caught: the probe waits for the summary, not for the first byte"
  else
    fail "mutation NOT caught: the probe waits for the summary, not for the first byte"
  fi
fi

# An inconclusive probe that removes the plist instead of putting it back is the outage.
if delayed_mutant "an inconclusive probe restores what was installed" \
     's|^      printf .*"$prev" > "$plist"$|      rm -f "$plist"|' "$WORK/m5" ""; then
  printf '%s\n' '<!-- SENTINEL-PREVIOUS-AGENT -->' > "$(agent_plist "$WORK/m5")"
  PROBE_SECONDS_OVERRIDE=2 run_install "$WORK/m5" >/dev/null
  if grep -q 'SENTINEL-PREVIOUS-AGENT' "$(agent_plist "$WORK/m5")" 2>/dev/null; then
    fail "mutation NOT caught: an inconclusive probe restores what was installed"
  else
    pass "mutation caught: an inconclusive probe restores what was installed"
  fi
fi

# And one that treats "no summary" as proof of a working job installs an agent nothing
# ever proved can run.
if delayed_mutant "a probe that did not finish decides nothing" \
     "s|^  if ! grep -q 'scratchpads:' \"\$logf\"; then$|  if false; then|" "$WORK/m6" ""; then
  PROBE_SECONDS_OVERRIDE=2 run_install "$WORK/m6" >/dev/null
  if [ -e "$(agent_plist "$WORK/m6")" ]; then
    pass "mutation caught: a probe that did not finish decides nothing"
  else
    fail "mutation NOT caught: a probe that did not finish decides nothing"
  fi
fi


# ------------------------------------------------- the ledger's mutations
#
# Four of the ledger's rules are ABSENCES - the line simply stops being printed - so they
# cannot go through mutate(), which asks what a mutant says. This asks what it stops
# saying, which is the same question from the only side these have.
ledger_gone() {
  local label="$1" prog="$2" want="$3" runner="${4:-run}"
  local m="$WORK/mutant-ledger.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return; fi
  build_fixture "$WORK/m"
  if printf '%s' "$("$runner" "$WORK/m" "$m")" | grep -q "$want"; then
    fail "mutation NOT caught: $label"
  else
    pass "mutation caught: $label"
  fi
}

ledger_gone "a sweep prints a timestamped header" \
  's|^log "== byproducts sweep started.*|:|' \
  "^== byproducts sweep started"

# The end line is a trap, so this is also the case that says why: with it gone, the five
# ways out of the sweep each end the log without a marker and without a total.
ledger_gone "a sweep prints an end line however it ends" \
  's|^trap sweep_ended EXIT|:|' \
  "^== byproducts sweep ended"

ledger_gone "the free-space delta is measured, not narrated" \
  's|^free_kb() .*|free_kb() { :; }|' \
  "free on .* -> .*GB ([-+][0-9.]*GB)"

ledger_gone "a section totals the bytes it took" \
  's|, $(freed_mb "$bytes")"$|"|' \
  "^scratchpads: .*would free"

# The ledger opens ABOVE the staleness gate. Below it, the one thing the log can never
# show is the schedule firing - which is the question it was added to answer.
ledger_gone "a firing that skips is recorded as a firing" \
  's|^log "== byproducts sweep started|[ "$CHECK_STALE" -eq 0 ] \&\& log "== byproducts sweep started|' \
  "== byproducts sweep started .* (scheduled," run_stale_fresh

# Rotation, both ways. Skip the copy and the previous generation is gone, which is the
# silent truncate the whole ledger exists to prevent; drop the size test and every sweep
# rotates, which throws away the history just as effectively, one sweep at a time.
rotation_mutant() {
  local label="$1" prog="$2" max="$3" pre="$4" root="$WORK/rot"
  local m="$WORK/mutant-rot.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return 1; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return 1; fi
  build_fixture "$root"
  ROTLOG="$root/home/.claude/logs/reclaim-byproducts.log"
  mkdir -p "$(dirname "$ROTLOG")"; rm -f "$ROTLOG.1"
  { printf '%s\n' "$pre"; head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$ROTLOG"
  LOG_MAX_OVERRIDE="$max" run "$root" "$m" >/dev/null
  return 0
}
if rotation_mutant "a rotation keeps the previous generation" \
     's|^  cp "$LOG_FILE" "$LOG_FILE.1".*|  :|' 2048 "OLD-SWEEP-SENTINEL"; then
  if grep -q 'OLD-SWEEP-SENTINEL' "$ROTLOG.1" 2>/dev/null; then
    fail "mutation NOT caught: a rotation keeps the previous generation"
  else
    pass "mutation caught: a rotation keeps the previous generation"
  fi
fi
if rotation_mutant "rotation happens only past the size cap" \
     's|^  \[ "$n" -gt "$LOG_MAX_BYTES" \] \|\| return 0|  :|' 999999999 "LIVE-SWEEP-SENTINEL"; then
  if [ -e "$ROTLOG.1" ]; then
    pass "mutation caught: rotation happens only past the size cap"
  else
    fail "mutation NOT caught: rotation happens only past the size cap"
  fi
fi

# ------------------------------------------------- the installer's mutations

# Put the installer back the way it shipped - rewrite and re-bootstrap unconditionally -
# and the plist's mtime moves and the log is truncated, which is the measured defect.
if install_mutant "installing what is already installed changes nothing" \
     's|^  if \[ -n "$prev" \] && \[ "$final" = "$prev" \].*|  if false; then|' "$WORK/m9"; then
  run_install "$WORK/m9" 3h >/dev/null
  M9_PLIST="$(agent_plist "$WORK/m9")"
  M9_BEFORE="$(stat -f '%Fm %z' "$M9_PLIST" 2>/dev/null)"
  printf 'EARLIER-SWEEP-SENTINEL\n' > "$(agent_logfile "$WORK/m9")"
  run_install "$WORK/m9" 3h >/dev/null
  if [ "$M9_BEFORE" = "$(stat -f '%Fm %z' "$M9_PLIST" 2>/dev/null)" ] \
     && grep -q 'EARLIER-SWEEP-SENTINEL' "$(agent_logfile "$WORK/m9")" 2>/dev/null; then
    fail "mutation NOT caught: installing what is already installed changes nothing"
  else
    pass "mutation caught: installing what is already installed changes nothing"
  fi
fi

# And the other half of that gate: an identical plist whose job is NOT loaded has to be
# installed. Drop the loaded check and the machine keeps a plist and no running agent.
if install_mutant "an unloaded job is installed even when its plist matches" \
     's|&& "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then|; then|' "$WORK/m10"; then
  run_install "$WORK/m10" 3h >/dev/null
  rm -f "$WORK/m10/home/.launchd-loaded"
  if printf '%s' "$(run_install "$WORK/m10" 3h)" | grep -q "nothing changed"; then
    pass "mutation caught: an unloaded job is installed even when its plist matches"
  else
    fail "mutation NOT caught: an unloaded job is installed even when its plist matches"
  fi
fi

# ------------------------------------------------- the cache reaper's mutations

# Every protected path is handed to the reaper as something to reap, so the refusal list
# is the only thing between them and an rm -rf. This is that list, removed.
run_protected() {
  DEAD_CACHES_OVERRIDE="$1/home/Library/Caches/CloudKit
$1/home/.cache/huggingface
$1/home/.cache/qmd
$1/home/Library/Caches/go-build" _run "$1" "$2" --dry-run
}
mutate "a protected cache is refused by name" \
  's|^cache_is_protected() {|cache_is_protected() { return 1;|' \
  "dead-application cache WOULD be reaped: .*CloudKit" run_protected

# The predicate the review found, put back: exact string match. Hand it the PARENT of a
# protected path - the edit the next dead application invites - and the rm -rf underneath
# takes the child. Not a synthetic mutation: this is what the file shipped with, and the
# four cases above were written red against it before it was changed.
M_CX="$WORK/mutant-cacheexact.sh"
sed -e 's|^    case "$p/" in "$c/"\*) return 0 ;; esac.*|    [ "$c" = "$p" ] \&\& return 0|' \
    -e 's|^    case "$c/" in "$p/"\*) return 0 ;; esac.*|    :|' "$SCRIPT" > "$M_CX"
if cmp -s "$M_CX" "$SCRIPT"; then
  fail "mutation an ancestor of a protected path is refused: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  DEAD_CACHES_OVERRIDE="$WORK/m/home/.cache" run_real "$WORK/m" "$M_CX" >/dev/null
  if [ -d "$WORK/m/home/.cache/qmd" ] && [ -d "$WORK/m/home/.cache/huggingface" ]; then
    fail "mutation NOT caught: an ancestor of a protected path is refused"
  else
    pass "mutation caught: an ancestor of a protected path is refused"
  fi
fi

# And the over-reach the fix could have been, once per direction. Drop a trailing
# separator and that comparison becomes a bare startswith, which refuses a real dead path
# for ever - the failure that looks like a reaper with nothing left to do.
starts_with_mutant() {
  local label="$1" prog="$2" dead="$3"
  local m="$WORK/mutant-cachestarts.sh"
  sed "$prog" "$SCRIPT" > "$m" || { fail "mutation $label: sed failed"; return; }
  if cmp -s "$m" "$SCRIPT"; then fail "mutation $label: changed nothing (anchor is stale)"; return; fi
  build_fixture "$WORK/m"
  DEAD_CACHES_OVERRIDE="$WORK/m/home/.cache/$dead" run_real "$WORK/m" "$m" >/dev/null
  if [ -d "$WORK/m/home/.cache/$dead" ]; then
    pass "mutation caught: $label"
  else
    fail "mutation NOT caught: $label"
  fi
}
# The list-side strip, which no case could reach until the seam above existed. Review put
# this exact mutation against the shipped commit and the suite answered 145/0.
M_LN="$WORK/mutant-listnorm.sh"
sed 's|^    while \[ "$p" != "${p%/}" \]; do p="${p%/}"; done|    :|' "$SCRIPT" > "$M_LN"
if cmp -s "$M_LN" "$SCRIPT"; then
  fail "mutation a list entry's trailing slash is stripped: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  mkdir -p "$WORK/m/home/.cache/listnorm/inside"
  EXTRA_NEVER_OVERRIDE="$WORK/m/home/.cache/listnorm/" \
    DEAD_CACHES_OVERRIDE="$WORK/m/home/.cache/listnorm/inside" run_real "$WORK/m" "$M_LN" >/dev/null
  if [ -d "$WORK/m/home/.cache/listnorm/inside" ]; then
    fail "mutation NOT caught: a list entry's trailing slash is stripped"
  else
    pass "mutation caught: a list entry's trailing slash is stripped"
  fi
fi

# And the seam's safety property, mutated into the substituting form it must never have:
# consult only the extra paths when they are set, and the four built-in refusals vanish
# for anybody who uses the knob.
M_SUB="$WORK/mutant-neversub.sh"
sed 's|^  done <<< "$CACHE_NEVER"|  done <<< "${BYPRODUCT_EXTRA_NEVER_CACHE_PATHS:-$CACHE_NEVER}"|' "$SCRIPT" > "$M_SUB"
if cmp -s "$M_SUB" "$SCRIPT"; then
  fail "mutation the extra paths widen rather than replace: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  EXTRA_NEVER_OVERRIDE="$WORK/m/home/.cache/listnorm" \
    DEAD_CACHES_OVERRIDE="$WORK/m/home/.cache/qmd" run_real "$WORK/m" "$M_SUB" >/dev/null
  if [ -d "$WORK/m/home/.cache/qmd" ]; then
    fail "mutation NOT caught: the extra paths widen rather than replace"
  else
    pass "mutation caught: the extra paths widen rather than replace"
  fi
fi

# The normalisation, which is the only thing deciding the ancestor-with-a-slash case: with
# it gone, `~/.cache//` matches nothing on the list and the rm -rf takes the children.
# Not askable on a protected path spelled with a slash - the "C is inside P" comparison
# tolerates that one by itself, so such a probe stays green with this deleted.
M_CN="$WORK/mutant-cachenorm.sh"
sed 's|^  while \[ "$c" != "${c%/}" \]; do c="${c%/}"; done|  :|' "$SCRIPT" > "$M_CN"
if cmp -s "$M_CN" "$SCRIPT"; then
  fail "mutation trailing slashes are normalised: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  DEAD_CACHES_OVERRIDE="$WORK/m/home/.cache//" run_real "$WORK/m" "$M_CN" >/dev/null
  if [ -d "$WORK/m/home/.cache/qmd" ]; then
    fail "mutation NOT caught: trailing slashes are normalised"
  else
    pass "mutation caught: trailing slashes are normalised"
  fi
fi

starts_with_mutant "a protected name starting with the candidate is not a match" \
  's|^    case "$p/" in "$c/"\*) return 0 ;; esac.*|    case "$p" in "$c"*) return 0 ;; esac|' qm
starts_with_mutant "a candidate starting with a protected name is not inside it" \
  's|^    case "$c/" in "$p/"\*) return 0 ;; esac.*|    case "$c" in "$p"*) return 0 ;; esac|' qmd-old

# --dry-run in the new section. The removal is reached by a path of its own, so the guard
# the other four reapers share proves nothing about this one.
M_CDRY="$WORK/mutant-cachedry.sh"
sed 's|^      log "dead-application cache WOULD be reaped: $p"|      rm -rf "$p" 2>/dev/null; log "dead-application cache WOULD be reaped: $p"|' "$SCRIPT" > "$M_CDRY"
if cmp -s "$M_CDRY" "$SCRIPT"; then
  fail "mutation --dry-run removes nothing in the cache section: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  run "$WORK/m" "$M_CDRY" >/dev/null
  if [ -d "$WORK/m/home/.cache/codex-runtimes" ]; then
    fail "mutation NOT caught: --dry-run removes nothing in the cache section"
  else
    pass "mutation caught: --dry-run removes nothing in the cache section"
  fi
fi

# A failure here must withhold the stamp exactly as one in the scratchpad reaper does.
run_cache_fail() {
  chmod 555 "$1/home/.cache"
  local out; out="$(_run "$1" "$2")"
  chmod 755 "$1/home/.cache"
  printf '%s' "$out"
}
mutate "a failed cache reap withholds the stamp" \
  's|      rm -rf "$p" 2>/dev/null \|\| { log "dead-application cache could not be removed: $p" >&2; FAILED=1; continue; }|      rm -rf "$p" 2>/dev/null \|\| { log "dead-application cache could not be removed: $p" >\&2; continue; }|' \
  "stamped " run_cache_fail

# And the reverse: an absent tool is a skip, so it must NOT withhold it. A machine without
# uv would otherwise never stamp, and every scheduled firing after it would re-sweep.
M_NOUV="$WORK/mutant-nouv.sh"
sed 's|^    log "caches: no ${UV} on PATH, pruned nothing"|    log "caches: no ${UV} on PATH, pruned nothing"; FAILED=1|' "$SCRIPT" > "$M_NOUV"
if cmp -s "$M_NOUV" "$SCRIPT"; then
  fail "mutation an absent tool is a skip, not a failure: changed nothing (anchor is stale)"
else
  build_fixture "$WORK/m"
  UV_OVERRIDE="$WORK/m/bin/no-such-uv" run_real "$WORK/m" "$M_NOUV" >/dev/null
  if [ -f "$WORK/m/stamp" ]; then
    fail "mutation NOT caught: an absent tool is a skip, not a failure"
  else
    pass "mutation caught: an absent tool is a skip, not a failure"
  fi
fi

# ------------------------------------------- scratchpads under disk pressure (2026-10-06)
#
# Two sessions idle for eight hours: past the 6h pressure window, inside the 24h one. One
# has a live Claude PID record (the test shell's own pid), one has none. The stub records
# the window path-in-use was asked with, so "the gate saw the shorter window" is askable.
pressure_fixture() {
  local root="$1" eight
  build_fixture "$root"
  eight="$(date -v-8H +%Y%m%d%H%M 2>/dev/null || date -d '8 hours ago' +%Y%m%d%H%M)"
  mkdir -p "$root/scratch/proj/55555555-5555-5555-5555-555555555555" \
           "$root/scratch/proj/66666666-6666-6666-6666-666666666666" "$root/home/.claude/sessions"
  touch -t "$eight" "$root/scratch/proj/55555555-5555-5555-5555-555555555555" \
                    "$root/scratch/proj/66666666-6666-6666-6666-666666666666"
  printf '{"pid":%s,"sessionId":"66666666-6666-6666-6666-666666666666"}\n' "$$" \
    > "$root/home/.claude/sessions/$$.json"
  cat > "$root/bin/path-in-use.sh" <<STUB
#!/usr/bin/env bash
printf '%s %s\\n' "\$1" "\${PATH_IN_USE_WINDOW_HOURS:-unset}" >> "$root/piu-calls"
echo "free      \$1"; exit 0
STUB
  chmod +x "$root/bin/path-in-use.sh"
}

pressure_fixture "$WORK/p"
OUT="$(run "$WORK/p" "$SCRIPT")"
check "without pressure an 8h-idle scratchpad is kept by the 24h window" "$OUT" \
  "scratchpad kept: .*55555555-.*touched within 24h" "WOULD be reaped: .*55555555-"

pressure_fixture "$WORK/p"
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
check "under pressure an 8h-idle scratchpad with no live record is reaped" "$OUT" \
  "scratchpad WOULD be reaped: .*55555555-"
check "under pressure a scratchpad with a live session record keeps the 24h window" "$OUT" \
  "scratchpad kept: .*66666666-.*touched within 24h" "WOULD be reaped: .*66666666-"
check "under pressure a scratchpad touched now is still kept" "$OUT" \
  "scratchpad kept: .*44444444-.*touched within 6h" "WOULD be reaped: .*44444444-"
check "the pressure tier says so in the log" "$OUT" \
  "scratchpads: disk pressure (free 10GB < 100GB): idle window 6h"
if grep -q "55555555-.* 6$" "$WORK/p/piu-calls" 2>/dev/null; then
  pass "path-in-use is asked with the pressure window"
else
  fail "path-in-use is asked with the pressure window: $(cat "$WORK/p/piu-calls" 2>/dev/null)"
fi

pressure_fixture "$WORK/p"
chmod 000 "$WORK/p/home/.claude/sessions"
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
chmod 755 "$WORK/p/home/.claude/sessions"
check "unreadable session records keep the 24h window for every scratchpad" "$OUT" \
  "could not be read; keeping the 24h window" "WOULD be reaped: .*55555555-"

pressure_fixture "$WORK/p"
printf 'not json\n' > "$WORK/p/home/.claude/sessions/1.json"
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
check "an unparseable session record keeps the 24h window" "$OUT" \
  "could not be read; keeping the 24h window" "WOULD be reaped: .*55555555-"

pressure_fixture "$WORK/p"
OUT="$(FREE_GB_OVERRIDE=10 BYPRODUCT_SCRATCH_PRESSURE_FREE_GB=0 run "$WORK/p" "$SCRIPT")"
check "a pressure threshold of 0 turns the tier off" "$OUT" \
  "scratchpad kept: .*55555555-.*touched within 24h" "WOULD be reaped: .*55555555-"

pressure_fixture "$WORK/p"
OUT="$(FREE_GB_OVERRIDE=10 BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS=six run "$WORK/p" "$SCRIPT")"
check "a non-numeric pressure window reaps nothing" "$OUT" \
  "BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS=six is not a whole number" "WOULD be reaped"

# A record whose pid is dead does not protect its session.
pressure_fixture "$WORK/p"
sleep 0 & deadpid=$!; wait "$deadpid" 2>/dev/null
printf '{"pid":%s,"sessionId":"55555555-5555-5555-5555-555555555555"}\n' "$deadpid" \
  > "$WORK/p/home/.claude/sessions/$deadpid.json"
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
check "a record whose pid is dead does not keep its scratchpad" "$OUT" \
  "scratchpad WOULD be reaped: .*55555555-"

# A resumed session: its record names the new id, its --session-id still names the old one.
pressure_fixture "$WORK/p"
bash -c 'sleep 120; :' 55555555-5555-5555-5555-555555555555 & argvpid=$!
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
kill "$argvpid" 2>/dev/null; wait "$argvpid" 2>/dev/null
check "a session id on a running command line keeps the 24h window" "$OUT" \
  "scratchpad kept: .*55555555-.*touched within 24h" "WOULD be reaped: .*55555555-"

# Claude is running but no live record exists: the record format moved, so trust nothing.
pressure_fixture "$WORK/p"
rm -f "$WORK/p/home/.claude/sessions/"*.json
OUT="$(FREE_GB_OVERRIDE=10 BYPRODUCT_CLAUDE_RUNNING=1 run "$WORK/p" "$SCRIPT")"
check "claude running with no live record keeps the 24h window" "$OUT" \
  "could not be read; keeping the 24h window" "WOULD be reaped: .*55555555-"
OUT="$(FREE_GB_OVERRIDE=10 BYPRODUCT_CLAUDE_RUNNING=0 run "$WORK/p" "$SCRIPT")"
check "no claude running and no record: the tier applies" "$OUT" \
  "scratchpad WOULD be reaped: .*55555555-"

# Only numeric names are records; another .json beside them is not read.
pressure_fixture "$WORK/p"
printf 'not json\n' > "$WORK/p/home/.claude/sessions/notes.json"
OUT="$(FREE_GB_OVERRIDE=10 run "$WORK/p" "$SCRIPT")"
check "a non-record json does not disable the tier" "$OUT" \
  "scratchpad WOULD be reaped: .*55555555-"

pressure_fixture "$WORK/p"
OUT="$(FREE_GB_OVERRIDE=10 BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS=0 run "$WORK/p" "$SCRIPT")"
check "a zero pressure window reaps nothing" "$OUT" \
  "BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS=0 is not a whole number" "WOULD be reaped"

echo
echo "passed: $PASSED, failed: $FAILURES"
[ "$FAILURES" -eq 0 ]
