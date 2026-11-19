#!/bin/sh
# Builds build/Airtap.app so macOS grants audio capture and local network access to Airtap itself, not to a terminal.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product AirtapApp
app=build/Airtap.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/AirtapApp "$app/Contents/MacOS/AirtapApp"
cp Sources/AirtapApp/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Sources/AirtapApp/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [ "${AIRTAP_VERSION:-}" != "" ]; then
	plutil -replace CFBundleShortVersionString -string "$AIRTAP_VERSION" "$app/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$AIRTAP_VERSION" "$app/Contents/Info.plist"
fi
# Ad-hoc by default; a real identity keeps the granted permissions across rebuilds (see README).
codesign --force --sign "${AIRTAP_SIGN_IDENTITY:--}" "$app"
echo "$app"
