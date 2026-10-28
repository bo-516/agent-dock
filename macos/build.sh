#!/bin/bash
# Builds AgentDock.app into macos/build/, signs it ad hoc, installs it to
# ~/Applications and starts the installed copy in place of any running one.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AgentDock.app
TARGET="$HOME/Applications/AgentDock.app"
ARCH=$(uname -m)

mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos13.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/AgentDock"
codesign --force --sign - "$APP"

pkill -f "AgentDock.app/Contents/MacOS/AgentDock" || true
# Opening it again straight after the kill fails with -600.
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
open "$TARGET"
echo "Installed $TARGET"
