#!/bin/bash
# Builds the iPhone app and installs it on a USB/Wi-Fi connected iPhone (iCloud Development environment).
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -E 'iPhone.*connected' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
xcodegen generate >/dev/null
xcodebuild -project Hushbook.xcodeproj -scheme HushbookIOS -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates SWIFT_OPTIMIZATION_LEVEL=-O build | grep -E "error:|BUILD" || true
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/Hushbook.app
echo "Installed on $DEVICE"
