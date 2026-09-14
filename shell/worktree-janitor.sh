#!/usr/bin/env bash
# worktree-janitor: read-only inventory and optional cleanup of stale git worktrees.
#
# Can be sourced for the _cc_wj_* functions or executed directly:
#   bash shell/worktree-janitor.sh
#   bash shell/worktree-janitor.sh --apply

_cc_wj_usage() {
  cat <<'EOF'
Usage: worktree-janitor [options]

Inventory and optionally remove stale git worktrees across local repos.

Options:
  --apply             Remove REMOVABLE worktrees (default: report only)
  --repo <path>       Scan only this repo (repeatable; replaces auto-discovery)
  --session           Sweep the repository of CLAUDE_PROJECT_DIR, detached (SessionEnd hook)
  -h, --help          Show this help

Environment:
  CC_WJ_ROOT              Root directory to discover repos under (default: ~/Documents/GitHub)
  CC_WJ_LOG               Log file path (default: ~/.cc-reaper/logs/worktree-janitor.log)
  CC_WJ_STATE_DIR         State directory for cooldown files (default: ~/.cc-reaper/state)
  CC_WJ_IDLE_HOURS        Keep a worktree modified within this many hours (default: 6)
  CC_WJ_NOTIFY_MIN_GB     Disk savings threshold in GB to trigger notification (default: 1)
  CC_WJ_COOLDOWN_SECS     Notification cooldown in seconds (default: 3600)
  CC_WJ_BASE_BRANCH       Integration branch (default: origin's default branch)
  CC_WJ_SESSION_APPLY     Set to 1 to let --session remove (default: report only)
  CC_WJ_SESSION_LOG       --session log (default: ~/.cc-reaper/logs/worktree-janitor-session.log)

A worktree is removable only when it holds nothing a command cannot rebuild, no process
has it as a working directory or holds a file in it, its work has landed on the fetched
base branch, and nothing in it changed within CC_WJ_IDLE_HOURS. Branches are never deleted.
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
  local v="${CC_WJ_IDLE_HOURS:-6}"
  case "$v" in
    ''|*[!0-9]*|??????*) return 1 ;;
  esac
  echo $((10#$v))
}

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
  done < <(_cc_wj_roots)
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
}

# ─── Holders ──────────────────────────────────────────────────────────────────

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
# In a UTF-8 locale when one exists, and the locale used is recorded in $1/locale. lsof
# prints every byte its locale does not consider printable as `\xNN` - measured in the C
# locale, which is what a hook or launchd usually inherits: `caf\xc3\xa9` - and a match
# against git's raw spelling of the path then finds no holder at all.
_cc_wj_utf8_locale() {
  locale -a 2>/dev/null | grep -i -m 1 -E '^(C|en_US)\.utf-?8$'
}

_cc_wj_scan_holders() {
  local dir="$1" loc
  command -v lsof >/dev/null 2>&1 || return 1
  loc="$(_cc_wj_utf8_locale)"
  printf '%s' "$loc" > "$dir/locale"
  _cc_wj_with_timeout 60 env LC_ALL="${loc:-C}" lsof -n -P -d cwd -Fn > "$dir/cwd.raw" 2>/dev/null || return 1
  _cc_wj_with_timeout 120 env LC_ALL="${loc:-C}" lsof -n -P -Fn > "$dir/open.raw" 2>/dev/null || return 1
  sed -n 's/^n//p' "$dir/cwd.raw" > "$dir/cwd"
  sed -n 's/^n//p' "$dir/open.raw" > "$dir/open"
  [ -s "$dir/cwd" ] && [ -s "$dir/open" ]
}

# Whether a scan in $1 names worktree $2, or anything under it, by either spelling: git
# records the path a worktree was added with, lsof reports the physical one, and on macOS
# those differ under /var and /tmp.
#
# A path lsof would not print the way git spells it counts as held, because no match is
# possible: lsof doubles a backslash and escapes control characters in every locale, and
# escapes every non-ASCII byte when no UTF-8 locale was available for the scan.
_cc_wj_held() {
  local dir="$1" wt="${2%/}" p
  for p in "$wt" "$(_cc_wj_realpath "$wt")"; do
    p="${p%/}"
    [ -n "$p" ] || continue
    case "$p" in *\\*) return 0 ;; esac
    printf '%s' "$p" | LC_ALL=C grep -q '[[:cntrl:]]' && return 0
    if [ ! -s "$dir/locale" ] && printf '%s' "$p" | LC_ALL=C grep -q '[^ -~]'; then
      return 0
    fi
    grep -qxF -- "$p" "$dir/cwd" "$dir/open" 2>/dev/null && return 0
    grep -qF -- "$p/" "$dir/cwd" "$dir/open" 2>/dev/null && return 0
  done
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
  set -- "$wt"
  for f in HEAD index logs; do
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

  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-worktrees.XXXXXX")" || return
  if ! git -C "$repo" worktree list --porcelain -z > "$sf" 2>/dev/null; then
    rm -f "$sf"
    return
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

# Whether repository-relative path $1 is declared. Unquoted patterns on purpose - they
# are globs, and `$pat/*` lets a declared directory cover what is inside it. zsh does not
# treat an expanded parameter as a pattern unless told to.
_cc_wj_declared() {
  local p="$1" pat
  [ -n "$_CC_WJ_DECLARED" ] || return 1
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options glob_subst
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$p" in $pat|$pat/*) return 0 ;; esac
  done <<DECL
$_CC_WJ_DECLARED
DECL
  return 1
}

# A declared ignored directory: 0 disposable, 1 not declared, 2 declared but holding a
# credential-shaped file. A build copies `.env` into its output at whatever depth it
# likes, so a declared directory is searched to the bottom, package trees aside.
_cc_wj_declared_dir() {
  local wt="$1" d="$2"
  [ -n "$_CC_WJ_DECLARED" ] || return 1
  if _cc_wj_declared "$d"; then
    _cc_wj_find_credential "$wt/$d" && return 2
    return 0
  fi
  _cc_wj_declared_contents "$wt" "$d"
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
# with a wildcard must spell two consecutive characters outside its wildcards and bracket
# expressions: `*`, `*.*`, `*e*`, `a*` and `[!.]*` name nothing in particular and would
# discount hand-written notes along with the logs. `*.o` and `db/*` pass, and a pattern
# with no wildcard names exactly one path.
_cc_wj_names_a_path() {
  # A POSIX class leaves `]]` behind once its brackets are stripped, which counted as two
  # literal characters: `[[:alpha:]][[:alpha:]]*` passed and matched every longer path.
  awk -v want="$1" 'NF { s = $0; gsub(/\[[^]]*\]/, "", s)
    ok = ($0 !~ /\[:/) && (($0 !~ /[*?[]/) || (s ~ /[^*?][^*?]/))
    if (ok == want) print }'
}

# One report line for an entry that keeps the worktree. Tabs and newlines in a name would
# break the inventory line that carries it, so they are shown as `?`.
_cc_wj_pin() {
  local line="$1 $2"
  line="${line//$'\t'/?}"
  printf '%s\n' "${line//$'\n'/?}"
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
_cc_wj_pins() {
  local wt="$1" sf rec code rest base skip_next=0 drc
  sf="$(mktemp "${TMPDIR:-/tmp}/cc-wj-status.XXXXXX")" || {
    _cc_wj_pin '??' "(no temporary file to read its status into)"; return 1; }
  # No optional locks, so a user's concurrent commit never meets this scan's index.lock
  # and the index the idle gate reads is not rewritten; no fsmonitor, so no daemon starts
  # inside the worktree and shows up as its holder.
  if ! git --no-optional-locks -c core.fsmonitor=false -C "$wt" status --porcelain --ignored -z > "$sf" 2>/dev/null; then
    rm -f "$sf"
    _cc_wj_pin '??' "(git status failed)"
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
        case "$drc" in
          0) ;;
          2) _cc_wj_pin '!!' "$rest/ (declared, but holds a credential-shaped file)" ;;
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
        if _cc_wj_declared "$rest" && ! _cc_wj_sensitive_name "$base"; then
          continue
        fi
        _cc_wj_pin '!!' "$rest"
        ;;
    esac
  done < "$sf"
  rm -f "$sf"
  return 0
}

# Count the entries a removal would destroy that nothing is known to rebuild.
_cc_wj_undiscounted_count() {
  local out
  out="$(_cc_wj_pins "$1")"
  if [ -z "$out" ]; then
    echo 0
  else
    printf '%s\n' "$out" | wc -l | tr -d ' '
  fi
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
  local repo="$1" base="${CC_WJ_BASE_BRANCH:-}" all dropped
  _CC_WJ_BASE=""; _CC_WJ_BASE_OK=0; _CC_WJ_BASE_WHY=""; _CC_WJ_DECLARED=""
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
  if ! _cc_wj_with_timeout 60 git -C "$repo" fetch --quiet --no-tags origin \
       "+refs/heads/${base}:refs/remotes/origin/${base}" >/dev/null 2>&1; then
    _CC_WJ_BASE_WHY="origin/$base could not be fetched"
    return 1
  fi
  _CC_WJ_BASE_OK=1

  # A leading or trailing `/` is dropped, so `/logs/` means `logs`. `#` starts a comment at
  # the start of a line and after whitespace, so `logs  # runtime` does not declare a path
  # nobody has. These are shell globs, not .gitignore patterns: `*` matches across `/`.
  all="$(git -C "$repo" show "refs/remotes/origin/${base}:.worktree-regenerable" 2>/dev/null |
         sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]][[:space:]]*#.*$//' \
             -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
             -e 's#^/*##' -e 's#/*$##')"
  # A negation cannot be honoured - a case glob has no "except" - and dropping just that
  # line would widen what the rest of the file discounts: `logs` then `!logs/keep.md`
  # still deletes the file its author protected. So the whole file is set aside.
  if printf '%s\n' "$all" | grep -q '^!'; then
    echo "worktree-janitor: $repo: .worktree-regenerable on origin/$base uses a negation (!), which is not supported; none of it was applied"
    return 0
  fi
  _CC_WJ_DECLARED="$(printf '%s\n' "$all" | _cc_wj_names_a_path 1)"
  dropped="$(printf '%s\n' "$all" | _cc_wj_names_a_path 0 | tr '\n' ' ')"
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
  elif _cc_wj_landed_by_pr "$wt" "$ref"; then
    echo pr
  else
    echo no
  fi
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
  local wt="$1" ref="$2" head url host slug rest merges mc
  command -v gh >/dev/null 2>&1 || return 1
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || return 1
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
  merges="$(_cc_wj_with_timeout 30 gh api --hostname "$host" "repos/$slug/commits/$head/pulls" \
     --paginate \
     --jq ".[] | select(.merged_at != null and .base.ref == \"$_CC_WJ_BASE\" and .head.sha == \"$head\") | .merge_commit_sha" \
     2>/dev/null)" || return 1
  [ -n "$merges" ] || return 1
  while IFS= read -r mc; do
    [ -n "$mc" ] || continue
    git -C "$wt" merge-base --is-ancestor "$mc" "$ref" 2>/dev/null && return 0
  done <<MERGES
$merges
MERGES
  return 1
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

  case "$landed" in
    ancestor|content|pr) ;;
    unfetched) echo "KEEP(base-unfetched)"; return ;;
    *) echo "KEEP(unlanded)"; return ;;
  esac

  case "$idle" in
    yes) ;;
    no) echo "KEEP(recent-activity)"; return ;;
    *) echo "KEEP(idle-unknown)"; return ;;
  esac

  # Removal takes the checkout and leaves the branch, so a branch's commits survive it.
  # A detached HEAD's do not: nothing references them once the worktree is gone. Landed by
  # ancestry puts them on the base; landed by content or PR puts only their change there.
  if [ "$branch" = "(detached)" ] && [ "$landed" != "ancestor" ]; then
    echo "KEEP(detached-head)"
    return
  fi

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

# ─── Removal ──────────────────────────────────────────────────────────────────

# Remove a single worktree, never with force. Ignored residue does not stop a plain
# removal; what does - an untracked file, a lock, a submodule appearing in the moment
# before - is exactly what force would destroy, and a status check that failed used to read
# as "nothing there" and authorise it.
_cc_wj_remove_worktree() {
  local repo="$1"
  local wt_path="$2"

  _cc_wj_log_write "removing worktree: $wt_path (repo: $repo)"

  if git -C "$repo" worktree remove "$wt_path" 2>/dev/null; then
    _cc_wj_log_write "removed: $wt_path"
    return 0
  fi

  _cc_wj_log_write "FAILED to remove (git refused): $wt_path"
  return 1
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
  echo "$$" > "$1/pid"
  ps -o command= -p "$$" > "$1/cmd" 2>/dev/null
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
  elif { [ -z "$holder" ] || [ -z "$recorded" ]; } &&
       [ -z "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    live=1   # a sweep between its mkdir and its writes
  fi
  if [ "$live" -eq 1 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    echo "worktree-janitor: pid ${holder:-?} has held $lock for over 60 minutes; taking it over"
    live=0
  fi
  if [ "$live" -eq 1 ]; then
    echo "worktree-janitor: another worktree-janitor sweep${holder:+ (pid $holder)} holds $lock; removed nothing in this repository"
    return 1
  fi
  rm -f "$lock/pid" "$lock/cmd"
  rmdir "$lock" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    echo "worktree-janitor: the sweep lock $lock could not be taken; removed nothing in this repository"
    return 1
  fi
  _cc_wj_lock_write "$lock"
}

# Released only while it is still ours: after a takeover it belongs to somebody else.
_cc_wj_unlock() {
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] && rm -f "$1/pid" "$1/cmd" && rmdir "$1" 2>/dev/null
  return 0
}

# ─── Main report/apply logic ─────────────────────────────────────────────────

_cc_wj_run() {
  # The scheduled agent's stdout/stderr pair is written by launchd, so no script owns it
  # unless one claims it. Bounded here, at the top of every run, rather than from
  # `_cc_wj_log_write`: a report-only run never calls that helper - every call site is in
  # removal, pruning, or the apply-only summary - so bounding from there was unreachable
  # for the one caller that produces these files daily.
  local agent_log
  for agent_log in "$HOME/.cc-reaper/logs/launchd-worktree-report-stdout.log" \
                   "$HOME/.cc-reaper/logs/launchd-worktree-report-stderr.log"; do
    _cc_wj_bound_log "$agent_log"
  done

  local apply=0
  local explicit_repos=()

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)
        apply=1
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
      --session)
        _cc_wj_session
        return $?
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

  local idle_hours
  if ! idle_hours="$(_cc_wj_idle_hours)"; then
    echo "worktree-janitor: CC_WJ_IDLE_HOURS=${CC_WJ_IDLE_HOURS:-} is not a whole number of hours below 100000; scanned and removed nothing" >&2
    return 2
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
    while IFS= read -r r; do
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
  local prune_repos=()

  # Holder scans, taken once per run into files and taken again right before each removal.
  local work LSOF_OK="yes"
  work="$(mktemp -d "${TMPDIR:-/tmp}/cc-wj.XXXXXX")" || {
    echo "worktree-janitor: no temporary directory for the process scan; scanned and removed nothing" >&2
    return 1
  }
  if ! _cc_wj_scan_holders "$work"; then
    LSOF_OK="no"
    echo "worktree-janitor: the process scan failed or saw nothing, so no worktree can be shown unheld" >&2
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

  local repo lock skipped=0
  # Declared once, outside the loop: zsh prints the value of an already-set local that is
  # declared again.
  local active landed idle classification wt_phys git_keep head0 bytes kp
  for repo in "${repos[@]}"; do
    if [ ! -d "$repo" ]; then
      continue
    fi
    # Verify it's actually a git repo
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      continue
    fi

    lock=""
    if [ "$apply" -eq 1 ]; then
      lock="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/cc-reaper-worktree-janitor.lock"
      _cc_wj_lock "$lock" || { skipped=1; continue; }
    fi

    if ! _cc_wj_prepare_base "$repo"; then
      echo "worktree-janitor: $repo: $_CC_WJ_BASE_WHY, so no worktree in it can be shown landed"
    fi

    # Collected to completion before anything is judged. Read as it is produced, the
    # producer runs `git -C <next worktree> status` while the loop scans for holders, and
    # the janitor's own git then holds the next worktree it is about to judge.
    _cc_wj_list_worktrees "$repo" > "$work/inventory"

    while IFS=$'\t' read -r wt_path branch dirty ahead push_state pins; do

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

      active="no"
      if [ "$LSOF_OK" = "no" ] || _cc_wj_held "$work" "$wt_path"; then
        active="yes"
      fi

      # Asked only of a worktree the cheaper gates have not already kept: the landed proofs
      # may reach the network, and the idle walk costs seconds on a tree with node_modules.
      landed="-"
      idle="-"
      head0="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)"
      if [ "$dirty" = "0" ] && [ "$active" = "no" ]; then
        landed="$(_cc_wj_landed "$wt_path")"
        case "$landed" in
          ancestor|content|pr) idle="$(_cc_wj_idle "$wt_path" "$idle_hours")" ;;
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
      [ -n "$classification" ] ||
        classification=$(_cc_wj_classify "$wt_path" "$dirty" "$active" "$LSOF_OK" "$branch" "$landed" "$idle")

      printf "  WORKTREE  %s\n" "$wt_path"
      printf "    branch=%s  dirty=%s  ahead=%s  push=%s  active=%s  landed=%s  idle=%s\n" \
        "$branch" "$dirty" "$ahead" "$push_state" "$active" "$landed" "$idle"
      printf "    classification: %s\n" "$classification"
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
        REMOVABLE)
          total_removable=$((total_removable + 1))
          if [ "$apply" -eq 1 ]; then
            # Everything above was decided from scans taken before the loop began, and
            # another session can have entered this worktree or written into it since.
            # Asked again against fresh scans, immediately before the one irreversible step.
            if ! _cc_wj_scan_holders "$work"; then
              LSOF_OK="no"
              printf "    → kept: the process scan failed right before removal\n"
              total_kept=$((total_kept + 1))
              continue
            fi
            if _cc_wj_held "$work" "$wt_path" ||
               [ "$(_cc_wj_undiscounted_count "$wt_path")" != "0" ] ||
               [ "$(_cc_wj_idle "$wt_path" "$idle_hours")" != "yes" ] ||
               [ -z "$head0" ] ||
               [ "$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" != "$head0" ] ||
               [ -n "$(_cc_wj_git_keep "$wt_path")" ]; then
              printf "    → kept: it was entered or changed between the scan and the removal\n"
              total_kept=$((total_kept + 1))
              continue
            fi
            # Measure disk usage before removal
            bytes=0
            bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
            if _cc_wj_remove_worktree "$repo" "$wt_path"; then
              total_removed=$((total_removed + 1))
              total_reclaimed=$((total_reclaimed + bytes))
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
  rm -rf "$work"

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
  if [ "$apply" -eq 1 ]; then
    local gb_str
    gb_str=$(awk -v b="$total_reclaimed" 'BEGIN { printf "%.2f", b / 1073741824 }')
    printf "Summary: removed=%d  reclaimed=%s GB  kept=%d\n" \
      "$total_removed" "$gb_str" "$total_kept"
    _cc_wj_log_write "summary: removed=$total_removed reclaimed=${total_reclaimed}B kept=$total_kept"
  else
    printf "Summary: removable=%d  kept=%d  (dry-run; use --apply to remove)\n" \
      "$total_removable" "$total_kept"
  fi

  # Notification fires only on --apply pass (report-only runs don't measure bytes)
  if [ "$apply" -eq 1 ] && [ "$total_reclaimed" -gt 0 ]; then
    _cc_wj_maybe_notify "$total_reclaimed"
  fi

  # Finding repositories under one root does not make a denial on another harmless:
  # the worktrees under the denied one were never even listed. A repository skipped for a
  # held lock was not swept either.
  [ "$blind" -eq 1 ] && return 1
  [ "$skipped" -eq 1 ] && return 1
  return 0
}

# ─── Session mode ─────────────────────────────────────────────────────────────

_cc_wj_free_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 + 0 }'; }
_cc_wj_gib() {
  case "$1" in
    ''|*[!0-9]*) printf '?' ;;
    *) awk -v k="$1" 'BEGIN { printf "%.1fGiB", k / 1048576 }' ;;
  esac
}

# `--session`: the inventory for the repository a Claude Code session stood in, meant to
# run as a SessionEnd hook.
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
    local log script input="" hook_cwd=""
    # A SessionEnd hook receives JSON on stdin, and its `cwd` is where the session stood -
    # which need not be CLAUDE_PROJECT_DIR when it worked in a linked worktree. Read only
    # from a pipe or file, and bounded, so a terminal invocation does not wait for input.
    if [ ! -t 0 ]; then
      input="$(_cc_wj_with_timeout 5 cat 2>/dev/null)"
      hook_cwd="$(printf '%s\n' "$input" |
        sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1)"
    fi
    log="${CC_WJ_SESSION_LOG:-$HOME/.cc-reaper/logs/worktree-janitor-session.log}"
    mkdir -p "$(dirname "$log")" 2>/dev/null
    _cc_wj_bound_log "$log"
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    export CC_WJ_DETACHED=1 CC_WJ_SESSION_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" CC_WJ_SESSION_CWD="$hook_cwd"
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
  echo "== worktree-janitor session sweep $(date '+%Y-%m-%dT%H:%M:%S%z') $dir (pid $$)"
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

# Run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cc_wj_run "$@"
fi
