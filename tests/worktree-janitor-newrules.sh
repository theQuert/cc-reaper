#!/usr/bin/env bash
# worktree-janitor: the rules on probation (stima-api#5886) and the names nothing may touch.
#   top-level-log        a top-level ignored *.log file no longer keeps a worktree
#   primary-skills-link  nor does a .claude/skills or .claude/commands link into the primary checkout
#   CC_WJ_NEW_RULES_MODE spotcheck (default) logs what they would trim or remove and changes nothing;
#                        auto lets them decide
#   CC_WJ_DENY_NAMES     a named worktree is never trimmed or removed
#   inbound-symlink      a tree that another worktree's node_modules symlink points into is kept
#                        (active in every mode: a keep only makes the sweep safer); a dead link
#                        is reported, never counted; a failed scan keeps
# Plus two costs: one holder scan per sweep, and no per-tree walk for a tree with nothing to trim.
# Real git repositories and a local bare "origin"; lsof and gh are stubs, find is logged.
# TAP-style; set WJ_SCRIPT to test another copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then nok "$name"; else ok "$name"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
live_pid=""
[ -n "${WJ_KEEP_TMP:-}" ] || trap 'kill $live_pid 2>/dev/null; rm -rf "$T"' EXIT
[ -z "${WJ_KEEP_TMP:-}" ] || echo "# kept: $T"
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
printf '*.log\nnode_modules\n.claude/skills\n.claude/commands\n' > "$PRIMARY/.gitignore"
echo init > "$PRIMARY/README.md"
# Tracked, as in stima-api: otherwise git collapses the whole directory to `!! .claude/`.
mkdir -p "$PRIMARY/.claude"; echo "{}" > "$PRIMARY/.claude/settings.json"
# Tracked too, so git reports web/next/node_modules itself and not a collapsed `!! web/`.
mkdir -p "$PRIMARY/web/next" "$PRIMARY/web/default"; echo '{}' > "$PRIMARY/web/next/package.json"; echo '{}' > "$PRIMARY/web/default/package.json"
G -C "$PRIMARY" add README.md .gitignore .claude/settings.json web
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main
# What new-task-worktree.sh links into every task worktree.
mkdir -p "$PRIMARY/.claude/skills/one" "$PRIMARY/.claude/commands"
echo skill > "$PRIMARY/.claude/skills/one/SKILL.md"

# A worktree on its own branch at main (landed), or with a commit of its own (unlanded).
mkwt() { # <name> [unlanded]
  G -C "$PRIMARY" worktree add -q -b "$1" "$T/wt-$1" main
  if [ "${2:-}" = unlanded ]; then
    echo "$1" > "$T/wt-$1/$1.txt"
    G -C "$T/wt-$1" add "$1.txt"
    G -C "$T/wt-$1" commit -qm "work on $1"
  fi
}
cache() { mkdir -p "$T/wt-$1/node_modules/pkg"; echo pkg > "$T/wt-$1/node_modules/pkg/index.js"; }

mkwt log;          echo "dev server" > "$T/wt-log/next-manual.log"
mkwt skillsabs;    mkdir -p "$T/wt-skillsabs/.claude"; ln -s "$PRIMARY/.claude/skills" "$T/wt-skillsabs/.claude/skills"
mkwt skillsrel;    mkdir -p "$T/wt-skillsrel/.claude"; ln -s ../../primary/.claude/commands "$T/wt-skillsrel/.claude/commands"
mkdir -p "$T/elsewhere/skills"
mkwt linkout;      mkdir -p "$T/wt-linkout/.claude"; ln -s "$T/elsewhere/skills" "$T/wt-linkout/.claude/skills"
mkwt nestedlog;    mkdir -p "$T/wt-nestedlog/sub"; echo x > "$T/wt-nestedlog/sub/run.log"
mkwt logheld;      echo x > "$T/wt-logheld/api-1.log"
mkwt trimme unlanded;  echo x > "$T/wt-trimme/.build-main.log"; cache trimme
mkwt trimheld unlanded; echo x > "$T/wt-trimheld/.build-main.log"; cache trimheld
mkwt homepage-bento;  cache homepage-bento
mkwt sessiondeny;     cache sessiondeny
# stima-api: web/next/node_modules is a symlink into another worktree's node_modules.
mkwt donor;    mkdir -p "$T/wt-donor/web/next/node_modules/pkg"; echo pkg > "$T/wt-donor/web/next/node_modules/pkg/index.js"
mkwt donor2;   mkdir -p "$T/wt-donor2/web/default/node_modules/pkg"; echo pkg > "$T/wt-donor2/web/default/node_modules/pkg/index.js"
mkwt lonely;   cache lonely
mkwt ghost
mkwt consumer; mkdir -p "$T/wt-consumer/web/next"; ln -s "$T/wt-donor/web/next/node_modules" "$T/wt-consumer/web/next/node_modules"
mkwt consumer2; mkdir -p "$T/wt-consumer2/web/default"; ln -s ../../../wt-donor2/web/default/node_modules "$T/wt-consumer2/web/default/node_modules"
mkwt deadc;    mkdir -p "$T/wt-deadc/web/next"; ln -s "$T/wt-ghost/web/next/node_modules" "$T/wt-deadc/web/next/node_modules"

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"; LSOF_LOG="$T/lsof.log"; FIND_LOG="$T/find.log"
export LSOF_CWD_FILE LSOF_OPEN_FILE LSOF_LOG FIND_LOG
# Two worktrees have a process standing in them.
printf 'p1\nn/\np77\nn%s\np78\nn%s\np79\nn%s\np80\nn%s\np81\nn%s\n' \
  "$T/wt-logheld" "$T/wt-trimheld" "$T/wt-consumer" "$T/wt-consumer2" "$T/wt-deadc" > "$LSOF_CWD_FILE"
printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LSOF_LOG"
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
REAL_FIND="$(command -v find)"
cat > "$STUBS/find" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FIND_LOG"
case " \$* " in *" -maxdepth 4 "*" -type l "*) [ -z "\${FIND_FAIL_LINKS:-}" ] || exit 1 ;; esac
exec "$REAL_FIND" "\$@"
STUB
chmod +x "$STUBS"/*

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS/p"
# A live Claude session named uiux standing in wt-sessiondeny: its pid is alive and its command
# line carries its session id, which is what the registry scan verifies.
LIVE_SID="0000aaaa-0000-4000-8000-000000000099"
python3 -c 'import time; time.sleep(600)' "$LIVE_SID" </dev/null >/dev/null 2>&1 &
live_pid=$!; disown "$live_pid" 2>/dev/null || true
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"uiux"}\n' "$live_pid" "$LIVE_SID" "$T/wt-sessiondeny" \
  > "$SESSIONS/$live_pid.json"
printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' "$LIVE_SID" "$T/wt-sessiondeny" \
  > "$PROJECTS/p/$LIVE_SID.jsonl"

SPOT="$T/spotcheck.log"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_RECLAIM_PUSHED=0
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$SPOT"
export CC_WJ_DENY_NAMES="homepage uiux verify-signin-redesign"
unset CC_WJ_NEW_RULES_MODE
wj() { PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }

# One worktree's lines of a report: its WORKTREE line up to the next one.
block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
says() { block "$1" "$2" | grep -qF -- "$3"; }
judged() { block "$1" "$2" | grep -qxF "    classification: $3"; }
spot_has() { grep -F -- "$1" "$SPOT" | grep -qF -- "$2"; }

# ─── Removal phase, reported ─────────────────────────────────────────────────

: > "$LSOF_LOG"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/report-auto.txt"
check "auto: a top-level ignored *.log no longer keeps a landed tree" judged "$T/report-auto.txt" log REMOVABLE
check "auto: an absolute .claude/skills link into the primary checkout no longer keeps it" \
  judged "$T/report-auto.txt" skillsabs REMOVABLE
check "auto: nor does a relative .claude/commands link into it" judged "$T/report-auto.txt" skillsrel REMOVABLE
check "auto: a .claude/skills link that points outside the primary checkout still keeps it" \
  judged "$T/report-auto.txt" linkout "KEEP(unrebuildable=1)"
check "auto: a *.log below the top level still keeps it" judged "$T/report-auto.txt" nestedlog "KEEP(unrebuildable=1)"
check "auto: a held tree whose only pin is a log is kept as held" judged "$T/report-auto.txt" logheld "KEEP(active-session)"
check "auto: unlanded work stays kept for removal" judged "$T/report-auto.txt" trimme "KEEP(unlanded)"
check "deny: a worktree whose name holds a deny-listed name is kept" \
  judged "$T/report-auto.txt" homepage-bento "KEEP(deny-listed:homepage)"
check "deny: a worktree a live session of a deny-listed name stands in is kept" \
  judged "$T/report-auto.txt" sessiondeny "KEEP(deny-listed:session uiux)"
check "one holder scan per sweep: a report over ten worktrees runs lsof exactly twice (cwd, open files)" \
  test "$(grep -vc -- '\.lock' "$LSOF_LOG")" -eq 2

# Inbound node_modules symlinks (held consumers, so only the targets are under test).
check "inbound: a tree another worktree's absolute node_modules link points into is kept" \
  judged "$T/report-auto.txt" donor "KEEP(inbound-symlink:wt-consumer)"
check "inbound: so is one a relative link points into" judged "$T/report-auto.txt" donor2 "KEEP(inbound-symlink:wt-consumer2)"
check "inbound: a landed tree nothing links into is still removable" judged "$T/report-auto.txt" lonely REMOVABLE
check "inbound: a dead link does not keep the tree it named" judged "$T/report-auto.txt" ghost REMOVABLE
check "inbound: the dead link is reported with its target" \
  grep -qF "dead-node-modules-link:$T/wt-deadc/web/next/node_modules -> $T/wt-ghost/web/next/node_modules" "$T/report-auto.txt"
check "inbound: the scan is bounded and prunes real node_modules" \
  bash -c 'grep -F -- "-name node_modules" "$1" | grep -F -- "-maxdepth 4" | grep -qF -- "-prune"' _ "$FIND_LOG"
FIND_FAIL_LINKS=1 wj > "$T/report-failscan.txt"
check "inbound: a failed scan keeps a tree that would be removable" \
  judged "$T/report-failscan.txt" lonely "KEEP(inbound-scan-unknown)"

: > "$SPOT"
wj > "$T/report-spot.txt"
check "spotcheck (default): the log still keeps the tree as before" judged "$T/report-spot.txt" log "KEEP(unrebuildable=1)"
check "  and the report names the pin as before" says "$T/report-spot.txt" log "kept by: !! next-manual.log"
check "  and says the rule would make it removable" says "$T/report-spot.txt" log "spotcheck: top-level-log would make it REMOVABLE"
check "  and the spot-check log records it with rule, size, holder and run id" \
  spot_has "path=$T/wt-log " "phase=removal action=would-remove rule=top-level-log"
check "  with a byte count and a run id" bash -c 'grep -F "path=$1 " "$2" | grep -Eq "run=[0-9TZ]+-[0-9]+ .* bytes=[0-9]+ holder=none"' _ "$T/wt-log" "$SPOT"
check "spotcheck: the skills link tree is kept as before" judged "$T/report-spot.txt" skillsabs "KEEP(unrebuildable=1)"
check "  and logged under its rule" spot_has "path=$T/wt-skillsabs " "rule=primary-skills-link"
refute "spotcheck: a held tree is not logged as removable" grep -qF "path=$T/wt-logheld " "$SPOT"
refute "spotcheck: a deny-listed tree is not logged" grep -qF "wt-homepage-bento" "$SPOT"

# ─── Trim phase ──────────────────────────────────────────────────────────────

: > "$SPOT"
wj --trim-regenerable --apply > "$T/trim-spot.txt"
check "spotcheck: an unlanded idle tree's node_modules is not trimmed" test -d "$T/wt-trimme/node_modules"
check "  and the would-trim is logged with its path" spot_has "path=$T/wt-trimme/node_modules " "phase=trim action=would-trim rule=top-level-log"
check "  and the tree is kept as before" judged "$T/trim-spot.txt" trimme "KEEP(unrebuildable=1)"
refute "spotcheck: a held tree's cache is not logged" grep -qF "wt-trimheld" "$SPOT"
check "inbound: trim keeps the node_modules another worktree's link points into" \
  test -d "$T/wt-donor/web/next/node_modules" -a -d "$T/wt-donor2/web/default/node_modules"
check "  and says why" judged "$T/trim-spot.txt" donor "KEEP(inbound-symlink:wt-consumer)"
refute "  while a tree nothing links into is trimmed" test -e "$T/wt-lonely/node_modules"

CC_WJ_NEW_RULES_MODE=auto wj --trim-regenerable --apply > "$T/trim-auto.txt"
refute "auto: an unlanded idle tree whose only pin is a log has its node_modules trimmed" test -e "$T/wt-trimme/node_modules"
check "  and keeps the worktree, its log and its own work" \
  bash -c '[ -f "$1/.build-main.log" ] && [ -f "$1/trimme.txt" ] && git -C "$1" rev-parse -q --verify HEAD' _ "$T/wt-trimme"
check "auto: a held tree keeps its node_modules" test -d "$T/wt-trimheld/node_modules"
check "  and says it is held" says "$T/trim-auto.txt" trimheld "KEEP(active-session)"
check "deny: a deny-listed tree keeps its node_modules" test -d "$T/wt-homepage-bento/node_modules"
check "deny: so does the one a deny-listed session stands in" test -d "$T/wt-sessiondeny/node_modules"

# Nothing to trim is answered before the claim lookups and the idle walk.
walked() { grep -F -- "-mmin" "$FIND_LOG" | grep -qF -- "$1 "; }
cache trimme; : > "$FIND_LOG"
CC_WJ_IDLE_HOURS=48 CC_WJ_PRESSURE_FREE_GB=99999 CC_WJ_NEW_RULES_MODE=auto wj --trim-regenerable > "$T/trim-pressure.txt"
refute "trim under pressure walks no tree that has nothing to trim" walked "$T/wt-log"
refute "  nor a dirty one that has nothing to trim" walked "$T/wt-nestedlog"
check "  but still walks one that has" walked "$T/wt-trimme"

# ─── Removal phase, applied ──────────────────────────────────────────────────

wj --apply > "$T/apply-spot.txt"
check "spotcheck --apply removes nothing the new rules reached" \
  bash -c '[ -d "$1/wt-log" ] && [ -d "$1/wt-skillsabs" ] && [ -d "$1/wt-skillsrel" ]' _ "$T"

CC_WJ_NEW_RULES_MODE=auto wj --apply > "$T/apply-auto.txt"
check "auto --apply removes the tree a log alone kept" test ! -e "$T/wt-log"
check "auto --apply removes the trees a skills link alone kept" test ! -e "$T/wt-skillsabs" -a ! -e "$T/wt-skillsrel"
check "  and the primary checkout's skills are untouched" test -f "$PRIMARY/.claude/skills/one/SKILL.md"
check "  and the branches remain" bash -c 'git -C "$1" show-ref -q --verify refs/heads/log && git -C "$1" show-ref -q --verify refs/heads/skillsabs' _ "$PRIMARY"
check "inbound: --apply removes the tree nothing links into and the one only a dead link named" \
  test ! -e "$T/wt-lonely" -a ! -e "$T/wt-ghost"
check "inbound: --apply keeps the trees live links point into, and their node_modules" \
  test -d "$T/wt-donor/web/next/node_modules" -a -d "$T/wt-donor2/web/default/node_modules"
check "inbound: and the links still resolve" test -d "$T/wt-consumer/web/next/node_modules/pkg" -a -d "$T/wt-consumer2/web/default/node_modules/pkg"
check "auto --apply keeps the held tree" test -d "$T/wt-logheld"
check "auto --apply keeps the deny-listed trees" test -d "$T/wt-homepage-bento" -a -d "$T/wt-sessiondeny"
check "auto --apply keeps a link outside the primary checkout" test -L "$T/wt-linkout/.claude/skills"

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
