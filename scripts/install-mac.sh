#!/bin/bash
# Builds the Mac app and installs it to /Applications/Hushbook.app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"   # Debug = iCloud Development environment (same as Xcode-run iPhone builds)
xcodegen generate >/dev/null
xcodebuild -project Hushbook.xcodeproj -scheme HushbookMac -configuration "$CONFIG" -derivedDataPath build -allowProvisioningUpdates \
  SWIFT_OPTIMIZATION_LEVEL=-O build | grep -E "error:|BUILD" || true
pkill -x Hushbook 2>/dev/null || true
sleep 1
rm -rf /Applications/Hushbook.app
ditto "build/Build/Products/$CONFIG/Hushbook.app" /Applications/Hushbook.app
open /Applications/Hushbook.app
echo "Installed /Applications/Hushbook.app ($CONFIG)"
