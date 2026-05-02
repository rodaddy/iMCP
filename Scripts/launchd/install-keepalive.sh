#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-/Applications/iMCP.app}"
LABEL="com.rodaddy.iMCP.keepalive"
PLIST_NAME="$LABEL.plist"
SOURCE_PLIST="$(cd "$(dirname "$0")" && pwd)/$PLIST_NAME"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET_PLIST="$TARGET_DIR/$PLIST_NAME"
APP_BINARY="$APP_PATH/Contents/MacOS/iMCP"

if [[ ! -x "$APP_BINARY" ]]; then
  echo "iMCP binary not found at: $APP_BINARY" >&2
  echo "Usage: $0 [/path/to/iMCP.app]" >&2
  exit 1
fi

if /usr/bin/pgrep -x iMCP >/dev/null 2>&1; then
  echo "iMCP is already running. Quit it before installing the keepalive agent." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
sed "s#/Applications/iMCP.app/Contents/MacOS/iMCP#$APP_BINARY#g" \
  "$SOURCE_PLIST" > "$TARGET_PLIST"

launchctl bootout "gui/$UID" "$TARGET_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$TARGET_PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed launchd keepalive: $TARGET_PLIST"
echo "It restarts iMCP after crashes or non-zero exits. A normal Quit is not relaunched."
