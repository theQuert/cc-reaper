#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CCReaper"
BUNDLE_ID="com.thequert.CCReaper"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [ -z "$ROOT_DIR" ] || [ "$ROOT_DIR" = "/" ]; then
  echo "build_and_run: refusing unsafe project root" >&2
  exit 1
fi

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

find_staged_app_pids() {
  local args
  local pid
  for pid in $(/usr/bin/pgrep -x "$APP_NAME" || true); do
    args="$(/bin/ps -ww -p "$pid" -o args= 2>/dev/null || true)"
    case "$args" in
      "$APP_BINARY"|"$APP_BINARY "*) echo "$pid" ;;
    esac
  done
}

EXISTING_PIDS=""
case "$MODE" in
  --verify|verify)
    EXISTING_PIDS="$(find_staged_app_pids)"
    ;;
  *)
    for pid in $(find_staged_app_pids); do
      /bin/kill "$pid" >/dev/null 2>&1 || true
    done
    ;;
esac

swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"

if [ -e "$APP_BUNDLE" ]; then
  /bin/rm -rf -- "$APP_BUNDLE"
fi
/bin/mkdir -p "$APP_MACOS"
/bin/cp "$BUILD_BINARY" "$APP_BINARY"
/bin/chmod +x "$APP_BINARY"

/bin/cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>cc-reaper</string>
  <key>CFBundleDisplayName</key>
  <string>cc-reaper</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

is_preexisting_pid() {
  local candidate="$1"
  local existing
  while IFS= read -r existing; do
    if [ -n "$existing" ] && [ "$existing" = "$candidate" ]; then
      return 0
    fi
  done <<<"$EXISTING_PIDS"
  return 1
}

find_new_app_pid() {
  local pid
  for pid in $(find_staged_app_pids); do
    if ! is_preexisting_pid "$pid"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

stop_verification_process() {
  local pid="$1"
  if /bin/kill -0 "$pid" >/dev/null 2>&1; then
    /bin/kill "$pid"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    /usr/bin/open -g -n "$APP_BUNDLE" --args --background-test
    verification_pid=""
    for _ in {1..40}; do
      verification_pid="$(find_new_app_pid || true)"
      if [ -n "$verification_pid" ]; then
        break
      fi
      /bin/sleep 0.1
    done
    if [ -z "$verification_pid" ]; then
      echo "build_and_run: background verification process did not start" >&2
      exit 1
    fi
    trap 'stop_verification_process "$verification_pid"' EXIT
    stop_verification_process "$verification_pid"
    for _ in {1..40}; do
      if ! /bin/kill -0 "$verification_pid" >/dev/null 2>&1; then
        break
      fi
      /bin/sleep 0.1
    done
    if /bin/kill -0 "$verification_pid" >/dev/null 2>&1; then
      echo "build_and_run: verification process did not stop" >&2
      exit 1
    fi
    trap - EXIT
    echo "background verification passed (pid $verification_pid)"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
