#!/bin/bash
set -e

echo "=== Claude Code Cleanup - Installer ==="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

# ─── 1. Shell functions ─────────────────────────────────────────────────────

echo "[1/4] Installing shell functions..."

SHELL_SOURCE="source \"$SCRIPT_DIR/shell/claude-cleanup.sh\""

# Detect shell config file
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME_DIR/.zshrc" ]; then
  SHELL_RC="$HOME_DIR/.zshrc"
elif [ -f "$HOME_DIR/.bashrc" ]; then
  SHELL_RC="$HOME_DIR/.bashrc"
else
  SHELL_RC="$HOME_DIR/.zshrc"
fi

if grep -q "claude-cleanup.sh" "$SHELL_RC" 2>/dev/null; then
  echo "  Already in $SHELL_RC, skipping."
else
  echo "" >> "$SHELL_RC"
  echo "# Claude Code cleanup functions" >> "$SHELL_RC"
  echo "$SHELL_SOURCE" >> "$SHELL_RC"
  echo "  Added to $SHELL_RC"
fi

# ─── 2. Stop hook ───────────────────────────────────────────────────────────

echo "[2/4] Installing Claude Code Stop hook..."

HOOKS_DIR="$HOME_DIR/.claude/hooks"
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/stop-cleanup-orphans.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/stop-cleanup-orphans.sh"

# Update global settings.json
SETTINGS_FILE="$HOME_DIR/.claude/settings.json"
HOOK_CMD="\"\\$HOME\"/.claude/hooks/stop-cleanup-orphans.sh"

if [ -f "$SETTINGS_FILE" ] && grep -q "stop-cleanup-orphans" "$SETTINGS_FILE" 2>/dev/null; then
  echo "  Stop hook already configured in settings.json, skipping."
else
  echo "  Hook script copied to $HOOKS_DIR/"
  echo "  NOTE: You need to manually add the hook to $SETTINGS_FILE."
  echo "  Add this to the \"Stop\" hooks array:"
  echo ""
  echo "    {"
  echo "      \"type\": \"command\","
  echo "      \"command\": \"\\\"\\\$HOME\\\"/.claude/hooks/stop-cleanup-orphans.sh\","
  echo "      \"timeout\": 15"
  echo "    }"
  echo ""
fi

# ─── 3. proc-janitor ────────────────────────────────────────────────────────

echo "[3/4] Setting up proc-janitor..."

if command -v proc-janitor &>/dev/null; then
  echo "  proc-janitor already installed."
else
  if command -v brew &>/dev/null; then
    echo "  Installing via Homebrew..."
    brew install jhlee0409/tap/proc-janitor
  elif command -v cargo &>/dev/null; then
    echo "  Installing via Cargo..."
    cargo install proc-janitor
  else
    echo "  WARNING: Neither brew nor cargo found. Install manually:"
    echo "    brew install jhlee0409/tap/proc-janitor"
    echo "    OR: cargo install proc-janitor"
  fi
fi

# Copy config
JANITOR_CONFIG_DIR="$HOME_DIR/.config/proc-janitor"
mkdir -p "$JANITOR_CONFIG_DIR"

if [ -f "$JANITOR_CONFIG_DIR/config.toml" ]; then
  echo "  Config already exists, skipping. See proc-janitor/config.toml for reference."
else
  # Replace ~ with actual home path in config
  sed "s|~/.proc-janitor|$HOME_DIR/.proc-janitor|g" "$SCRIPT_DIR/proc-janitor/config.toml" > "$JANITOR_CONFIG_DIR/config.toml"
  chmod 600 "$JANITOR_CONFIG_DIR/config.toml"
  echo "  Config installed to $JANITOR_CONFIG_DIR/config.toml"
fi

# ─── 4. Start daemon ────────────────────────────────────────────────────────

echo "[4/4] Starting proc-janitor daemon..."

if command -v brew &>/dev/null && command -v proc-janitor &>/dev/null; then
  brew services start jhlee0409/tap/proc-janitor 2>/dev/null || true
  echo "  Daemon started (brew services)."
elif command -v proc-janitor &>/dev/null; then
  echo "  Run manually: proc-janitor start"
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Installation complete ==="
echo ""
echo "Available commands (restart terminal or 'source $SHELL_RC'):"
echo "  claude-ram        Show Claude Code RAM usage breakdown"
echo "  claude-cleanup    Immediately kill orphan processes"
echo "  proc-janitor scan Show detected orphans (dry run)"
echo "  proc-janitor clean  Kill detected orphans"
echo "  proc-janitor status Check daemon health"
