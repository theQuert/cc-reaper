#!/usr/bin/env bash
# resource-watch: lightweight system snapshot + threshold-gated alerting for cc-reaper.
#
# Executed directly by launchd (--once style); can also be sourced for the
# _cc_rw_snapshot shell function.
#
#   bash shell/resource-watch.sh
#   bash shell/resource-watch.sh -h

_cc_rw_usage() {
  cat <<'EOF'
Usage: resource-watch [-h|--help]

Lightweight system snapshot with threshold-gated macOS notifications.

Takes one snapshot of load avg, CPU idle %, memory free %, compressor size,
and Data-volume disk free, then appends a structured log line and fires
osascript notifications when thresholds are breached (per-metric cooldown).

Options:
  -h, --help    Show this help

Environment:
  CC_RW_LOG            Log file path (default: ~/.cc-reaper/logs/resource-watch.log)
  CC_RW_STATE_DIR      Cooldown state directory (default: ~/.cc-reaper/state)
  CC_RW_COOLDOWN_SECS  Notification cooldown per metric in seconds (default: 3600)
  CC_RW_LOAD_FACTOR    Load-1 alert factor × logical-core count (default: 2)
  CC_RW_DISK_MIN_PCT   Disk free % below which alert fires (default: 15)
  CC_RW_MEM_MIN_PCT    Memory free % below which alert fires when compressor also high (default: 5)
EOF
}

# ---------------------------------------------------------------------------
# Config / defaults
# ---------------------------------------------------------------------------

_cc_rw_log_path() {
  echo "${CC_RW_LOG:-${HOME}/.cc-reaper/logs/resource-watch.log}"
}

_cc_rw_state_dir() {
  echo "${CC_RW_STATE_DIR:-${HOME}/.cc-reaper/state}"
}

_cc_rw_cooldown_secs() {
  local v="${CC_RW_COOLDOWN_SECS:-3600}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=3600
  echo "$v"
}

_cc_rw_load_factor() {
  local v="${CC_RW_LOAD_FACTOR:-2}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=2
  echo "$v"
}

_cc_rw_disk_min_pct() {
  local v="${CC_RW_DISK_MIN_PCT:-15}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=15
  echo "$v"
}

_cc_rw_mem_min_pct() {
  local v="${CC_RW_MEM_MIN_PCT:-5}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=5
  echo "$v"
}

# ---------------------------------------------------------------------------
# Directory bootstrap
# ---------------------------------------------------------------------------

_cc_rw_ensure_dirs() {
  local log_file state_dir
  log_file=$(_cc_rw_log_path)
  state_dir=$(_cc_rw_state_dir)
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  mkdir -p "$state_dir" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Metric collection (single-shot, macOS-native commands)
# ---------------------------------------------------------------------------

# Returns: load1 load5 load15
_cc_rw_collect_load() {
  sysctl -n vm.loadavg 2>/dev/null \
    | awk '{ gsub(/[{}]/, ""); print $1, $2, $3 }'
}

# Returns: cpu_idle (integer percent, 0-100)
_cc_rw_collect_cpu_idle() {
  LC_ALL=C top -l 1 -n 0 2>/dev/null \
    | awk '/^CPU usage:/ {
        for (i=1; i<=NF; i++) {
          if ($i == "idle") { val=$(i-1); gsub(/%/,"",val); print int(val+0.5); exit }
        }
      }'
}

# Returns: mem_free_pct compressor_gb phys_gb
# Uses vm_stat (page counts) and sysctl for physical RAM.
_cc_rw_collect_memory() {
  local page_size phys_bytes phys_gb
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
  phys_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  phys_gb=$(awk -v b="$phys_bytes" 'BEGIN { printf "%.2f", b / (1024*1024*1024) }')

  local free_pages inactive_pages compressor_pages vm_page_size
  free_pages=0; inactive_pages=0; compressor_pages=0; vm_page_size=""

  # vm_stat reports counts in its OWN page size (header line) — prefer it over
  # hw.pagesize, which can differ. "Pages occupied by compressor" is the
  # physical footprint; "stored in" is pre-compression and can exceed RAM.
  while IFS=: read -r key val; do
    case "$key" in
      "Mach Virtual Memory Statistics"*)
        vm_page_size=$(echo "$key$val" | sed -n 's/.*page size of \([0-9][0-9]*\) bytes.*/\1/p')
        continue ;;
    esac
    key="${key#"${key%%[! ]*}"}"   # ltrim
    key="${key%"${key##*[! ]}"}"   # rtrim
    val=$(echo "$val" | tr -d ' .')
    case "$key" in
      "Pages free")           free_pages="$val" ;;
      "Pages inactive")       inactive_pages="$val" ;;
      "Pages occupied by compressor") compressor_pages="$val" ;;
    esac
  done < <(vm_stat 2>/dev/null)
  [ -n "$vm_page_size" ] && page_size="$vm_page_size"

  awk -v fp="$free_pages" \
      -v ip="$inactive_pages" \
      -v cp="$compressor_pages" \
      -v ps="$page_size" \
      -v pg="$phys_bytes" \
  'BEGIN {
    free_bytes  = (fp + ip) * ps
    comp_bytes  = cp * ps
    phys        = (pg + 0 > 0) ? pg : 1
    free_pct    = (free_bytes / phys) * 100
    comp_gb     = comp_bytes / (1024*1024*1024)
    phys_gb     = phys / (1024*1024*1024)
    printf "%.1f %.2f %.2f\n", free_pct, comp_gb, phys_gb
  }'
}

# Returns: disk_free_gb disk_free_pct
_cc_rw_collect_disk() {
  df -k /System/Volumes/Data 2>/dev/null \
    | awk 'NR==2 {
        avail = $4
        capacity = $5
        gsub(/%/, "", capacity)
        used_pct = capacity + 0
        free_pct = 100 - used_pct
        free_gb  = avail / (1024*1024)
        printf "%.1f %.1f\n", free_gb, free_pct
      }'
}

# ---------------------------------------------------------------------------
# Cooldown helpers
# ---------------------------------------------------------------------------

# Return 0 (true) if metric is in cooldown (should suppress notification)
# Args: <metric> [now_epoch]  — now_epoch avoids a redundant date call when caller has it
_cc_rw_in_cooldown() {
  local metric="$1"
  local state_dir cooldown_secs state_file now mtime age
  state_dir=$(_cc_rw_state_dir)
  cooldown_secs=$(_cc_rw_cooldown_secs)
  state_file="${state_dir}/cooldown-${metric}"

  [ -f "$state_file" ] || return 1

  now="${2:-$(date +%s)}"
  mtime=$(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0)
  age=$(( now - mtime ))

  [ "$age" -lt "$cooldown_secs" ]
}

# Touch the cooldown file to start/refresh the window
_cc_rw_set_cooldown() {
  local metric="$1"
  local state_dir
  state_dir=$(_cc_rw_state_dir)
  touch "${state_dir}/cooldown-${metric}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Alert helper
# ---------------------------------------------------------------------------

_cc_rw_notify() {
  local metric="$1"
  local message="$2"
  message="${message//\\/\\\\}"
  message="${message//\"/\\\"}"
  osascript -e "display notification \"${message}\" with title \"cc-reaper: resource-watch\" subtitle \"${metric} threshold exceeded\""
}

# ---------------------------------------------------------------------------
# Notification helper (LOW-3): check cooldown, notify, set cooldown
# ---------------------------------------------------------------------------

_cc_rw_maybe_notify() {
  local metric="$1"
  local message="$2"
  local now="$3"
  if ! _cc_rw_in_cooldown "$metric" "$now"; then
    _cc_rw_notify "$metric" "$message"
    _cc_rw_set_cooldown "$metric"
  fi
}

# ---------------------------------------------------------------------------
# Core snapshot function
# ---------------------------------------------------------------------------

_cc_rw_snapshot() {
  _cc_rw_ensure_dirs

  # Hoist path/dir and now to single locals (E3+E4)
  local log_file state_dir now
  log_file=$(_cc_rw_log_path)
  state_dir=$(_cc_rw_state_dir)
  now=$(date +%s)

  # --- collect ---
  local load_out cpu_idle mem_out disk_out
  load_out=$(_cc_rw_collect_load)
  cpu_idle=$(_cc_rw_collect_cpu_idle)
  mem_out=$(_cc_rw_collect_memory)
  disk_out=$(_cc_rw_collect_disk)

  # --- parse (E1: builtin here-strings instead of echo | awk) ---
  local load1 load5 load15
  read -r load1 load5 load15 <<< "$load_out"

  local mem_free_pct compressor_gb phys_gb
  read -r mem_free_pct compressor_gb phys_gb <<< "$mem_out"

  local disk_free_gb disk_free_pct
  read -r disk_free_gb disk_free_pct <<< "$disk_out"

  # --- thresholds ---
  local ncpu load_factor load_threshold
  ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  load_factor=$(_cc_rw_load_factor)
  load_threshold=$(awk -v n="$ncpu" -v f="$load_factor" 'BEGIN { printf "%.2f", n * f }')

  local disk_min_pct mem_min_pct
  disk_min_pct=$(_cc_rw_disk_min_pct)
  mem_min_pct=$(_cc_rw_mem_min_pct)

  # compressor alert when > 50% of physical RAM
  local comp_threshold_gb
  comp_threshold_gb=$(awk -v p="$phys_gb" 'BEGIN { printf "%.2f", p * 0.5 }')

  # --- evaluate breaches ---
  local load_breach=false disk_breach=false mem_breach=false

  load_breach=$(awk -v l1="$load1" -v lt="$load_threshold" \
    'BEGIN { print (l1+0 > lt+0) ? "true" : "false" }')

  disk_breach=$(awk -v dfp="$disk_free_pct" -v dmin="$disk_min_pct" \
    'BEGIN { print (dfp+0 < dmin+0) ? "true" : "false" }')

  mem_breach=$(awk -v mfp="$mem_free_pct" -v mmin="$mem_min_pct" \
               -v cgb="$compressor_gb"    -v cth="$comp_threshold_gb" \
    'BEGIN { print (mfp+0 < mmin+0 && cgb+0 > cth+0) ? "true" : "false" }')

  # --- build markers (MED-2: remove dead alert_tag variable) ---
  local markers=""
  [ "$load_breach" = "true" ] && markers="${markers} ALERT:load"
  [ "$disk_breach" = "true" ] && markers="${markers} ALERT:disk"
  [ "$mem_breach"  = "true" ] && markers="${markers} ALERT:mem"
  markers="${markers# }"   # ltrim space

  # --- write log line ---
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  printf '%s load=%s/%s/%s cpu_idle=%s%% mem_free=%s%% compressor=%sGB disk_free=%sGB/%s%%%s\n' \
    "$ts" "$load1" "$load5" "$load15" \
    "$cpu_idle" "$mem_free_pct" "$compressor_gb" \
    "$disk_free_gb" "$disk_free_pct" \
    "${markers:+ ${markers}}" \
    >> "$log_file" 2>/dev/null || true

  # --- fire notifications (LOW-3: via _cc_rw_maybe_notify helper) ---
  [ "$load_breach" = "true" ] && _cc_rw_maybe_notify "load" \
    "load1=${load1} exceeds threshold ${load_threshold} (${ncpu} cores × ${load_factor})" "$now"

  [ "$disk_breach" = "true" ] && _cc_rw_maybe_notify "disk" \
    "disk free ${disk_free_pct}% (${disk_free_gb}GB) below ${disk_min_pct}% threshold" "$now"

  [ "$mem_breach"  = "true" ] && _cc_rw_maybe_notify "mem" \
    "mem free ${mem_free_pct}% below ${mem_min_pct}% and compressor ${compressor_gb}GB above ${comp_threshold_gb}GB" "$now"

  # deterministic exit: a false tail-test (`[ ... ] && notify`) must not leak
  # rc=1 into launchd's last-exit-status on healthy runs
  return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [ -n "${BASH_VERSION:-}" ]; then
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
      -h|--help)
        _cc_rw_usage
        exit 0
        ;;
      "")
        _cc_rw_snapshot
        ;;
      *)
        echo "resource-watch: unknown option '$1'" >&2
        _cc_rw_usage >&2
        exit 2
        ;;
    esac
  fi
fi
