#!/bin/bash
# Builds the iPhone/iPad app and installs it on a connected device (iCloud Development environment).
# DEVICE=<udid> picks one (e.g. the iPad); default is the first iPhone. Building for that device registers it for signing.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -E 'iPhone.*(connected|available)' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
xcodegen generate >/dev/null
xcodebuild -project Hushbook.xcodeproj -scheme HushbookIOS -configuration Debug -destination "id=$DEVICE" \
  -derivedDataPath build -allowProvisioningUpdates SWIFT_OPTIMIZATION_LEVEL=-O build | grep -E "error:|BUILD" || true
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/Hushbook.app
echo "Installed on $DEVICE"
