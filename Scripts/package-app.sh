#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/OmoUsage.app"
CONTENTS="$APP/Contents"
ICONSET="$ROOT/.build/OmoUsage.iconset"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources/ProviderIcons"
cp ".build/release/OmoUsage" "$CONTENTS/MacOS/OmoUsage"
cp "Config/Info.plist" "$CONTENTS/Info.plist"
# Config/Info.plist is written for xcodebuild, which expands these build
# settings. This script copies the file verbatim, so substitute them here or
# LaunchServices cannot find the executable and refuses to open the bundle.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleDevelopmentRegion en" \
    -c "Set :CFBundleExecutable OmoUsage" \
    -c "Set :CFBundleIdentifier com.omo.usage" \
    -c "Set :CFBundleName OmoUsage" \
    "$CONTENTS/Info.plist"
cp Sources/OmoUsage/Resources/ProviderIcons/*.svg \
    "$CONTENTS/Resources/ProviderIcons/"
cp Sources/OmoUsage/Resources/AppIcon.svg "$CONTENTS/Resources/AppIcon.svg"

rm -rf "$ICONSET"
swift Scripts/generate-app-icon.swift \
    Sources/OmoUsage/Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/OmoUsage.icns"
rm -rf "$ICONSET"

codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"
