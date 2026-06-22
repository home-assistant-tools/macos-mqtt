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
APP_NAME="MQTT Bridge"
APP="dist/$APP_NAME.app"
: "${APPLE_ID:?Set APPLE_ID}"
: "${TEAM_ID:?Set TEAM_ID}"
: "${APP_PASSWORD:?Set APP_PASSWORD (app-specific password)}"

[ -d "$APP" ] || { echo "Build first: scripts/build.sh $VERSION"; exit 1; }

SUBMIT_ZIP="dist/notarize-submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> submitting to Apple notary service (chờ vài phút)…"
xcrun notarytool submit "$SUBMIT_ZIP" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

OUT="dist/MQTT-Bridge-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
rm -f "$SUBMIT_ZIP"
echo "Notarized + stapled: $OUT"
