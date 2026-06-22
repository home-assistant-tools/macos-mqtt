#!/bin/bash
# Notarize and staple MQTT Bridge.app, then produce a distributable zip.
# Requires an app-specific password (https://appleid.apple.com → App-Specific Passwords).
#
# Usage:
#   APPLE_ID="you@example.com" TEAM_ID="3LMA9TXC7Z" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#       scripts/notarize.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
DMG="dist/MQTT-Bridge-$VERSION.dmg"
: "${APPLE_ID:?Set APPLE_ID}"
: "${TEAM_ID:?Set TEAM_ID}"
: "${APP_PASSWORD:?Set APP_PASSWORD (app-specific password)}"

[ -f "$DMG" ] || { echo "Build first: scripts/build.sh $VERSION"; exit 1; }

echo "==> submitting $DMG to Apple notary service (takes a few minutes)…"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait

echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "Notarized + stapled: $DMG"
