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
rc=0

case "$stage" in
  session-end)
    # The harness-specific SessionEnd hook protects its current cwd. This bounded
    # repository sweep is the optional external adapter path.
    if [ -x "$wj" ] && [ -n "$repo" ] && [ -d "$repo" ]; then
      "$wj" --scheduled --repo "$repo" || rc=$?
    fi
    ;;
  pr-merged|merge-gate-complete|staging-complete)
    if [ -x "$wj" ] && [ -n "$repo" ] && [ -d "$repo" ]; then
      "$wj" --scheduled --repo "$repo" || rc=$?
    fi
    ;;
esac

# A lifecycle event may request a builder-cache pass, but only with an explicit
# short-lived drain proof produced by the adapter. Missing proof is a safe no-op.
if [ -n "$proof" ] && [ -x "$dj" ]; then
  if "$dj" --orbstack-clean --drain-proof "$proof"; then
    :
  else
    disk_rc=$?
    [ "$rc" -ne 0 ] || rc="$disk_rc"
  fi
elif [ -x "$dj" ]; then
  if "$dj" --check >/dev/null 2>&1; then
    :
  else
    disk_rc=$?
    [ "$rc" -ne 0 ] || rc="$disk_rc"
  fi
fi

exit "$rc"
