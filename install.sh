#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

# Guard: an empty HOME (e.g. run under sudo or a stripped env) makes every
# `sed s|__HOME__|$HOME_DIR|` below produce a broken "/.cc-reaper/..." path,
# silently installing LaunchAgents that can never find their script (exit 78).
# Fall back to the account's real home, then fail-fast rather than mis-install.
if [ -z "$HOME_DIR" ]; then
  HOME_DIR=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
fi
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  echo "FATAL: cannot resolve home directory (HOME unset); aborting to avoid installing broken LaunchAgent paths." >&2
  exit 1
fi

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

# Activate a LaunchAgent and confirm it came up.
#
# `launchctl load` cannot clear a `disabled` flag in the launchd database, and
# reports nothing when the agent fails to start — an agent disabled once stays
# dead through every later install while still looking installed. Enable,
# bootstrap, then confirm. Appends failures to AGENT_FAILED.
AGENT_UI="gui/$(id -u)"
AGENT_FAILED=""
_cc_install_agent() {
  local label=$1 plist=$2
  launchctl enable "$AGENT_UI/$label" 2>/dev/null || true
  launchctl bootout "$AGENT_UI/$label" 2>/dev/null || true
  launchctl bootstrap "$AGENT_UI" "$plist" 2>/dev/null || true
  launchctl print "$AGENT_UI/$label" >/dev/null 2>&1 && return 0
  AGENT_FAILED="$AGENT_FAILED $label"
  return 1
}

_cc_report_failed_agents() {
  [ -n "$AGENT_FAILED" ] || return 0
  echo "  WARNING: these agents did not load:$AGENT_FAILED"
  echo "           inspect with: launchctl print $AGENT_UI/<label>"
}

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

  echo "[4/6] Starting proc-janitor daemon..."
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

  _cc_install_agent "com.cc-reaper.orphan-monitor" "$PLIST_FILE" || true

  echo "  LaunchAgent installed and started."
  echo "  Monitor runs every 10 minutes, logs at $REAPER_DIR/logs/"

  echo "[4/6] LaunchAgent active — skipping proc-janitor."
fi

# ─── 5. Resource & disk janitor (LaunchAgents) ──────────────────────────────

if $IS_UPDATE; then
  echo "[5/6] Updating resource & disk janitor..."
else
  echo "[5/6] Installing resource & disk janitor..."
fi

REAPER_DIR="$HOME_DIR/.cc-reaper"
mkdir -p "$REAPER_DIR/logs" "$REAPER_DIR/state"
PLIST_DIR="$HOME_DIR/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

# claude-cleanup + guard-runner ship too: the guard agent sources the DEPLOYED
# claude-cleanup.sh (a launchd agent has no TCC access to a ~/Documents checkout),
# with guard-runner.sh next to it.
for SCRIPT in resource-watch disk-janitor worktree-janitor cc-monitor claude-cleanup guard-runner; do
  cp "$SCRIPT_DIR/shell/$SCRIPT.sh" "$REAPER_DIR/"
  chmod +x "$REAPER_DIR/$SCRIPT.sh"
done

for AGENT in resource-watch disk-check weekly-clean guard; do
  AGENT_LABEL="com.cc-reaper.$AGENT"
  AGENT_PLIST="$PLIST_DIR/$AGENT_LABEL.plist"
  sed "s|__HOME__|$HOME_DIR|g" "$SCRIPT_DIR/launchd/$AGENT_LABEL.plist" > "$AGENT_PLIST"
  _cc_install_agent "$AGENT_LABEL" "$AGENT_PLIST" || true
done
_cc_report_failed_agents

echo "  resource-watch: snapshot every 10 min (alerts on load/disk/memory thresholds)"
echo "  disk-check:     read-only disk + TM-snapshot check every hour"
echo "  weekly-clean:   rebuildable-cache cleanup every Sunday 04:00"
echo "  worktree-janitor: manual — run '~/.cc-reaper/worktree-janitor.sh' (report), add --apply to clean"
echo "                    not scheduled: a LaunchAgent has no TCC access to ~/Documents, measured 2026-08-30"
echo "  guard:          runaway-MCP reaper every 10 min (SIGTERMs whitelisted MCP pinned >80% CPU for >60 min)"

# ─── 5b. TCC probe ────────────────────────────────────────────────────────────
#
# The agents just installed run under launchd, and launchd's context does not carry
# the operator's TCC grants. `~/Documents`, `~/Desktop` and `~/Downloads` are
# protected on macOS, so an agent reads them only if the program named in the plist
# holds Full Disk Access.
#
# Probed from launchd rather than from here, because the two contexts disagree and
# only one of them is the one the agents run in - an operator who checks by hand sees
# it work and never learns the agent cannot. That disagreement is the whole reason
# this is invisible without a probe.
#
# Reported, not recommended. No agent this installer schedules reads these paths -
# they work under ~/Library and /private/tmp - so telling an operator to grant
# /bin/bash Full Disk Access would hand every bash script on the machine access to all
# protected user data while enabling no sweep that exists. What the probe is for is
# the operator who later schedules something of their own over ~/Documents: that run
# would exit 0 reporting nothing found, which is what an empty machine looks like.
_cc_probe_tcc() {
  command -v launchctl >/dev/null 2>&1 || return 0
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0

  local label="com.cc-reaper.tcc-probe"
  local plist="$PLIST_DIR/$label.plist"
  local out="$REAPER_DIR/logs/tcc-probe.out"

  # Absent is not denied, and reporting the two the same way is the bug this exists
  # to avoid. Only a path that exists is worth asking about.
  local present=() d
  for d in "$HOME_DIR/Documents" "$HOME_DIR/Desktop" "$HOME_DIR/Downloads"; do
    [ -d "$d" ] && present+=("$d")
  done
  [ "${#present[@]}" -gt 0 ] || return 0

  : > "$out" 2>/dev/null || return 0

  # Each path is its own <string> in ProgramArguments and the probe iterates "$@".
  # Splicing them into a single `-c` word list split `/Users/John Smith/Documents`
  # into two, and the installer then reported a Full Disk Access grant as missing
  # when it was already held - a false alarm in the one place whose whole value is
  # being believed.
  local args="" xd
  for xd in "${present[@]}"; do
    xd="${xd//&/&amp;}"; xd="${xd//</&lt;}"; xd="${xd//>/&gt;}"
    args="$args
    <string>$xd</string>"
  done

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>for d in "\$@"; do if [ -r "\$d" ] &amp;&amp; [ -x "\$d" ] &amp;&amp; ls "\$d" >/dev/null 2>&amp;1; then echo "OK \$d"; else echo "DENIED \$d"; fi; done</string>
    <string>probe</string>$args
  </array>
  <key>StandardOutPath</key><string>$out</string>
  <key>RunAtLoad</key><false/>
</dict></plist>
PLIST

  launchctl bootout "$AGENT_UI/$label" 2>/dev/null || true
  launchctl bootstrap "$AGENT_UI" "$plist" 2>/dev/null || {
    rm -f "$plist"; return 0; }
  launchctl kickstart -k "$AGENT_UI/$label" 2>/dev/null || true

  # Bounded wait. A probe that never answered is reported as unknown, never as OK:
  # silence here would recreate the exact fault being probed for.
  # Every path, not the first. Breaking on the first `OK|DENIED` line meant that if
  # one directory answered quickly and another was slow to enumerate, the probe was
  # torn down mid-run - and a first result of OK would have been reported as "the
  # agents can read Documents/Desktop/Downloads" without the others ever being asked.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ "$(grep -cE '^(OK|DENIED) ' "$out" 2>/dev/null)" -ge "${#present[@]}" ] && break
    i=$((i + 1)); sleep 0.5
  done
  launchctl bootout "$AGENT_UI/$label" 2>/dev/null || true
  rm -f "$plist"

  # A partial answer is not an answer: reporting "all readable" on the strength of
  # one path that happened to finish is the same false success the probe exists to
  # prevent, one level in.
  if [ "$(grep -cE '^(OK|DENIED) ' "$out" 2>/dev/null)" -lt "${#present[@]}" ]; then
    echo "  TCC: probe reported on only $(grep -cE '^(OK|DENIED) ' "$out" 2>/dev/null) of ${#present[@]} paths;"
    echo "       could not determine what the agents can read."
    return 0
  fi

  local denied
  denied=$(sed -n 's/^DENIED //p' "$out" | tr '\n' ' ')
  if [ -z "$denied" ]; then
    echo "  TCC: agents can read Documents/Desktop/Downloads."
    return 0
  fi

  echo ""
  echo "  TCC: from a LaunchAgent, this machine cannot read:$denied"
  echo "       Nothing installed here reads them today - resource-watch, disk-check,"
  echo "       weekly-clean and guard work under ~/Library and /private/tmp, and"
  echo "       worktree-janitor is manual by design for exactly this reason."
  echo "       It matters if you schedule a sweep of your own over those paths: it"
  echo "       would run, exit 0, and report nothing found, which is what an empty"
  echo "       machine looks like."
  echo "       Granting Full Disk Access to /bin/bash would fix that and would also"
  echo "       give EVERY bash script on this machine access to all protected user"
  echo "       data. Keep the repositories you want swept outside those directories"
  echo "       instead, unless you have a reason to accept that trade."
  echo ""
}

_cc_probe_tcc || true

# ─── 6. Uninstall hint ────────────────────────────────────────────────────────

echo "[6/6] Done."

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
echo ""
echo "Resource & disk janitor:"
echo "  cat ~/.cc-reaper/logs/resource-watch.log       System snapshots (10-min cadence)"
echo "  ~/.cc-reaper/disk-janitor.sh --check           Read-only disk + snapshot-pin check"
echo "  ~/.cc-reaper/disk-janitor.sh --clean           Clean rebuildable caches now"
echo "  ~/.cc-reaper/worktree-janitor.sh               Worktree report (dry-run)"
echo "  ~/.cc-reaper/worktree-janitor.sh --apply       Remove clean idle worktrees"
