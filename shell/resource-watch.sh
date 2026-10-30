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
A fall in disk free against the sample from about 30 minutes earlier raises
ALERT:disk-drop, so fast growth is flagged before the percentage floor is hit.

Options:
  -h, --help    Show this help

Environment:
  CC_RW_LOG            Log file path (default: ~/.cc-reaper/logs/resource-watch.log)
  CC_RW_STATE_DIR      Cooldown state directory (default: ~/.cc-reaper/state)
  CC_RW_COOLDOWN_SECS  Notification cooldown per metric in seconds (default: 3600)
  CC_RW_LOAD_FACTOR    Load-1 alert factor × logical-core count (default: 2)
  CC_RW_DISK_MIN_PCT   Disk free % below which alert fires (default: 15)
  CC_RW_MEM_MIN_PCT    Memory free % below which alert fires when compressor also high (default: 5)
  CC_RW_DISK_DROP_GB   Disk free fall in GB, against a 25-45 minute old sample, that alerts; 0 disables (default: 10)
  CC_RW_DISK_ALERT_GB  Disk free GB below which ALERT:disk-low fires (default: 60); 0 disables
  CC_RW_DISK_ACT_GB    Disk free GB below which the reclaim starts by itself, detached: worktree-janitor
                       --scheduled, then reclaim-byproducts (default: 40); 0 disables
  CC_RW_DISK_EMERGENCY_GB  Disk free GB below which ALERT:disk-emergency fires and the flag file
                       <state>/disk-emergency exists, for other tools to read (default: 20); 0 disables
  CC_RW_ACT_COOLDOWN_SECS  Seconds between two reclaim starts (default: 1800)
  CC_RW_ACT_MAX_SECONDS    A reclaim running longer is ended, its process tree by pid, by the next
                       round, with ERROR and ALERT:disk-act-overrun (default: 5400); 0 disables the cap
  CC_RW_ACT_KILL_GRACE_SECS  Seconds between TERM and KILL when ending an overrun (default: 10)
  CC_RW_RATE_WINDOW_SECS   Span the disk write rate is measured over (default: 3600)
  CC_RW_RATE_ALERT_GBH     Disk free falling faster than this many GB/h raises ALERT:disk-rate (default: 10); 0 disables
  CC_RW_RATE_FLAG_GBH      Falling faster than this many GB/h also writes <state>/disk-rate-high,
                       removed once a measured rate is at or below it (default: 20); 0 disables
  CC_RW_SWAP_FLAG_GB   Swap used above this many GB (vm.swapusage), while swap is still being written
                       (kern.memorystatus_vm_pressure_level >= 2, or vm_stat Swapouts grew since the last
                       round, kept in <state>/swapouts-last), also writes <state>/disk-rate-high (with
                       swap=<gb>, so heavy leases hold) and <state>/swap-high (`<epoch> swap=<gb> limit=<gb>
                       pressure=<n> swapouts=<n>`), and raises ALERT:swap. macOS never shrinks swap once
                       pressure ends, so high but calm swap clears them. swap-high is removed once swap is
                       read at or below the limit, or above it with a readable calm signal; it is left alone
                       when swap cannot be read, or when neither pressure nor Swapouts growth is known (the
                       first round has no stored Swapouts); disk-rate-high then follows
                       the rate alone, except that a swap-high left alone for unreadable pressure and Swapouts
                       keeps it too (default: 18; 0 disables)
  CC_RW_SWAP_USED_GB   Test seam: used swap in GB, replacing the sysctl read; set but empty = unreadable
  CC_RW_VM_PRESSURE_LEVEL  Test seam: kern.memorystatus_vm_pressure_level; set but empty = unreadable
  CC_RW_SWAPOUTS       Test seam: vm_stat's Swapouts count; set but empty = unreadable
  CC_RW_GO_CAP_MAX_SECONDS The go cache cap is ended, by pid, past this many seconds (default: 120); 0 = no bound
  CC_RW_ROUND_MAX_SECONDS  A whole round past this many seconds ends its own process tree (never a detached
                       act), with ERROR and ALERT:round-overrun, so launchd can start the next (default: 240); 0 = no bound
  CC_RW_RECLAIM_SCRIPT     reclaim-byproducts.sh to run (default: ~/.cc-reaper/reclaim-byproducts.sh)
  CC_RW_JANITOR_SCRIPT     worktree-janitor.sh to run (default: ~/.cc-reaper/worktree-janitor.sh)
  CC_RW_GO_CAP         Set to 0 to stop the every-run `reclaim-byproducts.sh --go-cache-cap` (default: 1)
  CC_RW_RECLAIM_STALL_SECS  reclaim-byproducts' last-finished stamp older than this raises ALERT:reclaim-stalled,
                       once per stall; 0 disables. Unset, it is twice the StartInterval of the installed
                       LaunchAgent (CC_RW_RECLAIM_PLIST), 172800 for a calendar schedule, and 7200 when the
                       plist cannot be read. Alert only, nothing is ended. Skipped when CC_RW_RECLAIM_SCRIPT
                       is not installed
  CC_RW_RECLAIM_STAMP  That stamp (default: ~/.claude/logs/reclaim-byproducts.last, BYPRODUCT_STAMP's default)
  CC_RW_RECLAIM_PLIST  The reclaimer's LaunchAgent (default: ~/Library/LaunchAgents/com.cc-reaper.reclaim-byproducts.plist)
  CC_RW_PAUSE_EVENTS   The pause chain (EL-T24): shadow (default), on or off. On a change of the combined pause state
                       (any of <state>/disk-emergency, disk-rate-high, swap-high, disk-stop present, against none)
                       one line, `DISK-PAUSE on: <flag,...> free=<gb>GB swap=<gb>GB rate=<gbh>GB/h` or
                       `DISK-RESUME: all clear free=... swap=... rate=...`. `on` appends it, stamped like every
                       events.log line, to CC_RW_EVENTS_LOG; `shadow` only logs `EVENT shadow: would emit ...`.
                       Each mode keeps its own last state (<state>/disk-pause.state, disk-pause.shadow.state), so
                       a transition is told once, and a new mode starts by telling the state it finds
  CC_RW_EVENTS_LOG     The event log the gateway and the event router read (default: ~/handoffs/ops-dispatch/events.log)
Every snapshot line carries `swap=<gb>GB rate=<gbh>GB/h swap_hot=<1|0|?>` after disk_free (`?` when unreadable
or unmeasured; swap_hot is this round's swap-high decision: 1 written, 0 not hot, ? left as it was).
Reclaim output goes to resource-watch-act.log beside CC_RW_LOG. Each round appends
`<epoch>\t<free KB>` to <state>/disk-free-samples.tsv (last 48 hours kept), and first of all
writes its start epoch to <state>/resource-watch.heartbeat. A detached reclaim that is stopped
(SIGSTOP, `T` in ps) is an operator hold: ERROR and ALERT:disk-act-held every round, never signalled.
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

_cc_rw_disk_drop_gb() {
  local v="${CC_RW_DISK_DROP_GB:-10}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=10
  echo "$v"
}

# Non-negative number knob (decimals allowed); a bad value falls back to the default.
_cc_rw_num() {
  local v="${!1:-$2}"
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || v=$2
  echo "$v"
}

# ---------------------------------------------------------------------------
# Directory bootstrap
# ---------------------------------------------------------------------------

# Bound a log to one live file plus one previous generation. cc-reaper reaps
# other tools for leaking; an unbounded log of its own is the same fault.
#
# Copy-then-truncate rather than rename: truncating keeps the inode, so a
# descriptor launchd already opened for StandardOutPath stays valid and keeps
# appending to the live file. A rename would leave launchd filling the ".old"
# copy while the live path stayed empty.
_cc_rw_bound_log() {
  local file=$1 max=${2:-1048576} size=""
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] && [ "$size" -gt "$max" ] || return 0
  cp -f "$file" "$file.old" 2>/dev/null && : > "$file" 2>/dev/null
  return 0
}

_cc_rw_ensure_dirs() {
  local log_file state_dir
  log_file=$(_cc_rw_log_path)
  state_dir=$(_cc_rw_state_dir)
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  mkdir -p "$state_dir" 2>/dev/null || true
  _cc_rw_bound_log "$log_file"
  _cc_rw_bound_log "$HOME/.cc-reaper/logs/launchd-resource-watch-stdout.log"
  _cc_rw_bound_log "$HOME/.cc-reaper/logs/launchd-resource-watch-stderr.log"
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

# Returns: disk_free_gb disk_free_pct disk_free_kb
_cc_rw_collect_disk() {
  df -k /System/Volumes/Data 2>/dev/null \
    | awk 'NR==2 {
        avail = $4
        capacity = $5
        gsub(/%/, "", capacity)
        used_pct = capacity + 0
        free_pct = 100 - used_pct
        free_gb  = avail / (1024*1024)
        printf "%.1f %.1f %.0f\n", free_gb, free_pct, avail
      }'
}

# Record this sample, and print how far disk free fell since the newest stored sample
# 25-45 minutes old when that fall reaches the threshold. The log's timestamps are local
# time and macOS awk has no mktime, so samples live in their own `<epoch> <free GB>` file,
# trimmed to the last 12 (two hours at the ten-minute cadence). After sleep no sample is
# in the window, so nothing is compared rather than something false being raised.
# Args: <samples file> <now epoch> <free GB> <threshold GB, 0 disables>
_cc_rw_disk_drop() {
  local file=$1 now=$2 free=$3 threshold=$4
  [[ "$free" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [ -f "$file" ] && awk -v now="$now" -v free="$free" -v t="$threshold" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
      age = now - $1
      if (age >= 1500 && age <= 2700 && (!found || $1 > best)) { best = $1; prev = $2; found = 1 }
    }
    END { if (t + 0 > 0 && found && prev - free >= t + 0) printf "%.1f\n", prev - free }' "$file"
  { [ -f "$file" ] && tail -n 11 "$file"; printf '%s %s\n' "$now" "$free"; } > "$file.tmp" 2>/dev/null \
    && mv -f "$file.tmp" "$file" 2>/dev/null
  return 0
}

# D7, the write rate (stima-api #5886). The drop alert above compares two samples; this one
# answers "how fast is the disk filling", which is what decides whether a reclaim can still
# finish in time. On 2026-10-24 free space went from 54.5 GB to 23.5 GB in 73 minutes, about
# 25 GB/h, so at the 40 GB act line a run has roughly 80 minutes before 20 GB is gone.
#
# Every round appends `<epoch>\t<free KB>` to the samples file and keeps 48 hours (about 288
# lines at the ten-minute cadence). The rate is taken against the OLDEST sample whose age is
# between a third of the window and the window plus five minutes of launchd drift, so a
# gap (sleep, a stalled round) yields no rate rather than one averaged over hours. Printed in
# GB/h with consumption positive (a reclaim prints a negative rate); nothing when no sample
# qualifies. Args: <samples file> <now epoch> <free KB> <window secs> <keep secs>
_cc_rw_disk_rate() {
  local file=$1 now=$2 kb=$3 win=$4 keep=$5
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  [ -f "$file" ] && awk -v now="$now" -v kb="$kb" -v win="$win" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      age = now - $1
      if (age >= win / 3 && age <= win + 300 && age > 0 && (!found || $1 < best)) { best = $1; prev = $2; found = 1 }
    }
    END { if (found) printf "%.1f\n", (prev - kb) / 1048576 * 3600 / (now - best) }' "$file"
  { [ -f "$file" ] && awk -v cut=$(( now - keep )) '$1 ~ /^[0-9]+$/ && $1 + 0 >= cut' "$file"
    printf '%s\t%s\n' "$now" "$kb"; } > "$file.tmp" 2>/dev/null \
    && mv -f "$file.tmp" "$file" 2>/dev/null
  return 0
}

# 0 when number $1 is above limit $2 and the limit is on (> 0).
_cc_rw_above() {
  awk -v f="$1" -v l="$2" 'BEGIN { exit !(f ~ /^-?[0-9.]+$/ && l + 0 > 0 && f + 0 > l + 0) }'
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
# A stalled reclaimer (stima-api #5886)
# ---------------------------------------------------------------------------
#
# reclaim-byproducts.sh writes its stamp only when a sweep FINISHED without a failure, and the
# launchd agent starts one every hour. On 2026-10-24 it hung for hours in a liveness gate and
# nothing said so. A stamp older than twice the agent's StartInterval means the sweeps are
# stuck, failing, or not starting (CC_RW_RECLAIM_STALL_SECS overrides; the installed plist says
# 7200 on the Mac mini, so the line there is 14400, not 7200: at a 7200s period a healthy stamp
# is up to 7200s plus a sweep's length old). This raises ALERT:reclaim-stalled with a
# notification, ONCE per stall: <state>/reclaim-stalled.alerted holds the stamp's mtime (or
# "none") that was alerted, a later round with the same stamp stays quiet, and a fresh stamp
# removes the file so the next stall alerts again. No stamp at all is aged from the plist's mtime
# (else the script's): inside the line one INFO line, once (<state>/reclaim-stalled.nostamp); over
# it the same once-only alert, so a first sweep that never finishes cannot stay silent. Alert only: it ends no process and deletes
# nothing. Not installed (the script is absent) means nothing to be stalled.
_CC_RW_RECLAIM_STALL_FIRE=""
_cc_rw_reclaim_stall_limit() {
  local plist iv
  if [ -n "${CC_RW_RECLAIM_STALL_SECS:-}" ]; then
    iv=$(_cc_rw_num CC_RW_RECLAIM_STALL_SECS 7200); echo "${iv%%.*}"; return
  fi
  plist="${CC_RW_RECLAIM_PLIST:-$HOME/Library/LaunchAgents/com.cc-reaper.reclaim-byproducts.plist}"
  if [ -r "$plist" ]; then
    iv=$(/usr/bin/plutil -extract StartInterval raw -o - "$plist" 2>/dev/null)
    if [[ "$iv" =~ ^[0-9]+$ ]] && [ "$iv" -gt 0 ]; then echo $(( iv * 2 )); return; fi
    if /usr/bin/plutil -extract StartCalendarInterval xml1 -o - "$plist" >/dev/null 2>&1; then echo 172800; return; fi
  fi
  echo 7200
}
_cc_rw_reclaim_stall() {  # <now epoch>
  local now="$1" limit script stamp state_dir marker mt age key
  _CC_RW_RECLAIM_STALL_FIRE=""
  limit=$(_cc_rw_reclaim_stall_limit)
  [ "${limit:-0}" -gt 0 ] || return 0
  script="${CC_RW_RECLAIM_SCRIPT:-$HOME/.cc-reaper/reclaim-byproducts.sh}"
  [ -f "$script" ] || return 0
  stamp="${CC_RW_RECLAIM_STAMP:-$HOME/.claude/logs/reclaim-byproducts.last}"
  state_dir=$(_cc_rw_state_dir)
  marker="${state_dir}/reclaim-stalled.alerted"
  if [ -f "$stamp" ]; then
    mt=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null)
    [[ "$mt" =~ ^[0-9]+$ ]] || return 0
    age=$(( now - mt )); [ "$age" -ge 0 ] || age=0; key=$mt
  else
    # No stamp: a fresh install whose first sweep has not finished, or a reclaimer that never
    # finishes one (the first sweep hangs, or every sweep fails) and so never writes a stamp.
    # Silence forever is the failure this alert is for, so the age comes from a baseline: the
    # mtime of the LaunchAgent plist (when the agent was installed), else of the script. Inside
    # the line: one INFO, once. Over it: the same once-only alert as a stale stamp.
    local base="${CC_RW_RECLAIM_PLIST:-$HOME/Library/LaunchAgents/com.cc-reaper.reclaim-byproducts.plist}" bmt
    [ -r "$base" ] || base="$script"
    bmt=$(stat -f %m "$base" 2>/dev/null || stat -c %Y "$base" 2>/dev/null)
    if [[ "$bmt" =~ ^[0-9]+$ ]]; then
      age=$(( now - bmt )); [ "$age" -ge 0 ] || age=0; key="nostamp:$bmt"
      if [ "$age" -gt "$limit" ]; then
        [ "$(cat "$marker" 2>/dev/null)" = "$key" ] && return 0
        printf '%s\n' "$key" > "$marker" 2>/dev/null || true
        _CC_RW_RECLAIM_STALL_FIRE="no finished-sweep stamp at $stamp, and the reclaimer was installed ${age}s ago (over ${limit}s)"
        return 0
      fi
    fi
    if [ ! -e "${state_dir}/reclaim-stalled.nostamp" ]; then
      : > "${state_dir}/reclaim-stalled.nostamp" 2>/dev/null || true
      _cc_rw_log_line "INFO reclaim-stalled: no finished-sweep stamp yet at $stamp (alerting only if none appears within ${limit}s of the install)"
    fi
    return 0
  fi
  rm -f "${state_dir}/reclaim-stalled.nostamp" 2>/dev/null
  if [ "$age" -le "$limit" ]; then
    rm -f "$marker" 2>/dev/null
    return 0
  fi
  [ "$(cat "$marker" 2>/dev/null)" = "$key" ] && return 0
  printf '%s\n' "$key" > "$marker" 2>/dev/null || true
  _CC_RW_RECLAIM_STALL_FIRE="the reclaimer's last finished sweep was ${age}s ago (over ${limit}s)"
}

# ---------------------------------------------------------------------------
# Disk guard: below CC_RW_DISK_ACT_GB free, start the reclaim by itself, detached
# ---------------------------------------------------------------------------
#
# Tiers (stima-api #5886, EL-DISK-ROOTFIX-1356 D1). Measured on 2026-10-24: free space fell
# about 25 GB/h at its peak (54.5 GB to 23.5 GB in 73 minutes). At the old 25 GB act line that
# is an hour of headroom for a reclaim that ran 3h34m, so the lines move up:
#   < CC_RW_DISK_ALERT_GB     (60) ALERT:disk-low: about 2h24m from empty at the peak rate
#   < CC_RW_DISK_ACT_GB       (40) the reclaim starts, detached, once per CC_RW_ACT_COOLDOWN_SECS
#   < CC_RW_DISK_EMERGENCY_GB (20) ALERT:disk-emergency and <state>/disk-emergency, a flag other
#                                  tools read to stop starting heavy work; removed above the line
#
# Why detached (D1). The reclaim used to run in the foreground of this launchd job, so while it
# ran launchd started no new round: on 2026-10-24 one act (pid 55146) ran 3h34m and there were
# no samples, no go cache cap and no alerts from 10:35 on. Now the act is this script re-run as
# `resource-watch.sh --act`, in its own process group (`set -m`), under nohup with stdin, stdout
# and stderr off the job. launchd ends only the job's own process group when the job exits
# (unless AbandonProcessGroup), so the act survives the round and the round returns at once.
#
# Single instance. <state>/disk-act.lock is a directory: mkdir is the atomic claim, made by the
# round before it spawns; `started` holds the claim epoch and `pid` the act's own pid, written by
# the act itself with noclobber. A later round reads it:
#   - pid alive and its command line is a `resource-watch` `--act`: running; past
#     CC_RW_ACT_MAX_SECONDS it is ended (ERROR line, ALERT:disk-act-overrun);
#   - pid dead, or alive but not an act (a reused pid): stale, removed, the round may claim anew;
#   - no pid yet: the spawn is in flight for 120 seconds, stale after that.
# Ending an overrun walks the act's tree with `pgrep -P` from the recorded pid, sends TERM to
# exactly those pids, waits CC_RW_ACT_KILL_GRACE_SECS and sends KILL to whichever of them is
# still alive. Nothing is matched by name, so no other process can be hit.

# 0 when $1 < $2 and $2 > 0 (a limit of 0 is "off"); also 1 for an unreadable $1.
_cc_rw_below() {
  awk -v f="$1" -v l="$2" 'BEGIN { exit !(f ~ /^[0-9.]+$/ && l + 0 > 0 && f + 0 < l + 0) }'
}

_cc_rw_act_lock() {
  echo "$(_cc_rw_state_dir)/disk-act.lock"
}

_cc_rw_act_log() {
  echo "$(dirname "$(_cc_rw_log_path)")/resource-watch-act.log"
}

# One line to the main log, so an ERROR is read where the snapshots are.
_cc_rw_log_line() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$(_cc_rw_log_path)" 2>/dev/null || true
}

# 0 when pid $1 is alive and its command line is a resource-watch act, so a pid the system has
# since handed to another process is never taken for one.
_cc_rw_is_act_pid() {
  local pid=$1 cmd
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
  case "$cmd" in *resource-watch*" --act"*) return 0 ;; esac
  return 1
}

# $1 and every descendant, parents first, one per line (`pgrep -P` breadth-first).
_cc_rw_tree_pids() {
  local queue=$1 next pid kid
  while [ -n "$queue" ]; do
    next=""
    for pid in $queue; do
      echo "$pid"
      for kid in $(pgrep -P "$pid" 2>/dev/null); do next="$next $kid"; done
    done
    queue=${next# }
  done
}

# 0 when pid $1 is alive; a zombie (exited, its parent not yet reaped it) counts as gone.
_cc_rw_pid_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; esac
  return 0
}

# The pids of $1's tree whose `ps -o stat=` holds `T` (stopped), space-separated; empty when none.
_cc_rw_stopped_pids() {
  local pid out=""
  for pid in $(_cc_rw_tree_pids "$1"); do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in *T*) out="$out $pid" ;; esac
  done
  echo "${out# }"
}

# TERM the listed pids, wait up to <grace> seconds for them, KILL the ones still alive. Prints
# the pids that needed KILL. Args: <grace secs> <pid>...
_cc_rw_end_pids() {
  local grace=$1 pid alive waited=0
  shift
  [ "$#" -gt 0 ] || return 0
  kill -TERM "$@" 2>/dev/null
  while :; do
    alive=""
    for pid in "$@"; do _cc_rw_pid_alive "$pid" && alive="$alive $pid"; done
    [ -z "$alive" ] && return 0
    [ "$waited" -ge "$grace" ] && break
    sleep 1
    waited=$(( waited + 1 ))
  done
  # shellcheck disable=SC2086
  kill -KILL $alive 2>/dev/null
  echo "${alive# }"
}

_cc_rw_act_unlock() {
  local lock
  lock=$(_cc_rw_act_lock)
  rm -f "$lock/pid" "$lock/started" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  return 0
}

# Read the lock and act on it. Sets _CC_RW_ACT_STATE to one of
#   idle      no act (a stale lock found here has been removed)
#   running   an act is running inside its cap
#   held      the act, or a pid in its tree, is stopped (`T`): an operator hold, never signalled
#   overrun   an act ran past CC_RW_ACT_MAX_SECONDS and has just been ended
# and _CC_RW_ACT_PID to the act's pid when there is one. Args: <now epoch>
_cc_rw_act_supervise() {
  local now=$1 lock pid started age max grace tree killed held what
  lock=$(_cc_rw_act_lock)
  _CC_RW_ACT_STATE=idle
  _CC_RW_ACT_PID=""
  [ -d "$lock" ] || return 0
  pid=$(cat "$lock/pid" 2>/dev/null)
  started=$(cat "$lock/started" 2>/dev/null)
  [[ "$started" =~ ^[0-9]+$ ]] \
    || started=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || echo 0)
  age=$(( now - started ))
  if [ -z "$pid" ] && [ "$age" -lt 120 ]; then
    _CC_RW_ACT_STATE=running
    return 0
  fi
  if [ -z "$pid" ] || ! _cc_rw_is_act_pid "$pid"; then
    _cc_rw_log_line "WARN disk act lock stale (pid ${pid:-none} is not a running act, claimed ${age}s ago); taken over"
    _cc_rw_act_unlock
    return 0
  fi
  _CC_RW_ACT_PID=$pid
  max=$(_cc_rw_num CC_RW_ACT_MAX_SECONDS 5400)
  max=${max%.*}
  # A stopped pid anywhere in the act's tree is an operator's hold (SIGSTOP), not a hang: it is
  # never signalled, whatever its age, and the act keeps the lock. Every round says so.
  held=$(_cc_rw_stopped_pids "$pid")
  if [ -n "$held" ]; then
    what="is stopped"
    [ "$held" = "$pid" ] || what="has stopped pid(s) ${held} in its tree"
    _cc_rw_log_line "ERROR disk act pid ${pid} ${what} (an operator hold, claimed ${age}s ago); not signalled, not ended, no new act while it holds the lock"
    _CC_RW_ACT_STATE=held
    return 0
  fi
  if [ "$max" -eq 0 ] || [ "$age" -le "$max" ]; then
    _CC_RW_ACT_STATE=running
    return 0
  fi
  grace=$(_cc_rw_num CC_RW_ACT_KILL_GRACE_SECS 10)
  tree=$(_cc_rw_tree_pids "$pid" | tr '\n' ' ')
  tree=${tree% }
  _cc_rw_log_line "ERROR disk act pid ${pid} has run ${age}s, over CC_RW_ACT_MAX_SECONDS=${max}; ending its process tree: ${tree}"
  # shellcheck disable=SC2086
  killed=$(_cc_rw_end_pids "${grace%.*}" $tree)
  _cc_rw_log_line "ERROR disk act pid ${pid} ended (TERM: ${tree}; KILL: ${killed:-none})"
  printf '== disk act pid %s ended by resource-watch after %ss (over %ss) ==\n' "$pid" "$age" "$max" \
    >> "$(_cc_rw_act_log)" 2>/dev/null
  _cc_rw_act_unlock
  _CC_RW_ACT_STATE=overrun
  return 0
}

# Claim the lock and start the act, at most once per CC_RW_ACT_COOLDOWN_SECS. The cooldown stamp
# is touched when the act starts. Returns 1 when nothing was started. Sets _CC_RW_ACT_PID.
# Args: <free GB> <now epoch>
_cc_rw_disk_act() {
  local free=$1 now=$2 stamp mtime cool actlog lock self
  stamp="$(_cc_rw_state_dir)/cooldown-disk-act"
  cool=$(_cc_rw_num CC_RW_ACT_COOLDOWN_SECS 1800)
  if [ -f "$stamp" ]; then
    mtime=$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null || echo 0)
    [ $(( now - mtime )) -lt "${cool%.*}" ] && return 1
  fi
  lock=$(_cc_rw_act_lock)
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$now" > "$lock/started" 2>/dev/null
  touch "$stamp" 2>/dev/null
  actlog=$(_cc_rw_act_log)
  _cc_rw_bound_log "$actlog"
  self="${BASH_SOURCE[0]}"
  _CC_RW_ACT_PID=$(
    set -m
    nohup "${BASH:-bash}" "$self" --act "$free" >> "$actlog" 2>&1 < /dev/null &
    echo "$!"
  )
  return 0
}

# The act itself (`resource-watch.sh --act <free GB>`). Order is the byproducts doc's: the
# worktree sweep first, because a reclaimed tree orphans what reclaim-byproducts then collects.
_cc_rw_act_main() {
  local free=$1 lock janitor reclaim
  lock=$(_cc_rw_act_lock)
  # The claim is the round's; the pid is ours. No lock, or a pid already there, means this
  # process does not own the claim, so it does nothing.
  ( set -C; printf '%s\n' "$$" > "$lock/pid" ) 2>/dev/null || {
    echo "== disk act pid $$ not started: $lock is missing or already names an act =="
    return 1
  }
  trap '_cc_rw_act_release' EXIT
  janitor="${CC_RW_JANITOR_SCRIPT:-$HOME/.cc-reaper/worktree-janitor.sh}"
  reclaim="${CC_RW_RECLAIM_SCRIPT:-$HOME/.cc-reaper/reclaim-byproducts.sh}"
  echo "== disk act $(date '+%Y-%m-%dT%H:%M:%S') pid $$ free=${free}GB =="
  if [ -f "$janitor" ]; then bash "$janitor" --scheduled; echo "worktree-janitor --scheduled rc=$?"; else echo "no $janitor"; fi
  if [ -f "$reclaim" ]; then bash "$reclaim"; echo "reclaim-byproducts rc=$?"; else echo "no $reclaim"; fi
  echo "== disk act done $(date '+%Y-%m-%dT%H:%M:%S') pid $$ free=$(_cc_rw_collect_disk | awk '{print $1}')GB =="
  return 0
}

# Remove the lock only while it still names this act: a round that ended this act may already
# have removed it, and a newer act may hold a new one.
_cc_rw_act_release() {
  local lock
  lock=$(_cc_rw_act_lock)
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] && _cc_rw_act_unlock
  return 0
}

# Run a command in the background and wait for it at most <secs> seconds (0 = no bound), then
# end its tree by pid as an overrun act is ended. Keeps the round short however the go cache cap
# behaves. Args: <secs> <command>...
_cc_rw_run_bounded() {
  local cap=$1 pid ticks=0 tree killed rc=0
  shift
  if [ "${cap%.*}" -eq 0 ]; then "$@"; return $?; fi
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $(( ${cap%.*} * 5 )) ]; then
      tree=$(_cc_rw_tree_pids "$pid" | tr '\n' ' ')
      tree=${tree% }
      # shellcheck disable=SC2086
      killed=$(_cc_rw_end_pids 5 $tree)
      _cc_rw_log_line "ERROR $* ran over ${cap}s; ended pids ${tree} (KILL: ${killed:-none})"
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.2
    ticks=$(( ticks + 1 ))
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# The pause chain (EL-T24): one events.log line when heavy work is paused or resumed
# ---------------------------------------------------------------------------
#
# stima-api scripts/ci/with_local_resource.py refuses a heavy lease (exit 76) while any of these
# flags exists in the state dir: the three this script writes, and disk-stop, which a dispatch
# writes. Pausing and resuming sessions used to be fanned out by hand. Here the combined state
# (any flag against none) is compared with the last one told, and only a change is told, as one
# line in the REPORT-CHAIN shape: on change only, nothing when nothing changed.
_CC_RW_PAUSE_FLAGS="disk-emergency disk-rate-high swap-high disk-stop"

_cc_rw_pause_mode() {
  case "${CC_RW_PAUSE_EVENTS:-shadow}" in
    on|off|shadow) echo "${CC_RW_PAUSE_EVENTS:-shadow}" ;;
    *) echo shadow ;;   # an unknown value never turns the writes on
  esac
}

_cc_rw_events_log() {
  echo "${CC_RW_EVENTS_LOG:-${HOME}/handoffs/ops-dispatch/events.log}"
}

# The pause flags present now, comma-separated in a fixed order; empty when none.
_cc_rw_pause_flags() {
  local dir f out=""
  dir=$(_cc_rw_state_dir)
  for f in $_CC_RW_PAUSE_FLAGS; do [ -e "$dir/$f" ] && out="$out,$f"; done
  echo "${out#,}"
}

# A number with its unit, or `?` when there is none. Args: <value> <unit>
_cc_rw_val() {
  if [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then echo "$1$2"; else echo "?"; fi
}

# Tell a change of the pause state once. Runs after this round wrote or removed its flags.
# Sets _CC_RW_PAUSE_LINE to the line told this round (empty when none). In `on` mode a failed
# append leaves the state as it was, so the next round tries again. Args: <free GB> <swap GB> <rate GB/h>
_CC_RW_PAUSE_LINE=""
_cc_rw_pause_chain() {
  local free=$1 swap=$2 rate=$3 mode dir state flags prev want line events vals
  _CC_RW_PAUSE_LINE=""
  mode=$(_cc_rw_pause_mode)
  [ "$mode" = off ] && return 0
  dir=$(_cc_rw_state_dir)
  state="$dir/disk-pause.state"
  [ "$mode" = shadow ] && state="$dir/disk-pause.shadow.state"
  flags=$(_cc_rw_pause_flags)
  prev=$(head -n 1 "$state" 2>/dev/null)
  case "$prev" in paused*) prev=paused ;; clear) ;; *) prev="" ;; esac
  vals="free=$(_cc_rw_val "$free" GB) swap=$(_cc_rw_val "$swap" GB) rate=$(_cc_rw_val "$rate" GB/h)"
  if [ -n "$flags" ]; then
    [ "$prev" = paused ] && return 0
    want="paused $flags"
    line="DISK-PAUSE on: $flags $vals"
  else
    [ "$prev" = clear ] && return 0
    if [ -z "$prev" ]; then   # first round in this mode, nothing paused: nothing to tell
      { printf 'clear\n' > "$state.tmp" && mv -f "$state.tmp" "$state"; } 2>/dev/null
      return 0
    fi
    want=clear
    line="DISK-RESUME: all clear $vals"
  fi
  events=$(_cc_rw_events_log)
  if [ "$mode" = on ]; then
    if ! printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line" >> "$events" 2>/dev/null; then
      _cc_rw_log_line "ERROR pause chain: cannot append to $events; told next round: $line"
      return 0
    fi
    _cc_rw_log_line "EVENT emitted to $events: $line"
  else
    _cc_rw_log_line "EVENT shadow (CC_RW_PAUSE_EVENTS=shadow): would emit to $events: $line"
  fi
  { printf '%s\n' "$want" > "$state.tmp" && mv -f "$state.tmp" "$state"; } 2>/dev/null ||
    _cc_rw_log_line "ERROR pause chain: cannot write $state; the next round tells it again: $line"
  _CC_RW_PAUSE_LINE=$line
  return 0
}

# ---------------------------------------------------------------------------
# Round watchdog: the heartbeat and the whole-round deadline (stima-api #5886)
# ---------------------------------------------------------------------------
#
# launchd starts no new round while one runs, and has no maximum run time (ExitTimeOut only
# spaces TERM and KILL when a job is being stopped). On 2026-10-24 one round never returned and
# sampling, alerts and the go cache cap were gone for 5+ hours with nothing saying so. So:
#   - <state>/resource-watch.heartbeat holds the epoch of the newest round's start, written
#     before any step that can block, for a reader in another job to tell a dead guard;
#   - a watchdog subshell ends the round past CC_RW_ROUND_MAX_SECONDS (240), its own tree by
#     pid: the round, its command substitutions and children. A detached act is not in it (it
#     is reparented and leads its own group) and is skipped by command line in any case.

_cc_rw_heartbeat() {
  local dir
  dir=$(_cc_rw_state_dir)
  mkdir -p "$dir" 2>/dev/null || true
  { printf '%s\n' "$(date +%s)" > "$dir/resource-watch.heartbeat.tmp" \
      && mv -f "$dir/resource-watch.heartbeat.tmp" "$dir/resource-watch.heartbeat"; } 2>/dev/null
  return 0
}

# Like _cc_rw_tree_pids, but never lists or descends into pid <skip> (the watchdog) or a
# resource-watch act. Args: <root pid> <skip pid>
_cc_rw_round_tree() {
  local queue=$1 skip=$2 next pid kid
  while [ -n "$queue" ]; do
    next=""
    for pid in $queue; do
      [ "$pid" = "$skip" ] && continue
      _cc_rw_is_act_pid "$pid" && continue
      echo "$pid"
      for kid in $(pgrep -P "$pid" 2>/dev/null); do next="$next $kid"; done
    done
    queue=${next# }
  done
}

# The watchdog body, run as `( _cc_rw_round_watchdog <round pid> <secs> ) &`. TERM from the round
# (it finished in time) ends it and its sleep at once. Args: <round pid> <secs>
#
# It acts only on its own parent, and only while that parent runs resource-watch.sh: a
# watchdog orphaned (a hand-run ended with Ctrl-C) or facing a reused pid exits without a signal.
# The alert and the notification go out BEFORE the tree is ended: the watchdog is in the round's
# process group, and launchd ends that group once the round exits, so anything after the TERM may
# never run. A stopped pid in the round's own tree is ended with it, unlike a stopped act: a round
# that is held holds every later round (launchd starts none while it runs), which is the very
# failure this deadline exists for. The ERROR names such pids.
_cc_rw_round_watchdog() {
  local round=$1 secs=$2 me sp="" tree killed pid held=""
  trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
  sleep "$secs" &
  sp=$!
  wait "$sp" 2>/dev/null || exit 0
  sp=""
  kill -0 "$round" 2>/dev/null || exit 0
  # bash 3.2 (/bin/bash, launchd's) has no BASHPID: a child sh reports this subshell as its parent.
  me=${BASHPID:-$(exec sh -c 'echo $PPID')}
  [ "$(ps -o ppid= -p "$me" 2>/dev/null | tr -d ' ')" = "$round" ] || exit 0
  # The script itself, by name: a path that merely contains the words (a directory) is not it.
  case " $(ps -o command= -p "$round" 2>/dev/null) " in *"/resource-watch.sh "*|*" resource-watch.sh "*) ;; *) exit 0 ;; esac
  tree=$(_cc_rw_round_tree "$round" "$me" | tr '\n' ' ')
  tree=${tree% }
  for pid in $tree; do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in *T*) held="$held $pid" ;; esac
  done
  held=${held# }
  _cc_rw_log_line "ERROR resource-watch round ran over CC_RW_ROUND_MAX_SECONDS=${secs}s; ending the round's own tree: ${tree}${held:+ (stopped pid(s) ${held} are ended too: a held round holds every later round)} ALERT:round-overrun"
  # Bounded: a stuck osascript must not hold the TERM back, or the deadline means nothing.
  _cc_rw_run_bounded 5 _cc_rw_maybe_notify "round-overrun" "a resource-watch round ran over ${secs}s and is being ended; see resource-watch.log" "$(date +%s)"
  [ "$(ps -o ppid= -p "$me" 2>/dev/null | tr -d ' ')" = "$round" ] || exit 0   # the round ended meanwhile
  # shellcheck disable=SC2086
  killed=$(_cc_rw_end_pids 5 $tree)
  _cc_rw_log_line "ERROR resource-watch round ended (TERM: ${tree}; KILL: ${killed:-none})"
  exit 0
}

# One launchd round: heartbeat first, then the snapshot under the deadline.
_cc_rw_round() {
  local max wd=""
  _cc_rw_heartbeat
  max=$(_cc_rw_num CC_RW_ROUND_MAX_SECONDS 240)
  max=${max%.*}
  if [ "$max" -gt 0 ]; then
    ( _cc_rw_round_watchdog "$$" "$max" ) &
    wd=$!
  fi
  _cc_rw_snapshot
  if [ -n "$wd" ]; then
    kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
  fi
  return 0
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

  local disk_free_gb disk_free_pct disk_free_kb
  read -r disk_free_gb disk_free_pct disk_free_kb <<< "$disk_out"

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

  local drop_gb
  drop_gb=$(_cc_rw_disk_drop "${state_dir}/disk-free-samples" "$now" "$disk_free_gb" \
    "$(_cc_rw_disk_drop_gb)")

  # --- D7 write rate: GB/h over the last ~60 minutes of samples ---
  local rate_gbh rate_alert_gbh rate_flag_gbh rate_alert=false rate_flag=false
  rate_gbh=$(_cc_rw_disk_rate "${state_dir}/disk-free-samples.tsv" "$now" "$disk_free_kb" \
    "$(_cc_rw_num CC_RW_RATE_WINDOW_SECS 3600)" 172800)
  rate_alert_gbh=$(_cc_rw_num CC_RW_RATE_ALERT_GBH 10)
  rate_flag_gbh=$(_cc_rw_num CC_RW_RATE_FLAG_GBH 20)
  _cc_rw_above "$rate_gbh" "$rate_alert_gbh" && rate_alert=true
  _cc_rw_above "$rate_gbh" "$rate_flag_gbh" && rate_flag=true
  # Swap is the disk writer behind the 4-18 GB dips (2026-10-29 root cause: memory pressure grows
  # /System/Volumes/VM swapfiles 20 -> 26). Over CC_RW_SWAP_FLAG_GB the same disk-rate-high flag holds
  # heavy leases (with_local_resource.py), so no new next build / test suite adds memory while swap is
  # high; <state>/swap-high says which cause it is.
  # macOS never shrinks swap after the pressure ends (measured 2026-10-30: 20.9 of 22.5 GB used at
  # pressure level 1), so size alone made a flag that never cleared. The flag holds only while swap is
  # still being written: over the limit AND (pressure level >= 2 OR Swapouts grew since the previous
  # round, stored in <state>/swapouts-last). Over the limit with a readable calm signal clears it.
  # First round (no stored Swapouts): growth is unknown, not "growing"; a readable pressure < 2 then
  # decides, clearing a flag the next round re-sets within one interval if Swapouts do grow. A stuck
  # flag is the bug, and holding one round on a size-only reading would repeat it after every reinstall.
  # Over the limit with neither signal known (pressure unreadable, and growth unknown: Swapouts
  # unreadable or no stored sample) leaves swap-high as it was (neither set nor cleared), as an
  # unreadable swap does, and with it the disk-rate-high it holds. The snapshot line carries the
  # decision as swap_hot=1 (written), 0 (not hot: cleared or under the limit) or ? (left as it was),
  # which resource-watch-judge.py reads instead of re-deriving it from the size. Seams, for tests (set = replaces the read; set but empty =
  # unreadable): CC_RW_SWAP_USED_GB, CC_RW_VM_PRESSURE_LEVEL, CC_RW_SWAPOUTS.
  local swap_gb swap_flag=false swap_limit swap_pressure swapouts swapouts_prev swap_grow=unknown
  local swap_over=false swap_keep=false
  if [ "${CC_RW_SWAP_USED_GB+x}" = "x" ]; then
    swap_gb=$CC_RW_SWAP_USED_GB
  else
    swap_gb=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="used") {v=$(i+2); if (sub(/M$/,"",v)) printf "%.1f", v/1024}}')  # no M suffix: unreadable, not 0
  fi
  if [ "${CC_RW_VM_PRESSURE_LEVEL+x}" = "x" ]; then
    swap_pressure=$CC_RW_VM_PRESSURE_LEVEL
  else
    swap_pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  fi
  [[ "$swap_pressure" =~ ^[0-9]+$ ]] || swap_pressure=""
  if [ "${CC_RW_SWAPOUTS+x}" = "x" ]; then
    swapouts=$CC_RW_SWAPOUTS
  else
    swapouts=$(vm_stat 2>/dev/null | awk '/^Swapouts:/ {v=$2; sub(/\.$/,"",v); print v; exit}')
  fi
  [[ "$swapouts" =~ ^[0-9]+$ ]] || swapouts=""
  swapouts_prev=$(head -n 1 "${state_dir}/swapouts-last" 2>/dev/null || true)
  [[ "$swapouts_prev" =~ ^[0-9]+$ ]] || swapouts_prev=""
  if [ -n "$swapouts" ]; then
    if [ -n "$swapouts_prev" ]; then
      # A count below the stored one is a reboot's reset: not growth.
      if [ "$swapouts" -gt "$swapouts_prev" ]; then swap_grow=yes; else swap_grow=no; fi
    fi
    printf '%s\n' "$swapouts" > "${state_dir}/swapouts-last" 2>/dev/null
  fi
  swap_limit=$(_cc_rw_num CC_RW_SWAP_FLAG_GB 18)
  _cc_rw_above "$swap_gb" "$swap_limit" && swap_over=true
  if [ "$swap_over" = "true" ]; then
    if [ "$swap_grow" = "yes" ] || { [ -n "$swap_pressure" ] && [ "$swap_pressure" -ge 2 ]; }; then
      swap_flag=true
    elif [ -z "$swap_pressure" ] && [ "$swap_grow" = "unknown" ]; then
      swap_keep=true   # over the limit, nothing says whether it is still written: leave the flag as it is
    fi
  fi
  if [ "$swap_flag" = "true" ]; then
    printf '%s swap=%s limit=%s pressure=%s swapouts=%s\n' "$now" "$swap_gb" "$swap_limit" \
      "${swap_pressure:-?}" "${swapouts:-?}" > "${state_dir}/swap-high" 2>/dev/null
  elif [ "$swap_keep" != "true" ] && [[ "$swap_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rm -f "${state_dir}/swap-high" 2>/dev/null
  fi
  local swap_hot=0
  if [ "$swap_flag" = "true" ]; then swap_hot=1
  elif [ "$swap_keep" = "true" ] || ! [[ "$swap_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then swap_hot="?"
  fi
  if [ "$rate_flag" = "true" ] || [ "$swap_flag" = "true" ]; then
    printf '%s %s %s swap=%s\n' "$now" "${rate_gbh:-0}" "$disk_free_gb" "${swap_gb:-?}" > "${state_dir}/disk-rate-high" 2>/dev/null
  elif [ -n "$rate_gbh" ] && ! { [ "$swap_keep" = "true" ] && [ -e "${state_dir}/swap-high" ]; }; then
    # A swap-high left alone keeps the disk-rate-high it was written with.
    rm -f "${state_dir}/disk-rate-high" 2>/dev/null
  fi

  # --- the detached act: is one running, did one overrun? Every round, whatever free space is ---
  _cc_rw_act_supervise "$now"
  _cc_rw_reclaim_stall "$now"

  # --- build markers (MED-2: remove dead alert_tag variable) ---
  local markers=""
  [ "$load_breach" = "true" ] && markers="${markers} ALERT:load"
  [ "$disk_breach" = "true" ] && markers="${markers} ALERT:disk"
  [ -n "$drop_gb" ]           && markers="${markers} ALERT:disk-drop"
  [ "$swap_flag" = "true" ]   && markers="${markers} ALERT:swap"
  local alert_gb act_gb emerg_gb disk_low=false disk_act=false disk_emerg=false
  alert_gb=$(_cc_rw_num CC_RW_DISK_ALERT_GB 60); act_gb=$(_cc_rw_num CC_RW_DISK_ACT_GB 40)
  emerg_gb=$(_cc_rw_num CC_RW_DISK_EMERGENCY_GB 20)
  _cc_rw_below "$disk_free_gb" "$alert_gb" && disk_low=true
  _cc_rw_below "$disk_free_gb" "$act_gb" && disk_act=true
  _cc_rw_below "$disk_free_gb" "$emerg_gb" && disk_emerg=true
  if [ "$disk_emerg" = "true" ]; then
    printf '%s %s\n' "$now" "$disk_free_gb" > "${state_dir}/disk-emergency" 2>/dev/null
  elif [[ "$disk_free_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rm -f "${state_dir}/disk-emergency" 2>/dev/null
  fi
  # Every flag of this round is written: tell a change of the pause state, once.
  _cc_rw_pause_chain "$disk_free_gb" "$swap_gb" "$rate_gbh"
  # Started here rather than after the log line, so the line says what this round did.
  local act_started=false
  if [ "$disk_act" = "true" ] && [ "$_CC_RW_ACT_STATE" = "idle" ] \
    && _cc_rw_disk_act "$disk_free_gb" "$now"; then
    act_started=true
  fi
  [ "$disk_low" = "true" ]    && markers="${markers} ALERT:disk-low"
  [ "$disk_emerg" = "true" ]  && markers="${markers} ALERT:disk-emergency"
  [ "$rate_alert" = "true" ]  && markers="${markers} ALERT:disk-rate"
  [ "$_CC_RW_ACT_STATE" = "overrun" ] && markers="${markers} ALERT:disk-act-overrun"
  [ "$_CC_RW_ACT_STATE" = "held" ]    && markers="${markers} ALERT:disk-act-held ACT:held:${_CC_RW_ACT_PID}"
  [ "$mem_breach"  = "true" ] && markers="${markers} ALERT:mem"
  [ -n "$_CC_RW_RECLAIM_STALL_FIRE" ] && markers="${markers} ALERT:reclaim-stalled"
  [ "$act_started" = "true" ] && markers="${markers} ACT:started:${_CC_RW_ACT_PID}"
  [ "$_CC_RW_ACT_STATE" = "running" ] && markers="${markers} ACT:running:${_CC_RW_ACT_PID:-spawning}"
  [ -n "$rate_gbh" ]          && markers="${markers} disk_rate=${rate_gbh}GB/h"
  markers="${markers# }"   # ltrim space

  # --- write log line ---
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  printf '%s load=%s/%s/%s cpu_idle=%s%% mem_free=%s%% compressor=%sGB disk_free=%sGB/%s%% swap=%s rate=%s swap_hot=%s%s\n' \
    "$ts" "$load1" "$load5" "$load15" \
    "$cpu_idle" "$mem_free_pct" "$compressor_gb" \
    "$disk_free_gb" "$disk_free_pct" \
    "$(_cc_rw_val "$swap_gb" GB)" "$(_cc_rw_val "$rate_gbh" GB/h)" "$swap_hot" \
    "${markers:+ ${markers}}" \
    >> "$log_file" 2>/dev/null || true

  # --- fire notifications (LOW-3: via _cc_rw_maybe_notify helper) ---
  [ "$load_breach" = "true" ] && _cc_rw_maybe_notify "load" \
    "load1=${load1} exceeds threshold ${load_threshold} (${ncpu} cores × ${load_factor})" "$now"

  [ "$disk_breach" = "true" ] && _cc_rw_maybe_notify "disk" \
    "disk free ${disk_free_pct}% (${disk_free_gb}GB) below ${disk_min_pct}% threshold" "$now"

  [ -n "$drop_gb" ] && _cc_rw_maybe_notify "disk-drop" \
    "disk free fell ${drop_gb}GB within 45 minutes, now ${disk_free_gb}GB" "$now"

  [ "$disk_low" = "true" ] && _cc_rw_maybe_notify "disk-low" \
    "disk free ${disk_free_gb}GB below ${alert_gb}GB" "$now"

  [ "$disk_emerg" = "true" ] && _cc_rw_maybe_notify "disk-emergency" \
    "EMERGENCY: disk free ${disk_free_gb}GB below ${emerg_gb}GB" "$now"

  [ "$rate_alert" = "true" ] && _cc_rw_maybe_notify "disk-rate" \
    "disk filling at ${rate_gbh}GB/h, now ${disk_free_gb}GB free" "$now"

  [ "$_CC_RW_ACT_STATE" = "overrun" ] && _cc_rw_maybe_notify "disk-act-overrun" \
    "disk reclaim ran past its cap and was ended; see resource-watch.log" "$now"

  [ "$_CC_RW_ACT_STATE" = "held" ] && _cc_rw_maybe_notify "disk-act-held" \
    "disk reclaim pid ${_CC_RW_ACT_PID} is stopped (operator hold); no reclaim runs until it is continued or ended" "$now"

  [ -n "$_CC_RW_RECLAIM_STALL_FIRE" ] && _cc_rw_notify "reclaim-stalled" "$_CC_RW_RECLAIM_STALL_FIRE"

  [ "$mem_breach"  = "true" ] && _cc_rw_maybe_notify "mem" \
    "mem free ${mem_free_pct}% below ${mem_min_pct}% and compressor ${compressor_gb}GB above ${comp_threshold_gb}GB" "$now"

  # --- disk guard: the go cache cap every run, bounded so the round stays short ---
  local reclaim_script="${CC_RW_RECLAIM_SCRIPT:-$HOME/.cc-reaper/reclaim-byproducts.sh}"
  if [ "${CC_RW_GO_CAP:-1}" != "0" ] && [ -f "$reclaim_script" ]; then
    _cc_rw_run_bounded "$(_cc_rw_num CC_RW_GO_CAP_MAX_SECONDS 120)" \
      bash "$reclaim_script" --go-cache-cap >> "$(_cc_rw_act_log)" 2>&1
  fi

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
        _cc_rw_round
        ;;
      --act)
        # internal: the detached reclaim a round starts (see _cc_rw_disk_act)
        _cc_rw_act_main "${2:-}"
        exit $?
        ;;
      *)
        echo "resource-watch: unknown option '$1'" >&2
        _cc_rw_usage >&2
        exit 2
        ;;
    esac
  fi
fi
