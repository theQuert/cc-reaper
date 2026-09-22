#!/usr/bin/env bash
# Invoke cc-reaper at an external lifecycle boundary.
#
# CI and review systems have different event names, so the adapter owns the mapping
# and passes only a small stage vocabulary here. The janitors still own all safety
# gates; this hook never deletes by path or bypasses a claim/holder check.
set -u

usage() {
  cat >&2 <<'EOF'
Usage: lifecycle-reclaim.sh --stage session-end|pr-merged|merge-gate-complete|staging-complete
                            [--repo PATH] [--drain-proof FILE]
EOF
}

stage=""
repo="${CC_REAPER_REPO:-}"
proof=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage) stage="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --drain-proof) proof="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

case "$stage" in
  session-end|pr-merged|merge-gate-complete|staging-complete) ;;
  *) printf 'cc-reaper: unknown lifecycle stage: %s\n' "${stage:-<missing>}" >&2; exit 2 ;;
esac

root="${CC_REAPER_ROOT:-$HOME/.cc-reaper}"
wj="$root/worktree-janitor.sh"
dj="$root/disk-janitor.sh"
audit_log="${CC_REAPER_LIFECYCLE_LOG:-$root/logs/lifecycle-reclaim.log}"
rc=0

# This log records the lifecycle boundary and each delegated janitor result. It is
# deliberately best-effort: an audit-log permission problem must not turn a safe
# reclaim into a failed deletion path. The janitors remain the source of truth for
# holder, claim, landed and drain-proof decisions.
_cc_lifecycle_log() {
  local message="$1" stamp
  stamp="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'unknown-time')"
  (umask 077; mkdir -p "$(dirname "$audit_log")" 2>/dev/null &&
    printf '[%s] %s\n' "$stamp" "$message" >> "$audit_log") 2>/dev/null || true
}

_cc_lifecycle_finish() {
  local status=$?
  _cc_lifecycle_log "end stage=$stage status=$status"
  return "$status"
}
trap _cc_lifecycle_finish EXIT

_cc_lifecycle_log "start stage=$stage repo_present=$([ -n "$repo" ] && printf 1 || printf 0) proof_present=$([ -n "$proof" ] && printf 1 || printf 0)"

case "$stage" in
  session-end)
    # The harness-specific SessionEnd hook protects its current cwd. This bounded
    # repository sweep is the optional external adapter path.
    if [ -x "$wj" ] && [ -n "$repo" ] && [ -d "$repo" ]; then
      _cc_lifecycle_log "worktree=invoke mode=scheduled"
      if "$wj" --scheduled --repo "$repo"; then
        _cc_lifecycle_log "worktree=complete status=0"
      else
        wj_rc=$?
        _cc_lifecycle_log "worktree=complete status=$wj_rc"
        rc="$wj_rc"
      fi
    else
      _cc_lifecycle_log "worktree=skip reason=missing-script-or-repo"
    fi
    ;;
  pr-merged|merge-gate-complete|staging-complete)
    if [ -x "$wj" ] && [ -n "$repo" ] && [ -d "$repo" ]; then
      _cc_lifecycle_log "worktree=invoke mode=scheduled"
      if "$wj" --scheduled --repo "$repo"; then
        _cc_lifecycle_log "worktree=complete status=0"
      else
        wj_rc=$?
        _cc_lifecycle_log "worktree=complete status=$wj_rc"
        rc="$wj_rc"
      fi
    else
      _cc_lifecycle_log "worktree=skip reason=missing-script-or-repo"
    fi
    ;;
esac

# A lifecycle event may request a builder-cache pass, but only with an explicit
# short-lived drain proof produced by the adapter. Missing proof is a safe no-op.
if [ -n "$proof" ] && [ -x "$dj" ]; then
  _cc_lifecycle_log "disk=invoke mode=orbstack-clean"
  if "$dj" --orbstack-clean --drain-proof "$proof"; then
    _cc_lifecycle_log "disk=complete status=0"
  else
    disk_rc=$?
    _cc_lifecycle_log "disk=complete status=$disk_rc"
    [ "$rc" -ne 0 ] || rc="$disk_rc"
  fi
elif [ -x "$dj" ]; then
  _cc_lifecycle_log "disk=invoke mode=check"
  if "$dj" --check >/dev/null 2>&1; then
    _cc_lifecycle_log "disk=complete status=0"
  else
    disk_rc=$?
    _cc_lifecycle_log "disk=complete status=$disk_rc"
    [ "$rc" -ne 0 ] || rc="$disk_rc"
  fi
else
  _cc_lifecycle_log "disk=skip reason=missing-script"
fi

exit "$rc"
