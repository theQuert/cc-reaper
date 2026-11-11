#!/usr/bin/env bash
# worktree-janitor (stima-api#7881): the Mac mini disk audit of 2026-11-11.
#
# A Claude session that enters a worktree has its transcript moved to that worktree's project
#    directory. The sweep lists transcripts once, spends minutes judging trees, and then asks the
#    listed path: gone, so "could not be parsed", so one unknown record, so (under the default
#    spot-check mode, which decides as `global` does) every clean landed idle tree of the pass was
#    kept. 4 of the 35 removal passes that examined trees that day. The same session id's transcript is now looked up where
#    it went and read there. What cannot be read or found stays unknown, and a session that moved
#    INTO a tree claims it:
#      M1  scan, move, ask: the moved transcript names nothing          -> 1, no unknown record
#      M2  the moved transcript's last cwd is the tree                  -> 0 (the cwd claim the scan missed)
#      M3  the moved transcript's current turn names the tree           -> 0
#      M4  the transcript is nowhere                                    -> 2 (global) / unknown record
#      M5  the moved transcript cannot be read                          -> 2
#      M6  the moved transcript records no cwd                          -> 2
#      M7  a stale path that is no session id's transcript              -> 2
#      M8  the transcript did not move                                  -> as before
#      M9  the session id is found in two places                        -> 2 (as the live scan)
#      M10 after a move the records point at the new path, the claim is moved-cwd, and
#          the cwd claim stays for the next candidate
#
# Real git repository and a local bare origin; lsof and gh are stubs. TAP-style; set WJ_SCRIPT
# to test another copy of the janitor.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="${WJ_SCRIPT:-$ROOT_DIR/shell/worktree-janitor.sh}"
failures=0
ok() { printf 'ok - %s\n' "$1"; }
nok() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name"; fi; }
refute() { local name=$1; shift; if "$@" >/dev/null 2>&1; then nok "$name"; else ok "$name"; fi; }
eq() { local name=$1 got=$2 want=$3; if [ "$got" = "$want" ]; then ok "$name"; else nok "$name (got: $got; want: $want)"; fi; }

T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
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
G -C "$PRIMARY" add README.md
G -C "$PRIMARY" commit -qm init
G -C "$PRIMARY" push -q origin main
for n in B C; do G -C "$PRIMARY" worktree add -q -b "$n" "$T/wt-$n" main; done

PROJECTS="$T/claude-projects"; SESSIONS="$T/claude-sessions"; mkdir -p "$PROJECTS" "$SESSIONS"
STUBS="$T/stubs"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/osascript"
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) printf 'p1\nn/\n' ;;
  *) printf 'p1\nn/dev/null\n' ;;
esac
STUB
chmod +x "$STUBS"/*

export CC_WJ_CONFIG="$T/no-config" CC_WJ_ROOT="$T" CC_WJ_LOG="$T/wj.log" CC_WJ_STATE_DIR="$T/state"
export CC_WJ_NOTIFY_MIN_GB=0 CC_WJ_COOLDOWN_SECS=0 CC_WJ_IDLE_HOURS=0 CC_WJ_PRESSURE_FREE_GB=off
export CC_WJ_CLAUDE_SESSIONS="$SESSIONS" CC_WJ_CLAUDE_PROJECTS="$PROJECTS"
export CC_WJ_CODEX_LOCKS="$T/no-codex-locks" CC_WJ_CODEX_STATE_DB="$T/no-codex.sqlite"
export CC_WJ_ARCHIVE_DIR="$T/no-archive" CC_WJ_TRANSCRIPT_RETRY_SECONDS=0
export CC_WJ_LAUNCHAGENTS_DIRS="$T/no-launchagents" CC_WJ_SPOTCHECK_LOG="$T/spot.log"
unset CC_WJ_NEW_RULES_MODE CC_WJ_UNKNOWN_SESSION_SCOPE CC_WJ_DENY_NAMES
export PATH="$STUBS:$PATH" WJ T PRIMARY PROJECTS

enc() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
# Where Claude keeps session $2's transcript for cwd $1.
tpath() { printf '%s/%s/%s.jsonl' "$PROJECTS" "$(enc "$1")" "$2"; }
# A transcript for session $2 under the project directory of $1, last cwd $3, current turn
# naming $4 (nothing when empty).
mk() { # <projdir cwd> <sid> <last cwd> [path named]
  local f; f="$(tpath "$1" "$2")"; mkdir -p "$(dirname "$f")"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$3" > "$f"
  if [ -n "${4:-}" ]; then
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls %s"}}]}}\n' "$3" "$4" >> "$f"
  else
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}\n' "$3" >> "$f"
  fi
}
mv_t() { # <from cwd> <to cwd> <sid>
  mkdir -p "$(dirname "$(tpath "$2" "$3")")"
  mv "$(tpath "$1" "$3")" "$(tpath "$2" "$3")"
}

export -f enc tpath mv_t

# The sweep's own sequence: list recent transcripts, then (after the move) ask the janitor whether
# the recent session claims tree $2. Prints "rc=<status> unknown=<n>" and the reason on rc 2.
# $1 is the shell snippet that happens between the scan and the question.
ask() { # <between scan and ask> <tree> [scope]
  CC_WJ_UNKNOWN_SESSION_SCOPE="${3:-tree}" BETWEEN="$1" TREE="$2" bash -c '
    set +u
    . "$WJ"
    _cc_wj_scan_claude_recent 24 || { echo "scan-failed: $_CC_WJ_ACTIVE_ERROR"; exit 9; }
    eval "$BETWEEN"
    _cc_wj_recent_claim "$TREE" 24 tool; rc=$?
    echo "rc=$rc unknown=$(printf "%s" "$_CC_WJ_UNKNOWN" | cut -f1 | sort -u | grep -c .)"
  ' 2>&1
}

SID="5a1b2c3d-0000-4000-8000-0000000000aa"

# ─── M8 control: the transcript did not move ──────────────────────────────────

mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask : "$T/wt-B")"
eq "M8: a transcript that stayed and names nothing: rc=1, no unknown record" "$out" "rc=1 unknown=0"
mk "$PRIMARY" "$SID" "$PRIMARY" "$T/wt-B/x"
out="$(ask : "$T/wt-B")"
eq "M8: a transcript that stayed and names the tree: rc=0" "$out" "rc=0 unknown=0"

# ─── M1: scan, move, ask ──────────────────────────────────────────────────────

mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "mv_t '$PRIMARY' '$T/wt-C' $SID" "$T/wt-B")"
eq "M1: the moved transcript names nothing: rc=1 and no unknown record" "$out" "rc=1 unknown=0"
rm -f "$(tpath "$T/wt-C" "$SID")"
mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "mv_t '$PRIMARY' '$T/wt-C' $SID" "$T/wt-B" global)"
eq "M1: scope=global does not fail the sweep either" "$out" "rc=1 unknown=0"

# ─── M2: the session moved INTO the tree ──────────────────────────────────────

rm -f "$(tpath "$T/wt-C" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY"
BETWEEN="mv_t '$PRIMARY' '$T/wt-C' $SID; printf '%s\n' '{\"type\":\"user\",\"cwd\":\"$T/wt-C\",\"message\":{\"role\":\"user\",\"content\":\"cd\"}}' >> '$(tpath "$T/wt-C" "$SID")'"
out="$(ask "$BETWEEN" "$T/wt-C")"
eq "M2: the moved transcript's last cwd is the tree: it claims it (rc=0)" "$out" "rc=0 unknown=0"
rm -f "$(tpath "$T/wt-C" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "$BETWEEN" "$T/wt-B")"
eq "M2: and claims no other tree (rc=1)" "$out" "rc=1 unknown=0"

# ─── M3: the moved transcript's current turn names the tree ───────────────────

rm -f "$(tpath "$T/wt-C" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY" "$T/wt-B/file"
out="$(ask "mv_t '$PRIMARY' '$T/wt-C' $SID" "$T/wt-B")"
eq "M3: a tool call in the moved transcript names the tree: rc=0" "$out" "rc=0 unknown=0"

# ─── M4: the transcript is nowhere ────────────────────────────────────────────

rm -f "$(tpath "$T/wt-C" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "rm -f '$(tpath "$PRIMARY" "$SID")'" "$T/wt-B")"
eq "M4: gone for good: still an unknown record (tree scope)" "$out" "rc=1 unknown=1"
mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "rm -f '$(tpath "$PRIMARY" "$SID")'" "$T/wt-B" global)"
eq "M4: gone for good: still rc=2 (global scope)" "$out" "rc=2 unknown=0"

# ─── M5: the moved transcript cannot be read ──────────────────────────────────

mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "mv_t '$PRIMARY' '$T/wt-C' $SID; chmod 000 '$(tpath "$T/wt-C" "$SID")'" "$T/wt-B" global)"
eq "M5: an unreadable moved transcript is still rc=2" "$out" "rc=2 unknown=0"
chmod 600 "$(tpath "$T/wt-C" "$SID")"; rm -f "$(tpath "$T/wt-C" "$SID")"

# ─── M6: the moved transcript records no cwd ──────────────────────────────────

mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(ask "mv_t '$PRIMARY' '$T/wt-C' $SID; printf '{\"type\":\"summary\",\"summary\":\"s\"}\n' > '$(tpath "$T/wt-C" "$SID")'" "$T/wt-B" global)"
eq "M6: a moved transcript with no cwd cannot clear the tree: rc=2" "$out" "rc=2 unknown=0"
rm -f "$(tpath "$T/wt-C" "$SID")"

# ─── M7: a stale path that is no session id's transcript ──────────────────────

out="$(TREE="$T/wt-B" bash -c 'set +u; . "$WJ"; _cc_wj_transcript_claims_path Claude "$PROJECTS/x/not-a-session.jsonl" "$TREE"; echo "rc=$?"' 2>&1)"
eq "M7: a missing path that is not <session id>.jsonl is rc=2" "$out" "rc=2"
mk "$PRIMARY" "$SID" "$PRIMARY"
out="$(TREE="$T/wt-B" bash -c 'set +u; . "$WJ"; _cc_wj_transcript_claims_path Codex "$PROJECTS/x/'"$SID"'.jsonl" "$TREE"; echo "rc=$?"' 2>&1)"
eq "M7: a missing Codex path is not looked up under Claude's projects: rc=2" "$out" "rc=2"


# ─── M9: the session id is found in two places ────────────────────────────────

two_copies="mv_t '$PRIMARY' '$T/wt-C' $SID; mkdir -p '$(dirname "$(tpath "$T/wt-B" "$SID")")'; cp '$(tpath "$T/wt-C" "$SID")' '$(tpath "$T/wt-B" "$SID")'"
rm -f "$(tpath "$T/wt-C" "$SID")" "$(tpath "$T/wt-B" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY" "$T/wt-B/x"
out="$(ask "$two_copies" "$T/wt-B" global)"
eq "M9: two copies of the transcript: rc=2, even though both name the tree" "$out" "rc=2 unknown=0"
rm -f "$(tpath "$T/wt-C" "$SID")" "$(tpath "$T/wt-B" "$SID")"; mk "$PRIMARY" "$SID" "$PRIMARY" "$T/wt-B/x"
out="$(ask "$two_copies" "$T/wt-B")"
eq "M9: two copies, tree scope: an unknown record, not a claim" "$out" "rc=1 unknown=1"
rm -f "$(tpath "$T/wt-C" "$SID")" "$(tpath "$T/wt-B" "$SID")"

# ─── M10: after a move, the records follow it ─────────────────────────────────

FIND_LOG="$T/find.log"; export FIND_LOG
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIND_LOG"\nexec /usr/bin/find "$@"\n' > "$STUBS/find"; chmod +x "$STUBS/find"
mk "$PRIMARY" "$SID" "$PRIMARY"
OLD="$(tpath "$PRIMARY" "$SID")"; NEW="$(tpath "$T/wt-C" "$SID")"; export OLD NEW
: > "$FIND_LOG"
out="$(BETWEEN="$BETWEEN" bash -c '
  set +u
  . "$WJ"
  _cc_wj_scan_claude_recent 24 || exit 9
  eval "$BETWEEN"
  _cc_wj_recent_claim "$T/wt-C" 24 tool; c=$?
  reason="$_CC_WJ_RECENT_REASON"
  _cc_wj_recent_claim "$T/wt-B" 24 tool; b=$?
  _cc_wj_recent_claim "$T/wt-C" 24 cwd; c2=$?
  newp=$(printf "%s\n" "$_CC_WJ_RECENT_TRANSCRIPTS" | awk -F"\t" -v p="$NEW" "\$3 == p" | grep -c .)
  oldp=$(printf "%s\n" "$_CC_WJ_RECENT_TRANSCRIPTS" | awk -F"\t" -v p="$OLD" "\$3 == p" | grep -c .)
  echo "B=$b C=$c C-cwd-mode=$c2 $(printf "%s" "$reason" | grep -o "scope=[a-z-]*") new=$newp old=$oldp"
' 2>&1)"
eq "M10: one tree is not claimed; the tree the session moved into is, as moved-cwd; the claim outlives the call; the records point at the new path" \
  "$out" "B=1 C=0 C-cwd-mode=0 scope=moved-cwd new=1 old=0"
eq "M10: the session id was searched for once for two candidates" "$(grep -c -- '-maxdepth 2' "$FIND_LOG")" "1"
rm -f "$NEW" "$STUBS/find"

[ "$failures" -eq 0 ] && echo "# all passed" || echo "# $failures failed"
exit "$failures"
