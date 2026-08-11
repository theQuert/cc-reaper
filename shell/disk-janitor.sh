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

_cc_dj_clean_target() {
  local label="$1"
  shift
  # "$@" is the command to run
  _cc_dj_log "clean: running target '${label}'"
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >> "$CC_DJ_LOG"
  if [ "$rc" -eq 0 ]; then
    _cc_dj_log "clean: target '${label}' done (freed=?)"
  else
    _cc_dj_log "clean: target '${label}' returned non-zero (rc=${rc}, may be fine)"
  fi
}

_cc_dj_clean_dir() {
  local label="$1"
  local path="$2"
  [ -z "$path" ] && { _cc_dj_log "SKIP ${label} (empty path)"; return 0; }
  if [ ! -e "$path" ]; then
    _cc_dj_log "SKIP ${label} (path not found: ${path})"
    return
  fi
  local bytes
  bytes="$(_cc_dj_du_bytes "$path")"
  rm -rf "$path"
  _cc_dj_log "clean: removed '${label}' freed=${bytes} bytes"
}

# ---------------------------------------------------------------------------
# --clean mode
# ---------------------------------------------------------------------------
_cc_dj_clean() {
  _cc_dj_init_dirs || return 1
  local free_before free_after
  free_before="$(_cc_dj_free_pct)"
  _cc_dj_log "clean: starting — disk free=${free_before}%"

  # -- go clean -cache -------------------------------------------------------
  if command -v go >/dev/null 2>&1; then
    _cc_dj_clean_target "go clean -cache" go clean -cache
  else
    _cc_dj_log "SKIP go clean -cache (go not found)"
  fi

  # -- yarn cache clean -------------------------------------------------------
  if command -v yarn >/dev/null 2>&1; then
    _cc_dj_clean_target "yarn cache clean" yarn cache clean
  else
    _cc_dj_log "SKIP yarn cache clean (yarn not found)"
  fi

  # -- pip3 cache purge -------------------------------------------------------
  if command -v pip3 >/dev/null 2>&1; then
    _cc_dj_clean_target "pip3 cache purge" pip3 cache purge
  else
    _cc_dj_log "SKIP pip3 cache purge (pip3 not found)"
  fi

  # -- brew cleanup -s --------------------------------------------------------
  if command -v brew >/dev/null 2>&1; then
    _cc_dj_clean_target "brew cleanup -s" brew cleanup -s
  else
    _cc_dj_log "SKIP brew cleanup -s (brew not found)"
  fi

  # -- bun pm cache rm --------------------------------------------------------
  if command -v bun >/dev/null 2>&1; then
    _cc_dj_clean_target "bun pm cache rm" bun pm cache rm
  else
    _cc_dj_log "SKIP bun pm cache rm (bun not found)"
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

  # -- docker system prune ----------------------------------------------------
  if command -v docker >/dev/null 2>&1; then
    _cc_dj_clean_target "docker system prune" docker system prune -af
  else
    _cc_dj_log "SKIP docker system prune (docker not found)"
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
  _cc_dj_log "clean: finished — disk free=${free_after}%"
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
