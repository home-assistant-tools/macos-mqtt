#!/bin/bash
# Generate Resources/AppIcon.icns from a CoreGraphics drawing.
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/make_icon.swift
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
echo "Wrote Resources/AppIcon.icns"
