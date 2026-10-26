#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the app for a simulator and run it there: the UI only (no game runs in a
# simulator; simulator-staged.py, simulator-prebuild.sh).
#
#   app/Xcode/simulator-run.sh [SIMULATOR]   default: the iPhone Duo simulator
#
# The installed copy has no PlugIns/PlayportJIT.appex: its borrowed extension
# point does not exist in a simulator, which then refuses the whole app.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
SIM=${1:-$(xcrun simctl list devices available | sed -n 's/^ *iPhone Duo (\([0-9A-F-]*\)).*/\1/p' | head -1)}
DD=$REPO/.work/xcode-dd
xcodegen -q
xcodebuild -project Playport.xcodeproj -scheme Playport -destination "id=$SIM" -derivedDataPath "$DD" build \
    > "$REPO/.work/xcode-sim.log" 2>&1 || { grep -E "error:" "$REPO/.work/xcode-sim.log" | sort -u | head -20; exit 1; }
app=$REPO/.work/simulator/S1Probe.app
rm -rf "$app" && cp -R "$DD/Build/Products/Debug-iphonesimulator/S1Probe.app" "$app"
rm -rf "$app/PlugIns"
codesign -f -s - --preserve-metadata=entitlements "$app" 2>/dev/null
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl install "$SIM" "$app"
xcrun simctl launch --terminate-running-process "$SIM" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
