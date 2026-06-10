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
  -h, --help          Show this help

Environment:
  CC_WJ_ROOT              Root directory to discover repos under (default: ~/Documents/GitHub)
  CC_WJ_LOG               Log file path (default: ~/.cc-reaper/logs/worktree-janitor.log)
  CC_WJ_STATE_DIR         State directory for cooldown files (default: ~/.cc-reaper/state)
  CC_WJ_NOTIFY_MIN_GB     Disk savings threshold in GB to trigger notification (default: 1)
  CC_WJ_COOLDOWN_SECS     Notification cooldown in seconds (default: 3600)
EOF
}

# ─── Config defaults ──────────────────────────────────────────────────────────

_cc_wj_root() {
  echo "${CC_WJ_ROOT:-$HOME/Documents/GitHub}"
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

# ─── Logging ──────────────────────────────────────────────────────────────────

_cc_wj_log_write() {
  local log
  log=$(_cc_wj_log)
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf "[%s] %s\n" "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$log" 2>/dev/null || true
}

# ─── Repo discovery ───────────────────────────────────────────────────────────

# Emit one path per line: each directory directly under root that is a git repo
_cc_wj_discover_repos() {
  local root
  root=$(_cc_wj_root)
  if [ ! -d "$root" ]; then
    return
  fi
  # Use find at depth 1: repos have a .git entry (file for worktrees, dir for real repos)
  find "$root" -maxdepth 1 -mindepth 1 -type d | while IFS= read -r d; do
    if [ -e "$d/.git" ]; then
      echo "$d"
    fi
  done
}

# ─── Active-process detection ─────────────────────────────────────────────────

# Emit PIDs (one per line) of candidate processes that might own a worktree cwd
_cc_wj_candidate_pids() {
  pgrep -f 'claude|codex|node|bun' 2>/dev/null || true
  # Also check interactive shells
  pgrep -f 'bash|zsh|fish' 2>/dev/null || true
}

# Resolve a path through symlinks using POSIX cd -P (no external deps).
_cc_wj_realpath() {
  local p="$1"
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd) || echo "$p"
  else
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    echo "$(cd -P "$dir" 2>/dev/null && pwd)/$base"
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

  local dirty ahead push_state remote_sha
  if [ ! -d "$wt" ]; then
    printf "%s\t%s\t%s\t%s\t%s\n" "$wt" "${br:-?}" "MISSING" "?" "no_remote"
  else
    dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    # Resolve remote SHA once; pass to both helpers to avoid double rev-parse
    remote_sha=""
    if [ -n "${br:-}" ] && [ "$br" != "(detached)" ]; then
      remote_sha=$(git -C "$wt" rev-parse --verify --quiet "origin/$br" 2>/dev/null || echo "")
    fi
    ahead=$(_cc_wj_ahead_count "$wt" "${br:-}" "$remote_sha")
    push_state=$(_cc_wj_push_state "$wt" "${br:-}" "$remote_sha")
    printf "%s\t%s\t%s\t%s\t%s\n" "$wt" "${br:-?}" "$dirty" "$ahead" "$push_state"
  fi
}

# For a given repo path, print one line per non-primary worktree:
#   <wt_path> TAB <branch> TAB <dirty> TAB <ahead> TAB <push_state>
_cc_wj_list_worktrees() {
  local repo="$1"

  # git worktree list --porcelain output:
  #   worktree <path>
  #   HEAD <sha>
  #   branch refs/heads/<name>   (or "detached")
  #   (blank line)
  # The last block may not have a trailing blank line.
  local raw
  raw=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || return

  # Use a block_index counter so only the very first block (index 0) is skipped.
  local wt_path="" branch="" block_index=0

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        # Starting a new block — first emit any pending block (handles no trailing newline)
        if [ -n "$wt_path" ]; then
          _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
          block_index=$((block_index + 1))
        fi
        wt_path="${line#worktree }"
        branch=""
        ;;
      "HEAD "*)
        : # ignore sha line
        ;;
      "branch "*)
        branch="${line#branch refs/heads/}"
        ;;
      "detached")
        branch="(detached)"
        ;;
      "bare")
        branch="(bare)"
        ;;
      "")
        # End of a worktree block
        if [ -n "$wt_path" ]; then
          _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
          block_index=$((block_index + 1))
          wt_path=""
          branch=""
        fi
        ;;
    esac
  done <<< "$raw"

  # Handle final block if no trailing blank line
  if [ -n "$wt_path" ]; then
    _cc_wj_emit_wt_block "$wt_path" "$branch" "$block_index"
  fi
}

# ─── Classification ───────────────────────────────────────────────────────────

# Print KEEP(<reason>) or REMOVABLE
_cc_wj_classify() {
  local wt_path="$1"
  local dirty="$2"    # integer or "MISSING"
  local active="$3"   # "yes" or "no"
  local lsof_ok="$4"  # "yes" or "no" — "no" means lsof failed → conservative

  if [ "$dirty" = "MISSING" ]; then
    echo "KEEP(missing-dir)"
    return
  fi

  if [ "$lsof_ok" = "no" ]; then
    echo "KEEP(active-session)"
    return
  fi

  if [ "$dirty" -gt 0 ] 2>/dev/null; then
    echo "KEEP(dirty=$dirty)"
    return
  fi

  if [ "$active" = "yes" ]; then
    echo "KEEP(active-session)"
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

# Remove a single worktree; force-fallback if clean-but-ignored-residue.
# Returns the path of the repo owning this worktree (for prune afterwards).
_cc_wj_remove_worktree() {
  local repo="$1"
  local wt_path="$2"

  _cc_wj_log_write "removing worktree: $wt_path (repo: $repo)"

  if git -C "$repo" worktree remove "$wt_path" 2>/dev/null; then
    _cc_wj_log_write "removed (normal): $wt_path"
    return 0
  fi

  # Normal remove failed. Re-check dirty status — if still empty (residue is
  # untracked/ignored like node_modules), use --force.
  local recheck
  recheck=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$recheck" -eq 0 ] 2>/dev/null; then
    if git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null; then
      _cc_wj_log_write "removed (force, ignored residue): $wt_path"
      return 0
    fi
  fi

  _cc_wj_log_write "FAILED to remove: $wt_path"
  return 1
}

# ─── Main report/apply logic ─────────────────────────────────────────────────

_cc_wj_run() {
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
    echo "worktree-janitor: no repos found under $(_cc_wj_root)" >&2
    return 0
  fi

  local total_removable=0
  local total_kept=0
  local total_removed=0
  local total_reclaimed=0
  local prune_repos=()

  # Collect active process cwds ONCE per run. A per-pid lsof loop both
  # misreads vanished-pid exits as failures (pgrep->lsof race marks EVERY
  # worktree active) and costs O(worktrees x pids). Batched: vanished pids
  # are simply absent from output -- they cannot hold a cwd.
  # Dedup raw cwd paths before realpath to avoid redundant symlink resolution
  # (a per-pid lsof loop misread vanished-pid exits as failures, marking EVERY
  # worktree active).
  local ACTIVE_CWDS="" LSOF_OK="yes"
  if ! command -v lsof >/dev/null 2>&1; then
    LSOF_OK="no"
  else
    local _pids _csv _out _line _exit=0
    _pids=$(_cc_wj_candidate_pids | sort -un)
    if [ -n "$_pids" ]; then
      _csv=$(printf '%s\n' "$_pids" | paste -sd, -)
      _out=$(lsof -p "$_csv" -a -d cwd -Fn 2>/dev/null) || _exit=$?
      if [ -z "$_out" ] && [ "$_exit" -ne 0 ]; then
        LSOF_OK="no"  # lsof produced nothing and errored -- cannot trust it
      else
        # Collect raw n-lines, sort -u to dedup before calling realpath on each
        local _raw_cwds=""
        while IFS= read -r _line; do
          case "$_line" in
            n*) _raw_cwds="${_raw_cwds}${_line#n}"$'\n' ;;
          esac
        done <<< "$_out"
        while IFS= read -r _line; do
          [ -z "$_line" ] && continue
          ACTIVE_CWDS="${ACTIVE_CWDS}$(_cc_wj_realpath "$_line")"$'\n'
        done <<< "$(printf '%s' "$_raw_cwds" | sort -u)"
      fi
    fi
  fi

  for repo in "${repos[@]}"; do
    if [ ! -d "$repo" ]; then
      continue
    fi
    # Verify it's actually a git repo
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
      continue
    fi

    while IFS=$'\t' read -r wt_path branch dirty ahead push_state; do

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

      # Determine active-cwd status from the precomputed set
      local active="no" lsof_ok="$LSOF_OK"
      if [ "$LSOF_OK" = "no" ]; then
        active="yes"  # conservative: lsof unavailable or untrustworthy
      elif [ -n "$ACTIVE_CWDS" ]; then
        local wt_norm cwd
        wt_norm=$(_cc_wj_realpath "$wt_path")
        wt_norm="${wt_norm%/}"
        while IFS= read -r cwd; do
          [ -z "$cwd" ] && continue
          cwd="${cwd%/}"
          case "$cwd" in
            "$wt_norm"|"$wt_norm"/*) active="yes"; break ;;
          esac
        done <<< "$ACTIVE_CWDS"
      fi

      local classification
      classification=$(_cc_wj_classify "$wt_path" "$dirty" "$active" "$lsof_ok")

      printf "  WORKTREE  %s\n" "$wt_path"
      printf "    branch=%s  dirty=%s  ahead=%s  push=%s  active=%s\n" \
        "$branch" "$dirty" "$ahead" "$push_state" "$active"
      printf "    classification: %s\n" "$classification"

      case "$classification" in
        REMOVABLE)
          total_removable=$((total_removable + 1))
          if [ "$apply" -eq 1 ]; then
            # Measure disk usage before removal
            local bytes=0
            bytes=$(du -sk "$wt_path" 2>/dev/null | awk '{print $1 * 1024}') || bytes=0
            if _cc_wj_remove_worktree "$repo" "$wt_path"; then
              total_removed=$((total_removed + 1))
              total_reclaimed=$((total_reclaimed + bytes))
              printf "    → removed (%s bytes reclaimed)\n" "$bytes"
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

    done < <(_cc_wj_list_worktrees "$repo")

  done

  # Run git worktree prune on repos that had removals or missing dirs (deduped)
  if [ "${#prune_repos[@]}" -gt 0 ]; then
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
}

# ─── Entry point ─────────────────────────────────────────────────────────────

# Run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cc_wj_run "$@"
fi
