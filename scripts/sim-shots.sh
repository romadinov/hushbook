#!/bin/bash
# Simulator screenshots of the demo diary: scripts/sim-shots.sh <outdir> [screens...]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"; shift
SIM="${SIM:-213FD326-91F3-42BB-A03D-260F7E13A6BA}"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcodegen generate >/dev/null
xcodebuild -project Hushbook.xcodeproj -scheme HushbookIOS -configuration Debug -destination "id=$SIM" -derivedDataPath build/sim build | grep -E "error:|BUILD FAILED" && exit 1
xcrun simctl install "$SIM" build/sim/Build/Products/Debug-iphonesimulator/Hushbook.app
for screen in "${@:-list}"; do
  xcrun simctl terminate "$SIM" com.romadinov.hushbook 2>/dev/null || true
  SIMCTL_CHILD_HUSHBOOK_DEMO=$screen xcrun simctl launch "$SIM" com.romadinov.hushbook >/dev/null
  sleep 5
  xcrun simctl io "$SIM" screenshot "$OUT/$screen.png" 2>/dev/null
done
