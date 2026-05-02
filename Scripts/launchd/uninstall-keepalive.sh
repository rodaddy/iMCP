#!/usr/bin/env bash
set -euo pipefail

LABEL="com.rodaddy.iMCP.keepalive"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Removed launchd keepalive: $PLIST"
