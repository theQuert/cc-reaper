#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0

check() { local name=$1; shift; if "$@"; then echo "ok - $name"; else echo "not ok - $name"; failures=$((failures+1)); fi; }

SETTINGS="$TMP/settings.json"
cat > "$SETTINGS" <<'JSON'
{
  "env": {"WORKTREE_IDLE_HOURS": "6", "WORKTREE_DRY_RUN": "1", "MAX_THINKING_TOKENS": "10000"},
  "hooks": {
    "SessionEnd": [
      {"hooks": [
        {"type":"command","command":"\"$HOME\"/.claude/hooks/stop-cleanup-orphans.sh","timeout":15},
        {"type":"command","command":"\"$HOME\"/.claude/hooks/reclaim-worktrees.sh --background","timeout":10},
        {"type":"command","command":"\"$HOME\"/.claude/hooks/reclaim-inventory.sh --session","timeout":10},
        {"type":"command","command":"keep-me","timeout":10}
      ]}
    ]
  }
}
JSON

python3 "$ROOT_DIR/integrations/install-session-hook.py" --harness claude --file "$SETTINGS" >/dev/null
check "legacy Claude worktree hooks are removed" bash -c '! grep -q "reclaim-worktrees\|reclaim-inventory" "$1"' _ "$SETTINGS"
check "the shared Claude trigger is installed" grep -q 'worktree-session-end.sh claude' "$SETTINGS"
check "the Claude process hook is owned by cc-reaper" grep -q '\.cc-reaper/stop-cleanup-orphans.sh' "$SETTINGS"
check "the legacy Claude process-hook path is removed" bash -c '! grep -q "\.claude/hooks/stop-cleanup-orphans.sh" "$1"' _ "$SETTINGS"
check "a misplaced process hook is normalized to Stop" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any("stop-cleanup-orphans" in h.get("command", "") for g in d["hooks"]["Stop"] for h in g.get("hooks", [])); assert not any("stop-cleanup-orphans" in h.get("command", "") for g in d["hooks"]["SessionEnd"] for h in g.get("hooks", []))' "$SETTINGS"
check "unrelated hooks survive" grep -q 'keep-me' "$SETTINGS"
check "the worktree policy leaves Claude settings" bash -c '! grep -q "WORKTREE_IDLE_HOURS\|WORKTREE_DRY_RUN" "$1"' _ "$SETTINGS"
check "unrelated settings survive" grep -q 'MAX_THINKING_TOKENS' "$SETTINGS"

before="$(shasum -a 256 "$SETTINGS")"
python3 "$ROOT_DIR/integrations/install-session-hook.py" --harness claude --file "$SETTINGS" >/dev/null
after="$(shasum -a 256 "$SETTINGS")"
check "hook installation is idempotent" test "$before" = "$after"

CODEX="$TMP/repo/.codex/hooks.json"
python3 "$ROOT_DIR/integrations/install-session-hook.py" --harness codex --file "$CODEX" >/dev/null
check "a Codex hook file can be created" grep -q 'worktree-session-end.sh codex' "$CODEX"
check "the generated Codex hook uses shared process cleanup" grep -q '\.cc-reaper/stop-cleanup-orphans.sh' "$CODEX"
check "the generated Codex hook file is valid JSON" python3 -m json.tool "$CODEX" >/dev/null

MANAGED_DIR="$TMP/managed-dotfiles"
mkdir -p "$MANAGED_DIR" "$TMP/symlinked/.claude"
MANAGED_SETTINGS="$MANAGED_DIR/settings.json"
printf '{"hooks":{}}\n' > "$MANAGED_SETTINGS"
SYMLINKED_SETTINGS="$TMP/symlinked/.claude/settings.json"
ln -s ../../managed-dotfiles/settings.json "$SYMLINKED_SETTINGS"
python3 "$ROOT_DIR/integrations/install-session-hook.py" --harness claude --file "$SYMLINKED_SETTINGS" >/dev/null
check "a managed settings symlink is preserved" test -L "$SYMLINKED_SETTINGS"
check "the symlink target receives the shared hook" grep -q 'worktree-session-end.sh claude' "$MANAGED_SETTINGS"
check "the preserved settings symlink remains readable" python3 -m json.tool "$SYMLINKED_SETTINGS" >/dev/null

BROKEN_SETTINGS="$TMP/symlinked/.claude/broken.json"
ln -s ../../managed-dotfiles/missing.json "$BROKEN_SETTINGS"
rc=0
python3 "$ROOT_DIR/integrations/install-session-hook.py" --harness claude --file "$BROKEN_SETTINGS" >/dev/null 2>&1 || rc=$?
check "a broken settings symlink is refused" test "$rc" -ne 0
check "a refused broken settings symlink is preserved" test -L "$BROKEN_SETTINGS"

# ─── Interpreter-started hook commands (stima-api#9010) ───────────────────────
# A script started through its #! line leaks kernel memory on macOS 26 on every start,
# so the commands written for the hosts name the interpreter. An entry in either form is
# recognised by its script path, and a by-path one is upgraded in place.
INSTALLER="$ROOT_DIR/integrations/install-session-hook.py"
WANT_END='bash "$HOME"/.cc-reaper/worktree-session-end.sh'
WANT_STOP='/bin/bash "$HOME"/.cc-reaper/stop-cleanup-orphans.sh'

# count_entries <file> <event> <script-substring>: entries of that event holding the script
count_entries() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for g in d["hooks"].get(sys.argv[2],[]) for h in g.get("hooks",[]) if sys.argv[3] in h.get("command","")))' "$@"
}
# commands <file> <event> <script-substring>: the matching commands, one per line
commands() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print("\n".join(h["command"] for g in d["hooks"].get(sys.argv[2],[]) for h in g.get("hooks",[]) if sys.argv[3] in h.get("command","")))' "$@"
}

for harness in claude codex; do
  # (c) an empty file gets the new forms
  F="$TMP/empty-$harness.json"
  printf '{}\n' > "$F"
  python3 "$INSTALLER" --harness "$harness" --file "$F" >/dev/null
  check "$harness: an empty file gets the interpreter SessionEnd command" test "$(commands "$F" SessionEnd worktree-session-end.sh)" = "$WANT_END $harness"
  check "$harness: an empty file gets the interpreter Stop command" test "$(commands "$F" Stop stop-cleanup-orphans.sh)" = "$WANT_STOP"

  # (a) the new form is already there: no change, one entry
  F="$TMP/new-$harness.json"
  cat > "$F" <<JSON
{"hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"/bin/bash \"\$HOME\"/.cc-reaper/stop-cleanup-orphans.sh","timeout":15}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"bash \"\$HOME\"/.cc-reaper/worktree-session-end.sh $harness","timeout":10}]}]}}
JSON
  before="$(shasum -a 256 "$F")"
  out="$(python3 "$INSTALLER" --harness "$harness" --file "$F")"
  check "$harness: the interpreter forms are reported as already configured" bash -c 'case "$1" in *"already configured"*) exit 0;; esac; exit 1' _ "$out"
  check "$harness: the interpreter forms leave the file byte-identical" test "$before" = "$(shasum -a 256 "$F")"
  check "$harness: the interpreter SessionEnd form stays one entry" test "$(count_entries "$F" SessionEnd worktree-session-end.sh)" = 1
  check "$harness: the interpreter Stop form stays one entry" test "$(count_entries "$F" Stop stop-cleanup-orphans.sh)" = 1

  # (b) the by-path form is rewritten in place, never doubled
  F="$TMP/old-$harness.json"
  cat > "$F" <<JSON
{"hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"\"\$HOME\"/.cc-reaper/stop-cleanup-orphans.sh","timeout":15}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"\"\$HOME\"/.cc-reaper/worktree-session-end.sh $harness","timeout":7},{"type":"command","command":"keep-me"}]}]}}
JSON
  python3 "$INSTALLER" --harness "$harness" --file "$F" >/dev/null
  check "$harness: a by-path SessionEnd entry is rewritten to the interpreter form" test "$(commands "$F" SessionEnd worktree-session-end.sh)" = "$WANT_END $harness"
  check "$harness: a by-path Stop entry is rewritten to the interpreter form" test "$(commands "$F" Stop stop-cleanup-orphans.sh)" = "$WANT_STOP"
  check "$harness: the rewritten SessionEnd entry keeps its timeout" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"]==7' "$F"
  check "$harness: the rewrite keeps unrelated hooks" grep -q 'keep-me' "$F"
  before="$(shasum -a 256 "$F")"
  python3 "$INSTALLER" --harness "$harness" --file "$F" >/dev/null
  check "$harness: a second run after the rewrite changes nothing" test "$before" = "$(shasum -a 256 "$F")"

  # both forms side by side collapse to one interpreter entry
  F="$TMP/both-$harness.json"
  cat > "$F" <<JSON
{"hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"/bin/bash \"\$HOME\"/.cc-reaper/stop-cleanup-orphans.sh"},{"type":"command","command":"\"\$HOME\"/.cc-reaper/stop-cleanup-orphans.sh"}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"bash \"\$HOME\"/.cc-reaper/worktree-session-end.sh $harness"},{"type":"command","command":"\"\$HOME\"/.cc-reaper/worktree-session-end.sh $harness"}]}]}}
JSON
  python3 "$INSTALLER" --harness "$harness" --file "$F" >/dev/null
  check "$harness: duplicate SessionEnd entries collapse to one" test "$(count_entries "$F" SessionEnd worktree-session-end.sh)" = 1
  check "$harness: duplicate Stop entries collapse to one" test "$(count_entries "$F" Stop stop-cleanup-orphans.sh)" = 1
done

# the other harness's entry is not this harness's entry
F="$TMP/other-harness.json"
cat > "$F" <<JSON
{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"bash \"\$HOME\"/.cc-reaper/worktree-session-end.sh codex"}]}]}}
JSON
python3 "$INSTALLER" --harness claude --file "$F" >/dev/null
check "an entry for another harness is kept beside the new one" test "$(count_entries "$F" SessionEnd worktree-session-end.sh)" = 2

# The SessionEnd entrypoint starts the janitor through its interpreter, never its #! line.
# The stub's #! names an interpreter that does not exist, so only `bash <path>` can run it.
H="$TMP/session-home"
mkdir -p "$H/.cc-reaper"
cp "$ROOT_DIR/hooks/worktree-session-end.sh" "$H/.cc-reaper/worktree-session-end.sh"
printf '#!/nonexistent/interpreter\necho "ran $* harness=$CC_WJ_HARNESS" > "%s/ran"\n' "$TMP" > "$H/.cc-reaper/worktree-janitor.sh"
chmod +x "$H/.cc-reaper/worktree-janitor.sh"
HOME="$H" bash "$H/.cc-reaper/worktree-session-end.sh" codex </dev/null >/dev/null 2>&1
check "the SessionEnd entrypoint starts the janitor by its interpreter" test "$(cat "$TMP/ran" 2>/dev/null)" = "ran --session harness=codex"
check "the SessionEnd entrypoint has no by-path exec" bash -c '! grep -q "exec \"\$janitor\"" "$1"' _ "$ROOT_DIR/hooks/worktree-session-end.sh"

[ "$failures" -eq 0 ] || exit 1
echo "install-session-hook: all tests passed"
