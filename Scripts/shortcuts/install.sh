#!/usr/bin/env bash
# Build and install iMCP dock shortcut apps with proper icons
# Usage: bash Scripts/shortcuts/install.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON="$SCRIPT_DIR/AppIcon.icns"

echo "Building Restart iMCP.app..."
osacompile -o "/Applications/Restart iMCP.app" "$SCRIPT_DIR/restart-imcp.applescript"
cp "$ICON" "/Applications/Restart iMCP.app/Contents/Resources/applet.icns"
touch "/Applications/Restart iMCP.app"

echo "Refreshing Dock icon cache..."
killall Dock

echo "Done. Drag 'Restart iMCP' from /Applications to your Dock."
