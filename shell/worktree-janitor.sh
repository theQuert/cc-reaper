#!/usr/bin/env bash
# worktree-janitor: read-only inventory and optional cleanup of stale git worktrees.
#
# Can be sourced for the _cc_wj_* functions or executed directly:
#   bash shell/worktree-janitor.sh
#   bash shell/worktree-janitor.sh --apply

# The deployed config is the policy owner.  Preserve explicit environment values so a
# one-shot diagnostic or test can override the installed cross-device policy.
_CC_WJ_CONFIG_ERROR=""
_CC_WJ_ORDER=""
_CC_WJ_CONFIG_FILE="${CC_WJ_CONFIG:-$HOME/.cc-reaper/worktree-janitor.conf}"
_CC_WJ_PRE_IDLE_SET="${CC_WJ_IDLE_HOURS+x}"; _CC_WJ_PRE_IDLE="${CC_WJ_IDLE_HOURS-}"
_CC_WJ_PRE_GRACE_SET="${CC_WJ_SESSION_GRACE_HOURS+x}"; _CC_WJ_PRE_GRACE="${CC_WJ_SESSION_GRACE_HOURS-}"
_CC_WJ_PRE_SESSION_SET="${CC_WJ_SESSION_APPLY+x}"; _CC_WJ_PRE_SESSION="${CC_WJ_SESSION_APPLY-}"
_CC_WJ_PRE_SCHEDULE_SET="${CC_WJ_SCHEDULE_APPLY+x}"; _CC_WJ_PRE_SCHEDULE="${CC_WJ_SCHEDULE_APPLY-}"
_CC_WJ_PRE_ROOT_SET="${CC_WJ_ROOT+x}"; _CC_WJ_PRE_ROOT="${CC_WJ_ROOT-}"
if [ -e "$_CC_WJ_CONFIG_FILE" ]; then
  if [ ! -r "$_CC_WJ_CONFIG_FILE" ]; then
    _CC_WJ_CONFIG_ERROR="config $_CC_WJ_CONFIG_FILE is unreadable"
  elif ! . "$_CC_WJ_CONFIG_FILE"; then
    _CC_WJ_CONFIG_ERROR="config $_CC_WJ_CONFIG_FILE could not be loaded"
  fi
fi
[ -z "$_CC_WJ_PRE_IDLE_SET" ] || CC_WJ_IDLE_HOURS="$_CC_WJ_PRE_IDLE"
[ -z "$_CC_WJ_PRE_GRACE_SET" ] || CC_WJ_SESSION_GRACE_HOURS="$_CC_WJ_PRE_GRACE"
[ -z "$_CC_WJ_PRE_SESSION_SET" ] || CC_WJ_SESSION_APPLY="$_CC_WJ_PRE_SESSION"
[ -z "$_CC_WJ_PRE_SCHEDULE_SET" ] || CC_WJ_SCHEDULE_APPLY="$_CC_WJ_PRE_SCHEDULE"
[ -z "$_CC_WJ_PRE_ROOT_SET" ] || CC_WJ_ROOT="$_CC_WJ_PRE_ROOT"
unset _CC_WJ_PRE_IDLE_SET _CC_WJ_PRE_IDLE _CC_WJ_PRE_SESSION_SET _CC_WJ_PRE_SESSION
unset _CC_WJ_PRE_GRACE_SET _CC_WJ_PRE_GRACE
unset _CC_WJ_PRE_SCHEDULE_SET _CC_WJ_PRE_SCHEDULE _CC_WJ_PRE_ROOT_SET _CC_WJ_PRE_ROOT

_cc_wj_usage() {
  cat <<'EOF'
Usage: worktree-janitor [options]

Inventory and optionally remove stale git worktrees across local repos.

Options:
  --apply             Remove REMOVABLE worktrees (default: report only)
  --trim-regenerable  Report or, with --apply, remove only ignored built-in regenerable
                      directories (for example node_modules) from unheld, unclaimed
                      worktrees; the worktree and branch remain
  --repo <path>       Scan only this repo (repeatable; replaces auto-discovery)
  --landed <path>     Print the shared landed proof for one worktree; change nothing
  --claims [id|path]  Print live claims and recent-session leases, optionally filtered
  --session           Sweep the current Claude/Codex repository, detached (SessionEnd hook)
  --scheduled         Apply only when CC_WJ_SCHEDULE_APPLY=1; otherwise report
  -h, --help          Show this help

Environment:
  CC_WJ_ROOT              Root directory to discover repos under (default: ~/Documents/GitHub)
  CC_WJ_HARNESS_ROOTS     Colon-separated Claude/Codex worktree roots
  CC_WJ_LOG               Log file path (default: ~/.cc-reaper/logs/worktree-janitor.log)
  CC_WJ_STATE_DIR         State directory for cooldown files (default: ~/.cc-reaper/state)
  CC_WJ_IDLE_HOURS        Keep a worktree modified within this many hours (default: 48)
  CC_WJ_SESSION_GRACE_HOURS Keep a worktree after mapped harness activity (default: 48)
  CC_WJ_RECLAIM_PUSHED    1 (default): a worktree whose HEAD origin already holds is removable;
                          tracked edits and untracked files are first pushed to
                          refs/wip/$CC_WJ_WIP_LABEL/<name>-<UTC stamp> (only with --apply)
                          and read back. 0: landed on the base branch only
  CC_WJ_WIP_LABEL         Namespace under refs/wip/ for those snapshots (default: macmini)
  CC_WJ_NOTIFY_MIN_GB     Disk savings threshold in GB to trigger notification (default: 1)
  CC_WJ_COOLDOWN_SECS     Notification cooldown in seconds (default: 3600)
  CC_WJ_BASE_BRANCH       Integration branch (default: origin's default branch)
  CC_WJ_SESSION_APPLY     Set to 1 to let --session remove (default: report only)
  CC_WJ_SCHEDULE_APPLY    Set to 1 to let --scheduled remove (default: report only)
  CC_WJ_PRESSURE_FREE_GB  Below this many GB free, the disk pressure tier applies
                          (default: 100; off or 0 disables it)
  CC_WJ_PRESSURE_IDLE_HOURS, CC_WJ_PRESSURE_SESSION_GRACE_HOURS
                          The idle window and session lease under pressure (default: 2)
  CC_WJ_TRIM_DIRTY_IDLE_HOURS
                          A worktree with uncommitted files is trimmed only after this many
                          hours untouched (default: 168; 0 never trims a dirty worktree)
  CC_WJ_PRESSURE_TRIM     1 (default): a scheduled apply under pressure also trims the
                          regenerable caches of the worktrees it kept
  CC_WJ_SWEEP_BUDGET_SECONDS
                          Seconds each phase of an apply run may examine worktrees before
                          it yields to the next sweep, which resumes where it stopped
                          (default: 1800; 0 is unbounded)
  CC_WJ_ORDER             largest (default): each repository's worktrees are examined by their
                          last known size, largest first, so a sweep the budget cuts short has
                          spent it where the bytes are; path: in path order, as before
  CC_WJ_GROWTH_SAMPLES, CC_WJ_GROWTH_TARGETS
                          growth-watch's samples and targets, the sizes largest-first reads
                          besides its own (default: those disk-janitor --check writes and reads)
  CC_WJ_LSOF_TIMEOUT_SECONDS, CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS
                          Bounds on the machine-wide lsof scans and the Codex lock registry
                          scan, each retried once on a timeout (default: 120, 30)
  CC_WJ_RECHECK_FRESH_SECONDS
                          A trim reuses a holder/session snapshot younger than this before a
                          later cache directory of the same worktree (default: 120)
  CC_WJ_SESSION_LOG       --session log (default: ~/.cc-reaper/logs/worktree-janitor-session.log)
  CC_WJ_CLAUDE_SESSIONS  Claude live-session registry (default: ~/.claude/sessions)
  CC_WJ_CLAUDE_PROJECTS  Claude transcript registry (default: ~/.claude/projects)
  CC_WJ_CODEX_LOCKS      Codex writer-lock registry (default: ~/.codex/thread-writer-locks)
  CC_WJ_CODEX_SESSIONS   Codex active rollout registry (default: ~/.codex/sessions)
  CC_WJ_CODEX_STATE_DB   Codex local state database (default: ~/.codex/state_5.sqlite)
  CC_WJ_TOOL_DIRS        Directories appended to PATH when executed, for `gh` under launchd
                         (default: /opt/homebrew/bin:/usr/local/bin:~/.local/bin; empty: none)
  CC_WJ_LAUNCHD_DIRS     Colon-separated directories of launchd agent plists; every absolute path a
                         plist names counts as held (default: ~/Library/LaunchAgents; empty: none)
  CC_WJ_ARCHIVE_DIR      Where --apply copies archive:-declared files before a removal
                         (default: ~/.cc-reaper/archive)
  CC_WJ_ARCHIVE_MAX_BYTES Largest file an archive: declaration lets leave (default: 1048576)
  CC_WJ_NEW_RULES_MODE   spotcheck (default; any other value too) or auto. Whether a top-level
                         ignored *.log file and a .claude/skills or .claude/commands symlink into
                         the primary checkout stop keeping a worktree (auto), or only have what
                         they would trim or remove logged to CC_WJ_SPOTCHECK_LOG (spotcheck)
  CC_WJ_SPOTCHECK_LOG    (default: ~/.cc-reaper/logs/spotcheck-worktree-janitor.log)
  CC_WJ_UNKNOWN_SESSION_SCOPE  tree (default) or global (any other value too). With tree, a
                         session record that cannot be read keeps only the worktrees it could be
                         about (KEEP(session-unknown:<record>)), under CC_WJ_NEW_RULES_MODE: in
                         spotcheck every decision stays as global and the trees it would free are
                         logged (rule session-unknown-per-tree). global keeps every worktree
  CC_WJ_DENY_NAMES      Whitespace-separated names; a worktree whose directory name or branch
                         contains one, or that a live Claude session of that name stands in, is
                         never trimmed or removed (default: none; the installed config sets it)

A worktree is removable only when it holds nothing a command cannot rebuild - or that an
archive: line in .worktree-regenerable lets --apply copy out first - no process
has it as a working directory or holds a file in it, its work has landed on the fetched
base branch, and nothing in it changed within CC_WJ_IDLE_HOURS. Branches are never deleted.
A clean worktree whose claude-task-done annotation names its HEAD, on a branch, is judged
without that window and without the recent-session lease.
`--trim-regenerable` uses the same holder and harness claim vetoes but does not require
landing; it never removes tracked or non-regenerable content.
EOF
}

# ─── Config defaults ──────────────────────────────────────────────────────────

# Colon-separated, because one root was never enough and the single default was
# wrong on the machine that reported this: `~/Documents/GitHub` did not exist, so
# discovery found no repositories, said "no repos found", and exited 0 - the same
# output and the same status as a machine with nothing to clean. 34 GB of stale
# worktrees sat under `~/Documents` and `~/GitHub` throughout.
_cc_wj_roots() {
  printf '%s\n' "${CC_WJ_ROOT:-$HOME/Documents/GitHub:$HOME/GitHub:$HOME/Documents}" | tr ':' '\n'
}

_cc_wj_harness_roots() {
  printf '%s\n' "${CC_WJ_HARNESS_ROOTS:-$HOME/.claude/worktrees:$HOME/.codex/worktrees}" | tr ':' '\n'
}

# Back-compat for anything sourcing the old single-root helper.
_cc_wj_root() {
  _cc_wj_roots | head -1
}

_cc_wj_log() {
  echo "${CC_WJ_LOG:-$HOME/.cc-reaper/logs/worktree-janitor.log}"
}

_cc_wj_state_dir() {
  echo "${CC_WJ_STATE_DIR:-$HOME/.cc-reaper/state}"
}

_cc_wj_notify_min_gb() {
  local v="${CC_WJ_NOTIFY_MIN_GB:-1}"
  echo "$v" | grep -qE '^[0-9]+([.][0-9]+)?$' || v=1
  echo "$v"
}

_cc_wj_cooldown_secs() {
  local v="${CC_WJ_COOLDOWN_SECS:-3600}"
  echo "$v" | grep -qE '^[0-9]+$' || v=3600
  echo "$v"
}

# How long a worktree must sit untouched before it may go. Clean, unheld and landed are
# all true of a worktree somebody committed to a minute ago from another directory.
#
# Validated rather than defaulted. A malformed duration makes `find` fail, a failed find
# prints nothing, and nothing reads exactly like "nothing was touched" - the companion
# reclaimer in theQuert/skills sat on `off` for a week while 78 worktrees accumulated.
# Five digits at most, because `find -mmin` on a sixteen-digit count wraps.
_cc_wj_idle_hours() {
  local v="${CC_WJ_IDLE_HOURS:-48}"
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  echo $((10#$v))
}

# How long an UNLANDED worktree whose branch never opened a pull request may sit before it
# counts as abandoned rather than in progress. Deliberately much longer than the idle
# window: `KEEP(unlanded)` is the right answer for work on its way somewhere, and the only
# thing separating that from work that stopped is time plus the absence of a pull request.
# Measured on the reporting host 2026-09-20: 53 of 133 worktrees classified KEEP(unlanded),
# 27 of them older than seven days with no pull request ever opened, holding 27 GB that no
# sweep could ever reclaim because nothing was on its way to the base branch.
_cc_wj_abandon_hours() {
  local v="${CC_WJ_ABANDON_HOURS:-168}"
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  echo $((10#$v))
}

# A released writer lock or dead session pid proves only that the task is not live now.
# It does not prove that an archive was intentional or that the operator will not resume it.
# This independent lease resets on harness activity even when no worktree file changed.
_cc_wj_session_grace_hours() {
  local v="${CC_WJ_SESSION_GRACE_HOURS:-48}"
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  echo $((10#$v))
}

# `git status --ignored` walks the whole checkout. Bound it so one pathological or
# unavailable filesystem cannot prevent every later worktree and future schedule from
# being examined. Expiry is conservative: an unreadable status pins the worktree.
_cc_wj_git_status_timeout_seconds() {
  local v="${CC_WJ_GIT_STATUS_TIMEOUT_SECONDS:-300}" n
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  n=$((10#$v))
  [ "$n" -gt 0 ] || return 1
  echo "$n"
}

# Scheduled agents deliberately yield I/O priority, so a fetch that is fast in a terminal
# can need longer in launchd. Keep it bounded, but leave enough budget for that scheduling
# difference instead of making every run permanently unable to prove work landed.
_cc_wj_fetch_timeout_seconds() {
  local v="${CC_WJ_FETCH_TIMEOUT_SECONDS:-180}" n
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  n=$((10#$v))
  [ "$n" -gt 0 ] || return 1
  echo "$n"
}

# A whole number of seconds below 100000 on stdout; fails on anything else, and on 0 unless
# $2 is `zero-ok`.
_cc_wj_seconds() {
  case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac
  [ $((10#$1)) -gt 0 ] || [ "${2:-}" = zero-ok ] || return 1
  echo $((10#$1))
}

# On 2026-10-06, at load 50-70, scheduled sweeps ran 1667 s, 5913 s and over 80 minutes,
# holding the repository lock throughout, so every SessionEnd sweep in that window deferred
# and removed nothing. Each phase of an apply run (the removal sweep, the scheduled trim)
# stops examining worktrees past this budget and leaves the rest to the next sweep. 0 is
# unbounded.
_cc_wj_sweep_budget_seconds() { _cc_wj_seconds "${CC_WJ_SWEEP_BUDGET_SECONDS:-1800}" zero-ok; }
# How old a holder and session snapshot may be and still decide a later cache directory of
# the same worktree in a trim. 0 rescans before every directory.
_cc_wj_recheck_fresh_seconds() { _cc_wj_seconds "${CC_WJ_RECHECK_FRESH_SECONDS:-120}" zero-ok; }
# The machine-wide lsof scans: one at load 60 needed 70 s against a hardcoded 60.
_cc_wj_lsof_timeout_seconds() { _cc_wj_seconds "${CC_WJ_LSOF_TIMEOUT_SECONDS:-120}"; }
# The Codex writer-lock registry scan, `lsof +D` over one small directory.
_cc_wj_lock_scan_timeout_seconds() { _cc_wj_seconds "${CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS:-30}"; }

# Run a command under a time bound that ends its whole process group; exit 124 on expiry.
#
# `alarm; exec` bounds nothing that matters here: `gh` is a Go binary that ignores
# SIGALRM, and lsof sets alarms of its own that replace an inherited one. So the command
# runs as a child in its own process group while perl keeps the clock. The group is what
# is signalled - and signalled again after the child exits - because a grandchild still
# holding the output pipe keeps `$(...)` waiting after its parent is gone. TERM, INT and
# HUP are passed on, since a signal to the caller's group no longer reaches the command.
# Without perl the command runs unbounded.
_cc_wj_with_timeout() {
  local secs="$1"; shift
  command -v perl >/dev/null 2>&1 || { "$@"; return; }
  perl -MPOSIX=:sys_wait_h -e '
    my $secs = shift;
    defined(my $pid = fork) or exit 125;
    if (!$pid) { setpgrp(0, 0); exec @ARGV or POSIX::_exit(127) }
    my $end = sub {
      my $code = shift;
      kill "TERM", -$pid;
      for (1 .. 20) { last if waitpid($pid, WNOHANG) > 0; select undef, undef, undef, 0.1 }
      kill "KILL", -$pid; waitpid $pid, 0; exit $code };
    $SIG{ALRM} = sub { $end->(124) };
    $SIG{TERM} = sub { $end->(143) };
    $SIG{INT}  = sub { $end->(130) };
    $SIG{HUP}  = sub { $end->(129) };
    alarm $secs;
    waitpid $pid, 0;
    my $rc = WIFEXITED($?) ? WEXITSTATUS($?) : 128 + WTERMSIG($?);
    kill "KILL", -$pid;
    exit $rc;' "$secs" "$@"
}

# ─── Logging ──────────────────────────────────────────────────────────────────

# Bound a log to one live file plus one previous generation. cc-reaper reaps
# other tools for leaking; an unbounded log of its own is the same fault.
#
# Copy-then-truncate rather than rename: truncating keeps the inode, so a
# descriptor launchd already opened for StandardOutPath stays valid and keeps
# appending to the live file. A rename would leave launchd filling the ".old"
# copy while the live path stayed empty.
_cc_wj_bound_log() {
  local file=$1 max=${2:-1048576} size=""
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] && [ "$size" -gt "$max" ] || return 0
  cp -f "$file" "$file.old" 2>/dev/null && : > "$file" 2>/dev/null
  return 0
}

_cc_wj_log_write() {
  local log
  log=$(_cc_wj_log)
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  # Bound from here rather than the direct-execution guard: this file is also
  # sourced, and a sourced `_cc_wj_run` would otherwise append without any cap.
  # Checked on every write rather than once per process — a long-lived shell that
  # sourced this file would keep a one-shot flag set across runs and never look
  # again. A run writes a handful of lines, so the cost is a handful of stats.
  _cc_wj_bound_log "$log"
  printf "[%s] %s\n" "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$log" 2>/dev/null || true
}

# ─── Repo discovery ───────────────────────────────────────────────────────────

# Emit one path per line: each directory directly under root that is a git repo
# Sets CC_WJ_BLIND=1 when a configured root exists but cannot be read. A root that
# is simply absent is not an error - a default list naming three plausible locations
# will always miss some - but one that is there and denied means this run swept less
# than it was asked to, and that has to reach the exit status. Under launchd on macOS
# the usual cause is TCC: `~/Documents`, `~/Desktop` and `~/Downloads` need a Full
# Disk Access grant for the program in the plist, and without it every call is denied
# while the run still reports normally.
# Emit one line per configured root that exists and cannot be read. A root that is
# simply absent is not an error - a default list naming three plausible locations will
# always miss some - but one that is there and denied means this run swept less than it
# was asked to. Under launchd on macOS the usual cause is TCC: `~/Documents`,
# `~/Desktop` and `~/Downloads` need a Full Disk Access grant for the program in the
# plist, and without it every call is denied while the run reports normally.
#
# Called from `_cc_wj_run` rather than reported by `_cc_wj_discover_repos`: that one is
# consumed through a process substitution, so a flag it sets is set in a child and the
# caller never sees it.
# The binary that must hold the grant, named rather than described.
#
# TCC grants are per-EXECUTABLE, and the executable under launchd is the interpreter,
# not this script: the plist runs `/bin/bash /path/to/worktree-janitor.sh`. Measured
# 2026-09-01, in a sibling project whose message had this same shape: an operator
# granted Full Disk Access in direct response to it and the grant landed on their
# terminal and their editor - both of which already had it, neither of which is what
# launchd spawns - while `/bin/bash` stayed absent from the TCC database entirely. The
# next run printed the identical denial.
#
# `install.sh` has said the precise thing since it was written, including the trade-off
# and the alternative it prefers. This is the message the operator sees at the moment
# it actually bites, and it was the weaker of the two.
_cc_wj_grant_target() {
  local prog
  prog="$(ps -o comm= -p $$ 2>/dev/null | sed 's/^-//')"
  case "$prog" in
    /*) printf '%s' "$prog" ;;
    *)  printf '%s' "${BASH:-/bin/bash}" ;;
  esac
}

_cc_wj_unreadable_roots() {
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    # Mode bits are a cheap pre-filter, not the answer: TCC can deny enumeration
    # after they say yes, an ACL can block listing, and permissions can change
    # between the two probes. So the question is asked the way discovery asks it -
    # by listing - and a listing that fails marks the root blind. Piped straight
    # into a `while`, that failure produced an empty list indistinguishable from a
    # root holding no repositories, and the run reported success.
    { [ -r "$root" ] && [ -x "$root" ]; } || { echo "$root"; continue; }
    find "$root" -maxdepth 1 -mindepth 1 -type d >/dev/null 2>&1 || echo "$root"
  done < <({ _cc_wj_roots; _cc_wj_harness_roots; } | awk '!seen[$0]++')
}

_cc_wj_discover_repos() {
  local root d
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ] || continue
    # Use find at depth 1: repos have a .git entry (file for worktrees, dir for real repos)
    find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r d; do
      if [ -e "$d/.git" ]; then
        echo "$d"
      fi
    done
  done < <(_cc_wj_roots)

  # Harness-managed checkouts may be nested under a private root or belong to a second
  # clone of a repository already present under ~/GitHub.  Looking only one level below
  # ordinary source roots made those worktrees completely absent from the report.
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] && [ -r "$root" ] && [ -x "$root" ] || continue
    find "$root" -mindepth 1 -maxdepth 5 -name .git -print -prune 2>/dev/null |
      while IFS= read -r d; do dirname "$d"; done
  done < <(_cc_wj_harness_roots)
}

# ─── Holders ──────────────────────────────────────────────────────────────────

# Run a bounded scan into file $2, and once more when the first attempt timed out (124):
# under load a scan can miss one bound, and a second attempt is cheaper than a sweep that
# keeps everything. Any other failure, or a second timeout, is final.
_cc_wj_scan_retry() { # <seconds> <output file> <command...>
  local secs="$1" out="$2" rc
  shift 2
  _cc_wj_with_timeout "$secs" "$@" > "$out" 2>/dev/null; rc=$?
  [ "$rc" -eq 124 ] || return "$rc"
  _cc_wj_with_timeout "$secs" "$@" > "$out" 2>/dev/null
}

# Absolute paths named by launchd agent plists, one per line. A StartInterval job holds its
# script and config only while it runs, so between ticks no process names the worktree they
# live in and the lsof scan sees nothing (2026-10-15: tech.stima.event-gateway-feed ran
# `python3 <worktree>/.../mac_feed.py` every 60 s; an idle-window sweep removed the worktree
# and the job then failed ~1,230 times). A plist that cannot be read names nothing: this
# only ever adds holders, so it can never make the scan fail or a worktree removable.
_cc_wj_launchd_paths() {
  local d f p
  command -v plutil >/dev/null 2>&1 || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*.plist; do
      [ -f "$f" ] || continue
      plutil -convert xml1 -o - -- "$f" 2>/dev/null |
        sed -n 's|^.*<string>\(/[^<]*\)</string>.*$|\1|p' |
        sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' |
        while IFS= read -r p; do
          printf '%s\n' "$p"
          # lsof reports physical paths; a plist spells what its author typed.
          [ -d "${p%/*}" ] && _cc_wj_realpath "$p"
        done
    done
  done <<< "$(printf '%s' "${CC_WJ_LAUNCHD_DIRS-$HOME/Library/LaunchAgents}" | tr ':' '\n')"
  return 0
}

# Scan every process's working directory and every open file on the machine, once, into
# $1/cwd and $1/open as one path per line. Fails when either scan fails or comes back
# empty.
#
# Every process, not a `pgrep` subset: a session editing a task worktree through
# `git -C` and absolute paths has its own cwd in the primary checkout, and an editor or a
# dev server holding files in the worktree was never on the list. Open files, not only
# cwds, for the same reason. One machine-wide listing rather than `lsof +D` per worktree:
# `+D` walks the tree it is given, and a worktree with `node_modules` is a quarter of a
# million files.
#
# The status is lsof's, not the formatter's, and an empty listing is a failure: every
# live system has at least this shell's working directory in it, so no lines means the
# scan saw nothing - which would otherwise read as permission to remove everything.
#
# lsof prints a byte it will not print as `\xNN` and doubles a backslash. No locale avoids
# that: in the C locale a hook inherits it spells `caf\xc3\xa9`, and even under en_US.UTF-8
# it escapes U+200B, U+200F, U+FEFF and U+0085. So the scan runs in the C locale, where
# every non-ASCII byte is escaped the same way, and the names are decoded back to raw bytes.
# $1/decoded exists only when they were; without perl the names stay as lsof spelled them.
_cc_wj_scan_holders() {
  local dir="$1" f secs
  command -v lsof >/dev/null 2>&1 || return 1
  secs="$(_cc_wj_lsof_timeout_seconds)" || return 1
  _cc_wj_scan_retry "$secs" "$dir/cwd.raw" env LC_ALL=C lsof -n -P -d cwd -Fn || return 1
  _cc_wj_scan_retry "$secs" "$dir/open.raw" env LC_ALL=C lsof -n -P -Fn || return 1
  rm -f "$dir/decoded"
  if command -v perl >/dev/null 2>&1; then
    for f in cwd open; do
      LC_ALL=C perl -ne 'next unless s/^n//; s/\\(\\|x([0-9a-fA-F]{2}))/defined $2 ? chr(hex $2) : "\\"/ge; print' \
        "$dir/$f.raw" > "$dir/$f" || return 1
    done
    : > "$dir/decoded"
  else
    for f in cwd open; do
      sed -n 's/^n//p' "$dir/$f.raw" > "$dir/$f"
    done
  fi
  [ -s "$dir/cwd" ] && [ -s "$dir/open" ] || return 1
  _cc_wj_launchd_paths >> "$dir/open" 2>/dev/null
  return 0
}

# Whether a scan in $1 names worktree $2, or anything under it, by either spelling: git
# records the path a worktree was added with, lsof reports the physical one, and on macOS
# those differ under /var and /tmp.
#
# A path the scan cannot spell the way git does counts as held, because no match is
# possible: lsof writes control characters in forms that are not decoded (`\n`, `^A`), and
# when the names could not be decoded every non-ASCII byte and backslash is still escaped.
# Compared byte for byte, so the caller's locale cannot change what matches.
_cc_wj_held() {
  local dir="$1" wt="${2%/}" p
  for p in "$wt" "$(_cc_wj_realpath "$wt")"; do
    p="${p%/}"
    [ -n "$p" ] || continue
    printf '%s' "$p" | LC_ALL=C grep -q '[[:cntrl:]]' && return 0
    if [ ! -e "$dir/decoded" ] && printf '%s' "$p" | LC_ALL=C grep -qE '[^ -~]|\\'; then
      return 0
    fi
    LC_ALL=C grep -qxF -- "$p" "$dir/cwd" "$dir/open" 2>/dev/null && return 0
    LC_ALL=C grep -qF -- "$p/" "$dir/cwd" "$dir/open" 2>/dev/null && return 0
  done
  return 1
}

# ─── launchd targets ──────────────────────────────────────────────────────────

# A launchd job that runs a script from a worktree is a holder no process scan can see: it
# has no process between runs, so lsof shows nothing, and the job fails every run once the
# checkout is gone (tech.stima.event-gateway-feed, 16 hours, 2026-10-15). The plists that
# can start such a job are read instead.
#
# CC_WJ_LAUNCHAGENTS_DIRS, colon-separated, replaces the default three directories.
# A name containing `.disabled` is not a job. A plist that cannot be read fails the scan,
# and a failed scan keeps every worktree, as a failed lsof scan does.
_cc_wj_launchd_dirs() {
  printf '%s\n' "${CC_WJ_LAUNCHAGENTS_DIRS:-$HOME/Library/LaunchAgents:/Library/LaunchAgents:/Library/LaunchDaemons}" |
    tr ':' '\n'
}

# The home `~/` and `$HOME/` mean to a job: its UserName's, else the janitor's own.
_cc_wj_launchd_home() { # <UserName, may be empty>
  local h=""
  if [ -n "$1" ] && command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | LC_ALL=C awk '/^NFSHomeDirectory:/ { sub(/^NFSHomeDirectory: */, ""); print; exit }')"
  fi
  case "$h" in /*) printf '%s\n' "$h" ;; *) printf '%s\n' "${HOME:-}" ;; esac
}

# Scan every plist into $1/launchd-paths (`label<TAB>absolute path`: every absolute path
# found in any string value, as written and with symlinks resolved) and
# $1/launchd-missing (`label<TAB>program path` for a program that does not exist).
# Sets _CC_WJ_LAUNCHD_ERROR and fails when a plist cannot be read.
_CC_WJ_LAUNCHD_ERROR=""
_cc_wj_scan_launchd() {
  local dir="$1" d f xml label val kind idx prog scripted arg tok real user home
  local -a args
  _CC_WJ_LAUNCHD_ERROR=""
  : > "$dir/launchd-paths"; : > "$dir/launchd-missing"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] && [ -r "$d" ] || continue
    for f in "$d"/*.plist; do
      [ -f "$f" ] || continue
      case "${f##*/}" in *.disabled*) continue ;; esac
      if ! command -v plutil >/dev/null 2>&1; then
        _CC_WJ_LAUNCHD_ERROR="plutil is not available to read $f"; return 1
      fi
      xml="$(plutil -convert xml1 -o - -- "$f" 2>/dev/null)" && [ -n "$xml" ] || {
        _CC_WJ_LAUNCHD_ERROR="the launchd plist $f could not be parsed"; return 1; }
      label=""; prog=""; user=""; args=()
      # Strings only: kind S any string, L the Label, G the Program, A a ProgramArguments item,
      # U the UserName.
      while IFS=$'\t' read -r kind val; do
        case "$kind" in
          L) [ -n "$label" ] || label="$val" ;;
          G) prog="$val" ;;
          U) user="$val" ;;
          A) args+=("$val") ;;
        esac
        # Each absolute path in the value: whole, and cut where a shell would end a word or
        # a path: blanks, `=` `:` (a `--x=/p` argument, a PATH list), quotes, `; & | ( ) < >`
        # and the backtick. `~/` and `$HOME/` are kept as written, for the home of the
        # plist's user once the whole plist is read.
        # A third cut drops the quotes first, so `"$HOME"/wt/run.sh` stays one word.
        while IFS= read -r tok; do
          tok="${tok%/}"
          case "$tok" in /?*|'~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) ;; *) continue ;; esac
          printf '%s\n' "$tok" >> "$dir/launchd-paths.raw"
        done <<TOKENS
$val
$(printf '%s' "$val" | LC_ALL=C awk '{ gsub(/[=: \t"\047;&|()<>`]/, "\n"); print }')
$(printf '%s' "$val" | LC_ALL=C awk '{ gsub(/["\047]/, ""); gsub(/[=: \t;&|()<>`]/, "\n"); print }')
TOKENS
      done < <(printf '%s\n' "$xml" | LC_ALL=C awk '
        function emit(s) { s = dec(s)
                           if (pa == 2) print "A\t" s; else if (w != "") print w "\t" s; else print "S\t" s
                           w = "" }
        function dec(s) { gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s)
                          gsub(/&apos;/, "\047", s); gsub(/&amp;/, "\\&", s); return s }
        acc { if ($0 ~ /<\/string>/) { s = $0; sub(/<\/string>.*$/, "", s); acc = 0; emit(buf " " s) }
              else buf = buf " " $0
              next }
        /<key>/ { w = ""; if ($0 ~ /<key>Label<\/key>/) w = "L"
                  else if ($0 ~ /<key>UserName<\/key>/) w = "U"
                  else if ($0 ~ /<key>Program<\/key>/) w = "G"
                  else if ($0 ~ /<key>ProgramArguments<\/key>/) pa = 1
                  next }
        /<array\/>/ { pa = 0; next }
        /<array>/ { if (pa == 1) pa = 2; next }
        /<\/array>/ { if (pa == 2) pa = 0; next }
        /<string>/ { s = $0; sub(/^.*<string>/, "", s)
                     # A value with newlines runs on to the line with the closing tag; it is one value.
                     if (s !~ /<\/string>/) { buf = s; acc = 1; next }
                     sub(/<\/string>.*$/, "", s); emit(s); next }
        { w = "" }')
      [ -n "$label" ] || label="${f##*/}"
      if [ -f "$dir/launchd-paths.raw" ]; then
        LC_ALL=C sort -u "$dir/launchd-paths.raw" > "$dir/launchd-paths.uniq" &&
          mv -f "$dir/launchd-paths.uniq" "$dir/launchd-paths.raw"
        home=""
        while IFS= read -r tok; do
          case "$tok" in
            '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*)
              if [ -z "$home" ]; then home="$(_cc_wj_launchd_home "$user")"; home="${home%/}"; fi
              [ -n "$home" ] || continue
              case "$tok" in */*) tok="$home/${tok#*/}" ;; *) tok="$home" ;; esac ;;
          esac
          printf '%s\t%s\n' "$label" "$tok" >> "$dir/launchd-paths"
        done < "$dir/launchd-paths.raw"
        rm -f "$dir/launchd-paths.raw"
      fi
      # The program: Program, else the first argument; when that is an interpreter, the
      # script it runs is the first later argument that is not an option.
      [ -n "$prog" ] || prog="${args[0]:-}"
      case "$prog" in
        /*)
          [ -e "$prog" ] || printf '%s\t%s\n' "$label" "$prog" >> "$dir/launchd-missing"
          case "${prog##*/}" in
            python*|bash|sh|zsh|dash|ksh|node|ruby|perl|php|env)
              idx=1; scripted=""
              # `env python3 x.py`: the command word is skipped like the interpreter itself.
              if [ "${prog##*/}" = env ]; then
                while [ "$idx" -lt "${#args[@]}" ]; do
                  case "${args[$idx]}" in -*|*=*) idx=$((idx + 1)) ;; *) idx=$((idx + 1)); break ;; esac
                done
              fi
              while [ "$idx" -lt "${#args[@]}" ]; do
                arg="${args[$idx]}"; idx=$((idx + 1))
                case "$arg" in
                  -c|-*c|-m|-e) break ;;  # the next word is a command, a module or code
                  -*|*=*) continue ;;
                  *[[:space:]]*) ;;  # a command line, not a file
                  /*) scripted="$arg" ;;
                esac
                break
              done
              [ -z "$scripted" ] || [ -e "$scripted" ] ||
                printf '%s\t%s\n' "$label" "$scripted" >> "$dir/launchd-missing"
              ;;
          esac ;;
      esac
    done
  done < <(_cc_wj_launchd_dirs)
  # Symlinks resolved, once per distinct path: most tokens are PATH entries every job shares.
  # A path that does not exist (yet, or any more) is resolved through its nearest ancestor
  # that does, so /var/x/wt/run.sh still reads as /private/var/x/wt/run.sh.
  cut -f2 "$dir/launchd-paths" | LC_ALL=C sort -u | while IFS= read -r tok; do
    # Only an absolute path can be walked up to `/`; anything else would never end.
    case "$tok" in /*) ;; *) continue ;; esac
    d="$tok"; rest=""
    while [ ! -e "$d" ] && [ "$d" != / ]; do
      rest="/${d##*/}$rest"; d="${d%/*}"; [ -n "$d" ] || d=/
    done
    real="$(_cc_wj_realpath "$d")"; real="${real%/}$rest"
    [ "$real" = "$tok" ] || printf '%s\t%s\n' "$tok" "$real"
  done > "$dir/launchd-real"
  if [ -s "$dir/launchd-real" ]; then
    LC_ALL=C awk -F'\t' -v OFS='\t' 'NR == FNR { m[$1] = $2; next } $2 in m { print $1, m[$2] }' \
      "$dir/launchd-real" "$dir/launchd-paths" > "$dir/launchd-paths.real" &&
      cat "$dir/launchd-paths.real" >> "$dir/launchd-paths"
  fi
  return 0
}

# Print the label of a job whose plist names worktree $2 or anything under it, by either
# spelling of the worktree. Whole path components: /x/wt-1 is not /x/wt-10.
_cc_wj_launchd_target() { # <scan dir> <worktree>
  local dir="$1" wt="${2%/}" real
  real="$(_cc_wj_realpath "$wt")"
  CC_WJ_A="$wt" CC_WJ_B="${real%/}" LC_ALL=C awk -F'\t' '
    BEGIN { a = ENVIRON["CC_WJ_A"]; b = ENVIRON["CC_WJ_B"] }
    { t = $2
      if (t == a || t == b || index(t, a "/") == 1 || (b != "" && index(t, b "/") == 1)) { print $1; exit } }
  ' "$dir/launchd-paths"
}

# KEEP(...) when launchd forbids removing worktree $2, empty otherwise. $LAUNCHD_OK is the
# caller's record of whether the scan worked.
_cc_wj_launchd_keep() { # <scan dir> <worktree> <ok: yes|no>
  local label
  [ "$3" = yes ] || { echo "KEEP(launchd-scan-unknown)"; return 0; }
  label="$(_cc_wj_launchd_target "$1" "$2")"
  [ -z "$label" ] || echo "KEEP(launchd-target:$label)"
}

# ─── Harness activity claims ────────────────────────────────────────────────

# lsof proves that a process currently holds a path.  It cannot prove that an app task
# has ended: both Claude and Codex can keep their own registry/rollout open while driving
# a linked worktree through absolute tool paths.  These registries are therefore an
# independent veto, not a substitute for the holder scan.
_CC_WJ_ACTIVE_CLAIMS=""
_CC_WJ_ACTIVE_TRANSCRIPTS=""
_CC_WJ_ACTIVE_ERROR=""
_CC_WJ_TORN_WAITED=""
_CC_WJ_ACTIVE_REASON=""
_CC_WJ_RECENT_CLAIMS=""
_CC_WJ_RECENT_TRANSCRIPTS=""
_CC_WJ_RECENT_REASON=""
_CC_WJ_ACTIVE_GRACE_HOURS=0

_cc_wj_active_add_claim() { # <harness> <resolved cwd> <id>
  _CC_WJ_ACTIVE_CLAIMS="${_CC_WJ_ACTIVE_CLAIMS}${_CC_WJ_ACTIVE_CLAIMS:+$'\n'}$1"$'\t'"$2"$'\t'"$3"
}

_cc_wj_active_add_transcript() { # <harness> <id> <path>
  _CC_WJ_ACTIVE_TRANSCRIPTS="${_CC_WJ_ACTIVE_TRANSCRIPTS}${_CC_WJ_ACTIVE_TRANSCRIPTS:+$'\n'}$1"$'\t'"$2"$'\t'"$3"
}

_cc_wj_recent_add_claim() { # <harness> <resolved cwd> <id> <activity epoch> <state>
  _CC_WJ_RECENT_CLAIMS="${_CC_WJ_RECENT_CLAIMS}${_CC_WJ_RECENT_CLAIMS:+$'\n'}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"
}

_cc_wj_recent_add_transcript() { # <harness> <id> <path> <activity epoch> <state>
  _CC_WJ_RECENT_TRANSCRIPTS="${_CC_WJ_RECENT_TRANSCRIPTS}${_CC_WJ_RECENT_TRANSCRIPTS:+$'\n'}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"
}

_cc_wj_active_has_id() { # <harness> <id>
  local wanted_harness="$1" wanted_id="$2" harness cwd sid
  while IFS=$'\t' read -r harness cwd sid; do
    [ "$harness" = "$wanted_harness" ] && [ "$sid" = "$wanted_id" ] && return 0
  done <<ACTIVE_IDS
$_CC_WJ_ACTIVE_CLAIMS
ACTIVE_IDS
  return 1
}

_cc_wj_mtime_epoch() {
  local value
  value="$(stat -f %m "$1" 2>/dev/null)" && case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  value="$(stat -c %Y "$1" 2>/dev/null)" && case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  return 1
}

_cc_wj_epoch_iso() {
  date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null ||
    date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf '%s' "$1"
}

_cc_wj_claim_cwd() {
  local cwd="$1"
  case "$cwd" in ''|*$'\n'*|*$'\t'*) return 1 ;; esac
  (builtin cd -P -- "$cwd" >/dev/null 2>&1 && pwd -P)
}

_cc_wj_transcript_cache_identity() { # <mode> <path>
  local stat_identity
  stat_identity="$(stat -f '%d %i %z %m' "$2" 2>/dev/null)" ||
    stat_identity="$(stat -c '%d %i %s %Y' "$2" 2>/dev/null)" || return 1
  printf '%s\0%s\0%s\n' "$1" "$2" "$stat_identity"
}

# Query only the meaningful tail of an append-only transcript. Real session files on the
# measured host exceed 100 MB; reading each whole file once per candidate made a six-hour
# janitor run itself a sustained I/O workload. In reverse order the current two human
# turns end at the second user boundary, and Claude's last cwd is normally in the final
# record. Invalid unrelated tail records are ignored just as `fromjson?` did for cwd;
# an invalid record that actually names the target remains a fail-closed parse error.
_cc_wj_transcript_tail_query() { # <claude-cwd|claude-claim|codex-claim> <file> [target alternate]
  local mode="$1" transcript="$2" wt="${3:-}" alt="${4:-}" python cache="" index="" cache_key
  python="$(command -v python3 2>/dev/null)" || return 2
  if [[ "$mode" == *-claim ]]; then
    cache_key="$(printf '%s\t%s' "$mode" "$transcript" | cksum | awk '{ print $1 "-" $2 }')"
    if [ -n "${CC_WJ_TRANSCRIPT_CACHE_DIR:-}" ]; then
      mkdir -p "$CC_WJ_TRANSCRIPT_CACHE_DIR" 2>/dev/null || return 2
      cache="$CC_WJ_TRANSCRIPT_CACHE_DIR/$cache_key.json"
    fi
    if [ -n "${CC_WJ_TRANSCRIPT_INDEX_DIR:-}" ]; then
      mkdir -p "$CC_WJ_TRANSCRIPT_INDEX_DIR" 2>/dev/null || CC_WJ_TRANSCRIPT_INDEX_DIR=""
      [ -z "$CC_WJ_TRANSCRIPT_INDEX_DIR" ] || chmod 700 "$CC_WJ_TRANSCRIPT_INDEX_DIR" 2>/dev/null || true
      [ -z "$CC_WJ_TRANSCRIPT_INDEX_DIR" ] || index="$CC_WJ_TRANSCRIPT_INDEX_DIR/$cache_key.json"
    fi
    # The first target in one activity snapshot asks Python to decode the current-turn
    # tool inputs.  It writes their normalized text beside the offset snapshot.  Every
    # later target can then use grep instead of starting another Python interpreter for
    # every transcript.  A malformed relevant record keeps the legacy target-specific
    # parser on the path below, so the optimization cannot weaken fail-closed behavior.
    if [ -n "$cache" ] && [ -f "$cache.search" ] && [ -f "$cache.identity" ] &&
       [ ! -e "$cache.fatal" ] && [ ! -e "$cache.unsafe" ] &&
       cmp -s "$cache.identity" <(_cc_wj_transcript_cache_identity "$mode" "$transcript"); then
      LC_ALL=C grep -F -q -- "$wt" "$cache.search" 2>/dev/null
      case $? in 0) return 0 ;; 1) ;; *) return 2 ;; esac
      if [ -n "$alt" ]; then
        LC_ALL=C grep -F -q -- "$alt" "$cache.search" 2>/dev/null
        case $? in 0) return 0 ;; 1) ;; *) return 2 ;; esac
      fi
      return 1
    fi
  fi
  if [ -n "${CC_WJ_TRANSCRIPT_QUERY_TRACE:-}" ]; then
    printf '%s\t%s\n' "$mode" "$transcript" >> "$CC_WJ_TRANSCRIPT_QUERY_TRACE"
  fi
  "$python" - "$mode" "$transcript" "$wt" "$alt" "$cache" "$index" <<'PY'
import json
import mmap
import os
import sys
import tempfile

mode, path, target, alternate, cache_path, index_path = sys.argv[1:]
target_bytes = target.encode("utf-8", "surrogateescape")
alternate_bytes = alternate.encode("utf-8", "surrogateescape")
target_needles = {
    target_bytes,
    alternate_bytes,
    json.dumps(target, ensure_ascii=True)[1:-1].encode("ascii"),
    json.dumps(target, ensure_ascii=False)[1:-1].encode("utf-8", "surrogateescape"),
    json.dumps(alternate, ensure_ascii=True)[1:-1].encode("ascii"),
    json.dumps(alternate, ensure_ascii=False)[1:-1].encode("utf-8", "surrogateescape"),
}
target_needles.discard(b"")


def value_names_target(value, depth=0):
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    if target in text or alternate in text:
        return True
    # Codex custom_tool_call.input can itself be a JSON-encoded string. Decode a
    # bounded number of layers so escaped solidi and Unicode become the actual path;
    # keep the original text check for command-like inputs that are not JSON.
    if isinstance(value, str) and depth < 4:
        try:
            nested = json.loads(value)
        except (TypeError, json.JSONDecodeError):
            return False
        if nested != value:
            return value_names_target(nested, depth + 1)
    return False


def searchable_texts(value, depth=0):
    """Return every normalized text layer value_names_target can match."""
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    texts = [text]
    if isinstance(value, str) and depth < 4:
        try:
            nested = json.loads(value)
        except (TypeError, json.JSONDecodeError):
            return texts
        if nested != value:
            texts.extend(searchable_texts(nested, depth + 1))
    return texts


def event_searchable_texts(event):
    if not isinstance(event, dict):
        return []
    if mode == "codex-claim":
        payload = event.get("payload")
        if (
            event.get("type") == "response_item"
            and isinstance(payload, dict)
            and payload.get("type") == "custom_tool_call"
        ):
            return searchable_texts(payload.get("input", ""))
        return []
    if mode == "claude-claim":
        message = event.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if event.get("type") != "assistant" or not isinstance(content, list):
            return []
        texts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_use":
                texts.extend(searchable_texts(item.get("input", "")))
        return texts
    return []


def reverse_lines(file_path):
    with open(file_path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        position = handle.tell()
        # Segments of the one line crossing block boundaries, collected newest first.
        # Joining a growing bytes object at every block is quadratic for a single large
        # tool-result record (real rollouts contain lines tens of MB long).
        pending = []
        while position:
            size = min(65536, position)
            position -= size
            handle.seek(position)
            parts = handle.read(size).split(b"\n")
            if len(parts) == 1:
                pending.append(parts[0])
                continue
            line = parts[-1] + b"".join(reversed(pending))
            if line:
                yield line.rstrip(b"\r")
            for line in reversed(parts[1:-1]):
                if line:
                    yield line.rstrip(b"\r")
            pending = [parts[0]]
        line = b"".join(reversed(pending))
        if line:
            yield line.rstrip(b"\r")


def load_snapshot(snapshot_path, stat, allow_growth):
    if not snapshot_path:
        return None
    try:
        with open(snapshot_path, "r", encoding="utf-8") as cached:
            candidate = json.load(cached)
        size_matches = (
            stat.st_size >= candidate.get("size", stat.st_size + 1)
            if allow_growth
            else stat.st_size == candidate.get("size", -1)
        )
        mtime_matches = allow_growth or candidate.get("mtime_ns") == stat.st_mtime_ns
        if (
            candidate.get("schema") == 2
            and candidate.get("path") == path
            and candidate.get("mode") == mode
            and candidate.get("dev") == stat.st_dev
            and candidate.get("ino") == stat.st_ino
            and size_matches
            and mtime_matches
        ):
            return candidate
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return None


def write_snapshot(snapshot_path, snapshot):
    if not snapshot_path:
        return
    directory = os.path.dirname(snapshot_path)
    fd, temporary = tempfile.mkstemp(prefix=".transcript-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(snapshot, output, separators=(",", ":"))
        os.replace(temporary, snapshot_path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def write_bytes(pathname, payload):
    directory = os.path.dirname(pathname)
    fd, temporary = tempfile.mkstemp(prefix=".transcript-search-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
        os.replace(temporary, pathname)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


try:
    if mode.endswith("-claim"):
        with open(path, "rb") as preflight:
            stat = os.fstat(preflight.fileno())
            if stat.st_size == 0:
                raise SystemExit(1)
            with mmap.mmap(preflight.fileno(), 0, access=mmap.ACCESS_READ) as contents:
                snapshot = load_snapshot(cache_path, stat, allow_growth=True)
                if snapshot is None:
                    snapshot = load_snapshot(index_path, stat, allow_growth=False)
                    if snapshot is not None and cache_path:
                        write_snapshot(cache_path, snapshot)

                if snapshot is None:
                    # Save only byte ranges, never transcript content. The ranges are the
                    # small set of records which can affect a path claim inside the current
                    # two user turns. Every candidate in this activity snapshot reuses them.
                    ranges = []
                    turns = 0
                    end = len(contents)
                    while end:
                        if contents[end - 1 : end] == b"\n":
                            end -= 1
                            continue
                        newline = contents.rfind(b"\n", 0, end)
                        begin = 0 if newline < 0 else newline + 1
                        prefix = contents[begin : min(end, begin + 8192)]
                        if mode == "codex-claim":
                            hinted = (
                                b'"custom_tool_call"' in prefix
                                or (b'"role"' in prefix and b'"user"' in prefix)
                            )
                        else:
                            hinted = b'"tool_use"' in prefix or b'"user"' in prefix
                        # An otherwise malformed record is relevant only when it literally
                        # names an absolute target. Retain slash-bearing ranges so that the
                        # later target-specific check preserves that fail-closed behaviour.
                        if hinted or contents.find(b"/", begin, end) >= 0:
                            ranges.append([begin, end])
                        if hinted:
                            try:
                                event = json.loads(contents[begin:end])
                            except (UnicodeDecodeError, json.JSONDecodeError):
                                event = None
                            if isinstance(event, dict) and mode == "codex-claim":
                                payload = event.get("payload")
                                if (
                                    event.get("type") == "response_item"
                                    and isinstance(payload, dict)
                                    and payload.get("type") == "message"
                                    and payload.get("role") == "user"
                                ):
                                    turns += 1
                            elif isinstance(event, dict) and mode == "claude-claim":
                                message = event.get("message")
                                content = message.get("content") if isinstance(message, dict) else None
                                is_user = event.get("type") == "user" and (
                                    isinstance(content, str)
                                    or (
                                        isinstance(content, list)
                                        and any(
                                            isinstance(item, dict) and item.get("type") == "text"
                                            for item in content
                                        )
                                    )
                                )
                                if is_user:
                                    turns += 1
                            if turns >= 2:
                                break
                        end = newline if newline >= 0 else 0
                    snapshot = {
                        "schema": 2,
                        "path": path,
                        "mode": mode,
                        "dev": stat.st_dev,
                        "ino": stat.st_ino,
                        "size": stat.st_size,
                        "mtime_ns": stat.st_mtime_ns,
                        "ranges": ranges,
                    }
                    if cache_path:
                        try:
                            write_snapshot(cache_path, snapshot)
                        except OSError:
                            raise SystemExit(2)
                    if index_path:
                        try:
                            write_snapshot(index_path, snapshot)
                        except OSError:
                            pass
                    if cache_path or index_path:
                        trace = os.environ.get("CC_WJ_TRANSCRIPT_CACHE_TRACE")
                        if trace:
                            with open(trace, "a", encoding="utf-8") as output:
                                output.write(path + "\n")

                if cache_path:
                    values = []
                    fatal = False
                    unsafe = False
                    tool_marker = (
                        b'"custom_tool_call"' if mode == "codex-claim" else b'"tool_use"'
                    )
                    for range_begin, range_end in snapshot.get("ranges", []):
                        if (
                            range_begin < 0
                            or range_end > len(contents)
                            or range_begin >= range_end
                        ):
                            raise SystemExit(2)
                        raw = contents[range_begin:range_end]
                        has_tool_marker = tool_marker in raw
                        try:
                            event = json.loads(raw)
                        except (UnicodeDecodeError, json.JSONDecodeError):
                            if has_tool_marker:
                                fatal = True
                            elif b"/" in raw:
                                unsafe = True
                            continue
                        values.extend(event_searchable_texts(event))
                    encoded_values = []
                    for value in values:
                        try:
                            encoded_values.append(value.encode("utf-8", "surrogateescape"))
                        except UnicodeEncodeError:
                            # U+DC80..U+DCFF round-trip filesystem bytes. Other lone
                            # surrogates have no shell-byte representation, so keep the
                            # exact parser instead of turning an encoding error into the
                            # status-1 "no claim" answer.
                            fatal = True
                    search_payload = b"\0".join(encoded_values)
                    try:
                        write_bytes(cache_path + ".search", search_payload)
                        if fatal:
                            write_bytes(cache_path + ".fatal", b"1")
                        if unsafe:
                            write_bytes(cache_path + ".unsafe", b"1")
                        # Written last: the shell fast path is available only when
                        # the exact mode/path/file identity that produced the atomic
                        # projection is visible. The cksum is only a filename shard;
                        # it is never trusted as cache identity.
                        identity = (
                            mode.encode("utf-8")
                            + b"\0"
                            + os.fsencode(path)
                            + b"\0"
                            + f"{stat.st_dev} {stat.st_ino} {stat.st_size} {int(stat.st_mtime)}\n".encode("ascii")
                        )
                        write_bytes(cache_path + ".identity", identity)
                    except OSError:
                        raise SystemExit(2)
                    # The projection was built from the same normalized layers as
                    # value_names_target. Use it for this first target too; otherwise
                    # the process decodes every selected JSON record a second time
                    # before later candidates finally reach the shell fast path.
                    if not fatal and not unsafe:
                        if any(
                            target in value or (alternate and alternate in value)
                            for value in values
                        ):
                            raise SystemExit(0)
                        raise SystemExit(1)

                for begin, end in snapshot.get("ranges", []):
                    if begin < 0 or end > len(contents) or begin >= end:
                        raise SystemExit(2)
                    # The offset index deliberately keeps every current-turn tool/user
                    # record, including multi-megabyte results. Decode every actual tool
                    # call so JSON's many equivalent escape spellings retain exact claim
                    # behavior; skip only records with no canonical harness tool marker.
                    tool_marker = (
                        b'"custom_tool_call"' if mode == "codex-claim" else b'"tool_use"'
                    )
                    has_tool_marker = contents.find(tool_marker, begin, end) >= 0
                    names_target = any(
                        contents.find(needle, begin, end) >= 0 for needle in target_needles
                    )
                    if not has_tool_marker and not names_target:
                        continue
                    try:
                        event = json.loads(contents[begin:end])
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        if names_target or has_tool_marker:
                            raise SystemExit(2)
                        continue
                    if isinstance(event, dict) and mode == "codex-claim":
                        payload = event.get("payload")
                        if (
                            event.get("type") == "response_item"
                            and isinstance(payload, dict)
                            and payload.get("type") == "custom_tool_call"
                        ):
                            value = payload.get("input", "")
                            if value_names_target(value):
                                raise SystemExit(0)
                    elif isinstance(event, dict) and mode == "claude-claim":
                        message = event.get("message")
                        content = message.get("content") if isinstance(message, dict) else None
                        if event.get("type") == "assistant" and isinstance(content, list):
                            for item in content:
                                if not isinstance(item, dict) or item.get("type") != "tool_use":
                                    continue
                                value = item.get("input", "")
                                if value_names_target(value):
                                    raise SystemExit(0)
        raise SystemExit(1)

    for raw in reverse_lines(path):
        prefix = raw[:8192]
        if mode == "claude-cwd" and b'"cwd"' not in prefix:
            continue
        try:
            event = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue

        if mode == "claude-cwd":
            cwd = event.get("cwd") if isinstance(event, dict) else None
            if isinstance(cwd, str) and cwd:
                print(cwd)
                raise SystemExit(0)
            continue
        raise SystemExit(2)
except OSError:
    raise SystemExit(2)

raise SystemExit(1)
PY
}

_cc_wj_scan_claude_sessions() {
  local registry="${CC_WJ_CLAUDE_SESSIONS:-$HOME/.claude/sessions}"
  local projects="${CC_WJ_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
  local f files base row pid sid cwd cmd resolved transcripts count transcript sname t
  local unknown_attrs=()
  [ -e "$registry" ] || return 0
  if [ ! -d "$registry" ] || [ ! -r "$registry" ] || [ ! -x "$registry" ]; then
    _CC_WJ_ACTIVE_ERROR="the Claude session registry $registry is unreadable"
    return 1
  fi
  files="$(find "$registry" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null)" || {
    _CC_WJ_ACTIVE_ERROR="the Claude session registry $registry could not be listed"
    return 1
  }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"; base="${base%.json}"
    case "$base" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$base" 2>/dev/null || continue
    command -v jq >/dev/null 2>&1 || {
      _CC_WJ_ACTIVE_ERROR="jq is unavailable, so live Claude session claims cannot be checked"
      return 1
    }
    # A record that cannot be read keeps the worktrees it could be about: the cwd its live
    # process stands in, and any cwd string its raw text still carries.
    row="$(jq -er '[((.pid // "") | tostring), (.sessionId // ""), (.cwd // "")] | @tsv' "$f" 2>/dev/null)" || {
      _cc_wj_unknown_add "claude-session:${f##*/}" "live Claude session record ${f##*/} could not be parsed" \
        cwd "$(_cc_wj_pid_cwd "$base")" cwd "$(_cc_wj_raw_cwd "$f")"
      continue
    }
    IFS=$'\t' read -r pid sid cwd <<< "$row"
    # The session's name, for CC_WJ_DENY_NAMES only. Read apart from the row above so a
    # missing or odd name can never fail the scan that every veto depends on.
    sname="$(jq -r '(.name // "") | tostring' "$f" 2>/dev/null | head -n 1)"
    case "$pid" in ''|*[!0-9]*)
      _cc_wj_unknown_add "claude-session:${f##*/}" "live Claude session record ${f##*/} has no valid pid" \
        cwd "$(_cc_wj_pid_cwd "$base")" cwd "$cwd"
      continue ;;
    esac
    [ "$pid" = "$base" ] || {
      _cc_wj_unknown_add "claude-session:${f##*/}" "live Claude session record ${f##*/} disagrees with pid $pid" \
        cwd "$(_cc_wj_pid_cwd "$base")" cwd "$(_cc_wj_pid_cwd "$pid")" cwd "$cwd"
      continue
    }
    kill -0 "$pid" 2>/dev/null || continue
    cmd="$(ps -p "$pid" -o command= 2>/dev/null)" || {
      kill -0 "$pid" 2>/dev/null || continue
      _cc_wj_unknown_add "claude-session:${f##*/}" "live Claude pid $pid could not be inspected" \
        cwd "$(_cc_wj_pid_cwd "$pid")" cwd "$cwd"
      continue
    }
    printf '%s\n' "$sid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || {
      _cc_wj_unknown_add "claude-session:${f##*/}" "live Claude session record ${f##*/} has an invalid session id" \
        cwd "$(_cc_wj_pid_cwd "$pid")" cwd "$cwd"
      continue
    }
    # A live pid may have been reused.  The opaque session id in its command line binds
    # the registry record to this process.
    case "$cmd" in *"$sid"*) ;; *) continue ;; esac
    resolved="$(_cc_wj_claim_cwd "$cwd")" || {
      _cc_wj_unknown_add "claude-session:$sid" "live Claude session $sid could not map cwd ${cwd:-<empty>}" \
        cwd "$(_cc_wj_pid_cwd "$pid")" cwd "$cwd"
      continue
    }
    _cc_wj_active_add_claim Claude "$resolved" "$sid"
    case "$sname" in
      ''|*$'\t'*|*$'\n'*) ;;
      *) _CC_WJ_ACTIVE_NAMES="${_CC_WJ_ACTIVE_NAMES}${sname}"$'\t'"${resolved}"$'\n' ;;
    esac
    if [ ! -d "$projects" ] || [ ! -r "$projects" ] || [ ! -x "$projects" ]; then
      _CC_WJ_ACTIVE_ERROR="live Claude session $sid has no readable transcript registry at $projects"
      return 1
    fi
    # From here the session's cwd claim stands; what cannot be read is its transcript, so
    # the trees its tool calls may name are unknown. Its cwd and project directories
    # attribute it.
    transcripts="$(find "$projects" -type f -name "$sid.jsonl" -print 2>/dev/null)" || {
      _cc_wj_unknown_add "claude-session:$sid" "the transcript for live Claude session $sid could not be located" \
        cwd "$resolved" projdir "$(_cc_wj_project_dir_name "$resolved")"
      continue
    }
    count="$(printf '%s\n' "$transcripts" | grep -c .)"
    [ "$count" -eq 1 ] || {
      unknown_attrs=(cwd "$resolved" projdir "$(_cc_wj_project_dir_name "$resolved")")
      while IFS= read -r t; do
        [ -n "$t" ] && unknown_attrs+=(projdir "$(_cc_wj_transcript_projdir "$t")")
      done <<SID_TRANSCRIPTS
$transcripts
SID_TRANSCRIPTS
      _cc_wj_unknown_add "claude-session:$sid" "live Claude session $sid did not map to exactly one transcript" \
        "${unknown_attrs[@]}"
      continue
    }
    transcript="$transcripts"
    case "$transcript" in *$'\n'*|*$'\t'*)
      _cc_wj_unknown_add "claude-session:$sid" "live Claude session $sid has an unsafe transcript path" \
        cwd "$resolved" projdir "$(_cc_wj_project_dir_name "$resolved")"
      continue ;;
    esac
    [ -r "$transcript" ] || {
      _cc_wj_unknown_add "claude-session:$sid" "the transcript for live Claude session $sid is unreadable" \
        cwd "$resolved" projdir "$(_cc_wj_transcript_projdir "$transcript")"
      continue
    }
    _cc_wj_active_add_transcript Claude "$sid" "$transcript"
  done <<CLAUDE_FILES
$files
CLAUDE_FILES
}

# Codex can hold a live writer lock for minutes before publishing the task row to
# state_5.sqlite. The rollout already exists in that interval and starts with bounded,
# machine-readable session metadata. Map only one exact-id rollout whose metadata repeats
# the same id and supplies a safe cwd. Anything ambiguous remains fail-closed.
_cc_wj_codex_rollout_metadata() { # <thread id>
  local tid="$1" sessions="${CC_WJ_CODEX_SESSIONS:-$HOME/.codex/sessions}"
  local rollouts count rollout python
  [ -d "$sessions" ] && [ -r "$sessions" ] && [ -x "$sessions" ] || return 1
  rollouts="$(_cc_wj_with_timeout 15 find "$sessions" -type f -name "*-$tid.jsonl" -print 2>/dev/null)" || return 1
  count="$(printf '%s\n' "$rollouts" | grep -c .)"
  [ "$count" -eq 1 ] || return 1
  rollout="$rollouts"
  case "$rollout" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  [ -r "$rollout" ] || return 1
  python="$(command -v python3 2>/dev/null)" || return 1
  "$python" - "$rollout" "$tid" <<'PY'
import json
import sys

path, expected_id = sys.argv[1:]
try:
    with open(path, "rb") as stream:
        line = stream.readline(1024 * 1024 + 1)
    if not line.endswith(b"\n") or len(line) > 1024 * 1024:
        raise ValueError("unbounded session metadata")
    record = json.loads(line)
    payload = record.get("payload")
    if record.get("type") != "session_meta" or not isinstance(payload, dict):
        raise ValueError("missing session metadata")
    cwd = payload.get("cwd")
    if payload.get("id") != expected_id or not isinstance(cwd, str):
        raise ValueError("mismatched session metadata")
    if not cwd.startswith("/") or any(char in cwd for char in "\t\r\n"):
        raise ValueError("unsafe session cwd")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
print(f"{cwd}\t{path}")
PY
}

# Attribution words (`cwd <path>`, one pair per line, no spaces in a path) for an active Codex
# claim $1 whose task cannot be mapped: the cwd of every state row $3 lists, the cwd its rollout's
# first record names, and the cwd of each process holding its writer lock $2. A path with a space
# or a glob character is left out, since the words are split unquoted.
_cc_wj_codex_unknown_attrs() { # <thread id> <lock path> [state rows]
  local tid="$1" lock="$2" rows="${3:-}" cwd x pid sessions="${CC_WJ_CODEX_SESSIONS:-$HOME/.codex/sessions}" r
  {
    while IFS=$'\t' read -r cwd x; do printf '%s\n' "$cwd"; done <<ROWS
$rows
ROWS
    if [ -d "$sessions" ]; then
      _cc_wj_with_timeout 15 find "$sessions" -type f -name "*-$tid.jsonl" -print 2>/dev/null | head -n 3 |
        while IFS= read -r r; do _cc_wj_raw_cwd "$r"; done
    fi
    _cc_wj_with_timeout 5 lsof -n -P -Fp "$lock" 2>/dev/null | sed -n 's/^p//p' | head -n 5 |
      while IFS= read -r pid; do _cc_wj_pid_cwd "$pid"; done
  } | LC_ALL=C awk '/^\/[^ \t*?[]*$/ && $0 != "/" && !seen[$0]++ { print "cwd"; print $0 }'
}

_cc_wj_scan_codex_sessions() {
  local locks="${CC_WJ_CODEX_LOCKS:-$HOME/.codex/thread-writer-locks}"
  local state="${CC_WJ_CODEX_STATE_DB:-$HOME/.codex/state_5.sqlite}"
  local raw rc path base tid sqlite row cwd rollout resolved count lock_mtime now attempts attempt secs row_ok
  [ -e "$locks" ] || return 0
  if [ ! -d "$locks" ] || [ ! -r "$locks" ] || [ ! -x "$locks" ]; then
    _CC_WJ_ACTIVE_ERROR="the Codex writer-lock registry $locks is unreadable"
    return 1
  fi
  secs="$(_cc_wj_lock_scan_timeout_seconds)" || {
    _CC_WJ_ACTIVE_ERROR="CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS=${CC_WJ_LOCK_SCAN_TIMEOUT_SECONDS:-} is not a positive whole number below 100000"
    return 1
  }
  # One retry on a timeout, as for the holder scans.
  raw="$(_cc_wj_with_timeout "$secs" lsof -n -P -Fn +D "$locks" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 124 ] && { raw="$(_cc_wj_with_timeout "$secs" lsof -n -P -Fn +D "$locks" 2>/dev/null)"; rc=$?; }
  # lsof uses 1 for a successful search with no matching open file.
  if [ "$rc" -ge 2 ]; then
    _CC_WJ_ACTIVE_ERROR="the Codex writer-lock registry $locks could not be scanned"
    return 1
  fi
  while IFS= read -r path; do
    case "$path" in "$locks"/*.lock) ;; *) continue ;; esac
    base="${path##*/}"; tid="${base%.lock}"
    printf '%s\n' "$tid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || continue
    sqlite="$(command -v sqlite3 2>/dev/null)" || {
      _CC_WJ_ACTIVE_ERROR="sqlite3 is unavailable, so active Codex claim $tid could not be mapped"
      return 1
    }
    [ -r "$state" ] || {
      _CC_WJ_ACTIVE_ERROR="active Codex claim $tid could not be mapped because $state is unreadable"
      return 1
    }
    # Codex normally creates the writer lock just before its state row becomes visible.
    # Preserve the short retry for that common case. Some app sessions publish the row
    # much later, however, so lock age must not decide whether a verified-live task can
    # be mapped; the exact rollout metadata below is the bounded fallback.
    attempts=1
    lock_mtime="$(_cc_wj_mtime_epoch "$path")"; now="$(date +%s)"
    case "$lock_mtime" in
      ''|*[!0-9]*) ;;
      *) [ $((now - lock_mtime)) -le 10 ] && attempts=6 ;;
    esac
    attempt=1
    row_ok=1
    while :; do
      row="$("$sqlite" -batch -noheader -cmd '.timeout 2000' "$state" \
        "select cwd || char(9) || rollout_path from threads where id = '$tid';" 2>/dev/null)" || {
        row_ok=0; break
      }
      count="$(printf '%s\n' "$row" | grep -c .)"
      [ "$count" -eq 1 ] && break
      [ "$attempt" -lt "$attempts" ] || break
      sleep 0.5
      attempt=$((attempt + 1))
    done
    if [ "$row_ok" -eq 0 ]; then
      _cc_wj_unknown_add "codex-claim:$tid" "active Codex claim $tid could not be mapped from local state" \
        $(_cc_wj_codex_unknown_attrs "$tid" "$path")
      continue
    fi
    if [ "$count" -eq 0 ]; then
      row="$(_cc_wj_codex_rollout_metadata "$tid")" || {
        _cc_wj_unknown_add "codex-claim:$tid" "active Codex claim $tid could not be mapped to exactly one task or active rollout" \
          $(_cc_wj_codex_unknown_attrs "$tid" "$path")
        continue
      }
      count=1
    fi
    [ "$count" -eq 1 ] || {
      _cc_wj_unknown_add "codex-claim:$tid" "active Codex claim $tid could not be mapped to exactly one task or active rollout" \
        $(_cc_wj_codex_unknown_attrs "$tid" "$path" "$row")
      continue
    }
    IFS=$'\t' read -r cwd rollout <<< "$row"
    resolved="$(_cc_wj_claim_cwd "$cwd")" || {
      _cc_wj_unknown_add "codex-claim:$tid" "active Codex claim $tid could not be mapped to cwd ${cwd:-<empty>}" \
        cwd "$cwd" $(_cc_wj_codex_unknown_attrs "$tid" "$path")
      continue
    }
    case "$rollout" in ''|*$'\n'*|*$'\t'*)
      _cc_wj_active_add_claim Codex "$resolved" "$tid"
      _cc_wj_unknown_add "codex-claim:$tid" "active Codex claim $tid has an unsafe transcript path" cwd "$resolved"
      continue ;;
    esac
    [ -r "$rollout" ] || {
      _cc_wj_active_add_claim Codex "$resolved" "$tid"
      _cc_wj_unknown_add "codex-claim:$tid" "the transcript for active Codex claim $tid is unreadable" cwd "$resolved"
      continue
    }
    _cc_wj_active_add_claim Codex "$resolved" "$tid"
    _cc_wj_active_add_transcript Codex "$tid" "$rollout"
  done <<CODEX_LOCKS
$(printf '%s\n' "$raw" | sed -n 's/^n//p')
CODEX_LOCKS
}

# The reason open(2) gives for path, e.g. "Permission denied"; "unknown" when it opens.
_cc_wj_open_error() {
  local why
  why="$( { : < "$1"; } 2>&1 )" && { echo unknown; return; }
  why="${why##*: }"
  printf '%s\n' "${why:-unknown}"
}

_cc_wj_scan_claude_recent() { # <grace hours> [relisted]
  local grace="$1" relisted="${2:-}" projects="${CC_WJ_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
  local now cutoff_minutes files f base sid activity cwd resolved why
  [ "$grace" -gt 0 ] || return 0
  [ -e "$projects" ] || return 0
  if [ ! -d "$projects" ] || [ ! -r "$projects" ] || [ ! -x "$projects" ]; then
    _CC_WJ_ACTIVE_ERROR="the Claude transcript registry $projects is unreadable"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || {
    _CC_WJ_ACTIVE_ERROR="jq is unavailable, so recent Claude session leases cannot be checked"
    return 1
  }
  now="$(date +%s)"; cutoff_minutes=$((grace * 60))
  files="$(find "$projects" -type f -name '*.jsonl' -mmin "-$cutoff_minutes" -print 2>/dev/null)" || {
    _CC_WJ_ACTIVE_ERROR="the recent Claude transcript registry $projects could not be listed"
    return 1
  }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"; sid="${base%.jsonl}"
    printf '%s\n' "$sid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || continue
    _cc_wj_active_has_id Claude "$sid" && continue
    [ -r "$f" ] || {
      # The open error is what tells a vanished file from a denied one.
      why="$(_cc_wj_open_error "$f")"
      # A session that enters a worktree has its transcript moved to that worktree's
      # project directory, so the listed path is gone. List once more to read it there.
      if [ "$why" = "No such file or directory" ] && [ -z "$relisted" ]; then
        _CC_WJ_RECENT_CLAIMS=""; _CC_WJ_RECENT_TRANSCRIPTS=""
        _cc_wj_scan_claude_recent "$grace" relisted
        return
      fi
      # Its project directory still says which cwd it was started in.
      _cc_wj_unknown_add "claude-transcript:$sid" "recent Claude transcript $base is unreadable ($why)" \
        projdir "$(_cc_wj_transcript_projdir "$f")"
      continue; }
    activity="$(_cc_wj_mtime_epoch "$f")"
    case "$activity" in ''|*[!0-9]*)
      _cc_wj_unknown_add "claude-transcript:$sid" "recent Claude transcript $base has no readable activity time" \
        projdir "$(_cc_wj_transcript_projdir "$f")"
      continue ;;
    esac
    [ $((now - activity)) -lt $((grace * 3600)) ] || continue
    # Raw-line parsing tolerates a final partial JSONL record while a live harness writes.
    # Only the last explicit cwd is retained; message text never enters the diagnostic.
    cwd="$(_cc_wj_transcript_tail_query claude-cwd "$f")"
    if [ -z "$cwd" ]; then
      # Naming a session writes a title record before any message. With no message and
      # no cwd, the transcript cannot claim a path. Only grep's "no match" says so; a
      # read error (rc 2) still fails closed.
      grep -Eq '"message"[[:space:]]*:' "$f"
      [ $? -ne 1 ] || continue
      _cc_wj_unknown_add "claude-transcript:$sid" "recent Claude transcript $base has no mappable cwd" \
        projdir "$(_cc_wj_transcript_projdir "$f")"
      continue
    fi
    case "$cwd" in /*) ;; *)
      _cc_wj_unknown_add "claude-transcript:$sid" "recent Claude session $sid has a non-absolute cwd" \
        projdir "$(_cc_wj_transcript_projdir "$f")"
      continue ;;
    esac
    # Do not parse every recent transcript eagerly. Structured-path claims are only
    # relevant to a worktree that otherwise reaches the removable gate, where
    # `_cc_wj_transcript_claims_path` validates the matching transcript fail-closed.
    # Eager validation made every scheduled run read the full 48-hour transcript set,
    # then repeat that work before each removal candidate.
    _cc_wj_recent_add_transcript Claude "$sid" "$f" "$activity" transcript
    # The recorded cwd can disappear while another worktree named by a current tool
    # call is still live. Keep that transcript eligible for structured-path matching;
    # only the direct cwd claim depends on the recorded path still existing.
    [ -e "$cwd" ] || continue
    resolved="$(_cc_wj_claim_cwd "$cwd")" || {
      _cc_wj_unknown_add "claude-transcript:$sid" "recent Claude session $sid could not map cwd $cwd" \
        cwd "$cwd" projdir "$(_cc_wj_transcript_projdir "$f")"
      continue
    }
    _cc_wj_recent_add_claim Claude "$resolved" "$sid" "$activity" transcript
  done <<CLAUDE_RECENT
$files
CLAUDE_RECENT
}

_cc_wj_scan_codex_recent() { # <grace hours>
  local grace="$1" state="${CC_WJ_CODEX_STATE_DB:-$HOME/.codex/state_5.sqlite}"
  local sqlite now cutoff rows tid cwd rollout activity archived resolved claim_state
  [ "$grace" -gt 0 ] || return 0
  [ -e "$state" ] || return 0
  sqlite="$(command -v sqlite3 2>/dev/null)" || {
    _CC_WJ_ACTIVE_ERROR="sqlite3 is unavailable, so recent Codex session leases cannot be checked"
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    _CC_WJ_ACTIVE_ERROR="jq is unavailable, so recent Codex transcript leases cannot be checked"
    return 1
  }
  [ -r "$state" ] || {
    _CC_WJ_ACTIVE_ERROR="recent Codex session leases could not be mapped because $state is unreadable"
    return 1
  }
  now="$(date +%s)"; cutoff=$((now - grace * 3600))
  rows="$("$sqlite" -batch -noheader -cmd '.timeout 2000' "$state" \
    "select id || char(9) || cwd || char(9) || rollout_path || char(9) || max(updated_at, coalesce(archived_at, 0)) || char(9) || archived from threads where max(updated_at, coalesce(archived_at, 0)) >= $cutoff order by max(updated_at, coalesce(archived_at, 0)) desc, id desc;" 2>/dev/null)" || {
    _CC_WJ_ACTIVE_ERROR="recent Codex session leases could not be read from local state"
    return 1
  }
  while IFS=$'\t' read -r tid cwd rollout activity archived; do
    [ -n "$tid" ] || continue
    # A row that cannot be read keeps the trees its cwd column names, if it names one.
    printf '%s\n' "$tid" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || {
      _cc_wj_unknown_add "codex-task:invalid-id" "recent Codex local state contains an invalid task id" cwd "$cwd"
      continue
    }
    _cc_wj_active_has_id Codex "$tid" && continue
    case "$activity" in ''|*[!0-9]*)
      _cc_wj_unknown_add "codex-task:$tid" "recent Codex task $tid has no valid activity time" cwd "$cwd"; continue ;;
    esac
    case "$archived" in
      0) claim_state=recent ;;
      1) claim_state=archived ;;
      *) _cc_wj_unknown_add "codex-task:$tid" "recent Codex task $tid has an invalid archived state" cwd "$cwd"; continue ;;
    esac
    case "$cwd" in /*) ;; *)
      _cc_wj_unknown_add "codex-task:$tid" "recent Codex task $tid has a non-absolute cwd" \
        $(_cc_wj_codex_unknown_attrs "$tid" /nonexistent)
      continue ;;
    esac
    case "$rollout" in ''|*$'\n'*|*$'\t'*)
      _cc_wj_unknown_add "codex-task:$tid" "recent Codex task $tid has an unsafe transcript path" cwd "$cwd"; continue ;;
    esac
    [ -r "$rollout" ] || {
      _cc_wj_unknown_add "codex-task:$tid" "the transcript for recent Codex task $tid is unreadable" cwd "$cwd"; continue
    }
    _cc_wj_recent_add_transcript Codex "$tid" "$rollout" "$activity" "$claim_state"
    # A renamed or deleted recorded cwd must not discard current structured-path
    # evidence in the rollout for a different, still-existing worktree.
    [ -e "$cwd" ] || continue
    resolved="$(_cc_wj_claim_cwd "$cwd")" || {
      _cc_wj_unknown_add "codex-task:$tid" "recent Codex task $tid could not map cwd $cwd" cwd "$cwd"
      continue
    }
    _cc_wj_recent_add_claim Codex "$resolved" "$tid" "$activity" "$claim_state"
  done <<CODEX_RECENT
$rows
CODEX_RECENT
}

# ─── Unreadable session records, kept per tree (stima-api#5886) ────────────────
#
# One session record that cannot be read used to keep every worktree on the machine: on
# 2026-10-24 eight such records (a torn `53453.json`, a Codex claim not yet in state_5, a
# transcript find that failed on a full disk) each blinded a whole sweep, and the 10:35 run kept
# all ~120 trees and freed 0 B. A record that cannot be read now keeps exactly the worktrees it
# could be about. What can still be read of it attributes it: the cwd its process stands in
# (`lsof -p <pid> -d cwd`), a cwd string in its raw text or in the rows that name it, and for a
# Claude transcript the project directory, which encodes the session's cwd. What could not be
# read may still name any tree (a tool call names any path), so every such record also keeps,
# attributed or not, each tree whose own recent signals (its top-level entries, its git index,
# HEAD and HEAD reflog) fall inside the session-grace window, at least one hour. Every other
# gate still applies to every tree. A registry that cannot be listed at all, or a missing tool,
# still keeps every worktree: no record of it was read, so none can be attributed.
#
# CC_WJ_UNKNOWN_SESSION_SCOPE=tree (default) | global (the old behaviour; any other value means
# global). With tree, CC_WJ_NEW_RULES_MODE decides as for the other rules on probation:
# spotcheck (default) keeps every decision as global would and logs the trees the rule would
# free (rule `session-unknown-per-tree`), auto lets it decide.
_CC_WJ_UNKNOWN=""         # record \t cwd|projdir|none \t value, from the current scan
_CC_WJ_UNKNOWN_ATTR=""    # the same rows, every scan of this phase, for the summary
_CC_WJ_UNKNOWN_ERRORS=""  # record \t message, first seen in this phase
_CC_WJ_UNKNOWN_KEPT=""    # record \t worktree it kept
_CC_WJ_UNKNOWN_REASON=""
_CC_WJ_UNKNOWN_BY=""      # attr: a record names the tree; recent / any: every record keeps it

_cc_wj_unknown_scope() {
  case "${CC_WJ_UNKNOWN_SESSION_SCOPE:-tree}" in
    tree) if [ "$(_cc_wj_new_rules_mode)" = auto ]; then echo tree; else echo spotcheck; fi ;;
    *) echo global ;;
  esac
}

# A record name safe inside KEEP(...) and a log line.
_cc_wj_unknown_label() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._:-' '_'; }

# Claude's project directory for cwd $1: every byte but [A-Za-z0-9] becomes `-`.
_cc_wj_project_dir_name() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }

_cc_wj_unknown_add() { # <record> <message> [<cwd|projdir> <value>]...
  local rec msg kind value attributed=0 row
  rec="$(_cc_wj_unknown_label "$1")"; msg="$2"; shift 2
  [ -n "$_CC_WJ_ACTIVE_ERROR" ] || _CC_WJ_ACTIVE_ERROR="$msg"
  case $'\n'"$_CC_WJ_UNKNOWN_ERRORS" in
    *$'\n'"$rec"$'\t'*) ;;
    *) _CC_WJ_UNKNOWN_ERRORS="${_CC_WJ_UNKNOWN_ERRORS}${rec}"$'\t'"${msg//[$'\t\n']/ }"$'\n' ;;
  esac
  while [ "$#" -ge 2 ]; do
    kind="$1"; value="$2"; shift 2
    case "$value" in ''|*$'\t'*|*$'\n'*) continue ;; esac
    case "$kind" in
      cwd) case "$value" in /) continue ;; /*) value="${value%/}" ;; *) continue ;; esac ;;
      projdir) case "$value" in -?*) ;; *) continue ;; esac
               case "$value" in */*) continue ;; esac ;;
      *) continue ;;
    esac
    row="${rec}"$'\t'"${kind}"$'\t'"${value}"
    _CC_WJ_UNKNOWN="${_CC_WJ_UNKNOWN}${row}"$'\n'
    case $'\n'"$_CC_WJ_UNKNOWN_ATTR" in *$'\n'"$row"$'\n'*) ;; *) _CC_WJ_UNKNOWN_ATTR="${_CC_WJ_UNKNOWN_ATTR}${row}"$'\n' ;; esac
    attributed=1
  done
  [ "$attributed" -eq 1 ] || _CC_WJ_UNKNOWN="${_CC_WJ_UNKNOWN}${rec}"$'\t'none$'\t'-$'\n'
}

# The cwd live process $1 stands in, or nothing.
_cc_wj_pid_cwd() { # <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  _cc_wj_with_timeout 10 lsof -n -P -a -p "$1" -d cwd -Fn 2>/dev/null |
    awk -v p="p$1" '/^p/ { on = ($0 == p) } on && /^n/ { print substr($0, 2); exit }'
}

# The first "cwd" string in file $1's raw text, read without parsing it.
_cc_wj_raw_cwd() { # <file>
  [ -r "$1" ] || return 1
  LC_ALL=C head -c 1048576 "$1" 2>/dev/null |
    LC_ALL=C grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 |
    LC_ALL=C sed 's/^"cwd"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

# The project directory a Claude transcript under CC_WJ_CLAUDE_PROJECTS lives in.
_cc_wj_transcript_projdir() { # <transcript>
  local projects="${CC_WJ_CLAUDE_PROJECTS:-$HOME/.claude/projects}" rel
  case "$1" in "${projects%/}"/*/*) ;; *) return 1 ;; esac
  rel="${1#"${projects%/}"/}"
  printf '%s\n' "${rel%%/*}"
}

# A transcript that could not be parsed when a candidate asked it: recorded as unknown with the
# cwd its own session claims and, for Claude, its project directory, and dropped from both
# transcript lists so later candidates do not ask it again.
_cc_wj_unknown_from_transcript() { # <harness> <id> <transcript> <message>
  local harness="$1" sid="$2" transcript="$3" msg="$4" h cwd x rest attrs=()
  while IFS=$'\t' read -r h cwd x; do
    [ "$h" = "$harness" ] && [ "$x" = "$sid" ] && attrs+=(cwd "$cwd")
  done <<UNKNOWN_LIVE
$_CC_WJ_ACTIVE_CLAIMS
UNKNOWN_LIVE
  while IFS=$'\t' read -r h cwd x rest; do
    [ "$h" = "$harness" ] && [ "$x" = "$sid" ] && attrs+=(cwd "$cwd")
  done <<UNKNOWN_RECENT
$_CC_WJ_RECENT_CLAIMS
UNKNOWN_RECENT
  [ "$harness" = Claude ] && x="$(_cc_wj_transcript_projdir "$transcript")" && attrs+=(projdir "$x")
  _cc_wj_unknown_add "$(printf '%s' "$harness" | tr '[:upper:]' '[:lower:]')-transcript:$sid" "$msg" \
    ${attrs[@]+"${attrs[@]}"}
  _CC_WJ_ACTIVE_TRANSCRIPTS="$(printf '%s\n' "$_CC_WJ_ACTIVE_TRANSCRIPTS" |
    awk -F '\t' -v h="$harness" -v id="$sid" 'NF && !($1 == h && $2 == id)')"
  _CC_WJ_RECENT_TRANSCRIPTS="$(printf '%s\n' "$_CC_WJ_RECENT_TRANSCRIPTS" |
    awk -F '\t' -v h="$harness" -v id="$sid" 'NF && !($1 == h && $2 == id)')"
}

# 0 when worktree $1 shows its own activity within $2 hours (at least one): an entry at its top
# level, its git index, HEAD or HEAD reflog. A tree that cannot be read counts as recent.
_cc_wj_tree_recent() { # <worktree> <grace hours>
  local wt="$1" hours="${2:-0}" gitdir out p args=()
  case "$hours" in ''|*[!0-9]*) hours=0 ;; esac
  hours=$((10#$hours)); [ "$hours" -ge 1 ] || hours=1
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  args=("$wt")
  for p in "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD"; do
    [ -e "$p" ] && args+=("$p")
  done
  out="$(find "${args[@]}" -maxdepth 1 -mmin "-$((hours * 60))" -print 2>/dev/null)" || return 0
  [ -n "$out" ]
}

# 0, with _CC_WJ_UNKNOWN_REASON set, when an unreadable record of the current scan may be about
# worktree $1: one of its attributions names it, or the tree is recent.
_cc_wj_unknown_keeps() { # <worktree> <grace hours>
  local wt="${1%/}" grace="$2" phys alt enc encp enca rec kind value unattributed="" first=""
  _CC_WJ_UNKNOWN_REASON=""; _CC_WJ_UNKNOWN_BY=attr
  [ -n "$_CC_WJ_UNKNOWN" ] || return 1
  phys="$(_cc_wj_realpath "$wt")"; phys="${phys%/}"
  case "$phys" in /private/*) alt="${phys#/private}" ;; *) alt="/private$phys" ;; esac
  enc="$(_cc_wj_project_dir_name "$wt")"; encp="$(_cc_wj_project_dir_name "$phys")"
  enca="$(_cc_wj_project_dir_name "$alt")"
  while IFS=$'\t' read -r rec kind value; do
    [ -n "$rec" ] || continue
    case "$kind" in
      cwd)
        case "$value/" in "$wt/"*|"$phys/"*|"$alt/"*)
          _CC_WJ_UNKNOWN_REASON="session-unknown:$rec"; return 0 ;;
        esac ;;
      projdir)
        # A prefix also matches a sibling whose name extends this one: that keeps more, never less.
        case "$value" in "$enc"|"$enc"-*|"$encp"|"$encp"-*|"$enca"|"$enca"-*)
          _CC_WJ_UNKNOWN_REASON="session-unknown:$rec"; return 0 ;;
        esac ;;
      none) [ -n "$unattributed" ] || unattributed="$rec" ;;
    esac
    [ -n "$first" ] || first="$rec"
  done <<UNKNOWN_ROWS
$_CC_WJ_UNKNOWN
UNKNOWN_ROWS
  # What could not be read may also name trees nothing attributes (a tool call names any path),
  # so every record keeps a tree active within the session grace too.
  [ -n "$first" ] || return 1
  _cc_wj_tree_recent "$wt" "$grace" || return 1
  _CC_WJ_UNKNOWN_REASON="session-unknown:${unattributed:-$first}"; _CC_WJ_UNKNOWN_BY=recent
  return 0
}

_cc_wj_unknown_first() { printf '%s\n' "$_CC_WJ_UNKNOWN" | awk -F '\t' 'NF { print $1; exit }'; }

# The decision: 0 (keep, reason set) when an unreadable record of the current scan may be about
# worktree $1. Per tree only with scope tree; spotcheck and global keep every tree while any
# record is unknown. $3=yes is a tree whose edits would first go to refs/wip: a snapshot taken
# while a session nobody can read may be writing it proves nothing, so any unknown keeps it.
_cc_wj_unknown_gate() { # <worktree> <grace hours> [wip yes|no]
  _CC_WJ_UNKNOWN_REASON=""
  [ -n "$_CC_WJ_UNKNOWN" ] || return 1
  _cc_wj_unknown_keeps "$1" "$2" && return 0
  if [ "$(_cc_wj_unknown_scope)" != tree ] || [ "${3:-no}" = yes ]; then
    _CC_WJ_UNKNOWN_REASON="session-unknown:$(_cc_wj_unknown_first)"; _CC_WJ_UNKNOWN_BY=any
    return 0
  fi
  return 1
}

# A tree a record's attribution kept is listed against that record; one kept for recency (or,
# on the refs/wip path, for any unknown) against every record of the current scan.
_cc_wj_unknown_note_kept() { # <reason session-unknown:<record>> <worktree> [by]
  local recs="${1#session-unknown:}" rec row
  [ "${3:-$_CC_WJ_UNKNOWN_BY}" = attr ] ||
    recs="$(printf '%s' "$_CC_WJ_UNKNOWN" | awk -F '\t' 'NF && !seen[$1]++ { print $1 }')"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    row="$rec"$'\t'"$2"
    case $'\n'"$_CC_WJ_UNKNOWN_KEPT" in *$'\n'"$row"$'\n'*) ;; *) _CC_WJ_UNKNOWN_KEPT="${_CC_WJ_UNKNOWN_KEPT}${row}"$'\n' ;; esac
  done <<NOTE_RECORDS
$recs
NOTE_RECORDS
}

# Once per record per phase: what could not be read, what it was attributed to, what it kept.
_cc_wj_unknown_summary() { # <scope>
  local scope="$1" rec msg about kept n line
  [ -n "$_CC_WJ_UNKNOWN_ERRORS" ] || return 0
  while IFS=$'\t' read -r rec msg; do
    [ -n "$rec" ] || continue
    about="$(printf '%s' "$_CC_WJ_UNKNOWN_ATTR" | awk -F '\t' -v r="$rec" '$1 == r { printf "%s%s=%s", (n++ ? " " : ""), $2, $3 }')"
    kept="$(printf '%s' "$_CC_WJ_UNKNOWN_KEPT" | awk -F '\t' -v r="$rec" '$1 == r { printf "%s%s", (n++ ? " " : ""), $2 }')"
    n="$(printf '%s' "$_CC_WJ_UNKNOWN_KEPT" | awk -F '\t' -v r="$rec" '$1 == r { c++ } END { print c + 0 }')"
    line="KEEP(session-unknown:$rec) scope=$scope: $msg; about: ${about:-nothing attributable}, and trees active within the session grace; kept $n worktree(s)${kept:+: $kept}"
    echo "worktree-janitor: $line" >&2
    _cc_wj_log_write "$line"
  done <<UNKNOWN_ERRORS
$_CC_WJ_UNKNOWN_ERRORS
UNKNOWN_ERRORS
}

_CC_WJ_TRANSCRIPT_CACHE_ROOT=""
_CC_WJ_TRANSCRIPT_CACHE_GENERATION=0

_cc_wj_scan_active_sessions() { # <recent-session grace hours>
  local grace="${1:-0}"
  _CC_WJ_ACTIVE_GRACE_HOURS="$grace"
  if [ -n "$_CC_WJ_TRANSCRIPT_CACHE_ROOT" ]; then
    _CC_WJ_TRANSCRIPT_CACHE_GENERATION=$((_CC_WJ_TRANSCRIPT_CACHE_GENERATION + 1))
    CC_WJ_TRANSCRIPT_CACHE_DIR="$_CC_WJ_TRANSCRIPT_CACHE_ROOT/$_CC_WJ_TRANSCRIPT_CACHE_GENERATION"
    mkdir -p "$CC_WJ_TRANSCRIPT_CACHE_DIR" || {
      _CC_WJ_ACTIVE_ERROR="a transcript evidence snapshot could not be created"
      return 1
    }
  fi
  _CC_WJ_ACTIVE_CLAIMS=""; _CC_WJ_ACTIVE_TRANSCRIPTS=""; _CC_WJ_ACTIVE_ERROR=""; _CC_WJ_ACTIVE_NAMES=""
  _CC_WJ_RECENT_CLAIMS=""; _CC_WJ_RECENT_TRANSCRIPTS=""; _CC_WJ_RECENT_REASON=""
  _CC_WJ_UNKNOWN=""
  _cc_wj_scan_claude_sessions || return 1
  _cc_wj_scan_codex_sessions || return 1
  _cc_wj_scan_claude_recent "$grace" || return 1
  _cc_wj_scan_codex_recent "$grace" || return 1
  # A record that could not be read: with scope global the scan fails as before, and
  # _CC_WJ_ACTIVE_ERROR names the first such record.
  if [ -n "$_CC_WJ_UNKNOWN" ] && [ "$(_cc_wj_unknown_scope)" = global ]; then
    return 1
  fi
  return 0
}

# Return 0 when a structured tool call in the current two human user turns names the
# target, 1 when none does, and 2 when the transcript cannot be parsed. Live claims and
# recent leases intentionally share this parser.
_cc_wj_transcript_claims_path() { # <harness> <transcript> <resolved target>
  local harness="$1" transcript="$2" wt="$3" alt mode rc
  case "$wt" in /private/*) alt="${wt#/private}" ;; *) alt="/private$wt" ;; esac
  [ -r "$transcript" ] || return 2
  case "$harness" in
    Claude) mode=claude-claim ;;
    Codex) mode=codex-claim ;;
    *) return 1 ;;
  esac
  _cc_wj_transcript_tail_query "$mode" "$transcript" "$wt" "$alt"; rc=$?
  # A live session appends its transcript a line at a time, so a read can land mid-line
  # and find a torn last record it cannot decide. Read once more after the writer has
  # finished it; only a second failure reports the transcript unparsable. Twice that one
  # torn read blinded a whole sweep (2026-09-27, 2026-10-01). The wait is paid once per
  # transcript per process, so a record that stays malformed costs one second, not one per
  # candidate worktree.
  if [ "$rc" -eq 2 ] && [ -r "$transcript" ]; then
    case "$_CC_WJ_TORN_WAITED" in
      *"|$transcript|"*) ;;
      *) sleep "${CC_WJ_TRANSCRIPT_RETRY_SECONDS:-1}"
         _CC_WJ_TORN_WAITED="$_CC_WJ_TORN_WAITED|$transcript|" ;;
    esac
    _cc_wj_transcript_tail_query "$mode" "$transcript" "$wt" "$alt"; rc=$?
  fi
  return "$rc"
}

_cc_wj_recent_claim() { # <worktree> <grace hours> [all|cwd|tool]
  local wt="$(_cc_wj_realpath "$1")" grace="$2" harness cwd sid activity claim_state
  local transcript rc best_scope="cwd"
  local mode="${3:-all}"
  local now age remaining best_activity=-1 best_harness="" best_cwd="" best_sid="" best_state=""
  _CC_WJ_RECENT_REASON=""; now="$(date +%s)"
  if [ "$mode" != "tool" ]; then
  while IFS=$'\t' read -r harness cwd sid activity claim_state; do
    [ -n "$cwd" ] || continue
    case "$cwd/" in "$wt/"|"$wt/"*)
      if [ "$activity" -gt "$best_activity" ]; then
        best_activity="$activity"; best_harness="$harness"; best_cwd="$cwd"
        best_sid="$sid"; best_state="$claim_state"
      fi
      ;;
    esac
  done <<RECENT_CLAIMS
$_CC_WJ_RECENT_CLAIMS
RECENT_CLAIMS
  fi
  if [ "$mode" != "cwd" ]; then
  while IFS=$'\t' read -r harness sid transcript activity claim_state; do
    [ -n "$transcript" ] || continue
    _cc_wj_transcript_claims_path "$harness" "$transcript" "$wt"; rc=$?
    if [ "$rc" -eq 2 ]; then
      _CC_WJ_ACTIVE_ERROR="the transcript for recent $harness session $sid could not be parsed"
      # Per tree: the transcript becomes an unknown record, asked by the caller's gate.
      if [ "$(_cc_wj_unknown_scope)" != global ]; then
        _cc_wj_unknown_from_transcript "$harness" "$sid" "$transcript" "$_CC_WJ_ACTIVE_ERROR"
        continue
      fi
      return 2
    fi
    if [ "$rc" -eq 0 ] && [ "$activity" -gt "$best_activity" ]; then
      best_activity="$activity"; best_harness="$harness"; best_cwd="$wt"
      best_sid="$sid"; best_state="$claim_state"; best_scope="structured-tool-call"
    fi
  done <<RECENT_TRANSCRIPTS
$_CC_WJ_RECENT_TRANSCRIPTS
RECENT_TRANSCRIPTS
  fi
  [ "$best_activity" -ge 0 ] || return 1
  age=$((now - best_activity)); [ "$age" -lt 0 ] && age=0
  remaining=$((grace * 3600 - age)); [ "$remaining" -lt 0 ] && remaining=0
  _CC_WJ_RECENT_REASON="recent $best_harness session $best_sid state=$best_state scope=$best_scope path=$best_cwd last_activity=$(_cc_wj_epoch_iso "$best_activity") age=${age}s remaining=${remaining}s"
  return 0
}

_cc_wj_print_claims() { # <grace hours> [id-or-path filter]
  local grace="$1" filter="${2:-}" harness cwd sid activity claim_state now age remaining
  local transcript target rc
  printf 'CLAIMS session_grace_hours=%s\n' "$grace"
  while IFS=$'\t' read -r harness cwd sid; do
    [ -n "$cwd" ] || continue
    if [ -n "$filter" ]; then case "$sid $cwd" in *"$filter"*) ;; *) continue ;; esac; fi
    printf 'LIVE\tharness=%s\tid=%s\tcwd=%s\n' "$harness" "$sid" "$cwd"
  done <<LIVE_CLAIMS
$_CC_WJ_ACTIVE_CLAIMS
LIVE_CLAIMS
  now="$(date +%s)"
  while IFS=$'\t' read -r harness cwd sid activity claim_state; do
    [ -n "$cwd" ] || continue
    if [ -n "$filter" ]; then case "$sid $cwd" in *"$filter"*) ;; *) continue ;; esac; fi
    age=$((now - activity)); [ "$age" -lt 0 ] && age=0
    remaining=$((grace * 3600 - age)); [ "$remaining" -lt 0 ] && remaining=0
    printf 'RECENT\tharness=%s\tid=%s\tstate=%s\tcwd=%s\tlast_activity=%s\tage=%ss\tremaining=%ss\n' \
      "$harness" "$sid" "$claim_state" "$cwd" "$(_cc_wj_epoch_iso "$activity")" "$age" "$remaining"
  done <<RECENT_CLAIMS
$_CC_WJ_RECENT_CLAIMS
RECENT_CLAIMS
  case "$filter" in
    /*)
      target="$(_cc_wj_realpath "$filter")"
      while IFS=$'\t' read -r harness sid transcript; do
        [ -n "$transcript" ] || continue
        _cc_wj_transcript_claims_path "$harness" "$transcript" "$target"; rc=$?
        [ "$rc" -ne 2 ] || { printf 'ERROR\tharness=%s\tid=%s\treason=unreadable-live-transcript\n' "$harness" "$sid"; return 2; }
        [ "$rc" -eq 0 ] && printf 'LIVE_TOOL\tharness=%s\tid=%s\tpath=%s\tscope=current-two-user-turns\n' "$harness" "$sid" "$target"
      done <<LIVE_TRANSCRIPTS
$_CC_WJ_ACTIVE_TRANSCRIPTS
LIVE_TRANSCRIPTS
      while IFS=$'\t' read -r harness sid transcript activity claim_state; do
        [ -n "$transcript" ] || continue
        _cc_wj_transcript_claims_path "$harness" "$transcript" "$target"; rc=$?
        [ "$rc" -ne 2 ] || { printf 'ERROR\tharness=%s\tid=%s\treason=unreadable-recent-transcript\n' "$harness" "$sid"; return 2; }
        [ "$rc" -eq 0 ] || continue
        age=$((now - activity)); [ "$age" -lt 0 ] && age=0
        remaining=$((grace * 3600 - age)); [ "$remaining" -lt 0 ] && remaining=0
        printf 'RECENT_TOOL\tharness=%s\tid=%s\tstate=%s\tpath=%s\tlast_activity=%s\tage=%ss\tremaining=%ss\tscope=current-two-user-turns\n' \
          "$harness" "$sid" "$claim_state" "$target" "$(_cc_wj_epoch_iso "$activity")" "$age" "$remaining"
      done <<RECENT_TRANSCRIPTS
$_CC_WJ_RECENT_TRANSCRIPTS
RECENT_TRANSCRIPTS
      ;;
  esac
}

# Replace one captured-live Codex task with its archived state after the writer lock has
# closed and Codex has moved the rollout. Return 0 when reconciled, 1 while the state has
# not reached archived yet, and 2 for an unsafe or unreadable mapping.
_cc_wj_reconcile_codex_archive() { # <task id>
  local sid="$1" state="${CC_WJ_CODEX_STATE_DB:-$HOME/.codex/state_5.sqlite}"
  local sqlite row count cwd rollout activity archived resolved now attempt=1
  sqlite="$(command -v sqlite3 2>/dev/null)" || return 2
  [ -r "$state" ] || return 2
  while :; do
    row="$("$sqlite" -batch -noheader -cmd '.timeout 2000' "$state" \
      "select cwd || char(9) || rollout_path || char(9) || max(updated_at, coalesce(archived_at, 0)) || char(9) || archived from threads where id = '$sid';" 2>/dev/null)" || return 2
    count="$(printf '%s\n' "$row" | grep -c .)"
    if [ "$count" -eq 1 ]; then
      IFS=$'\t' read -r cwd rollout activity archived <<< "$row"
      [ "$archived" = 1 ] && break
    fi
    [ "$attempt" -lt 6 ] || return 1
    sleep 0.2
    attempt=$((attempt + 1))
  done
  case "$cwd" in /*) ;; *) return 2 ;; esac
  case "$rollout" in ''|*$'\n'*|*$'\t'*) return 2 ;; esac
  case "$activity" in ''|*[!0-9]*) return 2 ;; esac
  [ -r "$rollout" ] || return 2
  resolved="$(_cc_wj_claim_cwd "$cwd")" || return 2

  # Drop the stale live snapshot before adding the bounded archived lease. Subsequent
  # candidates in this run then consult the relocated rollout instead of treating its
  # expected disappearance as a claim on every path.
  _CC_WJ_ACTIVE_CLAIMS="$(printf '%s\n' "$_CC_WJ_ACTIVE_CLAIMS" |
    awk -F '\t' -v id="$sid" 'NF && !($1 == "Codex" && $3 == id)')"
  _CC_WJ_ACTIVE_TRANSCRIPTS="$(printf '%s\n' "$_CC_WJ_ACTIVE_TRANSCRIPTS" |
    awk -F '\t' -v id="$sid" 'NF && !($1 == "Codex" && $2 == id)')"
  _CC_WJ_RECENT_CLAIMS="$(printf '%s\n' "$_CC_WJ_RECENT_CLAIMS" |
    awk -F '\t' -v id="$sid" 'NF && !($1 == "Codex" && $3 == id)')"
  _CC_WJ_RECENT_TRANSCRIPTS="$(printf '%s\n' "$_CC_WJ_RECENT_TRANSCRIPTS" |
    awk -F '\t' -v id="$sid" 'NF && !($1 == "Codex" && $2 == id)')"
  now="$(date +%s)"
  if [ "$activity" -ge $((now - _CC_WJ_ACTIVE_GRACE_HOURS * 3600)) ]; then
    _cc_wj_recent_add_claim Codex "$resolved" "$sid" "$activity" archived
    _cc_wj_recent_add_transcript Codex "$sid" "$rollout" "$activity" archived
  fi
  return 0
}

# Return 0 for an active claim, 1 for no claim, 2 when activity became unknowable,
# and 3 when a captured-live Codex task became a recent archived lease. Globals carry
# the human-readable result.
_cc_wj_active_claim() { # <worktree> [all|cwd|tool]
  local wt="$(_cc_wj_realpath "$1")" harness cwd sid transcript rc lock lock_rc reconcile_rc recent_rc
  local mode="${2:-all}"
  _CC_WJ_ACTIVE_REASON=""
  if [ "$mode" != "tool" ]; then
  while IFS=$'\t' read -r harness cwd sid; do
    [ -n "$cwd" ] || continue
    case "$cwd/" in "$wt/"|"$wt/"*)
      _CC_WJ_ACTIVE_REASON="active $harness session $sid claims cwd $cwd"
      return 0
      ;;
    esac
  done <<ACTIVE_CLAIMS
$_CC_WJ_ACTIVE_CLAIMS
ACTIVE_CLAIMS
  fi
  if [ "$mode" != "cwd" ]; then
  while IFS=$'\t' read -r harness sid transcript; do
    [ -n "$transcript" ] || continue
    # The cleanup task necessarily names every target it inventories. Treating its own
    # tool calls as ownership makes a manual cleanup unable to clean anything it looked
    # at. Its cwd claim above still protects the checkout it is actually using; only its
    # self-referential mentions are skipped. Other live sessions keep their full veto.
    if { [ "$harness" = Codex ] && [ -n "${CODEX_THREAD_ID:-}" ] && [ "$sid" = "$CODEX_THREAD_ID" ]; } ||
       { [ "$harness" = Claude ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$sid" = "$CLAUDE_CODE_SESSION_ID" ]; }; then
      continue
    fi
    _cc_wj_transcript_claims_path "$harness" "$transcript" "$wt"; rc=$?
    if [ "$rc" -eq 2 ]; then
      if [ "$harness" = Codex ]; then
        lock="${CC_WJ_CODEX_LOCKS:-$HOME/.codex/thread-writer-locks}/$sid.lock"
        _cc_wj_with_timeout 5 lsof -n -P "$lock" >/dev/null 2>&1; lock_rc=$?
        if [ "$lock_rc" -eq 1 ]; then
          _cc_wj_reconcile_codex_archive "$sid"; reconcile_rc=$?
          case "$reconcile_rc" in
            0)
              _cc_wj_recent_claim "$wt" "$_CC_WJ_ACTIVE_GRACE_HOURS"; recent_rc=$?
              case "$recent_rc" in
                0) return 3 ;;
                2) return 2 ;;
              esac
              continue
              ;;
            *)
              _CC_WJ_ACTIVE_ERROR="Codex session $sid ended while activity was being checked but its archived state could not be mapped"
              if [ "$(_cc_wj_unknown_scope)" != global ]; then
                _cc_wj_unknown_from_transcript "$harness" "$sid" "$transcript" "$_CC_WJ_ACTIVE_ERROR"
                continue
              fi
              return 2
              ;;
          esac
        fi
      fi
      _CC_WJ_ACTIVE_ERROR="the transcript for active $harness session $sid could not be parsed"
      if [ "$(_cc_wj_unknown_scope)" != global ]; then
        _cc_wj_unknown_from_transcript "$harness" "$sid" "$transcript" "$_CC_WJ_ACTIVE_ERROR"
        continue
      fi
      return 2
    fi
    if [ "$rc" -eq 0 ]; then
      _CC_WJ_ACTIVE_REASON="active $harness session $sid has a structured tool call in its current two user turns naming this worktree"
      return 0
    fi
  done <<ACTIVE_TRANSCRIPTS
$_CC_WJ_ACTIVE_TRANSCRIPTS
ACTIVE_TRANSCRIPTS
  fi
  return 1
}

# ─── Idleness ─────────────────────────────────────────────────────────────────

# yes, no, or unknown: whether nothing under $1 was modified within $2 hours. A `find`
# that fails - an unreadable directory inside the tree - is unknown, not idle.
#
# `-H`, because BSD find does not follow a symlink given as its starting point: a worktree
# moved to another disk and linked back read as untouched however recently it was written.
# The worktree's `HEAD`, `index` and `logs/` too, because a `git switch` or an empty commit
# changes only those. The janitor's own `git status` runs without optional locks, so it
# does not rewrite the index it is about to judge.
_cc_wj_idle() {
  local wt="$1" hours="$2" recent gd f
  # No window at all. Asked of find, `-mmin -0` still matches a file written in the same
  # second the scan started, whose age rounds below zero.
  [ "$hours" -eq 0 ] && { echo yes; return; }
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo unknown; return; }
  # HEAD and index only. The per-worktree reflog is NOT evidence that anybody worked here:
  # git rewrites it during ordinary maintenance -- reflog expiry, `gc --auto` -- for every
  # worktree of a repository in one pass, so one background sweep resets "idle" on all of
  # them at once and nothing can ever age out. Measured 2026-09-20 on the reporting host:
  # 108 of 114 worktrees carried the SAME reflog timestamp to the minute, while their HEAD
  # and index were 194-318 hours old and `find -mmin -10080` over the worktree matched
  # nothing. The idle gate therefore answered "no" for essentially every worktree, which is
  # why four consecutive scheduled sweeps removed 0 - a threshold nobody could reach, not a
  # threshold set too high. 108 trees sharing a timestamp to the second is one event, not
  # 108 people.
  #
  # HEAD moves on checkout, index on add/commit/status-with-changes; both are what "somebody
  # worked in this checkout" actually looks like.
  set -- "$wt"
  for f in HEAD index; do
    [ -e "$gd/$f" ] && set -- "$@" "$gd/$f"
  done
  if ! recent="$(find -H "$@" -mmin "-$((hours * 60))" -print -quit 2>/dev/null)"; then
    echo unknown
  elif [ -n "$recent" ]; then
    echo no
  else
    echo yes
  fi
}

# Resolve a path through symlinks using POSIX cd -P (no external deps).
_cc_wj_realpath() {
  local p="$1"
  if [ -d "$p" ]; then
    (builtin cd -P -- "$p" >/dev/null 2>&1 && pwd -P) || echo "$p"
  else
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    echo "$(builtin cd -P -- "$dir" >/dev/null 2>&1 && pwd -P)/$base"
  fi
}

# ─── Ahead-of-origin count ────────────────────────────────────────────────────

# Print number of commits ahead of origin/<branch>, or "?" on error
# Args: <wt_path> <branch> <remote_sha>
# remote_sha="" means no remote ref — returns "?"
_cc_wj_ahead_count() {
  local wt_path="$1"
  local branch="$2"
  local remote_sha="$3"

  if [ -z "$branch" ] || [ "$branch" = "(detached)" ]; then
    echo "?"
    return
  fi

  if [ -z "$remote_sha" ]; then
    echo "?"
    return
  fi

  local remote_ref="origin/$branch"
  git -C "$wt_path" rev-list --count "${remote_ref}..HEAD" 2>/dev/null || echo "?"
}

# ─── Push state ───────────────────────────────────────────────────────────────

# PUSHED / diverged / no_remote
# Args: <wt_path> <branch> <remote_sha>
# remote_sha="" means no remote ref — returns "no_remote"
_cc_wj_push_state() {
  local wt_path="$1"
  local branch="$2"
  local remote_sha="$3"

  if [ -z "$branch" ] || [ "$branch" = "(detached)" ]; then
    echo "no_remote"
    return
  fi

  if [ -z "$remote_sha" ]; then
    echo "no_remote"
    return
  fi

  local local_sha
  local_sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null) || { echo "no_remote"; return; }

  if [ "$local_sha" = "$remote_sha" ]; then
    echo "PUSHED"
  else
    echo "diverged"
  fi
}

# ─── Worktree enumeration ─────────────────────────────────────────────────────

# Emit one TAB-separated inventory line for a non-primary worktree block.
# Args: <wt_path> <branch> <block_index>
# block_index 0 = primary worktree → skipped.
_cc_wj_emit_wt_block() {
  local wt="$1" br="$2" bidx="$3"
  [ -z "$wt" ] && return
  # First block (index 0) is the primary worktree — skip it
  [ "$bidx" -eq 0 ] && return

  local dirty ahead push_state remote_sha pins pin_summary more shown
  # A tab or newline in the path would shift or split the inventory line that carries it.
  # Such a worktree is shown with `?` in place of those bytes and never judged, so the
  # altered spelling never reaches a removal.
  case "$wt" in
    *$'\t'*|*$'\n'*)
      shown="${wt//$'\t'/?}"
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" "${shown//$'\n'/?}" "${br:-?}" "UNSAFE-PATH" "?" "no_remote" "-"
      return ;;
  esac
  if [ ! -d "$wt" ]; then
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$wt" "${br:-?}" "MISSING" "?" "no_remote" "-"
  else
    # `--ignored`, because a removal deletes ignored content along with the checkout and
    # plain `--porcelain` cannot see any of it. The entries are named, not only counted:
    # on 2026-09-11 45 worktrees were kept by a handful of log files that took a separate
    # investigation to find, because the report said only how many.
    pins="$(_cc_wj_pins "$wt")"
    if [ -z "$pins" ]; then
      dirty=0
      pin_summary="-"
    else
      dirty="$(printf '%s\n' "$pins" | wc -l | tr -d ' ')"
      pin_summary="$(printf '%s\n' "$pins" | head -n 3 | awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }')"
      more=$((dirty - 3))
      [ "$more" -gt 0 ] && pin_summary="$pin_summary (+$more more)"
    fi
    # Resolve remote SHA once; pass to both helpers to avoid double rev-parse
    remote_sha=""
    if [ -n "${br:-}" ] && [ "$br" != "(detached)" ]; then
      remote_sha=$(git -C "$wt" rev-parse --verify --quiet "origin/$br" 2>/dev/null || echo "")
    fi
    ahead=$(_cc_wj_ahead_count "$wt" "${br:-}" "$remote_sha")
    push_state=$(_cc_wj_push_state "$wt" "${br:-}" "$remote_sha")
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$wt" "${br:-?}" "$dirty" "$ahead" "$push_state" "$pin_summary"
  fi
}

# For a given repo path, print one line per non-primary worktree:
#   <wt_path> TAB <branch> TAB <dirty> TAB <ahead> TAB <push_state> TAB <pins>
#
# Read with `-z`, so a path containing a newline arrives whole rather than cut short.
_cc_wj_list_worktrees() {
  local repo="$1" sf rec wt_path="" branch="" block_index=0

  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-worktrees.XXXXXX")" || return 1
  if ! git -C "$repo" worktree list --porcelain -z > "$sf" 2>/dev/null; then
    rm -f "$sf"
    return 1
  fi

  # Records: `worktree <path>`, `HEAD <sha>`, `branch refs/heads/<name>` or `detached`,
  # optional `bare`/`locked`/`prunable`, then an empty record ending the block. Only the
  # very first block (index 0) - the primary worktree - is skipped.
  while IFS= read -r -d '' rec; do
    case "$rec" in
      "worktree "*)
        if [ -n "$wt_path" ]; then
          _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
          block_index=$((block_index + 1))
        fi
        wt_path="${rec#worktree }"
        branch=""
        ;;
      "branch "*) branch="${rec#branch refs/heads/}" ;;
      detached) branch="(detached)" ;;
      bare) branch="(bare)" ;;
      "")
        if [ -n "$wt_path" ]; then
          _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
          block_index=$((block_index + 1))
          wt_path=""
          branch=""
        fi
        ;;
    esac
  done < "$sf"
  rm -f "$sf"

  if [ -n "$wt_path" ]; then
    _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
  fi
}

# ─── Ignored content: what a removal would take with it ──────────────────────

# Caches a documented command rebuilds. Kept deliberately short: an entry here is a
# claim that losing the directory is safe, and the default for anything not named is
# to keep the worktree, which is the direction that cannot lose work.
CC_WJ_TRIM_DIRTY_IDLE_HOURS="${CC_WJ_TRIM_DIRTY_IDLE_HOURS:-168}"
CC_WJ_REGENERABLE="${CC_WJ_REGENERABLE:-node_modules .next .turbo .parcel-cache .svelte-kit .nuxt .astro .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .gradle .nyc_output coverage playwright-report test-results .wrangler-dist}"
# `.superpowers` is deliberately absent too: it holds brainstorm mockups, SDD
# ledgers, briefs, reports and review packages - a record of decisions, which no
# command regenerates.
# Four names came off this list rather than onto it, because an entry here is a claim
# that losing the directory is safe:
#   .wrangler  - `.wrangler/state` is local D1, KV, R2 and Durable Object data. A
#                developer's database, not a cache; nothing rebuilds it. The name
#                looks like tooling scaffolding, which is how it got in.
#   dist/build/target - conventionally build output and usually regenerable, but the
#                names are generic enough to be anything, and this list authorises
#                deleting the whole worktree when only its entries remain.
# `.wrangler-dist` stays: that one really is build output.
# The same claim for ignored entries that are not whole directories. `--porcelain`
# gives a trailing slash to a directory and to nothing else, so a generated file and
# a symlink pointing at a cache both arrive shaped like a hand-written `.env` and a
# directory-keyed list can never reach either.
CC_WJ_REGENERABLE_FILES="${CC_WJ_REGENERABLE_FILES:-next-env.d.ts tsconfig.tsbuildinfo .eslintcache}"

# Credential-shaped names. Discounting a directory says everything below it is
# machine-owned, which is true of a package tree and not of the `.env` somebody parked
# inside one: porcelain collapses the directory to one line, so no name inside it is
# ever seen unless something looks.
_cc_wj_sensitive_name() {
  case "$1" in
    .env.example|.env.sample|.env.template|.env.dist) return 1 ;;
    .env|.env.*|*.pem|*.key|*.p12|*.keystore|id_rsa|id_ed25519|credentials.json) return 0 ;;
  esac
  return 1
}

# A credential-shaped file under $1 - to depth $2, or at any depth outside the package
# trees inside it when $2 is empty (every virtualenv ships certifi's `cacert.pem` five
# levels down). A `find` that FAILS answers like one that found something: an unreadable
# directory is not evidence that nothing is there.
_cc_wj_find_credential() {
  local dir="$1" depth="${2:-}" hit
  set -- \( -type f -o -type l \) \
         ! -name '.env.example' ! -name '.env.sample' \
         ! -name '.env.template' ! -name '.env.dist' \( \
         -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o \
         -name '*.p12' -o -name '*.keystore' -o -name 'id_rsa' -o \
         -name 'id_ed25519' -o -name 'credentials.json' \
         \) -print -quit
  if [ -n "$depth" ]; then
    hit="$(find "$dir" -maxdepth "$depth" "$@" 2>/dev/null)" || return 0
  else
    hit="$(find "$dir" -type d \( -name node_modules -o -name site-packages \) -prune \
             -o "$@" 2>/dev/null)" || return 0
  fi
  [ -n "$hit" ]
}

# Patterns the repository declares regenerable in `.worktree-regenerable` on its fetched
# base, newline-separated; set per repository by `_cc_wj_prepare_base`.
#
# The lists above are this tool's knowledge, and a tool installed for every repository
# cannot know that one API opens `data/parsed/logs/api.log` at import or that one test
# suite leaves `model/one-api.db` behind. Measured 2026-09-11 in the repository this was
# built for: 45 landed worktrees and 35 GB kept by files like those, none of them named.
# Read from the base rather than the worktree, so every existing worktree benefits the
# moment a declaration lands, and so a branch cannot declare its own content disposable
# on the way to having it deleted.
_CC_WJ_DECLARED=""

# Patterns from `archive:<pattern>` lines, set alongside. They name records a person wrote -
# stima-api's `.canary-window-plan` kept 14 landed worktrees on 2026-09-24 - that nothing
# rebuilds but that a copy preserves: such a file leaves with its worktree once the removal
# has copied it out.
_CC_WJ_ARCHIVED=""

# Whether repository-relative path $2 matches a pattern in newline-separated list $1.
# Unquoted patterns on purpose - they are globs, and `$pat/*` lets a declared directory
# cover what is inside it. zsh does not treat an expanded parameter as a pattern unless
# told to.
_cc_wj_matches() {
  local list="$1" p="$2" pat
  [ -n "$list" ] || return 1
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options glob_subst
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$p" in $pat|$pat/*) return 0 ;; esac
  done <<DECL
$list
DECL
  return 1
}

# Whether repository-relative path $1 is declared regenerable.
_cc_wj_declared() { _cc_wj_matches "$_CC_WJ_DECLARED" "$1"; }

# Whether ignored file $2 in worktree $1 may leave with the worktree once copied out: 0 yes,
# 1 no archive: pattern names it, 2 one does but it is not copied (why in
# _CC_WJ_ARCHIVE_WHY). A regular file only; never a credential, since the archive would be
# a second home for it; never a name the line-oriented copy list would split; and never
# past CC_WJ_ARCHIVE_MAX_BYTES, because the archive is for what a person wrote, and a
# database copied out reclaims nothing.
_cc_wj_archivable() {
  local wt="$1" rel="$2" max="${CC_WJ_ARCHIVE_MAX_BYTES:-1048576}" size=""
  _CC_WJ_ARCHIVE_WHY=""
  _cc_wj_matches "$_CC_WJ_ARCHIVED" "$rel" || return 1
  if [ -L "$wt/$rel" ] || [ ! -f "$wt/$rel" ]; then
    _CC_WJ_ARCHIVE_WHY="not a regular file"
  elif _cc_wj_sensitive_name "${rel##*/}"; then
    _CC_WJ_ARCHIVE_WHY="credential-shaped"
  else
    case "$rel" in
      *$'\t'*|*$'\n'*) _CC_WJ_ARCHIVE_WHY="its name holds a tab or newline" ;;
      *)
        case "$max" in
          ''|*[!0-9]*) _CC_WJ_ARCHIVE_WHY="CC_WJ_ARCHIVE_MAX_BYTES is not a number" ;;
          *)
            size="$(wc -c < "$wt/$rel" 2>/dev/null)" || size=""
            size="${size//[[:space:]]/}"
            case "$size" in
              ''|*[!0-9]*) _CC_WJ_ARCHIVE_WHY="its size could not be read" ;;
              *) [ "$size" -le "$max" ] || _CC_WJ_ARCHIVE_WHY="larger than $max bytes" ;;
            esac ;;
        esac ;;
    esac
  fi
  [ -z "$_CC_WJ_ARCHIVE_WHY" ] || return 2
}

# A declared ignored directory: 0 disposable, 1 not declared, 2 declared but holding a
# credential-shaped file, 3 declared but within reach of an archive: pattern. A build
# copies `.env` into its output at whatever depth it likes, so a declared directory is
# searched to the bottom, package trees aside.
_cc_wj_declared_dir() {
  local wt="$1" d="$2"
  [ -n "$_CC_WJ_DECLARED" ] || return 1
  if _cc_wj_declared "$d"; then
    _cc_wj_find_credential "$wt/$d" && return 2
  else
    _cc_wj_declared_contents "$wt" "$d" || return $?
  fi
  # 3: discounted whole, it would take an archive:-declared file inside it along uncopied.
  # Only a clean "cannot reach" discounts it: a check that failed answered nothing.
  _cc_wj_archive_may_reach "$d"
  [ $? -eq 1 ] || return 3
  return 0
}

# Whether an archive: pattern could name a path inside directory $1: 0 yes, 1 no, anything
# else unknown. Yes when its text before the first wildcard is empty, is a prefix of `$1/`,
# or starts with `$1/`: `*.md` and `logs*` can reach into `logs/`; `.canary-window-plan`
# cannot.
# ponytail: judged from the patterns' text, so `archive:logs/notes.md` keeps every worktree
# with a declared `logs/`, and `archive:*.plan` every one with a declared ignored directory;
# walk the directory, bounded as `_cc_wj_declared_contents` is, if that keeps too much.
_cc_wj_archive_may_reach() {
  [ -n "$_CC_WJ_ARCHIVED" ] || return 1
  # The directory goes in through the environment: `-v` expands its escapes, and BSD awk
  # refuses a newline in it outright. `p == ""` spelled out: index() of an empty string is
  # 1 in BSD awk and 0 in gawk.
  printf '%s\n' "$_CC_WJ_ARCHIVED" | D="$1/" awk 'NF {
      p = $0; i = match(p, /[*?]/); if (i) p = substr(p, 1, i - 1)
      if (p == "" || index(ENVIRON["D"], p) == 1 || index(p, ENVIRON["D"]) == 1) f = 1
    } END { exit !f }' 2>/dev/null
}

# Whether a plain declaration names directory $2 itself, below archive: ancestor $1: its
# text before the first wildcard starts with `$1/`, and what follows spells two consecutive
# characters outside its wildcards. `$1/*` and a line naming $1 or one of its ancestors are
# as broad as the archive: line, and would discard the records it keeps.
_cc_wj_declared_below() {
  local anc="$1" p="$2" pat lit
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options glob_subst
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in "$anc/"*) ;; *) continue ;; esac
    lit="${pat#"$anc/"}"
    case "$lit" in *[!*?][!*?]*) ;; *) continue ;; esac
    lit="${pat%%[*?]*}"
    case "$lit" in "$anc/"*) ;; *) continue ;; esac
    # shellcheck disable=SC2254
    case "$p" in $pat) return 0 ;; esac
  done <<DECL
$_CC_WJ_DECLARED
DECL
  return 1
}

# Judge every file inside collapsed ignored directory $2 of worktree $1 that an archive:
# pattern may reach, as `_cc_wj_pins` judges an ignored file: an archivable one is appended
# to $3 for the copy, one only a plain line declares is discounted, and anything else
# prints one pin and stops. stima-api's `.codex/evidence/` - records merged docs cite - kept
# 25 landed worktrees (20.3G) on 2026-10-18 for 1.33G of them, because the directory was
# pinned rather than walked (#5284). Never past 1000 files: a directory holding more is not
# a record directory, and the walk is repeated on every recheck.
#
# A subdirectory a plain line declares - a virtualenv beside the records - is discounted
# whole after the credential scan, when every archive: pattern that reaches it is a
# wildcard-free strict ancestor of it, and a plain line names it below the deepest of them,
# such as `.codex/evidence/*/venv` below `.codex/evidence`: the plain line is the more
# specific statement. Otherwise its files are judged one by one, archive: first.
_cc_wj_archive_walk() {
  local wt="$1" d="$2" archive_to="${3:-}" list dirs f rel n=0 arc pruned="" p skip anc nl
  # A walk that fails is not a walk that found nothing.
  nl="$(find "$wt/$d" -name "*"$'\n'"*" -print -quit 2>/dev/null)" &&
    dirs="$(find "$wt/$d" -mindepth 1 -type d -print 2>/dev/null)" &&
    list="$(find "$wt/$d" ! -type d -print 2>/dev/null)" || {
    _cc_wj_pin '!!' "$d/ (declared archive:, but it could not be walked)"; return 0; }
  # A name holding a newline arrives as fragments, which can spell another path.
  [ -z "$nl" ] || {
    _cc_wj_pin '!!' "$d/ (declared archive:, but a name in it holds a newline)"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$wt/$d/"*) ;; *)
      _cc_wj_pin '!!' "$d/ (declared archive:, but a name in it holds a newline)"; return 0 ;; esac
    rel="${f#"$wt/"}"
    skip=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$rel/" in "$p/"*) skip=1; break ;; esac
    done <<PRUNED
$pruned
PRUNED
    [ "$skip" -eq 0 ] || continue
    # The deepest wildcard-free ancestor among the archive: patterns reaching it; any other
    # pattern reaching it answers no prune.
    anc="$(printf '%s\n' "$_CC_WJ_ARCHIVED" | D="$rel" awk 'NF {
        p = $0; i = match(p, /[*?]/)
        if (i) { p = substr(p, 1, i - 1); if (p == "" || index(ENVIRON["D"] "/", p) == 1 || index(p, ENVIRON["D"] "/") == 1) bad = 1 }
        else if (p == ENVIRON["D"] || index(p, ENVIRON["D"] "/") == 1) bad = 1
        else if (index(ENVIRON["D"], p "/") == 1 && length(p) > length(a)) a = p
      } END { if (bad) exit 1; print a }' 2>/dev/null)" || continue
    if [ -n "$anc" ]; then _cc_wj_declared_below "$anc" "$rel" || continue
    else _cc_wj_declared "$rel" || continue
    fi
    if _cc_wj_find_credential "$f"; then
      _cc_wj_pin '!!' "$rel/ (declared, but holds a credential-shaped file)"; return 0
    fi
    pruned="$pruned$rel"$'\n'
  done <<DIRS
$dirs
DIRS
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A name containing a newline arrives as fragments; a fragment proves nothing.
    case "$f" in "$wt/$d/"*) ;; *)
      _cc_wj_pin '!!' "$d/ (declared archive:, but a name in it holds a newline)"; return 0 ;; esac
    rel="${f#"$wt/"}"
    skip=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$rel" in "$p/"*) skip=1; break ;; esac
    done <<PRUNED
$pruned
PRUNED
    [ "$skip" -eq 0 ] || continue
    n=$((n + 1))
    [ "$n" -le 1000 ] || {
      _cc_wj_pin '!!' "$d/ (declared archive:, but it holds more than 1000 files)"; return 0; }
    rel="${f#"$wt/"}"
    arc=0
    _cc_wj_archivable "$wt" "$rel" || arc=$?
    case "$arc" in
      0)
        [ -z "$archive_to" ] || { printf '%s\n' "$rel" >> "$archive_to"; } 2>/dev/null || {
          _cc_wj_pin '!!' "$rel (declared archive:, but it could not be listed for the copy)"
          return 0; }
        continue ;;
      2) _cc_wj_pin '!!' "$rel (declared archive:, but $_CC_WJ_ARCHIVE_WHY)"; return 0 ;;
    esac
    _cc_wj_declared "$rel" && ! _cc_wj_sensitive_name "${rel##*/}" && continue
    _cc_wj_pin '!!' "$rel"
    return 0
  done <<LIST
$list
LIST
  return 0
}

# git collapses a wholly ignored directory to one `!! dir/` entry, so a declaration naming
# files inside it - `logs/*.log` inside `logs/` - never meets a name it can match. Such a
# directory is disposable when every non-directory in it is declared and none is
# credential-shaped. Walked only when some pattern could name a path below it, and never
# past 200 files: a directory holding more is not a log directory, whatever the patterns
# say.
_cc_wj_declared_contents() {
  local wt="$1" d="$2" list f n=0
  # `p == ""` spelled out: index() of an empty string is 1 in BSD awk and 0 in gawk.
  printf '%s\n' "$_CC_WJ_DECLARED" | awk -v d="$d/" '{
      p = $0; i = match(p, /[*?[]/); if (i) p = substr(p, 1, i - 1)
      if (p == "" || index(d, p) == 1 || index(p, d) == 1) f = 1
    } END { exit !f }' || return 1
  # A walk that fails is not a walk that found nothing.
  list="$(find "$wt/$d" ! -type d -print 2>/dev/null)" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # A name containing a newline arrives as fragments; a fragment proves nothing.
    case "$f" in "$wt/$d/"*) ;; *) return 1 ;; esac
    n=$((n + 1))
    [ "$n" -le 200 ] || return 1
    _cc_wj_sensitive_name "${f##*/}" && return 2
    _cc_wj_declared "${f#"$wt/"}" || return 1
  done <<LIST
$list
LIST
  return 0
}

# Print patterns from stdin that name a path ($1 = 1) or that do not ($1 = 0). A pattern
# with a wildcard must spell two consecutive characters outside its wildcards: `*`, `*.*`,
# `*e*` and `a*` name nothing in particular and would discount hand-written notes along
# with the logs. `*.o` and `db/*` pass, and a pattern with no wildcard names one path.
#
# Only plain names and the wildcards `*` and `?` are accepted; any other glob syntax is
# dropped. Counting literal characters around it was bypassed three times: bracket
# expressions (`[[:alpha:]][[:alpha:]]*`, `[!]][!]]*`) and, sourced into zsh where the
# match uses glob_subst, alternation (`(*|ab)`) all matched every path.
_cc_wj_names_a_path() {
  awk -v want="$1" 'NF { ok = ($0 ~ /^[A-Za-z0-9._\/*?+@ -]+$/) && (($0 !~ /[*?]/) || ($0 ~ /[^*?][^*?]/))
    if (ok == want) print }'
}

# One report line for an entry that keeps the worktree. Tabs and newlines in a name would
# break the inventory line that carries it, so they are shown as `?`.
_cc_wj_pin() {
  local line="$1 $2"
  line="${line//$'\t'/?}"
  printf '%s\n' "${line//$'\n'/?}"
}

# ─── Rules on probation, and names nothing may touch (stima-api#5886) ─────────

# On 2026-10-24 the last sweep kept 50 worktrees (30.9 GB) as unrebuildable, most of them for
# one of two trivial entries: a top-level log a dev server or build wrote (`next-manual.log`,
# `routing-snapshot-redis.log`, `.build-main.log`), and the `.claude/skills` link an older
# new-task-worktree.sh made into the primary checkout. Neither is work: the log is output, and
# removing a link removes nothing it names. Both rules start in spot-check mode, where they
# change no decision and log what they would have trimmed or removed; `auto` lets them decide.
_cc_wj_new_rules_mode() {
  case "${CC_WJ_NEW_RULES_MODE:-spotcheck}" in
    auto) echo auto ;;
    *) echo spotcheck ;;
  esac
}

# The rule that discounts ignored entry $2 (porcelain path, no trailing slash) of worktree $1,
# printed, or status 1. Asked only after every existing discount has declined the entry.
_cc_wj_new_rule() {
  local wt="$1" rest="$2" target common primary resolved dir
  case "$rest" in *$'\t'*|*$'\n'*|'') return 1 ;; esac
  case "$rest" in
    */*) ;;
    *.log)
      # A regular file at the top level, not a link and not credential-shaped.
      [ -f "$wt/$rest" ] && [ ! -L "$wt/$rest" ] || return 1
      _cc_wj_sensitive_name "$rest" && return 1
      echo top-level-log; return 0 ;;
    *) return 1 ;;
  esac
  case "$rest" in .claude/skills|.claude/commands) ;; *) return 1 ;; esac
  [ -L "$wt/$rest" ] || return 1
  target="$(readlink "$wt/$rest" 2>/dev/null)" || return 1
  [ -n "$target" ] || return 1
  case "$target" in /*) ;; *) target="$wt/.claude/$target" ;; esac
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$(basename "$common")" = .git ] || return 1
  primary="$(dirname "$common")"
  # Resolved when the target's directory exists, so `..` and a symlinked home compare by what
  # they name; a dangling link is compared as written.
  dir="$(dirname "$target")"
  resolved="$target"
  if [ -d "$dir" ]; then
    resolved="$(_cc_wj_realpath "$dir")/$(basename "$target")"
  fi
  case "$resolved" in */../*|*/./*|*/..|*/.) return 1 ;; esac
  for dir in "$primary" "$(_cc_wj_realpath "$primary")"; do
    case "$resolved" in "${dir%/}"/*) echo primary-skills-link; return 0 ;; esac
  done
  return 1
}

_cc_wj_spotcheck_log() {
  printf '%s\n' "${CC_WJ_SPOTCHECK_LOG:-$HOME/.cc-reaper/logs/spotcheck-worktree-janitor.log}"
}

# One spot-check record: what a new rule would have done, and nothing done.
_cc_wj_spotcheck() { # <phase> <action> <rules> <path> <bytes> <holder> <worktree>
  local log
  log="$(_cc_wj_spotcheck_log)"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  _cc_wj_bound_log "$log"
  printf '[%s] run=%s phase=%s action=%s rule=%s path=%s bytes=%s holder=%s worktree=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${_CC_WJ_RUN_ID:-?}" "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    >> "$log" 2>/dev/null || true
}

# Status 0, with _CC_WJ_DENY_REASON set, when CC_WJ_DENY_NAMES forbids touching worktree $1 on
# branch $2: a name inside the worktree's directory name or branch, or a live Claude session
# of that name standing at or under it. A live session's structured tool calls already veto
# through the ordinary claim gate; this one holds whatever the claim windows say.
_CC_WJ_DENY_REASON=""
_cc_wj_denied() {
  local wt="$1" branch="$2" name base phys sname scwd
  _CC_WJ_DENY_REASON=""
  [ -n "${CC_WJ_DENY_NAMES:-}" ] || return 1
  base="$(basename "$wt")"
  phys="$(_cc_wj_realpath "$wt")"
  for name in $CC_WJ_DENY_NAMES; do
    case "$base" in *"$name"*) _CC_WJ_DENY_REASON="deny-listed:$name"; return 0 ;; esac
    case "$branch" in *"$name"*) _CC_WJ_DENY_REASON="deny-listed:$name"; return 0 ;; esac
    while IFS=$'\t' read -r sname scwd; do
      [ "$sname" = "$name" ] && [ -n "$scwd" ] || continue
      case "$scwd/" in "${phys%/}/"*|"${wt%/}/"*)
        _CC_WJ_DENY_REASON="deny-listed:session $name"; return 0 ;;
      esac
    done <<DENY_SESSIONS
${_CC_WJ_ACTIVE_NAMES:-}
DENY_SESSIONS
  done
  return 1
}

# Print every entry a removal would destroy that nothing is known to rebuild, one per
# line as `<porcelain code> <path>`. When the status cannot be read, print one line
# saying so and fail: an unreadable repository must not read as a clean one.
#
# Read with `-z` from a file. Without `-z` git C-quotes any path that is not plain ASCII,
# and `[ -L "$wt/$rest" ]` then probes a name that does not exist; command substitution
# would strip the NULs `-z` produces. The file also keeps git's exit status apart from
# the loop's. Nothing here is named `status` or `path`: both are reserved in zsh, and
# this file is sourceable.
#
# With $2, each archivable file this read discounts is appended to that file, one path per
# line, so a removal copies out exactly what the read that cleared it saw.
_cc_wj_pins() {
  local wt="$1" archive_to="${2:-}" sf rec code rest base skip_next=0 drc reach arc status_timeout status_rc=0 nr
  status_timeout="$(_cc_wj_git_status_timeout_seconds)" || {
    _cc_wj_pin '??' "(invalid git status timeout)"; return 1; }
  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-status.XXXXXX")" || {
    _cc_wj_pin '??' "(no temporary file to read its status into)"; return 1; }
  # No optional locks, so a user's concurrent commit never meets this scan's index.lock
  # and the index the idle gate reads is not rewritten; no fsmonitor, so no daemon starts
  # inside the worktree and shows up as its holder.
  _cc_wj_with_timeout "$status_timeout" \
    git --no-optional-locks -c core.fsmonitor=false -C "$wt" \
      status --porcelain --ignored -z > "$sf" 2>/dev/null || status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    rm -f "$sf"
    if [ "$status_rc" -eq 124 ]; then
      _cc_wj_pin '??' "(git status timed out after ${status_timeout}s)"
    else
      _cc_wj_pin '??' "(git status failed)"
    fi
    return 1
  fi
  while IFS= read -r -d '' rec; do
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    [ -n "$rec" ] || continue
    code="${rec:0:2}"
    rest="${rec:3}"
    # A rename or copy is followed by a second record holding its source path.
    case "$code" in R?|?R|C?|?C) skip_next=1 ;; esac
    if [ "$code" != '!!' ]; then
      _cc_wj_pin "$code" "$rest"   # tracked change or untracked entry: real work
      continue
    fi
    case "$rest" in
      */)
        rest="${rest%/}"
        base="${rest##*/}"
        case " $CC_WJ_REGENERABLE " in
          *" $base "*)
            # Two levels down is where a person parks something in a cache; a scan to the
            # bottom of `node_modules` costs seconds per worktree.
            _cc_wj_find_credential "$wt/$rest" 2 &&
              _cc_wj_pin '!!' "$rest/ (holds a credential-shaped file)"
            continue ;;
        esac
        drc=0
        _cc_wj_declared_dir "$wt" "$rest" || drc=$?
        reach=1
        case "$drc" in 0|2) ;; *) _cc_wj_archive_may_reach "$rest"; reach=$? ;; esac
        case "$drc:$reach" in
          0:*) ;;
          2:*) _cc_wj_pin '!!' "$rest/ (declared, but holds a credential-shaped file)" ;;
          *:0) _cc_wj_archive_walk "$wt" "$rest" "$archive_to" ;;
          3:*) _cc_wj_pin '!!' "$rest/ (declared, but an archive: pattern may name a path inside it)" ;;
          *) _cc_wj_pin '!!' "$rest/" ;;
        esac
        ;;
      *)
        # No trailing slash: an ignored file, or a symlink - git marks a link to a
        # directory the same way. Removing a link to a cache removes nothing it names.
        base="${rest##*/}"
        if [ -L "$wt/$rest" ]; then
          case " $CC_WJ_REGENERABLE " in *" $base "*) continue ;; esac
        fi
        case " $CC_WJ_REGENERABLE_FILES " in *" $base "*) continue ;; esac
        # archive: first: a plain line naming the same file would delete it uncopied.
        arc=0
        _cc_wj_archivable "$wt" "$rest" || arc=$?
        case "$arc" in
          0)
            # Unlisted, it would be removed without a copy.
            [ -z "$archive_to" ] || { printf '%s\n' "$rest" >> "$archive_to"; } 2>/dev/null ||
              _cc_wj_pin '!!' "$rest (declared archive:, but it could not be listed for the copy)"
            continue ;;
          2)
            _cc_wj_pin '!!' "$rest (declared archive:, but $_CC_WJ_ARCHIVE_WHY)"
            continue ;;
        esac
        if _cc_wj_declared "$rest" && ! _cc_wj_sensitive_name "$base"; then
          continue
        fi
        if nr="$(_cc_wj_new_rule "$wt" "$rest")"; then
          [ "$(_cc_wj_new_rules_mode)" = auto ] && continue
          # Spot check: still kept, and the inventory is told which rule would discount it.
          [ -z "${_CC_WJ_NEWRULE_LOG:-}" ] ||
            printf '%s\t%s\t%s\n' "$wt" "$nr" "$rest" >> "$_CC_WJ_NEWRULE_LOG" 2>/dev/null || true
        fi
        _cc_wj_pin '!!' "$rest"
        ;;
    esac
  done < "$sf"
  rm -f "$sf"
  return 0
}

# Count the entries a removal would destroy that nothing is known to rebuild. $2 as for
# `_cc_wj_pins`.
_cc_wj_undiscounted_count() {
  local out
  out="$(_cc_wj_pins "$1" "${2:-}")"
  if [ -z "$out" ]; then
    echo 0
  else
    printf '%s\n' "$out" | wc -l | tr -d ' '
  fi
}

# Print ignored, built-in regenerable directories in a worktree. This is deliberately
# separate from `_cc_wj_pins`: a normal worktree removal discounts these paths, while a
# pressure pass needs to name them so it can remove only those bytes and leave the
# worktree, branch and all authored content in place.
_cc_wj_regenerable_dirs() {
  local wt="$1" sf rec code rest base status_timeout status_rc=0
  status_timeout="$(_cc_wj_git_status_timeout_seconds)" || return 1
  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-regenerable.XXXXXX")" || return 1
  _cc_wj_with_timeout "$status_timeout" \
    git --no-optional-locks -c core.fsmonitor=false -C "$wt" \
      status --porcelain --ignored -z > "$sf" 2>/dev/null || status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    rm -f "$sf"
    return 1
  fi
  while IFS= read -r -d '' rec; do
    [ -n "$rec" ] || continue
    code="${rec:0:2}"
    [ "$code" = '!!' ] || continue
    rest="${rec:3}"
    case "$rest" in
      */) rest="${rest%/}" ;;
      *) continue ;;
    esac
    case "$rest" in
      *$'\n'*|*$'\t'*) continue ;;
    esac
    base="${rest##*/}"
    case " $CC_WJ_REGENERABLE " in
      *" $base "*) ;;
      *) continue ;;
    esac
    [ -d "$wt/$rest" ] || continue
    [ -L "$wt/$rest" ] && continue
    # A cache directory containing an obvious credential is not disposable. The
    # existing shallow check is intentional: package trees contain certificate
    # bundles, while a credential parked near the cache root must veto trimming.
    _cc_wj_find_credential "$wt/$rest" 2 && continue
    printf '%s\n' "$wt/$rest"
  done < "$sf"
  rm -f "$sf"
  return 0
}

_cc_wj_trim_regenerable() {
  local wt="$1" work="$2" apply="$3" session_grace="$4" idle_window="${5:-}" dir bytes before after list_file list_rc
  local count=0 trimmed=0 reclaimed=0 active_rc recent_rc fresh scanned_at="" now
  fresh="$(_cc_wj_recheck_fresh_seconds)" || fresh=0
  [ "$LSOF_OK" = yes ] || { printf 'KEEP(process-scan-unknown)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'; return 0; }
  [ "$ACTIVE_OK" = yes ] || { printf 'KEEP(session-scan-unknown)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'; return 0; }
  if _cc_wj_held "$work" "$wt"; then
    printf 'KEEP(active-session)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'
    return 0
  fi
  _cc_wj_active_claim "$wt" trim; active_rc=$?
  case "$active_rc" in
    0) printf 'KEEP(%s)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n' "$_CC_WJ_ACTIVE_REASON"; return 0 ;;
    2) printf 'KEEP(session-scan-unknown)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'; return 0 ;;
  esac
  _cc_wj_recent_claim "$wt" "$session_grace" trim; recent_rc=$?
  case "$recent_rc" in
    0) printf 'KEEP(%s)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n' "$_CC_WJ_RECENT_REASON"; return 0 ;;
    2) printf 'KEEP(session-scan-unknown)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'; return 0 ;;
  esac
  if _cc_wj_unknown_gate "$wt" "$session_grace"; then
    printf 'KEEP(%s)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n' "$_CC_WJ_UNKNOWN_REASON"
    return 0
  fi
  # Under disk pressure the session lease is short, so a tree someone works in outside a
  # harness session must also have sat untouched for the pressure idle window.
  if [ -n "$idle_window" ] && [ "$(_cc_wj_idle "$wt" "$idle_window")" != yes ]; then
    printf 'KEEP(recent-activity)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'
    return 0
  fi

  list_file="$(mktemp "${TMPDIR:-/tmp}/cc-wj-trim-list.XXXXXX")" || {
    printf 'KEEP(trim-list-unavailable)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'
    return 0
  }
  _cc_wj_regenerable_dirs "$wt" > "$list_file" || list_rc=$?
  list_rc="${list_rc:-0}"
  if [ "$list_rc" -ne 0 ]; then
    rm -f "$list_file"
    printf 'KEEP(status-unknown)\nTRIM_RESULT count=0 trimmed=0 reclaimed=0\n'
    return 0
  fi
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    count=$((count + 1))
    bytes=0
    bytes=$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
    printf '  TRIM_CANDIDATE  %s  bytes=%s\n' "$dir" "$bytes"
    [ "$apply" -eq 1 ] || continue

    # Recheck the safety boundary immediately before every directory removal.
    # A session may start after inventory but before the first or a later cache. The
    # machine is rescanned before the first directory of a worktree, and before a later
    # one once that snapshot is CC_WJ_RECHECK_FRESH_SECONDS old: at load 60 each rescan
    # costs a machine-wide lsof, once per cache directory. Every check below still runs.
    now="$(date +%s)"
    if [ -z "$scanned_at" ] || [ $((now - scanned_at)) -ge "$fresh" ]; then
      if ! _cc_wj_scan_holders "$work" || ! _cc_wj_scan_active_sessions "$session_grace"; then
        printf '    → kept: holder or session scan became unavailable\n'
        break
      fi
      scanned_at="$now"
    fi
    _cc_wj_active_claim "$wt" trim; active_rc=$?
    [ "$active_rc" -eq 0 ] && { printf '    → kept: %s\n' "$_CC_WJ_ACTIVE_REASON"; break; }
    [ "$active_rc" -eq 2 ] && { printf '    → kept: session scan became unavailable\n'; break; }
    _cc_wj_recent_claim "$wt" "$session_grace" trim; recent_rc=$?
    [ "$recent_rc" -eq 0 ] && { printf '    → kept: %s\n' "$_CC_WJ_RECENT_REASON"; break; }
    [ "$recent_rc" -eq 2 ] && { printf '    → kept: session scan became unavailable\n'; break; }
    _cc_wj_unknown_gate "$wt" "$session_grace" &&
      { printf '    → kept: %s; an unreadable session record may be about it\n' "$_CC_WJ_UNKNOWN_REASON"; break; }
    if _cc_wj_held "$work" "$wt" || [ ! -d "$dir" ] || [ -L "$dir" ] ||
       _cc_wj_find_credential "$dir" 2; then
      printf '    → kept: cache changed or is no longer disposable\n'
      break
    fi
    before="$bytes"
    rm -rf -- "$dir" 2>/dev/null || {
      printf '    → kept: removal failed\n'
      break
    }
    after=0
    [ -e "$dir" ] && after=1
    if [ "$after" -ne 0 ]; then
      printf '    → kept: cache still exists after removal\n'
      break
    fi
    reclaimed=$((reclaimed + before))
    trimmed=$((trimmed + 1))
    printf '    → trimmed (%s bytes reclaimed)\n' "$before"
    # Every gate was asked again just now; say so to a sweep deciding whether this one died.
    [ -n "${lock:-}" ] && touch "$lock" 2>/dev/null
  done < "$list_file"
  rm -f "$list_file"
  printf 'TRIM_RESULT count=%s trimmed=%s reclaimed=%s\n' "$count" "$trimmed" "$reclaimed"
}

# ─── Base branch and landing ─────────────────────────────────────────────────

# Set per repository by `_cc_wj_prepare_base`: the integration branch, whether it was
# fetched during this run, and why not.
_CC_WJ_BASE=""
_CC_WJ_BASE_OK=0
_CC_WJ_BASE_WHY=""

# Resolve and fetch the base branch of repository $1, then read its declarations.
#
# Fetched, in report mode too, because `merge-base --is-ancestor` contacts nothing: a
# stale tracking ref makes a unique HEAD look landed after a force-push, and everything
# merged since the last fetch look unlanded. Into the fully qualified ref through an
# explicit refspec, because `git fetch origin <branch>` honours `remote.origin.fetch` and
# a custom one would update some other ref while this one stayed stale.
#
# `origin/HEAD` is what the clone recorded; without one the remote is asked. A guess of
# `main` is never made: in a repository whose trunk is not main nothing would be an
# ancestor, and the run would report normally while reclaiming nothing.
_cc_wj_prepare_base() {
  local repo="$1" base="${CC_WJ_BASE_BRANCH:-}" all plain archived dropped fetch_timeout fetch_err fetch_rc=0
  _CC_WJ_BASE=""; _CC_WJ_BASE_OK=0; _CC_WJ_BASE_WHY=""; _CC_WJ_DECLARED=""; _CC_WJ_ARCHIVED=""
  if ! git -C "$repo" config --get remote.origin.url >/dev/null 2>&1; then
    _CC_WJ_BASE_WHY="it has no origin remote"
    return 1
  fi
  if [ -z "$base" ]; then
    base="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
    base="${base#origin/}"
  fi
  if [ -z "$base" ]; then
    base="$(_cc_wj_with_timeout 30 git -C "$repo" ls-remote --symref origin HEAD 2>/dev/null |
            awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }')"
  fi
  if [ -z "$base" ]; then
    _CC_WJ_BASE_WHY="origin's default branch could not be resolved"
    return 1
  fi
  _CC_WJ_BASE="$base"
  # Without automatic maintenance: the gc a fetch may start prunes worktree records, and
  # this runs in report mode too.
  fetch_timeout="$(_cc_wj_fetch_timeout_seconds)" || {
    _CC_WJ_BASE_WHY="the base fetch timeout is invalid"; return 1; }
  fetch_err="$(_cc_wj_with_timeout "$fetch_timeout" git -C "$repo" fetch --quiet --no-tags \
    --no-auto-maintenance origin "+refs/heads/${base}:refs/remotes/origin/${base}" \
    2>&1 >/dev/null)" || fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ]; then
    if [ "$fetch_rc" -eq 124 ]; then
      _CC_WJ_BASE_WHY="origin/$base could not be fetched within ${fetch_timeout}s"
    else
      _CC_WJ_BASE_WHY="origin/$base could not be fetched (rc=$fetch_rc)"
    fi
    # git's first fatal/error line says why (no network, auth, a missing ref); its last
    # lines are generic advice. Credentials an origin URL may carry are blanked before the
    # line reaches a log.
    fetch_err="$(printf '%s\n' "$fetch_err" |
                 awk '/^(fatal|error):/ && !why { why = $0 } NF { last = $0 }
                      END { print (why ? why : last) }' |
                 sed -E 's#://[^/@[:space:]]*@#://***@#g' | cut -c1-200)"
    [ -z "$fetch_err" ] || _CC_WJ_BASE_WHY="$_CC_WJ_BASE_WHY: $fetch_err"
    return 1
  fi
  _CC_WJ_BASE_OK=1

  # A leading or trailing `/` is dropped, so `/logs/` means `logs`. `#` starts a comment at
  # the start of a line and after whitespace, so `logs  # runtime` does not declare a path
  # nobody has. These are shell globs, not .gitignore patterns: `*` matches across `/`.
  # `archive: /x` means `archive:x`.
  all="$(git -C "$repo" show "refs/remotes/origin/${base}:.worktree-regenerable" 2>/dev/null |
         sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]][[:space:]]*#.*$//' \
             -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's#^/*##' -e 's#/*$##' -e 's#^archive:[[:space:]/]*#archive:#')"
  # A negation cannot be honoured - a case glob has no "except" - and dropping just that
  # line would widen what the rest of the file discounts: `logs` then `!logs/keep.md`
  # still deletes the file its author protected. So the whole file is set aside.
  if printf '%s\n' "$all" | grep -q '^!'; then
    echo "worktree-janitor: $repo: .worktree-regenerable on origin/$base uses a negation (!), which is not supported; none of it was applied"
    return 0
  fi
  plain="$(printf '%s\n' "$all" | awk '!/^archive:/')"
  archived="$(printf '%s\n' "$all" | awk 'sub(/^archive:/, "")')"
  _CC_WJ_DECLARED="$(printf '%s\n' "$plain" | _cc_wj_names_a_path 1)"
  _CC_WJ_ARCHIVED="$(printf '%s\n' "$archived" | _cc_wj_names_a_path 1)"
  dropped="$( { printf '%s\n' "$plain" | _cc_wj_names_a_path 0
               printf '%s\n' "$archived" | _cc_wj_names_a_path 0 | sed 's/^/archive:/'; } |
             tr '\n' ' ')"
  [ -n "$dropped" ] &&
    echo "worktree-janitor: $repo: ignoring .worktree-regenerable pattern(s) on origin/$base that name no path: $dropped"
  return 0
}

# How the work in worktree $1 reached the base: ancestor, content, pr - or no, or
# unfetched when the base was not fetched this run.
_cc_wj_landed() {
  local wt="$1" ref
  [ "$_CC_WJ_BASE_OK" -eq 1 ] || { echo unfetched; return; }
  ref="refs/remotes/origin/$_CC_WJ_BASE"
  if git -C "$wt" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
    echo ancestor
  elif _cc_wj_landed_by_content "$wt" "$ref"; then
    echo content
  elif _cc_wj_landed_by_pr "$wt" "$ref" || _cc_wj_behind_merged "$wt" "$ref"; then
    echo pr
  else
    echo no
  fi
}

# Read-only policy query for another reaper that owns resources attached to a worktree.
# A local stack must be stopped before the holder gate can allow worktree removal, so it
# needs the exact same ancestry/content/PR answer without duplicating that policy.
_cc_wj_query_landed() { # <worktree>
  local wt="$1" proof
  if [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    echo "unknown"
    return 2
  fi
  if ! _cc_wj_prepare_base "$wt"; then
    echo "unfetched"
    return 2
  fi
  proof="$(_cc_wj_landed "$wt")"
  printf '%s\n' "$proof"
  case "$proof" in
    ancestor|content|pr) return 0 ;;
    no) return 1 ;;
    *) return 2 ;;
  esac
}

# Merging HEAD into the base would change nothing. Ancestry misses every squash merge and
# every rebase that left a local HEAD behind while its change landed; in a repository that
# squash-merges, an ancestry-only test reclaims nothing while reporting normally.
# Three-way rather than a comparison of the files the branch touched, so later edits on
# the base to other lines of those files do not turn landed work back into unlanded work.
# A conflict, unrelated history, or a git older than 2.38 fails, and failing keeps.
_cc_wj_landed_by_content() {
  local wt="$1" ref="$2" base_tree merged
  base_tree="$(git -C "$wt" rev-parse "$ref^{tree}" 2>/dev/null)" || return 1
  merged="$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null)" || return 1
  [ -n "$base_tree" ] && [ "${merged%%$'\n'*}" = "$base_tree" ]
}

# A merged pull request whose head is THIS commit, into the base branch, whose merge
# commit is still on the base just fetched.
#
# Asked by commit, not branch name: names get reused, and a branch listing needs a limit
# that makes it a subset. The head SHA is compared again because the commit's PR list
# includes a PR whose head later moved past it. The merge commit is checked against the
# fetched base because a merged PR is history and a force-push can undo it. The repository
# is named from `remote.origin.url` - the configured URL, not the `insteadOf` rewrite -
# rather than left to gh, which would honour $GH_REPO and let another repository's merged
# PR authorise this removal.
_cc_wj_landed_by_pr() {
  local wt="$1" ref="$2" head="${3:-}" url host slug rest merges mc
  command -v gh >/dev/null 2>&1 || return 1
  [ -n "$head" ] || head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
  url="$(git -C "$wt" config --get remote.origin.url 2>/dev/null)" || return 1
  url="${url%.git}"
  # URL form before SCP form: an https URL contains both a colon and slashes.
  case "$url" in
    *://*)
      rest="${url#*://}"; rest="${rest#*@}"
      host="${rest%%/*}"; host="${host%%:*}"
      slug="${rest#*/}" ;;
    *:*)
      host="${url%%:*}"; host="${host##*@}"
      slug="${url#*:}" ;;
    *) return 1 ;;
  esac
  case "$slug" in */*) ;; *) return 1 ;; esac
  [ -n "$host" ] || return 1
  local listed n numbers
  listed="$(_cc_wj_with_timeout 30 gh api --hostname "$host" "repos/$slug/commits/$head/pulls" \
     --paginate \
     --jq ".[] | select(.merged_at != null and .head.sha == \"$head\") | \"\\(.base.ref) \\(.merge_commit_sha)\"" \
     2>/dev/null)" || return 1
  merges="$(printf '%s\n' "$listed" | awk -v b="$_CC_WJ_BASE" '$1 == b { print $2 }')"
  # The commit's PR list names one pull request, not all of them: a head first merged into
  # a stacked branch lists only that PR, and the later one that took the same head to the
  # base, from another branch, is missing (stima-api #2506 into codex/2471-header-state,
  # then #2490 into main, kept 6.9 GB as unlanded on 2026-10-03). Search merged pull
  # requests by the SHA and read each one: the head, base and merge commit checks are the
  # same as above, so a search hit is only a candidate. Searched only when this head was
  # merged into some other branch, the stacked case's mark: search allows 30 calls a
  # minute per account, and most unlanded trees are simply unfinished.
  if [ -z "$merges" ] && [ -n "$listed" ]; then
    numbers="$(_cc_wj_with_timeout 30 gh api --hostname "$host" \
      "search/issues?q=repo:$slug+is:pr+is:merged+$head&per_page=20" --jq '.items[].number' 2>/dev/null)" || return 1
    while IFS= read -r n; do
      case "$n" in ''|*[!0-9]*) continue ;; esac
      mc="$(_cc_wj_with_timeout 30 gh api --hostname "$host" "repos/$slug/pulls/$n" \
        --jq "select(.merged_at != null and .base.ref == \"$_CC_WJ_BASE\" and .head.sha == \"$head\") | .merge_commit_sha" \
        2>/dev/null)" || return 1
      [ -z "$mc" ] || merges="$merges$mc"$'\n'
    done <<NUMBERS
$numbers
NUMBERS
  fi
  [ -n "$merges" ] || return 1
  while IFS= read -r mc; do
    [ -n "$mc" ] || continue
    git -C "$wt" merge-base --is-ancestor "$mc" "$ref" 2>/dev/null && return 0
  done <<MERGES
$merges
MERGES
  return 1
}

# Run jq filter $5 over the pull requests in state $4 whose head is worktree $1's branch or
# its upstream's branch, in repository $3 on host $2, printing the results. Fails when any
# query fails, so a partial answer never reads as a complete one; prints nothing for a
# detached HEAD.
_cc_wj_branch_prs() {
  local wt="$1" host="$2" slug="$3" state="$4" filter="$5" name up seen="" out
  name="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 0
  up="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || up=""
  up="${up#*/}"
  for name in "$name" "$up"; do
    [ -n "$name" ] || continue
    case " $seen " in *" $name "*) continue ;; esac
    seen="$seen $name"
    out="$(_cc_wj_with_timeout 30 gh api --hostname "$host" --paginate \
          "repos/$slug/pulls?head=${slug%%/*}:$name&state=$state&per_page=100" \
          --jq "$filter" 2>/dev/null)" || return 1
    [ -z "$out" ] || printf '%s\n' "$out"
  done
}

# Answer `yes` only when GitHub confirms a pull request was CLOSED unmerged at exactly this
# worktree's HEAD, at least CC_WJ_CLOSED_PR_DAYS (14) days ago, and that no pull request for
# the branch is open. Somebody decided against that work, the commits stay on the branch
# and in the pull request's ref, and only the checkout goes. 11 such worktrees held 9.8 GB
# on 2026-10-03. Every failure, a detached HEAD and a newer commit answer `no`.
_cc_wj_closed_at_head() {
  local wt="$1" head url rest host slug days="${CC_WJ_CLOSED_PR_DAYS:-14}" cutoff closed open
  # Whole days, 1 to 9999, read as decimal: `08` is not octal, and 0 would take a PR closed
  # this minute.
  case "$days" in ''|*[!0-9]*|?????*) echo no; return ;; esac
  days=$((10#$days))
  [ "$days" -ge 1 ] || { echo no; return; }
  command -v gh >/dev/null 2>&1 || { echo no; return; }
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || { echo no; return; }
  url="$(git -C "$wt" config --get remote.origin.url 2>/dev/null)" || { echo no; return; }
  url="${url%.git}"
  case "$url" in
    *://*)
      rest="${url#*://}"; rest="${rest#*@}"
      host="${rest%%/*}"; host="${host%%:*}"
      slug="${rest#*/}" ;;
    *:*)
      host="${url%%:*}"; host="${host##*@}"
      slug="${url#*:}" ;;
    *) echo no; return ;;
  esac
  case "$slug" in */*) ;; *) echo no; return ;; esac
  [ -n "$host" ] || { echo no; return; }
  cutoff="$(( $(date +%s) - days * 86400 ))"
  open="$(_cc_wj_branch_prs "$wt" "$host" "$slug" open '.[] | .number')" || { echo no; return; }
  [ -z "$open" ] || { echo no; return; }
  closed="$(_cc_wj_branch_prs "$wt" "$host" "$slug" closed \
    ".[] | select(.merged_at == null and .head.sha == \"$head\" and (.closed_at | fromdateiso8601) <= $cutoff) | .number")" ||
    { echo no; return; }
  [ -n "$closed" ] && echo yes || echo no
}

# Answer `yes` only when GitHub CONFIRMS that this branch has never had a pull request,
# `no` for anything else including every failure. The whole value of this probe is its
# zero, so it must never be able to produce one by examining nothing: an absent `gh`, an
# unparseable remote, a detached HEAD, a network error and a non-zero exit all answer `no`.
#
# `gh pr list --state all` is the population that matters. `landed=pr` already asks whether
# a MERGED pull request delivered this head; the question here is the opposite and wider --
# whether one was ever opened at all, merged, closed or still open. A branch with a closed
# pull request is a decision somebody made and is not abandoned; a branch with none is work
# that never reached anyone.
# A branch whose own pushed head moved past it, and that pushed head merged: every local
# commit is in what landed. A squash merge keys on the PR's final head, so a checkout that
# stopped one push short never matched it; on 2026-10-05 two such stima-api trees, 1.1 GB,
# sat as unlanded with their PRs merged. Asked only when the local HEAD is a strict
# ancestor of refs/remotes/origin/<branch>, so a tree ahead or diverged is never judged.
_cc_wj_behind_merged() {
  local wt="$1" ref="$2" br head up
  br="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1
  up="$(git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$br^{commit}" 2>/dev/null)" || return 1
  [ "$up" != "$head" ] || return 1
  git -C "$wt" merge-base --is-ancestor "$head" "$up" 2>/dev/null || return 1
  _cc_wj_landed_by_pr "$wt" "$ref" "$up"
}

# yes when a branch, tag or remote-tracking ref contains this worktree's HEAD, so removing
# the checkout leaves every commit referenced; no otherwise, and no on any failure. On
# 2026-10-05 four detached stima-api trees idle 7+ days, 4.6 GB, were all contained in
# origin branches and three also in local ones, yet a detached HEAD could never be removed
# unless it sat on the base.
_cc_wj_referenced() {
  local wt="$1" head out
  head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" || { echo no; return; }
  out="$(git -C "$wt" for-each-ref --count=1 --contains "$head" --format='%(refname)' \
        refs/heads refs/tags refs/remotes 2>/dev/null)" || { echo no; return; }
  [ -n "$out" ] && echo yes || echo no
}

_cc_wj_never_had_pr() {
  local wt="$1" branch url rest host slug out
  command -v gh >/dev/null 2>&1 || { echo no; return; }
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || { echo no; return; }
  [ -n "$branch" ] || { echo no; return; }
  url="$(git -C "$wt" config --get remote.origin.url 2>/dev/null)" || { echo no; return; }
  url="${url%.git}"
  case "$url" in
    *://*)
      rest="${url#*://}"; rest="${rest#*@}"
      host="${rest%%/*}"; host="${host%%:*}"
      slug="${rest#*/}" ;;
    *:*)
      host="${url%%:*}"; host="${host##*@}"
      slug="${url#*:}" ;;
    *) echo no; return ;;
  esac
  case "$slug" in */*) ;; *) echo no; return ;; esac
  [ -n "$host" ] || { echo no; return ; }
  # `--json number` so the answer is a JSON array and an empty one is `[]`, never the empty
  # string a failed command also produces. The command substitution's own exit status is
  # checked first, so a timeout or an API error cannot reach the emptiness test.
  out="$(_cc_wj_with_timeout 30 gh api --hostname "$host" \
        "repos/$slug/pulls?head=${slug%%/*}:$branch&state=all&per_page=1" \
        --jq 'length' 2>/dev/null)" || { echo no; return; }
  case "$out" in
    0) echo yes ;;
    *) echo no ;;
  esac
}

# ─── What git itself protects ─────────────────────────────────────────────────

# Print `locked` or `submodule` when git's own state says to keep worktree $1, nothing
# otherwise.
#
# A lock is an explicit request: `git worktree lock`, and Claude Code locks every agent
# worktree it creates. Measured 2026-09-14 on a real repository: one such worktree,
# landed, clean and idle, was otherwise classified REMOVABLE. A populated submodule - a
# `modules` directory in the worktree's git directory, or a gitlink whose path holds a
# checkout - carries state the outer status does not show, and removal refuses it without
# force.
_cc_wj_git_keep() {
  local wt="$1" gitdir rec sf
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo unknown; return 0; }
  if [ -e "$gitdir/locked" ]; then
    echo locked
    return 0
  fi
  if [ -d "$gitdir/modules" ]; then
    echo submodule
    return 0
  fi
  # An operation in progress lives only in the worktree's git dir: a rebase's todo list, a
  # bisect's log, a merge or pick waiting on a commit. Removal would drop it, and a detached
  # HEAD mid-rebase can otherwise pass every other gate.
  for rec in rebase-merge rebase-apply BISECT_LOG MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [ -e "$gitdir/$rec" ]; then
      echo in-progress
      return 0
    fi
  done
  # Into a file, so an index that cannot be listed is told apart from one with no gitlinks.
  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-stage.XXXXXX")" || { echo unknown; return 0; }
  if ! git -C "$wt" ls-files --stage -z > "$sf" 2>/dev/null; then
    rm -f "$sf"
    echo unknown
    return 0
  fi
  while IFS= read -r -d '' rec; do
    case "$rec" in
      160000\ *) [ -e "$wt/${rec#*$'\t'}/.git" ] && { rm -f "$sf"; echo submodule; return 0; } ;;
    esac
  done < "$sf"
  rm -f "$sf"
  return 0
}

# ─── An accepted task ─────────────────────────────────────────────────────────

# yes when worktree $1 carries its dev loop's acceptance of the commit it has checked out,
# no otherwise. The loop writes `claude-task-done` beside the `claude-task-worktree` marker,
# in the worktree's own git dir, once the task is accepted and live. Of its key=value lines
# only `head=` is read.
#
# It stands in for the two gates that exist only because nobody said the work was finished,
# the recent-session lease and the idle window, so it has to be about this checkout: exactly
# one well-formed `head=`, naming the current HEAD, on a branch. An annotation left from an
# earlier commit says nothing about the work in the tree now, and the task's branch is what
# keeps its commits once the checkout goes. Anything else is no, and the worktree is judged
# as if there were no file. The caller asks it only of a clean worktree.
_cc_wj_done() {
  local wt="$1" gd f head
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo no; return 0; }
  f="$gd/claude-task-done"
  if [ -f "$f" ] && [ "$(LC_ALL=C grep -c '^head=' "$f" 2>/dev/null)" = 1 ] &&
     head="$(LC_ALL=C grep -xE 'head=[0-9a-f]{40}' "$f" 2>/dev/null)" &&
     [ "${head#head=}" = "$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" ] &&
     git -C "$wt" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

# `_cc_wj_active_claim`, with its lease answer waived when $1 is yes. That 3 is a Codex task
# that archived while its claim was read, and it comes back as soon as that one task is
# reconciled - before the live transcripts listed after it have been read. The reconcile
# dropped the task from the live list, so asking again reads only the rest, and the answer
# that ends the loop is a live claim (0), one that cannot be read (2) or none (1). Waiving a
# lease never waives a live claim.
_cc_wj_live_claim() { # <waive: yes|no> <worktree> [all|cwd|tool]
  local waive="$1" rc
  shift
  while :; do
    _cc_wj_active_claim "$@"; rc=$?
    [ "$rc" -eq 3 ] && [ "$waive" = yes ] || return "$rc"
  done
}

# ─── Pushed work ──────────────────────────────────────────────────────────────

# 1 when pushed work may be reclaimed (CC_WJ_RECLAIM_PUSHED, default on), 0 otherwise.
_cc_wj_reclaim_pushed() { if [ "${CC_WJ_RECLAIM_PUSHED:-1}" = 1 ]; then echo 1; else echo 0; fi; }

# Ask origin, now, for its branch tips and keep those whose commit this clone has, one
# per line, in file $2. A remote-tracking ref is only as fresh as the last fetch and the
# run fetches only the base, so "pushed" is judged against this listing instead.
# Fails, leaving the file empty, when origin cannot be asked: nothing is then pushed.
_CC_WJ_TIPS_OK=0
_cc_wj_prepare_tips() { # <repo> <file>
  local repo="$1" out="$2" t
  _CC_WJ_TIPS_OK=0
  : > "$out"
  t="$(_cc_wj_fetch_timeout_seconds)" || return 1
  _cc_wj_with_timeout "$t" git -C "$repo" ls-remote origin 'refs/heads/*' 2>/dev/null |
    awk '{ print $1 }' |
    git -C "$repo" cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null |
    awk '$2 == "commit" { print $1 }' > "$out.tmp" || return 1
  # An empty answer is a failed ask, not a remote with no branches.
  [ -s "$out.tmp" ] || { rm -f "$out.tmp"; return 1; }
  mv -f "$out.tmp" "$out" && _CC_WJ_TIPS_OK=1
}

# yes when HEAD of worktree $1 is contained in a branch tip listed in file $2.
_cc_wj_pushed() { # <worktree> <tips file>
  local unpushed
  [ "$_CC_WJ_TIPS_OK" -eq 1 ] || { echo no; return; }
  # Commits of HEAD that no tip reaches; none at all means HEAD is on origin.
  unpushed="$({ echo HEAD; echo --not; cat "$2"; } | git -C "$1" rev-list -n 1 --stdin 2>/dev/null)" ||
    { echo no; return; }
  if [ -z "$unpushed" ]; then echo yes; else echo no; fi
}

# Succeeds when the only things worktree $1 would lose are tracked edits and untracked
# files that are not ignored - what a WIP snapshot carries. An ignored file that is not
# regenerable (`!!`), or a status that could not be read, is not in the snapshot.
# $2 as for `_cc_wj_pins`.
_cc_wj_wip_ok() { # <worktree> [archive list file]
  local out
  out="$(_cc_wj_pins "$1" "${2:-}")" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | grep -q '^!! ' && return 1
  return 0
}

# Print the tree id of everything worktree $1 holds that a snapshot can keep: HEAD plus
# tracked edits plus untracked non-ignored files, built in a private index so the worktree
# and its real index are untouched. Fails on an unreadable file or on a nested repository
# (a gitlink would record only a commit id, not the files).
_cc_wj_wip_tree() { # <worktree>
  local wt="$1" idx tree head
  head="$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  idx="$(mktemp -u "${TMPDIR:-/tmp}/cc-wj-wip.XXXXXX")"
  tree="$(export GIT_INDEX_FILE="$idx"
          git --no-optional-locks -c core.fsmonitor=false -C "$wt" read-tree "$head" 2>/dev/null &&
          git --no-optional-locks -c core.fsmonitor=false -C "$wt" add -A >/dev/null 2>&1 &&
          git --no-optional-locks -c core.fsmonitor=false -C "$wt" write-tree 2>/dev/null)"
  rm -f "$idx"
  [ -n "$tree" ] || return 1
  git -C "$wt" diff-tree -r "$head" "$tree" 2>/dev/null | awk '$2 == "160000" { bad = 1 } END { exit bad }' ||
    return 1
  printf '%s\n' "$tree"
}

# Send a snapshot of worktree $2 (repo $1) to $3 on origin and prove it arrived: origin
# must list that ref at the commit made here, and the worktree must still hold exactly the
# tree that was sent. Anything less returns 1 and the worktree stays.
_cc_wj_wip_send() { # <repo> <worktree> <ref>
  local repo="$1" wt="$2" ref="$3" head tree commit t again
  t="$(_cc_wj_fetch_timeout_seconds)" || return 1
  git check-ref-format "$ref" 2>/dev/null || return 1
  head="$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  tree="$(_cc_wj_wip_tree "$wt")" || return 1
  commit="$(GIT_AUTHOR_NAME=cc-reaper GIT_COMMITTER_NAME=cc-reaper \
            GIT_AUTHOR_EMAIL=cc-reaper@localhost GIT_COMMITTER_EMAIL=cc-reaper@localhost \
            git -C "$wt" commit-tree "$tree" -p "$head" -m "wip: $(basename "$wt") before reclaim" 2>/dev/null)" || return 1
  GIT_TERMINAL_PROMPT=0 _cc_wj_with_timeout "$t" git -C "$repo" push -q --no-progress origin "$commit:$ref" >/dev/null 2>&1 || return 1
  [ "$(_cc_wj_with_timeout "$t" git -C "$repo" ls-remote origin "$ref" 2>/dev/null | awk '{ print $1 }')" = "$commit" ] ||
    return 1
  again="$(_cc_wj_wip_tree "$wt")" || return 1
  [ "$again" = "$tree" ] || return 1
  _CC_WJ_WIP_COMMIT="$commit"
}

# ─── Classification ───────────────────────────────────────────────────────────

# Print KEEP(<reason>) or REMOVABLE. Every gate that was not shown to hold keeps: an empty
# argument is a question nobody answered, never a yes.
_cc_wj_classify() {
  local wt_path="$1"
  local dirty="$2"    # integer or "MISSING"
  local active="$3"   # "yes" or "no"
  local lsof_ok="$4"  # "yes" or "no" — "no" means a holder scan failed
  local branch="${5:-}"  # branch name, or "(detached)"
  local landed="${6:-}"  # ancestor | content | pr | no | unfetched
  local idle="${7:-}"    # yes | no | unknown
  local recent="${8:-no}" # "yes" when a bounded harness-session lease applies
  local abandoned="${9:-no}" # "yes" only when GitHub confirmed no pull request ever existed,
                             # or one closed unmerged at this HEAD (`_cc_wj_closed_at_head`),
                             # or, for a detached HEAD, a ref contains it (`_cc_wj_referenced`)
  local referenced="${10:-no}" # "yes" when a branch, tag or remote ref contains the HEAD
  local pushed="${11:-no}"   # "yes" when origin lists a branch containing the HEAD
  local wip="${12:-no}"      # "yes" when its edits reach refs/wip on origin before removal

  if [ "$dirty" = "MISSING" ]; then
    echo "KEEP(missing-dir)"
    return
  fi

  if [ "$lsof_ok" != "yes" ]; then
    echo "KEEP(active-session)"
    return
  fi

  # Exactly `0`, not "not greater than zero": an empty or garbled count is what a failed
  # read looks like, and `[ "" -gt 0 ]` is false.
  if [ "$dirty" != "0" ]; then
    echo "KEEP(unrebuildable=$dirty)"
    return
  fi

  if [ "$active" != "no" ]; then
    echo "KEEP(active-session)"
    return
  fi

  if [ "$recent" != "no" ]; then
    echo "KEEP(recent-session)"
    return
  fi

  case "$landed" in
    ancestor|content|pr) ;;
    unfetched) echo "KEEP(base-unfetched)"; return ;;
    *)
      # Not landed has two meanings and only one of them is "not yet". A branch that never
      # opened a pull request has nothing on its way to the base, so waiting for it to land
      # waits forever -- which is what kept 27 GB standing on the reporting host. Removal
      # still takes only the checkout and leaves the branch, so the commits survive either
      # way; what changes is whether the disk does.
      [ "$abandoned" = "yes" ] || [ "$pushed" = "yes" ] || { echo "KEEP(unlanded)"; return ; }
      ;;
  esac

  case "$idle" in
    yes) ;;
    no) echo "KEEP(recent-activity)"; return ;;
    *) echo "KEEP(idle-unknown)"; return ;;
  esac

  # Removal takes the checkout and leaves the branch, so a branch's commits survive it.
  # A detached HEAD's survive only when something else references them: the base (landed by
  # ancestry), or a branch, tag or remote ref that contains the HEAD. Landed by content or
  # PR puts only their change on the base.
  if [ "$branch" = "(detached)" ] && [ "$landed" != "ancestor" ] && [ "$referenced" != "yes" ]; then
    echo "KEEP(detached-head)"
    return
  fi

  # Removal still takes only the checkout. These two are removable because origin holds
  # the commits (pushed) and, for edits, because a snapshot reaches refs/wip first.
  if [ "$wip" = "yes" ]; then
    echo "REMOVABLE(wip-pushed)"
    return
  fi
  case "$landed" in
    ancestor|content|pr) ;;
    *) [ "$abandoned" = "yes" ] || { echo "REMOVABLE(pushed)"; return; } ;;
  esac
  echo "REMOVABLE"
}

# ─── Notification ─────────────────────────────────────────────────────────────

_cc_wj_maybe_notify() {
  local total_bytes="$1"
  local state_dir
  state_dir=$(_cc_wj_state_dir)
  mkdir -p "$state_dir" 2>/dev/null || true

  local cooldown_file="$state_dir/cooldown-worktree"
  local cooldown_secs
  cooldown_secs=$(_cc_wj_cooldown_secs)

  # Check cooldown
  if [ -f "$cooldown_file" ]; then
    local mtime now elapsed
    mtime=$(stat -f %m "$cooldown_file" 2>/dev/null || stat -c %Y "$cooldown_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$((now - mtime))
    if [ "$elapsed" -lt "$cooldown_secs" ]; then
      return
    fi
  fi

  local min_bytes
  min_bytes=$(awk -v gb="$(_cc_wj_notify_min_gb)" 'BEGIN { printf "%.0f", gb * 1073741824 }')

  if [ "$total_bytes" -lt "$min_bytes" ] 2>/dev/null; then
    return
  fi

  local gb_str
  gb_str=$(awk -v b="$total_bytes" 'BEGIN { printf "%.1f", b / 1073741824 }')

  # Touch cooldown file before notify (prevent storm if osascript hangs)
  touch "$cooldown_file" 2>/dev/null || true

  local msg="${gb_str} GB of stale worktrees found. Run worktree-janitor --apply to reclaim space."
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  osascript -e "display notification \"${msg}\" with title \"cc-reaper: worktree-janitor\"" 2>/dev/null || true
}

_cc_wj_remove_private_temp() {
  local directory="${1:-}"
  [ -d "$directory" ] || return 0
  case "${directory##*/}" in
    cc-wj.??????) rm -rf -- "$directory" ;;
    *)
      echo "worktree-janitor: refused to remove unexpected temporary path: $directory" >&2
      return 1
      ;;
  esac
}

_cc_wj_scavenge_private_temp() {
  local root="${TMPDIR:-/tmp}" directory owner mtime now
  [ -d "$root" ] || return 0
  # zsh aborts on an unmatched glob by default.  An empty temp root is the normal
  # case, so keep the literal pattern and let the directory guard below skip it.
  # `local_options` contains the change to this function when the file is sourced.
  if [ -n "${ZSH_VERSION:-}" ]; then
    setopt local_options nonomatch
  fi
  now="$(date +%s)"
  for directory in "$root"/cc-wj.??????; do
    [ -d "$directory" ] || continue
    # Never cross users even if a shared temporary root contains a matching name.
    [ -O "$directory" ] || continue
    owner=""
    if IFS= read -r owner 2>/dev/null < "$directory/.owner-pid"; then
      case "$owner" in
        ''|*[!0-9]*) continue ;;
      esac
      # PID reuse only delays cleanup; it can never authorize removal of a live run.
      kill -0 "$owner" 2>/dev/null && continue
      _cc_wj_remove_private_temp "$directory"
      continue
    fi
    # There is an unavoidable interval between mktemp and writing the owner marker.
    # Retain unmarked directories for five minutes so a concurrent startup cannot
    # remove a live run. This also migrates privacy residue from older installations.
    mtime="$(_cc_wj_mtime_epoch "$directory")" || continue
    [ $((now - mtime)) -ge 300 ] || continue
    _cc_wj_remove_private_temp "$directory"
  done
}

_cc_wj_capture_run_pid() {
  local probe
  /bin/sleep 5 & probe=$!
  _CC_WJ_RUN_PID="$(ps -o ppid= -p "$probe" 2>/dev/null | awk '{ print $1; exit }')"
  kill "$probe" 2>/dev/null || true
  wait "$probe" 2>/dev/null || true
  case "${_CC_WJ_RUN_PID:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

_cc_wj_cleanup_and_reraise() {
  local signal="$1" status="$2"
  local caller_trap=""
  # Bash uses dynamic scope, so these are the interrupted _cc_wj_run_inner locals.
  _cc_wj_remove_private_temp "${work:-}"
  case "$signal" in
    INT) caller_trap="${old_int:-}" ;;
    TERM) caller_trap="${old_term:-}" ;;
    HUP) caller_trap="${old_hup:-}" ;;
  esac
  trap - INT TERM HUP
  # Running a restored signal trap nested inside this handler makes Bash skip EXIT
  # when that caller trap exits. Run the caller's quoted trap action in a subshell
  # with EXIT disabled, then exit this shell normally so its original EXIT trap runs
  # exactly once. No interrupted janitor body resumes between cleanup and exit.
  if [ -n "$caller_trap" ]; then
    (
      trap - EXIT
      eval "set -- $caller_trap"
      [ "${1:-}" = trap ] && [ "${2:-}" = -- ] && eval "${3:-}"
    )
  fi
  exit "$status"
}

# ─── Removal ──────────────────────────────────────────────────────────────────

# Remove a single worktree, never with force. Ignored residue does not stop a plain
# removal; what does - an untracked file, a lock, a submodule appearing in the moment
# before - is exactly what force would destroy, and a status check that failed used to read
# as "nothing there" and authorise it.
# Pin a detached HEAD that is not on the base under refs/cc-reaper/detached/<sha> before its
# checkout goes, so a branch, tag or remote ref that contained it - a remote one can be
# pruned or force-pushed away at any time - is not what keeps its commits. Fails, and the
# caller keeps the worktree, when the ref cannot be written.
_cc_wj_pin_detached() {
  local wt="$1" head="$2"
  case "$head" in *[!0-9a-f]*|'') return 1 ;; esac
  git -C "$wt" update-ref "refs/cc-reaper/detached/$head" "$head" 2>/dev/null || return 1
  _cc_wj_log_write "pinned detached HEAD $head as refs/cc-reaper/detached/$head: $wt"
}

_cc_wj_remove_worktree() {
  local repo="$1"
  local wt_path="$2"
  local force="${3:-}"   # --force only for a worktree whose edits are verified on origin

  _cc_wj_log_write "removing worktree: $wt_path (repo: $repo)"

  if git -C "$repo" worktree remove ${force:+"$force"} "$wt_path" 2>/dev/null; then
    _cc_wj_log_write "removed: $wt_path"
    return 0
  fi

  _cc_wj_log_write "FAILED to remove (git refused): $wt_path"
  return 1
}

# Copy the files listed in $3 - worktree-relative, one per line - out of worktree $2 of
# repository $1 into a directory made for this removal, and compare every copy with its
# source. Sets _CC_WJ_ARCHIVE_DEST. Any failure answers 1 and the worktree stays: the copy
# is all that stands between those files and the removal. Nothing in the archive is ever
# deleted here, a partial copy included.
_cc_wj_archive_files() {
  local repo wt="$2" list="$3" root dest f
  # Resolved, so `--repo ..` or `--repo .` names the repository, not a path outside the root.
  repo="$(cd "$1" 2>/dev/null && pwd -P)"; repo="${repo##*/}"
  root="${CC_WJ_ARCHIVE_DIR:-$HOME/.cc-reaper/archive}"
  _CC_WJ_ARCHIVE_DEST="$root/${repo:-repository}"
  mkdir -p "$_CC_WJ_ARCHIVE_DEST" 2>/dev/null || return 1
  # mktemp, because two worktrees of one repository can share a name and a second.
  dest="$(mktemp -d "$_CC_WJ_ARCHIVE_DEST/${wt##*/}-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX" 2>/dev/null)" ||
    return 1
  _CC_WJ_ARCHIVE_DEST="$dest"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$(dirname "$dest/$f")" 2>/dev/null &&
      cp -p "$wt/$f" "$dest/$f" 2>/dev/null &&
      cmp -s "$wt/$f" "$dest/$f" || return 1
  done < "$list"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" \
    "$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')" \
    "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" "$dest" >> "$root/index.tsv" 2>/dev/null
}

# ─── Sweep lock ───────────────────────────────────────────────────────────────

# One removal sweep per repository. Every session end can start a sweep that outlives
# it, and a manual `--apply` can start another; two sweeps deciding about the same
# worktree race each other into git's own locks. The lock lives in the repository's
# common git directory, so every clone path to the same repository shares it.
#
# A holder counts only while its pid is alive and still this script - a pid the kernel
# has handed to something else is not a sweep - and not for more than an hour, because
# nothing a sweep does takes that long - it refreshes the lock on every removal - and
# deferring to a hung one would mean the repository is never swept again.
#
# ponytail: taking over a dead holder's lock is check-then-act, so two sweeps that find
# the same dead holder in the same instant can both proceed. git's own locks bound what
# that costs - one of two concurrent removals fails and is reported - so the lock is a
# de-duplication of work, not the thing standing between a worktree and its deletion.
_cc_wj_lock_write() {
  echo "${_CC_WJ_RUN_PID:-$$}" > "$1/pid"
  ps -o command= -p "${_CC_WJ_RUN_PID:-$$}" > "$1/cmd" 2>/dev/null
}

_cc_wj_lock() {
  local lock="$1" holder recorded live=0
  if mkdir "$lock" 2>/dev/null; then
    _cc_wj_lock_write "$lock"
    return 0
  fi
  holder="$(cat "$lock/pid" 2>/dev/null)"
  recorded="$(cat "$lock/cmd" 2>/dev/null)"
  # Alive and still running the command recorded when it took the lock. Matching on a name
  # instead took over a sweep started through a symlink, and kept a pid the kernel had
  # handed to anything whose command line happened to contain it.
  if [ -n "$holder" ] && [ -n "$recorded" ] &&
     [ "$(ps -o command= -p "$holder" 2>/dev/null)" = "$recorded" ]; then
    live=1
  elif [ -d "$lock" ] && { [ -z "$holder" ] || [ -z "$recorded" ]; } &&
       [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    # A sweep between its mkdir and its writes. Only a directory can be that: when mkdir
    # failed and nothing is there - an unwritable or missing parent - `find` prints nothing
    # either, and this branch used to read that as a holder and defer.
    live=1
  fi
  if [ "$live" -eq 1 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    echo "worktree-janitor: pid ${holder:-?} has held $lock for over 60 minutes; taking it over"
    live=0
  fi
  # 2, not 1: a live holder is another removal or trim sweep of this repository, so this run
  # leaves the repository to it and to the next sweep rather than failing. Counting the
  # deferral as a failure put 14 false `status=1` lines in one day's session log (2026-09-23).
  if [ "$live" -eq 1 ]; then
    echo "worktree-janitor: another worktree-janitor sweep${holder:+ (pid $holder)} holds $lock; deferred to it and removed nothing in this repository"
    return 2
  fi
  rm -f "$lock/pid" "$lock/cmd" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    echo "worktree-janitor: the sweep lock $lock could not be taken; removed nothing in this repository"
    return 1
  fi
  _cc_wj_lock_write "$lock"
}

# Best effort: a cursor that cannot be written costs only where the next sweep starts.
_cc_wj_cursor_write() { # <cursor file> <worktree>
  [ -n "$1" ] || return 0
  mkdir -p "$(dirname "$1")" 2>/dev/null
  printf '%s\n' "$2" > "$1.tmp.${_CC_WJ_RUN_PID:-$$}" 2>/dev/null &&
    mv -f "$1.tmp.${_CC_WJ_RUN_PID:-$$}" "$1" 2>/dev/null ||
    rm -f "$1.tmp.${_CC_WJ_RUN_PID:-$$}" 2>/dev/null
  return 0
}

# ─── Largest first (stima-api#5886) ──────────────────────────────────────────
#
# A sweep the budget cuts short should have spent it where the bytes are, so with
# CC_WJ_ORDER=largest (the default) each repository's worktrees are examined by their last
# known size, largest first. Nothing is measured for the ordering: a full `du` of the
# worktree roots took over ten minutes under load. The sizes are the ones already taken:
#   - growth-watch's samples (disk-janitor --check, every few hours, budgeted), keyed
#     `<label>/<name>` under a glob row of its targets file, mapped back to the path here;
#   - this janitor's own `du` of a worktree (a report's estimate, a spot-check, a removal),
#     kept in $(_cc_wj_state_dir)/worktree-sizes.tsv as path<TAB>bytes<TAB>measured_at.
# The newest measurement of a path wins. The order only decides which worktree is asked
# first: every one is still judged by every gate, wherever it sits. CC_WJ_ORDER=path is the
# old path order and cursor, and reads and writes no size.
_cc_wj_order() {
  case "${CC_WJ_ORDER:-largest}" in
    largest|path) printf '%s\n' "${CC_WJ_ORDER:-largest}" ;;
    *) return 1 ;;
  esac
}

_cc_wj_size_cache() { printf '%s\n' "$(_cc_wj_state_dir)/worktree-sizes.tsv"; }

_cc_wj_tilde() { case "$1" in '~') printf '%s\n' "$HOME" ;; '~/'*) printf '%s\n' "$HOME/${1#\~/}" ;; *) printf '%s\n' "$1" ;; esac; }

# Best effort, like the cursor: a size that cannot be written only costs the order. Rows not
# measured for 30 days go, so trees removed some other way do not accumulate. `-` forgets the
# path (it was removed). Two sweeps of different repositories may race here; the loser's row
# is lost, which again only costs the order.
_cc_wj_size_record() { # <path> <bytes | ->
  [ "$_CC_WJ_ORDER" = largest ] || return 0
  case "$2" in -) ;; ''|*[!0-9]*) return 0 ;; esac
  local file tmp now
  file="$(_cc_wj_size_cache)"; tmp="$file.tmp.${_CC_WJ_RUN_PID:-$$}"; now="$(date +%s)"
  mkdir -p "$(dirname "$file")" 2>/dev/null
  {
    cat "$file" 2>/dev/null | CC_WJ_P="$1" LC_ALL=C awk -F'\t' -v cutoff=$((now - 2592000)) \
      'NF == 3 && $1 != ENVIRON["CC_WJ_P"] && $2 ~ /^[0-9]+$/ && $3 + 0 >= cutoff'
    [ "$2" = - ] || printf '%s\t%s\t%s\n' "$1" "$2" "$now"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# The newest known size of each path, as path<TAB>bytes, into $1. Read once per run.
_cc_wj_size_map() { # <out>
  local targets samples
  targets="$(_cc_wj_tilde "${CC_WJ_GROWTH_TARGETS:-${CC_DJ_GROWTH_TARGETS:-$HOME/.cc-reaper/growth-targets.tsv}}")"
  samples="$(_cc_wj_tilde "${CC_WJ_GROWTH_SAMPLES:-${CC_DJ_STATE_DIR:-$HOME/.cc-reaper/state}/growth-samples.tsv}")"
  # Copied first: an unreadable file is then an empty one, never an awk error.
  cat "$targets" > "$1.targets" 2>/dev/null || : > "$1.targets"
  cat "$samples" > "$1.samples" 2>/dev/null || : > "$1.samples"
  cat "$(_cc_wj_size_cache)" > "$1.cache" 2>/dev/null || : > "$1.cache"
  LC_ALL=C awk -F'\t' -v home="$HOME" -v uid="$(id -u)" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function note(p, epoch, bytes) { if (!(p in at) || epoch + 0 >= at[p] + 0) { at[p] = epoch; size[p] = bytes } }
    FILENAME == ARGV[1] {
      # growth-watch keys a glob row `label<TAB>path` as label/<path relative to the
      # directory before the first wildcard>, with ~ and {uid} expanded.
      if ($0 ~ /^[ \t]*#/ || NF < 3) next
      label = trim($1); path = trim($2)
      if (label == "" || path ~ /^docker:/) next
      gsub(/\{uid\}/, uid, path)
      if (path == "~") path = home; else if (substr(path, 1, 2) == "~/") path = home substr(path, 2)
      cut = 0
      for (i = 1; i <= length(path); i++) { c = substr(path, i, 1); if (c == "*" || c == "?" || c == "[") { cut = i; break } }
      if (!cut) next
      prefix = substr(path, 1, cut - 1); sub(/\/[^\/]*$/, "", prefix)
      dir[label] = prefix
      next
    }
    FILENAME == ARGV[2] {
      # <epoch><TAB><key><TAB><KiB or a status>
      if ($3 !~ /^[0-9]+$/ || (slash = index($2, "/")) == 0) next
      label = substr($2, 1, slash - 1)
      if (label in dir) note(dir[label] "/" substr($2, slash + 1), $1, $3 * 1024)
      next
    }
    NF == 3 && $2 ~ /^[0-9]+$/ { note($1, $3, $2) }
    END { for (p in at) printf "%s\t%.0f\n", p, size[p] }' "$1.targets" "$1.samples" "$1.cache" > "$1" 2>/dev/null ||
    : > "$1"
  rm -f "$1.targets" "$1.samples" "$1.cache"
  return 0
}

# The inventory in examination order: worktrees not yet examined in this cycle before those
# already examined, each part by known size, largest first, then those with no known size in
# path order. Unknown sizes go last because a tree no measurement has reached yet is almost
# always a new one, still in use and kept; the cycle reaches it all the same.
_cc_wj_order_largest() { # <inventory> <sizes> <seen>
  local tab
  tab="$(printf '\t')"
  LC_ALL=C sort -t "$tab" -k1,1 "$1" |
    LC_ALL=C awk -F'\t' '
      FILENAME == ARGV[1] { size[$1] = $2; next }
      FILENAME == ARGV[2] { seen[$1] = 1; next }
      { n++; known = ($1 in size)
        printf "%d\t%d\t%.0f\t%d\t%s\n", ($1 in seen), !known, known ? size[$1] : 0, n, $0 }' "$2" "$3" - |
    LC_ALL=C sort -t "$tab" -k1,1n -k2,2n -k3,3nr -k4,4n | cut -f5-
}

# Released only while it is still ours: after a takeover it belongs to somebody else.
_cc_wj_unlock() {
  [ "$(cat "$1/pid" 2>/dev/null)" = "${_CC_WJ_RUN_PID:-$$}" ] && rm -f "$1/pid" "$1/cmd" && rmdir "$1" 2>/dev/null
  return 0
}

# ─── Main report/apply logic ─────────────────────────────────────────────────

_cc_wj_run_inner() {
  # Recover private projections even when this invocation later exits through help,
  # --claims, invalid config, or empty discovery. Bash 3.2 leaves $$ pointing at the
  # parent for a sourced background function, so derive the OS pid from a short-lived
  # child before owner markers or repository locks are written.
  _cc_wj_scavenge_private_temp
  if ! _cc_wj_capture_run_pid; then
    echo "worktree-janitor: could not determine the executing process id; scanned and removed nothing" >&2
    return 1
  fi
  # The scheduled agent's stdout/stderr pair is written by launchd, so no script owns it
  # unless one claims it. Bounded here, at the top of every run, rather than from
  # `_cc_wj_log_write`: a report-only run never calls that helper - every call site is in
  # removal, pruning, or the apply-only summary - so bounding from there was unreachable
  # for the unattended caller that produces these files every six hours.
  local agent_log
  for agent_log in "$HOME/.cc-reaper/logs/launchd-worktree-janitor-stdout.log" \
                   "$HOME/.cc-reaper/logs/launchd-worktree-janitor-stderr.log"; do
    _cc_wj_bound_log "$agent_log"
  done

  local apply=0 trim=0 scheduled=0 claims_only=0 claims_filter=""
  local explicit_repos=()
  [ -n "${_CC_WJ_RUN_ID:-}" ] || _CC_WJ_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)
        apply=1
        shift
        ;;
      --trim-regenerable)
        trim=1
        shift
        ;;
      --repo)
        shift
        if [ -z "${1:-}" ]; then
          echo "worktree-janitor: --repo requires a path" >&2
          return 1
        fi
        explicit_repos+=("$1")
        shift
        ;;
      --landed)
        shift
        if [ -z "${1:-}" ]; then
          echo "worktree-janitor: --landed requires a worktree path" >&2
          return 1
        fi
        _cc_wj_query_landed "$1"
        return $?
        ;;
      --claims)
        claims_only=1
        shift
        if [ -n "${1:-}" ]; then
          case "$1" in -*) ;; *) claims_filter="$1"; shift ;; esac
        fi
        ;;
      --session)
        _cc_wj_session
        return $?
        ;;
      --scheduled)
        scheduled=1
        shift
        ;;
      -h|--help)
        _cc_wj_usage
        return 0
        ;;
      *)
        echo "worktree-janitor: unknown option: $1" >&2
        _cc_wj_usage >&2
        return 1
        ;;
    esac
  done

  if [ "$scheduled" -eq 1 ]; then
    case "${CC_WJ_SCHEDULE_APPLY-}" in
      1) apply=1 ;;
      '') ;;
      *) echo "worktree-janitor: CC_WJ_SCHEDULE_APPLY=${CC_WJ_SCHEDULE_APPLY} is not 1; reporting only" ;;
    esac
    if [ "${CC_WJ_TRANSCRIPT_INDEX_DIR+x}" != x ]; then
      CC_WJ_TRANSCRIPT_INDEX_DIR="${CC_WJ_STATE_DIR:-$HOME/.cc-reaper/state}/transcript-index"
    fi
  fi

  if [ -n "$_CC_WJ_CONFIG_ERROR" ]; then
    echo "worktree-janitor: $_CC_WJ_CONFIG_ERROR; scanned and removed nothing" >&2
    return 2
  fi

  local idle_hours session_grace_hours abandon_hours status_timeout fetch_timeout sweep_budget phase_start knob
  phase_start="$(date +%s)"
  if ! idle_hours="$(_cc_wj_idle_hours)"; then
    echo "worktree-janitor: CC_WJ_IDLE_HOURS=${CC_WJ_IDLE_HOURS:-} is not a whole number of hours below 100000; scanned and removed nothing" >&2
    return 2
  fi
  if ! session_grace_hours="$(_cc_wj_session_grace_hours)"; then
    echo "worktree-janitor: CC_WJ_SESSION_GRACE_HOURS=${CC_WJ_SESSION_GRACE_HOURS:-} is not a whole number of hours below 100000; scanned and removed nothing" >&2
    return 2
  fi
  if ! abandon_hours="$(_cc_wj_abandon_hours)"; then
    echo "worktree-janitor: CC_WJ_ABANDON_HOURS=${CC_WJ_ABANDON_HOURS:-} is not a whole number of hours below 100000; scanned and removed nothing" >&2
    return 2
  fi
  if ! status_timeout="$(_cc_wj_git_status_timeout_seconds)"; then
    echo "worktree-janitor: CC_WJ_GIT_STATUS_TIMEOUT_SECONDS=${CC_WJ_GIT_STATUS_TIMEOUT_SECONDS:-} is not a positive whole number below 100000; scanned and removed nothing" >&2
    return 2
  fi
  if ! fetch_timeout="$(_cc_wj_fetch_timeout_seconds)"; then
    echo "worktree-janitor: CC_WJ_FETCH_TIMEOUT_SECONDS=${CC_WJ_FETCH_TIMEOUT_SECONDS:-} is not a positive whole number below 100000; scanned and removed nothing" >&2
    return 2
  fi
  if ! sweep_budget="$(_cc_wj_sweep_budget_seconds)"; then
    echo "worktree-janitor: CC_WJ_SWEEP_BUDGET_SECONDS=${CC_WJ_SWEEP_BUDGET_SECONDS:-} is not a whole number below 100000; scanned and removed nothing" >&2
    return 2
  fi
  for knob in recheck_fresh lsof_timeout lock_scan_timeout; do
    if ! "_cc_wj_${knob}_seconds" >/dev/null; then
      echo "worktree-janitor: CC_WJ_$(printf '%s' "$knob" | tr '[:lower:]' '[:upper:]')_SECONDS is not a valid whole number of seconds below 100000; scanned and removed nothing" >&2
      return 2
    fi
  done
  if ! _CC_WJ_ORDER="$(_cc_wj_order)"; then
    _CC_WJ_ORDER=""
    echo "worktree-janitor: CC_WJ_ORDER=${CC_WJ_ORDER:-} is neither largest nor path; scanned and removed nothing" >&2
    return 2
  fi

  if [ "$claims_only" -eq 1 ]; then
    # A record that could not be read leaves the claims incomplete whatever the scope.
    if ! _cc_wj_scan_active_sessions "$session_grace_hours" || [ -n "$_CC_WJ_UNKNOWN" ]; then
      echo "worktree-janitor: $_CC_WJ_ACTIVE_ERROR; claims are incomplete" >&2
      return 2
    fi
    _cc_wj_print_claims "$session_grace_hours" "$claims_filter"
    return $?
  fi

  # Under disk pressure a finished tree waits CC_WJ_PRESSURE_IDLE_HOURS and
  # CC_WJ_PRESSURE_SESSION_GRACE_HOURS (default 2 each) instead, never longer than configured.
  local pressure p_idle p_grace trim_idle_window=""
  if pressure="$(_cc_wj_disk_pressure)"; then
    p_idle="${CC_WJ_PRESSURE_IDLE_HOURS:-2}"; p_grace="${CC_WJ_PRESSURE_SESSION_GRACE_HOURS:-2}"
    case "$p_idle" in ''|*[!0-9]*|??????*)
      echo "worktree-janitor: CC_WJ_PRESSURE_IDLE_HOURS=$p_idle is not a whole number of hours below 100000; scanned and removed nothing" >&2
      return 2 ;;
    esac
    case "$p_grace" in ''|*[!0-9]*|??????*)
      echo "worktree-janitor: CC_WJ_PRESSURE_SESSION_GRACE_HOURS=$p_grace is not a whole number of hours below 100000; scanned and removed nothing" >&2
      return 2 ;;
    esac
    [ $((10#$p_idle)) -lt "$idle_hours" ] && idle_hours=$((10#$p_idle))
    [ $((10#$p_grace)) -lt "$session_grace_hours" ] && session_grace_hours=$((10#$p_grace))
    trim_idle_window="$idle_hours"
    echo "worktree-janitor: disk pressure ($pressure): idle window ${idle_hours}h, session lease ${session_grace_hours}h"
    _cc_wj_log_write "disk pressure ($pressure): idle window ${idle_hours}h, session lease ${session_grace_hours}h"
  fi

  # Asked once, before discovery, so the reason a scan came back empty is on the
  # record next to the emptiness rather than inferred from it.
  #
  # Only when discovery is what answers the question. With `--repo` the caller named
  # the repositories, the roots are never read, and failing the run over a default
  # root nobody asked about made every targeted run on a TCC host exit 1 - training
  # the operator to ignore the one signal this whole change is built on.
  local blind=0 blind_root
  if [ "${#explicit_repos[@]}" -eq 0 ]; then
  while IFS= read -r blind_root; do
    [ -n "$blind_root" ] || continue
    echo "worktree-janitor: root exists but cannot be read, scanned nothing: $blind_root" >&2
    echo "worktree-janitor:   under launchd, ~/Documents, ~/Desktop and ~/Downloads need a" >&2
    echo "worktree-janitor:   Full Disk Access grant on THIS binary: $(_cc_wj_grant_target)" >&2
    echo "worktree-janitor:   System Settings > Privacy & Security > Full Disk Access > + > Cmd-Shift-G." >&2
    echo "worktree-janitor:   Granting it to your terminal or editor does nothing: launchd spawns the" >&2
    echo "worktree-janitor:   binary above. Note this hands EVERY bash script on the machine access to" >&2
    echo "worktree-janitor:   all protected user data - keeping swept repositories outside those three" >&2
    echo "worktree-janitor:   directories avoids the grant entirely, and is what install.sh prefers." >&2
    blind=1
  done < <(_cc_wj_unreadable_roots)
  fi

  # Determine repo list
  local repos=()
  if [ "${#explicit_repos[@]}" -gt 0 ]; then
    repos=("${explicit_repos[@]}")
  else
    local repo_keys="" key
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      key="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      [ -n "$key" ] || continue
      case $'\n'"$repo_keys"$'\n' in *$'\n'"$key"$'\n'*) continue ;; esac
      repo_keys="${repo_keys}${repo_keys:+$'\n'}$key"
      repos+=("$r")
    done < <(_cc_wj_discover_repos)
  fi

  if [ "${#repos[@]}" -eq 0 ]; then
    echo "worktree-janitor: no repos found under $(_cc_wj_roots | paste -sd, -)" >&2
    # Blind is not idle, and the two used to print the same line and return the same
    # status. A scheduled run leaves nothing behind but that status.
    [ "$blind" -eq 1 ] && return 1
    return 0
  fi

  local total_removable=0
  local total_kept=0
  local total_removed=0
  local total_reclaimed=0
  local total_trim_candidates=0
  local total_trimmed=0
  local total_trim_reclaimed=0
  local prune_repos=()

  # Holder scans, taken once per run into files and taken again right before each removal.
  local work old_exit="" old_int="" old_term="" old_hup="" cleanup_exit_installed=0
  local LSOF_OK="yes" ACTIVE_OK="yes" LAUNCHD_OK="yes" ld_keep ld_label ld_path activity_blind=0
  work="$(mktemp -d "${TMPDIR:-/tmp}/cc-wj.XXXXXX")" || {
    echo "worktree-janitor: no temporary directory for the process scan; scanned and removed nothing" >&2
    return 1
  }
  if ! (umask 077; printf '%s\n' "$_CC_WJ_RUN_PID" > "$work/.owner-pid"); then
    _cc_wj_remove_private_temp "$work"
    echo "worktree-janitor: could not mark its private temporary directory; scanned and removed nothing" >&2
    return 1
  fi
  # Installed and hook-triggered runs execute under bash. Preserve caller traps, then
  # register signal cleanup before transcript projections can materialize normalized
  # tool input. An existing EXIT trap stays installed; otherwise add cleanup there too.
  # zsh only sources this file for helper tests; its `trap -p` is incompatible and no
  # installed run executes through that path.
  if [ -n "${BASH_VERSION:-}" ]; then
    old_exit="$(trap -p EXIT)"
    old_int="$(trap -p INT)"
    old_term="$(trap -p TERM)"
    old_hup="$(trap -p HUP)"
    if [ -z "$old_exit" ]; then
      trap '_cc_wj_remove_private_temp "$work"' EXIT
      cleanup_exit_installed=1
    fi
    trap '_cc_wj_cleanup_and_reraise INT 130' INT
    trap '_cc_wj_cleanup_and_reraise TERM 143' TERM
    trap '_cc_wj_cleanup_and_reraise HUP 129' HUP
  fi
  _CC_WJ_TRANSCRIPT_CACHE_ROOT="$work/transcript-cache"
  _CC_WJ_TRANSCRIPT_CACHE_GENERATION=0
  # Unreadable session records, per phase (stima-api#5886).
  local uk_scope uk_note="" uk_bytes uk_holder uk_would=0
  uk_scope="$(_cc_wj_unknown_scope)"
  _CC_WJ_UNKNOWN=""; _CC_WJ_UNKNOWN_ATTR=""; _CC_WJ_UNKNOWN_ERRORS=""; _CC_WJ_UNKNOWN_KEPT=""
  if ! _cc_wj_scan_holders "$work"; then
    LSOF_OK="no"
    echo "worktree-janitor: the process scan failed or saw nothing, so no worktree can be shown unheld" >&2
  fi
  if ! _cc_wj_scan_active_sessions "$session_grace_hours"; then
    ACTIVE_OK="no"
    activity_blind=1
    echo "worktree-janitor: $_CC_WJ_ACTIVE_ERROR, so no worktree can be shown free of active sessions" >&2
  fi
  # Launchd jobs that run from a worktree. A program that no longer exists is only reported.
  if _cc_wj_scan_launchd "$work"; then
    while IFS=$'\t' read -r ld_label ld_path; do
      [ -n "$ld_label" ] && echo "worktree-janitor: launchd-missing-program:$ld_label $ld_path"
    done < "$work/launchd-missing"
  else
    LAUNCHD_OK="no"
    echo "worktree-janitor: $_CC_WJ_LAUNCHD_ERROR, so no worktree can be shown free of launchd jobs" >&2
  fi

  # The checkout the calling session stands in, kept whatever else is true of it:
  # `claude --resume` expects to find it.
  # Newline-separated: a session supplies both its project directory and the cwd its hook
  # input names, and either may be the linked worktree it worked in.
  local keep_paths=""
  if [ -n "${CC_WJ_KEEP_PATH:-}" ]; then
    while IFS= read -r kp; do
      [ -n "$kp" ] && keep_paths="$keep_paths$(_cc_wj_realpath "$kp")"$'\n'
    done <<KEEP
$CC_WJ_KEEP_PATH
KEEP
  fi

  local repo lock lock_rc skipped=0
  # The phase budget and rotation. `examined` counts worktrees this phase started; the
  # first is examined whatever the clock says, so a phase whose setup alone outlasts the
  # budget still moves the cursor on. A yield is never a failure.
  local common cursor cursor_file phase=removal budget_hit=0 examined=0 wt_total=0 wt_index=0 elapsed=0 unexamined=0 repo_wts
  local repo_cursor_file="" progress_common="" rr rr_found=0 rr_after=() rr_through=()
  [ "$trim" -eq 1 ] && phase=trim
  # Repositories rotate too: the next apply run of a phase starts with the repository after
  # the last one in which it examined a worktree before its budget ran out - not merely the
  # one it was fetching or listing, which would then be skipped again - so a large first
  # repository cannot keep the others from ever being examined. Same rules as the worktree
  # cursor; an unknown one keeps the order, and a phase that examined nothing writes none.
  # Every size known before this run, read once; what this run measures orders the next one.
  : > "$work/sizes"
  [ "$_CC_WJ_ORDER" != largest ] || _cc_wj_size_map "$work/sizes"
  if [ "$apply" -eq 1 ]; then
    repo_cursor_file="$(_cc_wj_state_dir)/repo-cursor-$phase"
    cursor="$(head -n 1 "$repo_cursor_file" 2>/dev/null)"
    if [ -n "$cursor" ]; then
      for rr in "${repos[@]}"; do
        if [ "$rr_found" -eq 1 ]; then
          rr_after+=("$rr")
        else
          rr_through+=("$rr")
          [ "$(git -C "$rr" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$cursor" ] && rr_found=1
        fi
      done
      [ "$rr_found" -eq 1 ] && repos=(${rr_after[@]+"${rr_after[@]}"} "${rr_through[@]}")
    fi
  fi
  # Declared once, outside the loop: zsh prints the value of an already-set local that is
  # declared again.
  local reclaim pushed wip wip_dirty wip_ref wip_name total_pushed=0 total_wip=0 total_estimate=0
  reclaim="$(_cc_wj_reclaim_pushed)"
  local trim_known active lease landed idle referenced classification wt_phys git_keep head0 bytes kp active_detail active_rc lease_detail recent_rc linked_count abandoned idle_long trim_result trim_count trim_count_done trim_bytes task_done wt_idle_hours
  local nr_rules="" nr_dirty="" nr_count nr_line nr_note="" nr_holder nr_active_ok nr_blind
  # Said once, because the absence is otherwise silent: every squash-merged worktree just
  # reads KEEP(unlanded). That is how the scheduled sweep went without landed=pr for weeks.
  if [ "$trim" -eq 0 ] && ! command -v gh >/dev/null 2>&1; then
    echo "worktree-janitor: gh is not on PATH, so this run cannot prove landing by a merged pull request; such worktrees stay kept"
  fi
  for repo in "${repos[@]}"; do
    if [ ! -d "$repo" ]; then
      continue
    fi
    # Verify it's actually a git repo
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      continue
    fi

    if [ "$apply" -eq 1 ] && [ "$budget_hit" -eq 0 ] && [ "$sweep_budget" -gt 0 ] && [ "$examined" -gt 0 ]; then
      elapsed=$(( $(date +%s) - phase_start ))
      [ "$elapsed" -ge "$sweep_budget" ] && budget_hit=1
    fi
    # Past the budget a repository is not locked, fetched or judged, only counted.
    if [ "$budget_hit" -eq 1 ]; then
      repo_wts="$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
      [ "${repo_wts:-0}" -gt 1 ] && unexamined=$((unexamined + repo_wts - 1))
      continue
    fi

    lock=""
    cursor_file=""
    if [ "$apply" -eq 1 ]; then
      common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
      lock="$common/cc-reaper-worktree-janitor.lock"
      # One cursor per repository and phase, so the scheduled trim does not move where
      # the removal sweep starts.
      cursor_file="$(_cc_wj_state_dir)/worktree-cursor-$phase-$(printf '%s' "$common" | cksum | awk '{ print $1 }')"
      lock_rc=0
      _cc_wj_lock "$lock" || lock_rc=$?
      if [ "$lock_rc" -ne 0 ]; then
        [ "$lock_rc" -eq 2 ] || skipped=1
        continue
      fi
    fi

    # Discovery also sees ordinary clones with no linked worktree. They have nothing this
    # janitor can reclaim, so do not fetch their origin or load repository policy. Keep
    # failures on the ordinary path below, where they are reported fail-closed.
    if git -C "$repo" worktree list --porcelain > "$work/preflight-inventory" 2>/dev/null; then
      linked_count="$(grep -c '^worktree ' "$work/preflight-inventory")"
      if [ "$linked_count" -le 1 ]; then
        [ -n "$lock" ] && _cc_wj_unlock "$lock"
        continue
      fi
    fi

    if ! _cc_wj_prepare_base "$repo"; then
      echo "worktree-janitor: $repo: $_CC_WJ_BASE_WHY, so no worktree in it can be shown landed"
      # Fail closed for deletion and fail visibly for operations.  A zero exit here made
      # launchd report a healthy sweep even though an entire repository was ineligible
      # only because its fresh-base proof could not run.
      skipped=1
    fi

    # Origin's branch tips, asked fresh once per repository: "pushed" is judged against
    # them, never against a remote-tracking ref nobody refreshed.
    _CC_WJ_TIPS_OK=0
    if [ "$trim" -eq 0 ] && [ "$reclaim" = 1 ]; then
      _cc_wj_prepare_tips "$repo" "$work/tips" ||
        echo "worktree-janitor: $repo: origin's branches could not be listed, so nothing in it counts as pushed"
    fi

    # Collected to completion before anything is judged. Read as it is produced, the
    # producer runs `git -C <next worktree> status` while the loop scans for holders, and
    # the janitor's own git then holds the next worktree it is about to judge.
    # In spot-check mode the listing also records, per worktree, each entry that kept it only
    # because a rule on probation is not yet allowed to discount it.
    : > "$work/newrule"
    if ! _CC_WJ_NEWRULE_LOG="$work/newrule" _cc_wj_list_worktrees "$repo" > "$work/inventory"; then
      echo "worktree-janitor: could not list the worktrees of $repo (git 2.36 or newer is required); judged nothing in it"
      skipped=1
      [ -n "$lock" ] && _cc_wj_unlock "$lock"
      continue
    fi
    # In path order, starting after the worktree the last apply run of this phase examined
    # and wrapping round: a bounded sweep would otherwise re-examine the head of the list
    # every time. By order rather than by name, because the last one examined is often the
    # one it removed. A missing or unreadable cursor starts at the beginning; a report run
    # neither reads nor writes one.
    cursor=""
    if [ "$_CC_WJ_ORDER" = largest ]; then
      # Largest first, the order changing as sizes do, so "after the last examined" means
      # nothing here. The cursor file instead holds the worktrees examined in this cycle, one
      # per line: those go after the rest, and once every listed worktree is in it a new cycle
      # starts. Paths no longer listed are dropped. A missing or unreadable file is an empty
      # cycle; a report run neither reads nor writes it.
      : > "$work/seen"
      if [ -n "$cursor_file" ]; then
        cat "$cursor_file" 2>/dev/null |
          LC_ALL=C awk -F'\t' 'FILENAME == ARGV[1] { listed[$1] = 1; next }
            ($0 in listed) && !($0 in kept) { kept[$0] = 1; print }' "$work/inventory" - > "$work/seen"
        [ "$(wc -l < "$work/seen")" -lt "$(wc -l < "$work/inventory")" ] || : > "$work/seen"
        { cp "$work/seen" "$cursor_file.tmp.${_CC_WJ_RUN_PID:-$$}" 2>/dev/null &&
            mv -f "$cursor_file.tmp.${_CC_WJ_RUN_PID:-$$}" "$cursor_file" 2>/dev/null; } ||
          rm -f "$cursor_file.tmp.${_CC_WJ_RUN_PID:-$$}" 2>/dev/null
      fi
      _cc_wj_order_largest "$work/inventory" "$work/sizes" "$work/seen" > "$work/inventory.rotated" &&
        mv -f "$work/inventory.rotated" "$work/inventory"
    else
      [ -n "$cursor_file" ] && cursor="$(head -n 1 "$cursor_file" 2>/dev/null)"
      LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$work/inventory" |
        CC_WJ_CURSOR="$cursor" LC_ALL=C awk -F'\t' '$1 > ENVIRON["CC_WJ_CURSOR"] { print; next }
          { rest = rest $0 "\n" } END { printf "%s", rest }' > "$work/inventory.rotated" &&
        mv -f "$work/inventory.rotated" "$work/inventory"
    fi
    wt_total="$(wc -l < "$work/inventory" | tr -d ' ')"
    wt_index=0
    while IFS=$'\t' read -r wt_path branch dirty ahead push_state pins; do
      if [ "$apply" -eq 1 ]; then
        if [ "$sweep_budget" -gt 0 ] && [ "$examined" -gt 0 ]; then
          elapsed=$(( $(date +%s) - phase_start ))
          if [ "$elapsed" -ge "$sweep_budget" ]; then
            budget_hit=1
            unexamined=$((unexamined + wt_total - wt_index))
            break
          fi
        fi
        # The heartbeat: a sweep that is still deciding is not a dead holder.
        [ -n "$lock" ] && touch "$lock" 2>/dev/null
        if [ "$_CC_WJ_ORDER" = largest ]; then
          [ -z "$cursor_file" ] || printf '%s\n' "$wt_path" >> "$cursor_file" 2>/dev/null || :
        else
          _cc_wj_cursor_write "$cursor_file" "$wt_path"
        fi
        examined=$((examined + 1))
        progress_common="$common"
      fi
      wt_index=$((wt_index + 1))

      if [ "$dirty" = "UNSAFE-PATH" ]; then
        printf "  WORKTREE  %s\n" "$wt_path"
        printf "    branch=%s  dirty=?  active=n/a\n" "$branch"
        printf "    classification: KEEP(unsafe-path)  [a tab or newline in the path; review it by hand]\n"
        total_kept=$((total_kept + 1))
        continue
      fi

      # Handle missing dir
      if [ "$dirty" = "MISSING" ]; then
        printf "  WORKTREE  %s\n" "$wt_path"
        printf "    branch=%s  dirty=MISSING  ahead=%s  push=%s  active=n/a\n" \
          "$branch" "$ahead" "$push_state"
        printf "    classification: KEEP(missing-dir)  [cue: git worktree prune]\n"
        # Queue prune
        prune_repos+=("$repo")
        total_kept=$((total_kept + 1))
        continue
      fi

      # Named in CC_WJ_DENY_NAMES: nothing in it is trimmed or removed, in either phase.
      if _cc_wj_denied "$wt_path" "$branch"; then
        printf "  WORKTREE  %s\n" "$wt_path"
        printf "    branch=%s  dirty=%s  active=n/a\n" "$branch" "$dirty"
        printf "    classification: KEEP(%s)\n" "$_CC_WJ_DENY_REASON"
        total_kept=$((total_kept + 1))
        continue
      fi

      # Spot check: a worktree kept only by entries a rule on probation would discount is
      # judged as the rule would judge it, and every decision that would act is logged instead
      # and reverts to what the existing rules decide (KEEP(unrebuildable=<n>)).
      nr_rules=""; nr_dirty=""
      case "$dirty" in
        ''|0|*[!0-9]*) ;;
        *)
          if [ -s "$work/newrule" ]; then
            nr_count="$(W="$wt_path" LC_ALL=C awk -F'\t' '$1 == ENVIRON["W"]' "$work/newrule" | wc -l | tr -d ' ')"
            if [ "$nr_count" = "$dirty" ]; then
              nr_rules="$(W="$wt_path" LC_ALL=C awk -F'\t' '$1 == ENVIRON["W"] && !seen[$2]++ { printf "%s%s", (n++ ? "," : ""), $2 }' "$work/newrule")"
              nr_dirty="$dirty"; dirty=0
              nr_active_ok="$ACTIVE_OK"; nr_blind="$activity_blind"
            fi
          fi ;;
      esac

      active="n/a"
      active_detail="-"
      lease="n/a"
      lease_detail="-"
      # An accepted task (`_cc_wj_done`) is judged without its recent-session lease and
      # without the idle window; every other gate below, and every recheck before a
      # removal, still decides. Not asked in a trim pass, which judges nothing for removal.
      task_done="no"
      [ "$trim" -eq 0 ] && [ "$dirty" = "0" ] && task_done="$(_cc_wj_done "$wt_path")"
      wt_idle_hours="$idle_hours"
      [ "$task_done" = yes ] && wt_idle_hours=0
      # Only tracked edits and untracked files stand in the way: a snapshot of them reaches
      # refs/wip on origin before removal, so every gate below is asked as of a clean tree.
      # An ignored file that is not regenerable is not in a snapshot and keeps the tree.
      wip="no"; wip_dirty=""; wip_ref=""
      case "$dirty" in
        ''|0|*[!0-9]*) ;;
        *)
          if [ "$trim" -eq 0 ] && [ "$reclaim" = 1 ]; then
            case "$pins" in
              *'!! '*) ;;
              *)
                if _cc_wj_wip_ok "$wt_path"; then
                  wip="yes"; wip_dirty="$dirty"; dirty=0
                  wip_name="$(basename "$wt_path")"; wip_name="${wip_name//[^A-Za-z0-9._-]/-}"
                  wip_name="$(printf '%s' "$wip_name" | sed 's/^[.-]*//')"
                  wip_ref="refs/wip/${CC_WJ_WIP_LABEL:-macmini}/${wip_name}-$(date -u +%Y%m%dT%H%M%SZ)"
                fi ;;
            esac
          fi ;;
      esac
      # A dirty or unreadable git state already keeps the worktree. Do not spend seconds
      # rereading large harness transcripts to prove an additional keep reason that cannot
      # change the outcome. Clean candidates still take every holder/session veto below.
      if [ "$dirty" = "0" ]; then
        active="no"
        lease="no"
        if [ "$LSOF_OK" = "no" ] || _cc_wj_held "$work" "$wt_path"; then
          active="yes"
          active_detail="process holder"
        elif [ "$ACTIVE_OK" != "yes" ]; then
          active="yes"
          active_detail="$_CC_WJ_ACTIVE_ERROR"
        else
          # A direct recent cwd lease is an in-memory lookup and already vetoes removal.
          # Ask it before parsing every live transcript for structured tool paths.
          recent_rc=1
          if [ "$task_done" != yes ]; then
            _cc_wj_recent_claim "$wt_path" "$session_grace_hours" cwd; recent_rc=$?
          fi
          case "$recent_rc" in
            0) lease="yes"; lease_detail="$_CC_WJ_RECENT_REASON" ;;
            2) active="yes"; active_detail="$_CC_WJ_ACTIVE_ERROR"; ACTIVE_OK="no"; activity_blind=1 ;;
          esac
          if [ "$active" = "no" ] && [ "$lease" = "no" ]; then
            # Direct cwd claims are an in-memory lookup. Structured transcript matching
            # is deferred until the other gates prove this worktree could be removed.
            _cc_wj_live_claim "$task_done" "$wt_path" cwd; active_rc=$?
            case "$active_rc" in
              0) active="yes"; active_detail="$_CC_WJ_ACTIVE_REASON" ;;
              2) active="yes"; active_detail="$_CC_WJ_ACTIVE_ERROR"; ACTIVE_OK="no"; activity_blind=1 ;;
              3) lease="yes"; lease_detail="$_CC_WJ_RECENT_REASON" ;;
            esac
          fi
        fi
      fi

      # Pressure mode is intentionally narrower than worktree removal. It only
      # touches ignored built-in regenerable directories, and only after the
      # same process and harness claim vetoes have established that this tree is
      # not being used. The branch and worktree remain available for resume.
      if [ "$trim" -eq 1 ]; then
        printf "  WORKTREE  %s\n" "$wt_path"
        if [ -n "$nr_dirty" ]; then
          printf "    branch=%s  dirty=%s  active=n/a  recent=n/a\n" "$branch" "$nr_dirty"
        else
          printf "    branch=%s  dirty=%s  active=%s  recent=%s\n" "$branch" "$dirty" "$active" "$lease"
        fi
        # Nothing to trim is the common answer, and the cheapest to reach: one status read,
        # before the claim lookups, the idle walk and the git-state probe, which cost seconds
        # a tree and on 2026-10-24 ran the trim phase to 3240 s against an 1800 s budget with
        # every one of its 132 worktrees answering count=0. A failed read falls through to
        # the full path, which keeps the worktree with its reason.
        if _cc_wj_regenerable_dirs "$wt_path" > "$work/trim-precheck" 2>/dev/null &&
           [ ! -s "$work/trim-precheck" ]; then
          printf 'TRIM_RESULT count=0 trimmed=0 reclaimed=0\n'
          [ -z "$nr_dirty" ] || { ACTIVE_OK="$nr_active_ok"; activity_blind="$nr_blind"; }
          continue
        fi
        # Uncommitted files are never listed, since only ignored regenerable directories
        # are, so a dirty tree loses nothing authored. It is still work in progress, so it
        # waits a long idle window first. Measured 2026-10-06: 55 of 90 trees were dirty,
        # and stima-api's held 31.9 GB of node_modules and .next.
        # 1-5 digits, base 10: `08` is octal to $(( )), and a huge value wraps `-mmin`.
        case "$CC_WJ_TRIM_DIRTY_IDLE_HOURS" in
          ''|*[!0-9]*|??????*) CC_WJ_TRIM_DIRTY_IDLE_HOURS=0 ;;
          *) CC_WJ_TRIM_DIRTY_IDLE_HOURS=$((10#$CC_WJ_TRIM_DIRTY_IDLE_HOURS)) ;;
        esac
        if [ "$dirty" != "0" ] && { [ "$CC_WJ_TRIM_DIRTY_IDLE_HOURS" -eq 0 ] ||
             [ "$(_cc_wj_idle "$wt_path" "$CC_WJ_TRIM_DIRTY_IDLE_HOURS")" != yes ]; }; then
          printf "    classification: KEEP(unrebuildable=%s)\n" "$dirty"
          total_kept=$((total_kept + 1))
          continue
        fi
        git_keep="$(_cc_wj_git_keep "$wt_path")"
        case "$git_keep" in
          '') ;;
          unknown)
            printf "    classification: KEEP(git-state-unknown)\n"
            total_kept=$((total_kept + 1))
            continue
            ;;
          *)
            printf "    classification: KEEP(%s)\n" "$git_keep"
            total_kept=$((total_kept + 1))
            continue
            ;;
        esac
        if [ -n "$nr_dirty" ]; then
          # Judged as the new rule would, with every gate, and trimmed by nothing: each
          # directory it would remove is logged, and the tree stays as the existing rules keep it.
          trim_result="$(_cc_wj_trim_regenerable "$wt_path" "$work" 0 "$session_grace_hours" "$trim_idle_window")"
          nr_count=0
          while IFS= read -r nr_line; do
            case "$nr_line" in
              '  TRIM_CANDIDATE  '*)
                nr_line="${nr_line#  TRIM_CANDIDATE  }"
                _cc_wj_spotcheck trim would-trim "$nr_rules" "${nr_line%  bytes=*}" "${nr_line##*  bytes=}" \
                  "none(sweep-snapshot)" "$wt_path"
                nr_count=$((nr_count + 1)) ;;
            esac
          done <<NR_TRIM
$trim_result
NR_TRIM
          printf "    classification: KEEP(unrebuildable=%s)\n" "$nr_dirty"
          [ "$nr_count" -eq 0 ] ||
            printf "    spotcheck: %s would trim %s director%s here; logged to %s, nothing trimmed\n" \
              "$nr_rules" "$nr_count" "$([ "$nr_count" -eq 1 ] && echo y || echo ies)" "$(_cc_wj_spotcheck_log)"
          ACTIVE_OK="$nr_active_ok"; activity_blind="$nr_blind"
          total_kept=$((total_kept + 1))
          continue
        fi
        trim_result="$(_cc_wj_trim_regenerable "$wt_path" "$work" "$apply" "$session_grace_hours" "$trim_idle_window")"
        printf "%s\n" "$trim_result"
        case "$trim_result" in
          *'KEEP(session-unknown:'*|*'→ kept: session-unknown:'*)
            uk_note="$(printf '%s\n' "$trim_result" | LC_ALL=C grep -o 'session-unknown:[A-Za-z0-9._:-]*' | head -n 1)"
            # In spot-check mode every tree is kept while a record is unknown; only what the
            # per-tree rule itself keeps is listed against a record.
            if [ -n "$uk_note" ] && [ "$uk_scope" = tree ]; then
              if _cc_wj_unknown_keeps "$wt_path" "$session_grace_hours"; then
                _cc_wj_unknown_note_kept "$_CC_WJ_UNKNOWN_REASON" "$wt_path"
              else
                _cc_wj_unknown_note_kept "$uk_note" "$wt_path" attr
              fi
            fi
            uk_note="" ;;
        esac
        trim_count="$(printf '%s\n' "$trim_result" | awk -F'[ =]' '/^TRIM_RESULT / {print $3}')"
        trim_count_done="$(printf '%s\n' "$trim_result" | awk -F'[ =]' '/^TRIM_RESULT / {print $5}')"
        trim_bytes="$(printf '%s\n' "$trim_result" | awk -F'[ =]' '/^TRIM_RESULT / {print $7}')"
        case "$trim_count" in ''|*[!0-9]*) trim_count=0 ;; esac
        case "$trim_count_done" in ''|*[!0-9]*) trim_count_done=0 ;; esac
        case "$trim_bytes" in ''|*[!0-9]*) trim_bytes=0 ;; esac
        total_trim_candidates=$((total_trim_candidates + trim_count))
        if [ "$apply" -eq 1 ]; then
          total_trimmed=$((total_trimmed + trim_count_done))
          total_trim_reclaimed=$((total_trim_reclaimed + trim_bytes))
          # What it freed comes off its known size, so the next trim does not put a tree it
          # just emptied first again. No known size, nothing to subtract from: none is written.
          if [ "$trim_bytes" -gt 0 ] && [ "$_CC_WJ_ORDER" = largest ]; then
            trim_known="$(CC_WJ_P="$wt_path" LC_ALL=C awk -F'\t' '$1 == ENVIRON["CC_WJ_P"] { print $2; exit }' "$work/sizes")"
            case "$trim_known" in
              ''|*[!0-9]*) ;;
              *) _cc_wj_size_record "$wt_path" "$(awk -v k="$trim_known" -v t="$trim_bytes" 'BEGIN { printf "%.0f", (k > t ? k - t : 0) }')" ;;
            esac
          fi
        fi
        printf '%s\n' "$trim_result" | grep -q '^KEEP(' && total_kept=$((total_kept + 1))
        continue
      fi

      # Asked only of a worktree the cheaper gates have not already kept: the landed proofs
      # may reach the network, and the idle walk costs seconds on a tree with node_modules.
      landed="-"
      idle="-"
      abandoned="no"
      referenced="no"
      pushed="no"
      head0="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)"
      if [ "$dirty" = "0" ] && [ "$active" = "no" ] && [ "$lease" = "no" ]; then
        [ "$branch" = "(detached)" ] && referenced="$(_cc_wj_referenced "$wt_path")"
        landed="$(_cc_wj_landed "$wt_path")"
        [ "$landed" = no ] && pushed="$(_cc_wj_pushed "$wt_path" "$work/tips")"
        case "$landed" in
          ancestor|content|pr) idle="$(_cc_wj_idle "$wt_path" "$wt_idle_hours")" ;;
          unfetched) ;;
          *)
            if [ "$pushed" = yes ]; then
              # On origin already: only the ordinary idle window is left to ask.
              idle="$(_cc_wj_idle "$wt_path" "$wt_idle_hours")"
              [ "$branch" = "(detached)" ] && referenced=yes
            elif [ "$wip" = yes ]; then
              :  # edits of work that is neither landed nor on origin stay put
            else
            # The abandoned question, asked in cost order: the tree walk before the network
            # call, and the network call only for a tree that has already sat out the long
            # window. Most unlanded worktrees are recent, so most pay neither.
            #
            # `idle` is taken from the LONG window's answer rather than walked a second
            # time. The predicate is "nothing under this tree was modified within N hours",
            # so a yes at 168 hours entails a yes at any smaller window; an `unknown` or a
            # `no` entails nothing, and neither is copied.
            idle_long="$(_cc_wj_idle "$wt_path" "$abandon_hours")"
            if [ "$idle_long" = "yes" ]; then
              idle="yes"
              # A detached HEAD has no branch to ask GitHub about; what makes it safe to
              # remove is that a ref keeps its commits.
              if [ "$branch" = "(detached)" ]; then
                abandoned="$referenced"
              else
                abandoned="$(_cc_wj_never_had_pr "$wt_path")"
                [ "$abandoned" = "yes" ] || abandoned="$(_cc_wj_closed_at_head "$wt_path")"
              fi
            fi
            fi
            ;;
        esac
      fi

      classification=""
      if [ -n "$keep_paths" ]; then
        wt_phys="$(_cc_wj_realpath "$wt_path")"
        while IFS= read -r kp; do
          [ -n "$kp" ] || continue
          case "$kp/" in "${wt_phys%/}"/*) classification="KEEP(this-session)" ;; esac
        done <<KEEP
$keep_paths
KEEP
      fi
      git_keep=""
      if [ -z "$classification" ]; then
        git_keep="$(_cc_wj_git_keep "$wt_path")"
        case "$git_keep" in
          '') ;;
          unknown) classification="KEEP(git-state-unknown)" ;;
          *) classification="KEEP($git_keep)" ;;
        esac
      fi
      # Structured transcript matching is the expensive active/recent-session proof.
      # Ask it only for a worktree every cheaper gate would otherwise make removable;
      # direct cwd claims and leases were checked above. `--claims PATH` remains the
      # explicit full scan.
      if [ -z "$classification" ] && [ "$dirty" = "0" ] && [ "$active" = "no" ] &&
         [ "$lease" = "no" ] &&
         { [ "$landed" = ancestor ] || [ "$landed" = content ] || [ "$landed" = pr ] ||
           [ "$abandoned" = "yes" ] || [ "$pushed" = "yes" ]; } &&
         [ "$idle" = "yes" ]; then
        _cc_wj_live_claim "$task_done" "$wt_path" tool; active_rc=$?
        case "$active_rc" in
          0) active="yes"; active_detail="$_CC_WJ_ACTIVE_REASON" ;;
          2) active="yes"; active_detail="$_CC_WJ_ACTIVE_ERROR"; ACTIVE_OK="no"; activity_blind=1 ;;
          3) lease="yes"; lease_detail="$_CC_WJ_RECENT_REASON" ;;
        esac
        if [ "$active" = "no" ] && [ "$lease" = "no" ] && [ "$task_done" != yes ]; then
          _cc_wj_recent_claim "$wt_path" "$session_grace_hours" tool; recent_rc=$?
          case "$recent_rc" in
            0) lease="yes"; lease_detail="$_CC_WJ_RECENT_REASON" ;;
            2) active="yes"; active_detail="$_CC_WJ_ACTIVE_ERROR"; ACTIVE_OK="no"; activity_blind=1 ;;
          esac
        fi
      fi
      [ -n "$classification" ] ||
        classification=$(_cc_wj_classify "$wt_path" "$dirty" "$active" "$LSOF_OK" "$branch" "$landed" "$idle" "$lease" "$abandoned" "$referenced" "$pushed" "$wip")
      # A launchd job that runs from the tree has no process to hold it between runs.
      case "$classification" in
        REMOVABLE|REMOVABLE\(*\))
          ld_keep="$(_cc_wj_launchd_keep "$work" "$wt_path" "$LAUNCHD_OK")"
          [ -z "$ld_keep" ] || classification="$ld_keep" ;;
      esac
      # A session record that could not be read keeps the trees it could be about, asked last,
      # of a tree every other gate would remove (stima-api#5886). In spot-check mode a tree it
      # would free is logged and kept as the global rule keeps it.
      uk_note=""
      if [ "$uk_scope" != global ] && [ -n "$_CC_WJ_UNKNOWN" ]; then
        case "$classification" in
          REMOVABLE|REMOVABLE\(*\))
            if _cc_wj_unknown_keeps "$wt_path" "$session_grace_hours" ||
               { [ "$wip" = yes ] && _cc_wj_unknown_gate "$wt_path" "$session_grace_hours" yes; }; then
              classification="KEEP($_CC_WJ_UNKNOWN_REASON)"
              _cc_wj_unknown_note_kept "$_CC_WJ_UNKNOWN_REASON" "$wt_path"
            elif [ "$uk_scope" = spotcheck ]; then
              uk_holder="none(sweep-snapshot)"
              { [ "$LSOF_OK" != yes ] || _cc_wj_held "$work" "$wt_path"; } && uk_holder="held"
              uk_bytes="$(CC_WJ_P="$wt_path" LC_ALL=C awk -F'\t' '$1 == ENVIRON["CC_WJ_P"] { print $2; exit }' "$work/sizes")"
              case "$uk_bytes" in
                ''|*[!0-9]*)
                  uk_bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || uk_bytes=0
                  _cc_wj_size_record "$wt_path" "${uk_bytes:-0}" ;;
              esac
              _cc_wj_spotcheck removal would-remove session-unknown-per-tree "$wt_path" "${uk_bytes:-0}" "$uk_holder" "$wt_path"
              uk_note="spotcheck: session-unknown-per-tree would make it $classification; logged to $(_cc_wj_spotcheck_log), nothing removed"
              classification="KEEP(active-session)"
              active="yes"; active_detail="$(printf '%s' "$_CC_WJ_UNKNOWN_ERRORS" | awk -F '\t' 'NF { print $2; exit }')"
              uk_would=$((uk_would + 1))
            fi ;;
        esac
      fi
      # Spot check: what the new rule would remove is logged, and the decision reverts to the
      # existing one. A keep the existing rules gave before the content gate stays as it was.
      nr_note=""
      if [ -n "$nr_dirty" ]; then
        case "$classification" in
          REMOVABLE|REMOVABLE\(*\))
            nr_holder="none(sweep-snapshot)"
            { [ "$LSOF_OK" != yes ] || _cc_wj_held "$work" "$wt_path"; } && nr_holder="held"
            bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
            _cc_wj_size_record "$wt_path" "$bytes"
            _cc_wj_spotcheck removal would-remove "$nr_rules" "$wt_path" "${bytes:-0}" "$nr_holder" "$wt_path"
            nr_note="spotcheck: $nr_rules would make it $classification; logged to $(_cc_wj_spotcheck_log), nothing removed" ;;
        esac
        case "$classification" in
          KEEP\(this-session\)) ;;
          *) [ -n "$git_keep" ] || classification="$(_cc_wj_classify "$wt_path" "$nr_dirty" n/a "$LSOF_OK")" ;;
        esac
        dirty="$nr_dirty"; active="n/a"; lease="n/a"; active_detail="-"; lease_detail="-"
        landed="-"; idle="-"; task_done="no"
        ACTIVE_OK="$nr_active_ok"; activity_blind="$nr_blind"
      fi

      printf "  WORKTREE  %s\n" "$wt_path"
      printf "    branch=%s  dirty=%s  ahead=%s  push=%s  active=%s  recent=%s  landed=%s  idle=%s\n" \
        "$branch" "${wip_dirty:-$dirty}" "$ahead" "$push_state" "$active" "$lease" "$landed" "$idle"
      printf "    classification: %s\n" "$classification"
      [ -z "$nr_note" ] || printf "    %s\n" "$nr_note"
      [ -z "$uk_note" ] || printf "    %s\n" "$uk_note"
      case "$classification" in
        'REMOVABLE(pushed)') printf "    pushed: origin lists a branch that contains HEAD\n" ;;
        'REMOVABLE(wip-pushed)')
          [ "$apply" -eq 1 ] || printf "    would push wip: %s entries to %s\n" "$wip_dirty" "$wip_ref" ;;
      esac
      [ "$active_detail" = "-" ] || printf "    active claim: %s\n" "$active_detail"
      [ "$lease_detail" = "-" ] || printf "    session lease: %s\n" "$lease_detail"
      [ "$task_done" != yes ] || printf "    done: claude-task-done at HEAD %s\n" "${head0:0:12}"
      if [ "$classification" = REMOVABLE ] && [ -n "$_CC_WJ_ARCHIVED" ]; then
        : > "$work/archive-list"
        _cc_wj_undiscounted_count "$wt_path" "$work/archive-list" >/dev/null
        [ ! -s "$work/archive-list" ] || printf "    archive on removal: %s\n" \
          "$(awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 }' "$work/archive-list")"
      fi
      if [ "$dirty" != "0" ] && [ "${pins:--}" != "-" ]; then
        printf "    kept by: %s\n" "$pins"
        case "$pins" in
          *'!! '*)
            printf "    if a command rebuilds an ignored entry, list it in .worktree-regenerable on origin/%s\n" \
              "${_CC_WJ_BASE:-<default branch>}" ;;
        esac
      fi
      case "$classification" in
        KEEP\(base-unfetched\)) printf "    %s\n" "$_CC_WJ_BASE_WHY" ;;
        KEEP\(idle-unknown\)) printf "    the idle test could not read the whole tree\n" ;;
        KEEP\(locked\))
          printf "    lock reason: %s\n" \
            "$(head -n 1 "$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null)/locked" 2>/dev/null)" ;;
      esac

      case "$classification" in
        REMOVABLE|REMOVABLE\(*\))
          total_removable=$((total_removable + 1))
          [ "$classification" = 'REMOVABLE(pushed)' ] && total_pushed=$((total_pushed + 1))
          [ "$classification" = 'REMOVABLE(wip-pushed)' ] && total_wip=$((total_wip + 1))
          if [ "$apply" -ne 1 ]; then
            # What a removal would free; measured here, for the candidates only.
            bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
            _cc_wj_size_record "$wt_path" "$bytes"
            total_estimate=$((total_estimate + ${bytes:-0}))
          fi
          if [ "$apply" -eq 1 ]; then
            # A task can start after the inventory snapshot without yet opening any file
            # in the worktree.  Refresh both harness registries before the destructive
            # path, then refresh holders/content/idleness as before.
            if ! _cc_wj_scan_active_sessions "$session_grace_hours"; then
              ACTIVE_OK="no"; activity_blind=1
              printf "    → kept: %s, so active sessions are unknown\n" "$_CC_WJ_ACTIVE_ERROR"
              total_kept=$((total_kept + 1))
              continue
            fi
            # The annotation waives two of the questions below, so it has to hold now too.
            # Read again, it can only withdraw a waiver the inventory granted.
            if [ "$task_done" = yes ]; then
              task_done="$(_cc_wj_done "$wt_path")"
              [ "$task_done" = yes ] || wt_idle_hours="$idle_hours"
            fi
            _cc_wj_live_claim "$task_done" "$wt_path"; active_rc=$?
            case "$active_rc" in
              0)
                printf "    → kept: %s; claim appeared before removal\n" "$_CC_WJ_ACTIVE_REASON"
                total_kept=$((total_kept + 1))
                continue
                ;;
              2)
                ACTIVE_OK="no"; activity_blind=1
                printf "    → kept: %s, so active sessions are unknown\n" "$_CC_WJ_ACTIVE_ERROR"
                total_kept=$((total_kept + 1))
                continue
                ;;
            esac
            recent_rc=1
            if [ "$task_done" != yes ]; then
              _cc_wj_recent_claim "$wt_path" "$session_grace_hours"; recent_rc=$?
            fi
            case "$recent_rc" in
              0)
                printf "    → kept: %s; recent-session lease appeared before removal\n" "$_CC_WJ_RECENT_REASON"
                total_kept=$((total_kept + 1))
                continue
                ;;
              2)
                ACTIVE_OK="no"; activity_blind=1
                printf "    → kept: %s, so recent sessions are unknown\n" "$_CC_WJ_ACTIVE_ERROR"
                total_kept=$((total_kept + 1))
                continue
                ;;
            esac
            # The fresh scans may hold a record that cannot be read; it gets the same per-tree say.
            if _cc_wj_unknown_gate "$wt_path" "$session_grace_hours" "$wip"; then
              printf "    → kept: %s; an unreadable session record may be about it\n" "$_CC_WJ_UNKNOWN_REASON"
              _cc_wj_unknown_note_kept "$_CC_WJ_UNKNOWN_REASON" "$wt_path"
              total_kept=$((total_kept + 1))
              continue
            fi
            # Everything above was decided from scans taken before the loop began, and
            # another session can have entered this worktree or written into it since.
            # Asked again against fresh scans, immediately before the one irreversible step.
            if ! _cc_wj_scan_holders "$work"; then
              LSOF_OK="no"
              printf "    → kept: the process scan failed right before removal\n"
              total_kept=$((total_kept + 1))
              continue
            fi
            # Launchd plists are read again too: a job can be installed after the first scan.
            if ! _cc_wj_scan_launchd "$work"; then
              LAUNCHD_OK="no"
              printf "    → kept: %s, so launchd jobs are unknown\n" "$_CC_WJ_LAUNCHD_ERROR"
              total_kept=$((total_kept + 1))
              continue
            fi
            LAUNCHD_OK="yes"
            ld_keep="$(_cc_wj_launchd_target "$work" "$wt_path")"
            if [ -n "$ld_keep" ]; then
              printf "    → kept: launchd job %s runs from it\n" "$ld_keep"
              total_kept=$((total_kept + 1))
              continue
            fi
            # The same read lists what the removal must copy out first.
            : > "$work/archive-list"
            if _cc_wj_held "$work" "$wt_path" ||
               { if [ "$wip" = yes ]; then ! _cc_wj_wip_ok "$wt_path" "$work/archive-list"
                 else [ "$(_cc_wj_undiscounted_count "$wt_path" "$work/archive-list")" != "0" ]; fi; } ||
               [ "$(_cc_wj_idle "$wt_path" "$wt_idle_hours")" != "yes" ] ||
               [ -z "$head0" ] ||
               [ "$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" != "$head0" ] ||
               [ -n "$(_cc_wj_git_keep "$wt_path")" ]; then
              printf "    → kept: it was entered or changed between the scan and the removal\n"
              total_kept=$((total_kept + 1))
              continue
            fi
            # Measure disk usage before removal, and before any copy: nothing slow may sit
            # between a verified copy and the removal.
            bytes=0
            bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
            _cc_wj_size_record "$wt_path" "$bytes"
            if [ -s "$work/archive-list" ]; then
              if ! _cc_wj_archive_files "$repo" "$wt_path" "$work/archive-list"; then
                printf "    → kept: archiving its archive: files to %s failed\n" "$_CC_WJ_ARCHIVE_DEST"
                total_kept=$((total_kept + 1))
                continue
              fi
              printf "    → archived %s file(s) to %s\n" \
                "$(wc -l < "$work/archive-list" | tr -d ' ')" "$_CC_WJ_ARCHIVE_DEST"
            fi
            if [ "$wip" = yes ]; then
              # Last step before the one irreversible one, and the only way a dirty tree is
              # removed: its edits must be on origin, read back, and unchanged since.
              if ! _cc_wj_wip_send "$repo" "$wt_path" "$wip_ref"; then
                printf "    → kept: its edits could not be pushed to %s and read back\n" "$wip_ref"
                total_kept=$((total_kept + 1))
                continue
              fi
              printf "    → wip pushed: %s at %s\n" "$wip_ref" "$_CC_WJ_WIP_COMMIT"
              _cc_wj_log_write "wip pushed: $wip_ref $_CC_WJ_WIP_COMMIT for $wt_path"
            fi
            if [ "$branch" = "(detached)" ] && [ "$landed" != "ancestor" ] &&
               ! _cc_wj_pin_detached "$wt_path" "$head0"; then
              printf "    → kept: its detached HEAD could not be pinned before removal\n"
              total_kept=$((total_kept + 1))
              continue
            fi
            if _cc_wj_remove_worktree "$repo" "$wt_path" "$([ "$wip" = yes ] && echo --force)"; then
              total_removed=$((total_removed + 1))
              total_reclaimed=$((total_reclaimed + bytes))
              _cc_wj_size_record "$wt_path" -
              printf "    → removed (%s bytes reclaimed)\n" "$bytes"
              [ -n "$lock" ] && touch "$lock" 2>/dev/null
              # Queue prune for this repo
              prune_repos+=("$repo")
            else
              printf "    → removal FAILED\n" >&2
              total_kept=$((total_kept + 1))
            fi
          fi
          ;;
        KEEP*)
          total_kept=$((total_kept + 1))
          ;;
      esac

    done < "$work/inventory"

    [ -n "$lock" ] && _cc_wj_unlock "$lock"
  done
  if [ "$budget_hit" -eq 1 ]; then
    echo "worktree-janitor: $phase phase budget exhausted: budget=${sweep_budget}s elapsed=${elapsed}s unexamined=$unexamined; kept them for the next sweep, which $([ "$_CC_WJ_ORDER" = largest ] && echo "starts with those not yet examined in this cycle, largest first" || echo "resumes after the last examined")"
    _cc_wj_log_write "$phase phase budget exhausted: budget=${sweep_budget}s elapsed=${elapsed}s unexamined=$unexamined"
    [ -n "$progress_common" ] && _cc_wj_cursor_write "$repo_cursor_file" "$progress_common"
  fi
  # Each unreadable record once, with what it kept. Global mode said so at the scan, as before.
  [ "$uk_scope" = global ] || _cc_wj_unknown_summary "$uk_scope"
  if [ "$uk_would" -gt 0 ]; then
    echo "worktree-janitor: spotcheck: session-unknown-per-tree would free $uk_would worktree(s) the unreadable records kept; logged to $(_cc_wj_spotcheck_log), nothing removed" >&2
    _cc_wj_log_write "spotcheck: session-unknown-per-tree would free $uk_would worktree(s)"
  fi
  [ -z "$_CC_WJ_UNKNOWN_ERRORS" ] || activity_blind=1
  _cc_wj_remove_private_temp "$work"
  if [ -n "${BASH_VERSION:-}" ]; then
    trap - INT TERM HUP
    [ -z "$old_int" ] || eval "$old_int"
    [ -z "$old_term" ] || eval "$old_term"
    [ -z "$old_hup" ] || eval "$old_hup"
    [ "$cleanup_exit_installed" -eq 0 ] || trap - EXIT
  fi

  # Run git worktree prune on repos that had removals or missing dirs (deduped).
  #
  # Gated on --apply. `git worktree prune` removes administrative records, and this
  # script's own usage says removal needs --apply; running it from a report made the
  # default mode mutate the repository it was only supposed to describe. That became
  # load-bearing when the scheduled agent landed: an agent that never passes --apply
  # was deleting metadata daily under the name "report-only". The report still prints
  # `[cue: git worktree prune]` for a missing directory, so the finding is not lost -
  # only the unrequested action is.
  if [ "$apply" -eq 1 ] && [ "${#prune_repos[@]}" -gt 0 ]; then
    local pruned_repos=()
    for repo in "${prune_repos[@]}"; do
      local already=0
      for p in ${pruned_repos[@]+"${pruned_repos[@]}"}; do
        [ "$p" = "$repo" ] && already=1 && break
      done
      if [ "$already" -eq 0 ]; then
        git -C "$repo" worktree prune 2>/dev/null || true
        _cc_wj_log_write "pruned: $repo"
        pruned_repos+=("$repo")
      fi
    done
  fi

  # Summary
  echo ""
  if [ "$trim" -eq 1 ]; then
    gb_str="$(awk -v b="$total_trim_reclaimed" 'BEGIN { printf "%.2f", b / 1073741824 }')"
    if [ "$apply" -eq 1 ]; then
      printf "Summary: trimmed=%d  reclaimed=%s GB  kept=%d\n" \
        "$total_trimmed" "$gb_str" "$total_kept"
      _cc_wj_log_write "trim summary: trimmed=$total_trimmed reclaimed=${total_trim_reclaimed}B kept=$total_kept"
    else
      printf "Summary: trim-candidates=%d  kept=%d  (dry-run; use --apply --trim-regenerable to remove)\n" \
        "$total_trim_candidates" "$total_kept"
    fi
  elif [ "$apply" -eq 1 ]; then
    local gb_str
    gb_str=$(awk -v b="$total_reclaimed" 'BEGIN { printf "%.2f", b / 1073741824 }')
    printf "Summary: removed=%d  reclaimed=%s GB  kept=%d\n" \
      "$total_removed" "$gb_str" "$total_kept"
    _cc_wj_log_write "summary: removed=$total_removed reclaimed=${total_reclaimed}B kept=$total_kept"
  else
    printf "Summary: removable=%d  kept=%d  (dry-run; use --apply to remove)  pushed=%d  wip=%d  estimated-reclaimable=%s GB\n" \
      "$total_removable" "$total_kept" "$total_pushed" "$total_wip" \
      "$(awk -v b="$total_estimate" 'BEGIN { printf "%.2f", b / 1073741824 }')"
  fi

  # Notification fires only on --apply pass (report-only runs don't measure bytes)
  if [ "$apply" -eq 1 ] && { [ "$total_reclaimed" -gt 0 ] || [ "$total_trim_reclaimed" -gt 0 ]; }; then
    _cc_wj_maybe_notify $((total_reclaimed + total_trim_reclaimed))
  fi

  # Finding repositories under one root does not make a denial on another harmless:
  # the worktrees under the denied one were never even listed. A repository whose lock could
  # not be taken was not swept either; one a live sweep holds was deferred, not failed.
  [ "$blind" -eq 1 ] && return 1
  [ "$skipped" -eq 1 ] && return 1
  [ "$activity_blind" -eq 1 ] && return 1
  return 0
}

# Delimit unattended output even when the inner run exits through an early validation or
# discovery failure. The wrapper owns only scheduled evidence; manual reports retain their
# established output shape for callers and tests.
_cc_wj_run() {
  local arg scheduled=0 started rc
  for arg in "$@"; do
    [ "$arg" = --scheduled ] && scheduled=1
  done
  # One id for both phases of a sweep, so spot-check records of one run can be read together.
  _CC_WJ_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if [ "$scheduled" -eq 1 ]; then
    _cc_wj_bound_log "$HOME/.cc-reaper/logs/launchd-worktree-janitor-stdout.log"
    _cc_wj_bound_log "$HOME/.cc-reaper/logs/launchd-worktree-janitor-stderr.log"
    started="$(date +%s)"
    printf '== worktree-janitor scheduled sweep started %s pid=%s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$"
  fi
  _cc_wj_run_inner "$@"; rc=$?
  # Under disk pressure the scheduled sweep also trims the regenerable caches
  # (node_modules, .next, .venv...) of the worktrees it kept: 45 GB of them on 2026-10-05.
  # The trim keeps the worktree and asks every gate again before each directory.
  if [ "$scheduled" -eq 1 ] && [ "${CC_WJ_SCHEDULE_APPLY-}" = 1 ] &&
     [ "${CC_WJ_PRESSURE_TRIM:-1}" = 1 ] && _cc_wj_disk_pressure >/dev/null; then
    echo "== worktree-janitor under disk pressure: trimming regenerable caches of kept worktrees"
    # The same repositories the sweep was given: --repo pairs pass through, nothing else.
    local trim_args=() prev=""
    for arg in "$@"; do
      [ "$prev" = --repo ] && trim_args+=(--repo "$arg")
      prev="$arg"
    done
    # Its own status is printed; the sweep's is the one the run reports.
    _cc_wj_run_inner --trim-regenerable --apply ${trim_args[@]+"${trim_args[@]}"} ||
      echo "== worktree-janitor pressure trim ended with status $?"
  fi
  if [ "$scheduled" -eq 1 ]; then
    printf '== worktree-janitor scheduled sweep ended %s elapsed=%ss status=%s\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(( $(date +%s) - started ))" "$rc"
  fi
  return "$rc"
}

# ─── Session mode ─────────────────────────────────────────────────────────────

_cc_wj_free_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 + 0 }'; }

# Disk pressure: under CC_WJ_PRESSURE_FREE_GB (default 100) free on the volume holding
# $HOME, print why and return 0. On 2026-10-05 the Mac mini fell to 25 GB free while 31
# landed, clean, unheld worktrees (21.5 GB) waited out a 24h idle window and the session
# lease: worktrees open at about 60 a day there, and a day of them is 45 GB. Nothing the
# pressure tier shortens is a safety gate - landed, clean, unheld and unclaimed still
# hold - only how long a finished tree waits. `off` or 0 disables it; an unreadable free
# figure or a bad floor is not pressure.
_cc_wj_disk_pressure() {
  local floor="${CC_WJ_PRESSURE_FREE_GB:-100}" free
  case "$floor" in ''|off|*[!0-9]*|??????*) return 1 ;; esac
  floor=$((10#$floor))
  [ "$floor" -gt 0 ] || return 1
  free="$(_cc_wj_free_kb)"
  case "$free" in ''|*[!0-9]*) return 1 ;; esac
  [ "$free" -lt $((floor * 1048576)) ] || return 1
  printf 'free %s < %sGB' "$(_cc_wj_gib "$free")" "$floor"
}
_cc_wj_gib() {
  case "$1" in
    ''|*[!0-9]*) printf '?' ;;
    *) awk -v k="$1" 'BEGIN { printf "%.1fGiB", k / 1048576 }' ;;
  esac
}

# `--session`: the inventory for the repository a Claude Code or Codex session stood in,
# meant to run through hooks/worktree-session-end.sh.
#
# Why a session and not a schedule: a LaunchAgent cannot read `~/Documents`, measured
# 2026-08-30, which is why the inventory was never scheduled. A session's processes run
# with the grant its terminal holds.
#
# Why detached: every SessionEnd hook shares one deadline of at most 60 seconds, and a
# sweep of a large repository measured 258. So the hook starts the sweep in a new session
# and returns at once. perl forks in the foreground and the child calls setsid() before
# the parent exits - the other order leaves a moment in which the sweep is an orphan still
# in the session's process group, which is precisely what an orphan reaper running beside
# this hook at session end kills.
#
# It reports unless CC_WJ_SESSION_APPLY is exactly `1`. An unattended run never removed
# anything before this mode existed, and installing the hook should not change that
# without a decision.
_cc_wj_session() {
  # The launcher re-executes this file by the path bash knows it by; another shell that
  # sourced it has no such path.
  if [ -z "${BASH_VERSION:-}" ]; then
    echo "worktree-janitor: --session requires bash; run the script rather than sourcing it" >&2
    return 1
  fi
  if [ "${CC_WJ_DETACHED:-}" != "1" ]; then
    local log script input="" hook_cwd="" unparsed=""
    # A SessionEnd hook receives JSON on stdin, and its `cwd` is where the session stood -
    # which need not be CLAUDE_PROJECT_DIR when it worked in a linked worktree. Read only
    # from a pipe or file, so a terminal invocation does not wait for input.
    #
    # One character at a time, each read bounded, so a pipe left open costs two seconds and
    # what arrived before it stalled is kept: bash 3.2 discards everything a timed-out
    # `read -d ''` had read. Without exactly one `"cwd"` that parses to an absolute path -
    # none read, an escaped quote, a second one nested in the input, or input past the
    # bound - the session's own worktree is unknown, and that sweep only reports.
    #
    # The bound is 8192 characters, where a SessionEnd payload is a few hundred: bash 3.2
    # appends in quadratic time, and 70K bytes took 77 seconds, past the hook's deadline.
    if [ ! -t 0 ]; then
      local c rest
      while [ "${#input}" -lt 8192 ] && IFS= read -r -d '' -n 1 -t 2 c; do
        input="$input$c"
      done
      [ "${#input}" -lt 8192 ] || input=""
      case "$input" in
        *'"cwd"'*)
          rest="${input#*\"cwd\"}"
          case "$rest" in
            *'"cwd"'*) ;;
            *) hook_cwd="$(printf '%s\n' "$rest" |
                 sed -n '1s/^[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p')" ;;
          esac ;;
      esac
      case "$hook_cwd" in /*) ;; *) unparsed=1 ;; esac
    fi
    log="${CC_WJ_SESSION_LOG:-$HOME/.cc-reaper/logs/worktree-janitor-session.log}"
    mkdir -p "$(dirname "$log")" 2>/dev/null
    _cc_wj_bound_log "$log"
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    export CC_WJ_DETACHED=1 \
      CC_WJ_SESSION_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}" \
      CC_WJ_SESSION_CWD="$hook_cwd" \
      CC_WJ_SESSION_CWD_UNPARSED="$unparsed"
    if command -v perl >/dev/null 2>&1; then
      perl -MPOSIX -e 'pipe(my $r, my $w) or exit 1; defined(my $p = fork) or exit 1;
        if ($p) { close $w; my $done = <$r>; exit 0 }
        close $r; POSIX::setsid(); close $w; exec @ARGV or exit 127' \
        "${BASH:-/bin/bash}" "$script" --session </dev/null >>"$log" 2>&1
    elif command -v setsid >/dev/null 2>&1; then
      setsid -f "${BASH:-/bin/bash}" "$script" --session </dev/null >>"$log" 2>&1
    else
      nohup "${BASH:-/bin/bash}" "$script" --session </dev/null >>"$log" 2>&1 &
    fi
    return 0
  fi

  local dir cwd common main apply_flag="" t0 free0 rc=0
  dir="${CC_WJ_SESSION_DIR:-$PWD}"
  dir="$(builtin cd -P -- "$dir" >/dev/null 2>&1 && pwd -P)" || dir="${CC_WJ_SESSION_DIR:-$PWD}"
  cwd=""
  [ -n "${CC_WJ_SESSION_CWD:-}" ] && cwd="$(builtin cd -P -- "$CC_WJ_SESSION_CWD" >/dev/null 2>&1 && pwd -P)"
  # The repository is the one the session actually stood in, when its hook input said.
  [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 && dir="$cwd"
  t0="$(date +%s)"
  free0="$(_cc_wj_free_kb)"
  echo "== worktree-janitor ${CC_WJ_HARNESS:-unknown} session sweep $(date '+%Y-%m-%dT%H:%M:%S%z') $dir (pid $$)"
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$common" ]; then
    echo "worktree-janitor: $dir is not inside a git repository; swept nothing"
  elif [ "$(basename "$common")" != ".git" ]; then
    echo "worktree-janitor: $dir belongs to a repository without a primary checkout ($common); swept nothing"
  else
    main="$(dirname "$common")"
    case "${CC_WJ_SESSION_APPLY-}" in
      1) apply_flag="--apply" ;;
      '') ;;
      *) echo "worktree-janitor: CC_WJ_SESSION_APPLY=${CC_WJ_SESSION_APPLY} is not 1; reporting only" ;;
    esac
    if [ -n "${CC_WJ_SESSION_CWD_UNPARSED:-}" ]; then
      echo "worktree-janitor: no cwd could be parsed from the hook input, so this session's worktree is unknown; reporting only"
      apply_flag=""
    elif [ -n "${CC_WJ_SESSION_CWD:-}" ] && [ -z "$cwd" ]; then
      # A session that deleted the directory it stood in still owns the worktree around it,
      # and a path that no longer resolves cannot be kept by comparison.
      echo "worktree-janitor: the hook input's cwd ${CC_WJ_SESSION_CWD} does not resolve, so this session's worktree is unknown; reporting only"
      apply_flag=""
    fi
    # Out of every worktree, so this sweep's own working directory holds none of them.
    cd / || true
    CC_WJ_KEEP_PATH="$dir${cwd:+
$cwd}${CC_WJ_SESSION_DIR:+
$CC_WJ_SESSION_DIR}" _cc_wj_run --repo "$main" $apply_flag || rc=$?
  fi
  echo "== worktree-janitor session sweep ended $(date '+%Y-%m-%dT%H:%M:%S%z') elapsed=$(( $(date +%s) - t0 ))s free_before=$(_cc_wj_gib "$free0") free_after=$(_cc_wj_gib "$(_cc_wj_free_kb)") status=$rc"
  return 0
}

# ─── Entry point ─────────────────────────────────────────────────────────────

# launchd hands an agent PATH=/usr/bin:/bin:/usr/sbin:/sbin, and `gh` installs outside it,
# so the scheduled sweep could never prove landed=pr: measured 2026-09-23, 0 scheduled
# proofs against 54 from session sweeps. Appended, never prepended, as in disk-janitor, so a
# caller's toolchain and a test's stubs keep priority; only when executed, so a shell that
# sources this file keeps its own PATH. CC_WJ_TOOL_DIRS empty makes PATH the whole answer.
_cc_wj_append_tool_dirs() {
  local dir
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$PATH:$dir" ;;
    esac
  done <<< "$(printf '%s' "${CC_WJ_TOOL_DIRS-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin}" | tr ':' '\n')"
  export PATH
}

# Run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cc_wj_append_tool_dirs
  _cc_wj_run "$@"
fi
