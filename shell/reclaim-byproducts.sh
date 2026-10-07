#!/usr/bin/env bash
# Reclaim the BYPRODUCTS of work that is already finished — the things a reclaimed
# worktree, an ended session, or a removed container leaves behind and nothing owns.
#
# cc-reaper's worktree janitor retires worktrees, at SessionEnd and on a schedule. It
# does not touch what those worktrees and the
# sessions around them produced OUTSIDE the tree: a session scratchpad under
# /tmp/claude-<uid>, the anonymous Docker volume a removed container left on the shared
# daemon, the archive a previous reclaim wrote. On 2026-09-11 those three came to
# 20.5 GiB, 6.5 GB and 2.3 GB, and every one of them was freed by hand.
#
# Five reapers, one rule each, all fail-closed:
#
#   scratchpads  /tmp/claude-<uid>/<project>/<session-uuid>  — only when path-in-use.sh
#                says free. UNKNOWN is treated as in use. Idle 24h, or 6h under disk
#                pressure when no live Claude PID record names the session.
#   go cache     the entries Go itself would trim (`<hash>-a`/`-d` in the two-hex-digit
#                subdirectories), sooner, and a size ceiling that takes the idlest entries
#                first. This machine's one owner of that cache: cc-reaper's weekly trim
#                is set off here.
#   docker       ANONYMOUS volumes (64-hex names), dangling images, and tagged images
#                that opt in as disposable (`apertis-prepared:<sha>`), unreferenced and
#                older than the age gate. Never a named volume, never a pulled image,
#                never a prune; builder cache is cc-reaper's weekly `until=168h` prune.
#   archives     ~/.claude/reclaim-archive/<YYYYMMDD> past its retention.
#   caches       uv's cache, whose own `uv cache prune` knows which entries are dead
#                (pip's is cc-reaper's weekly purge), and a NAMED list of leftovers from
#                applications that are gone. Everything else under ~/.cache and
#                ~/Library/Caches is refused by name, with the reason beside it.
#
# Every sweep prints a ledger: a `== byproducts sweep started <ISO-8601> ==` header, an
# `== byproducts sweep ended ... ==` line carrying elapsed seconds and how much free space
# the volume actually gained, and a per-section byte total wherever one is cheap to take.
# Until 2026-09-13 the log was 147 lines of two concatenated sweeps with no separator, no
# timestamp and no total, so "how often did it fire, and how much did it reclaim" had no
# answer on the machine the reaper was installed to protect.
#
# It runs AFTER the worktree sweep by design: a worktree reclaimed at 03:30 orphans
# its local stack's containers, and their volumes are only collectable once that has
# happened.
#
# Measured on 2026-09-12 with 116 scratchpads: 358s wall, 289s CPU, nearly all of it the
# liveness gate. It is self-limiting - the run that costs that much is the one clearing a
# backlog, and every run after it faces what one day produced.
#
# A LaunchAgent loads at LOGIN, not at boot, and FileVault rules out an automatic one:
# after a reboot nothing is loaded until somebody logs in, and the 04:00 firing that was
# missed is never caught up. The daily reclamation skips a day, or as many days as nobody
# logs in, and says nothing. (`pmset autorestart 1` - the machine does come back on its
# own after a power event; it just sits at the login window.) RunAtLoad in the plist below
# fires the job at that first login, which closes the hole and opens a smaller one: it
# also fires on every `launchctl load`. So the scheduled path is --if-stale, and
# $HOME/.claude/logs/reclaim-byproducts.last (BYPRODUCT_STAMP) records when a reap last
# COMPLETED - reloading the agent at noon is then a no-op instead of a second full docker
# and Go-cache sweep. Only that path consults the stamp; a hand-run always reaps.
#
#   reclaim-byproducts.sh              reap now, whatever the stamp says
#   reclaim-byproducts.sh --dry-run    report what would be reaped, touch nothing
#   reclaim-byproducts.sh --go-cache   trim the go build cache only, now (no stamp)
#   reclaim-byproducts.sh --if-stale   reap only if the last completed reap is older than
#                                      the gate - BYPRODUCT_MIN_MINUTES, or failing that
#                                      BYPRODUCT_MIN_HOURS (default 12) - the agent's path
#   reclaim-byproducts.sh --self-test  run the calibration suite
#   reclaim-byproducts.sh --install-launchd [HH:MM]   daily at that wall-clock time
#   reclaim-byproducts.sh --install-launchd [Nh]      every N hours (1-24)
#                                      (default 04:00) — a no-op when the agent it would
#                                      install is already the one installed and loaded
set -u

# Deployed as a copy under ~/.cc-reaper (moved from the skills repository, 2026-10-07), and
# runnable through a symlink to the checkout, where `dirname $BASH_SOURCE` is the link's
# directory and not the repository. HERE names where it was invoked from, which is where
# the LaunchAgent points; REPO_HERE follows links to the checkout for tests/, which only
# the checkout has. Keep both.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_real="${BASH_SOURCE[0]}"
while [ -L "$_real" ]; do
  _link="$(readlink "$_real")"
  case "$_link" in /*) _real="$_link" ;; *) _real="$(dirname "$_real")/$_link" ;; esac
done
REPO_HERE="$(cd "$(dirname "$_real")" && pwd -P)"
# The liveness gate is the harness's own (the skills repository installs it in
# ~/.claude/hooks); without it no scratchpad is safe to judge and the run refuses below.
PATH_IN_USE="${PATH_IN_USE_BIN:-$HOME/.claude/hooks/path-in-use.sh}"
LABEL="com.cc-reaper.reclaim-byproducts"
# The agent's name while the skills repository owned it; retired once this one is loaded.
LEGACY_LABEL="${BYPRODUCT_LEGACY_LABEL:-com.claude.reclaim-byproducts}"
LAUNCHCTL="${BYPRODUCT_LAUNCHCTL:-launchctl}"

SCRATCH_ROOT="${BYPRODUCT_SCRATCH_ROOT:-/tmp/claude-$(id -u)}"
ARCHIVE_ROOT="${BYPRODUCT_ARCHIVE_ROOT:-$HOME/.claude/reclaim-archive}"
DOCKER="${BYPRODUCT_DOCKER_BIN:-docker}"

# Hours a SCRATCHPAD must have been untouched. The same 24h the mention window in
# path-in-use.sh uses, so the two gates cannot disagree about what "recent" means. It has
# to stay there: a scratchpad idle for seven hours may belong to a session that is simply
# thinking, and lowering this deletes work in progress.
IDLE_HOURS="${BYPRODUCT_IDLE_HOURS:-24}"

# Under disk pressure a scratchpad whose session has NO live Claude PID record
# (~/.claude/sessions/<pid>.json naming its id, with that pid alive) may go after this many
# idle hours instead of IDLE_HOURS, and path-in-use is asked with the same window. The
# reason above for 24h is a session that is simply thinking; a thinking session has a live
# process and a PID record, so it keeps the 24h. On 2026-10-06 /tmp/claude-501 held 33 GiB
# with 37 GiB free and 96 scratchpads kept, nearly all by the 24h window alone.
# PRESSURE_FREE_GB is the data volume's free space below which the tier applies, the same
# 100 cc-reaper's worktree janitor calls pressure; 0 turns the tier off. Session records
# that cannot be read keep the 24h for every scratchpad in that run.
SCRATCH_PRESSURE_FREE_GB="${BYPRODUCT_SCRATCH_PRESSURE_FREE_GB:-100}"
SCRATCH_PRESSURE_IDLE_HOURS="${BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS:-6}"
SESSIONS_DIR="${BYPRODUCT_SESSIONS_DIR:-$HOME/.claude/sessions}"

# The minimum age of an ANONYMOUS VOLUME, which was the line above until 2026-09-13 and is
# not the same question. A volume an `--ephemeral` CI runner container left is dead the
# moment that container exited, minutes after it was created; the four runners on this
# machine leave ~150 a day, 15.8 GB of rolling garbage, and at 24h only 13 were ever old
# enough to reap. The gate itself stays - a container being created right now and a dead
# volume look identical, and age is the only thing that separates them. Defaulted to the
# 24h it inherited, so splitting the knob changes nothing until somebody turns it.
DOCKER_VOLUME_AGE_HOURS="${BYPRODUCT_DOCKER_VOLUME_AGE_HOURS:-24}"
ARCHIVE_DAYS="${BYPRODUCT_ARCHIVE_RETENTION_DAYS:-30}"
# Go's build cache trims entries unused for 5 days, on its own, at most once a day and
# only when `go` runs. Measured 2026-09-12: that leaves a plateau of 33.2 GiB, because a
# machine running eleven sessions produces more than five days of entries. A shorter age
# does what Go's own policy does, just sooner. The ceiling is the backstop for the case
# the age trim cannot reach - a burst inside the window - and it trims by idleness before
# it ever empties the cache (see reap_go_cache).
GO_CACHE_TRIM_DAYS="${BYPRODUCT_GO_CACHE_TRIM_DAYS:-3}"
GO_CACHE_MAX_GB="${BYPRODUCT_GO_CACHE_MAX_GB:-30}"
GO_CACHE_DIR="${BYPRODUCT_GO_CACHE_DIR:-$HOME/Library/Caches/go-build}"
# A fixed ceiling says nothing about the disk around the cache. On 2026-10-04 the cache
# was 33GB, under nothing but its own 30GB line, with the data volume at 7GB free: every
# heavy CI slot on this machine declines a job below 20GB (~/ci-runner/run-loop.sh), so
# merge-gate - the only required check - queued for 90 minutes. Whatever the data volume
# is short of this floor comes off the ceiling for that run, through the same idle-first
# halving; the cache is still only ever EMPTIED at the fixed ceiling, never for pressure.
# 30 = the CI floor plus room for the cache to grow between two runs. 0 turns it off.
# BYPRODUCT_FREE_GB stands in for df, for the self-test only.
GO_FREE_FLOOR_GB="${BYPRODUCT_GO_FREE_FLOOR_GB:-30}"

# A tagged image is not a dangling one, so the reaper above never sees it. Only images
# that opt in by name are taken: `apertis-prepared:<sha>`, one per release-lane commit.
# A PULLED image is never taken. Its `.Created` is when upstream built it, not when it was
# pulled, and Docker records no last use, so "seven days old" was true of a fresh pull:
# alpine:3, which every CI job runs, was removed and re-pulled 35 times, redis:7-alpine 22
# and postgres:17 8 (reclaim-byproducts.log, to 2026-09-23). A locally BUILT image whose
# Dockerfile may have moved is not re-creatable, and is never touched either.
IMAGE_AGE_DAYS="${BYPRODUCT_IMAGE_AGE_DAYS:-7}"
DISPOSABLE_IMAGE_RE="${BYPRODUCT_DISPOSABLE_IMAGE_RE:-^apertis-prepared:}"

# When a reap last COMPLETED, and how long that answer suppresses the SCHEDULED run. See
# the RunAtLoad paragraph at the top: the agent fires on its schedule AND at every load,
# and without this the second kind would re-do the whole sweep every time somebody logs in.
STAMP="${BYPRODUCT_STAMP:-$HOME/.claude/logs/reclaim-byproducts.last}"
MIN_HOURS="${BYPRODUCT_MIN_HOURS:-12}"
# The gate belongs to the SCHEDULE, and 12 whole hours can only express a daily one. An
# interval schedule writes its own gate here, in minutes, when --install-launchd builds the
# plist; see install_launchd for why it is half the period.
MIN_MINUTES_SET="${BYPRODUCT_MIN_MINUTES:-}"

# ------------------------------------------------------------------ the run ledger
#
# Where the SCHEDULED run's output lands: the agent's plist names this same path for both
# StandardOutPath and StandardErrorPath, so the reaper owns it and rotating it is its job.
LOG_FILE="${BYPRODUCT_LOG:-$HOME/.claude/logs/reclaim-byproducts.log}"
# 1 MiB. One sweep of this machine measured 19,526 bytes on 2026-09-13, so at the 3h
# cadence the agent installs - eight firings a day - the live generation holds roughly
# twelve days and the pair holds twenty-four. Small enough that the file never becomes the
# thing nobody opens; large enough that a week of history survives one bad backlog run.
LOG_MAX_BYTES="${BYPRODUCT_LOG_MAX_BYTES:-1048576}"
# The volume the freed bytes actually come back to. Not `/`, which on this machine is the
# sealed read-only system snapshot and never moves.
DATA_VOLUME="${BYPRODUCT_DATA_VOLUME:-/System/Volumes/Data}"

# ------------------------------------------------------------------ caches
#
# ~20.9 GB sat here with no reaper at all until 2026-09-13. Only entries whose owner can
# say they are dead are taken: `uv cache prune` removes what nothing references any more,
# and the list below is leftovers from applications that have been removed from the
# machine. pip's download cache is purged weekly by cc-reaper; purging it here too, every
# three hours, left cc-reaper an empty cache and a failed `pip3 cache purge` (rc=1 on
# 2026-09-06 and 2026-09-20).
UV="${BYPRODUCT_UV_BIN:-uv}"
# Newline-separated. Do not put a runtime cache here merely because one client was
# removed: Codex is installed in the current harness and recreates this directory.
# Dead application caches must be supplied explicitly by the machine owner after
# proving that no installed client, process, or active session can read them.
CACHE_DEAD_PATHS="${BYPRODUCT_DEAD_CACHE_PATHS:-}"
# Refused by name, whatever anybody later adds to the list above. Each line carries why,
# because every one of them is a fat directory that reads like an obvious win.
#
# BYPRODUCT_EXTRA_NEVER_CACHE_PATHS is APPENDED, never substituted, and that is the whole
# design of the seam: a knob that could empty this list would be a knob for turning the
# guard off, and the guard is the only thing between a future edit of the list above and
# somebody's iCloud cache. It can widen the refusal and nothing else. It earns its place
# twice over - a machine with its own precious cache directory can protect it without
# editing this file, and the four entries above being literals is otherwise the reason the
# trailing-slash strip below them cannot be exercised at all.
CACHE_NEVER="
$HOME/Library/Caches/CloudKit
$HOME/.cache/huggingface
$HOME/.cache/qmd
$HOME/Library/Caches/go-build
${BYPRODUCT_EXTRA_NEVER_CACHE_PATHS:-}
"
# CloudKit (8.03 GB) is iCloud's own cache, and ~/Documents here is an iCloud
#   file-provider domain: emptying it forces a re-sync, which is exactly the service
#   interruption this reaper exists not to cause.
# huggingface (2.63 GB) is re-downloadable and expensive, and nothing running here can
#   know whether the run that needs it next has network.
# qmd (0.89 GB) holds index.sqlite plus the models for an INSTALLED tool
#   (~/.bun/bin/qmd). It is an index, not a cache; deleting it destroys state.
# go-build is already reaped above, by a section that correctly stands down while a go
#   build or test is running. Reaping it here too would delete entries out from under it.

DRY=0
CHECK_STALE=0
FAILED=0

usage() { sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; }

log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- the run ledger

now_iso() { date +%Y-%m-%dT%H:%M:%S%z; }
# 1K blocks available, which is the only column here that answers "did the sweep return
# anything". Empty when df cannot answer, and every consumer below renders that as "?"
# rather than as a number nobody measured.
free_kb() { df -k "$DATA_VOLUME" 2>/dev/null | awk 'NR==2 {print $4+0}'; }
free_gb() {
  if [ -n "${BYPRODUCT_FREE_GB:-}" ]; then printf '%s' "$BYPRODUCT_FREE_GB"; return; fi
  local k; k="$(free_kb)"; [ -n "$k" ] && printf '%d' "$((k / 1048576))"
}
kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }
as_gb() { case "$1" in ''|*[!0-9]*) printf '?GB' ;; *) awk -v k="$1" 'BEGIN{printf "%.1fGB", k/1048576}' ;; esac; }
as_mb() { case "$1" in ''|*[!0-9]*) printf '?' ;; *) awk -v k="$1" 'BEGIN{printf "%.1f", k/1024}' ;; esac; }
# What a section calls its own total. A dry run measured the same bytes and removed none
# of them, and a summary line that said "freed" either way would be the report this whole
# change exists to stop trusting.
freed_mb() { if [ "$DRY" -eq 1 ]; then printf 'would free %sMB' "$(as_mb "$1")"; else printf 'freed %sMB' "$(as_mb "$1")"; fi; }

# launchd APPENDS to StandardOutPath, so the file is copied and truncated rather than
# renamed: an O_APPEND write after a truncate lands at offset 0, while after a rename it
# would land in the generation just rotated away. A hand-run redirecting `>` into this
# same path truncates it at open, so the size test below can never fire on one.
#
# Never `: > "$LOG_FILE"` on its own. The point of a ledger is that a sweep cannot destroy
# the evidence of the sweeps before it, and a silent truncate is exactly that.
rotate_log() {
  local n
  [ -f "$LOG_FILE" ] || return 0
  n="$(stat -f %z "$LOG_FILE" 2>/dev/null || stat -c %s "$LOG_FILE" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt "$LOG_MAX_BYTES" ] || return 0
  cp "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || { log "could not rotate $LOG_FILE; leaving it alone"; return 0; }
  : > "$LOG_FILE" 2>/dev/null || return 0
  log "rotated the previous ${n} bytes to $LOG_FILE.1"
}

# A trap rather than a line before each `exit`, for the reason the sibling reaper's is
# one: there are five ways out of the sweep below - an unreadable liveness gate, a
# staleness skip, a failed reap, a clean one, an interrupt - and a marker missing from any
# of them leaves a sweep in the log with no end and no total.
sweep_ended() {
  local after delta
  after="$(free_kb)"
  # Each substituted through a non-digit placeholder, so that ONE empty reading falls into
  # the unmeasured branch. Concatenated bare, an empty before and a numeric after read as
  # a number, and the delta would be the whole volume.
  case "${FREE_BEFORE:-x}${after:-x}" in
    *[!0-9]*) delta="free space on $DATA_VOLUME: unmeasured" ;;
    # A few KiB of drift on a busy volume renders as "-0.0GB" under %+.1f, which reads as
    # a defect rather than as a rounded zero. Anything inside the displayed precision is
    # printed as the zero it rounds to.
    *) delta="free on $DATA_VOLUME $(as_gb "$FREE_BEFORE") -> $(as_gb "$after") ($(awk -v a="$FREE_BEFORE" -v b="$after" 'BEGIN{d=(b-a)/1048576; if (d>-0.05 && d<0.05) d=0; printf "%+.1fGB", d}'))" ;;
  esac
  log "== byproducts sweep ended $(now_iso) after ${SECONDS}s; $delta =="
}

# A whole number of hours, refused rather than silently reinterpreted. `off` in
# WORKTREE_IDLE_HOURS cost 78 worktrees; the same shape is possible here.
case "$IDLE_HOURS" in
  ''|*[!0-9]*|??????*) echo "byproducts: BYPRODUCT_IDLE_HOURS=$IDLE_HOURS is not a whole number of hours below 100000; reaping nothing" >&2; exit 2 ;;
  *) IDLE_HOURS=$((10#$IDLE_HOURS)) ;;
esac
case "$SCRATCH_PRESSURE_FREE_GB" in
  ''|*[!0-9]*|??????*) echo "byproducts: BYPRODUCT_SCRATCH_PRESSURE_FREE_GB=$SCRATCH_PRESSURE_FREE_GB is not a whole number of GB below 100000; reaping nothing" >&2; exit 2 ;;
  *) SCRATCH_PRESSURE_FREE_GB=$((10#$SCRATCH_PRESSURE_FREE_GB)) ;;
esac
case "$SCRATCH_PRESSURE_IDLE_HOURS" in
  ''|0|*[!0-9]*|??????*) echo "byproducts: BYPRODUCT_SCRATCH_PRESSURE_IDLE_HOURS=$SCRATCH_PRESSURE_IDLE_HOURS is not a whole number of hours from 1 to 99999; reaping nothing" >&2; exit 2 ;;
  *) SCRATCH_PRESSURE_IDLE_HOURS=$((10#$SCRATCH_PRESSURE_IDLE_HOURS)) ;;
esac
# Never longer than the normal window: pressure only ever shortens it.
[ "$SCRATCH_PRESSURE_IDLE_HOURS" -gt "$IDLE_HOURS" ] && SCRATCH_PRESSURE_IDLE_HOURS=$IDLE_HOURS
# Refused rather than defaulted for the same reason IDLE_HOURS is: it decides WHAT is
# deleted. A value that fell back silently would reap on some age nobody asked for.
case "$DOCKER_VOLUME_AGE_HOURS" in
  ''|*[!0-9]*|??????*) echo "byproducts: BYPRODUCT_DOCKER_VOLUME_AGE_HOURS=$DOCKER_VOLUME_AGE_HOURS is not a whole number of hours below 100000; reaping nothing" >&2; exit 2 ;;
  *) DOCKER_VOLUME_AGE_HOURS=$((10#$DOCKER_VOLUME_AGE_HOURS)) ;;
esac
case "$ARCHIVE_DAYS" in
  ''|*[!0-9]*|?????*) echo "byproducts: BYPRODUCT_ARCHIVE_RETENTION_DAYS=$ARCHIVE_DAYS is not a whole number of days below 10000; reaping nothing" >&2; exit 2 ;;
  *) ARCHIVE_DAYS=$((10#$ARCHIVE_DAYS)) ;;
esac
# The one window that is defaulted rather than refused. It decides WHEN the job runs, not
# what it deletes, and a typo that stops the daily reclamation outright is the worse of
# the two failures. Not silent either way: a bad value says which number it fell back to,
# and 0 - meaning "nothing is ever recent" - is the only thing that turns the gate off.
case "$MIN_HOURS" in
  ''|*[!0-9]*|??????*) echo "byproducts: BYPRODUCT_MIN_HOURS=$MIN_HOURS is not a whole number of hours below 100000; using 12" >&2; MIN_HOURS=12 ;;
  *) MIN_HOURS=$((10#$MIN_HOURS)) ;;
esac
# The same window in the unit a sub-daily schedule can express. Defaulted like the hours
# above, never refused and never silently off: a bad value falls back to whatever
# BYPRODUCT_MIN_HOURS resolved to and says which. It WINS over the hours when both are
# set, because it is the more specific of the two and it is the one the plist carries.
if [ -n "$MIN_MINUTES_SET" ]; then
  case "$MIN_MINUTES_SET" in
    *[!0-9]*|????????*) echo "byproducts: BYPRODUCT_MIN_MINUTES=$MIN_MINUTES_SET is not a whole number of minutes below 10000000; using ${MIN_HOURS}h" >&2; MIN_MINUTES=$((MIN_HOURS * 60)) ;;
    *) MIN_MINUTES=$((10#$MIN_MINUTES_SET)) ;;
  esac
else
  MIN_MINUTES=$((MIN_HOURS * 60))
fi
# What the two messages below call the window. Whole hours keep reading as hours, which is
# every daily install ever made; anything else has to say minutes or it would round to a
# number the gate is not actually using.
if [ $((MIN_MINUTES % 60)) -eq 0 ]; then GATE="$((MIN_MINUTES / 60))h"; else GATE="${MIN_MINUTES}m"; fi

# BSD `find -mtime +0` rounds up to the next whole day, so a tree touched an hour ago
# reads as a day old. Minutes are the only unit that means what it says here.
IDLE_MINUTES=$((IDLE_HOURS * 60))
GO_TRIM_MINUTES=$((GO_CACHE_TRIM_DAYS * 1440))

# The Bash tool's `find` is bfs, which rejects `-newermt '-6 hours'`. Every find below
# is the system one by absolute path for that reason.
FIND=/usr/bin/find
[ -x "$FIND" ] || FIND=find

# ---------------------------------------------------------------- staleness

# Asked in minutes for the same reason everything else here is: BSD `find -mtime +N`
# rounds the day count up. A MISSING stamp is not recent - the reap runs. One extra sweep
# costs minutes; the other way round, a machine that has never stamped never reclaims.
ran_recently() {
  [ -f "$STAMP" ] || return 1
  [ -n "$("$FIND" "$STAMP" -mmin -"$MIN_MINUTES" 2>/dev/null)" ]
}

write_stamp() {
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null
  if : > "$STAMP" 2>/dev/null; then
    # $GATE is THIS process's window and nothing else's. A hand-run has no
    # BYPRODUCT_MIN_MINUTES in its environment and falls back to the 12h hours default,
    # while the installed agent carries 90m in its plist and MIN_MINUTES wins - so the
    # sentence this used to print, "a scheduled run inside the next 12h will skip", was
    # measurably false about the only subject it named, in a log the two share. Anybody
    # auditing the schedule read it as the 3-hour timer being suppressed. The gate the
    # other process will use is not knowable from here, and reading the installed plist to
    # guess it would only be wrong in the other direction.
    log "stamped $STAMP; a run with the same gate inside the next ${GATE} will skip"
  else
    echo "byproducts: could not write the stamp $STAMP; every scheduled run will reap" >&2
  fi
}

# ---------------------------------------------------------------- scratchpads

is_session_id() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}

# Nothing under the tree modified inside the window. Asked with -quit so a scratchpad
# holding 132,756 files does not cost a full walk to answer "recent".
tree_is_idle() {
  local hit
  hit="$("$FIND" "$1" -mmin -"${2:-$IDLE_MINUTES}" -print -quit 2>/dev/null)" || return 1
  [ -z "$hit" ]
}

# Session ids that count as live, one per line: every Claude PID record
# (~/.claude/sessions/<pid>.json; only numeric names are records) whose pid is alive, plus
# every session-id-shaped word on any running process's command line. The second half is
# for a resumed session: /resume points its record at the new id while its background task
# output stays under the id it started with, which its `--session-id` still names. Fails -
# and the caller keeps the normal window - when a record cannot be read, the process list
# cannot be read, or a claude process is running while no live record exists (the record
# format moved). A reused pid reads as alive, which only keeps more.
# BYPRODUCT_CLAUDE_RUNNING (0/1) stands in for the claude process check, for the self-test.
live_session_ids() {
  [ -d "$SESSIONS_DIR" ] && [ -r "$SESSIONS_DIR" ] || return 1
  local f pid sid records=0 argv running
  for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    case "${f##*/}" in *[!0-9]*.json|.json) continue ;; esac
    pid="$(/usr/bin/plutil -extract pid raw -o - "$f" 2>/dev/null)" || return 1
    sid="$(/usr/bin/plutil -extract sessionId raw -o - "$f" 2>/dev/null)" || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    if kill -0 "$pid" 2>/dev/null; then printf '%s\n' "$sid"; records=$((records + 1)); fi
  done
  argv="$(ps -axww -o command= 2>/dev/null)" && [ -n "$argv" ] || return 1
  printf '%s\n' "$argv" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  if [ "$records" -eq 0 ]; then
    case "${BYPRODUCT_CLAUDE_RUNNING:-}" in
      0) running=1 ;;
      1) running=0 ;;
      *) pgrep -x claude >/dev/null 2>&1; running=$? ;;
    esac
    [ "$running" -eq 0 ] && return 1
  fi
  return 0
}

reap_scratchpads() {
  [ -d "$SCRATCH_ROOT" ] || { log "scratchpads: $SCRATCH_ROOT does not exist, nothing to reap"; return 0; }
  # /tmp is shared and the root is named by uid, so another account could have made it.
  if [ -L "$SCRATCH_ROOT" ] || [ ! -O "$SCRATCH_ROOT" ]; then
    log "scratchpads: $SCRATCH_ROOT is a link or not owned by $(id -un); nothing reaped" >&2
    FAILED=1; return 0
  fi
  local reaped=0 kept=0 bytes=0 d sid verdict rc
  local pressure=0 live="" free window=$IDLE_HOURS
  free="$(free_gb)"
  if [ "$SCRATCH_PRESSURE_FREE_GB" -gt 0 ] && [ -n "$free" ] && [ "$free" -lt "$SCRATCH_PRESSURE_FREE_GB" ]; then
    if live="$(live_session_ids)"; then
      pressure=1
      log "scratchpads: disk pressure (free ${free}GB < ${SCRATCH_PRESSURE_FREE_GB}GB): idle window ${SCRATCH_PRESSURE_IDLE_HOURS}h for sessions with no live record"
    else
      log "scratchpads: disk pressure (free ${free}GB), but session records under $SESSIONS_DIR could not be read; keeping the ${IDLE_HOURS}h window"
    fi
  fi
  for d in "$SCRATCH_ROOT"/*/*; do
    # A link at either level points anywhere; it is never a scratchpad.
    [ -d "$d" ] && [ ! -L "$d" ] && [ ! -L "${d%/*}" ] || continue
    sid="$(basename "$d")"
    # Only a session directory. /tmp/claude-501 also holds loose probe files and
    # directories nobody names a session, and those are not this reaper's business.
    if ! is_session_id "$sid"; then kept=$((kept + 1)); continue; fi

    window=$IDLE_HOURS
    if [ "$pressure" -eq 1 ] && ! printf '%s\n' "$live" | grep -qxF "$sid"; then
      window=$SCRATCH_PRESSURE_IDLE_HOURS
    fi
    if ! tree_is_idle "$d" "$((window * 60))"; then
      log "scratchpad kept: $d — touched within ${window}h"
      kept=$((kept + 1)); continue
    fi

    # The user's rule, and the only test that matters: ask whether a live session is
    # using it. Exit 0 free, 1 in use, 2 unknown. UNKNOWN keeps it - on 2026-09-11
    # the mention rule correctly held a directory two sessions were still writing to
    # while `lsof` reported no holder at all.
    if [ "$window" -ne "$IDLE_HOURS" ]; then
      verdict="$(PATH_IN_USE_SELF="${CLAUDE_CODE_SESSION_ID:-}" PATH_IN_USE_WINDOW_HOURS="$window" bash "$PATH_IN_USE" "$d" 2>&1)"; rc=$?
    else
      verdict="$(PATH_IN_USE_SELF="${CLAUDE_CODE_SESSION_ID:-}" bash "$PATH_IN_USE" "$d" 2>&1)"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      log "scratchpad kept: $d — $(printf '%s' "$verdict" | sed -n '2p' | sed 's/^ *//')"
      kept=$((kept + 1)); continue
    fi

    # Measured before the removal, because afterwards there is nothing to measure. It is
    # a second walk of a tree the `rm -rf` below is about to walk anyway; on the dry-run
    # path it is the only walk, and it is still small beside the liveness gate that just
    # decided this directory (358s of a 358s sweep, measured 2026-09-12).
    bytes=$((bytes + $(kb_of "$d")))
    if [ "$DRY" -eq 1 ]; then
      log "scratchpad WOULD be reaped: $d"
    else
      rm -rf "$d" 2>/dev/null || { log "scratchpad could not be removed: $d" >&2; FAILED=1; kept=$((kept + 1)); continue; }
      log "scratchpad reaped: $d"
    fi
    reaped=$((reaped + 1))
  done
  log "scratchpads: $reaped reaped, $kept kept, $(freed_mb "$bytes")"
}

# ---------------------------------------------------------------- docker

# An anonymous volume is one Docker named itself: 64 hex characters. A NAMED volume is
# somebody's, always, and this is the difference the whole reaper turns on.
#
# `docker volume ls -f dangling=true` is NOT that question. Measured 2026-09-11 at
# 03:0x: it listed stima-ci-work-1, -2 and -3 - three live CI slots that happened to be
# between jobs, because run-loop.sh removes the container at the top of each loop and a
# volume with no container is "dangling" by that filter's definition. A reaper keyed on
# it would have deleted the working state of the machine's own CI.
is_anonymous_volume() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) return 1 ;;
  esac
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

docker_available() { command -v "$DOCKER" >/dev/null 2>&1 && "$DOCKER" info >/dev/null 2>&1; }

reap_docker() {
  if ! docker_available; then
    log "docker: not available, reaped nothing"
    return 0
  fi

  # Every volume any container references, running or not. Built from the containers
  # rather than from a filter, because the filter is what got this wrong.
  local referenced
  referenced="$("$DOCKER" ps -aq 2>/dev/null | while read -r c; do
      "$DOCKER" inspect "$c" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}
{{end}}{{end}}' 2>/dev/null
    done | grep -v '^$' | sort -u)"

  # Both the image ref and the resolved id, because a container records the id and the
  # `docker ps` format records the ref, and neither alone matches both spellings.
  local referenced_images ; image_referenced() {
    printf '%s\n' "$referenced_images" | grep -Fxq "$1" && return 0
    printf '%s\n' "$referenced_images" | grep -q "$2"
  }
  referenced_images="$( { "$DOCKER" ps -a --format '{{.Image}}' 2>/dev/null
      "$DOCKER" ps -aq 2>/dev/null | while read -r c; do "$DOCKER" inspect "$c" --format '{{.Image}}' 2>/dev/null; done
    } | grep -v '^$' | sort -u)"

  local now cutoff reaped=0 kept=0 v created created_epoch
  now="$(date +%s)"
  cutoff=$((now - DOCKER_VOLUME_AGE_HOURS * 3600))

  while read -r v; do
    [ -n "$v" ] || continue
    if ! is_anonymous_volume "$v"; then kept=$((kept + 1)); continue; fi
    if printf '%s\n' "$referenced" | grep -Fxq "$v"; then kept=$((kept + 1)); continue; fi
    created="$("$DOCKER" volume inspect "$v" --format '{{.CreatedAt}}' 2>/dev/null)"
    # docker prints `2026-09-11T09:47:48+08:00`; BSD date's -f rejects the trailing
    # offset, so the timestamp is cut to its fixed-width head rather than guessed at.
    created_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$(printf '%s' "$created" | cut -c1-19)" +%s 2>/dev/null \
      || date -d "$created" +%s 2>/dev/null)"
    # A volume whose age cannot be read is kept. An unreadable date is not evidence
    # of age, and a container being created right now is exactly the race this gate
    # exists for.
    if [ -z "$created_epoch" ] || [ "$created_epoch" -ge "$cutoff" ]; then
      kept=$((kept + 1)); continue
    fi
    if [ "$DRY" -eq 1 ]; then
      log "docker volume WOULD be reaped: $v"
    else
      "$DOCKER" volume rm "$v" >/dev/null 2>&1 && log "docker volume reaped: $v" || { kept=$((kept + 1)); continue; }
    fi
    reaped=$((reaped + 1))
  done <<< "$("$DOCKER" volume ls -q 2>/dev/null)"

  local img imgs=0
  while read -r img; do
    [ -n "$img" ] || continue
    if [ "$DRY" -eq 1 ]; then
      log "docker image WOULD be reaped: $img"
    else
      "$DOCKER" rmi "$img" >/dev/null 2>&1 && log "docker image reaped: $img" || continue
    fi
    imgs=$((imgs + 1))
  done <<< "$("$DOCKER" images -f dangling=true -q 2>/dev/null)"

  # Tagged images nothing references. `docker images -f dangling=true` cannot see these -
  # they have a name - so without this they accumulate forever: 18 `apertis-prepared:<sha>`
  # built one per release-lane commit were sitting here on 2026-09-12.
  #
  # The discriminator is the name. Until 2026-09-23 a PULLED image (one carrying a
  # registry digest) was taken too, on its `.Created` - which is upstream's build time,
  # so a fresh pull was already old; see DISPOSABLE_IMAGE_RE. A BUILT image's Dockerfile
  # may have moved or never existed. Only the disposable pattern opts an image in.
  local tags=0 ref iid created_e
  while read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in *'<none>'*) continue ;; esac
    # Disposable by name, or not taken at all; see DISPOSABLE_IMAGE_RE for why a pulled
    # image's age cannot be read. For a disposable one `.Created` is this machine's build.
    if ! printf '%s' "$ref" | grep -qE "$DISPOSABLE_IMAGE_RE"; then kept=$((kept + 1)); continue; fi
    iid="$("$DOCKER" images -q "$ref" 2>/dev/null | head -1)"
    [ -n "$iid" ] || continue
    if image_referenced "$ref" "$iid"; then kept=$((kept + 1)); continue; fi
    created_e="$("$DOCKER" image inspect "$ref" --format '{{.Created}}' 2>/dev/null | cut -c1-19)"
    created_e="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$created_e" +%s 2>/dev/null || date -d "$created_e" +%s 2>/dev/null)"
    if [ -z "$created_e" ] || [ "$created_e" -ge "$(( now - IMAGE_AGE_DAYS * 86400 ))" ]; then kept=$((kept + 1)); continue; fi
    if [ "$DRY" -eq 1 ]; then
      log "docker tagged image WOULD be reaped: $ref"
    else
      "$DOCKER" rmi "$ref" >/dev/null 2>&1 && log "docker tagged image reaped: $ref" || { kept=$((kept + 1)); continue; }
    fi
    tags=$((tags + 1))
  done <<< "$("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)"

  log "docker: $reaped anonymous volume(s), $imgs dangling image(s), ${tags:-0} tagged image(s), $kept kept"
}

# ---------------------------------------------------------------- go build cache

# Never while `go` is working. A deleted entry is a cache MISS, not an error, so a
# concurrent build would survive this - but it would also silently pay for it, and a
# reaper that makes somebody's build slower without saying so is the kind of thing that
# gets blamed on the compiler.
# BYPRODUCT_GO_BUSY is a test seam, and it exists because without one the suite reads the
# real process table: on 2026-09-12 another session was running `go test` and two fixture
# cases went red for it. A calibration suite whose result depends on whether somebody is
# compiling is not calibrating anything. Unset -- which is production -- probes for real.
go_is_running() {
  case "${BYPRODUCT_GO_BUSY:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  pgrep -f 'go (build|test|run|vet)|/pkg/tool/.*/(compile|link)' >/dev/null 2>&1
}

go_cache_gb() { du -sm "$GO_CACHE_DIR" 2>/dev/null | awk '{printf "%d", $1/1024}'; }

# The files Go's own trim removes: `<hash>-a` and `<hash>-d` in the two-hex-digit
# subdirectories. Nothing at the top: an old `testexpire.txt` deleted here would make
# test results `go clean -testcache` had expired valid again. Nothing in `fuzz/`, which
# holds generated corpora Go's trim leaves alone. Extra arguments go to find (`-delete`).
go_stale_entries() {
  "$FIND" "$GO_CACHE_DIR" -mindepth 2 -maxdepth 2 -path "$GO_CACHE_DIR/[0-9a-f][0-9a-f]/*" \
    \( -name '*-a' -o -name '*-d' \) -type f -mmin +"$GO_TRIM_MINUTES" "$@" 2>/dev/null
}

reap_go_cache() {
  [ -d "$GO_CACHE_DIR" ] || { log "go cache: $GO_CACHE_DIR does not exist, nothing to reap"; return 0; }
  case "$GO_CACHE_TRIM_DAYS" in ''|*[!0-9]*) log "go cache: BYPRODUCT_GO_CACHE_TRIM_DAYS is not a whole number of days; reaping nothing"; return 0 ;; esac
  [ "$GO_CACHE_TRIM_DAYS" -eq 0 ] && { log "go cache: trim disabled"; return 0; }
  # The idle trims never wait for a running go build; only the full clear below does.
  # With a dozen sessions some go build is nearly always running: on 2026-10-04 the first
  # pressure run stood down on it with 24GB free and falling, and on 2026-10-05 the sweep
  # stood down every time while the cache grew to 36GB over its 30GB ceiling, trimmed only
  # by the below-30GB pressure path. Go's own trim deletes entries while other go processes
  # build, every day, and a missing entry is a miss, never an error: the guard was caution,
  # not correctness.
  local free pressed=0
  free="$(free_gb)"
  case "$GO_FREE_FLOOR_GB:$free" in
    *[!0-9:]*|*:|:*) ;;
    *) [ "$GO_FREE_FLOOR_GB" -gt 0 ] && [ "$free" -lt "$GO_FREE_FLOOR_GB" ] && pressed=1 ;;
  esac

  local before after
  before="$(go_cache_gb)"
  if [ "$DRY" -eq 1 ]; then
    local n
    n="$(go_stale_entries | wc -l | tr -d ' ')"
    log "go cache WOULD trim ${n} entr(ies) older than ${GO_CACHE_TRIM_DAYS}d (cache is ${before:-?}GB)"
    [ -n "$before" ] && [ "$before" -ge "$GO_CACHE_MAX_GB" ] 2>/dev/null \
      && log "go cache WOULD then trim idle entries, halving the horizon to no less than 180m, and clear it only if still at or above the ${GO_CACHE_MAX_GB}GB ceiling"
    return 0
  fi

  # `-delete` rather than `go clean -cache`: this is the same age rule Go applies to
  # itself, so what it removes is what Go would have removed eventually. A full clean is
  # the ceiling's job, not this one's.
  go_stale_entries -delete
  after="$(go_cache_gb)"
  log "go cache: trimmed entries older than ${GO_CACHE_TRIM_DAYS}d (${before:-?}GB -> ${after:-?}GB)"

  local ceiling="$GO_CACHE_MAX_GB"
  case "$pressed:$after" in
    *[!0-9:]*|*:) ;;
    1:*) ceiling=$((after - (GO_FREE_FLOOR_GB - free) + 1))
         [ "$ceiling" -gt "$GO_CACHE_MAX_GB" ] && ceiling="$GO_CACHE_MAX_GB"
         [ "$ceiling" -lt 1 ] && ceiling=1
         log "go cache: ${free}GB free is under the ${GO_FREE_FLOOR_GB}GB floor; ceiling ${ceiling}GB for this run" ;;
  esac

  # The ceiling takes the idlest entries first. It used to empty the whole cache, and
  # between 2026-09-14 and 09-19 it did so seven times, 31-50GB each: every session's next
  # build started cold, on a machine whose load is the scarce thing. What a burst inside
  # the age window leaves is mostly idle: measured 2026-09-25 at 23GB, 0.1GB was past the
  # 3d age, but 5.0GB had been idle over 36h and 12.1GB over 9h. Go keys a build on the
  # package directory, so every worktree compiles its own copy of each package, and a
  # quiet worktree's copies are dead weight. So halve the idle horizon until the cache
  # fits, never below 180m. Go refreshes an entry's mtime when it uses one older than an
  # hour, so an entry idle for hours is in no build's working set, and a missing one is a
  # miss. Emptying it stays as the last resort.
  while [ -n "$after" ] && [ "$after" -ge "$ceiling" ] 2>/dev/null \
        && [ $((GO_TRIM_MINUTES / 2)) -ge 180 ]; do
    GO_TRIM_MINUTES=$((GO_TRIM_MINUTES / 2))
    go_stale_entries -delete
    after="$(go_cache_gb)"
    log "go cache: at or above the ${ceiling}GB ceiling; trimmed entries idle over ${GO_TRIM_MINUTES}m (-> ${after:-?}GB)"
  done

  if [ -n "$after" ] && [ "$after" -ge "$GO_CACHE_MAX_GB" ] 2>/dev/null; then
    if go_is_running; then
      log "go cache: still ${after}GB but a go build started; leaving the ceiling alone"
      return 0
    fi
    # GOCACHE pinned to the directory measured above: without it `go clean` empties
    # whichever cache Go resolves, a different one whenever BYPRODUCT_GO_CACHE_DIR is set.
    GOCACHE="$GO_CACHE_DIR" go clean -cache 2>/dev/null || rm -rf "${GO_CACHE_DIR:?}/"* 2>/dev/null
    log "go cache: was still ${after}GB after the trim, at or above the ${GO_CACHE_MAX_GB}GB ceiling; cleared it"
  fi
}

# ---------------------------------------------------------------- archives

reap_archives() {
  [ -d "$ARCHIVE_ROOT" ] || { log "archives: $ARCHIVE_ROOT does not exist, nothing to reap"; return 0; }
  local reaped=0 kept=0 bytes=0 d name
  for d in "$ARCHIVE_ROOT"/*; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$name" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) kept=$((kept + 1)); continue ;;
    esac
    if [ -n "$("$FIND" "$d" -maxdepth 0 -mtime -"$ARCHIVE_DAYS" 2>/dev/null)" ]; then
      kept=$((kept + 1)); continue
    fi
    bytes=$((bytes + $(kb_of "$d")))
    if [ "$DRY" -eq 1 ]; then
      log "archive WOULD be reaped: $d"
    else
      rm -rf "$d" 2>/dev/null && log "archive reaped: $d" || { FAILED=1; kept=$((kept + 1)); continue; }
    fi
    reaped=$((reaped + 1))
  done
  log "archives: $reaped reaped, $kept kept (retention ${ARCHIVE_DAYS}d), $(freed_mb "$bytes")"
}

# ---------------------------------------------------------------- caches

# The refusal list, consulted for every path before anything is removed. A list of things
# to delete grows by editing one line; this is what stops that edit being the last step
# between somebody's iCloud cache and an `rm -rf`.
#
# It asks about PATHS, not about four literal strings, and that distinction is the whole
# guard. `grep -Fxq`, which is what this was until it was reviewed, protects the exact
# spelling and nothing else - so the edit that will actually happen, listing `~/.cache`
# when the next dead application leaves several subdirectories behind, sails past it and
# the rm -rf underneath takes huggingface, qmd and the uv cache. Measured on the fixture:
# four assertions red, two protected directories gone.
#
# Three relations, all refusing, compared as strings only. No `realpath`: a protected path
# need not exist on a given machine, and a predicate that answers differently depending on
# whether it does is one that stops guarding on the machine that most needs it.
cache_is_protected() {
  local c="$1" p
  while [ "$c" != "${c%/}" ]; do c="${c%/}"; done
  while IFS= read -r p; do
    # Both sides are stripped, and the LIST side is not decoration: as this file ships the
    # four entries carry no trailing slash, so the state this line defends against is
    # unreachable at runtime and every test stays green with it deleted - measured. What
    # makes it load-bearing is the next edit to the list above, which is exactly the edit
    # nothing would have warned anybody about. BYPRODUCT_EXTRA_NEVER_CACHE_PATHS is how
    # the suite reaches that state; it is not the only reason the line is here.
    while [ "$p" != "${p%/}" ]; do p="${p%/}"; done
    [ -n "$p" ] || continue
    # Both comparisons carry a trailing separator, which is what makes "shares a prefix"
    # different from "is inside", once per direction: against the protected `.cache/qmd`,
    # neither `.cache/qmd-old` nor `.cache/qm` is a relative, and both are real dead paths.
    # A bare startswith on either side refuses one of them for ever, and a reaper that has
    # silently stopped reaping looks exactly like a reaper with nothing left to do.
    case "$p/" in "$c/"*) return 0 ;; esac   # C is P, or C is an ancestor of P
    case "$c/" in "$p/"*) return 0 ;; esac   # C is inside P
  done <<< "$CACHE_NEVER"
  return 1
}

reap_caches() {
  local bytes=0 reaped=0 p

  # `uv cache prune` removes only entries nothing references any more - that is what the
  # subcommand is for, and it is why this is not an `rm -rf ~/.cache/uv`, which would cost
  # a re-download of every wheel still in use.
  if ! command -v "$UV" >/dev/null 2>&1; then
    log "caches: no ${UV} on PATH, pruned nothing"
  elif [ "$DRY" -eq 1 ]; then
    log "caches: WOULD run uv cache prune"
  elif "$UV" cache prune >/dev/null 2>&1; then
    log "caches: uv cache pruned of unreferenced entries"
  else
    log "caches: uv cache prune failed" >&2; FAILED=1
  fi

  # Leftovers from applications that are gone. Named one at a time, never matched by a
  # pattern: a glob over ~/.cache would have swept all four of the refusals above. Naming
  # a PARENT of one is the same mistake spelled differently, which is why the predicate
  # below refuses an ancestor as well as an exact match.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if cache_is_protected "$p"; then
      log "cache REFUSED: $p — on the never-reap list; see the reason beside it in this script"
      continue
    fi
    [ -d "$p" ] || { log "cache absent, nothing to reap: $p"; continue; }
    bytes=$((bytes + $(kb_of "$p")))
    if [ "$DRY" -eq 1 ]; then
      log "dead-application cache WOULD be reaped: $p"
    else
      rm -rf "$p" 2>/dev/null || { log "dead-application cache could not be removed: $p" >&2; FAILED=1; continue; }
      log "dead-application cache reaped: $p"
    fi
    reaped=$((reaped + 1))
  done <<< "$CACHE_DEAD_PATHS"

  log "caches: $reaped dead-application path(s), $(freed_mb "$bytes") beyond what uv returned"
}

# ---------------------------------------------------------------- launchd

# The agent the skills repository installed before this moved here. It shares this one's
# log and stamp, so it is retired BEFORE the probe: otherwise its sweep could answer the
# probe, or run beside this agent's first catch-up run, and nothing here holds a lock.
# Disabled first so launchd starts no new run, then waited on while a sweep is in progress
# (unloading signals it), then unloaded and its plist moved aside, never deleted. If this
# install then fails, restore_legacy_agent puts it back exactly as it was.
LEGACY_ASIDE=""
retire_legacy_agent() {
  local legacy="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist" waited=0
  local wait="${BYPRODUCT_LEGACY_WAIT_SECONDS:-900}" aside="$HOME/.cc-reaper/state/retired-agents"
  local target="gui/$(id -u)/$LEGACY_LABEL"
  [ -f "$legacy" ] || return 0
  "$LAUNCHCTL" disable "$target" 2>/dev/null || true
  while "$LAUNCHCTL" print "$target" 2>/dev/null | grep -q 'state = running'; do
    if [ "$waited" -ge "$wait" ]; then
      "$LAUNCHCTL" enable "$target" 2>/dev/null || true
      echo "$LEGACY_LABEL is still running a sweep after ${wait}s; nothing was changed - re-run --install-launchd" >&2
      exit 1
    fi
    sleep 5; waited=$((waited + 5))
  done
  "$LAUNCHCTL" unload "$legacy" 2>/dev/null || true
  LEGACY_ASIDE="$aside/$LEGACY_LABEL.$(date +%Y%m%d%H%M%S).plist"
  if ! { mkdir -p "$aside" && mv "$legacy" "$LEGACY_ASIDE"; }; then
    LEGACY_ASIDE=""
    "$LAUNCHCTL" enable "$target" 2>/dev/null || true
    "$LAUNCHCTL" load "$legacy" 2>/dev/null || true
    echo "could not move $legacy aside; it is loaded again and nothing was installed" >&2
    exit 1
  fi
}
restore_legacy_agent() {
  [ -n "$LEGACY_ASIDE" ] && [ -f "$LEGACY_ASIDE" ] || return 0
  local legacy="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
  mv "$LEGACY_ASIDE" "$legacy" && "$LAUNCHCTL" enable "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null
  "$LAUNCHCTL" load "$legacy" 2>/dev/null || true
  echo "restored $LEGACY_LABEL, since this install did not complete" >&2
}

install_launchd() {
  local at="${1:-04:00}" plist logf
  # The plist names this copy. Run from a checkout, that is a task worktree the janitor will
  # reclaim, and the agent would fail silently from then on: install from the deployed copy.
  if git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "refusing to schedule $HERE/reclaim-byproducts.sh: it is inside a git checkout; run ~/.cc-reaper/reclaim-byproducts.sh --install-launchd" >&2
    exit 1
  fi
  # Two cadences, one installer. StartCalendarInterval is a wall-clock time and can only
  # say "daily at 04:00"; StartInterval is a PERIOD in seconds and is the only launchd key
  # that repeats on one. What it does not do is keep counting while the machine is away:
  # the period is measured from load, sleep pauses it and the wake fires the job ONCE
  # however many periods were missed (they coalesce - a weekend asleep is one catch-up run,
  # not sixteen), and at logout a gui/ agent is unloaded outright so the timer stops until
  # somebody logs back in. That last hole is the one RunAtLoad below already covers, for
  # exactly the same reason it covers the 04:00 missed after a reboot.
  local schedule gate_env='' mode
  case "$at" in
    [0-9][0-9]:[0-9][0-9])
      schedule="  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$((10#${at%%:*}))</integer><key>Minute</key><integer>$((10#${at##*:}))</integer></dict>"
      mode="at $at and at every login"
      ;;
    [0-9]h|[0-9][0-9]h)
      local every=$((10#${at%h}))
      if [ "$every" -lt 1 ] || [ "$every" -gt 24 ]; then
        echo "usage: reclaim-byproducts.sh --install-launchd [Nh]  (N is 1 to 24 hours)" >&2; exit 2
      fi
      # The gate would otherwise cancel the schedule silently. --if-stale is on the
      # scheduled path, so a 12h gate at a 3h cadence lets one firing in four do anything
      # and logs "skipping" for the other three; nothing fails, the schedule just is not
      # the schedule. Half the period is strictly less than it, with the whole second half
      # as margin: a firing that lands early - launchd's timer drifts, and a wake-up
      # firing is a missed period arriving whenever the lid opened - can never be mistaken
      # for one that already ran. It still absorbs what the gate is FOR, the extra run
      # RunAtLoad fires at every login. Carried IN the plist so the installed job says
      # why it will not skip.
      gate_env="<key>BYPRODUCT_MIN_MINUTES</key><string>$((every * 30))</string>"
      schedule="  <key>StartInterval</key><integer>$((every * 3600))</integer>"
      mode="every ${every}h and at every login"
      ;;
    *) echo "usage: reclaim-byproducts.sh --install-launchd [HH:MM | Nh]" >&2; exit 2 ;;
  esac
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.claude/logs"
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  logf="$HOME/.claude/logs/reclaim-byproducts.log"

  # How long to wait for the probe, sized for a REAL dry run rather than for the first
  # line of one. Measured 2026-09-12 on this machine with a 116-scratchpad backlog: 358s
  # wall, nearly all of it the liveness gate - which runs BEFORE the `scratchpads:`
  # summary every verdict below is keyed on. 900s is 2.5x the worst run measured, so a
  # bigger backlog still answers instead of timing out. It is a ceiling, not a cost: the
  # wait ends the moment the evidence appears.
  local probe="${BYPRODUCT_LAUNCHD_PROBE_SECONDS:-900}"

  # What was installed before this ran. Captured because overwriting the plist is the
  # first thing this function does, so without a copy an inconclusive probe - the branch
  # below - has no way to leave the machine as it found it. Empty means no agent.
  local prev=""
  [ -f "$plist" ] && prev="$(cat "$plist")"

  # An agent that LOADS is not an agent that RUNS. reclaim-inventory.sh reported
  # "installed" for a job whose first firing produced only `Operation not permitted`,
  # because launchd's /bin/bash holds no Full Disk Access grant. The probe below is
  # the real agent, fired once with --dry-run, so proving the schedule can run never
  # costs anything.
  plist_text() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$HERE/reclaim-byproducts.sh</string>$1</array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>$gate_env</dict>$2
$schedule
  <key>StandardOutPath</key><string>$logf</string>
  <key>StandardErrorPath</key><string>$logf</string>
</dict>
</plist>
PLIST
  }
  write_plist() { plist_text "$1" "$2" > "$plist"; }

  # Installing what is already installed must cost nothing, because re-running the
  # installer is how a second session says "make sure this is set up" - and until
  # 2026-09-13 that rewrote the plist, booted the job out and back in, and truncated the
  # log. Measured: the plist was rewritten at 10:19:34 that morning by exactly such a
  # re-run, which reset launchd's `runs` counter to 1 and destroyed the only evidence that
  # the 3-hour timer had ever fired. An installer that erases the proof its own schedule
  # works is worse than one that does nothing.
  #
  # Both halves are required. Identical CONTENT with no job loaded is a plist somebody
  # left behind, and LOADED with different content is an agent running yesterday's
  # arguments; each has to be repaired, and neither is repaired by leaving it alone.
  local final
  final="$(plist_text '<string>--if-stale</string>' '
  <key>RunAtLoad</key><true/>')"
  if [ -n "$prev" ] && [ "$final" = "$prev" ] && "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "$LABEL is already installed $mode and loaded; nothing changed (log: $logf)"
    retire_legacy_agent
    [ -z "$LEGACY_ASIDE" ] || echo "retired $LEGACY_LABEL (plist kept in ${LEGACY_ASIDE%/*})"
    LEGACY_ASIDE=""
    return 0
  fi

  retire_legacy_agent

  # No RunAtLoad on the probe plist: loading it would fire the job once and the kickstart
  # below again, and on a backlogged machine one dry run is six minutes.
  write_plist '<string>--dry-run</string>' ''
  "$LAUNCHCTL" unload "$plist" 2>/dev/null || true
  "$LAUNCHCTL" load "$plist" || { echo "could not load $plist" >&2; exit 1; }

  : > "$logf"
  "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  # Wait for the SHAPE the verdict is about to judge, never merely for output to exist.
  #
  # This loop stopped at `[ ! -s "$logf" ]` until 2026-09-12, and that cost the live
  # agent: a dry run takes 358s and prints `-- scratchpads` in its first second, so the
  # wait returned after one second holding one line, the `scratchpads:` check below found
  # no summary in it, and the installer refused a perfectly good install and `rm`ed
  # com.claude.reclaim-byproducts on the way out. A probe that waits for output to EXIST
  # and then asks a question only FINISHED output can answer gets a wrong answer at speed.
  local w=0
  while [ "$w" -lt "$probe" ]; do
    grep -q 'scratchpads:' "$logf" 2>/dev/null && break
    # Not one line of this script's own output this long after the kickstart: the job did
    # not start (`/bin/bash: ...: Operation not permitted` is launchd's line, not ours),
    # and every verdict below can already be rendered. A latency bound only - it decides
    # when the loop stops, never what any verdict says - so that the commonest refusal is
    # not also the slowest one under a deadline sized for a whole sweep.
    [ "$w" -ge 20 ] && ! grep -q '^-- ' "$logf" 2>/dev/null && break
    sleep 1; w=$((w + 1))
  done

  # Silence has not answered the question either. Treating it as success is how the
  # sibling installer shipped broken.
  if [ ! -s "$logf" ]; then
    "$LAUNCHCTL" unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "the probe run produced no output at all; not installing" >&2
    exit 1
  fi
  if grep -qiE 'operation not permitted|permission denied|not permitted' "$logf"; then
    "$LAUNCHCTL" unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "the scheduled job cannot start; not installing. Its output was:" >&2
    sed -n '1,5p' "$logf" >&2
    echo "grant Full Disk Access to /bin/bash (the plist's program), not to your terminal." >&2
    exit 1
  fi
  # Output is not the same as output from the reapers. A run that refused early - no
  # liveness gate, a bad window, or a staleness skip if the probe were ever given
  # --if-stale - prints a line, and the emptiness check above would take it for proof.
  # This is why the probe is --dry-run: the stamp must not be able to answer for it.
  #
  # What this is NOT allowed to be is a refusal. The job printed, so the failure the two
  # checks above exist to catch - nothing executed at all - is already disproved; what is
  # missing is the evidence for the NEXT question, and a probe that cannot answer a
  # question is inconclusive, not a verdict. Read as a refusal on 2026-09-12 it deleted
  # the live agent, and the daily reclamation would simply have stopped, silently, on the
  # machine it was installed to protect.
  #
  # So an inconclusive probe changes nothing at all. The plist that was loaded before goes
  # back exactly as it was; if there was none there is none now, because installing an
  # agent whose only probe never finished would claim the proof this branch is admitting
  # it does not have. What is never left behind is the probe plist itself - it carries
  # --dry-run, and a nightly job that reaps nothing is the same outage in a quieter
  # costume. Loud either way: silence is what made the first one invisible.
  if ! grep -q 'scratchpads:' "$logf"; then
    "$LAUNCHCTL" unload "$plist" 2>/dev/null || true
    if [ -n "$prev" ]; then
      printf '%s\n' "$prev" > "$plist"
      "$LAUNCHCTL" load "$plist" >/dev/null 2>&1 || true
      echo "the probe run never reached the reapers within ${probe}s; nothing was changed - the agent that was already installed is loaded again, exactly as it was. Its output was:" >&2
    else
      rm -f "$plist"
      echo "the probe run never reached the reapers within ${probe}s; nothing was installed, and nothing was installed before either. Its output was:" >&2
    fi
    sed -n '1,5p' "$logf" >&2
    echo "a run that is merely slow finishes later: re-run with BYPRODUCT_LAUNCHD_PROBE_SECONDS higher, or read $logf to see where it stopped." >&2
    exit 1
  fi

  # RunAtLoad means this load fires the job, so the install itself is the first catch-up
  # run - and --if-stale means it is a no-op when one finished inside the gate above.
  write_plist '<string>--if-stale</string>' '
  <key>RunAtLoad</key><true/>'
  "$LAUNCHCTL" unload "$plist" 2>/dev/null || true
  "$LAUNCHCTL" load "$plist" || { echo "could not load $plist" >&2; exit 1; }
  echo "installed $LABEL $mode (log: $logf); its probe run reaped nothing"
  [ -z "$LEGACY_ASIDE" ] || echo "retired $LEGACY_LABEL (plist kept in ${LEGACY_ASIDE%/*})"
  LEGACY_ASIDE=""
}

# ---------------------------------------------------------------- main

case "${1:-}" in
  --dry-run) DRY=1 ;;
  # The go cache alone, for a caller that just watched the disk run low (the CI runner
  # loop, when it starts declining jobs). No scratchpad liveness gate - that is the slow
  # part, minutes - and no stamp, so the scheduled full sweep is not pushed back.
  --go-cache) rotate_log; log "== go cache only $(now_iso) (pid $$) =="; reap_go_cache; exit 0 ;;
  --if-stale) CHECK_STALE=1 ;;
  --install-launchd) trap restore_legacy_agent EXIT; install_launchd "${2:-04:00}"; exit 0 ;;
  --self-test) exec bash "$REPO_HERE/../tests/reclaim-byproducts.sh" ;;
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# The ledger opens HERE, above the two gates below, because a firing that refused and a
# firing that skipped are both firings and the question this answers is how often the
# timer fires. The header is the separator the log did not have either: two sweeps ran
# into each other in it with nothing between them.
MODE=reap
[ "$CHECK_STALE" -eq 1 ] && MODE=scheduled
[ "$DRY" -eq 1 ] && MODE=dry-run
rotate_log
FREE_BEFORE="$(free_kb)"
log "== byproducts sweep started $(now_iso) (${MODE}, ${GATE} gate, pid $$) =="
trap sweep_ended EXIT

if [ ! -r "$PATH_IN_USE" ]; then
  # Without the liveness gate there is no safe scratchpad rule, and reaping the other
  # two while pretending the run was complete is the blind success this file avoids.
  echo "byproducts: $PATH_IN_USE is not readable; reaping nothing" >&2
  exit 1
fi

# Only the scheduled path passes --if-stale. A human running this to reclaim disk right
# now is never told the job ran recently, so there is nothing to have to get past. It is
# checked after the liveness gate above on purpose: a broken install must still shout on
# every firing, not fall silent for a whole window because somebody's hand-run stamped.
if [ "$CHECK_STALE" -eq 1 ] && ran_recently; then
  log "byproducts: a reap completed less than ${GATE} ago (stamp: $STAMP); skipping"
  exit 0
fi

log "-- scratchpads"; reap_scratchpads
log "-- go cache";   reap_go_cache
log "-- docker";      reap_docker
log "-- archives";    reap_archives
log "-- caches";      reap_caches

[ "$FAILED" -eq 0 ] || { echo "byproducts: at least one reap failed — see above" >&2; exit 1; }
# Only a run that reaped, and finished. A dry run reported; a failed one left work behind,
# and stamping either would suppress the next scheduled run that could have done it.
[ "$DRY" -eq 1 ] || write_stamp
exit 0
