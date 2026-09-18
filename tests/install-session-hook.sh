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

[ "$failures" -eq 0 ] || exit 1
echo "install-session-hook: all tests passed"
