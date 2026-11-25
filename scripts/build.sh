#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/DingLater.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/DingLaterMac" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/Info.plist"
swift scripts/Icon.swift .build/AppIcon.iconset "$app/Contents/Resources/Koala.png"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${DINGLATER_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"

