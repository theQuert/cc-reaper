#!/usr/bin/env bash
# Shared Claude/Codex worktree activity claims and scheduling policy.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WJ="$ROOT_DIR/shell/worktree-janitor.sh"
TMP_ROOT="$(mktemp -d)"
trap 'jobs -p | xargs kill 2>/dev/null || true; rm -rf "$TMP_ROOT"' EXIT
failures=0

ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
LSOF_CWD_FILE="$TMP_ROOT/lsof-cwd"
LSOF_OPEN_FILE="$TMP_ROOT/lsof-open"
LSOF_LOCK_FILE="$TMP_ROOT/lsof-lock"
LSOF_LOCK_CALLS="$TMP_ROOT/lsof-lock-calls"
export LSOF_CWD_FILE LSOF_OPEN_FILE LSOF_LOCK_FILE LSOF_LOCK_CALLS

cat > "$BIN/lsof" <<'STUB'
#!/usr/bin/env bash
if [ -n "${LSOF_SLEEP_MARKER:-}" ]; then
  : > "$LSOF_SLEEP_MARKER"
  sleep "${LSOF_SLEEP_SECONDS:-2}"
fi
case " $* " in
  *" +D "*)
    printf 'x\n' >> "$LSOF_LOCK_CALLS"
    if [ -z "${LSOF_LOCK_AFTER:-}" ] ||
       [ "$(wc -l < "$LSOF_LOCK_CALLS")" -ge "$LSOF_LOCK_AFTER" ]; then
      cat "$LSOF_LOCK_FILE"
    fi
    ;;
  *" -d cwd "*) cat "$LSOF_CWD_FILE" ;;
  *".lock"*)
    if [ "${LSOF_EXACT_CLOSED:-}" = 1 ]; then
      if [ -n "${LSOF_EXACT_CLOSED_HOOK:-}" ] && [ ! -e "${LSOF_EXACT_CLOSED_HOOK}.done" ]; then
        bash "$LSOF_EXACT_CLOSED_HOOK"
        : > "${LSOF_EXACT_CLOSED_HOOK}.done"
      fi
      exit 1
    fi
    cat "$LSOF_OPEN_FILE"
    ;;
  *) cat "$LSOF_OPEN_FILE" ;;
esac
exit 0
STUB
chmod +x "$BIN/lsof"

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/gh"

reset_lsof() {
  printf 'p1\nn/\n' > "$LSOF_CWD_FILE"
  printf 'p1\nn/dev/null\n' > "$LSOF_OPEN_FILE"
  : > "$LSOF_LOCK_FILE"
  : > "$LSOF_LOCK_CALLS"
  unset LSOF_LOCK_AFTER
}

new_fixture() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  ORIGIN="$CASE/origin.git"
  PRIMARY="$CASE/primary"
  WT="$CASE/worktree"
  CLAUDE_SESSIONS="$CASE/claude-sessions"
  CLAUDE_PROJECTS="$CASE/claude-projects"
  CODEX_LOCKS="$CASE/codex-locks"
  CODEX_STATE="$CASE/codex.sqlite"
  mkdir -p "$CASE" "$CLAUDE_SESSIONS" "$CLAUDE_PROJECTS" "$CODEX_LOCKS"
  git init --bare -q -b main "$ORIGIN"
  git clone -q "$ORIGIN" "$PRIMARY"
  git -C "$PRIMARY" config user.email test@example.com
  git -C "$PRIMARY" config user.name Test
  printf 'base\n' > "$PRIMARY/README.md"
  git -C "$PRIMARY" add README.md
  git -C "$PRIMARY" commit -qm base
  git -C "$PRIMARY" push -q origin main
  git -C "$PRIMARY" worktree add -q -b task "$WT" origin/main
  reset_lsof
}

age_worktree() {
  local hours=$1 target="${2:-$WT}" stamp gd
  stamp="$(date -v-"${hours}"H '+%Y%m%d%H%M.%S' 2>/dev/null ||
           date -d "${hours} hours ago" '+%Y%m%d%H%M.%S')"
  find -H "$target" -exec touch -t "$stamp" {} +
  gd="$(git -C "$target" rev-parse --absolute-git-dir)"
  [ ! -e "$gd/HEAD" ] || touch -t "$stamp" "$gd/HEAD"
  [ ! -e "$gd/index" ] || touch -t "$stamp" "$gd/index"
  [ ! -d "$gd/logs" ] || find "$gd/logs" -exec touch -t "$stamp" {} +
}

run_wj() {
  PATH="$BIN:$PATH" CC_WJ_CONFIG="$CASE/no-config" CC_WJ_LOG="$CASE/wj.log" \
    CC_WJ_STATE_DIR="$CASE/state" CC_WJ_CLAUDE_SESSIONS="$CLAUDE_SESSIONS" \
    CC_WJ_CLAUDE_PROJECTS="$CLAUDE_PROJECTS" CC_WJ_CODEX_LOCKS="$CODEX_LOCKS" \
    CC_WJ_CODEX_STATE_DB="$CODEX_STATE" CC_WJ_NOTIFY_MIN_GB=999999 \
    CODEX_THREAD_ID="${CODEX_THREAD_ID:-}" CLAUDE_CODE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}" \
    bash "$WJ" --repo "$PRIMARY" "$@"
}

make_codex_state() {
  sqlite3 "$CODEX_STATE" 'create table threads (id text primary key, cwd text not null, rollout_path text not null, updated_at integer not null default 0, archived integer not null default 0, archived_at integer);'
}

GNU_BIN="$TMP_ROOT/gnu-bin"
mkdir -p "$GNU_BIN"
cat > "$GNU_BIN/stat" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = -f ]; then
  printf '  File: "%s"\n' "$3"
  exit 1
fi
if [ "$1" = -c ] && [ "$2" = %Y ]; then
  printf '1234567890\n'
  exit 0
fi
exit 1
STUB
chmod +x "$GNU_BIN/stat"
mtime_fixture="$TMP_ROOT/mtime-fixture"
: > "$mtime_fixture"
portable_mtime="$(PATH="$GNU_BIN:$PATH" CC_WJ_CONFIG="$TMP_ROOT/no-config" bash -c \
  'source "$1"; _cc_wj_mtime_epoch "$2"' _ "$WJ" "$mtime_fixture" 2>/dev/null || true)"
check "GNU stat fallback returns only the numeric modification epoch" test "$portable_mtime" = 1234567890

# The policy belongs to cc-reaper and is two days even when no harness exports anything.
default_idle="$(CC_WJ_CONFIG="$TMP_ROOT/no-config" bash -c \
  'source "$1"; unset CC_WJ_IDLE_HOURS; _cc_wj_idle_hours' _ "$WJ" 2>/dev/null || true)"
check "default idle window is 48 hours" test "$default_idle" = 48
default_session_grace="$(CC_WJ_CONFIG="$TMP_ROOT/no-config" bash -c \
  'source "$1"; unset CC_WJ_SESSION_GRACE_HOURS; _cc_wj_session_grace_hours' _ "$WJ" 2>/dev/null || true)"
check "default recent-session grace is 48 hours" test "$default_session_grace" = 48
explicit_idle="$(CC_WJ_IDLE_HOURS=7 CC_WJ_CONFIG="$ROOT_DIR/config/worktree-janitor.conf" bash -c \
  'source "$1"; _cc_wj_idle_hours' _ "$WJ" 2>/dev/null || true)"
check "an explicit one-shot idle window overrides the installed policy" test "$explicit_idle" = 7

new_fixture no-linked-network
git -C "$PRIMARY" worktree remove "$WT"
git -C "$PRIMARY" remote set-url origin http://127.0.0.1:9/unreachable.git
out="$(run_wj 2>&1)"
case "$out" in
  *'could not be fetched'*) bad "a repository with no linked worktree is not fetched" ;;
  *) ok "a repository with no linked worktree is not fetched" ;;
esac

new_fixture landed-query
printf 'same result\n' > "$WT/result.txt"
git -C "$WT" add result.txt
git -C "$WT" commit -qm task-result
printf 'same result\n' > "$PRIMARY/result.txt"
git -C "$PRIMARY" add result.txt
git -C "$PRIMARY" commit -qm squash-result
git -C "$PRIMARY" push -q origin main
query="$(PATH="$BIN:$PATH" CC_WJ_CONFIG="$CASE/no-config" bash "$WJ" --landed "$WT")"
check "the shared landed query recognizes squash-equivalent content" test "$query" = content

new_fixture default-window
age_worktree 24
out="$(run_wj --apply 2>&1)"
check "a landed worktree younger than 48 hours is kept" test -d "$WT"
case "$out" in
  *'KEEP(recent-activity)'*) ok "the report names the 48-hour recent-activity gate" ;;
  *) bad "the report names the 48-hour recent-activity gate" ;;
esac

new_fixture old-window
age_worktree 72
run_wj --apply >/dev/null 2>&1
check "a landed finished worktree older than 48 hours is removed" test ! -d "$WT"

new_fixture claude-live
age_worktree 72
sid=11111111-2222-4333-8444-555555555555
python3 -c 'import time; time.sleep(120)' "$sid" </dev/null >/dev/null 2>&1 & claude_pid=$!
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$claude_pid" "$sid" "$WT" > "$CLAUDE_SESSIONS/$claude_pid.json"
mkdir -p "$CLAUDE_PROJECTS/project"
: > "$CLAUDE_PROJECTS/project/$sid.jsonl"
out="$(run_wj --apply 2>&1)"
check "a verified live Claude cwd claim keeps its worktree" test -d "$WT"
case "$out" in *'active Claude'*) ok "the Claude keep reason is visible" ;; *) bad "the Claude keep reason is visible" ;; esac
kill "$claude_pid" 2>/dev/null; wait "$claude_pid" 2>/dev/null || true

new_fixture claude-stale
age_worktree 72
sid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$$" "$sid" "$WT" > "$CLAUDE_SESSIONS/$$.json"
run_wj --apply >/dev/null 2>&1
check "a reused Claude PID record does not pin a worktree" test ! -d "$WT"

new_fixture claude-historical-tool-workdir
age_worktree 72
sid=abababab-bbbb-4ccc-8ddd-eeeeeeeeeeee
python3 -c 'import time; time.sleep(120)' "$sid" </dev/null >/dev/null 2>&1 & claude_pid=$!
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$claude_pid" "$sid" "$PRIMARY" > "$CLAUDE_SESSIONS/$claude_pid.json"
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"workdir":"%s"}}]}}\n' "$WT" > "$transcript"
printf '%s\n' \
  '{"type":"user","message":{"content":"next task"}}' \
  '{"type":"user","message":{"content":"another task"}}' \
  '{"type":"user","message":{"content":"current task"}}' >> "$transcript"
run_wj --apply >/dev/null 2>&1
check "a historical Claude tool call outside the current two user turns does not pin a worktree" test ! -d "$WT"
kill "$claude_pid" 2>/dev/null; wait "$claude_pid" 2>/dev/null || true

new_fixture claude-unlanded-skips-tool-transcript
printf 'unlanded\n' > "$WT/unlanded.txt"
git -C "$WT" add unlanded.txt
git -C "$WT" commit -qm unlanded
age_worktree 72
sid=acacacac-bbbb-4ccc-8ddd-eeeeeeeeeeee
python3 -c 'import time; time.sleep(120)' "$sid" </dev/null >/dev/null 2>&1 & claude_pid=$!
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}\n' "$claude_pid" "$sid" "$PRIMARY" > "$CLAUDE_SESSIONS/$claude_pid.json"
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
printf '{"path":"%s"\n' "$WT" > "$transcript"
rc=0; out="$(run_wj --apply 2>&1)" || rc=$?
check "an unlanded worktree does not parse active structured transcripts" test "$rc" -eq 0
case "$out" in *'KEEP(unlanded)'*) ok "the cheaper unlanded gate decides before active tool matching" ;; *) bad "the cheaper unlanded gate decides before active tool matching" ;; esac
check "the unlanded worktree remains present" test -d "$WT"
kill "$claude_pid" 2>/dev/null; wait "$claude_pid" 2>/dev/null || true

new_fixture codex-live
age_worktree 72
tid=22222222-3333-7444-8555-666666666666
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/rollout.jsonl"; : > "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$WT','$rollout');"
out="$(run_wj --apply 2>&1)"
check "an open Codex writer claim keeps its worktree" test -d "$WT"
case "$out" in *'active Codex'*) ok "the Codex keep reason is visible" ;; *) bad "the Codex keep reason is visible" ;; esac

new_fixture codex-new-lock-state-race
age_worktree 72
tid=23232323-3333-7444-8555-666666666666
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/racing-rollout.jsonl"; : > "$rollout"
(
  sleep 0.2
  sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$WT','$rollout');"
) &
out="$(run_wj --apply 2>&1)"
check "a fresh Codex lock waits for its state row and keeps the worktree" test -d "$WT"
case "$out" in *'active Codex'*) ok "the fresh-lock retry preserves the mapped keep reason" ;; *) bad "the fresh-lock retry preserves the mapped keep reason" ;; esac

new_fixture codex-stale
age_worktree 72
tid=33333333-4444-7555-8666-777777777777
: > "$CODEX_LOCKS/$tid.lock"
make_codex_state
rollout="$CASE/rollout.jsonl"; : > "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$WT','$rollout');"
run_wj --apply >/dev/null 2>&1
check "an unopened Codex lock file does not pin a worktree" test ! -d "$WT"

new_fixture codex-archived-recent
age_worktree 72
tid=34343434-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/archived-rollout.jsonl"; printf '{"cwd":"%s"}\n' "$WT" > "$rollout"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$WT','$rollout',$((now - 3600)),1,$now);"
out="$(run_wj --apply 2>&1)"
check "a freshly archived Codex task keeps an otherwise old worktree" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$tid"*) ok "the inventory exposes the archived-session lease" ;; *) bad "the inventory exposes the archived-session lease" ;; esac
claims="$(run_wj --claims "$tid" 2>&1)"
case "$claims" in *'RECENT'*'Codex'*"$tid"*'archived'*'remaining='*) ok "--claims exposes archived status and remaining grace" ;; *) bad "--claims exposes archived status and remaining grace" ;; esac
check "--claims can filter one task without inventory noise" test "$(printf '%s\n' "$claims" | wc -l | tr -d ' ')" -eq 2

new_fixture codex-archived-tool-workdir
age_worktree 72
tid=34444444-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/archived-tool-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish task"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}}" > "$rollout"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$PRIMARY','$rollout',$((now - 60)),1,$now);"
out="$(run_wj --apply 2>&1)"
check "a recent archived Codex tool workdir keeps an old worktree" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$tid"*'structured-tool-call'*) ok "the inventory exposes the derived Codex lease" ;; *) bad "the inventory exposes the derived Codex lease" ;; esac
claims="$(run_wj --claims "$WT" 2>&1)"
wt_claim_path="$(cd -P "$WT" && pwd)"
case "$claims" in
  *'RECENT_TOOL'*'Codex'*"$tid"*"path=$wt_claim_path"*) ok "--claims by path exposes the derived Codex lease" ;;
  *) bad "--claims by path exposes the derived Codex lease"; printf '# claims output: %s\n' "$claims" ;;
esac

new_fixture codex-archived-missing-cwd-tool-workdir
age_worktree 72
tid=34445444-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/archived-missing-cwd-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish task"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}}" > "$rollout"
missing_cwd="$CASE/deleted-codex-cwd"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$missing_cwd','$rollout',$((now - 60)),1,$now);"
out="$(run_wj --apply 2>&1)"
check "a recent archived Codex rollout survives a missing recorded cwd" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$tid"*'structured-tool-call'*) ok "the missing-cwd Codex lease remains observable" ;; *) bad "the missing-cwd Codex lease remains observable" ;; esac

new_fixture codex-large-tail-record
age_worktree 72
tid=34454545-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/large-tail-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish task"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}}" > "$rollout"
printf '{"type":"event_msg","payload":{"message":"' >> "$rollout"
head -c 2097152 /dev/zero | tr '\0' x >> "$rollout"
printf '"}}\n' >> "$rollout"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$PRIMARY','$rollout',$now,1,$now);"
run_wj --apply >/dev/null 2>&1
check "a multi-megabyte tail record does not hide a recent Codex tool claim" test -d "$WT"

new_fixture codex-unrelated-malformed-recent
age_worktree 72
tid=34545454-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/unrelated-malformed-rollout.jsonl"
printf '{not-json\n' > "$rollout"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$PRIMARY','$rollout',$now,1,$now);"
run_wj --apply >/dev/null 2>&1
check "an unrelated malformed recent transcript does not blind an old worktree" test ! -d "$WT"

new_fixture codex-matching-malformed-recent
age_worktree 72
tid=34646464-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/matching-malformed-rollout.jsonl"
printf '{"path":"%s"\n' "$WT" > "$rollout"
now="$(date +%s)"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$PRIMARY','$rollout',$now,1,$now);"
rc=0; run_wj --apply >/dev/null 2>&1 || rc=$?
check "a malformed recent transcript naming the target fails closed" test -d "$WT"
check "a malformed matching transcript fails the run" test "$rc" -ne 0

new_fixture codex-archive-expired
age_worktree 72
tid=35353535-4444-7555-8666-777777777777
make_codex_state
rollout="$CASE/expired-rollout.jsonl"; printf '{"cwd":"%s"}\n' "$WT" > "$rollout"
old=$(( $(date +%s) - 73 * 3600 ))
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path,updated_at,archived,archived_at) values ('$tid','$WT','$rollout',$old,1,$old);"
run_wj --apply >/dev/null 2>&1
check "an expired Codex archive lease does not pin the worktree" test ! -d "$WT"

new_fixture claude-recent-inactive
age_worktree 72
sid=36363636-4444-4555-8666-777777777777
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' "$sid" "$WT" > "$transcript"
out="$(run_wj --apply 2>&1)"
check "recent inactive Claude transcript activity keeps an old worktree" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$sid"*) ok "the inventory exposes the Claude session lease" ;; *) bad "the inventory exposes the Claude session lease" ;; esac

new_fixture claude-recent-tool-workdir
age_worktree 72
sid=36464646-4444-4555-8666-777777777777
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
printf '%s\n' \
  "{\"type\":\"user\",\"sessionId\":\"$sid\",\"cwd\":\"$PRIMARY\",\"message\":{\"content\":\"finish task\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"$sid\",\"cwd\":\"$PRIMARY\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"input\":{\"workdir\":\"$WT\"}}]}}" > "$transcript"
out="$(run_wj --apply 2>&1)"
check "recent inactive Claude tool workdir keeps an old worktree" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$sid"*'structured-tool-call'*) ok "the inventory exposes the derived Claude lease" ;; *) bad "the inventory exposes the derived Claude lease" ;; esac

new_fixture claude-recent-missing-cwd-tool-workdir
age_worktree 72
sid=36465646-4444-4555-8666-777777777777
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
missing_cwd="$CASE/deleted-claude-cwd"
printf '%s\n' \
  "{\"type\":\"user\",\"sessionId\":\"$sid\",\"cwd\":\"$missing_cwd\",\"message\":{\"content\":\"finish task\"}}" \
  "{\"type\":\"assistant\",\"sessionId\":\"$sid\",\"cwd\":\"$missing_cwd\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"input\":{\"workdir\":\"$WT\"}}]}}" > "$transcript"
out="$(run_wj --apply 2>&1)"
check "a recent Claude transcript survives a missing recorded cwd" test -d "$WT"
case "$out" in *'KEEP(recent-session)'*"$sid"*'structured-tool-call'*) ok "the missing-cwd Claude lease remains observable" ;; *) bad "the missing-cwd Claude lease remains observable" ;; esac

new_fixture claude-recent-expired
age_worktree 72
sid=37373737-4444-4555-8666-777777777777
mkdir -p "$CLAUDE_PROJECTS/project"
transcript="$CLAUDE_PROJECTS/project/$sid.jsonl"
printf '{"type":"system","sessionId":"%s","cwd":"%s"}\n' "$sid" "$WT" > "$transcript"
stamp="$(date -v-73H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '73 hours ago' '+%Y%m%d%H%M.%S')"
touch -t "$stamp" "$transcript"
run_wj --apply >/dev/null 2>&1
check "an expired Claude transcript lease does not pin the worktree" test ! -d "$WT"

new_fixture claims-read-only
age_worktree 72
run_wj --claims --apply >/dev/null 2>&1
check "--claims stays read-only even when combined with --apply" test -d "$WT"

new_fixture malformed-session-grace
age_worktree 72
rc=0
CC_WJ_SESSION_GRACE_HOURS=tomorrow run_wj --apply >/dev/null 2>&1 || rc=$?
check "a malformed session grace refuses the run" test "$rc" -ne 0
check "a malformed session grace removes nothing" test -d "$WT"

new_fixture codex-tool-workdir
age_worktree 72
tid=44444444-5555-7666-8777-888888888888
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/rollout.jsonl"
printf '{"type":"response_item","payload":{"type":"custom_tool_call","input":"workdir=%s"}}\n' "$WT" > "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$PRIMARY','$rollout');"
out="$(run_wj --apply 2>&1)"
check "an active Codex structured tool workdir keeps its worktree" test -d "$WT"
case "$out" in *'tool call'*) ok "the structured-tool keep reason is visible" ;; *) bad "the structured-tool keep reason is visible" ;; esac

new_fixture codex-self-tool-workdir
age_worktree 72
tid=44555555-5555-7666-8777-888888888888
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/rollout.jsonl"
printf '{"type":"response_item","payload":{"type":"custom_tool_call","input":"workdir=%s"}}\n' "$WT" > "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$PRIMARY','$rollout');"
CODEX_THREAD_ID="$tid" run_wj --apply >/dev/null 2>&1
check "the cleanup task's own tool mention does not pin another worktree" test ! -d "$WT"

new_fixture codex-historical-tool-workdir
age_worktree 72
tid=45454545-5555-7666-8777-888888888888
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/rollout.jsonl"
printf '{"type":"response_item","payload":{"type":"custom_tool_call","input":"workdir=%s"}}\n' "$WT" > "$rollout"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"next task"}}' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"another task"}}' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"current task"}}' >> "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$PRIMARY','$rollout');"
run_wj --apply >/dev/null 2>&1
check "a historical Codex tool call outside the current two user turns does not pin a worktree" test ! -d "$WT"

new_fixture codex-archive-during-scan
age_worktree 72
tid=46464646-5555-7666-8777-888888888888
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
old_rollout="$CASE/moving-rollout.jsonl"
new_rollout="$CASE/archived-rollout.jsonl"
printf '{"path":"%s"\n' "$WT" > "$old_rollout"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}}" > "$new_rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$PRIMARY','$old_rollout');"
OTHER="$CASE/unrelated-worktree"
git -C "$PRIMARY" worktree add -q -b unrelated "$OTHER" origin/main
age_worktree 72 "$OTHER"
archive_hook="$CASE/archive-task.sh"
cat > "$archive_hook" <<HOOK
#!/usr/bin/env bash
sqlite3 "$CODEX_STATE" "update threads set rollout_path='$new_rollout', updated_at=strftime('%s','now'), archived=1, archived_at=strftime('%s','now') where id='$tid';"
HOOK
chmod +x "$archive_hook"
rc=0; out="$(LSOF_EXACT_CLOSED=1 LSOF_EXACT_CLOSED_HOOK="$archive_hook" run_wj --apply 2>&1)" || rc=$?
check "a Codex archive race keeps the worktree named by the archived rollout" test -d "$WT"
check "a Codex archive race does not claim an unrelated worktree" test ! -d "$OTHER"
check "a released writer lock does not poison the whole run" test "$rc" -eq 0
case "$out" in *'KEEP(recent-session)'*"$tid"*) ok "the archive-race lease is visible as recent-session evidence" ;; *) bad "the archive-race lease is visible as recent-session evidence"; printf '# output: %s\n' "$out" ;; esac

new_fixture transcript-snapshot-cache
cache_transcript="$CASE/cache-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"older"}}' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"current"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}}" > "$cache_transcript"
printf '{"type":"event_msg","payload":{"message":"' >> "$cache_transcript"
head -c 2097152 /dev/zero | tr '\0' x >> "$cache_transcript"
printf '"}}\n' >> "$cache_transcript"
cache_dir="$CASE/transcript-cache"; cache_trace="$CASE/cache-trace"; query_trace="$CASE/query-trace"
cache_other="$CASE/not-this-worktree"; mkdir -p "$cache_other"
cache_result="$(CC_WJ_TRANSCRIPT_CACHE_DIR="$cache_dir" CC_WJ_TRANSCRIPT_CACHE_TRACE="$cache_trace" \
  CC_WJ_TRANSCRIPT_QUERY_TRACE="$query_trace" \
  bash -c 'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; a=$?; _cc_wj_transcript_claims_path Codex "$2" "$4"; b=$?; printf "%s %s\n" "$a" "$b"' \
  _ "$WJ" "$cache_transcript" "$WT" "$cache_other")"
check "the cached transcript snapshot preserves matching and non-matching results" test "$cache_result" = "0 1"
cache_builds="$(wc -l < "$cache_trace" | tr -d ' ')"
check "one activity snapshot indexes a large transcript once across candidate paths" test "$cache_builds" -eq 1
query_processes="$(wc -l < "$query_trace" | tr -d ' ')"
check "one activity snapshot starts Python once across candidate paths" test "$query_processes" -eq 1

malformed_cache_transcript="$CASE/malformed-cache-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"current"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$WT\"}" > "$malformed_cache_transcript"
malformed_cache_dir="$CASE/malformed-transcript-cache"
malformed_query_trace="$CASE/malformed-query-trace"
malformed_cache_result="$(CC_WJ_TRANSCRIPT_CACHE_DIR="$malformed_cache_dir" \
  CC_WJ_TRANSCRIPT_QUERY_TRACE="$malformed_query_trace" \
  bash -c 'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; a=$?; _cc_wj_transcript_claims_path Codex "$2" "$4"; b=$?; printf "%s %s\n" "$a" "$b"' \
  _ "$WJ" "$malformed_cache_transcript" "$WT" "$cache_other")"
check "a malformed canonical tool record stays fail closed for every candidate" test "$malformed_cache_result" = "2 2"
malformed_query_processes="$(wc -l < "$malformed_query_trace" | tr -d ' ')"
check "malformed relevant evidence bypasses the shared fast path" test "$malformed_query_processes" -eq 2

escaped_target="$CASE/測試-worktree"
escaped_transcript="$CASE/escaped-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish task"}}' \
  "{\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"input\":\"workdir=$CASE/\\u6e2c\\u8a66-worktree\"}}" > "$escaped_transcript"
escaped_cache_dir="$CASE/escaped-transcript-cache"
escaped_query_trace="$CASE/escaped-query-trace"
escaped_result="$(CC_WJ_CONFIG="$CASE/no-config" CC_WJ_TRANSCRIPT_CACHE_DIR="$escaped_cache_dir" \
  CC_WJ_TRANSCRIPT_QUERY_TRACE="$escaped_query_trace" bash -c \
  'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; a=$?; _cc_wj_transcript_claims_path Codex "$2" "$4"; b=$?; printf "%s %s\n" "$a" "$b"' \
  _ "$WJ" "$escaped_transcript" "$cache_other" "$escaped_target")"
check "JSON-escaped Unicode tool paths survive the shared fast path" test "$escaped_result" = "1 0"
escaped_query_processes="$(wc -l < "$escaped_query_trace" | tr -d ' ')"
check "the normalized Unicode claim reuses one interpreter" test "$escaped_query_processes" -eq 1

byte_target="$CASE/"$'\377'"-worktree"
byte_transcript="$CASE/non-utf8-rollout.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":"finish task"}}' \
  '{"type":"response_item","payload":{"type":"custom_tool_call","input":"workdir='"$CASE"'/\udcff-worktree"}}' > "$byte_transcript"
byte_cache_dir="$CASE/non-utf8-transcript-cache"
byte_result="$(LC_ALL=C CC_WJ_CONFIG="$CASE/no-config" CC_WJ_TRANSCRIPT_CACHE_DIR="$byte_cache_dir" \
  bash -c 'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; a=$?; _cc_wj_transcript_claims_path Codex "$2" "$4"; b=$?; printf "%s %s\n" "$a" "$b"' \
  _ "$WJ" "$byte_transcript" "$cache_other" "$byte_target")"
check "a surrogate-escaped filesystem byte survives the shared fast path" test "$byte_result" = "1 0"

mixed_target="$CASE/café-worktree"
mixed_transcript="$CASE/mixed-escaped-rollout.jsonl"
python3 - "$mixed_transcript" "$CASE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
user = {"type": "response_item", "payload": {"type": "message", "role": "user", "content": "finish task"}}
tool = {"type": "response_item", "payload": {"type": "custom_tool_call", "input": f"workdir={sys.argv[2]}/café-worktree"}}
encoded_tool = json.dumps(tool).replace("/", r"\/").replace(r"\u00e9", r"\u00E9")
path.write_text(json.dumps(user) + "\n" + encoded_tool + "\n")
PY
mixed_result="$(CC_WJ_CONFIG="$CASE/no-config" bash -c \
  'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; printf "%s\n" "$?"' \
  _ "$WJ" "$mixed_transcript" "$mixed_target")"
check "mixed solidus and uppercase Unicode escapes retain a tool claim" test "$mixed_result" = 0

nested_target="$CASE/café-nested-worktree"
nested_transcript="$CASE/nested-escaped-rollout.jsonl"
python3 - "$nested_transcript" "$nested_target" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
user = {"type": "response_item", "payload": {"type": "message", "role": "user", "content": "finish task"}}
nested = json.dumps({"workdir": sys.argv[2]}).replace("/", r"\/").replace(r"\u00e9", r"\u00E9")
tool = {"type": "response_item", "payload": {"type": "custom_tool_call", "input": nested}}
path.write_text(json.dumps(user) + "\n" + json.dumps(tool) + "\n")
PY
nested_result="$(CC_WJ_CONFIG="$CASE/no-config" bash -c \
  'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"; printf "%s\n" "$?"' \
  _ "$WJ" "$nested_transcript" "$nested_target")"
check "nested JSON Codex arguments retain an escaped tool path claim" test "$nested_result" = 0

persistent_dir="$CASE/persistent-transcript-index"; persistent_trace="$CASE/persistent-trace"
for generation in one two; do
  CC_WJ_TRANSCRIPT_CACHE_DIR="$CASE/cache-$generation" \
    CC_WJ_TRANSCRIPT_INDEX_DIR="$persistent_dir" \
    CC_WJ_TRANSCRIPT_CACHE_TRACE="$persistent_trace" \
    bash -c 'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"' \
    _ "$WJ" "$cache_transcript" "$WT" >/dev/null
done
persistent_builds="$(wc -l < "$persistent_trace" | tr -d ' ')"
check "an unchanged transcript reuses its persistent offset index across snapshots" test "$persistent_builds" -eq 1
if grep -R -F -q -- "$WT" "$persistent_dir"; then
  bad "the persistent transcript index contains no normalized tool input"
else
  ok "the persistent transcript index contains no normalized tool input"
fi
printf '%s\n' '{"type":"event_msg","payload":{"message":"changed"}}' >> "$cache_transcript"
CC_WJ_TRANSCRIPT_CACHE_DIR="$CASE/cache-three" \
  CC_WJ_TRANSCRIPT_INDEX_DIR="$persistent_dir" \
  CC_WJ_TRANSCRIPT_CACHE_TRACE="$persistent_trace" \
  bash -c 'source "$1"; _cc_wj_transcript_claims_path Codex "$2" "$3"' \
  _ "$WJ" "$cache_transcript" "$WT" >/dev/null
persistent_builds="$(wc -l < "$persistent_trace" | tr -d ' ')"
check "a changed transcript rebuilds the persistent evidence" test "$persistent_builds" -eq 2

new_fixture codex-unmappable
age_worktree 72
tid=55555555-6666-7777-8888-999999999999
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rc=0; out="$(run_wj --apply 2>&1)" || rc=$?
check "an unmappable live Codex claim removes nothing" test -d "$WT"
check "an unmappable live Codex claim fails the run" test "$rc" -ne 0
case "$out" in *'could not be mapped'*) ok "the failed mapping is named" ;; *) bad "the failed mapping is named" ;; esac

new_fixture codex-race
age_worktree 72
tid=66666666-7777-7888-8999-aaaaaaaaaaaa
lock="$CODEX_LOCKS/$tid.lock"; : > "$lock"
printf 'p9\nn%s\n' "$lock" > "$LSOF_LOCK_FILE"
make_codex_state
rollout="$CASE/rollout.jsonl"; : > "$rollout"
sqlite3 "$CODEX_STATE" "insert into threads(id,cwd,rollout_path) values ('$tid','$WT','$rollout');"
export LSOF_LOCK_AFTER=2
out="$(run_wj --apply 2>&1)"
unset LSOF_LOCK_AFTER
check "a Codex claim appearing before removal wins the race" test -d "$WT"
case "$out" in *'appeared before removal'*) ok "the race keep reason is visible" ;; *) bad "the race keep reason is visible" ;; esac

new_fixture scheduled-report
age_worktree 72
run_wj --scheduled >/dev/null 2>&1
check "scheduled mode reports without its cc-reaper opt-in" test -d "$WT"

new_fixture scheduled-apply
age_worktree 72
CC_WJ_SCHEDULE_APPLY=1 run_wj --scheduled >/dev/null 2>&1
check "scheduled mode applies when the cc-reaper policy opts in" test ! -d "$WT"

new_fixture interrupted-temp-cleanup
interrupt_tmp="$CASE/tmp"; interrupt_marker="$CASE/lsof-started"
mkdir -p "$interrupt_tmp"
env PATH="$BIN:$PATH" TMPDIR="$interrupt_tmp" LSOF_SLEEP_MARKER="$interrupt_marker" \
  LSOF_SLEEP_SECONDS=2 CC_WJ_CONFIG="$CASE/no-config" CC_WJ_LOG="$CASE/wj.log" \
  CC_WJ_STATE_DIR="$CASE/state" CC_WJ_CLAUDE_SESSIONS="$CLAUDE_SESSIONS" \
  CC_WJ_CLAUDE_PROJECTS="$CLAUDE_PROJECTS" CC_WJ_CODEX_LOCKS="$CODEX_LOCKS" \
  CC_WJ_CODEX_STATE_DB="$CODEX_STATE" CC_WJ_NOTIFY_MIN_GB=999999 \
  bash "$WJ" --repo "$PRIMARY" >/dev/null 2>&1 &
interrupt_pid=$!
for _ in 1 2 3 4 5; do
  [ -e "$interrupt_marker" ] && break
  sleep 1
done
kill -TERM "$interrupt_pid" 2>/dev/null || true
wait "$interrupt_pid" 2>/dev/null || true
interrupt_dirs="$(find "$interrupt_tmp" -maxdepth 1 -type d -name 'cc-wj.*' | wc -l | tr -d ' ')"
check "an interrupted run removes its private transcript projection directory" test "$interrupt_dirs" -eq 0

new_fixture harness-discovery
age_worktree 72
out="$(PATH="$BIN:$PATH" CC_WJ_CONFIG="$CASE/no-config" CC_WJ_ROOT="$CASE/no-source-root" \
  CC_WJ_HARNESS_ROOTS="$CASE" CC_WJ_CLAUDE_SESSIONS="$CASE/no-claude" \
  CC_WJ_CODEX_LOCKS="$CASE/no-codex" CC_WJ_LOG="$CASE/wj.log" \
  CC_WJ_STATE_DIR="$CASE/state" bash "$WJ" 2>&1)"
WT_PHYS="$(cd -P "$WT" && pwd)"
case "$out" in
  *"WORKTREE  $WT_PHYS"*) ok "a harness-owned repository outside source roots is discovered" ;;
  *) bad "a harness-owned repository outside source roots is discovered"; printf '%s\n' "$out" ;;
esac
count="$(printf '%s\n' "$out" | grep -cF "WORKTREE  $WT_PHYS")"
check "harness discovery deduplicates linked worktrees by git common directory" test "$count" -eq 1

if [ "$failures" -gt 0 ]; then
  printf '%d test failure(s)\n' "$failures"
  exit 1
fi
printf 'worktree-active-sessions: all tests passed\n'
