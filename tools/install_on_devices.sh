#!/bin/bash
# Builds Piano Pals for iOS and installs it on every connected iPad/iPhone that is awake and unlocked.
# usage: tools/install_on_devices.sh   (devices must show "connected" in: xcrun devicectl list devices)
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/ddInstall"
xcodebuild build -project PianoPals.xcodeproj -scheme PianoPals -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath "$OUT" -allowProvisioningUpdates > "$OUT.log" 2>&1 || { grep error: "$OUT.log" | sort -u; exit 1; }
APP=$(find "$OUT" -name PianoPals.app -path "*iphoneos*" | head -1)
for ID in $(xcrun devicectl list devices | awk '/connected/ && /physical/ {print $3}'); do
  echo "Installing on $ID"
  xcrun devicectl device install app --device "$ID" "$APP" | tail -2
done
