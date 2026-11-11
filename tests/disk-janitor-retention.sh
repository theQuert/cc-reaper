#!/usr/bin/env bash
# TAP-style tests for the host retention rules in shell/disk-janitor.sh and
# shell/retention-helper.py (stima-api#7881).
#
# Every fixture lives in a mktemp directory; nothing outside it is read or removed, and the
# janitor runs with HOME pointed into it. Each safety property has a test, and each test has a
# mutant: the script and helper are copied, one exact string is replaced (the replacement must
# match once, so a stale anchor fails loudly), and the test must FAIL against the copy.
#
#   bash tests/disk-janitor-retention.sh            the cases and the mutants
#   bash tests/disk-janitor-retention.sh --no-mutants
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/shell"
failures=0
PIDS_FILE="$(mktemp)"
WORK="$(cd "$(mktemp -d)" && pwd -P)"

ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
  local p
  while IFS= read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$PIDS_FILE"
  rm -rf "$WORK" "$PIDS_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------- fixtures

mkstubs() {  # <dir>
  mkdir -p "$1"
  # df: only the `-Pk` shape the janitor uses; available KiB from FAKE_DF_AVAIL_KB.
  cat > "$1/df" <<'STUB'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk1s1 976490576 1000 %s 1%% /\n' "${FAKE_DF_AVAIL_KB:-10485760}"
STUB
  cat > "$1/go" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${GOCACHE:-unset}" "$*" >> "${GO_CALLS:?}"
exit 0
STUB
  cat > "$1/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_CALLS:?}"
[ "${GH_FAIL:-0}" = 1 ] && exit 1
cat "${GH_CLOSED:?}"
STUB
  cat > "$1/lsof-stub" <<'STUB'
#!/bin/sh
printf 'p1\nn/\n'
[ -r "${LSOF_EXTRA:-/nonexistent}" ] && cat "$LSOF_EXTRA"
exit 0
STUB
  chmod +x "$1/df" "$1/go" "$1/gh" "$1/lsof-stub"
}

begin() {  # sets T, FH and the env every case runs under
  T="$(cd "$(mktemp -d "$WORK/case.XXXXXX")" && pwd -P)"
  FH="$T/home"; mkdir -p "$FH" "$T/state" "$T/sessions" "$T/outside"
  mkstubs "$T/bin"
  : > "$T/go.calls"; : > "$T/gh.calls"; : > "$T/gh.closed"
  BASE_ENV=(HOME="$FH" PATH="$T/bin:$PATH" CC_DJ_CONFIG=/dev/null CC_DJ_LOG="$T/dj.log"
    CC_DJ_STATE_DIR="$T/state/" CC_DJ_SPOTCHECK_LOG="$T/spot.log" CC_DJ_SESSIONS_DIR="$T/sessions"
    CC_DJ_RET_GO_BUSY=0 CC_DJ_RET_LSOF="$T/bin/lsof-stub" CC_DJ_RET_GH="$T/bin/gh"
    GO_CALLS="$T/go.calls" GH_CALLS="$T/gh.calls" GH_CLOSED="$T/gh.closed"
    CC_DJ_RET_GCLOUD_MODE=off CC_DJ_RET_RELEASE_MODE=off CC_DJ_RET_SCRATCH_MODE=off
    CC_DJ_RET_PROJECTS_MODE=off CC_DJ_RET_GOCACHE_MODE=off CC_DJ_RET_EVIDENCE_MODE=off CC_DJ_RET_DEV_MODE=off
    CC_DJ_RET_GCLOUD_DIR="$T/none/gcloud" CC_DJ_RET_RELEASE_DIR="$T/none/release"
    CC_DJ_RET_SCRATCH_ROOT="$T/none/scratch" CC_DJ_RET_PROJECTS_DIR="$T/none/projects"
    CC_DJ_RET_GOCACHE_DIR="$T/none/gocache" CC_DJ_RET_HELMWAY_DIR="$T/none/helmway"
    CC_DJ_RET_HANDOFFS_DIR="$T/none/handoffs" CC_DJ_RET_CODEX_WORKTREES_DIR="$T/none/cwt"
    CC_DJ_RET_CODEX_ARCHIVED_DIR="$T/none/carch")
}

jr() { env "${BASE_ENV[@]}" "$@"; }       # jr K=V ... bash script args
run() { local sd="$1"; shift; jr "$@" bash "$sd/disk-janitor.sh" ${RUN_ARG:---retention} > "$T/out" 2>&1; }

# Sets the mtime of a path and everything under it to N days ago (deepest first).
age() {  # <path> <days>
  local stamp; stamp="$(date -v-"$2"d +%Y%m%d%H%M)"
  find "$1" -depth -exec touch -h -t "$stamp" {} +
}

has() { grep -q -- "$1" "$T/dj.log" && return 0; echo "  (log lacks: $1)"; grep "retention:" "$T/dj.log" | tail -4 | sed "s/^/    /"; return 1; }
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
spawn_sleeper() {  # prints a pid; the process lives until cleanup
  ( nohup sleep 600 >/dev/null 2>&1 & echo $! ) | tail -1 | tee -a "$PIDS_FILE"
}
write_session() {  # <pid> <session id> <cwd>
  printf '{"pid": %s, "sessionId": "%s", "cwd": "%s"}\n' "$1" "$2" "$3" > "$T/sessions/$1.json"
}
alive() { kill -0 "$1" 2>/dev/null; }

UUID_A=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa
UUID_B=bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb
UUID_C=cccccccc-3333-4333-8333-cccccccccccc
UUID_D=dddddddd-4444-4444-8444-dddddddddddd
UUID_E=eeeeeeee-5555-4555-8555-eeeeeeeeeeee
UUID_F=ffffffff-6666-4666-8666-ffffffffffff
UUID_G=99999999-7777-4777-8777-999999999999
UUID_H=88888888-8888-4888-8888-888888888888

# ---------------------------------------------------------------------------- the cases
# Each takes the directory holding the disk-janitor.sh and retention-helper.py under test and
# returns 0 when every property holds.

t_gcloud() {
  local sd="$1" L r=0
  begin; L="$T/gcloud/logs"
  mkdir -p "$L/2026.10.01" "$L/2026.11.11" "$L/2026.11.01"
  echo old > "$L/2026.10.01/a.log"; echo new > "$L/2026.11.11/b.log"; echo ten > "$L/2026.11.01/c.log"; echo keepme > "$T/outside/keep.txt"
  ln -s "$T/outside" "$L/linkdir"; ln -s "$T/outside/keep.txt" "$L/linkfile"
  age "$L/2026.10.01" 20; age "$L/2026.11.01" 10; age "$T/outside" 40
  # Shadow lists exactly the one real old file: a symlinked directory or file is not a candidate.
  run "$sd" CC_DJ_RET_GCLOUD_MODE=shadow CC_DJ_RET_GCLOUD_DIR="$L"
  has 'rule=gcloud-logs mode=shadow candidates=1 bytes=4 ' || { echo "  shadow count/bytes wrong"; r=1; }
  [ -f "$L/2026.10.01/a.log" ] || { echo "  shadow removed a file"; r=1; }
  run "$sd" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  has 'rule=gcloud-logs mode=apply candidates=1 bytes=4 .* removed=1' || { echo "  apply line wrong"; r=1; }
  [ ! -e "$L/2026.10.01/a.log" ] || { echo "  old file survived"; r=1; }
  [ ! -d "$L/2026.10.01" ] || { echo "  emptied dir survived"; r=1; }
  [ -f "$L/2026.11.11/b.log" ] && [ -f "$L/2026.11.01/c.log" ] || { echo "  a file younger than the window was removed"; r=1; }
  [ -f "$T/outside/keep.txt" ] || { echo "  file outside the root removed through a symlink"; r=1; }
  [ -L "$L/linkdir" ] && [ -L "$L/linkfile" ] || { echo "  symlink removed"; r=1; }
  : > "$T/dj.log"
  run "$sd" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  has 'candidates=0 bytes=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

t_gcloud_root_symlink() {
  local sd="$1" r=0
  begin
  mkdir -p "$T/real/logs"; echo old > "$T/real/logs/a.log"; age "$T/real/logs" 30
  ln -s "$T/real/logs" "$T/linked"
  run "$sd" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$T/linked"
  [ -f "$T/real/logs/a.log" ] || { echo "  a symlinked root was followed"; r=1; }
  has 'skipped: root .* is a symlink' || { echo "  no skip line"; r=1; }
  return $r
}

t_release() {
  local sd="$1" R i r=0
  begin; R="$T/rel"; mkdir -p "$R"
  for i in 1 2 3 4 5 6 7 8; do mkdir -p "$R/r$i"; echo x > "$R/r$i/f"; age "$R/r$i" $((i + 2)); done
  touch "$R/r8/fresh"; touch -t "$(date -v-10d +%Y%m%d%H%M)" "$R/r8"    # old dir, file inside modified now
  mkdir -p "$T/outside/rundir"; echo z > "$T/outside/rundir/f"; age "$T/outside" 30
  ln -s "$T/outside/rundir" "$R/linkrun"
  run "$sd" CC_DJ_RET_RELEASE_MODE=shadow CC_DJ_RET_RELEASE_DIR="$R"
  has 'rule=release-owner mode=shadow candidates=2 ' || { echo "  shadow should list r6 and r7 only"; r=1; }
  [ -d "$R/r6" ] || { echo "  shadow removed"; r=1; }
  run "$sd" CC_DJ_RET_RELEASE_MODE=apply CC_DJ_RET_RELEASE_DIR="$R"
  for i in 1 2 3 4 5; do [ -d "$R/r$i" ] || { echo "  r$i (newest five) removed"; r=1; }; done
  [ ! -d "$R/r6" ] && [ ! -d "$R/r7" ] || { echo "  r6/r7 survived"; r=1; }
  [ -d "$R/r8" ] || { echo "  a run modified inside 24 h was removed"; r=1; }
  [ -f "$T/outside/rundir/f" ] || { echo "  symlinked run followed"; r=1; }
  : > "$T/dj.log"; run "$sd" CC_DJ_RET_RELEASE_MODE=apply CC_DJ_RET_RELEASE_DIR="$R"
  has 'candidates=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

scratch_fixture() {  # builds T/tmp/claude-501 with one dir per verdict; sets S SL
  S="$T/tmp/claude-501"; P="$S/-Users-x-proj"; mkdir -p "$P" "$S/homepage"
  local u
  for u in $UUID_A $UUID_B $UUID_C $UUID_D $UUID_E $UUID_G; do mkdir -p "$P/$u/scratchpad"; echo data > "$P/$u/scratchpad/f"; done
  mkdir -p "$P/scratchpad" "$S/homepage/$UUID_F"; echo d > "$S/homepage/$UUID_F/f"; echo d > "$P/scratchpad/f"
  mkdir -p "$T/outside/uu"; echo keep > "$T/outside/uu/f"; ln -s "$T/outside/uu" "$P/$UUID_H"
  for u in $UUID_A $UUID_B $UUID_D $UUID_E $UUID_G; do age "$P/$u" 6; done
  age "$S/homepage" 6; age "$P/scratchpad" 6; age "$T/outside" 6
  touch "$P/$UUID_C/scratchpad/fresh"          # C: modified now
  # B: its session record names a live pid. D: a live process names it on its command line.
  # E: a process holds a file in it (lsof). G: nothing: the one that goes.
  local pid; pid="$(spawn_sleeper)"; write_session "$pid" "$UUID_B" "$T"
  ( nohup bash -c "exec -a 'claude --session-id $UUID_D' sleep 600" >/dev/null 2>&1 & echo $! >> "$PIDS_FILE" )
  printf 'n%s\n' "$P/$UUID_E/scratchpad/f" > "$T/lsof.extra"
  sleep 0.3
}

t_scratch() {
  local sd="$1" r=0 S P
  begin; scratch_fixture
  run "$sd" CC_DJ_RET_SCRATCH_MODE=apply CC_DJ_RET_SCRATCH_ROOT="$S" LSOF_EXTRA="$T/lsof.extra"
  [ ! -d "$P/$UUID_G" ] && [ ! -d "$P/$UUID_A" ] || { echo "  a dead old scratchpad survived"; r=1; }
  [ -d "$P/$UUID_B" ] || { echo "  a live session's scratchpad (record) was removed"; r=1; }
  [ -d "$P/$UUID_D" ] || { echo "  a live session's scratchpad (command line) was removed"; r=1; }
  [ -d "$P/$UUID_E" ] || { echo "  a held scratchpad was removed"; r=1; }
  [ -d "$P/$UUID_C" ] || { echo "  a recent scratchpad was removed"; r=1; }
  [ -d "$S/homepage/$UUID_F" ] || { echo "  a protected (homepage) scratchpad was removed"; r=1; }
  [ -d "$P/scratchpad" ] || { echo "  a directory that is not a session id was removed"; r=1; }
  [ -f "$T/outside/uu/f" ] || { echo "  a symlinked session directory was followed"; r=1; }
  has 'rule=scratchpads mode=apply candidates=2 .* removed=2 .*kept_live=2 kept_held=1 kept_protected=1 kept_recent=1' || { echo "  report line wrong"; r=1; }
  : > "$T/dj.log"; run "$sd" CC_DJ_RET_SCRATCH_MODE=apply CC_DJ_RET_SCRATCH_ROOT="$S" LSOF_EXTRA="$T/lsof.extra"
  has 'candidates=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

t_scratch_unknown_keeps() {
  local sd="$1" r=0 S P
  begin; scratch_fixture
  rm -rf "$T/sessions"        # the live-session records cannot be read: unknown means keep
  run "$sd" CC_DJ_RET_SCRATCH_MODE=apply CC_DJ_RET_SCRATCH_ROOT="$S" LSOF_EXTRA="$T/lsof.extra"
  [ -d "$P/$UUID_G" ] || { echo "  removed a scratchpad with live sessions unreadable"; r=1; }
  has 'rule=scratchpads skipped: live sessions cannot be read' || { echo "  no skip line"; r=1; }
  return $r
}

t_scratch_lsof_unknown_keeps() {
  local sd="$1" r=0 S P
  begin; scratch_fixture
  run "$sd" CC_DJ_RET_SCRATCH_MODE=apply CC_DJ_RET_SCRATCH_ROOT="$S" CC_DJ_RET_LSOF=/usr/bin/true
  [ -d "$P/$UUID_G" ] || { echo "  removed a scratchpad with lsof unusable"; r=1; }
  has 'rule=scratchpads skipped: lsof cannot report' || { echo "  no skip line"; r=1; }
  return $r
}

t_scratch_default_shadow() {
  local sd="$1" r=0 S P
  begin; scratch_fixture
  run "$sd" CC_DJ_RET_SCRATCH_MODE= CC_DJ_RET_SCRATCH_ROOT="$S" LSOF_EXTRA="$T/lsof.extra"
  [ -d "$P/$UUID_G" ] || { echo "  default mode removed (should be shadow)"; r=1; }
  has 'rule=scratchpads mode=shadow candidates=2 ' || { echo "  default is not shadow"; r=1; }
  return $r
}

projects_fixture() {  # sets B PR
  B="$T/gh"; PR="$T/proj"
  mkdir -p "$B/repo-worktrees/exists-one" "$B/repo-worktrees/exists-two/web/next" "$B/repo-worktrees/gone-old" "$PR" "$T/outside/pj"
  local n
  for n in "$B/repo-worktrees/gone-old" "$B/repo-worktrees/gone-recent" "$B/repo-worktrees/exists-one" "$B/repo-worktrees/exists-two/web/next" "$B/plain" "$B/gone-parent-worktrees/x"; do
    mkdir -p "$PR/$(enc "$n")"; echo transcript > "$PR/$(enc "$n")/s.jsonl"
  done
  rmdir "$B/repo-worktrees/gone-old" 2>/dev/null
  echo keep > "$T/outside/pj/f"; ln -s "$T/outside/pj" "$PR/$(enc "$B/repo-worktrees/gone-link")"
  age "$PR" 20; age "$T/outside" 20
  touch "$PR/$(enc "$B/repo-worktrees/gone-recent")/s.jsonl"
}

t_projects() {
  local sd="$1" r=0 B PR
  begin; projects_fixture
  run "$sd" CC_DJ_RET_PROJECTS_MODE=shadow CC_DJ_RET_PROJECTS_DIR="$PR"
  has 'rule=projects mode=shadow candidates=1 ' || { echo "  shadow should find only gone-old"; r=1; }
  [ -d "$PR/$(enc "$B/repo-worktrees/gone-old")" ] || { echo "  shadow removed"; r=1; }
  run "$sd" CC_DJ_RET_PROJECTS_MODE=apply CC_DJ_RET_PROJECTS_DIR="$PR"
  [ ! -d "$PR/$(enc "$B/repo-worktrees/gone-old")" ] || { echo "  gone worktree's transcripts survived"; r=1; }
  [ -d "$PR/$(enc "$B/repo-worktrees/gone-recent")" ] || { echo "  a recently written one was removed"; r=1; }
  [ -d "$PR/$(enc "$B/repo-worktrees/exists-one")" ] || { echo "  an existing worktree's transcripts removed"; r=1; }
  [ -d "$PR/$(enc "$B/repo-worktrees/exists-two/web/next")" ] || { echo "  a subdirectory of an existing worktree removed"; r=1; }
  [ -d "$PR/$(enc "$B/plain")" ] || { echo "  a non-worktree project removed"; r=1; }
  [ -d "$PR/$(enc "$B/gone-parent-worktrees/x")" ] || { echo "  unresolvable parent was not kept"; r=1; }
  [ -f "$T/outside/pj/f" ] || { echo "  a symlinked project dir was followed"; r=1; }
  : > "$T/dj.log"; run "$sd" CC_DJ_RET_PROJECTS_MODE=apply CC_DJ_RET_PROJECTS_DIR="$PR"
  has 'candidates=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

t_projects_default_shadow() {
  local sd="$1" r=0 B PR
  begin; projects_fixture
  run "$sd" CC_DJ_RET_PROJECTS_MODE= CC_DJ_RET_PROJECTS_DIR="$PR"
  [ -d "$PR/$(enc "$B/repo-worktrees/gone-old")" ] && has 'rule=projects mode=shadow candidates=1' || { echo "  default is not shadow"; r=1; }
  return $r
}

t_gocache() {
  local sd="$1" r=0 n
  begin; mkdir -p "$T/gocache/ab"; head -c 100000 /dev/zero > "$T/gocache/ab/entry"
  # Above the threshold (100 GB free, act at 40): nothing.
  run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=104857600
  [ ! -s "$T/go.calls" ] || { echo "  cleaned with plenty of free space"; r=1; }
  # The act threshold is CC_RW_DISK_ACT_GB: 10 GB free is not under 5.
  run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=10485760 CC_RW_DISK_ACT_GB=5
  [ ! -s "$T/go.calls" ] || { echo "  ignored CC_RW_DISK_ACT_GB"; r=1; }
  # Under it, but a go build is running.
  run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=10485760 CC_DJ_RET_GO_BUSY=1
  [ ! -s "$T/go.calls" ] || { echo "  cleaned under a running go build"; r=1; }
  # Report-only: bytes, no clean, no stamp.
  RUN_ARG=--retention-report run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=10485760
  [ ! -s "$T/go.calls" ] && [ ! -e "$T/state/retention-go-cache.stamp" ] || { echo "  report mode cleaned or stamped"; r=1; }
  has 'rule=go-cache mode=shadow candidates=1 bytes=[1-9]' || { echo "  report line has no bytes"; r=1; }
  # Under the threshold: one clean, with the cache dir named, and a stamp.
  run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=10485760
  n="$(wc -l < "$T/go.calls" | tr -d ' ')"
  [ "$n" = 1 ] && grep -q "^$T/gocache clean -cache" "$T/go.calls" || { echo "  expected one 'go clean -cache' on the cache dir, got $n"; r=1; }
  [ -e "$T/state/retention-go-cache.stamp" ] || { echo "  no stamp"; r=1; }
  # Second run the same day: the stamp holds it back.
  run "$sd" CC_DJ_RET_GOCACHE_MODE=apply CC_DJ_RET_GOCACHE_DIR="$T/gocache" FAKE_DF_AVAIL_KB=10485760
  n="$(wc -l < "$T/go.calls" | tr -d ' ')"
  [ "$n" = 1 ] || { echo "  cleaned twice in a day ($n)"; r=1; }
  return $r
}

t_evidence() {
  local sd="$1" r=0 H E calls
  begin; H="$T/handoffs"; E="$T/helm"
  mkdir -p "$H/i100-old" "$H/i200-open" "$H/i300-fresh" "$H/i400" "$H/notes" "$E/2026-10-01-a" "$E/2026-10-02-b" "$E/2026-10-03-c" "$E/2026-10-04-d" "$T/outside/ev"
  echo x > "$H/i100-old/f"; echo x > "$H/i200-open/f"; echo x > "$H/i300-fresh/f"; echo x > "$H/i400/f"; echo x > "$H/notes/f"; : > "$H/i999.md"
  mkdir -p "$E/2026-10-01-a/100-x" "$E/2026-10-02-b/100-x"; echo x > "$E/2026-10-01-a/100-x/f"; echo x > "$E/2026-10-02-b/100-x/f"; echo x > "$E/2026-10-02-b/200-y.md"
  echo x > "$E/2026-10-03-c/abc.txt"; echo '{"issue": 400}' > "$E/2026-10-04-d/manifest.json"
  echo keep > "$T/outside/ev/f"; ln -s "$T/outside/ev" "$H/i100-link"
  age "$H" 20; age "$E" 20; age "$T/outside" 20
  touch "$H/i300-fresh/new"
  printf '100\n300\n400\n' > "$T/gh.closed"
  # Shadow: everything stays, bytes are reported per directory.
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=shadow CC_DJ_RET_HELMWAY_DIR="$E" CC_DJ_RET_HANDOFFS_DIR="$H"
  [ -d "$H/i100-old" ] && [ -d "$E/2026-10-01-a" ] || { echo "  shadow removed"; r=1; }
  has 'rule=evidence mode=shadow candidates=4 bytes=[1-9]' || { echo "  shadow should list i100-old, i400, 2026-10-01-a, 2026-10-04-d"; r=1; }
  grep -q 'rule=evidence WOULD-REMOVE .*i100-old' "$T/spot.log" || { echo "  no per-directory line with the reason"; r=1; }
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HELMWAY_DIR="$E" CC_DJ_RET_HANDOFFS_DIR="$H"
  [ ! -d "$H/i100-old" ] && [ ! -d "$H/i400" ] && [ ! -d "$E/2026-10-01-a" ] && [ ! -d "$E/2026-10-04-d" ] || { echo "  closed and quiet directories survived"; r=1; }
  [ -d "$H/i200-open" ] || { echo "  an open issue's directory was removed"; r=1; }
  [ -d "$H/i300-fresh" ] || { echo "  a recently written directory was removed"; r=1; }
  [ -d "$E/2026-10-02-b" ] || { echo "  a directory naming an open issue as well was removed"; r=1; }
  [ -d "$E/2026-10-03-c" ] || { echo "  a directory naming no issue was removed"; r=1; }
  [ -d "$H/notes" ] && [ -e "$H/i999.md" ] || { echo "  something that is not an i<N> directory was removed"; r=1; }
  [ -f "$T/outside/ev/f" ] || { echo "  a symlinked directory was followed"; r=1; }
  calls="$(wc -l < "$T/gh.calls" | tr -d ' ')"
  [ "$calls" = 2 ] || { echo "  expected one gh read per run (2 runs), saw $calls"; r=1; }
  : > "$T/dj.log"; run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HELMWAY_DIR="$E" CC_DJ_RET_HANDOFFS_DIR="$H"
  has 'candidates=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

t_evidence_gh_failure() {
  local sd="$1" r=0 H
  begin; H="$T/handoffs"; mkdir -p "$H/i100"; echo x > "$H/i100/f"; age "$H" 20
  printf '100\n' > "$T/gh.closed"
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HANDOFFS_DIR="$H" GH_FAIL=1
  [ -d "$H/i100" ] || { echo "  removed a directory with the issue state unknown"; r=1; }
  has 'gh issue list failed' || { echo "  failure not logged"; r=1; }
  return $r
}

# A git worktree fixture built from plumbing only (no checkout, so the suite stays tiny): a repo
# whose main points at an empty-tree commit, and a linked worktree $T/wt/feat on its own branch.
dev_fixture() {  # sets REPO WT FEAT_SHA
  REPO="$T/repo"; WT="$T/wt/feat"
  local g="$REPO/.git" tree c1 c2 gd
  mkdir -p "$g/objects" "$g/refs/heads" "$WT"
  printf 'ref: refs/heads/main\n' > "$g/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' > "$g/config"
  tree="$(git --git-dir="$g" hash-object -t tree -w /dev/null)"
  c1="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git --git-dir="$g" commit-tree "$tree" -m base)"
  c2="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git --git-dir="$g" commit-tree "$tree" -p "$c1" -m work)"
  printf '%s\n' "$c1" > "$g/refs/heads/main"; printf '%s\n' "$c2" > "$g/refs/heads/feat"
  gd="$g/worktrees/feat"; mkdir -p "$gd"
  printf 'ref: refs/heads/feat\n' > "$gd/HEAD"; printf '../..\n' > "$gd/commondir"; printf '%s\n' "$WT/.git" > "$gd/gitdir"
  printf 'gitdir: %s\n' "$gd" > "$WT/.git"
  FEAT_SHA="$c2"
  echo f > "$WT/file"; age "$WT" 30; age "$REPO" 30
}
# The devprocs cases match on a unique marker, never on the default pattern: the machine running
# the suite has real `next dev` servers, and no case may be able to judge one of them.
MARK="retention-test-marker-$$"
spawn_dev() {  # <cwd> [trap-term]: a process that looks like `next dev`, reparented to launchd
  local pf="$T/pid.$RANDOM"
  ( cd "$1"; nohup bash -c "${2:+trap '' TERM;} echo \$\$ > '$pf'; exec -a 'node ./node_modules/.bin/next dev --port 1 $MARK' sleep 600" >/dev/null 2>&1 & )
  sleep 0.5; cat "$pf" | tee -a "$PIDS_FILE"
}
devrun() { run "$1" CC_DJ_RET_DEV_MODE="$2" CC_DJ_RET_DEV_MIN_AGE_HOURS="${AGE_H:-0}" CC_DJ_RET_DEV_GRACE_SECONDS=1 \
  CC_DJ_RET_DEV_BASE=main CC_DJ_RET_DEV_IDLE_DAYS=7 CC_DJ_RET_DEV_MATCH="$MARK"; }

t_dev() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  pid="$(spawn_dev "$WT")"
  devrun "$sd" shadow
  alive "$pid" || { echo "  shadow stopped the process"; r=1; }
  has "WOULD-STOP $pid pid=$pid .*cwd=$WT worktree=idle owner=dead" || { echo "  shadow line lacks cwd, state, owner"; r=1; }
  has 'rule=dev-processes mode=shadow candidates=1' || { echo "  shadow count wrong"; r=1; }
  devrun "$sd" apply; sleep 0.5
  alive "$pid" && { echo "  the dead-owner dev process was not stopped"; r=1; }
  return $r
}

t_dev_sigkill() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  pid="$(spawn_dev "$WT" ignore-term)"
  devrun "$sd" apply; sleep 0.5
  alive "$pid" && { echo "  a process ignoring SIGTERM survived the grace"; r=1; }
  return $r
}

t_dev_young_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  pid="$(spawn_dev "$WT")"
  AGE_H=999 devrun "$sd" apply
  alive "$pid" || { echo "  a process younger than the minimum age was stopped"; r=1; }
  return $r
}

t_dev_active_worktree_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"; touch "$WT/file"
  pid="$(spawn_dev "$WT")"
  devrun "$sd" apply
  alive "$pid" || { echo "  a process in an active, unmerged worktree was stopped"; r=1; }
  return $r
}

t_dev_merged_worktree_stops() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  printf '%s\n' "$FEAT_SHA" > "$REPO/.git/refs/heads/main"; touch "$WT/file"   # main moved up to feat: merged, and not idle
  pid="$(spawn_dev "$WT")"
  devrun "$sd" apply; sleep 0.5
  alive "$pid" && { echo "  a process in a merged worktree was not stopped"; r=1; }
  return $r
}

t_dev_primary_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  pid="$(spawn_dev "$REPO")"
  devrun "$sd" apply
  alive "$pid" || { echo "  a process in a primary checkout was stopped"; r=1; }
  return $r
}

t_dev_live_session_keeps() {
  local sd="$1" r=0 REPO WT pid sp
  begin; dev_fixture
  sp="$(spawn_sleeper)"; write_session "$sp" "$UUID_A" "$WT"      # a live session works in that worktree
  pid="$(spawn_dev "$WT")"
  devrun "$sd" apply
  alive "$pid" || { echo "  a process whose worktree has a live session was stopped"; r=1; }
  return $r
}

t_dev_claude_ancestor_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  cat > "$T/inner.sh" <<'EOS'
#!/bin/bash
(cd "$1" && exec -a "node ./node_modules/.bin/next dev --port 1 $3" sleep 600) &
echo $! > "$2"
wait
EOS
  ( nohup bash -c "exec -a claude bash '$T/inner.sh' '$WT' '$T/childpid' '$MARK'" >/dev/null 2>&1 & echo $! >> "$PIDS_FILE" )
  sleep 0.8; pid="$(cat "$T/childpid")"; echo "$pid" >> "$PIDS_FILE"
  devrun "$sd" apply
  alive "$pid" || { echo "  a process under a live claude ancestor was stopped"; r=1; }
  return $r
}

t_dev_never_kill_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; write_session "$$" "$UUID_A" "$T/elsewhere"
  pid="$(spawn_dev "$WT")"
  CC_NEVER_KILL_PIDS="$pid" devrun "$sd" apply
  alive "$pid" || { echo "  stopped a pid on CC_NEVER_KILL_PIDS"; r=1; }
  return $r
}

t_dev_unknown_keeps() {
  local sd="$1" r=0 REPO WT pid
  begin; dev_fixture; rm -rf "$T/sessions"       # no way to read the sessions: unknown means keep
  pid="$(spawn_dev "$WT")"
  devrun "$sd" apply
  alive "$pid" || { echo "  stopped a process with the owner unknown"; r=1; }
  return $r
}

t_dev_match_default() {
  local sd="$1" r=0 pat hpat
  begin
  pat="$(env HOME="$FH" CC_DJ_CONFIG=/dev/null bash -c '. "$1"; printf "%s" "$CC_DJ_RET_DEV_MATCH"' _ "$sd/disk-janitor.sh")"
  hpat="$(python3 -I - "$sd/retention-helper.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'"--match", default=r"(.*)"\)', src)
print(m.group(1) if m else "", end="")
PY
)"
  [ "$pat" = "$hpat" ] || { echo "  the script and helper default patterns differ"; r=1; }
  python3 -I - "$pat" <<'PY' || r=1
import re, sys
p = re.compile(sys.argv[1])
yes = ["node ./node_modules/.bin/next dev --hostname 127.0.0.1 --port 4117", "node proxy.mjs 5278 4495",
       "node /tmp/x/frameproxy.mjs 4496 4495", "next-server (v16.4.3)", "npm exec next dev -p 4140", "node /a/node_modules/.bin/vite --port 3"]
no = ["vim notes.txt", "claude --session-id x", "/bin/zsh -l", "node server.js", "git log --oneline"]
bad = [c for c in yes if not p.search(c)] + [c for c in no if p.search(c)]
if bad:
    print("  default pattern misjudges:", bad)
    sys.exit(1)
PY
  return $r
}

t_report_forces_shadow() {
  local sd="$1" r=0 L
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30
  RUN_ARG=--retention-report run "$sd" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  [ -f "$L/a.log" ] || { echo "  --retention-report deleted"; r=1; }
  has 'rule=gcloud-logs mode=shadow candidates=1 bytes=4 ' || { echo "  no byte report"; r=1; }
  return $r
}

t_bad_mode_is_shadow() {
  local sd="$1" r=0 L
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30
  run "$sd" CC_DJ_RET_GCLOUD_MODE=bogus CC_DJ_RET_GCLOUD_DIR="$L"
  [ -f "$L/a.log" ] || { echo "  an unknown mode deleted"; r=1; }
  return $r
}

t_defaults() {
  local sd="$1" r=0 out
  begin
  out="$(env HOME="$FH" CC_DJ_CONFIG=/dev/null bash -c 'unset CC_RW_DISK_ACT_GB; . "$1"; echo "$CC_DJ_RET_GCLOUD_MODE $CC_DJ_RET_RELEASE_MODE $CC_DJ_RET_GOCACHE_MODE $CC_DJ_RET_SCRATCH_MODE $CC_DJ_RET_PROJECTS_MODE $CC_DJ_RET_EVIDENCE_MODE $CC_DJ_RET_DEV_MODE $CC_DJ_RET_GOCACHE_ACT_GB $CC_DJ_RET_GCLOUD_DAYS $CC_DJ_RET_RELEASE_KEEP $CC_DJ_RET_SCRATCH_DAYS $CC_DJ_RET_PROJECTS_DAYS $CC_DJ_RET_EVIDENCE_DAYS $CC_DJ_RET_DEV_MIN_AGE_HOURS $CC_DJ_RET_CODEX_DAYS"' _ "$sd/disk-janitor.sh" 2>&1)"
  [ "$out" = "apply apply apply shadow shadow apply shadow 40 14 5 3 7 7 168 0" ] || { echo "  defaults are: $out"; r=1; }
  out="$(env HOME="$FH" CC_DJ_CONFIG=/dev/null CC_RW_DISK_ACT_GB=33 bash -c '. "$1"; echo "$CC_DJ_RET_GOCACHE_ACT_GB"' _ "$sd/disk-janitor.sh" 2>&1)"
  [ "$out" = 33 ] || { echo "  go-cache threshold does not follow CC_RW_DISK_ACT_GB ($out)"; r=1; }
  return $r
}

t_gcloud_default_apply() {
  local sd="$1" r=0 L
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30
  run "$sd" CC_DJ_RET_GCLOUD_MODE= CC_DJ_RET_GCLOUD_DIR="$L"
  [ ! -e "$L/a.log" ] || { echo "  the default mode for gcloud logs is not apply"; r=1; }
  return $r
}

t_remove_guards() {
  local sd="$1" r=0 root list
  begin; root="$T/root"; mkdir -p "$root/real" "$T/outside/d"; echo a > "$T/outside/d/f"; echo b > "$T/outside/loose"
  ln -s "$T/outside/d" "$root/linkdir"; ln -s "$T/outside/loose" "$root/linkfile"
  list="$T/list"; echo ok > "$root/real/ok"
  printf '%s\0' "$T/outside/loose" "$root/linkfile" "$root/linkdir/f" "$root/linkdir" "$root/real/ok" > "$list"
  # An empty root must be refused: a `${1:?}` that became empty would let "/?*" match anything.
  ( env HOME="$FH" CC_DJ_CONFIG=/dev/null CC_DJ_LOG="$T/dj.log" bash -c '. "$1"; _CC_DJ_RET_DEADLINE=999999; _cc_dj_ret_remove_list "" "$2" f' _ "$sd/disk-janitor.sh" "$list" ) >/dev/null 2>&1 && { echo "  an empty root was accepted"; r=1; }
  [ -f "$T/outside/loose" ] || { echo "  empty root removed an outside file"; r=1; }
  ( env HOME="$FH" CC_DJ_CONFIG=/dev/null CC_DJ_LOG="$T/dj.log" bash -c '. "$1"; _CC_DJ_RET_DEADLINE=999999; _cc_dj_ret_remove_list "$2" "$3" f' _ "$sd/disk-janitor.sh" "$root" "$list" ) >/dev/null 2>&1
  [ ! -e "$root/real/ok" ] || { echo "  the control file inside the root was not removed (the function did nothing)"; r=1; }
  [ -f "$T/outside/loose" ] || { echo "  removed a path outside the root"; r=1; }
  [ -L "$root/linkfile" ] || { echo "  removed a symlink"; r=1; }
  [ -f "$T/outside/d/f" ] || { echo "  removed through a symlinked directory"; r=1; }
  [ -L "$root/linkdir" ] || { echo "  removed a symlinked directory"; r=1; }
  has 'not inside the root' || { echo "  the outside path was not refused for being outside the root"; r=1; }
  return $r
}

# A rule root must be ours and closed to group and others: anyone who can write it can swap an
# entry for a symlink between the listing and the removal.
t_root_mode() {
  local sd="$1" r=0 L H E S P
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30; chmod 777 "$L"
  run "$sd" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  [ -f "$L/a.log" ] || { echo "  a mode-777 gcloud root was used"; r=1; }
  has 'rule=gcloud-logs skipped: root .* mode 777' || { echo "  no skip line (gcloud)"; r=1; }
  begin; scratch_fixture; chmod 777 "$S"
  run "$sd" CC_DJ_RET_SCRATCH_MODE=apply CC_DJ_RET_SCRATCH_ROOT="$S" LSOF_EXTRA="$T/lsof.extra"
  [ -d "$P/$UUID_G" ] || { echo "  a mode-777 scratch root was used"; r=1; }
  has 'rule=scratchpads skipped: root .* mode 777' || { echo "  no skip line (scratch)"; r=1; }
  begin; H="$T/handoffs"; mkdir -p "$H/i100"; echo x > "$H/i100/f"; age "$H" 20; printf '100\n' > "$T/gh.closed"; chmod 777 "$H"
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HANDOFFS_DIR="$H"
  [ -d "$H/i100" ] || { echo "  a mode-777 evidence root was used"; r=1; }
  begin; E="$T/handoffs"; mkdir -p "$E/i100"; echo x > "$E/i100/f"; age "$E" 20; printf '100\n' > "$T/gh.closed"; chmod 775 "$E"
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HANDOFFS_DIR="$E"
  [ -d "$E/i100" ] || { echo "  a group-writable evidence root was used"; r=1; }
  return $r
}

t_root_uid() {
  local sd="$1" r=0 L H other
  other=$(( $(id -u) + 1 ))
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30
  run "$sd" CC_DJ_RET_UID="$other" CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  [ -f "$L/a.log" ] || { echo "  a root owned by another uid was used (gcloud)"; r=1; }
  has 'rule=gcloud-logs skipped: root .* owned by uid' || { echo "  no skip line"; r=1; }
  begin; H="$T/handoffs"; mkdir -p "$H/i100"; echo x > "$H/i100/f"; age "$H" 20; printf '100\n' > "$T/gh.closed"
  run "$sd" CC_DJ_RET_UID="$other" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HANDOFFS_DIR="$H"
  [ -d "$H/i100" ] || { echo "  a root owned by another uid was used (evidence)"; r=1; }
  # Control: our own uid works.
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HANDOFFS_DIR="$H"
  [ ! -d "$H/i100" ] || { echo "  control: a root of our own uid was refused"; r=1; }
  return $r
}

# safe_rmtree itself, called directly: the walk is fd-relative and never follows a symlink.
t_safe_rmtree() {
  local sd="$1" r=0 R out
  begin; R="$T/r"
  mkdir -p "$R/a/b/leaf" "$T/out/leaf" "$T/r2"; echo f > "$R/a/b/leaf/f"; echo keep > "$T/out/leaf/f"
  ln -s "$T/out" "$R/lnk"; ln -s "$T/out/leaf" "$R/linkleaf"; chmod 755 "$R"
  echo keep > "$T/out/loose"; ln -s "$T/out/loose" "$R/linkfile"; echo p > "$R/plain"
  cat > "$T/unit.py" <<'PY'
import importlib.util, os, shutil, sys
spec = importlib.util.spec_from_file_location("rh", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mode, root, path = sys.argv[2:5]
if mode == "nofdsafe":
    shutil.rmtree.avoids_symlink_attacks = False
try:
    (m.safe_unlink if mode == "unlink" else m.safe_rmtree)(root, path)
    print("REMOVED")
except OSError as e:
    print("REFUSED", e)
PY
  u() { python3 -I "$T/unit.py" "$sd/retention-helper.py" "$@" 2>&1; }
  out="$(u normal "$R" "$R/lnk/leaf")"
  case "$out" in REFUSED*) ;; *) echo "  removed through a symlinked parent: $out"; r=1 ;; esac
  [ -f "$T/out/leaf/f" ] || { echo "  the file behind the symlinked parent is gone"; r=1; }
  out="$(u normal "$R" "$R/linkleaf")"
  case "$out" in REFUSED*) ;; *) echo "  removed a symlinked leaf: $out"; r=1 ;; esac
  [ -f "$T/out/leaf/f" ] || { echo "  the file behind the symlinked leaf is gone"; r=1; }
  out="$(u normal "$R" "$R/a/../../out/leaf")"
  case "$out" in REFUSED*) ;; *) echo "  followed a .. component: $out"; r=1 ;; esac
  [ -f "$T/out/leaf/f" ] || { echo "  the file reached through .. is gone"; r=1; }
  out="$(u normal "$R" "$T/out/leaf")"
  case "$out" in REFUSED*) ;; *) echo "  removed a path outside the root: $out"; r=1 ;; esac
  [ -f "$T/out/leaf/f" ] || { echo "  the path outside the root is gone"; r=1; }
  out="$(u nofdsafe "$R" "$R/a/b/leaf")"
  case "$out" in REFUSED*) ;; *) echo "  removed although shutil.rmtree is not symlink-attack safe: $out"; r=1 ;; esac
  [ -d "$R/a/b/leaf" ] || { echo "  removed with the unsafe rmtree"; r=1; }
  mkdir -p "$T/r2/x"; chmod 777 "$T/r2"
  out="$(u normal "$T/r2" "$T/r2/x")"
  case "$out" in REFUSED*) ;; *) echo "  removed under a mode-777 root: $out"; r=1 ;; esac
  [ -d "$T/r2/x" ] || { echo "  the mode-777 root's entry is gone"; r=1; }
  out="$(u unlink "$R" "$R/linkfile")"
  case "$out" in REFUSED*) ;; *) echo "  unlinked a symlink: $out"; r=1 ;; esac
  [ -L "$R/linkfile" ] && [ -f "$T/out/loose" ] || { echo "  the symlink or the file behind it is gone"; r=1; }
  out="$(u unlink "$R" "$R/a")"
  case "$out" in REFUSED*) ;; *) echo "  unlinked a directory: $out"; r=1 ;; esac
  out="$(u unlink "$R" "$R/lnk/loose")"
  case "$out" in REFUSED*) ;; *) echo "  unlinked through a symlinked parent: $out"; r=1 ;; esac
  [ -f "$T/out/loose" ] || { echo "  the file behind the symlinked parent is gone"; r=1; }
  out="$(u unlink "$R" "$R/plain")"
  [ "$out" = REMOVED ] && [ ! -e "$R/plain" ] || { echo "  control: a plain unlink failed: $out"; r=1; }
  out="$(u normal "$R" "$R/a/b/leaf")"
  [ "$out" = REMOVED ] && [ ! -d "$R/a/b/leaf" ] || { echo "  control: a plain removal failed: $out"; r=1; }
  return $r
}

# The parent of a listed path is swapped for a symlink after the listing: nothing outside is deleted.
t_swap_after_listing() {
  local sd="$1" r=0 root list
  begin; root="$T/root"; mkdir -p "$root/proj/$UUID_A" "$root/proj2/$UUID_B" "$T/outside/$UUID_A"
  echo in > "$root/proj/$UUID_A/f"; echo in > "$root/proj2/$UUID_B/f"; echo keep > "$T/outside/$UUID_A/f"; chmod 755 "$root"
  list="$T/list"; printf '%s\0' "$root/proj/$UUID_A" "$root/proj2/$UUID_B" > "$list"
  mv "$root/proj" "$T/proj.aside" && ln -s "$T/outside" "$root/proj"        # the swap, after the listing
  ( env HOME="$FH" CC_DJ_CONFIG=/dev/null CC_DJ_LOG="$T/dj.log" bash -c '. "$1"; _CC_DJ_RET_DEADLINE=999999; _cc_dj_ret_remove_list "$2" "$3" d' _ "$sd/disk-janitor.sh" "$root" "$list" ) >/dev/null 2>&1
  [ -f "$T/outside/$UUID_A/f" ] || { echo "  a parent swapped for a symlink redirected the delete outside the root"; r=1; }
  [ ! -d "$root/proj2/$UUID_B" ] || { echo "  control: an untouched listed path was not removed"; r=1; }
  has 'REFUSED' || { echo "  the refusal was not logged"; r=1; }
  return $r
}

# ~/.codex leftovers (the founder: 「codex相關的都去刪光」): no age; a worktree goes only when clean with
# every commit on a remote and no process in it; an archived session goes unless held or sqlite;
# nothing else under ~/.codex is a root. The repo is built from plumbing (see dev_fixture).
codex_fixture() {  # sets C (the codex home), M (the main repo's git dir), C1 (on origin/main), C2 (local only)
  C="$T/codex"; M="$T/mainrepo/.git"
  local tree id="GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t"
  mkdir -p "$M/objects" "$M/refs/heads" "$M/refs/remotes/origin" "$C/worktrees" "$C/archived_sessions" "$C/helmway-evidence" \
    "$C/packages/p" "$C/plugins/q" "$C/sessions"
  printf 'ref: refs/heads/main\n' > "$M/HEAD"
  # status.showUntrackedFiles = no: only an explicit -unormal makes `git status` see an untracked file.
  printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n[status]\n\tshowUntrackedFiles = no\n' > "$M/config"
  tree="$(git --git-dir="$M" hash-object -t tree -w /dev/null)"
  C1="$(env $id git --git-dir="$M" commit-tree "$tree" -m base)"
  C2="$(env $id git --git-dir="$M" commit-tree "$tree" -p "$C1" -m local-only)"
  printf '%s\n' "$C1" > "$M/refs/heads/main"; printf '%s\n' "$C1" > "$M/refs/remotes/origin/main"
  printf '%s\n' "$C2" > "$M/refs/heads/feat"
  echo '{}' > "$C/auth.json"; echo 'x = 1' > "$C/config.toml"; echo p > "$C/packages/p/f"; echo q > "$C/plugins/q/f"
  echo s > "$C/state.sqlite"; echo r > "$C/sessions/rollout.jsonl"
}
cwt() {  # <id> <HEAD file content>: a linked worktree $C/worktrees/<id>/repo
  local w="$C/worktrees/$1/repo" gd="$M/worktrees/$1"
  mkdir -p "$w" "$gd"
  printf '%s\n' "$2" > "$gd/HEAD"; printf '../..\n' > "$gd/commondir"; printf '%s\n' "$w/.git" > "$gd/gitdir"
  printf 'gitdir: %s\n' "$gd" > "$w/.git"
}
codexrun() { run "$1" CC_DJ_RET_EVIDENCE_MODE="$2" CC_DJ_RET_HELMWAY_DIR="$C/helmway-evidence" \
  CC_DJ_RET_CODEX_WORKTREES_DIR="$C/worktrees" CC_DJ_RET_CODEX_ARCHIVED_DIR="$C/archived_sessions" LSOF_EXTRA="$T/lsof.extra" "${@:3}"; }

t_codex() {
  local sd="$1" r=0 C M C1 C2 h x
  begin; codex_fixture; h="$C/helmway-evidence"; x="$C/archived_sessions"
  mkdir -p "$h/2026-11-01-a" "$h/2026-11-02-b" "$h/2026-11-03-c"
  mkdir -p "$h/2026-11-01-a/100-x"; echo x > "$h/2026-11-01-a/100-x/f"; echo x > "$h/2026-11-02-b/200-y.md"; echo x > "$h/2026-11-03-c/n.txt"
  cwt clean "$C1"; cwt ahead "ref: refs/heads/feat"; cwt dirty "$C1"; echo u > "$C/worktrees/dirty/repo/untracked"
  cwt held "$C1"; mkdir -p "$C/worktrees/nogit/repo"; echo x > "$C/worktrees/nogit/repo/f"
  echo a > "$x/a.jsonl"; echo h > "$x/held.jsonl"; echo s > "$x/state.sqlite"; echo w > "$x/state.sqlite-wal"
  mkdir -p "$x/dir1" "$x/dir2"; echo x > "$x/dir1/x.jsonl"; echo y > "$x/dir2/hist.sqlite"
  echo keep > "$T/outside/f"; ln -s "$T/outside" "$x/lnk"
  printf 'n%s\n' "$C/worktrees/held/repo" "$x/held.jsonl" > "$T/lsof.extra"
  printf '100\n' > "$T/gh.closed"
  # Shadow lists the four, with bytes and the reason, and removes nothing.
  codexrun "$sd" shadow
  [ -d "$C/worktrees/clean" ] && [ -f "$x/a.jsonl" ] && [ -d "$h/2026-11-01-a" ] || { echo "  shadow removed"; r=1; }
  has 'rule=evidence mode=shadow candidates=4 bytes=[1-9]' || { echo "  shadow should list helmway a, worktree clean, a.jsonl, dir1"; r=1; }
  grep -q 'rule=evidence WOULD-REMOVE .*/worktrees/clean [0-9]* clean, every commit is on a remote' "$T/spot.log" || { echo "  no per-worktree line with the reason"; r=1; }
  # The default mode is apply, and nothing is aged: the files above were written a moment ago.
  codexrun "$sd" ""
  [ ! -d "$h/2026-11-01-a" ] || { echo "  helmway-evidence of a closed issue survived (no age applies)"; r=1; }
  [ ! -d "$C/worktrees/clean" ] || { echo "  a clean worktree with every commit on a remote survived"; r=1; }
  [ ! -e "$x/a.jsonl" ] && [ ! -d "$x/dir1" ] || { echo "  archived sessions survived"; r=1; }
  [ -d "$h/2026-11-02-b" ] || { echo "  helmway-evidence of an open issue was removed"; r=1; }
  [ -d "$h/2026-11-03-c" ] || { echo "  helmway-evidence naming no issue was removed"; r=1; }
  [ -d "$C/worktrees/ahead" ] || { echo "  a worktree with a commit on no remote was removed"; r=1; }
  [ -f "$C/worktrees/dirty/repo/untracked" ] || { echo "  a dirty worktree was removed"; r=1; }
  [ -d "$C/worktrees/held" ] || { echo "  a worktree a process holds was removed"; r=1; }
  [ -d "$C/worktrees/nogit" ] || { echo "  an entry holding no git worktree was removed"; r=1; }
  [ -f "$x/held.jsonl" ] || { echo "  an archived session a process holds was removed"; r=1; }
  [ -f "$x/state.sqlite" ] && [ -f "$x/state.sqlite-wal" ] || { echo "  an sqlite file in archived_sessions was removed"; r=1; }
  [ -f "$x/dir2/hist.sqlite" ] || { echo "  a directory holding an sqlite file was removed"; r=1; }
  [ -L "$x/lnk" ] && [ -f "$T/outside/f" ] || { echo "  a symlink in archived_sessions was followed or removed"; r=1; }
  [ -f "$C/auth.json" ] && [ -f "$C/config.toml" ] && [ -f "$C/packages/p/f" ] && [ -f "$C/plugins/q/f" ] \
    && [ -f "$C/state.sqlite" ] && [ -f "$C/sessions/rollout.jsonl" ] || { echo "  something outside the three roots was touched"; r=1; }
  has 'rule=evidence mode=apply candidates=4 .* removed=4' || { echo "  apply report wrong"; r=1; }
  : > "$T/dj.log"; codexrun "$sd" ""
  has 'candidates=0 .* removed=0' || { echo "  second run is not a no-op"; r=1; }
  return $r
}

# lsof that cannot report means nothing in a worktree or an archived session can be called unheld.
t_codex_lsof_unknown_keeps() {
  local sd="$1" r=0 C M C1 C2
  begin; codex_fixture; cwt clean "$C1"; echo a > "$C/archived_sessions/a.jsonl"; : > "$T/lsof.extra"
  codexrun "$sd" apply CC_DJ_RET_LSOF=/usr/bin/true
  [ -d "$C/worktrees/clean" ] && [ -f "$C/archived_sessions/a.jsonl" ] || { echo "  removed with lsof unable to report"; r=1; }
  grep -q 'lsof cannot report open files; kept' "$T/spot.log" || { echo "  no KEEP line"; r=1; }
  codexrun "$sd" apply
  [ ! -d "$C/worktrees/clean" ] && [ ! -e "$C/archived_sessions/a.jsonl" ] || { echo "  control: not removed with a working lsof"; r=1; }
  return $r
}

# F1: a date-shaped name is not an issue number; i<N>, issue-<N> and #<N> are.
t_evidence_date_names() {
  local sd="$1" r=0 E
  begin; E="$T/helm"; mkdir -p "$E/2026-11-05-a" "$E/2026-11-06-b" "$E/2026-11-07-c" "$E/2026-11-08-d" "$E/2026-11-09-e"
  echo x > "$E/2026-11-05-a/2026-11-10T0930.log"; echo x > "$E/2026-11-05-a/2026-11-11.md"
  echo x > "$E/2026-11-06-b/i2026-11-10.md"; echo x > "$E/2026-11-06-b/#2026-11.md"; echo x > "$E/2026-11-06-b/i2026_11_10.md"
  echo x > "$E/2026-11-06-b/2026.11.10.md"
  echo x > "$E/2026-11-07-c/i2026.md"; echo x > "$E/2026-11-08-d/issue-2026.md"; echo x > "$E/2026-11-09-e/#2026.md"
  printf '2026\n' > "$T/gh.closed"
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HELMWAY_DIR="$E"
  [ -d "$E/2026-11-05-a" ] || { echo "  a directory holding only date-named files was removed (#2026 is closed)"; r=1; }
  [ -d "$E/2026-11-06-b" ] || { echo "  i2026-11-10 was read as issue #2026"; r=1; }
  [ ! -d "$E/2026-11-07-c" ] || { echo "  i<N> no longer names an issue"; r=1; }
  [ ! -d "$E/2026-11-08-d" ] || { echo "  issue-<N> no longer names an issue"; r=1; }
  [ ! -d "$E/2026-11-09-e" ] || { echo "  #<N> no longer names an issue"; r=1; }
  return $r
}

# I-3: a bare number counts only as <N>-<letter> (no leading zero), and in a file name it can keep a
# directory but never make one removable.
t_evidence_bare_numbers_keep() {
  local sd="$1" r=0 E d
  begin; E="$T/helm"
  for d in n1 n2 n3 n4 n5 n6; do mkdir -p "$E/2026-11-01-$d"; done
  echo x > "$E/2026-11-01-n1/notes.md"; echo x > "$E/2026-11-01-n1/0930.log"
  echo x > "$E/2026-11-01-n2/notes.md"; echo x > "$E/2026-11-01-n2/001.png"
  echo x > "$E/2026-11-01-n3/2026.md"; echo x > "$E/2026-11-01-n3/2026-Q4.md"
  echo x > "$E/2026-11-01-n4/404.html"
  mkdir -p "$E/2026-11-01-n5/0930-run" "$E/2026-11-01-n5/001-x"; echo x > "$E/2026-11-01-n5/0930-run/f"; echo x > "$E/2026-11-01-n5/001-x/f"
  mkdir -p "$E/2026-11-01-n6/404" "$E/2026-11-01-n6/500-1"; echo x > "$E/2026-11-01-n6/404/f"; echo x > "$E/2026-11-01-n6/500-1/f"
  mkdir -p "$E/2026-11-01-okdir/930-run" "$E/2026-11-01-okpre"; echo x > "$E/2026-11-01-okdir/930-run/f"; echo x > "$E/2026-11-01-okpre/i930-x.md"
  printf '930\n1\n2026\n404\n500\n' > "$T/gh.closed"
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HELMWAY_DIR="$E"
  [ -d "$E/2026-11-01-n1" ] || { echo "  notes.md + 0930.log was read as issue #930 and removed"; r=1; }
  [ -d "$E/2026-11-01-n2" ] || { echo "  001.png was read as issue #1 and removed"; r=1; }
  [ -d "$E/2026-11-01-n3" ] || { echo "  2026.md / 2026-Q4.md made a directory removable"; r=1; }
  [ -d "$E/2026-11-01-n4" ] || { echo "  404.html was read as issue #404 and removed"; r=1; }
  [ -d "$E/2026-11-01-n5" ] || { echo "  a leading-zero bare number was read as an issue"; r=1; }
  [ -d "$E/2026-11-01-n6" ] || { echo "  a bare number with no letter after it (404/, 500-1/) was read as an issue"; r=1; }
  [ ! -d "$E/2026-11-01-okdir" ] || { echo "  control: a bare <N>-slug directory of a closed issue did not remove"; r=1; }
  [ ! -d "$E/2026-11-01-okpre" ] || { echo "  control: i<N> of a closed issue did not remove"; r=1; }
  return $r
}

# I-1: the real layout is <date>-<kind>/<N>-<slug>/; a bare <N>-slug entry names an issue.
t_evidence_bare_names() {
  local sd="$1" r=0 E
  begin; E="$T/helm"; mkdir -p "$E/2026-10-31-quality/6125-pg-envelope" "$E/2026-10-31-mixed/6126-other" "$E/2026-10-31-both/6125-pg-envelope"
  echo x > "$E/2026-10-31-quality/6125-pg-envelope/f"; echo x > "$E/2026-10-31-quality/2026-11-10T0930.log"
  echo x > "$E/2026-10-31-mixed/6126-other/f"; echo '{"issue": 6125}' > "$E/2026-10-31-mixed/manifest.json"
  echo x > "$E/2026-10-31-both/6125-pg-envelope/f"; echo x > "$E/2026-10-31-both/6126-other.md"
  printf '6125\n' > "$T/gh.closed"            # #6125 closed, #6126 open; a year is not an issue
  run "$sd" CC_DJ_RET_EVIDENCE_MODE=apply CC_DJ_RET_HELMWAY_DIR="$E"
  [ ! -d "$E/2026-10-31-quality" ] || { echo "  6125-pg-envelope plus a date-named log did not read as #6125 only"; r=1; }
  [ -d "$E/2026-10-31-mixed" ] || { echo "  a manifest naming a closed issue plus a bare entry for an open one was removed"; r=1; }
  [ -d "$E/2026-10-31-both" ] || { echo "  a bare <N>-slug entry for an open issue did not keep the directory"; r=1; }
  return $r
}

# F2: CC_DJ_RET_CODEX_DAYS applies to every ~/.codex root, by the entry's newest mtime.
t_codex_days() {
  local sd="$1" r=0 C M C1 C2 h x
  begin; codex_fixture; h="$C/helmway-evidence"; x="$C/archived_sessions"
  mkdir -p "$h/2026-11-01-old" "$h/2026-11-02-new"; echo x > "$h/2026-11-01-old/i100-x.md"; echo x > "$h/2026-11-02-new/i100-x.md"
  cwt oldwt "$C1"; cwt newwt "$C1"; echo a > "$x/old.jsonl"; echo b > "$x/new.jsonl"
  age "$h/2026-11-01-old" 40; age "$C/worktrees/oldwt" 40; age "$x/old.jsonl" 40
  printf '100\n' > "$T/gh.closed"; : > "$T/lsof.extra"
  # EVIDENCE_DAYS is larger than the age of the old entries: only CODEX_DAYS can let them go.
  codexrun "$sd" apply CC_DJ_RET_CODEX_DAYS=30 CC_DJ_RET_EVIDENCE_DAYS=100
  [ ! -d "$h/2026-11-01-old" ] && [ ! -d "$C/worktrees/oldwt" ] && [ ! -e "$x/old.jsonl" ] || { echo "  an entry older than CODEX_DAYS survived"; r=1; }
  [ -d "$h/2026-11-02-new" ] || { echo "  a fresh helmway-evidence dir was removed"; r=1; }
  [ -d "$C/worktrees/newwt" ] || { echo "  a fresh worktree was removed"; r=1; }
  [ -f "$x/new.jsonl" ] || { echo "  a fresh archived session was removed"; r=1; }
  grep -q 'KEEP .*newwt 0 newest file inside is younger than 30 days' "$T/spot.log" || { echo "  no KEEP line with the age reason"; r=1; }
  return $r
}

# F3: the shapes a codex <id> directory can take.
cwt_full() {  # <id> <HEAD content>: a full clone $C/worktrees/<id>/repo: .git is a directory with the main repo's objects and refs
  local w="$C/worktrees/$1/repo"
  mkdir -p "$w/.git"; cp -R "$M/objects" "$M/refs" "$M/config" "$w/.git/"
  rm -f "$w/.git/refs/heads/feat"; printf '%s\n' "$2" > "$w/.git/HEAD"
}
t_codex_worktree_shapes() {
  local sd="$1" r=0 C M C1 C2 w
  begin; codex_fixture; : > "$T/lsof.extra"; printf '100\n' > "$T/gh.closed"
  cwt_full fullok "ref: refs/heads/main"
  cwt_full fullahead "ref: refs/heads/main"; printf '%s\n' "$C2" > "$C/worktrees/fullahead/repo/.git/refs/heads/feat"
  cwt_full fullstash "ref: refs/heads/main"; w="$C/worktrees/fullstash/repo/.git"
  printf '%s\n' "$C1" > "$w/refs/stash"; mkdir -p "$w/logs/refs"
  printf '%s %s t <t@t> 1700000000 +0000\tWIP\n' 0000000000000000000000000000000000000000 "$C1" > "$w/logs/refs/stash"
  cwt sib "$C1"; echo x > "$C/worktrees/sib/notes.txt"
  codexrun "$sd" apply
  [ ! -d "$C/worktrees/fullok" ] || { echo "  a clean full clone with every ref on a remote survived"; r=1; }
  [ -d "$C/worktrees/fullahead" ] || { echo "  a full clone with a local-only branch was removed"; r=1; }
  [ -d "$C/worktrees/fullstash" ] || { echo "  a full clone with a stash was removed"; r=1; }
  [ -d "$C/worktrees/sib" ] || { echo "  an <id> directory with a non-git sibling was removed"; r=1; }
  grep -q 'KEEP .*worktrees/sib 0 .*notes.txt is not a git worktree' "$T/spot.log" || { echo "  no KEEP line naming the sibling"; r=1; }
  return $r
}

# I-2: when the <id> directory is itself a worktree, a repository nested in a child is still judged.
t_codex_nested_repo() {
  local sd="$1" r=0 C M C1 C2 id sub
  begin; codex_fixture; : > "$T/lsof.extra"; printf '100\n' > "$T/gh.closed"
  mkdir -p "$M/info"; printf 'sub/\n' > "$M/info/exclude"          # the outer worktree ignores the nested repo
  for id in nestahead nestok; do
    mkdir -p "$M/worktrees/$id" "$C/worktrees/$id"
    printf '%s\n' "$C1" > "$M/worktrees/$id/HEAD"; printf '../..\n' > "$M/worktrees/$id/commondir"
    printf '%s\n' "$C/worktrees/$id/.git" > "$M/worktrees/$id/gitdir"; printf 'gitdir: %s\n' "$M/worktrees/$id" > "$C/worktrees/$id/.git"
    sub="$C/worktrees/$id/sub/.git"; mkdir -p "$sub"; cp -R "$M/objects" "$M/refs" "$M/config" "$sub/"
    rm -f "$sub/refs/heads/feat"; printf 'ref: refs/heads/main\n' > "$sub/HEAD"
  done
  printf '%s\n' "$C2" > "$C/worktrees/nestahead/sub/.git/refs/heads/feat"       # a commit on no remote, inside the nested repo
  codexrun "$sd" apply
  [ -d "$C/worktrees/nestahead" ] || { echo "  a worktree with an unpushed commit in a nested repository was removed"; r=1; }
  [ ! -d "$C/worktrees/nestok" ] || { echo "  control: a worktree whose nested repository is on a remote survived"; r=1; }
  return $r
}

t_wired_into_check() {
  local sd="$1"
  awk '/^_cc_dj_check\(\)/{f=1} f && /^  _cc_dj_retention$/{found=1} f && /^}/{exit} END{exit !found}' "$sd/disk-janitor.sh"
}

t_retention_off() {
  local sd="$1" r=0 L
  begin; L="$T/gcloud/logs"; mkdir -p "$L"; echo old > "$L/a.log"; age "$L" 30
  run "$sd" CC_DJ_RETENTION=off CC_DJ_RET_GCLOUD_MODE=apply CC_DJ_RET_GCLOUD_DIR="$L"
  [ -f "$L/a.log" ] || { echo "  CC_DJ_RETENTION=off still deleted"; r=1; }
  return $r
}

CASES="t_gcloud t_gcloud_root_symlink t_gcloud_default_apply t_release t_scratch t_scratch_unknown_keeps
t_scratch_lsof_unknown_keeps t_scratch_default_shadow t_projects t_projects_default_shadow t_gocache
t_evidence t_evidence_gh_failure t_dev t_dev_sigkill t_dev_young_keeps t_dev_active_worktree_keeps
t_dev_merged_worktree_stops t_dev_primary_keeps t_dev_live_session_keeps t_dev_claude_ancestor_keeps
t_dev_never_kill_keeps t_dev_unknown_keeps t_dev_match_default t_report_forces_shadow t_bad_mode_is_shadow t_defaults t_remove_guards
t_wired_into_check t_retention_off t_root_mode t_root_uid t_safe_rmtree t_swap_after_listing t_codex t_codex_lsof_unknown_keeps t_evidence_date_names t_codex_days t_codex_worktree_shapes t_evidence_bare_names t_evidence_bare_numbers_keep t_codex_nested_repo"

for c in $CASES; do
  if "$c" "$SRC"; then ok "$c"; else nok "$c"; fi
done

# ---------------------------------------------------------------------------- mutants

[ "${1:-}" = --no-mutants ] && { echo "1..$((failures))"; [ "$failures" -eq 0 ]; exit; }

mutant() {  # <label> <file> <old> <new> <case...>
  local label="$1" file="$2" old="$3" new="$4" dir rc=0 c; shift 4
  # M2_OLD/M2_NEW: a second replacement in the same file, for a guard backed by a second layer.
  dir="$(mktemp -d "$WORK/mut.XXXXXX")"
  cp "$SRC/disk-janitor.sh" "$SRC/retention-helper.py" "$dir/"
  if ! python3 - "$dir/$file" "$old" "$new" "${M2_OLD:-}" "${M2_NEW:-}" <<'PY'
import sys
p, old, new, old2, new2 = sys.argv[1:6]
s = open(p).read()
for o, n in ((old, new), (old2, new2)):
    if not o:
        continue
    if s.count(o) != 1:
        sys.exit(1)
    s = s.replace(o, n)
open(p, "w").write(s)
PY
  then nok "mutant $label: anchor not found exactly once"; return; fi
  for c in "$@"; do
    if "$c" "$dir" >/dev/null 2>&1; then
      nok "mutant NOT caught: $label (case $c still passes)"; rc=1
    fi
  done
  [ "$rc" -eq 0 ] && ok "mutant caught: $label"
  return 0
}

J=disk-janitor.sh; H=retention-helper.py

# 1 gcloud: age window, symlinks, mode
mutant "gcloud: any age is old enough" $J '-type f -mmin +"$((days * 1440))" -print0' '-type f -mmin +0 -print0' t_gcloud
mutant "gcloud: find follows symlinks" $J 'find "$root" -type f -mmin' 'find -L "$root" -type f -mmin' t_gcloud
mutant "gcloud: default mode is shadow" $J 'CC_DJ_RET_GCLOUD_MODE:-apply' 'CC_DJ_RET_GCLOUD_MODE:-shadow' t_gcloud_default_apply t_defaults
mutant "root symlink is followed" $J 'if [ -L "$dir" ]; then _cc_dj_log "retention: rule=$rule skipped: root $dir is a symlink"; return 1; fi' ':' t_gcloud_root_symlink
# 2 release-owner
mutant "release: keeps none of the newest" $J '[ "$i" -gt "$keep" ] || continue' '[ "$i" -gt 0 ] || continue' t_release
mutant "release: ignores the 24 h guard" $J '[ -z "$recent" ] || continue' ': "$recent"' t_release
mutant "release: lists symlinked run dirs" $J 'find "$root" -mindepth 1 -maxdepth 1 -type d -print0' 'find -L "$root" -mindepth 1 -maxdepth 1 -type d -print0' t_release
# 3 scratchpads
mutant "scratch: live session ignored" $J 'if printf '"'"'%s\n'"'"' "$live" | grep -qxF -- "$sid"; then' 'if false; then' t_scratch
mutant "scratch: holder ignored" $J 'if grep -qxF -- "n$p" "$snap" || grep -qF -- "n$p/" "$snap"; then' 'if false; then' t_scratch
mutant "scratch: protected names ignored" $J 'if _cc_dj_protected_tree "$p" >/dev/null; then' 'if false; then' t_scratch
mutant "scratch: unreadable sessions do not keep" $J 'if ! live="$(_cc_dj_ret_live_ids 2>/dev/null)"; then' 'if ! live="$(_cc_dj_ret_live_ids 2>/dev/null)" && false; then' t_scratch_unknown_keeps
mutant "scratch: unusable lsof does not keep" $J ' || ! grep -q '"'"'^n/'"'"' "$snap"; then' '; then' t_scratch_lsof_unknown_keeps
mutant "scratch: age window ignored" $J 'find "$p" -mmin -"$((days * 1440))" -print -quit' 'find "$p" -mmin -0 -print -quit' t_scratch
mutant "scratch: default mode is apply" $J 'CC_DJ_RET_SCRATCH_MODE:-shadow' 'CC_DJ_RET_SCRATCH_MODE:-apply' t_scratch_default_shadow t_defaults
# 4 projects
mutant "projects: recent files do not keep" $H 'if newest_within(d, days * 86400):' 'if False:' t_projects
mutant "projects: existing worktree does not keep" $H '                if leaf == e or leaf.startswith(e + "-"):' '                if False:' t_projects
mutant "projects: unresolvable parent does not keep" $H 'if not resolved_any:' 'if False:' t_projects
mutant "projects: default mode is apply" $J 'CC_DJ_RET_PROJECTS_MODE:-shadow' 'CC_DJ_RET_PROJECTS_MODE:-apply' t_projects_default_shadow t_defaults
# 5 go cache
mutant "go-cache: no free-space threshold" $J 'if [ "$free_kb" -ge $(( act_gb * 1048576 )) ]; then' 'if false; then' t_gocache
mutant "go-cache: no stamp" $J 'if [ "$rc" -eq 0 ]; then touch "$stamp"; detail' 'if [ "$rc" -eq 0 ]; then : ; detail' t_gocache
mutant "go-cache: ignores a running build" $J '1) _cc_dj_ret_report go-cache "$mode" 0 0 0 "a go build or test is running; not cleaning (cache_bytes=$bytes)"; return 0 ;;' '1) ;;' t_gocache
mutant "go-cache: threshold ignores CC_RW_DISK_ACT_GB" $J 'CC_DJ_RET_GOCACHE_ACT_GB:-${CC_RW_DISK_ACT_GB:-40}' 'CC_DJ_RET_GOCACHE_ACT_GB:-40' t_gocache t_defaults
# 6 evidence
mutant "evidence: open issue does not keep" $H '        if still:' '        if False:' t_evidence
mutant "evidence: a directory naming no issue goes" $H '        if not strong:' '        if False:' t_evidence t_evidence_bare_numbers_keep
mutant "evidence: recent files do not keep" $H '                if days_of(kind) > 0 and newest_within(p, days_of(kind) * 86400):' '                if False:' t_evidence
mutant "evidence: unknown issue state counts as closed" $H 'closed = closed_issues(a.repo, a.gh, a.limit)' 'closed = closed_issues(a.repo, a.gh, a.limit) or set(range(10**6))' t_evidence_gh_failure
mutant "evidence: default mode is shadow" $J 'CC_DJ_RET_EVIDENCE_MODE:-apply' 'CC_DJ_RET_EVIDENCE_MODE:-shadow' t_codex t_defaults
# F1 issue names
mutant "evidence: the old entry regex reads a date as an issue" $H 'ENTRY_ISSUE = re.compile(r"^(?:i|issue-?|#)" + _NUM)' 'ENTRY_ISSUE = re.compile(r"^(?:i)?(\d{3,6})(?:[-_.]|$)")' t_evidence_date_names
mutant "evidence: a date counts as a number" $H '_NOT_DATE = r"(?!(?:19|20)\d{2}[-_.](?:0[1-9]|1[0-2])(?!\d))"' '_NOT_DATE = r""' t_evidence_date_names
mutant "evidence: #<N> and issue-<N> are not names" $H 'ENTRY_ISSUE = re.compile(r"^(?:i|issue-?|#)" + _NUM)' 'ENTRY_ISSUE = re.compile(r"^(?:i)" + _NUM)' t_evidence_date_names
mutant "evidence: a bare <N>-slug is not a name" $H 'BARE_ISSUE = re.compile(r"^([1-9]\d{2,5})-[A-Za-z]")' 'BARE_ISSUE = re.compile(r"^(?!)(\d)")' t_evidence_bare_names t_evidence
mutant "evidence: a bare number may start with a zero" $H 'BARE_ISSUE = re.compile(r"^([1-9]\d{2,5})-[A-Za-z]")' 'BARE_ISSUE = re.compile(r"^(\d{3,6})-[A-Za-z]")' t_evidence_bare_numbers_keep
mutant "evidence: a bare number needs no letter after it" $H 'BARE_ISSUE = re.compile(r"^([1-9]\d{2,5})-[A-Za-z]")' 'BARE_ISSUE = re.compile(r"^([1-9]\d{2,5})(?!\d)")' t_evidence_bare_numbers_keep
mutant "evidence: a bare number in a file name can remove" $H '(found if os.path.isdir(full) and not os.path.islink(full) else weak).add(int(m.group(1)))' 'found.add(int(m.group(1)))' t_evidence_bare_numbers_keep
mutant "codex: a nested repository is not judged" $H '        for n in sorted(os.listdir(top)):       # a repository nested in a child, ignored by the outer one' '        for n in []:       # a repository nested in a child, ignored by the outer one' t_codex_nested_repo
# F2 codex age
mutant "codex: CODEX_DAYS does not reach worktrees and archived sessions" $H 'return a.codex_days if kind in ("helmway", "worktrees", "archived") else a.days' 'return a.codex_days if kind == "helmway" else a.days' t_codex_days
mutant "codex: the age test is skipped for worktrees and archived sessions" $H '        if ds > 0 and newest_within(p, ds * 86400):
            return "newest' '        if False:
            return "newest' t_codex_days
# F3 worktree shapes
mutant "codex: a non-git sibling does not keep the <id> directory" $H '                return False, "%s is not a git worktree" % d' '                continue' t_codex_worktree_shapes
mutant "codex: a full clone is judged by HEAD only" $H '"rev-list", "--count", "--all", "--not", "--remotes"' '"rev-list", "--count", "HEAD", "--not", "--remotes"' t_codex_worktree_shapes
mutant "codex: a stash does not keep a full clone" $H '            if rc2 != 0 or stash:' '            if False:' t_codex_worktree_shapes
mutant "codex: untracked files are not looked at" $H '"status", "--porcelain", "-unormal"' '"status", "--porcelain"' t_codex
# ~/.codex leftovers
mutant "codex: helmway-evidence is aged like handoffs" $H 'return a.codex_days if kind in ("helmway", "worktrees", "archived") else a.days' 'return a.days' t_codex
mutant "codex: a dirty worktree goes" $H 'return False, "uncommitted changes in %s" % d' 'pass' t_codex
mutant "codex: a commit on no remote does not keep" $H '        if int(out) != 0:' '        if False:' t_codex
mutant "codex: a held entry goes" $H '            elif is_held(p, held):' '            elif False:' t_codex
mutant "codex: unknown lsof counts as nothing held" $H 'held = held_paths([r for _, r, _, _ in units])' 'held = held_paths([r for _, r, _, _ in units]) or []' t_codex_lsof_unknown_keeps
mutant "codex: an sqlite file goes" $H '    if SQLITE_NAME.search(os.path.basename(p)):' '    if False:' t_codex
mutant "codex: a directory holding an sqlite file goes" $H '            if any(SQLITE_NAME.search(n) for n in dn + fn):' '            if False:' t_codex
mutant "codex: unlink accepts a symlink" $H '        if not stat.S_ISREG(os.stat(leaf, dir_fd=fd, follow_symlinks=False).st_mode):' '        if False:' t_safe_rmtree t_remove_guards
# 7 dev processes
mutant "dev: claude ancestor ignored" $H '        if is_agent(p["cmd"]):' '        if False:' t_dev_claude_ancestor_keeps
mutant "dev: live session cwd ignored" $H '        if c == real or c.startswith(real + "/"):' '        if False:' t_dev_live_session_keeps
mutant "dev: unreadable sessions do not keep" $H 'return None, None, "session directory %s unreadable" % sessions_dir' 'return [], set(), None' t_dev_unknown_keeps
mutant "dev: age gate ignored" $H '        if row["age"] < a.min_age_hours * 3600:' '        if False:' t_dev_young_keeps
mutant "dev: primary checkout treated as worktree" $H 'os.path.realpath(gd) == os.path.realpath(cd)' 'False' t_dev_primary_keeps
mutant "dev: active worktree stopped" $H 'return top, "active" if recent else "idle"' 'return top, "idle"' t_dev_active_worktree_keeps
mutant "dev: merged is not recognised" $H '    if rc == 0:
        return top, "merged"' '    if False:
        return top, "merged"' t_dev_merged_worktree_stops
mutant "dev: no SIGKILL after the grace" $H '                os.kill(pid, signal.SIGKILL)' '                pass' t_dev_sigkill
mutant "dev: CC_NEVER_KILL_PIDS ignored" $H '        if never_kill(pid, rows):' '        if False:' t_dev_never_kill_keeps
mutant "dev: default mode is apply" $J 'CC_DJ_RET_DEV_MODE:-shadow' 'CC_DJ_RET_DEV_MODE:-apply' t_defaults
mutant "dev: default pattern drifts in the script" $J '\S*proxy\.mjs|vite(?: |$)|react' '\S*proxy\.mjs|react' t_dev_match_default
# shared safety
mutant "report mode deletes" $J 'if [ "${_CC_DJ_RET_REPORT:-0}" = 1 ]; then echo shadow; else echo apply; fi' 'echo apply' t_report_forces_shadow
mutant "unknown mode deletes" $J '    *) echo shadow ;;' '    *) echo apply ;;' t_bad_mode_is_shadow
mutant "removal guard: variables unchecked" $J 'local root="${1:?}" list="${2:?}" kind="${3:?}" helper out line left' 'local root="${1:-}" list="${2:-}" kind="${3:-d}" helper out line left' t_remove_guards
mutant "removal guard: outside the root" $H '    if not path.startswith(root + "/"):' '    if False:' t_remove_guards
mutant "removal guard: file removal falls back to rm" $H '(safe_unlink if a.kind == "f" else safe_rmtree)(root, p)' 'safe_rmtree(root, p) if a.kind == "d" else os.unlink(p)' t_remove_guards
mutant "root trust: owner and mode unchecked (bash)" $J 'if [ "$own" != "${CC_DJ_RET_UID:-$(id -u)}" ] || [ $(( 8#$mode & 8#022 )) -ne 0 ]; then' 'if false; then' t_root_mode t_root_uid
mutant "root trust: owner unchecked (bash)" $J 'if [ "$own" != "${CC_DJ_RET_UID:-$(id -u)}" ] || [ $(( 8#$mode & 8#022 )) -ne 0 ]; then' 'if [ $(( 8#$mode & 8#022 )) -ne 0 ]; then' t_root_uid
mutant "root trust: mode unchecked (bash)" $J 'if [ "$own" != "${CC_DJ_RET_UID:-$(id -u)}" ] || [ $(( 8#$mode & 8#022 )) -ne 0 ]; then' 'if [ "$own" != "${CC_DJ_RET_UID:-$(id -u)}" ]; then' t_root_mode
mutant "root trust: owner and mode unchecked (helper)" $H 'return st.st_uid == want_uid() and (st.st_mode & 0o022) == 0' 'return True' t_root_mode t_root_uid
mutant "removal: root descriptor not re-checked" $H '        if not trusted_stat(os.fstat(fd)):' '        if False:' t_safe_rmtree
mutant "removal: components followed through symlinks" $H 'flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW' 'flags = os.O_RDONLY | os.O_DIRECTORY' t_safe_rmtree t_swap_after_listing t_remove_guards
mutant "removal: unsafe rmtree allowed" $H 'if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):' 'if False:' t_safe_rmtree
mutant "removal: .. components allowed" $H 'if any(p in ("", ".", "..") for p in parts):' 'if False:' t_safe_rmtree
mutant "not wired into --check" $J '  _cc_dj_retention

  # By GB' '
  # By GB' t_wired_into_check
mutant "CC_DJ_RETENTION=off ignored" $J 'if [ "$CC_DJ_RETENTION" = off ]; then' 'if false; then' t_retention_off

echo "1..done failures=$failures"
[ "$failures" -eq 0 ]
