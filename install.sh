#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

# ─── Detect install vs update ────────────────────────────────────────────────
IS_UPDATE=false
if grep -q "claude-cleanup.sh" "$HOME_DIR/.zshrc" 2>/dev/null || \
   grep -q "claude-cleanup.sh" "$HOME_DIR/.bashrc" 2>/dev/null || \
   [ -f "$HOME_DIR/.claude/hooks/stop-cleanup-orphans.sh" ]; then
  IS_UPDATE=true
fi

if $IS_UPDATE; then
  echo "=== cc-reaper — Update ==="
  echo "Existing installation detected. Updating to latest version..."
else
  echo "=== cc-reaper — Install ==="
fi
echo ""

# ─── 1. Shell functions ─────────────────────────────────────────────────────

echo "[1/4] Installing shell functions..."

SHELL_SOURCE="source \"$SCRIPT_DIR/shell/claude-cleanup.sh\""
MONITOR_SOURCE="source \"$SCRIPT_DIR/shell/cc-monitor.sh\""

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

if grep -q "cc-monitor.sh" "$SHELL_RC" 2>/dev/null; then
  echo "  cc-monitor already in $SHELL_RC, skipping."
else
  echo "$MONITOR_SOURCE" >> "$SHELL_RC"
  echo "  Added cc-monitor to $SHELL_RC"
fi

# ─── 2. Stop hook ───────────────────────────────────────────────────────────

if $IS_UPDATE; then
  echo "[2/4] Updating Claude Code Stop hook..."
else
  echo "[2/4] Installing Claude Code Stop hook..."
fi

HOOKS_DIR="$HOME_DIR/.claude/hooks"
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/stop-cleanup-orphans.sh" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/stop-cleanup-orphans.sh"

# Update global settings.json
SETTINGS_FILE="$HOME_DIR/.claude/settings.json"
HOOK_CMD="\"\\$HOME\"/.claude/hooks/stop-cleanup-orphans.sh"

if [ -f "$SETTINGS_FILE" ] && grep -q "stop-cleanup-orphans" "$SETTINGS_FILE" 2>/dev/null; then
  echo "  Hook script updated. settings.json already configured."
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

# ─── 3. Daemon setup (proc-janitor OR LaunchAgent) ──────────────────────────

if $IS_UPDATE; then
  echo "[3/5] Updating background daemon..."
else
  echo "[3/5] Setting up background daemon..."
fi
echo ""
echo "  Choose a daemon for continuous orphan cleanup:"
echo "    a) proc-janitor  — Feature-rich Rust daemon (grace period, whitelist, logging)"
echo "                       Requires: Homebrew or Cargo"
echo "    b) LaunchAgent   — Zero-dependency macOS native (10-min interval, PPID=1 detection)"
echo "                       Requires: nothing (built-in macOS)"
echo ""
printf "  Your choice [a/b] (default: b): "
read -r DAEMON_CHOICE
DAEMON_CHOICE="${DAEMON_CHOICE:-b}"
while [ "$DAEMON_CHOICE" != "a" ] && [ "$DAEMON_CHOICE" != "b" ]; do
  printf "  Invalid choice. Please enter 'a' or 'b' (default: b): "
  read -r DAEMON_CHOICE
  DAEMON_CHOICE="${DAEMON_CHOICE:-b}"
done

if [ "$DAEMON_CHOICE" = "a" ]; then
  # ─── proc-janitor path ───
  echo "  Setting up proc-janitor..."

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
    if $IS_UPDATE; then
      echo "  Config exists — comparing with latest..."
      if diff -q "$SCRIPT_DIR/proc-janitor/config.toml" "$JANITOR_CONFIG_DIR/config.toml" >/dev/null 2>&1; then
        echo "  Config already up to date."
      else
        echo "  Config differs from latest. Review changes:"
        echo "    diff $SCRIPT_DIR/proc-janitor/config.toml $JANITOR_CONFIG_DIR/config.toml"
      fi
    else
      echo "  Config already exists, skipping. See proc-janitor/config.toml for reference."
    fi
  else
    sed "s|~/.proc-janitor|$HOME_DIR/.proc-janitor|g" "$SCRIPT_DIR/proc-janitor/config.toml" > "$JANITOR_CONFIG_DIR/config.toml"
    chmod 600 "$JANITOR_CONFIG_DIR/config.toml"
    echo "  Config installed to $JANITOR_CONFIG_DIR/config.toml"
  fi

  echo "[4/5] Starting proc-janitor daemon..."
  if command -v brew &>/dev/null && command -v proc-janitor &>/dev/null; then
    brew services start jhlee0409/tap/proc-janitor 2>/dev/null || true
    echo "  Daemon started (brew services)."
  elif command -v proc-janitor &>/dev/null; then
    echo "  Run manually: proc-janitor start"
  fi

else
  # ─── LaunchAgent path ───
  echo "  Setting up LaunchAgent (zero-dependency)..."

  REAPER_DIR="$HOME_DIR/.cc-reaper"
  mkdir -p "$REAPER_DIR/logs"

  # Copy monitor script
  cp "$SCRIPT_DIR/launchd/cc-reaper-monitor.sh" "$REAPER_DIR/"
  chmod +x "$REAPER_DIR/cc-reaper-monitor.sh"

  # Install plist with actual home path
  PLIST_DIR="$HOME_DIR/Library/LaunchAgents"
  mkdir -p "$PLIST_DIR"
  PLIST_FILE="$PLIST_DIR/com.cc-reaper.orphan-monitor.plist"

  sed "s|__HOME__|$HOME_DIR|g" "$SCRIPT_DIR/launchd/com.cc-reaper.orphan-monitor.plist" > "$PLIST_FILE"

  # Load the LaunchAgent
  launchctl unload "$PLIST_FILE" 2>/dev/null || true
  launchctl load "$PLIST_FILE"

  echo "  LaunchAgent installed and started."
  echo "  Monitor runs every 10 minutes, logs at $REAPER_DIR/logs/"

  echo "[4/5] LaunchAgent active — skipping proc-janitor."
fi

# ─── 5. Uninstall hint ────────────────────────────────────────────────────────

echo "[5/5] Done."

echo ""
if $IS_UPDATE; then
  echo "=== Update complete ==="
else
  echo "=== Installation complete ==="
fi
echo ""
echo "Available commands (restart terminal or 'source $SHELL_RC'):"
echo "  cc-monitor          Explain current CPU heat contributors (read-only)"
echo "  claude-ram          Show Claude Code RAM/CPU usage breakdown"
echo "  claude-cleanup      Immediately kill orphan processes"
echo "  claude-sessions     List active sessions with idle detection"
if [ "$DAEMON_CHOICE" = "a" ]; then
echo "  proc-janitor scan   Show detected orphans (dry run)"
echo "  proc-janitor clean  Kill detected orphans"
echo "  proc-janitor status Check daemon health"
else
echo ""
echo "LaunchAgent commands:"
echo "  launchctl list | grep cc-reaper   Check if monitor is running"
echo "  cat ~/.cc-reaper/logs/monitor.log View cleanup log"
echo "  launchctl unload ~/Library/LaunchAgents/com.cc-reaper.orphan-monitor.plist  Stop"
fi
