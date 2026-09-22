#!/usr/bin/env bash
# Focused tests for the generic builder-cache drain proof boundary.
set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/cc-reaper-drain.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
PATH="$SANDBOX/bin:$PATH"
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CC_DJ_DOCKER_LOG:?}"
case "$*" in
  "context show") echo "orbstack" ;;
  "info"|"system df") exit 0 ;;
  "ps --filter label=cc.reaper.protect=true -q")
    if [ "${CC_DJ_TEST_HOLDER:-0}" = 1 ]; then echo holder-id; fi ;;
  "builder prune --force --filter until=168h") echo builder-pruned ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$SANDBOX/bin/docker"
cat > "$SANDBOX/bin/orb" <<'EOF'
#!/bin/sh
echo 'running'
EOF
chmod +x "$SANDBOX/bin/orb"

source "$ROOT_DIR/shell/disk-janitor.sh"

now="$(date +%s)"
proof="$SANDBOX/proof"
export CC_DJ_DOCKER_LOG="$SANDBOX/docker.log"
: > "$CC_DJ_DOCKER_LOG"
cat > "$proof" <<EOF
schema=1
scope=builder-cache
host=$(hostname -s)
context=orbstack
issued_at=$((now - 10))
expires_at=$((now + 100))
drained=1
EOF

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

_cc_dj_drain_proof_valid "$proof" && ok 'fresh proof matches host and context' || not_ok 'fresh proof matches host and context'
sed 's/expires_at=.*/expires_at=1/' "$proof" > "$SANDBOX/stale"
_cc_dj_drain_proof_valid "$SANDBOX/stale" && not_ok 'expired proof is rejected' || ok 'expired proof is rejected'
sed 's/host=.*/host=other-host/' "$proof" > "$SANDBOX/foreign"
_cc_dj_drain_proof_valid "$SANDBOX/foreign" && not_ok 'foreign host proof is rejected' || ok 'foreign host proof is rejected'
sed 's/drained=1/drained=0/' "$proof" > "$SANDBOX/not-drained"
_cc_dj_drain_proof_valid "$SANDBOX/not-drained" && not_ok 'non-drained proof is rejected' || ok 'non-drained proof is rejected'
cat "$proof" > "$SANDBOX/duplicate"
printf '%s\n' 'scope=builder-cache' >> "$SANDBOX/duplicate"
_cc_dj_drain_proof_valid "$SANDBOX/duplicate" && not_ok 'duplicate proof fields are rejected' || ok 'duplicate proof fields are rejected'
CC_DJ_DRAIN_PROOF_MAX_AGE_SECONDS=901 _cc_dj_drain_proof_valid "$proof" \
  && not_ok 'proof lifetime above hard cap is rejected' \
  || ok 'proof lifetime above hard cap is rejected'

CC_DJ_LOG="$SANDBOX/janitor.log" CC_DJ_STATE_DIR="$SANDBOX/state" \
  CC_DJ_DRAIN_PROOF_FILE="$proof" CC_DJ_PROTECTED_CONTAINER_FILTERS='label=cc.reaper.protect=true' \
  _cc_dj_orbstack_clean
grep -qx 'builder prune --force --filter until=168h' "$CC_DJ_DOCKER_LOG" \
  && ok 'fresh proof permits builder-cache cleanup' \
  || not_ok 'fresh proof permits builder-cache cleanup'

before="$(wc -l < "$CC_DJ_DOCKER_LOG")"
CC_DJ_LOG="$SANDBOX/janitor-holder.log" CC_DJ_STATE_DIR="$SANDBOX/state-holder" \
  CC_DJ_DRAIN_PROOF_FILE="$proof" CC_DJ_TEST_HOLDER=1 \
  _cc_dj_orbstack_clean
after="$(wc -l < "$CC_DJ_DOCKER_LOG")"
if sed -n "$((before + 1)),${after}p" "$CC_DJ_DOCKER_LOG" | grep -q 'builder prune'; then
  not_ok 'protected container blocks builder-cache cleanup'
else
  ok 'protected container blocks builder-cache cleanup'
fi

printf '%s\n' "1..$((pass + fail))"
[ "$fail" -eq 0 ]
