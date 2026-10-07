#!/usr/bin/env bash
# install.sh --check: says whether the deployed copies match this checkout, and touches nothing.
#
# The deployed copies under ~/.cc-reaper are what launchd and the hooks run, and nothing
# compared them with the repository except a hand-written byte comparison after each deploy
# (2026-10-06: four deploys, each checked by hand). --check is that comparison, run from the
# same list the installer deploys from.
#
# Runs against a sandbox HOME with launchctl stubbed: a real HOME would reinstall the machine.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
ok()  { printf "ok - %s\n" "$1"; }
bad() { printf "not ok - %s\n" "$1"; failures=$((failures + 1)); }

H="$(mktemp -d)"; S="$(mktemp -d)"
trap 'rm -rf "$H" "$S"' EXIT
mkdir -p "$H/Library/LaunchAgents" "$H/.claude/hooks" "$H/.cc-reaper/logs"
: > "$H/.zshrc"
for c in brew cargo; do printf '#!/bin/sh\nexit 0\n' > "$S/$c"; chmod +x "$S/$c"; done
cat > "$S/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/calls"
case "$1" in
  bootstrap) label=${3##*/}; : > "$(dirname "$0")/${label%.plist}.loaded" ;;
  bootout) rm -f "$(dirname "$0")/${2##*/}.loaded" ;;
  print) test -e "$(dirname "$0")/${2##*/}.loaded"; exit $? ;;
esac
exit 0
STUB
chmod +x "$S/launchctl"

run() { HOME="$H" PATH="$S:$PATH" CC_REAPER_DAEMON=b bash "$ROOT_DIR/install.sh" "$@" < /dev/null; }
snap() { (cd "$H" && find . -type f -print0 | sort -z | xargs -0 shasum) ; }

run >/dev/null 2>&1 || bad "sandbox install failed"

out="$(run --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a fresh install checks clean" || bad "fresh install: rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'worktree-janitor.sh' && ok "the check names what it compared" \
  || bad "check output names no file: $out"

: > "$S/calls"; before="$(snap)"
run --check >/dev/null 2>&1
[ "$(snap)" = "$before" ] && ok "--check writes nothing under HOME" || bad "--check changed HOME"
[ ! -s "$S/calls" ] && ok "--check never calls launchctl" || bad "--check called launchctl: $(cat "$S/calls")"

echo '# drift' >> "$H/.cc-reaper/disk-janitor.sh"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'DRIFT.*disk-janitor.sh' \
  && ok "an edited deployed script is drift" || bad "edited script: rc=$rc: $out"
run >/dev/null 2>&1

rm "$H/.cc-reaper/host-temp-reaper.py"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'MISSING.*host-temp-reaper.py' \
  && ok "a missing deployed script is drift" || bad "missing script: rc=$rc: $out"
run >/dev/null 2>&1

sed -i '' 's|<integer>600</integer>|<integer>601</integer>|' "$H/Library/LaunchAgents/com.cc-reaper.guard.plist"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'DRIFT.*com.cc-reaper.guard.plist' \
  && ok "an edited LaunchAgent is drift" || bad "edited plist: rc=$rc: $out"
run >/dev/null 2>&1

: > "$H/.cc-reaper/lifecycle-reclaim.sh"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'RETIRED.*lifecycle-reclaim.sh' \
  && ok "a retired file still installed is drift" || bad "retired file: rc=$rc: $out"
run >/dev/null 2>&1

# A worktree interval chosen at install time is the operator's, not drift.
HOME="$H" PATH="$S:$PATH" CC_REAPER_DAEMON=b CC_REAPER_WORKTREE_INTERVAL_SECONDS=1800 \
  bash "$ROOT_DIR/install.sh" < /dev/null >/dev/null 2>&1
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a custom worktree interval is not drift" || bad "custom interval: rc=$rc: $out"

# Policies are operator-owned: reported, never drift.
echo ': "${CC_WJ_IDLE_HOURS:=24}"' >> "$H/.cc-reaper/worktree-janitor.conf"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'worktree-janitor.conf.*differs' \
  && ok "an operator-edited policy is reported, not drift" || bad "edited conf: rc=$rc: $out"

[ "$failures" -eq 0 ] && echo "install-check: all passed" || { echo "install-check: $failures failed"; exit 1; }
