#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/OmoUsage.app"
CONTENTS="$APP/Contents"
ICONSET="$ROOT/.build/OmoUsage.iconset"
IDENTITY="${OMO_USAGE_CODESIGN_IDENTITY:--}"
TEAM_IDENTIFIER="${OMO_USAGE_TEAM_IDENTIFIER:-}"
ENTITLEMENTS_TEMPLATE="$ROOT/Config/OmoUsage.entitlements"
TEMP_ENTITLEMENTS=""
EXTRACTED_ENTITLEMENTS=""

usage() {
    printf '%s\n' "usage: $0 [--print-signing-plan]" >&2
    exit 64
}

case "$#" in
    0) MODE=package ;;
    1)
        [ "$1" = "--print-signing-plan" ] || usage
        MODE=plan
        ;;
    *) usage ;;
esac

case "$TEAM_IDENTIFIER" in
    *[!A-Za-z0-9]*)
        printf '%s\n' "error: OMO_USAGE_TEAM_IDENTIFIER must contain only letters and digits" >&2
        exit 64
        ;;
esac

if [ "$IDENTITY" != "-" ] && [ -z "$TEAM_IDENTIFIER" ]; then
    printf '%s\n' "error: OMO_USAGE_TEAM_IDENTIFIER is required for non-ad-hoc signing" >&2
    exit 64
fi

if [ "$MODE" = "plan" ]; then
    printf 'SIGNING_IDENTITY=%s\n' "$IDENTITY"
    if [ -n "$TEAM_IDENTIFIER" ]; then
        printf 'TEAM_IDENTIFIER=%s\n' "$TEAM_IDENTIFIER"
        printf 'ENTITLEMENTS=%s\n' "$ENTITLEMENTS_TEMPLATE"
        printf 'KVS_IDENTIFIER=%s.com.omo.usage\n' "$TEAM_IDENTIFIER"
        printf 'CLOUD_KVS_AVAILABLE=yes\n'
    else
        printf 'TEAM_IDENTIFIER=\n'
        printf 'ENTITLEMENTS=\n'
        printf 'KVS_IDENTIFIER=\n'
        printf 'CLOUD_KVS_AVAILABLE=no\n'
    fi
    exit 0
fi

cleanup() {
    [ -z "$TEMP_ENTITLEMENTS" ] || rm -f "$TEMP_ENTITLEMENTS"
    [ -z "$EXTRACTED_ENTITLEMENTS" ] || rm -f "$EXTRACTED_ENTITLEMENTS"
}
trap cleanup EXIT HUP INT TERM

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
cp Sources/OmoUsage/Resources/WebDashboard/index.html \
    "$CONTENTS/Resources/index.html"

rm -rf "$ICONSET"
swift Scripts/generate-app-icon.swift \
    Sources/OmoUsage/Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/OmoUsage.icns"
rm -rf "$ICONSET"

if [ -n "$TEAM_IDENTIFIER" ]; then
    TEMP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/OmoUsage-entitlements.XXXXXX.plist")"
    EXTRACTED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/OmoUsage-signed-entitlements.XXXXXX.plist")"
    cp "$ENTITLEMENTS_TEMPLATE" "$TEMP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy \
        -c "Set :com.apple.developer.ubiquity-kvstore-identifier ${TEAM_IDENTIFIER}.com.omo.usage" \
        "$TEMP_ENTITLEMENTS"
    codesign --force --deep --sign "$IDENTITY" \
        --entitlements "$TEMP_ENTITLEMENTS" "$APP"
    codesign -d --entitlements :- "$APP" > "$EXTRACTED_ENTITLEMENTS"
    ACTUAL_KVS_IDENTIFIER="$(/usr/libexec/PlistBuddy \
        -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' \
        "$EXTRACTED_ENTITLEMENTS")"
    if [ "$ACTUAL_KVS_IDENTIFIER" != "${TEAM_IDENTIFIER}.com.omo.usage" ]; then
        printf '%s\n' "error: signed cloud KVS entitlement did not match the requested team" >&2
        exit 1
    fi
else
    printf '%s\n' "warning: ad-hoc package has no team identifier; cloud KVS is unavailable" >&2
    codesign --force --deep --sign - "$APP"
fi
printf '%s\n' "$APP"
