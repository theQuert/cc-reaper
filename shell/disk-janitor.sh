#!/usr/bin/env bash
# disk-janitor: disk-space cleanup and monitoring for cc-reaper.
#
# Can be sourced for the _cc_dj_* functions or executed directly:
#   bash shell/disk-janitor.sh --check
#   bash shell/disk-janitor.sh --clean

_cc_dj_usage() {
  cat <<'EOF'
Usage: disk-janitor --check | --clean

Disk space monitoring and rebuildable-cache cleanup for cc-reaper.

Modes:
  --check   Read-only: measure disk free %, detect TM snapshot pins,
            notify when below threshold (cooldown-gated). No deletions.
  --clean   Delete rebuildable caches and thin TM snapshots when below
            threshold.

Options:
  -h, --help  Show this help

Environment:
  CC_DJ_DISK_MIN_PCT    Minimum free disk % before action (default: 15)
  CC_DJ_COOLDOWN_SECS   Seconds between repeat --check notifications (default: 3600)
  CC_DJ_LOG             Log file path (default: ~/.cc-reaper/logs/disk-janitor.log)
  CC_DJ_STATE_DIR       State directory path (default: ~/.cc-reaper/state/)
EOF
}

# ---------------------------------------------------------------------------
# Config defaults
# ---------------------------------------------------------------------------
CC_DJ_DISK_MIN_PCT="${CC_DJ_DISK_MIN_PCT:-15}"
CC_DJ_COOLDOWN_SECS="${CC_DJ_COOLDOWN_SECS:-3600}"
CC_DJ_LOG="${CC_DJ_LOG:-$HOME/.cc-reaper/logs/disk-janitor.log}"
CC_DJ_STATE_DIR="${CC_DJ_STATE_DIR:-$HOME/.cc-reaper/state/}"
# Abandoned scratch checkouts under the shared temp directory. Agents and review
# sessions copy or clone a repository there and nothing ever revisits it; measured
# 2026-08-31 on one host, twelve of them between 484 MB and 1.3 GB, 5.7 GB in total,
# the oldest three days untouched. macOS does not clear `/private/tmp` on any
# schedule a developer machine reaches - the periodic scripts are off by default and
# the boot-time sweep does not run on a host that stays up.
CC_DJ_TMP_DIRS="${CC_DJ_TMP_DIRS:-/private/tmp}"
# Applied to the whole SUBTREE, not to the top-level directory entry - see the
# staleness gate for why the difference is the whole finding.
CC_DJ_TMP_AGE_DAYS="${CC_DJ_TMP_AGE_DAYS:-3}"
# Below this a directory is not worth the risk of being wrong about it.
CC_DJ_TMP_MIN_MB="${CC_DJ_TMP_MIN_MB:-100}"
# Report only, unless an operator opts in. Every other `--clean` target is a NAMED
# cache at a KNOWN path whose owner documents how to rebuild it. This one is a
# heuristic over a world-writable directory, and age plus size plus "no open handle"
# does not establish that something is an abandoned checkout: an old application
# directory, an archive, a database, a mounted data directory all satisfy it. So the
# default is the half that cannot be wrong - say what is there, let a human decide -
# and the weekly unattended agent never deletes here unless told to.
# This target REPORTS and never removes, and there is no flag to change that.
#
# Every other `--clean` target is a named cache at a known path whose owner documents
# how to rebuild it. `/private/tmp` is a heuristic over a world-writable directory,
# and age plus size plus "no open handle" does not establish that something is an
# abandoned checkout - an old application directory, an archive, a database, a
# mounted data directory all satisfy it.
#
# A deletion path was written, gated behind an opt-in, then removed. It produced
# three CRITICAL review findings and most of the rest; roughly 300 lines existed to
# make safe a code path that was off by default; and it reclaimed nothing on the host
# that motivated it - the 5.7 GB found there was removed by hand, after reading the
# report. Seeing the accumulation is the half with no failure mode.

# launchd hands an agent PATH=/usr/bin:/bin:/usr/sbin:/sbin and nothing more unless the
# plist sets it, while Homebrew and Docker Desktop install outside that set. Resolving
# tools through the inherited environment therefore reports them absent, which is a fact
# about the caller and not about the machine. Measured here 2026-08-30: a weekly clean
# skipped go, yarn, brew, bun and docker - 21 GB of go build cache among them - and still
# ended on "clean: finished".
#
# Prepended rather than replaced, so an operator who has put a different toolchain ahead
# on PATH keeps it. `command -v` downstream then answers the same question for an agent
# and for an interactive shell.
# The list covers where the targets below actually install: Homebrew, Docker Desktop and
# pipx/uv under the first three, plus Bun's own installer (`$HOME/.bun/bin`) and the official
# Go macOS package (`/usr/local/go/bin`), neither of which lands anywhere else. A default
# list that misses a tool's standard location reproduces the bug it exists to fix.
#
# Appended, never prepended. Whatever the caller put on PATH keeps priority - an operator
# with their own toolchain, and a test sandbox shimming `docker` so a suite cannot reach
# the real daemon. Prepending would silently step over both, which is the same class of
# fault as the one being fixed. Set CC_DJ_TOOL_DIRS empty to make PATH the whole answer,
# which is how a test simulates a tool that is genuinely not installed.
CC_DJ_TOOL_DIRS="${CC_DJ_TOOL_DIRS-/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/go/bin}"
if [ -n "$CC_DJ_TOOL_DIRS" ]; then
  _cc_dj_dir=""
  while IFS= read -r _cc_dj_dir; do
    [ -n "$_cc_dj_dir" ] && [ -d "$_cc_dj_dir" ] || continue
    case ":$PATH:" in
      *":$_cc_dj_dir:"*) ;;
      *) PATH="$PATH:$_cc_dj_dir" ;;
    esac
  done <<< "$(printf '%s' "$CC_DJ_TOOL_DIRS" | tr ':' '\n')"
  unset _cc_dj_dir
fi
export PATH

# Targets that ran, and targets skipped because their tool did not resolve. A clean that
# skipped most of its work ended on the same line as one that did all of it, which is how
# five dead targets survived weeks of weekly runs.
CC_DJ_RAN=0
CC_DJ_SKIPPED=0
# Reset per run alongside the other two - see `_cc_dj_clean`. Initialised only at
# load time, one failure made every later `_cc_dj_clean` in the same shell report
# FAILED>0 and return non-zero with nothing wrong, which is how a real signal turns
# into one nobody reads.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_cc_dj_init_dirs() {
  mkdir -p "$(dirname "$CC_DJ_LOG")" || { echo "disk-janitor: cannot create log dir" >&2; return 1; }
  _cc_dj_bound_log "$CC_DJ_LOG"
  local agent
  for agent in disk-check weekly-clean; do
    _cc_dj_bound_log "$HOME/.cc-reaper/logs/launchd-$agent-stdout.log"
    _cc_dj_bound_log "$HOME/.cc-reaper/logs/launchd-$agent-stderr.log"
  done
  mkdir -p "$CC_DJ_STATE_DIR" || { echo "disk-janitor: cannot create log dir" >&2; return 1; }
}

# Bound a log to one live file plus one previous generation. cc-reaper reaps
# other tools for leaking; an unbounded log of its own is the same fault.
#
# Copy-then-truncate rather than rename: truncating keeps the inode, so a
# descriptor launchd already opened for StandardOutPath stays valid and keeps
# appending to the live file. A rename would leave launchd filling the ".old"
# copy while the live path stayed empty.
_cc_dj_bound_log() {
  local file=$1 max=${2:-1048576} size=""
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] && [ "$size" -gt "$max" ] || return 0
  cp -f "$file" "$file.old" 2>/dev/null && : > "$file" 2>/dev/null
  return 0
}

_cc_dj_log() {
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  printf "[%s] %s\n" "$ts" "$msg" | tee -a "$CC_DJ_LOG"
}

# Returns the integer free-disk percentage for the root filesystem.
_cc_dj_free_pct() {
  # macOS df -P: "Filesystem 1024-blocks Used Available Use% Mounted"
  # On modern macOS "/" is the sealed system snapshot (mostly empty — reads
  # ~93% free regardless of real usage); user data lives on
  # /System/Volumes/Data. Fall back to "/" where that mount doesn't exist.
  local vol="${CC_DJ_VOLUME:-/System/Volumes/Data}"
  [ -d "$vol" ] || vol="/"
  df -P "$vol" | awk 'NR==2 { gsub(/%/,"",$5); print 100 - $5 }'
}

# Free 1K-blocks on the same volume free_pct measures. Used to price a target from the
# delta across it: a target that freed 21 GB and one that did nothing logged the same
# "freed=?" before, and that is the distinction an operator needs.
#
# `-Pk`, not `-P`. POSIX leaves `-P` alone reporting 512-byte blocks and macOS does exactly
# that - `df -P` here prints a "512-blocks" header - so treating column 4 as KiB reported
# every saving at twice its real size. A number that is confidently wrong by 2x is worse
# than the "freed=?" it replaced, because it invites arithmetic.
_cc_dj_free_kb() {
  local vol="${CC_DJ_VOLUME:-/System/Volumes/Data}"
  [ -d "$vol" ] || vol="/"
  df -Pk "$vol" | awk 'NR==2 { print $4 }'
}

# Human-readable byte count from a 1K-block delta. Negative deltas happen - another
# process can write during a target - and are reported as 0 rather than as a negative
# saving, which would read as the target having consumed space.
_cc_dj_fmt_kb_delta() {
  local kb="$1"
  [ -n "$kb" ] || { printf '0B'; return; }
  [ "$kb" -gt 0 ] 2>/dev/null || { printf '0B'; return; }
  awk -v k="$kb" 'BEGIN{
    b=k*1024
    if (b>=1073741824) printf "%.1fG", b/1073741824
    else if (b>=1048576) printf "%.1fM", b/1048576
    else printf "%.0fK", b/1024
  }'
}

# One place that records a target as skipped, so the counter cannot drift from the log.
_cc_dj_skip() {
  CC_DJ_SKIPPED=$(( CC_DJ_SKIPPED + 1 ))
  _cc_dj_log "SKIP $*"
}

# Returns newline-separated list of TM snapshot date tokens (e.g. 2026-06-10-040000)
# Only matches com.apple.TimeMachine.<date>.local — never os.update names.
_cc_dj_tm_snapshots() {
  tmutil listlocalsnapshots / 2>/dev/null \
    | grep -E '^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.local$' \
    | sed 's/com\.apple\.TimeMachine\.\(.*\)\.local/\1/'
}

# Cooldown: returns 0 when notification is allowed (no state file or cooldown expired); 1 to suppress
_cc_dj_cooldown_ok() {
  local state_file="$CC_DJ_STATE_DIR/cooldown-disk"
  if [ ! -f "$state_file" ]; then
    return 0  # no prior record → allow
  fi
  local mtime now elapsed
  # mtime via stat — portable: macOS -f %m, Linux -c %Y
  mtime="$(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0)"
  now="$(date '+%s')"
  elapsed=$(( now - mtime ))
  if [ "$elapsed" -ge "$CC_DJ_COOLDOWN_SECS" ]; then
    return 0  # cooldown expired → allow
  fi
  return 1  # within cooldown → suppress
}

_cc_dj_cooldown_touch() {
  local state_file="$CC_DJ_STATE_DIR/cooldown-disk"
  touch "$state_file"
}

_cc_dj_notify() {
  local msg="$1"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  osascript -e "display notification \"$msg\" with title \"cc-reaper: disk-janitor\""
}

# ---------------------------------------------------------------------------
# --check mode
# ---------------------------------------------------------------------------
_cc_dj_check() {
  _cc_dj_init_dirs || return 1
  local free_pct
  free_pct="$(_cc_dj_free_pct)"
  _cc_dj_log "check: disk free=${free_pct}% threshold=${CC_DJ_DISK_MIN_PCT}%"

  local snapshots
  snapshots="$(_cc_dj_tm_snapshots)"
  if [ -n "$snapshots" ]; then
    _cc_dj_log "check: TM snapshots present:"
    while IFS= read -r s; do
      _cc_dj_log "  com.apple.TimeMachine.${s}.local"
    done <<< "$snapshots"
  fi

  # Reported on every check, not only below threshold. This is the one target whose
  # contents are somebody's abandoned work rather than a rebuildable cache, so the
  # operator gets to see it accumulating well before free space forces the question.
  _cc_dj_report_stale_tmp_dirs

  if [ "$free_pct" -lt "$CC_DJ_DISK_MIN_PCT" ]; then
    _cc_dj_log "check: BELOW threshold — free=${free_pct}% < ${CC_DJ_DISK_MIN_PCT}%"
    if [ -n "$snapshots" ]; then
      _cc_dj_log "check: TM snapshot pin detected; consider: tmutil thinlocalsnapshots / --clean"
    fi
    if _cc_dj_cooldown_ok; then
      _cc_dj_notify "disk free ${free_pct}% — run disk-janitor --clean"
      _cc_dj_cooldown_touch
      _cc_dj_log "check: notification sent (cooldown reset)"
    else
      _cc_dj_log "check: notification suppressed (within cooldown)"
    fi
  else
    _cc_dj_log "check: OK — free=${free_pct}% >= ${CC_DJ_DISK_MIN_PCT}%"
  fi
}

# ---------------------------------------------------------------------------
# --clean helpers
# ---------------------------------------------------------------------------

# Log bytes freed by a removal target (best-effort via du before removal).
# Usage: _cc_dj_du_bytes <path>  → prints integer bytes or "?"
_cc_dj_du_bytes() {
  local path="$1"
  if [ -e "$path" ]; then
    du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo "?"
  else
    echo "0"
  fi
}

# `_cc_dj_clean_target` logs a non-zero return and then returns success itself,
# because for a cache target "rc may be fine" is genuinely true. It is not true of
_cc_dj_clean_target() {
  local label="$1"
  shift
  # "$@" is the command to run
  _cc_dj_log "clean: running target '${label}'"
  local out rc=0 before after
  before="$(_cc_dj_free_kb)"
  out=$("$@" 2>&1) || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >> "$CC_DJ_LOG"
  after="$(_cc_dj_free_kb)"
  local freed
  freed="$(_cc_dj_fmt_kb_delta "$(( ${after:-0} - ${before:-0} ))")"
  CC_DJ_RAN=$(( CC_DJ_RAN + 1 ))
  if [ "$rc" -eq 0 ]; then
    _cc_dj_log "clean: target '${label}' done (freed=${freed})"
  else
    _cc_dj_log "clean: target '${label}' returned non-zero (rc=${rc}, may be fine, freed=${freed})"
  fi
}

# KiB, the unit the size floor is expressed in. `_cc_dj_du_bytes` exists but prints
# "?" on failure, and "?" in an arithmetic comparison is a syntax error, not a skip.
_cc_dj_du_kib() {
  # `head -1`, because `du -sk` echoes the path back and a path containing a newline
  # therefore produces two lines. The second one made this print `2048\nDocuments`,
  # `[ … -ge … ]` failed as "illegal number", and the candidate was dropped by a gate
  # that was supposed to be measuring its size. Safe direction, silent, and wrong.
  du -sk "$1" 2>/dev/null | head -1 | awk '{print $1 + 0; found=1} END {if (!found) print 0}'
}

# Emit one path per line: a directory directly under a temp root that is stale, large,
# unheld, and not something git still points at. Every gate is a reason to *skip*,
# because the failure mode here is deleting work, not leaving a cache behind - so the
# report and the clean share this one enumerator and no skip is silent.
#
# Deliberately not matched by name. A name pattern would have to guess which prefixes
# agents use, and the twelve found here shared no prefix at all.
# Is lsof usable at all? Its exit status cannot answer that: measured on macOS,
# `lsof -Fn +D` returns 1 both for a populated directory (42 result lines) and for an
# empty one, so a status check either skips always or never. Ask it something whose
# answer is known instead - this process has a working directory - and treat an lsof
# that cannot report that as an lsof that cannot report anything.
#
# A probe that has not been shown to see a positive case cannot be trusted when it
# reports nothing, and "nothing is held" is the single answer here that authorises
# `rm -rf`.
_cc_dj_lsof_usable() {
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -p "$$" -d cwd -Fn 2>/dev/null | grep -q '^n/' || return 1
  return 0
}

# Emit one NUL-terminated path per candidate: a directory directly under a temp root
# that is stale, large, unheld, and holds no git repository.
#
# NUL and not newline, all the way to the consumers. A newline-delimited contract
# re-creates at the reader the exact split this function works to avoid at the
# writer - `/private/tmp` is world-writable, and a directory may be called anything. Every gate is a reason to *skip*,
# because the failure mode here is deleting work, not leaving a cache behind.
#
# Diagnostics go to stderr, never stdout. This function's stdout IS the deletion
# list, so a log line written to it becomes a path somebody tries to remove.
#
# Deliberately not matched by name. A name pattern would have to guess which prefixes
# agents use, and the twelve found on the reporting host shared no prefix at all.
# A bare repository carries no `.git`; it IS the git directory. Checked by the three
# entries git itself requires, so an ordinary directory that happens to hold a file
# called `HEAD` does not qualify.
_cc_dj_looks_bare() {
  [ -f "$1/HEAD" ] && [ -d "$1/objects" ] && [ -d "$1/refs" ]
}

# Does any of these `HEAD` paths sit in a real bare repository?
# Does any of these `HEAD` paths sit in a real bare repository? Reads a NUL-delimited
# FILE, so a repository under a path containing a newline is confirmed as itself
# rather than as fragments that happen to name nothing.
_cc_dj_any_bare_parent() {
  local h
  while IFS= read -r -d '' h; do
    [ -n "$h" ] || continue
    _cc_dj_looks_bare "${h%/HEAD}" && return 0
  done < "$1"
  return 1
}

_cc_dj_stale_tmp_dirs() {
  local root root_real d d_parent d_real held cwd recent listing repo_hit head_hits min_kb age roots=()
  age="$CC_DJ_TMP_AGE_DAYS"
  min_kb=$(( CC_DJ_TMP_MIN_MB * 1024 ))

  # Read the fields rather than word-splitting an unquoted expansion: a configured
  # root containing a space was split into two nonexistent roots and skipped in
  # silence, which is the "clean machine" quiet this target exists to remove. The
  # unquoted form was also subject to globbing.
  local IFS=:
  read -ra roots <<< "$CC_DJ_TMP_DIRS"
  unset IFS

  for root in ${roots[@]+"${roots[@]}"}; do
    [ -n "$root" ] || continue
    if [ ! -d "$root" ] || [ ! -r "$root" ]; then
      echo "disk-janitor: temp root unusable, scanned nothing: $root" >&2
      continue
    fi
    if ! _cc_dj_lsof_usable; then
      echo "disk-janitor: lsof cannot report open files; skipped $root rather than assume nothing is held" >&2
      continue
    fi
    # One lsof for the whole root rather than one per directory: `+D` walks the tree,
    # and per-directory it is quadratic on exactly the hosts that need this most.
    # `-F0n`: NUL-terminated fields, so a field cannot be split by its own content.
    held="$(lsof -F0n +D "$root" 2>/dev/null | tr '\0' '\n' | sed -n 's/^n//p')"

    # NUL-delimited, through a FILE, and every candidate re-checked afterwards.
    #
    # `/private/tmp` is world-writable and a directory name may contain a newline. A
    # line-delimited listing split `$'\nDocuments'` into two candidates, the second
    # of them the bare relative path `Documents` - which a manual run from $HOME
    # would resolve against the wrong directory entirely, and whose open handles are
    # of course absent from an lsof inventory taken over /private/tmp.
    #
    # A file rather than `listing="$(find … -print0)"`, because command substitution
    # STRIPS NUL bytes: that version threw away the delimiters that made it safe and
    # split on newlines again, exactly as before. The file keeps the NULs and keeps
    # find's exit status, and both are load-bearing - one so a name cannot forge a
    # second candidate, the other so a failed listing is not read as an empty root.
    #
    # The root listing also gets the same treatment as everything else here: a `find`
    # that fails produces no directories, and "no directories" is indistinguishable
    # from "nothing to clean" unless somebody says so.
    root_real="$( (cd -P "$root" 2>/dev/null && pwd) || echo "$root" )"
    listing="$(mktemp "${TMPDIR:-/tmp}/cc-dj-list.XXXXXX")" || {
      echo "disk-janitor: could not create a work file, scanned nothing: $root" >&2
      continue
    }
    if ! find "$root" -maxdepth 1 -mindepth 1 -type d -print0 >"$listing" 2>/dev/null; then
      echo "disk-janitor: could not list temp root, scanned nothing: $root" >&2
      rm -f "$listing"
      continue
    fi

    while IFS= read -r -d '' d; do
      [ -n "$d" ] || continue
      # Belt and braces: whatever the traversal produced, act only on something that
      # really is a direct child of the root we were asked to scan.
      case "$d" in "$root"/*) ;; *) continue ;; esac
      d_parent="$( (cd -P "$d/.." 2>/dev/null && pwd) || echo "" )"
      [ "$d_parent" = "$root_real" ] || continue

      # Any git repository anywhere in the candidate, and bare ones too.
      #
      # `-f "$d/.git"` matched a gitfile alone, so a plain clone - whose `.git` is a
      # directory, and whose unpushed commits exist nowhere else - passed the one
      # gate meant to catch it, while a linked worktree whose commits survive on a
      # branch was caught. Backwards. `-e "$d/.git"` then fixed the clone but still
      # only looked at the top level, so `/private/tmp/session/repo/.git` was invisible
      # and the whole container went; and a bare repository has no `.git` at all.
      #
      # Bounded to depth 3: a scratch checkout parks its repository at the top or one
      # or two levels down, and an unbounded walk here runs over every candidate on
      # every check. A find that FAILS keeps the candidate, for the same reason as
      # everywhere else in this function.
      if ! repo_hit="$(find "$d" -maxdepth 3 -name .git -print -quit 2>/dev/null)"; then
        echo "disk-janitor: could not scan for git repositories, kept: $d" >&2
        continue
      fi
      [ -n "$repo_hit" ] && continue

      # Bare repositories, at the top level and nested. A bare repo has no `.git` for
      # the search above to find, and checking only `$d` missed `$d/session/repo.git`
      # - an old, large, unheld candidate whose unique commits would go with it.
      #
      # Found by STRUCTURE, not by name. The `.git` suffix is a convention and
      # nothing enforces it - `git init --bare repo` produces a perfectly ordinary
      # `repo/`, which a name filter walks straight past. The search is for the `HEAD`
      # file every git directory has, and each hit is confirmed by the three entries
      # git actually requires, which is also what stops a stray file called HEAD from
      # pinning a candidate forever.
      _cc_dj_looks_bare "$d" && continue
      # `-print0` into a file, for the same reason the root listing uses one: command
      # substitution strips NULs, and `-print` alone lets a path split itself so the
      # confirmation runs against fragments rather than against the repository.
      head_hits="$(mktemp "${TMPDIR:-/tmp}/cc-dj-heads.XXXXXX")" || {
          echo "disk-janitor: could not create a work file, kept: $d" >&2
        continue
      }
      if ! find "$d" -maxdepth 4 -type f -name HEAD -print0 >"$head_hits" 2>/dev/null; then
          echo "disk-janitor: could not scan for bare repositories, kept: $d" >&2
        rm -f "$head_hits"
        continue
      fi
      if _cc_dj_any_bare_parent "$head_hits"; then rm -f "$head_hits"; continue; fi
      rm -f "$head_hits"

      # Staleness is a property of the subtree, not of the directory entry. A
      # directory's mtime advances only when its DIRECT entries change, so a
      # container whose children are written to constantly still reads as stale.
      # `/private/tmp/claude-501` on the reporting host is exactly that: the
      # scratchpad root for every live session, its mtime moving only when a new
      # project appears, 720 MB of in-use files that the top-level test called
      # three days idle.
      #
      # `-mtime -N`, not `-newermt "-N days"`. POSIX `-mtime` works in BSD find, GNU
      # find and bfs alike; the relative-timestamp form is a GNU extension that bfs
      # - a drop-in `find` many developers have on PATH - rejects outright. Measured
      # on the reporting host: the gate errored, printed nothing, and an empty result
      # reads as "nothing recent here", which is the answer that authorises deletion.
      # `/private/tmp/claude-501`, 720 MB of live session scratchpads, was left
      # standing only by the lsof gate behind it.
      #
      # A find that FAILS keeps the directory. Empty output from a failed probe is
      # not evidence that the tree is idle, and this is the check standing between a
      # live tree and `rm -rf`.
      if ! recent="$(find "$d" -mtime -"$age" -print -quit 2>/dev/null)"; then
        echo "disk-janitor: could not test staleness, kept: $d" >&2
        continue
      fi
      [ -n "$recent" ] && continue

      # Prefix match on the literal string. `grep "^$d_real\(/\|$\)"` put an
      # unescaped path into a regex: `/private/tmp/foo*` became `fo` + zero-or-more
      # `o`, matched nothing, and a directory a process held open was emitted for
      # deletion. `/private/tmp` is world-writable, so nothing constrains the names
      # in it. `.`, `+` and `[1]` merely over-matched - wrong in the safe direction -
      # but `*` and an unmatched `[` fail toward deleting.
      # A name lsof would escape cannot be checked against its inventory, so it is
      # never cleared. macOS lsof reports `weird<LF>name` as the eight characters
      # `weird\nname`, so the comparison below never matches the real path and the
      # directory reads as unheld. Nothing is deleted here any more, but a report
      # that names a tree somebody is actively using is a report people stop reading.
      case "$d" in
        *[$'\n\t\r\\']*)
          echo "disk-janitor: name cannot be matched against lsof output, kept: $d" >&2
          continue ;;
      esac
      d_real="$( (cd -P "$d" 2>/dev/null && pwd) || echo "$d" )"
      local skip=0
      while IFS= read -r cwd; do
        [ -n "$cwd" ] || continue
        case "$cwd" in
          "$d_real"|"$d_real"/*) skip=1; break ;;
        esac
      done <<EOF
$held
EOF
      [ "$skip" -eq 1 ] && continue

      [ "$(_cc_dj_du_kib "$d")" -ge "$min_kb" ] 2>/dev/null || continue
      printf '%s\0' "$d"
    done < "$listing"
    rm -f "$listing"
  done
}

_cc_dj_report_stale_tmp_dirs() {
  local d n=0 kb=0
  while IFS= read -r -d '' d; do
    [ -n "$d" ] || continue
    n=$(( n + 1 )); kb=$(( kb + $(_cc_dj_du_kib "$d") ))
    _cc_dj_log "check: stale temp checkout ${d} ($(_cc_dj_du_bytes "$d") bytes)"
  done < <(_cc_dj_stale_tmp_dirs)
  [ "$n" -gt 0 ] && _cc_dj_log "check: ${n} stale temp checkout(s), $(( kb / 1024 )) MB — review them and remove by hand; --clean does not touch these"
  return 0
}

_cc_dj_clean_dir() {
  local label="$1"
  local path="$2"
  [ -z "$path" ] && { _cc_dj_log "SKIP ${label} (empty path)"; return 0; }
  if [ ! -e "$path" ]; then
    _cc_dj_skip "${label} (path not found: ${path})"
    return
  fi
  # Two numbers, because they answer different questions and their gap is informative.
  # `du` says how large the directory was; the free-space delta says how much the volume
  # actually got back. They diverge when a process still holds a deleted file open - the
  # blocks are not reclaimed until it closes - so reporting only `du` overstates the
  # saving, which is the failure this target's accounting was added to prevent. The
  # command targets already measure the delta; this one now measures the same way.
  local bytes before after freed
  bytes="$(_cc_dj_du_bytes "$path")"
  before="$(_cc_dj_free_kb)"
  rm -rf "$path"
  after="$(_cc_dj_free_kb)"
  freed="$(_cc_dj_fmt_kb_delta "$(( ${after:-0} - ${before:-0} ))")"
  CC_DJ_RAN=$(( CC_DJ_RAN + 1 ))
  _cc_dj_log "clean: removed '${label}' size=${bytes} bytes freed=${freed}"
}

# Dangling images: built layers no tag points at any more. `-f dangling=true` is a
# filter, not a prune verb - it enumerates, and each id is passed to `rmi` explicitly, so
# a tagged image cannot be reached however the inventory changes between calls.
_cc_dj_docker_rmi_dangling() {
  # The inventory's own status is checked before its output is believed. If the daemon
  # goes away after the `docker info` probe, `docker images` fails and prints nothing, and
  # reading that as "no dangling images" reports a target as done when nothing was
  # examined - the same fault as the swallowed `rmi` status, one command earlier.
  local ids ls_rc=0
  ids="$(docker images -f dangling=true -q 2>/dev/null)" || ls_rc=$?
  if [ "$ls_rc" -ne 0 ]; then
    echo "docker images failed (rc=$ls_rc); nothing examined"
    return "$ls_rc"
  fi
  ids="$(printf '%s\n' "$ids" | sort -u)"
  [ -n "$ids" ] || { echo "no dangling images"; return 0; }
  # The pipeline's status must be docker's, not tail's: an image that became referenced
  # between the inventory and the removal makes `rmi` fail, and swallowing that reported a
  # failed cleanup as `done`, which is the exact fault this change exists to remove.
  # Output is captured before it is trimmed. Piping the command group into `tail` would put
  # the group in a subshell, where the status assignment is lost - the fix has to survive
  # the shape of the pipeline, not just be written down.
  local out rc=0
  # shellcheck disable=SC2086
  out="$(docker rmi $ids 2>&1)" || rc=$?
  printf '%s\n' "$out" | tail -40
  return "$rc"
}

# Unreferenced volumes with docker-generated-looking names: 64 lowercase hex characters,
# referenced by no container.
#
# Reported, never removed. The name is the only signal available - `docker volume inspect`
# exposes no "anonymous" flag, and a user-created volume carries the same empty Labels and
# Options as a daemon-created one - and `docker volume create <name>` accepts a 64-hex name
# from anyone. So the name cannot establish provenance, an unreferenced volume is not the
# same as an abandoned one, and deleting on that inference risks persistent data for space
# an operator can reclaim by hand in one command.
#
# Reporting is not a lesser version of this target, it is the correct one. The premise of
# this change is that a janitor which cannot see is indistinguishable from a clean machine;
# what it is not is a licence to act on what it cannot establish.
_cc_dj_docker_report_dead_anon_volumes() {
  # Same reason as the image inventory: an empty volume list from a dead daemon is
  # indistinguishable from a machine with no volumes unless the producer's status is kept.
  local names ls_rc=0
  names="$(docker volume ls --format '{{.Name}}' 2>/dev/null)" || ls_rc=$?
  if [ "$ls_rc" -ne 0 ]; then
    echo "docker volume ls failed (rc=$ls_rc); nothing examined"
    return "$ls_rc"
  fi
  local dead
  dead="$(printf '%s\n' "$names" | python3 -c '
import json, re, subprocess, sys

names = [n.strip() for n in sys.stdin if n.strip()]
anon = [n for n in names if re.fullmatch(r"[0-9a-f]{64}", n)]
if not anon:
    sys.exit(0)

# Every producer is checked before its output is believed. An unreadable container
# inventory yields an empty reference set, and an empty reference set makes every
# such volume look unreferenced. Silence is never read as "nothing".
ps = subprocess.run(["docker", "ps", "-aq"], capture_output=True, text=True)
if ps.returncode != 0:
    sys.exit(1)
ids = ps.stdout.split()
used = set()
if ids:
    ins = subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True)
    if ins.returncode != 0:
        sys.exit(1)
    try:
        parsed = json.loads(ins.stdout or "[]")
    except ValueError:
        sys.exit(1)
    if len(parsed) != len(ids):
        sys.exit(1)
    for c in parsed:
        for m in c.get("Mounts") or []:
            if m.get("Name"):
                used.add(m["Name"])

# chr(10), not an escape. This python is nested inside a shell single-quoted string
# inside a command substitution, and an escaped newline survives that stack as a literal
# backslash-n: the whole list became one physical line and `grep -c .` reported 1 no
# matter how many volumes there were - wrong exactly when the count starts to matter.
print(chr(10).join(n for n in anon if n not in used))
')" || { echo "container inventory unreadable; reporting nothing"; return 1; }
  [ -n "$dead" ] || { echo "no unreferenced anonymous-looking volumes"; return 0; }
  local count
  count="$(printf '%s\n' "$dead" | grep -c .)"
  echo "$count unreferenced volumes with docker-generated-looking names; not removed"
  echo "  a 64-hex name can also be one you chose, so review before removing:"
  echo "  docker volume ls --format '{{.Name}}' | grep -E '^[0-9a-f]{64}\$'"
  return 0
}

# ---------------------------------------------------------------------------
# --clean mode
# ---------------------------------------------------------------------------
_cc_dj_clean() {
  _cc_dj_init_dirs || return 1
  # Per run, not per source. This file is meant to be sourced, and counters initialised only
  # at load time make a second `_cc_dj_clean` in the same shell report cumulative totals -
  # the accounting added to make a skipped run legible would itself become wrong.
  CC_DJ_RAN=0
  CC_DJ_SKIPPED=0
  local free_before free_after
  free_before="$(_cc_dj_free_pct)"
  _cc_dj_log "clean: starting — disk free=${free_before}%"

  # -- go clean -cache -------------------------------------------------------
  if command -v go >/dev/null 2>&1; then
    _cc_dj_clean_target "go clean -cache" go clean -cache
  else
    _cc_dj_skip "go clean -cache (go not found)"
  fi

  # -- yarn cache clean -------------------------------------------------------
  if command -v yarn >/dev/null 2>&1; then
    _cc_dj_clean_target "yarn cache clean" yarn cache clean
  else
    _cc_dj_skip "yarn cache clean (yarn not found)"
  fi

  # -- pip3 cache purge -------------------------------------------------------
  if command -v pip3 >/dev/null 2>&1; then
    _cc_dj_clean_target "pip3 cache purge" pip3 cache purge
  else
    _cc_dj_skip "pip3 cache purge (pip3 not found)"
  fi

  # -- brew cleanup -s --------------------------------------------------------
  if command -v brew >/dev/null 2>&1; then
    _cc_dj_clean_target "brew cleanup -s" brew cleanup -s
  else
    _cc_dj_skip "brew cleanup -s (brew not found)"
  fi

  # -- bun pm cache rm --------------------------------------------------------
  if command -v bun >/dev/null 2>&1; then
    _cc_dj_clean_target "bun pm cache rm" bun pm cache rm
  else
    _cc_dj_skip "bun pm cache rm (bun not found)"
  fi

  # -- Spotify cache ----------------------------------------------------------
  local spotify_cache="$HOME/Library/Caches/com.spotify.client"
  _cc_dj_clean_dir "Spotify cache" "$spotify_cache"

  # -- ToDesktop ShipIt cache -------------------------------------------------
  local todesktop_cache="$HOME/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"
  _cc_dj_clean_dir "ToDesktop ShipIt cache" "$todesktop_cache"

  # -- CoreSimulator caches ---------------------------------------------------
  local sim_cache="$HOME/Library/Developer/CoreSimulator/Caches"
  _cc_dj_clean_dir "CoreSimulator caches" "$sim_cache"

  # -- docker: dangling images and unreferenced anonymous volumes -------------
  #
  # Not `docker system prune -af`. That removes every image no running container holds,
  # which on a development host reaches images that take hours to rebuild and pinned
  # versions kept on purpose - neither of which "rebuilds automatically on next use",
  # the property every other target here satisfies. Until 2026-08-30 this line was
  # `prune -af` and had never fired only because launchd's PATH hid the docker binary;
  # repairing that PATH without replacing this would have armed it.
  #
  # What is removed instead is addressed by id, computed from the current inventory, and
  # provably unreachable: a dangling image carries no tag. Volumes are reported and never
  # removed - see `_cc_dj_docker_report_dead_anon_volumes` for why a 64-hex name cannot
  # establish that docker, rather than an operator, chose it.
  if ! command -v docker >/dev/null 2>&1; then
    _cc_dj_skip "docker cleanup (docker not found)"
  elif ! docker info >/dev/null 2>&1; then
    _cc_dj_skip "docker (daemon unreachable)"
  else
    _cc_dj_clean_target "docker dangling images" _cc_dj_docker_rmi_dangling
    # The volume report needs python3, which macOS does not ship without Command Line
    # Tools. Declared here rather than left to fail inside the target: a missing
    # interpreter makes it exit 127, and `_cc_dj_clean_target` counts a failed command as
    # one that ran - so the summary would report `skipped=0` for a run whose volume
    # inventory never happened. That is the shape of false success this change exists to
    # remove, so the dependency is named and counted.
    if command -v python3 >/dev/null 2>&1; then
      _cc_dj_clean_target "docker unreferenced volumes (report only)" \
        _cc_dj_docker_report_dead_anon_volumes
    else
      _cc_dj_skip "docker unreferenced volumes report (python3 not found)"
    fi
  fi

  # -- TM snapshot thinning (only when below threshold) ----------------------
  free_after="$(_cc_dj_free_pct)"
  if [ "$free_after" -lt "$CC_DJ_DISK_MIN_PCT" ]; then
    local snapshots
    snapshots="$(_cc_dj_tm_snapshots)"
    if [ -n "$snapshots" ]; then
      _cc_dj_log "clean: disk still below threshold (${free_after}% < ${CC_DJ_DISK_MIN_PCT}%), thinning TM snapshots"
      local df_before df_after
      local vol="${CC_DJ_VOLUME:-/System/Volumes/Data}"
      [ -d "$vol" ] || vol="/"
      df_before="$(df -P "$vol" | awk 'NR==2{print $4}')"
      while IFS= read -r date_token; do
        _cc_dj_log "clean: deleting TM snapshot ${date_token}"
        tmutil deletelocalsnapshots "$date_token"
      done <<< "$snapshots"
      df_after="$(df -P "$vol" | awk 'NR==2{print $4}')"
      local freed_blocks=$(( df_after - df_before ))
      _cc_dj_log "clean: TM thinning done freed_blocks=${freed_blocks}"
    else
      _cc_dj_log "clean: no TM snapshots to thin"
    fi
  else
    _cc_dj_log "clean: disk free=${free_after}% >= threshold — skipping TM snapshot thinning"
  fi

  free_after="$(_cc_dj_free_pct)"
  # The counts are on this line because their absence is what let five dead targets run
  # weekly for weeks: a clean that skipped most of its work and one that did all of it
  # both ended on "clean: finished - disk free=16%".
  if [ "$CC_DJ_SKIPPED" -gt 0 ]; then
    _cc_dj_log "clean: finished — disk free=${free_after}% — ran=${CC_DJ_RAN} SKIPPED=${CC_DJ_SKIPPED} (a skipped target cleaned nothing)"
  else
    _cc_dj_log "clean: finished — disk free=${free_after}% — ran=${CC_DJ_RAN} skipped=0"
  fi
}

# ---------------------------------------------------------------------------
# Entry point (only when executed, not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --check)
      _cc_dj_check
      ;;
    --clean)
      _cc_dj_clean
      ;;
    -h|--help)
      _cc_dj_usage
      exit 0
      ;;
    *)
      _cc_dj_usage >&2
      exit 1
      ;;
  esac
fi
