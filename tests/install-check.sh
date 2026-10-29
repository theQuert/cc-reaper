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

# ─── The repository is the source of truth for every agent (EL-T24-STORAGE-LOAD-REAPER) ───
# The session reaper, stall watch and wip backup were copied in by hand, and reclaim-byproducts'
# agent lived nowhere in the repository: --check could not see any of them drift.
R="$H/.cc-reaper"; L="$H/Library/LaunchAgents"
for f in session-reaper.py stall-watch.py wip-backup.sh; do
  if [ -x "$R/$f" ] && cmp -s "$ROOT_DIR/shell/$f" "$R/$f"; then ok "the installer deploys $f"
  else bad "the installer did not deploy $f"; fi
done
for a in session-reaper stall-watch reclaim-byproducts; do
  if [ -e "$L/com.cc-reaper.$a.plist" ] && [ -e "$S/com.cc-reaper.$a.loaded" ]; then ok "the installer schedules $a"
  else bad "the installer did not schedule $a"; fi
done
if [ "$(stat -f %Lp "$R/session-reaper.conf" 2>/dev/null)" = 600 ] && cmp -s "$ROOT_DIR/config/session-reaper.conf" "$R/session-reaper.conf"; then
  ok "a missing session policy is installed, 600, report-only as the repository ships it"
else bad "session policy not installed as the repository's"; fi

# wip-backup pushes untracked files to remotes: a host that did not opt in never gets it.
out="$(run --check 2>&1)"; rc=$?
if [ ! -e "$L/com.cc-reaper.wip-backup.plist" ] && [ "$rc" -eq 0 ] &&
   printf '%s\n' "$out" | grep -q 'opt-in   wip-backup is not enabled'; then
  ok "wip-backup is neither scheduled nor drift on a host that did not opt in"
else bad "wip-backup on a fresh host: rc=$rc: $(printf '%s\n' "$out" | grep wip)"; fi
: > "$R/wip-backup.conf"
run >/dev/null 2>&1
out="$(run --check 2>&1)"; rc=$?
if [ -e "$S/com.cc-reaper.wip-backup.loaded" ] && [ "$rc" -eq 0 ] &&
   printf '%s\n' "$out" | grep -q 'current  .*com.cc-reaper.wip-backup.plist'; then
  ok "a host that opted in by its policy gets wip-backup scheduled and compared"
else bad "opted-in wip-backup: rc=$rc: $(printf '%s\n' "$out" | grep wip)"; fi
rm "$L/com.cc-reaper.wip-backup.plist"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'MISSING.*com.cc-reaper.wip-backup.plist' \
  && ok "an opted-in host missing its wip-backup agent is drift" || bad "opted-in missing agent: rc=$rc"
run >/dev/null 2>&1

# A deployed script that lost its execute bit is drift, though its bytes match.
chmod 644 "$R/host-temp-reaper.py"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'MODE .*host-temp-reaper.py is 644' \
  && ok "a deployed script at 644 is drift" || bad "mode 644: rc=$rc: $out"
run >/dev/null 2>&1
[ "$(stat -f %Lp "$R/host-temp-reaper.py")" = 755 ] && ok "and an install puts 755 back" || bad "install left mode $(stat -f %Lp "$R/host-temp-reaper.py")"

# launchd reads the property list, not its bytes: a plist rewritten by plutil is the same agent,
# and one whose values changed is not.
if command -v plutil >/dev/null 2>&1; then
  plutil -convert xml1 "$L/com.cc-reaper.resource-watch.plist"
  out="$(run --check 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "a plist rewritten by plutil (keys sorted, comments gone) is not drift" \
    || bad "plutil-rewritten plist: rc=$rc: $(printf '%s\n' "$out" | grep -v current)"
  plutil -replace StartInterval -integer 600 "$L/com.cc-reaper.resource-watch.plist"
  out="$(run --check 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'DRIFT.*com.cc-reaper.resource-watch.plist' \
    && ok "the old 600 s resource-watch interval is drift" || bad "changed interval: rc=$rc"
  run >/dev/null 2>&1
fi

# An update leaves an agent that already says what the checkout says, and is loaded, alone:
# booting it out and back in resets launchd's run counter, the record that its schedule fires.
: > "$S/calls"
run >/dev/null 2>&1
if ! grep -E '^(bootout|bootstrap) .*com\.cc-reaper\.(resource-watch|session-reaper|stall-watch|reclaim-byproducts|wip-backup|guard)' "$S/calls" >/dev/null; then
  ok "a re-run reloads no agent that is current and loaded"
else bad "a re-run reloaded current agents: $(grep -E '^(bootout|bootstrap)' "$S/calls" | tr '\n' ';')"; fi
sed -i '' 's|<integer>1800</integer>|<integer>1801</integer>|' "$L/com.cc-reaper.session-reaper.plist"
: > "$S/calls"
run >/dev/null 2>&1
grep -q 'bootstrap .*com.cc-reaper.session-reaper.plist' "$S/calls" && cmp -s \
  <(sed "s|__HOME__|$H|g" "$ROOT_DIR/launchd/com.cc-reaper.session-reaper.plist") "$L/com.cc-reaper.session-reaper.plist" \
  && ok "an agent that differs is rewritten and reloaded" || bad "drifted agent not repaired: $(tr '\n' ';' < "$S/calls")"

# Hand-deploy backups are named, never drift and never removed.
: > "$R/session-reaper.py.bak-test"
out="$(run --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'note     1 hand-deploy backups' && [ -e "$R/session-reaper.py.bak-test" ] \
  && ok "a hand-deploy backup is reported and left in place" || bad "backup note: rc=$rc"

[ "$failures" -eq 0 ] && echo "install-check: all passed" || { echo "install-check: $failures failed"; exit 1; }
