#!/bin/bash
# Build, bundle and code-sign MQTT Bridge.app
# Usage: SIGN_ID="Developer ID Application: …" scripts/build.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP_NAME="MQTT Bridge"
SIGN_ID="${SIGN_ID:-Developer ID Application: Ba DUong (3LMA9TXC7Z)}"

echo "==> swift build (release)"
swift build -c release
BIN=".build/release/MqttBridge"

DIST="dist"
APP="$DIST/$APP_NAME.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MqttBridge"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

echo "==> codesign ($SIGN_ID)"
codesign --force --options runtime --timestamp \
    --entitlements entitlements.plist \
    --sign "$SIGN_ID" "$APP"

echo "==> verify"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Authority=Developer|TeamIdentifier' || true

echo "==> zip"
ZIP="$DIST/MQTT-Bridge-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $APP"
echo "      $ZIP"
