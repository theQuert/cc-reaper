#!/usr/bin/env bash
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-life.XXXXXX")"
mkdir -p "$SANDBOX/root" "$SANDBOX/repo"
trap 'rm -r "$SANDBOX"' EXIT
cat > "$SANDBOX/root/worktree-janitor.sh" <<'EOF'
#!/bin/sh
printf 'wj %s\n' "$*" >> "$CC_REAPER_TEST_LOG"
EOF
cat > "$SANDBOX/root/disk-janitor.sh" <<'EOF'
#!/bin/sh
printf 'dj %s\n' "$*" >> "$CC_REAPER_TEST_LOG"
EOF
chmod +x "$SANDBOX/root"/*.sh
log="$SANDBOX/log"

CC_REAPER_ROOT="$SANDBOX/root" CC_REAPER_TEST_LOG="$log" \
  bash "$ROOT_DIR/hooks/lifecycle-reclaim.sh" --stage staging-complete --repo "$SANDBOX/repo"
grep -qx 'wj --scheduled --repo '"$SANDBOX/repo" "$log"
grep -qx 'dj --check' "$log"

if CC_REAPER_ROOT="$SANDBOX/root" CC_REAPER_TEST_LOG="$log" \
  bash "$ROOT_DIR/hooks/lifecycle-reclaim.sh" --stage unsupported >/dev/null 2>&1; then
  echo 'unsupported stage unexpectedly accepted' >&2
  exit 1
fi
echo 'lifecycle adapter validation passed'

cat > "$SANDBOX/root/disk-janitor.sh" <<'EOF'
#!/bin/sh
printf 'dj-fail %s\n' "$*" >> "$CC_REAPER_TEST_LOG"
exit 7
EOF
chmod +x "$SANDBOX/root/disk-janitor.sh"
if CC_REAPER_ROOT="$SANDBOX/root" CC_REAPER_TEST_LOG="$log" \
  bash "$ROOT_DIR/hooks/lifecycle-reclaim.sh" --stage staging-complete --repo "$SANDBOX/repo"; then
  echo 'disk failure unexpectedly swallowed' >&2
  exit 1
fi
echo 'lifecycle adapter propagates disk failure'
