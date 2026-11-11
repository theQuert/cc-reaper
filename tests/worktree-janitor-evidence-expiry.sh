#!/usr/bin/env bash
# worktree-janitor: the evidence-expired rule and per-rule promotion (stima-api#7895).
#   A landed, idle tree whose ONLY unrebuildable entries are under .codex/evidence is removable when
#   every issue the entries name is closed (GitHub, from origin's URL) and the newest file under the
#   root is at least CC_WJ_EVIDENCE_EXPIRY_DAYS old. Anything unknown keeps the tree.
#   CC_WJ_EVIDENCE_EXPIRY_MODE  shadow (default) logs would-remove and decides nothing; apply decides;
#                               off does not ask
#   CC_WJ_PROMOTED_RULES        a rule on probation named here decides while CC_WJ_NEW_RULES_MODE
#                               stays spotcheck for every other rule
# Fixtures are real git repositories with a local bare "origin" reached through insteadOf under a
# GitHub URL; lsof and gh are stubs (gh answers issue states from files). Every keep guard of the rule
# is then removed from a copy of the janitor, and the matching tree must turn removable: a mutant
# that survives would mean the test checks nothing.
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

# One repository whose origin is a local bare repository that git reaches under a URL the janitor
# reads as the remote's identity (it never follows insteadOf).
mkrepo() { # <name> <url>
  G init -q --bare "$T/$1-origin.git" -b main
  G clone -q "$T/$1-origin.git" "$T/$1" 2>/dev/null
  printf '.codex/evidence/\nnode_modules\n*.db\n.claude/skills\n.claude/commands\n' > "$T/$1/.gitignore"
  echo init > "$T/$1/README.md"
  mkdir -p "$T/$1/.claude"; echo "{}" > "$T/$1/.claude/settings.json"
  printf 'archive:.codex/evidence\n' > "$T/$1/.worktree-regenerable"
  G -C "$T/$1" add README.md .gitignore .claude/settings.json .worktree-regenerable
  G -C "$T/$1" commit -qm init
  G -C "$T/$1" push -q origin main
  G -C "$T/$1" remote set-url origin "$2"
  G -C "$T/$1" config "url.$T/$1-origin.git.insteadOf" "$2"
  G -C "$T/$1" fetch -q origin 2>/dev/null
  mkdir -p "$T/$1/.claude/skills/one"; echo skill > "$T/$1/.claude/skills/one/SKILL.md"
}
mkrepo primary https://github.com/acme/widgets.git
mkrepo other https://example.org/acme/widgets.git
PRIMARY="$T/primary"; OTHER="$T/other"

mkwt() { # <repo dir> <name>
  G -C "$1" worktree add -q -b "$2" "$T/wt-$2" main
}
# A file under a worktree, <age hours> old: its modification time is what the age rule reads.
put() { # <name> <path relative to the worktree> <age hours> [bytes]
  mkdir -p "$(dirname "$T/wt-$1/$2")"
  head -c "${4:-20}" /dev/zero | tr '\0' x > "$T/wt-$1/$2"
  python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]) * 3600; os.utime(sys.argv[1], (t, t))' "$T/wt-$1/$2" "$3"
}
# Evidence a copy cannot take (bigger than CC_WJ_ARCHIVE_MAX_BYTES), which is what makes the rule matter,
# beside a small record the archive: line copies out first.
evid() { # <name> <entry> <age hours>
  put "$1" ".codex/evidence/$2/result.json" "$3"
  put "$1" ".codex/evidence/$2/big.bin" "$3" 2000
}
D=24
# The newest file 7 days and 1 hour old, 6 days and 1 hour old: either side of the line.
OLD=$((7 * D + 1)); YOUNG=$((6 * D + 1)); LONG=$((30 * D))

mkwt "$PRIMARY" ev-closed;   evid ev-closed 101 "$LONG"; put ev-closed .codex/evidence/102-notes/n.txt "$LONG"
put ev-closed .codex/evidence/102-notes/big.bin "$LONG" 2000
mkwt "$PRIMARY" ev-shared;   evid ev-shared 101 "$LONG"
mkwt "$PRIMARY" ev-edge;     evid ev-edge 106 "$OLD"
mkwt "$PRIMARY" ev-open;     evid ev-open 103 "$LONG"; evid ev-open 104 "$LONG"
mkwt "$PRIMARY" ev-young;    evid ev-young 105 "$LONG"; put ev-young .codex/evidence/105/late.txt "$YOUNG"
mkwt "$PRIMARY" ev-nonum;    evid ev-nonum 107 "$LONG"; evid ev-nonum scratch "$LONG"
mkwt "$PRIMARY" ev-date;     evid ev-date 2026-11-11-notes "$LONG"
mkwt "$PRIMARY" ev-date-us;  evid ev-date-us 2026_11_04-run "$LONG"
mkwt "$PRIMARY" ev-date-dot; evid ev-date-dot 2026.11.04 "$LONG"
mkwt "$PRIMARY" ev-date-ym;  evid ev-date-ym 2026-11 "$LONG"
mkwt "$PRIMARY" ev-letter;   evid ev-letter 3rdparty "$LONG"
mkwt "$PRIMARY" ev-cred;     evid ev-cred 108 "$LONG"; put ev-cred .codex/evidence/108/.env "$LONG"
mkwt "$PRIMARY" ev-ghfail;   evid ev-ghfail 109 "$LONG"
mkwt "$PRIMARY" ev-timeout;  evid ev-timeout 110 "$LONG"
mkwt "$PRIMARY" ev-timeout2; evid ev-timeout2 111 "$LONG"
# Expired evidence, but the branch holds a commit main does not: not landed, so nothing may reach it.
mkwt "$PRIMARY" ev-unlanded; evid ev-unlanded 101 "$LONG"
echo more > "$T/wt-ev-unlanded/unlanded.txt"; G -C "$T/wt-ev-unlanded" add unlanded.txt; G -C "$T/wt-ev-unlanded" commit -qm unlanded
mkwt "$PRIMARY" ev-mixed;    evid ev-mixed 101 "$LONG"; put ev-mixed stray.db "$LONG"
mkwt "$PRIMARY" ev-live;     evid ev-live 101 "$LONG"
mkwt "$PRIMARY" ev-skills;   evid ev-skills 101 "$LONG"
mkdir -p "$T/wt-ev-skills/.claude"; ln -s "$PRIMARY/.claude/skills" "$T/wt-ev-skills/.claude/skills"
mkwt "$PRIMARY" skills-only; mkdir -p "$T/wt-skills-only/.claude"; ln -s "$PRIMARY/.claude/skills" "$T/wt-skills-only/.claude/skills"
mkwt "$OTHER" ev-nongh;      evid ev-nongh 101 "$LONG"

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
GH_STATE="$T/gh-state"; GH_LOG="$T/gh.log"; mkdir -p "$GH_STATE"; : > "$GH_LOG"; export GH_STATE GH_LOG
issue() { printf '%s\n' "$2" > "$GH_STATE/acme_widgets_issues_$1"; }
for n in 1 101 102 106; do issue "$n" closed; done
issue 103 open; issue 104 closed; issue 105 closed; issue 107 closed; issue 108 closed
issue 2026 closed; issue 3 closed
# 109 and 110 have no state file: the lookup fails, as a network error would (110 hangs in one run below).
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"; export LSOF_CWD_FILE LSOF_OPEN_FILE
printf 'p1\nn/\n' > "$LSOF_CWD_FILE"; printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
endpoint=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname|--jq) shift 2 ;;
    repos/*) endpoint="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$endpoint" >> "$GH_LOG"
case "$endpoint" in
  repos/*/issues/*)
    f="$GH_STATE/$(printf '%s' "${endpoint#repos/}" | tr '/' '_')"
    [ -f "$f" ] || exit 1
    s="$(cat "$f")"
    [ "$s" != hang ] || { sleep 30; exit 1; }
    printf '%s\n' "$s" ;;
  *) exit 1 ;;
esac
STUB
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$STUBS"/*

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS/p"
# A live Claude session standing in wt-ev-live: its pid is alive and its command line carries its id.
LIVE_SID="0000aaaa-0000-4000-8000-0000000000e7"
python3 -c 'import time; time.sleep(600)' "$LIVE_SID" </dev/null >/dev/null 2>&1 &
live_pid=$!; disown "$live_pid" 2>/dev/null || true
printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"worker7"}\n' "$live_pid" "$LIVE_SID" "$T/wt-ev-live" \
  > "$SESSIONS/$live_pid.json"
printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' "$LIVE_SID" "$T/wt-ev-live" > "$PROJECTS/p/$LIVE_SID.jsonl"

SPOT="$T/spotcheck.log"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/archive" CC_WJ_ARCHIVE_MAX_BYTES=1024 CC_WJ_RECLAIM_PUSHED=0
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$SPOT"
export CC_WJ_EVIDENCE_GH_TIMEOUT_SECONDS=5
unset CC_WJ_NEW_RULES_MODE CC_WJ_PROMOTED_RULES CC_WJ_EVIDENCE_EXPIRY_MODE CC_WJ_EVIDENCE_EXPIRY_DAYS CC_WJ_EVIDENCE_EXPIRY_ROOT CC_WJ_DENY_NAMES
wj() { PATH="$STUBS:$PATH" bash "${WJS:-$WJ}" --repo "$PRIMARY" --repo "$OTHER" "$@" 2>&1; }

# One worktree's lines of a report: its WORKTREE line up to the next one.
block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
says() { block "$1" "$2" | grep -qF -- "$3"; }
judged() { block "$1" "$2" | grep -qxF "    classification: $3"; }
spot_has() { grep -F -- "path=$T/wt-$1 " "$SPOT" | grep -qF -- "$2"; }
logged() { grep -qF -- "path=$T/wt-$1 " "$SPOT"; }
issue_calls() { grep -cxF "repos/acme/widgets/issues/$1" "$GH_LOG"; }
# Trees whose evidence is expired (every issue closed, newest file at least 7 days old).
EXPIRED="closed shared edge"

# ─── shadow (the default): decides nothing, logs what it would do ────────────

: > "$SPOT"; : > "$GH_LOG"
wj > "$T/report-shadow.txt"
for n in $EXPIRED; do
  check "shadow: ev-$n stays kept as before" judged "$T/report-shadow.txt" "ev-$n" "KEEP(unrebuildable=1)"
  check "shadow: ev-$n is logged as would-remove for rule evidence-expired" \
    spot_has "ev-$n" "phase=removal action=would-remove rule=evidence-expired"
  check "shadow: ev-$n's log line carries the tree's bytes and a run id" \
    bash -c 'grep -F "path=$1 " "$2" | grep -Eq "run=[0-9TZ]+-[0-9]+ .* bytes=[1-9][0-9]* holder=none"' _ "$T/wt-ev-$n" "$SPOT"
  check "shadow: the report says the rule would make ev-$n removable" \
    says "$T/report-shadow.txt" "ev-$n" "spotcheck: evidence-expired would make it REMOVABLE"
done
check "shadow: the report counts the trees the rule would free and decides nothing" \
  grep -qF "rule-effect: evidence-expired (shadow: logged only, decides nothing) trees=3 " "$T/report-shadow.txt"
check "shadow: an issue is asked once per run however many trees name it" test "$(issue_calls 101)" -eq 1
wj --apply > "$T/apply-shadow.txt"
check "shadow --apply removes nothing the rule reached" \
  bash -c 'for n in closed shared edge; do [ -d "$1/wt-ev-$n" ] || exit 1; done' _ "$T"
check "  and archives nothing" test ! -e "$T/archive"

# Every keep, in every mode: the tree is neither removable nor logged.
keeps() { # <report file> <label> <how a live session shows: shadow reverts to the content gate's keep>
  local r="$1" l="$2" live="$3"
  check "$l: an open issue keeps the tree (104 closed, 103 open)" judged "$r" ev-open "KEEP(unrebuildable=1)"
  check "  and the report names the open issue" says "$r" ev-open "evidence-expired: kept: issue acme/widgets#103 is open"
  check "$l: a newest file 6 days old keeps it" judged "$r" ev-young "KEEP(unrebuildable=1)"
  check "  and the report says it is younger than 7 days" says "$r" ev-young "is younger than 7 days"
  check "$l: a name with no issue number keeps it" judged "$r" ev-nonum "KEEP(unrebuildable=1)"
  check "  and the report names the entry" says "$r" ev-nonum "no issue number in the name .codex/evidence/scratch"
  check "$l: a date-like name is no issue number" says "$r" ev-date "no issue number in the name .codex/evidence/2026-11-11-notes"
  for d in us dot ym; do
    check "$l: a date written with underscores, dots or only a month (ev-date-$d) is no issue number" \
      judged "$r" "ev-date-$d" "KEEP(unrebuildable=1)"
  done
  check "  and the report names the entry" says "$r" ev-date-us "no issue number in the name .codex/evidence/2026_11_04-run"
  check "$l: a tree not landed on main stays kept with its evidence expired" \
    bash -c 'grep -A3 -F "wt-ev-unlanded" "$1" | grep -qE "^    classification: KEEP\("' _ "$r"
  check "$l: a name whose digits run into a letter is no issue number" says "$r" ev-letter "no issue number in the name .codex/evidence/3rdparty"
  check "$l: a credential-shaped file keeps it" judged "$r" ev-cred "KEEP(unrebuildable=1)"
  check "  and the report says so" says "$r" ev-cred "a credential-shaped file under .codex/evidence"
  check "$l: a failing issue lookup keeps it" says "$r" ev-ghfail "issue acme/widgets#109 is unknown"
  check "$l: a non-GitHub remote keeps it" judged "$r" ev-nongh "KEEP(unrebuildable=1)"
  check "  and the report says so" says "$r" ev-nongh "origin is not a GitHub repository"
  check "$l: another unrebuildable entry beside the evidence keeps it" judged "$r" ev-mixed "KEEP(unrebuildable=2)"
  check "$l: a live session in it keeps it" judged "$r" ev-live "$live"
}
keeps "$T/report-shadow.txt" shadow "KEEP(unrebuildable=1)"
for n in open young nonum date date-us date-dot date-ym letter cred ghfail timeout timeout2 nongh mixed live unlanded; do
  refute "shadow: ev-$n is not logged" logged "ev-$n"
done

# A lookup that outlasts its bound keeps the tree: one run with 110 hanging and a 2 s bound.
# Two distinct issues hang (110, 111): the first costs the bound, the second is answered unknown at once.
issue 110 hang; issue 111 hang; : > "$GH_LOG"
CC_WJ_EVIDENCE_GH_TIMEOUT_SECONDS=2 CC_WJ_EVIDENCE_EXPIRY_MODE=apply wj > "$T/report-timeout.txt"
check "a timed-out issue lookup keeps the tree" says "$T/report-timeout.txt" ev-timeout "issue acme/widgets#110 is unknown"
check "  and so does the tree of the second hanging issue" says "$T/report-timeout.txt" ev-timeout2 "issue acme/widgets#111 is unknown"
check "after the first timeout the run asks no further issue (one hanging call in all)" \
  test "$(( $(issue_calls 110) + $(issue_calls 111) ))" -eq 1
check "  and does not hold up the tree whose issue answered" judged "$T/report-timeout.txt" ev-closed REMOVABLE
rm -f "$GH_STATE/acme_widgets_issues_110" "$GH_STATE/acme_widgets_issues_111"

# ─── off ─────────────────────────────────────────────────────────────────────

: > "$SPOT"; : > "$GH_LOG"
CC_WJ_EVIDENCE_EXPIRY_MODE=off wj > "$T/report-off.txt"
refute "off: the rule logs nothing" grep -qF "rule=evidence-expired" "$SPOT"
check "off: no issue is asked" test ! -s "$GH_LOG"
check "off: an expired tree is kept as before" judged "$T/report-off.txt" ev-closed "KEEP(unrebuildable=1)"
refute "off: no rule-effect line" grep -qF "rule-effect: evidence-expired" "$T/report-off.txt"

# ─── apply: the rule decides ─────────────────────────────────────────────────

: > "$SPOT"; : > "$GH_LOG"
CC_WJ_EVIDENCE_EXPIRY_MODE=apply wj > "$T/report-apply.txt"
for n in $EXPIRED; do
  check "apply: ev-$n is REMOVABLE" judged "$T/report-apply.txt" "ev-$n" REMOVABLE
done
check "apply: the report says the record is copied out first" says "$T/report-apply.txt" ev-closed ".codex/evidence/101/result.json"
refute "  and the file it cannot copy is not listed" says "$T/report-apply.txt" ev-closed "big.bin"
check "apply: the report counts what the rule decides" \
  grep -qF "rule-effect: evidence-expired (decides: would free) trees=3 " "$T/report-apply.txt"
refute "apply: nothing is logged to the spot-check log" logged ev-closed
check "apply: a newest file 7 days old (ev-edge) is old enough" judged "$T/report-apply.txt" ev-edge REMOVABLE
check "apply: and 6 days (ev-young) is not" judged "$T/report-apply.txt" ev-young "KEEP(unrebuildable=1)"
keeps "$T/report-apply.txt" apply "KEEP(active-session)"
check "apply: that tree is kept as not landed" judged "$T/report-apply.txt" ev-unlanded "KEEP(unlanded)"
check "apply: an issue is asked once per run" test "$(issue_calls 101)" -eq 1

# ─── per-rule promotion ──────────────────────────────────────────────────────

wj > "$T/report-probation.txt"
check "probation: a tree kept only by a skills link into the primary checkout stays kept" \
  judged "$T/report-probation.txt" skills-only "KEEP(unrebuildable=1)"
CC_WJ_PROMOTED_RULES="dirty-pressure pushed-idle" wj > "$T/report-other.txt"
check "promotion: naming other rules leaves primary-skills-link on probation" \
  judged "$T/report-other.txt" skills-only "KEEP(unrebuildable=1)"
CC_WJ_PROMOTED_RULES="dirty-pressure   primary-skills-link" wj > "$T/report-promoted.txt"
check "promotion: a named rule decides although CC_WJ_NEW_RULES_MODE is spotcheck" \
  judged "$T/report-promoted.txt" skills-only REMOVABLE
check "  and the report counts it" grep -qF "rule-effect: primary-skills-link (decides: would free) trees=1 " "$T/report-promoted.txt"
check "promotion: a tree kept by a skills link and by expired evidence is kept, as the skills link only logged" \
  judged "$T/report-probation.txt" ev-skills "KEEP(unrebuildable=2)"
check "promotion: with the link promoted, the evidence rule is asked (shadow) and logs it" \
  judged "$T/report-promoted.txt" ev-skills "KEEP(unrebuildable=1)"
check "  as would-remove for rule evidence-expired" spot_has ev-skills "action=would-remove rule=evidence-expired"
CC_WJ_PROMOTED_RULES="primary-skills-link" CC_WJ_EVIDENCE_EXPIRY_MODE=apply wj > "$T/report-both.txt"
check "promotion: promoted and applied together, that tree is REMOVABLE" judged "$T/report-both.txt" ev-skills REMOVABLE
CC_WJ_PROMOTED_RULES="primary-skills-link" CC_WJ_EVIDENCE_EXPIRY_MODE=off wj > "$T/report-promoted-only.txt"
check "promotion: with the evidence rule off that tree keeps its evidence pin" judged "$T/report-promoted-only.txt" ev-skills "KEEP(unrebuildable=1)"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/report-auto.txt"
check "auto: CC_WJ_NEW_RULES_MODE=auto still promotes every rule" judged "$T/report-auto.txt" skills-only REMOVABLE

# ─── mutants: remove one keep guard, the matching tree must turn removable ───

mutant() { # <name> <tree> <mode> <old> <new> [<old> <new>]...
  local name="$1" tree="$2" mode="$3" f="$T/mutant-$1.sh"
  shift 3
  if ! python3 - "$WJ" "$f" "$@" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
pairs = sys.argv[3:]
for old, new in zip(pairs[::2], pairs[1::2]):
    if s.count(old) != 1:
        sys.exit("mutation target not found exactly once: %r (%d)" % (old, s.count(old)))
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  then nok "mutant $name could not be built"; return; fi
  WJS="$f" CC_WJ_EVIDENCE_EXPIRY_MODE="$mode" wj > "$T/mutant-$name.txt"
  if judged "$T/mutant-$name.txt" "$tree" REMOVABLE; then ok "mutant $name is killed: $tree turns REMOVABLE without the guard"
  else nok "mutant $name survives: $tree is still kept without the guard"; fi
}
mutant issue-state ev-open apply \
  '[ "$st" = closed ] ||' 'true ||'
mutant failed-lookup ev-ghfail apply \
  'case "$out" in closed|open) ;; *) out=unknown ;; esac' 'case "$out" in closed|open) ;; *) out=closed ;; esac'
mutant age ev-young apply \
  '[ -z "$f" ] || { _CC_WJ_EVIDENCE_WHY="${f#"$wt/"} is younger than $days days"; return 1; }' ':'
mutant no-number ev-nonum apply \
  '      { _CC_WJ_EVIDENCE_WHY="no issue number in the name $root/$name"; return 1; }' '      num=1'
mutant date-name ev-date apply \
  'case "$rest" in [-_.][0-9][0-9]*) return 1 ;; esac' ':'
for sep in us dot ym; do
  mutant "date-sep-$sep" "ev-date-$sep" apply \
    'case "$rest" in [-_.][0-9][0-9]*) return 1 ;; esac' \
    'case "$n" in [0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]*) return 1 ;; esac'
done
mutant credential ev-cred apply \
  'if _cc_wj_find_credential "$wt/$root" "" all; then' 'if false; then' \
  '*"holds a newline"*|*"could not be listed for the copy"*|*"credential-shaped"*|' '*"holds a newline"*|*"could not be listed for the copy"*|'
mutant letter-name ev-letter apply \
  "  case \"\$rest\" in ''|[-_.\\ ]*) ;; *) return 1 ;; esac" ':'
mutant remote ev-nongh apply \
  '[ "$host" = github.com ] || return 1' ':'
mutant only-evidence ev-mixed apply \
  '      *) ok=0; break ;;' '      *) ;;' \
  '      *) ok=0 ;;' '      *) ;;'
mutant shadow-mode ev-closed shadow \
  '  if [ "$mode" = shadow ]; then
    while IFS= read -r line; do _cc_wj_newrule_note' '  if false; then
    while IFS= read -r line; do _cc_wj_newrule_note'
mutant mode-off ev-closed off \
  'if [ "$mode" = off ] || [ "$rc" -ne 0 ]' 'if [ "$rc" -ne 0 ]'
mutant promotion skills-only spotcheck \
  $'  case "$list" in *" $1 "*) return 0 ;; esac\n  return 1\n}' $'  return 0\n}'

# The timeout marker is what spares the second hanging issue its wait: without it both issues are asked.
python3 - "$WJ" "$T/mutant-marker.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = """    if [ -e "$_CC_WJ_EVIDENCE_CACHE_DIR/timed-out" ]; then printf 'unknown\\n'; return 0; fi\n"""
if s.count(old) != 1: sys.exit("marker line not found exactly once")
open(sys.argv[2], "w").write(s.replace(old, ""))
PY
rc=$?
if [ "$rc" -ne 0 ]; then nok "mutant timeout-marker could not be built"; else
  issue 110 hang; issue 111 hang; : > "$GH_LOG"
  WJS="$T/mutant-marker.sh" CC_WJ_EVIDENCE_GH_TIMEOUT_SECONDS=2 CC_WJ_EVIDENCE_EXPIRY_MODE=apply wj > "$T/mutant-marker.txt"
  if [ "$(( $(issue_calls 110) + $(issue_calls 111) ))" -eq 2 ]; then ok "mutant timeout-marker is killed: both hanging issues are asked without the marker"
  else nok "mutant timeout-marker survives: the second hanging issue was not asked"; fi
  issue 110 fail; issue 111 fail
fi

# ─── apply --apply: removal, copy first, the rest untouched ──────────────────

: > "$SPOT"
CC_WJ_EVIDENCE_EXPIRY_MODE=apply wj --apply > "$T/apply-apply.txt"
check "--apply: the expired trees are removed" \
  bash -c 'for n in closed shared edge; do [ ! -e "$1/wt-ev-$n" ] || exit 1; done' _ "$T"
check "  and their branches remain" \
  bash -c 'for n in closed shared edge; do git -C "$1" show-ref -q --verify "refs/heads/ev-$n" || exit 1; done' _ "$PRIMARY"
check "  and the record the archive: line can copy was copied first" \
  bash -c 'find "$1" -name result.json -path "*ev-closed*" | grep -q result.json && find "$1" -name n.txt | grep -q n.txt' _ "$T/archive"
refute "  and the file it cannot copy was not" bash -c 'find "$1" -name big.bin | grep -q .' _ "$T/archive"
check "  and the other trees stay" \
  bash -c 'for n in open young nonum date date-us date-dot date-ym letter cred ghfail timeout timeout2 mixed live skills unlanded; do [ -d "$1/wt-ev-$n" ] || exit 1; done' _ "$T"
check "  and a tree on another remote stays" test -d "$T/wt-ev-nongh"
check "--apply: the janitor says what it freed" grep -qF "rule-effect: evidence-expired (decided: freed) trees=3 " "$T/apply-apply.txt"
refute "  and the rule logged nothing in apply mode" grep -qF "rule=evidence-expired" "$SPOT"

echo "# $failures failure(s)"
[ "$failures" -eq 0 ]
