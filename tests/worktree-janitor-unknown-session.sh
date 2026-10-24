#!/usr/bin/env bash
# worktree-janitor: a session record that cannot be read keeps only the worktrees it could be
# about (stima-api#5886), instead of every worktree on the machine.
#   A  old, landed, clean; an unreadable recent transcript's project directory names it  -> kept
#   F  old, landed, clean; a torn live session record's raw cwd names it                 -> kept
#      (its transcript, found by the session id in the raw text, is ten days old and readable)
#   B  old, landed, clean; nothing names it                       -> freed per tree, kept by global
#   C  recent, landed, clean; nothing names it                    -> kept by its own recency
#   D  old, dirty (would go to refs/wip first)                    -> never freed while a record is unknown
#   E  old, a commit origin does not have                         -> never freed
# CC_WJ_UNKNOWN_SESSION_SCOPE=tree under CC_WJ_NEW_RULES_MODE=spotcheck (default), auto, and
# CC_WJ_UNKNOWN_SESSION_SCOPE=global. Then, with trees G and H, a live record that can work in any
# tree by absolute path (stima-api#5886 review): its transcript names H from a cwd elsewhere; it
# has no transcript at all (every tree kept); its cwd is a symlink into G; and a torn record that
# appears only after the inventory, caught right before removal. Real git repositories and a
# local bare "origin"; lsof and gh are stubs. TAP-style; set WJ_SCRIPT to test another copy of
# the janitor.
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
cleanup() {
  [ -z "$live_pid" ] || kill "$live_pid" 2>/dev/null
  chmod -R u+rwX "$T" 2>/dev/null
  rm -rf "$T"
}
[ -n "${WJ_KEEP_TMP:-}" ] || trap cleanup EXIT
[ -z "${WJ_KEEP_TMP:-}" ] || echo "# kept: $T"
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
G() { git -c user.name=Fixture -c user.email=fixture@example.com "$@"; }

ORIGIN="$T/origin.git"; PRIMARY="$T/primary"
G init -q --bare "$ORIGIN" -b main
G clone -q "$ORIGIN" "$PRIMARY" 2>/dev/null
echo init > "$PRIMARY/README.md"
printf 'node_modules/\n' > "$PRIMARY/.gitignore"
G -C "$PRIMARY" add README.md .gitignore
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main

mkwt() { G -C "$PRIMARY" worktree add -q -b "$1" "$T/wt-$1" main; }
mkwt A; mkwt B; mkwt C; mkwt D; mkwt E; mkwt F
echo notes > "$T/wt-D/notes.txt"
echo work > "$T/wt-E/work.txt"; G -C "$T/wt-E" add work.txt; G -C "$T/wt-E" commit -qm "work on E"

# Ten days old, so no recent-session scan reads it: a live session idle since then.
old_file() { python3 -c 'import os, sys, time; t = time.time() - 10 * 86400; os.utime(sys.argv[1], (t, t))' "$1"; }
# A readable transcript for session $1 in the project directory of cwd $2, whose current turn
# has a tool call naming path $3.
transcript() { # <session id> <cwd> <path named>
  local dir="$PROJECTS/$(printf '%s' "$2" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$2" > "$dir/$1.jsonl"
  printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls %s"}}]}}\n' \
    "$2" "$3" >> "$dir/$1.jsonl"
  old_file "$dir/$1.jsonl"
}

# Ten days old: every entry of the tree, the tree itself, and its git index, HEAD and HEAD reflog.
age() { # <name>...
  local n gitdir
  for n in "$@"; do
    gitdir="$(git -C "$T/wt-$n" rev-parse --absolute-git-dir)"
    python3 - "$T/wt-$n" "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD" <<'PY'
import os, sys, time
old = time.time() - 10 * 86400
tree, *extra = sys.argv[1:]
for root, dirs, files in os.walk(tree):
    for name in dirs + files:
        os.utime(os.path.join(root, name), (old, old), follow_symlinks=False)
for path in extra:
    if os.path.exists(path):
        os.utime(path, (old, old))
os.utime(tree, (old, old))
PY
  done
}
reage() { age A B D E F; }

# ─── Stubs and env ────────────────────────────────────────────────────────────

STUBS="$T/stubs"; mkdir -p "$STUBS"
LSOF_CWD_FILE="$T/lsof-cwd.txt"; LSOF_OPEN_FILE="$T/lsof-open.txt"
export LSOF_CWD_FILE LSOF_OPEN_FILE
printf 'p1\nn/\n' > "$LSOF_CWD_FILE"
printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$STUBS"/*

SESSIONS="$T/claude-sessions"; PROJECTS="$T/claude-projects"; mkdir -p "$SESSIONS" "$PROJECTS"
SPOT="$T/spotcheck.log"
export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_RECLAIM_PUSHED=1 CC_WJ_TRANSCRIPT_RETRY_SECONDS=0
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$SPOT"
unset CC_WJ_NEW_RULES_MODE CC_WJ_UNKNOWN_SESSION_SCOPE CC_WJ_DENY_NAMES
wj() { reage; PATH="$STUBS:$PATH" bash "$WJ" --repo "$PRIMARY" "$@" 2>&1; }

block() { awk -v tail="/wt-$2" '/^  WORKTREE  / { on = (substr($0, length($0) - length(tail) + 1) == tail) } on' "$1"; }
says() { block "$1" "$2" | grep -qF -- "$3"; }
judged() { block "$1" "$2" | grep -qxF "    classification: $3"; }
removable() { block "$1" "$2" | grep -q '^    classification: REMOVABLE'; }

# ─── Control: no unreadable record ────────────────────────────────────────────

wj > "$T/control.txt"; control_rc=$?
check "control: exit 0 with every record readable" test "$control_rc" -eq 0
for n in A B C F; do
  check "control: landed clean tree $n is removable" judged "$T/control.txt" "$n" REMOVABLE
done
check "control: dirty D would go to refs/wip first" judged "$T/control.txt" D 'REMOVABLE(wip-pushed)'
check "control: E with an unpushed commit is kept" judged "$T/control.txt" E 'KEEP(unlanded)'

# ─── The unreadable records ───────────────────────────────────────────────────

# A recent transcript nobody can open, in the project directory Claude names after wt-A.
SID_A="b627c13d-0000-4000-8000-00000000000a"
PROJ_A="$PROJECTS/$(printf '%s' "$T/wt-A" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$PROJ_A"
printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"x"}}\n' "$T/wt-A" > "$PROJ_A/$SID_A.jsonl"
chmod 000 "$PROJ_A/$SID_A.jsonl"
# A live Claude process whose registry record is torn mid-write; its raw text still names wt-F.
python3 -c 'import time; time.sleep(600)' </dev/null >/dev/null 2>&1 &
live_pid=$!; disown "$live_pid" 2>/dev/null || true
printf '{"pid":%s,"sessionId":"0000aaaa-0000-4000-8000-00000000000f","cwd":"%s","na' "$live_pid" "$T/wt-F" \
  > "$SESSIONS/$live_pid.json"
transcript 0000aaaa-0000-4000-8000-00000000000f "$T/wt-F" "$T/wt-F/notes"
REC_A="session-unknown:claude-transcript:$SID_A"
REC_F="session-unknown:claude-session:$live_pid.json"

# ─── scope=tree, mode=auto: the rule decides ──────────────────────────────────

: > "$SPOT"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/auto.txt"; auto_rc=$?
check "auto: A, which the unreadable transcript's project directory names, is kept by it" \
  judged "$T/auto.txt" A "KEEP($REC_A)"
check "auto: F, which the torn session record's raw cwd names, is kept by it" \
  judged "$T/auto.txt" F "KEEP($REC_F)"
check "auto: old clean landed B, which nothing names, is removable" judged "$T/auto.txt" B REMOVABLE
check "auto: recent C is kept by its own recency" bash -c 'grep -A3 "/wt-C$" "$1" | grep -q "classification: KEEP(session-unknown:"' _ "$T/auto.txt"
check "auto: dirty D is not sent to refs/wip while a record is unknown" \
  bash -c 'grep -A3 "/wt-D$" "$1" | grep -q "classification: KEEP(session-unknown:"' _ "$T/auto.txt"
check "auto: unpushed E stays kept" judged "$T/auto.txt" E 'KEEP(unlanded)'
check "auto: the transcript is logged once, with the trees it kept" \
  test "$(grep -c "worktree-janitor: KEEP($REC_A) scope=tree:" "$T/auto.txt")" -eq 1
check "  and that line names A and C" bash -c 'grep -F "KEEP($1) scope=tree:" "$2" | grep -F "$3/wt-A" | grep -qF "$3/wt-C"' _ "$REC_A" "$T/auto.txt" "$T"
check "  and what attributed it" bash -c 'grep -F "KEEP($1) scope=tree:" "$2" | grep -qF "projdir=-"' _ "$REC_A" "$T/auto.txt"
check "auto: the torn record is logged once" test "$(grep -c "worktree-janitor: KEEP($REC_F) scope=tree:" "$T/auto.txt")" -eq 1
refute "auto: no line says no worktree can be shown free of active sessions" \
  grep -qF "no worktree can be shown free of active sessions" "$T/auto.txt"
check "auto: the run still exits 1, since a record could not be read" test "$auto_rc" -eq 1
refute "auto: nothing is spot-checked" grep -qF "session-unknown-per-tree" "$SPOT"

# ─── scope=tree, mode=spotcheck (default): decisions as global, B logged ──────

: > "$SPOT"
wj > "$T/spot.txt"
check "spotcheck: B is kept as the global rule keeps it" judged "$T/spot.txt" B 'KEEP(active-session)'
check "  and the report says the per-tree rule would free it" says "$T/spot.txt" B "spotcheck: session-unknown-per-tree would make it REMOVABLE"
check "  and the spot-check log records B under rule session-unknown-per-tree" \
  bash -c 'grep -F "path=$1 " "$2" | grep -qF "phase=removal action=would-remove rule=session-unknown-per-tree"' _ "$T/wt-B" "$SPOT"
for n in A C D E F; do
  refute "spotcheck: $n is not logged as one the rule would free" grep -qF "path=$T/wt-$n " "$SPOT"
done
for n in A B C D E F; do
  refute "spotcheck: $n is not removable" removable "$T/spot.txt" "$n"
done

# ─── scope=global: the old behaviour ──────────────────────────────────────────

: > "$SPOT"
CC_WJ_UNKNOWN_SESSION_SCOPE=global wj > "$T/global.txt"; global_rc=$?
check "global: says no worktree can be shown free of active sessions" \
  grep -qF "so no worktree can be shown free of active sessions" "$T/global.txt"
check "global: B is kept as an active session" judged "$T/global.txt" B 'KEEP(active-session)'
for n in A B C D E F; do
  refute "global: $n is not removable" removable "$T/global.txt" "$n"
done
check "global: exits 1" test "$global_rc" -eq 1
refute "global: nothing is spot-checked" grep -qF "session-unknown-per-tree" "$SPOT"
CC_WJ_UNKNOWN_SESSION_SCOPE=global CC_WJ_NEW_RULES_MODE=auto wj > "$T/global-auto.txt"
check "global with auto: B is still kept, auto does not widen global" judged "$T/global-auto.txt" B 'KEEP(active-session)'

# ─── Trim phase ───────────────────────────────────────────────────────────────

cache() { mkdir -p "$T/wt-$1/node_modules/pkg"; echo pkg > "$T/wt-$1/node_modules/pkg/index.js"; }
cache A; cache B
wj --trim-regenerable --apply > "$T/trim-spot.txt"
check "spotcheck trim: B's cache stays while a record is unknown" test -d "$T/wt-B/node_modules"
check "spotcheck trim: so does A's" test -d "$T/wt-A/node_modules"
CC_WJ_NEW_RULES_MODE=auto wj --trim-regenerable --apply > "$T/trim-auto.txt"
check "auto trim: B's cache is trimmed" test ! -e "$T/wt-B/node_modules"
check "auto trim: A's cache stays, kept by the transcript naming it" test -d "$T/wt-A/node_modules"
check "  and says so" says "$T/trim-auto.txt" A "KEEP($REC_A)"

# ─── Applied ──────────────────────────────────────────────────────────────────

wj --apply > "$T/apply-spot.txt"
check "spotcheck --apply removes nothing" bash -c 'for n in A B C D E F; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$T"
CC_WJ_UNKNOWN_SESSION_SCOPE=global wj --apply > "$T/apply-global.txt"
check "global --apply removes nothing" bash -c 'for n in A B C D E F; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$T"
CC_WJ_NEW_RULES_MODE=auto wj --apply > "$T/apply-auto.txt"
check "auto --apply removes B" test ! -e "$T/wt-B"
check "  and keeps A, C, D, E and F" bash -c 'for n in A C D E F; do [ -d "$1/wt-$n" ] || exit 1; done' _ "$T"
check "  with D's uncommitted file and E's commit in place" \
  bash -c '[ -f "$1/wt-D/notes.txt" ] && git -C "$1/wt-E" log -1 --format=%s | grep -q "work on E"' _ "$T"
check "  and sends no refs/wip snapshot" test -z "$(git -C "$ORIGIN" for-each-ref refs/wip)"
check "  and B's branch remains" git -C "$PRIMARY" show-ref -q --verify refs/heads/B

# ─── A live record can be about any tree (stima-api#5886 review) ──────────────
#
# G and H are old, landed and clean. Each case leaves exactly one unreadable record: the torn
# registry record of the live process, rewritten per case. A's transcript is made readable and
# old, so it is no longer a record.

chmod 600 "$PROJ_A/$SID_A.jsonl"; old_file "$PROJ_A/$SID_A.jsonl"
mkwt G; mkwt H
reage() { age A D E F G H; }
REC_L="session-unknown:claude-session:$live_pid.json"
torn() { # <session id> <cwd>
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","na' "$live_pid" "$1" "$2" > "$SESSIONS/$live_pid.json"
}

# A transcript whose current turn names H, from a cwd in the primary checkout.
SID_N="0000aaaa-0000-4000-8000-00000000001a"
torn "$SID_N" "$PRIMARY"; transcript "$SID_N" "$PRIMARY" "$T/wt-H/src/main.go"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/named.txt"
check "live, transcript names H by path: H is kept by the record" judged "$T/named.txt" H "KEEP($REC_L)"
check "  and G, which nothing names, is removable" judged "$T/named.txt" G REMOVABLE

# No transcript to search: the record may be about any tree.
SID_X="0000aaaa-0000-4000-8000-00000000001b"
torn "$SID_X" "$PRIMARY"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/notranscript.txt"
for n in G H; do
  check "live, no transcript: $n is kept by the record" judged "$T/notranscript.txt" "$n" "KEEP($REC_L)"
done
check "  and the log says it may be about any tree" \
  bash -c 'grep -F "KEEP($1) scope=tree:" "$2" | grep -qF "global=-"' _ "$REC_L" "$T/notranscript.txt"

# A cwd given through a symlink into G.
SID_S="0000aaaa-0000-4000-8000-00000000001c"
ln -s "$T/wt-G" "$T/link-to-G"
torn "$SID_S" "$T/link-to-G/sub"; transcript "$SID_S" "$PRIMARY" "$PRIMARY/README.md"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/symlink.txt"
check "cwd through a symlink into G: G is kept by the record" judged "$T/symlink.txt" G "KEEP($REC_L)"
check "  and H is removable" judged "$T/symlink.txt" H REMOVABLE

# A record that parses but whose pid is not the live process its file is named for (or that has
# no pid at all): its session id may be another session's, so the transcript of that id says
# nothing about what the live process does. That transcript is readable and names only the
# primary checkout, yet G and H must stay kept by the record.
SID_Y="0000aaaa-0000-4000-8000-00000000001e"
transcript "$SID_Y" "$PRIMARY" "$PRIMARY/README.md"
printf '{"pid":1,"sessionId":"%s","cwd":"%s"}\n' "$SID_Y" "$PRIMARY" > "$SESSIONS/$live_pid.json"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/disagree.txt"
for n in G H; do
  check "record disagreeing with its live pid, foreign session id: $n is kept by the record" \
    judged "$T/disagree.txt" "$n" "KEEP($REC_L)"
done
printf '{"sessionId":"%s","cwd":"%s"}\n' "$SID_Y" "$PRIMARY" > "$SESSIONS/$live_pid.json"
CC_WJ_NEW_RULES_MODE=auto wj > "$T/nopid.txt"
for n in G H; do
  check "record with no pid, foreign session id: $n is kept by the record" judged "$T/nopid.txt" "$n" "KEEP($REC_L)"
done

# A torn record that appears after the inventory. The lsof stub writes it on its first scan of
# the Codex lock registry, which runs after the Claude registry in the same session scan, so the
# inventory never sees it and the rescan right before the first removal does.
rm -f "$SESSIONS/$live_pid.json"
mkdir -p "$T/codex-locks"
export TORN_AFTER_SCAN="$SESSIONS/$live_pid.json"
export TORN_TEXT="{\"pid\":$live_pid,\"sessionId\":\"0000aaaa-0000-4000-8000-00000000001d\",\"cwd\":\"$PRIMARY\",\"na"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *" +D "*) [ -n "${TORN_AFTER_SCAN:-}" ] && [ ! -e "$TORN_AFTER_SCAN.done" ] &&
      { printf '%s' "$TORN_TEXT" > "$TORN_AFTER_SCAN"; : > "$TORN_AFTER_SCAN.done"; }
    cat "$LSOF_OPEN_FILE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$STUBS/lsof"
CC_WJ_CODEX_LOCKS="$T/codex-locks" CC_WJ_NEW_RULES_MODE=auto wj --apply > "$T/late.txt"
check "late record: the stub wrote it during the run" test -e "$TORN_AFTER_SCAN.done"
for n in A G H; do
  check "late record: auto --apply keeps landed clean $n" test -d "$T/wt-$n"
done
check "  the first removal candidate kept by the rescan right before removal" \
  grep -qF -- "→ kept: $REC_L; an unreadable session record may be about it" "$T/late.txt"

# An active Codex claim with two state rows: one rollout path holds a space, so it cannot be
# passed on as a word. The other is readable and names only the primary checkout. The dropped
# rollout may be the one naming G, so the claim must keep every tree.
rm -f "$SESSIONS/$live_pid.json"
TID_Q="0000bbbb-0000-4000-8000-00000000002a"
LOCKS_Q="$T/codex-locks-q"; mkdir -p "$LOCKS_Q" "$T/codex rollouts"
: > "$LOCKS_Q/$TID_Q.lock"; old_file "$LOCKS_Q/$TID_Q.lock"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$TID_Q" "$PRIMARY" > "$T/codex rollouts/r1.jsonl"
printf '{"type":"response_item","payload":{"type":"function_call","arguments":"ls %s"}}\n' "$T/wt-G" >> "$T/codex rollouts/r1.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$TID_Q" "$PRIMARY" > "$T/codex-r2.jsonl"
STATE_Q="$T/codex-q.sqlite"
sqlite3 "$STATE_Q" "create table threads(id text, cwd text, rollout_path text, updated_at integer,
    archived_at integer, archived integer);
  insert into threads values ('$TID_Q', '$PRIMARY', '$T/codex rollouts/r1.jsonl', 0, null, 0);
  insert into threads values ('$TID_Q', '$PRIMARY', '$T/codex-r2.jsonl', 0, null, 0);"
export LOCK_Q_LINE="n$LOCKS_Q/$TID_Q.lock"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *" +D "*) printf 'p1\n%s\n' "$LOCK_Q_LINE" ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
STUB
chmod +x "$STUBS/lsof"
REC_Q="session-unknown:codex-claim:$TID_Q"
CC_WJ_CODEX_LOCKS="$LOCKS_Q" CC_WJ_CODEX_STATE_DB="$STATE_Q" CC_WJ_NEW_RULES_MODE=auto wj > "$T/codex-space.txt"
for n in G H; do
  check "Codex claim with a rollout path holding a space: $n is kept by the claim" \
    judged "$T/codex-space.txt" "$n" "KEEP($REC_Q)"
done

if [ "$failures" -eq 0 ]; then echo "# all passed"; else echo "# $failures failed"; fi
[ "$failures" -eq 0 ]
