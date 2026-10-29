#!/bin/bash
# Builds a Developer ID signed, notarized Hushbook.app and zips it: scripts/release-mac.sh [version]
# Needs the "Developer ID Application" certificate and a notarytool keychain profile (NOTARY_PROFILE, default tasker-notary).
# With a version, also publishes the zip as a GitHub release (tag v<version>).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"
PROFILE="${NOTARY_PROFILE:-tasker-notary}"
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Hushbook.xcodeproj -scheme HushbookMac -configuration Release -archivePath "$OUT/Hushbook.xcarchive" \
  -allowProvisioningUpdates ${VERSION:+MARKETING_VERSION=$VERSION} archive | grep -E "error:|ARCHIVE" || true
cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>SZVSSCJQFN</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/Hushbook.xcarchive" -exportPath "$OUT" -exportOptionsPlist "$OUT/export.plist" \
  -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
APP="$OUT/Hushbook.app"
ZIP="$OUT/Hushbook-macOS${VERSION:+-$VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with the stapled ticket
spctl -a -vv "$APP"
echo "Built $ZIP"
if [ -n "$VERSION" ]; then
  gh release create "v$VERSION" "$ZIP" --title "Hushbook $VERSION" --notes-file - <<EOF
Hushbook for Mac, signed with Developer ID and notarized by Apple. Unzip and move **Hushbook.app** to Applications. Requires macOS 26.

iPhone and iPad builds can't be distributed as files: build them from source with Xcode (see the README).
EOF
fi
