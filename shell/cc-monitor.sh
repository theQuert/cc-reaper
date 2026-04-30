#!/usr/bin/env bash
# cc-monitor: read-only heat attribution for cc-reaper.
#
# Can be sourced for the cc-monitor shell function or executed directly:
#   bash shell/cc-monitor.sh --once

_cc_monitor_usage() {
  cat <<'EOF'
Usage: cc-monitor [options]

Read-only process heat attribution for cc-reaper.

Options:
  --once              Take one snapshot and return immediately
  --json              Print JSON only
  --duration SECONDS  Sampling duration (default: 60)
  --interval SECONDS  Sampling interval (default: 5)
  --top N             Number of top contributors in human output (default: 10)
  --min-cpu PERCENT   Minimum average CPU to report, except safe candidates (default: 1)
  -h, --help          Show this help

Environment:
  CC_MONITOR_DURATION      Default duration override
  CC_MONITOR_INTERVAL      Default interval override
  CC_MONITOR_TOP           Default top contributor count
  CC_MONITOR_MIN_CPU       Default CPU reporting floor
  CC_MONITOR_SNAPSHOT_FILE Test hook: read tab-separated snapshots from a file
EOF
}

_cc_monitor_is_positive_number() {
  echo "$1" | grep -qE '^[0-9]+([.][0-9]+)?$'
}

_cc_monitor_is_positive_int() {
  echo "$1" | grep -qE '^[0-9]+$' && [ "$1" -gt 0 ]
}

_cc_monitor_etime_to_seconds() {
  echo "${1// /}" | awk '
    {
      days=0
      time_part=$0
      if (index(time_part, "-") > 0) {
        split(time_part, day_parts, "-")
        days=day_parts[1]+0
        time_part=day_parts[2]
      }
      split(time_part, parts, ":")
      if (length(parts[3]) > 0) {
        print days * 86400 + (parts[1]+0) * 3600 + (parts[2]+0) * 60 + (parts[3]+0)
      } else if (length(parts[2]) > 0) {
        print days * 86400 + (parts[1]+0) * 60 + (parts[2]+0)
      } else {
        print days * 86400 + (parts[1]+0)
      }
    }
  '
}

_cc_monitor_agent_stale_seconds() {
  local minutes=${CC_AGENT_STALE_MINUTES:-360}
  if ! echo "$minutes" | grep -qE '^[0-9]+$' || [ "$minutes" -eq 0 ]; then
    minutes=360
  fi
  echo $((minutes * 60))
}

_cc_monitor_is_stale_etime() {
  local etime=$1
  local seconds
  seconds=$(_cc_monitor_etime_to_seconds "$etime")
  [ "$seconds" -ge "$(_cc_monitor_agent_stale_seconds)" ]
}

_cc_monitor_is_detached_or_orphan() {
  local ppid=$1
  local tty=$2
  [ "$ppid" = "1" ] || [ "$tty" = "??" ] || [ "$tty" = "?" ]
}

_cc_monitor_protected_pattern() {
  echo "node.*(dev-server|http-server|next.*server)|pm2|npm exec @supabase|mcp-server-supabase|supabase.*mcp|npm exec @stripe|@stripe/mcp|mcp-server-stripe|stripe.*mcp|claude-mem|chroma-mcp|cloudflare/mcp-server|sequentialthinking|codex.*mcp|ChatGPT\\.app|cmux\\.app|Bitdefender|mdworker|mds_stores"
}

_cc_monitor_is_protected_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "$(_cc_monitor_protected_pattern)"
}

_cc_monitor_is_agent_browser_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "agent-browser-darwin-arm64|Google Chrome for Testing.*agent-browser-chrome-|agent-browser-chrome-"
}

_cc_monitor_is_puppeteer_chrome_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "puppeteer_dev_chrome_profile-"
}

_cc_monitor_is_codex_agent_cmd() {
  local cmd=$1
  if echo "$cmd" | grep -qE "codex app-server|app-server-broker"; then
    return 1
  fi
  echo "$cmd" | grep -qE "node /usr/local/bin/codex( --yolo| resume|$)|@openai/codex.*/codex/codex( --yolo| resume|$)|/codex/codex( --yolo| resume|$)|(^|/)codex( --yolo| resume|$)"
}

_cc_monitor_is_claude_agent_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "claude.*stream-json|claude.*--session-id|claude --dangerously"
}

_cc_monitor_is_agent_mcp_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "npm exec @upstash/context7-mcp|context7-mcp|chrome-devtools-mcp|npm exec mcp-remote|mcp-remote|npm exec mcp-|npx.*mcp-server"
}

_cc_monitor_is_dev_server_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "react-scripts/scripts/start|react-scripts start|next dev|vite( --host| --port|$)|webpack-dev-server|astro dev|node.*(dev-server|http-server|next.*server)|npm run dev|pnpm dev|yarn dev"
}

_cc_monitor_is_system_cmd() {
  local cmd=$1
  echo "$cmd" | grep -qE "WindowServer|kernel_task|coreaudiod|syspolicyd|mdworker|mds_stores|Spotlight|Bitdefender|com\\.apple\\.|/System/Library/"
}

_cc_monitor_is_normal_chrome_cmd() {
  local cmd=$1
  if _cc_monitor_is_agent_browser_cmd "$cmd" || _cc_monitor_is_puppeteer_chrome_cmd "$cmd"; then
    return 1
  fi
  echo "$cmd" | grep -qE "Google Chrome\\.app|Google Chrome Helper|/Google Chrome( |$)|Chromium\\.app"
}

_cc_monitor_is_safe_candidate() {
  local ppid=$1
  local tty=$2
  local etime=$3
  local cmd=$4

  _cc_monitor_is_protected_cmd "$cmd" && return 1
  _cc_monitor_is_dev_server_cmd "$cmd" && return 1
  _cc_monitor_is_system_cmd "$cmd" && return 1
  _cc_monitor_is_normal_chrome_cmd "$cmd" && return 1

  if _cc_monitor_is_claude_agent_cmd "$cmd"; then
    [ "$ppid" = "1" ] || { _cc_monitor_is_detached_or_orphan "$ppid" "$tty" && _cc_monitor_is_stale_etime "$etime"; }
    return
  fi

  if _cc_monitor_is_agent_browser_cmd "$cmd" || _cc_monitor_is_puppeteer_chrome_cmd "$cmd"; then
    [ "$ppid" = "1" ] || _cc_monitor_is_stale_etime "$etime"
    return
  fi

  if _cc_monitor_is_codex_agent_cmd "$cmd" || _cc_monitor_is_agent_mcp_cmd "$cmd"; then
    [ "$ppid" = "1" ] || { _cc_monitor_is_detached_or_orphan "$ppid" "$tty" && _cc_monitor_is_stale_etime "$etime"; }
    return
  fi

  return 1
}

_cc_monitor_family() {
  local cmd=$1
  if _cc_monitor_is_system_cmd "$cmd"; then
    echo "system"
  elif _cc_monitor_is_agent_browser_cmd "$cmd" || _cc_monitor_is_puppeteer_chrome_cmd "$cmd"; then
    echo "agent-browser"
  elif _cc_monitor_is_dev_server_cmd "$cmd"; then
    echo "dev-server"
  elif _cc_monitor_is_agent_mcp_cmd "$cmd"; then
    echo "mcp"
  elif _cc_monitor_is_codex_agent_cmd "$cmd"; then
    echo "codex"
  elif _cc_monitor_is_claude_agent_cmd "$cmd"; then
    echo "claude"
  elif echo "$cmd" | grep -qE "Cursor Helper|Cursor\\.app|Visual Studio Code|Code Helper|/Code\\.app|/Cursor\\.app"; then
    echo "editor"
  elif echo "$cmd" | grep -qE "(^|/)cmux( |$)|cmux\\.app"; then
    echo "cmux"
  elif _cc_monitor_is_normal_chrome_cmd "$cmd"; then
    echo "chrome"
  else
    echo "other"
  fi
}

_cc_monitor_classification() {
  local ppid=$1
  local tty=$2
  local etime=$3
  local cmd=$4
  local family=$5

  if _cc_monitor_is_safe_candidate "$ppid" "$tty" "$etime" "$cmd"; then
    echo "SAFE_TO_REAP"
  elif [ "$family" = "system" ] || [ "$family" = "chrome" ]; then
    echo "DO_NOT_KILL"
  elif _cc_monitor_is_protected_cmd "$cmd" && [ "$family" != "cmux" ]; then
    echo "DO_NOT_KILL"
  else
    echo "ASK_BEFORE_KILL"
  fi
}

_cc_monitor_reason() {
  local classification=$1
  local family=$2
  local cmd=$3

  case "$classification:$family" in
    SAFE_TO_REAP:agent-browser)
      echo "stale or orphaned browser automation matches cc-reaper cleanup criteria" ;;
    SAFE_TO_REAP:codex)
      echo "stale or orphaned Codex background process matches cleanup criteria" ;;
    SAFE_TO_REAP:mcp)
      echo "detached or stale MCP subprocess matches cleanup criteria" ;;
    SAFE_TO_REAP:claude)
      echo "detached or orphaned Claude agent process matches cleanup criteria" ;;
    SAFE_TO_REAP:*)
      echo "matches existing cc-reaper stale or orphan cleanup criteria" ;;
    ASK_BEFORE_KILL:editor)
      echo "editor renderer is an active user app; close or restart it intentionally" ;;
    ASK_BEFORE_KILL:cmux)
      echo "cmux is an active terminal/session manager; inspect panes first" ;;
    ASK_BEFORE_KILL:dev-server)
      echo "development server may be serving current work; stop it from its terminal if unused" ;;
    ASK_BEFORE_KILL:agent-browser)
      echo "browser automation appears active or recent; confirm no test is running first" ;;
    ASK_BEFORE_KILL:codex|ASK_BEFORE_KILL:claude)
      echo "agent session appears attached or recent; exit the session before killing" ;;
    ASK_BEFORE_KILL:mcp)
      echo "MCP process may be shared or attached; confirm ownership before stopping" ;;
    DO_NOT_KILL:system)
      echo "system, security, or UI process; do not terminate directly" ;;
    DO_NOT_KILL:chrome)
      echo "normal Chrome browsing process; close tabs/windows instead of using cc-reaper" ;;
    DO_NOT_KILL:mcp)
      echo "shared MCP service matched cc-reaper safety boundaries" ;;
    DO_NOT_KILL:*)
      echo "protected process matched cc-reaper safety boundaries" ;;
    *)
      if echo "$cmd" | grep -qE "ChatGPT\\.app"; then
        echo "ChatGPT.app is protected user software"
      else
        echo "unknown process family; inspect manually before killing"
      fi
      ;;
  esac
}

_cc_monitor_action() {
  local classification=$1
  local family=$2
  local pid=$3

  case "$classification:$family" in
    SAFE_TO_REAP:*)
      echo "Run claude-cleanup to reap safe stale/orphan candidates, then rerun cc-monitor." ;;
    ASK_BEFORE_KILL:editor)
      echo "Close or restart the hot editor window if it is not needed." ;;
    ASK_BEFORE_KILL:cmux)
      echo "Inspect cmux panes and close idle panes before killing cmux itself." ;;
    ASK_BEFORE_KILL:dev-server)
      echo "Stop unused dev server PID $pid from its owning terminal." ;;
    ASK_BEFORE_KILL:agent-browser)
      echo "If browser automation is not actively testing, stop that session or run claude-cleanup after confirming it is stale." ;;
    ASK_BEFORE_KILL:codex|ASK_BEFORE_KILL:claude)
      echo "Exit the attached agent session cleanly before considering a kill." ;;
    ASK_BEFORE_KILL:mcp)
      echo "Check which agent owns the MCP process before stopping it." ;;
    DO_NOT_KILL:system)
      echo "Do not kill system/security/UI processes; reduce workload or wait for the system task to finish." ;;
    DO_NOT_KILL:chrome)
      echo "Close heavy Chrome tabs or windows; do not use cc-reaper for normal browsing." ;;
    DO_NOT_KILL:mcp)
      echo "Leave shared MCP services running unless you know no active session depends on them." ;;
    *)
      echo "Inspect PID $pid manually before taking action." ;;
  esac
}

_cc_monitor_redact_cmd() {
  printf "%s" "$1" | sed -E \
    -e 's/(--access-token[= ]?)[^ ]+/\1[redacted]/g' \
    -e 's/(--api[-_]key[= ]?)[^ ]+/\1[redacted]/g' \
    -e 's/(--secret[-_a-zA-Z]*[= ]?)[^ ]+/\1[redacted]/g' \
    -e 's/(--password[= ]?)[^ ]+/\1[redacted]/g' \
    -e 's/([A-Za-z_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Za-z_]*=)[^ ]+/\1[redacted]/g'
}

_cc_monitor_label() {
  local family=$1
  local cmd=$2

  if echo "$cmd" | grep -q "Cursor Helper"; then
    echo "Cursor Helper"
  elif echo "$cmd" | grep -q "Visual Studio Code"; then
    echo "VS Code"
  elif echo "$cmd" | grep -q "WindowServer"; then
    echo "WindowServer"
  elif echo "$cmd" | grep -q "agent-browser-darwin-arm64"; then
    echo "agent-browser"
  elif echo "$cmd" | grep -q "puppeteer_dev_chrome_profile"; then
    echo "Puppeteer Chrome"
  elif echo "$cmd" | grep -q "Google Chrome for Testing"; then
    echo "Chrome for Testing"
  elif echo "$cmd" | grep -q "react-scripts"; then
    echo "react-scripts start"
  elif echo "$cmd" | grep -q "chrome-devtools-mcp"; then
    echo "chrome-devtools-mcp"
  elif echo "$cmd" | grep -qE "(^|/)cmux( |$)|cmux\\.app"; then
    echo "cmux"
  elif [ "$family" = "chrome" ]; then
    echo "Google Chrome"
  else
    echo "$cmd" | awk '{name=$1; sub(/^.*\//, "", name); if (name == "") name="process"; print name}'
  fi
}

_cc_monitor_snapshot() {
  if [ -n "${CC_MONITOR_SNAPSHOT_FILE:-}" ]; then
    cat "$CC_MONITOR_SNAPSHOT_FILE"
    return
  fi

  ps -axo pid=,ppid=,pgid=,tty=,etime=,%cpu=,rss=,command= 2>/dev/null | awk '
    BEGIN { OFS="\t" }
    {
      pid=$1; ppid=$2; pgid=$3; tty=$4; etime=$5; cpu=$6; rss=$7
      cmd=""
      for (i=8; i<=NF; i++) {
        cmd = cmd (i == 8 ? "" : " ") $i
      }
      gsub(/\t/, " ", cmd)
      if (pid ~ /^[0-9]+$/ && cpu ~ /^[0-9.]+$/ && rss ~ /^[0-9]+$/) {
        print pid, ppid, pgid, tty, etime, cpu, rss, cmd
      }
    }
  '
}

_cc_monitor_collect_samples() {
  local outfile=$1
  local once=$2
  local duration=$3
  local interval=$4
  local progress=$5

  : > "$outfile"
  if [ "$once" = "true" ]; then
    [ "$progress" = "true" ] && printf "cc-monitor: collecting one process snapshot..." >&2
    _cc_monitor_snapshot >> "$outfile"
    [ "$progress" = "true" ] && printf " done\n" >&2
    echo 1
    return
  fi

  local elapsed=0
  local samples=0
  if [ "$progress" = "true" ]; then
    printf "cc-monitor: sampling process state for %ss every %ss" "$duration" "$interval" >&2
  fi
  while :; do
    _cc_monitor_snapshot >> "$outfile"
    samples=$((samples + 1))
    [ "$progress" = "true" ] && printf "." >&2
    [ "$elapsed" -ge "$duration" ] && break
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  [ "$progress" = "true" ] && printf " done (%s snapshots)\n" "$samples" >&2
  echo "$samples"
}

_cc_monitor_aggregate_samples() {
  local raw_file=$1
  local out_file=$2

  awk -F '\t' '
    BEGIN { OFS="\t" }
    NF >= 8 {
      pid=$1; ppid=$2; pgid=$3; tty=$4; etime=$5; cpu=$6+0; rss=$7+0; cmd=$8
      key=pid SUBSEP cmd
      if (!(key in count)) {
        first_order[++n]=key
        last_ppid[key]=ppid
        last_pgid[key]=pgid
        last_tty[key]=tty
        last_etime[key]=etime
      }
      count[key]++
      sum_cpu[key]+=cpu
      if (cpu > max_cpu[key]) max_cpu[key]=cpu
      if (rss > max_rss[key]) max_rss[key]=rss
      last_ppid[key]=ppid
      last_pgid[key]=pgid
      last_tty[key]=tty
      last_etime[key]=etime
    }
    END {
      for (i=1; i<=n; i++) {
        key=first_order[i]
        split(key, parts, SUBSEP)
        pid=parts[1]
        cmd=parts[2]
        avg=sum_cpu[key]/count[key]
        rss_mb=int(max_rss[key]/1024 + 0.5)
        printf "%.2f\t%.2f\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n",
          avg, max_cpu[key], count[key], pid, last_ppid[key], last_pgid[key],
          last_tty[key], last_etime[key], rss_mb, cmd
      }
    }
  ' "$raw_file" | sort -k1,1nr > "$out_file"
}

_cc_monitor_float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !((a+0) >= (b+0)) }'
}

_cc_monitor_enrich_findings() {
  local agg_file=$1
  local out_file=$2
  local min_cpu=$3
  local filtered_file="${out_file}.prefilter"

  : > "$out_file"
  awk -F '\t' -v min_cpu="$min_cpu" '
    ($1+0) >= (min_cpu+0) || $10 ~ /agent-browser|puppeteer_dev_chrome_profile|Chrome for Testing|codex|claude|mcp|stream-json/ {
      print
    }
  ' "$agg_file" > "$filtered_file"

  while IFS="$(printf '\t')" read -r avg_cpu max_cpu row_samples pid ppid pgid tty etime rss_mb cmd; do
    [ -z "$pid" ] && continue
    local family="" classification="" label="" reason="" action=""
    family=$(_cc_monitor_family "$cmd")
    classification=$(_cc_monitor_classification "$ppid" "$tty" "$etime" "$cmd" "$family")

    if [ "$classification" != "SAFE_TO_REAP" ] && ! _cc_monitor_float_ge "$avg_cpu" "$min_cpu"; then
      continue
    fi

    label=$(_cc_monitor_label "$family" "$cmd")
    reason=$(_cc_monitor_reason "$classification" "$family" "$cmd")
    action=$(_cc_monitor_action "$classification" "$family" "$pid")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$avg_cpu" "$max_cpu" "$row_samples" "$pid" "$ppid" "$pgid" "$tty" "$etime" \
      "$rss_mb" "$family" "$classification" "$label" "$reason" "$action" "$cmd" >> "$out_file"
  done < "$filtered_file"

  rm -f "$filtered_file"
}

_cc_monitor_family_totals() {
  local findings_file=$1
  awk -F '\t' '
    BEGIN { OFS="\t" }
    NF >= 15 {
      family=$10
      cpu[family]+=$1
      rss[family]+=$9
      count[family]++
    }
    END {
      for (family in cpu) {
        printf "%s\t%.2f\t%d\t%d\n", family, cpu[family], rss[family], count[family]
      }
    }
  ' "$findings_file" | sort -k2,2nr
}

_cc_monitor_json_escape() {
  printf "%s" "$1" | awk '
    {
      gsub(/\\/,"\\\\")
      gsub(/"/,"\\\"")
      gsub(/\t/,"\\t")
      gsub(/\r/,"\\r")
      gsub(/\n/,"\\n")
      printf "%s", $0
    }
  '
}

_cc_monitor_human_report() {
  local findings_file=$1
  local duration=$2
  local interval=$3
  local samples=$4
  local once=$5
  local top=$6

  echo "=== cc-monitor: heat attribution ==="
  if [ "$once" = "true" ]; then
    echo "Sample: once, snapshots: $samples"
  else
    echo "Sample: ${duration}s, interval: ${interval}s, snapshots: $samples"
  fi
  echo "Mode: read-only (no signals sent)"
  echo ""

  echo "Top contributors:"
  if [ ! -s "$findings_file" ]; then
    echo "  none above reporting threshold"
  else
    awk -F '\t' -v top="$top" '
      NF >= 15 && shown < top {
        shown++
        printf "  %2d. %-24.24s pid %-7s avg %6.2f%% max %6.2f%% rss %5d MB  %-16s %s\n",
          shown, $12, $4, $1, $2, $9, $11, $10
      }
    ' "$findings_file"
  fi

  echo ""
  echo "Family totals:"
  local family_totals
  family_totals=$(_cc_monitor_family_totals "$findings_file")
  if [ -z "$family_totals" ]; then
    echo "  none"
  else
    echo "$family_totals" | awk -F '\t' '
      { printf "  %-14s avg %6.2f%% rss %5d MB processes %d\n", $1, $2, $3, $4 }
    '
  fi

  echo ""
  echo "Safe cleanup candidates:"
  local safe_count
  safe_count=$(awk -F '\t' '$11 == "SAFE_TO_REAP" { count++ } END { print count+0 }' "$findings_file")
  if [ "$safe_count" -eq 0 ]; then
    echo "  none"
  else
    awk -F '\t' '
      $11 == "SAFE_TO_REAP" {
        printf "  PID %-7s %-14s avg %6.2f%% max %6.2f%% - %s\n", $4, $10, $1, $2, $13
      }
    ' "$findings_file"
  fi

  echo ""
  echo "Suggested actions:"
  awk -F '\t' '
    NF >= 15 && !seen[$14]++ {
      printf "  - %s\n", $14
      count++
    }
    END {
      if (count == 0) print "  - No action needed from this sample."
    }
  ' "$findings_file"
}

_cc_monitor_json_report() {
  local findings_file=$1
  local duration=$2
  local interval=$3
  local samples=$4
  local once=$5

  local mode="sample"
  [ "$once" = "true" ] && mode="once"

  printf '{\n'
  printf '  "sample_seconds": %s,\n' "$duration"
  printf '  "interval_seconds": %s,\n' "$interval"
  printf '  "sample_count": %s,\n' "$samples"
  printf '  "mode": "%s",\n' "$mode"
  printf '  "read_only": true,\n'
  printf '  "findings": [\n'

  local first=true
  while IFS="$(printf '\t')" read -r avg_cpu max_cpu sample_count pid ppid pgid tty etime rss_mb family classification label reason action cmd; do
    [ -z "$pid" ] && continue
    if [ "$first" = "true" ]; then
      first=false
    else
      printf ',\n'
    fi
    printf '    {"pid": %s, "ppid": %s, "pgid": %s, "family": "%s", "classification": "%s", "label": "%s", "avg_cpu": %.2f, "max_cpu": %.2f, "rss_mb": %s, "samples": %s, "elapsed": "%s", "reason": "%s", "suggested_action": "%s", "command": "%s"}' \
      "$pid" "$ppid" "$pgid" \
      "$(_cc_monitor_json_escape "$family")" \
      "$(_cc_monitor_json_escape "$classification")" \
      "$(_cc_monitor_json_escape "$label")" \
      "$avg_cpu" "$max_cpu" "$rss_mb" "$sample_count" \
      "$(_cc_monitor_json_escape "$etime")" \
      "$(_cc_monitor_json_escape "$reason")" \
      "$(_cc_monitor_json_escape "$action")" \
      "$(_cc_monitor_json_escape "$(_cc_monitor_redact_cmd "$cmd")")"
  done < "$findings_file"

  printf '\n  ],\n'
  printf '  "family_totals": [\n'
  first=true
  _cc_monitor_family_totals "$findings_file" | while IFS="$(printf '\t')" read -r family avg_cpu rss_mb count; do
    [ -z "$family" ] && continue
    if [ "$first" = "true" ]; then
      first=false
    else
      printf ',\n'
    fi
    printf '    {"family": "%s", "avg_cpu": %.2f, "rss_mb": %s, "processes": %s}' \
      "$(_cc_monitor_json_escape "$family")" "$avg_cpu" "$rss_mb" "$count"
  done
  printf '\n  ],\n'

  printf '  "safe_cleanup_candidates": [\n'
  first=true
  while IFS="$(printf '\t')" read -r avg_cpu max_cpu sample_count pid ppid pgid tty etime rss_mb family classification label reason action cmd; do
    [ "$classification" = "SAFE_TO_REAP" ] || continue
    if [ "$first" = "true" ]; then
      first=false
    else
      printf ',\n'
    fi
    printf '    {"pid": %s, "family": "%s", "avg_cpu": %.2f, "reason": "%s"}' \
      "$pid" "$(_cc_monitor_json_escape "$family")" "$avg_cpu" "$(_cc_monitor_json_escape "$reason")"
  done < "$findings_file"
  printf '\n  ],\n'

  printf '  "suggested_actions": [\n'
  first=true
  awk -F '\t' 'NF >= 15 && !seen[$14]++ { print $14 }' "$findings_file" | while IFS= read -r action; do
    [ -n "$action" ] || continue
    if [ "$first" = "true" ]; then
      first=false
    else
      printf ',\n'
    fi
    printf '    "%s"' "$(_cc_monitor_json_escape "$action")"
  done
  printf '\n  ]\n'
  printf '}\n'
}

_cc_monitor_module_command() {
  case "$1" in
    claude-cleanup)       echo "claude-cleanup" ;;
    claude-guard)         echo "claude-guard" ;;
    claude-guard-dry)     echo "claude-guard --dry-run" ;;
    proc-janitor-scan)    echo "proc-janitor scan" ;;
    proc-janitor-clean)   echo "proc-janitor clean" ;;
    *) return 1 ;;
  esac
}

_cc_monitor_module_label() {
  case "$1" in
    claude-cleanup)       echo "claude-cleanup (kill all stale orphans)" ;;
    claude-guard)         echo "claude-guard (kill RSS/FD/idle violators)" ;;
    claude-guard-dry)     echo "claude-guard --dry-run (preview only)" ;;
    proc-janitor-scan)    echo "proc-janitor scan (preview only)" ;;
    proc-janitor-clean)   echo "proc-janitor clean (kill detected orphans)" ;;
    *) return 1 ;;
  esac
}

_cc_monitor_module_destructive() {
  case "$1" in
    claude-cleanup|claude-guard|proc-janitor-clean) return 0 ;;
    *) return 1 ;;
  esac
}

_cc_monitor_module_binary() {
  case "$1" in
    claude-cleanup)                       echo "claude-cleanup" ;;
    claude-guard|claude-guard-dry)        echo "claude-guard" ;;
    proc-janitor-scan|proc-janitor-clean) echo "proc-janitor" ;;
    *) return 1 ;;
  esac
}

_cc_monitor_module_available() {
  local binary
  binary=$(_cc_monitor_module_binary "$1") || return 1
  command -v "$binary" >/dev/null 2>&1
}

_cc_monitor_install_hint() {
  case "$1" in
    claude-cleanup|claude-guard|claude-guard-dry)
      echo "source shell/claude-cleanup.sh from this repo"
      ;;
    proc-janitor-scan|proc-janitor-clean)
      echo "brew install proc-janitor (or cargo install proc-janitor)"
      ;;
  esac
}

_cc_monitor_recommended_module() {
  local findings_file=$1
  if awk -F '\t' '$11 == "SAFE_TO_REAP" { found=1; exit } END { exit !found }' "$findings_file"; then
    echo "claude-cleanup"
    return 0
  fi
  if awk -F '\t' '
      ($1+0) >= 60 { hot=1 }
      { rss[$10]+=$9 }
      END {
        if (hot) exit 0
        for (f in rss) if (rss[f] >= 1024) exit 0
        exit 1
      }
    ' "$findings_file"; then
    echo "claude-guard-dry"
    return 0
  fi
  return 1
}

_cc_monitor_is_tty() {
  [ -t 0 ] && [ -t 1 ]
}

_cc_monitor_prompt_apply() {
  local findings_file=$1
  local recommended=""
  recommended=$(_cc_monitor_recommended_module "$findings_file") || recommended=""

  local all_modules=(claude-cleanup claude-guard claude-guard-dry proc-janitor-scan proc-janitor-clean)
  local available=() unavailable=()
  local m
  for m in "${all_modules[@]}"; do
    if _cc_monitor_module_available "$m"; then
      available+=("$m")
    else
      unavailable+=("$m")
    fi
  done

  if [ "${#available[@]}" -eq 0 ]; then
    printf "\nOptimization options: none available on PATH.\n" >&2
    for m in "${all_modules[@]}"; do
      printf "  -  %s — install: %s\n" "$(_cc_monitor_module_label "$m")" "$(_cc_monitor_install_hint "$m")" >&2
    done
    return 1
  fi

  printf "\nOptimization options:\n" >&2
  local i=0 mark
  for m in "${available[@]}"; do
    i=$((i + 1))
    mark=""
    [ "$m" = "$recommended" ] && mark=" (recommended)"
    printf "  %d. %s%s\n" "$i" "$(_cc_monitor_module_label "$m")" "$mark" >&2
  done
  local skip_index=$((i + 1))
  printf "  %d. skip\n" "$skip_index" >&2
  for m in "${unavailable[@]}"; do
    printf "  -  %s — install: %s\n" "$(_cc_monitor_module_label "$m")" "$(_cc_monitor_install_hint "$m")" >&2
  done
  printf "> " >&2

  local choice=""
  if ! { read -r choice < /dev/tty; } 2>/dev/null; then
    return 1
  fi

  if [ -z "$choice" ] || [ "$choice" = "$skip_index" ]; then
    return 1
  fi

  if echo "$choice" | grep -qE '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "${#available[@]}" ]; then
    echo "${available[$((choice - 1))]}"
    return 0
  fi
  return 1
}

_cc_monitor_dispatch_module() {
  local module=$1
  local skip_confirm=$2

  if ! _cc_monitor_module_available "$module"; then
    local binary
    binary=$(_cc_monitor_module_binary "$module")
    echo "cc-monitor: module '$module' not available on PATH (binary: $binary)" >&2
    return 127
  fi

  if [ "$skip_confirm" != "true" ] && _cc_monitor_module_destructive "$module"; then
    local label
    label=$(_cc_monitor_module_label "$module")
    printf "Run %s? [y/N] " "$label" >&2
    local answer=""
    if ! { read -r answer < /dev/tty; } 2>/dev/null; then
      return 0
    fi
    case "$answer" in
      y|Y|yes|YES) ;;
      *) return 0 ;;
    esac
  fi

  local cmd
  cmd=$(_cc_monitor_module_command "$module")
  # shellcheck disable=SC2086
  eval "command $cmd"
}

cc-monitor() {
  local once=false
  local json=false
  local duration=${CC_MONITOR_DURATION:-60}
  local interval=${CC_MONITOR_INTERVAL:-5}
  local top=${CC_MONITOR_TOP:-10}
  local min_cpu=${CC_MONITOR_MIN_CPU:-1}
  local apply_module=""
  local no_prompt=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --once)
        once=true
        shift
        ;;
      --json)
        json=true
        shift
        ;;
      --duration)
        [ "$#" -ge 2 ] || { echo "cc-monitor: --duration requires a value" >&2; return 2; }
        duration=$2
        shift 2
        ;;
      --interval)
        [ "$#" -ge 2 ] || { echo "cc-monitor: --interval requires a value" >&2; return 2; }
        interval=$2
        shift 2
        ;;
      --top)
        [ "$#" -ge 2 ] || { echo "cc-monitor: --top requires a value" >&2; return 2; }
        top=$2
        shift 2
        ;;
      --min-cpu)
        [ "$#" -ge 2 ] || { echo "cc-monitor: --min-cpu requires a value" >&2; return 2; }
        min_cpu=$2
        shift 2
        ;;
      --apply)
        [ "$#" -ge 2 ] || { echo "cc-monitor: --apply requires a module name" >&2; return 2; }
        apply_module=$2
        shift 2
        ;;
      --no-prompt)
        no_prompt=true
        shift
        ;;
      -h|--help)
        _cc_monitor_usage
        return 0
        ;;
      *)
        echo "cc-monitor: unknown option '$1'" >&2
        _cc_monitor_usage >&2
        return 2
        ;;
    esac
  done

  if [ -n "$apply_module" ] && [ "$json" = "true" ]; then
    echo "cc-monitor: --apply cannot be combined with --json" >&2
    return 2
  fi

  if [ -n "$apply_module" ]; then
    case "$apply_module" in
      claude-cleanup|claude-guard|claude-guard-dry|proc-janitor-scan|proc-janitor-clean) ;;
      *)
        echo "cc-monitor: unknown module '$apply_module'. Valid: claude-cleanup, claude-guard, claude-guard-dry, proc-janitor-scan, proc-janitor-clean" >&2
        return 2
        ;;
    esac
  fi

  _cc_monitor_is_positive_int "$duration" || { echo "cc-monitor: duration must be a positive integer" >&2; return 2; }
  _cc_monitor_is_positive_int "$interval" || { echo "cc-monitor: interval must be a positive integer" >&2; return 2; }
  _cc_monitor_is_positive_int "$top" || { echo "cc-monitor: top must be a positive integer" >&2; return 2; }
  _cc_monitor_is_positive_number "$min_cpu" || { echo "cc-monitor: min-cpu must be numeric" >&2; return 2; }

  if [ "$once" = "true" ]; then
    duration=0
  fi

  local tmp_dir="" raw_file="" agg_file="" findings_file="" samples=""
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cc-monitor.XXXXXX") || return 1
  raw_file="$tmp_dir/raw.tsv"
  agg_file="$tmp_dir/agg.tsv"
  findings_file="$tmp_dir/findings.tsv"

  local progress=false
  [ "$json" = "false" ] && progress=true

  samples=$(_cc_monitor_collect_samples "$raw_file" "$once" "$duration" "$interval" "$progress")
  _cc_monitor_aggregate_samples "$raw_file" "$agg_file"
  _cc_monitor_enrich_findings "$agg_file" "$findings_file" "$min_cpu"

  local dispatch_rc=0
  if [ "$json" = "true" ]; then
    _cc_monitor_json_report "$findings_file" "$duration" "$interval" "$samples" "$once"
  else
    _cc_monitor_human_report "$findings_file" "$duration" "$interval" "$samples" "$once" "$top"

    if [ -n "$apply_module" ]; then
      _cc_monitor_dispatch_module "$apply_module" "true"
      dispatch_rc=$?
    elif [ "$no_prompt" != "true" ] && _cc_monitor_is_tty; then
      local recommended=""
      recommended=$(_cc_monitor_recommended_module "$findings_file") || recommended=""
      if [ -n "$recommended" ]; then
        local chosen=""
        chosen=$(_cc_monitor_prompt_apply "$findings_file") || chosen=""
        if [ -n "$chosen" ]; then
          _cc_monitor_dispatch_module "$chosen" "false"
          dispatch_rc=$?
        fi
      fi
    fi
  fi

  rm -rf "$tmp_dir"
  return "$dispatch_rc"
}

if [ -n "${BASH_VERSION:-}" ]; then
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cc-monitor "$@"
  fi
fi
