#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT/dist/OmoUsage.app"
CONTENTS="$APP/Contents"
ICONSET="$ROOT/.build/OmoUsage.iconset"
REQUESTED_IDENTITY="${OMO_USAGE_CODESIGN_IDENTITY:--}"
TEAM_IDENTIFIER="${OMO_USAGE_TEAM_IDENTIFIER:-}"
ENTITLEMENTS_TEMPLATE="$ROOT/Config/OmoUsage.entitlements"
VERSION_CONFIGURATION="$ROOT/Config/Version.xcconfig"
SPARKLE_VERSION=2.9.6
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
TEMP_ENTITLEMENTS=""
EXTRACTED_ENTITLEMENTS=""
PLAN=no
QA_FIXTURES=no
MODE_WAS_EXPLICIT=no

version_setting() {
    value="$(awk -F ' = ' -v key="$1" '$1 == key { print $2; exit }' "$VERSION_CONFIGURATION")"
    if [ -z "$value" ]; then
        printf 'error: %s is missing from %s\n' "$1" "$VERSION_CONFIGURATION" >&2
        exit 1
    fi
    printf '%s\n' "$value"
}

usage() {
    printf '%s\n' "usage: $0 [--adhoc|--developer-id] [--qa-fixtures] [--print-signing-plan]" >&2
    exit 64
}

# No mode remains the documented local ad-hoc path. For compatibility,
# --print-signing-plan infers Developer ID only when an identity was supplied.
SIGNING_MODE=adhoc
while [ "$#" -gt 0 ]; do
    case "$1" in
        --adhoc)
            [ "$MODE_WAS_EXPLICIT" = no ] || usage
            SIGNING_MODE=adhoc
            MODE_WAS_EXPLICIT=yes
            ;;
        --developer-id)
            [ "$MODE_WAS_EXPLICIT" = no ] || usage
            SIGNING_MODE=developer-id
            MODE_WAS_EXPLICIT=yes
            ;;
        --qa-fixtures)
            [ "$QA_FIXTURES" = no ] || usage
            QA_FIXTURES=yes
            ;;
        --print-signing-plan)
            [ "$PLAN" = no ] || usage
            PLAN=yes
            ;;
        *) usage ;;
    esac
    shift
done
if [ "$MODE_WAS_EXPLICIT" = no ] && [ "$PLAN" = yes ] && [ "$REQUESTED_IDENTITY" != "-" ]; then
    SIGNING_MODE=developer-id
fi

case "$TEAM_IDENTIFIER" in
    *[!A-Za-z0-9]*)
        printf '%s\n' "error: OMO_USAGE_TEAM_IDENTIFIER must contain only letters and digits" >&2
        exit 64
        ;;
esac

if [ "$SIGNING_MODE" = developer-id ]; then
    IDENTITY="$REQUESTED_IDENTITY"
    if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
        printf '%s\n' "error: Developer ID packaging requires OMO_USAGE_CODESIGN_IDENTITY" >&2
        exit 64
    fi
    if [ -z "$TEAM_IDENTIFIER" ]; then
        printf '%s\n' "error: Developer ID packaging requires OMO_USAGE_TEAM_IDENTIFIER" >&2
        exit 64
    fi
else
    IDENTITY=-
    if [ -n "$TEAM_IDENTIFIER" ]; then
        printf '%s\n' "error: OMO_USAGE_TEAM_IDENTIFIER is not accepted for ad-hoc packaging" >&2
        exit 64
    fi
fi

MARKETING_VERSION="$(version_setting MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$(version_setting CURRENT_PROJECT_VERSION)"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

if [ "$PLAN" = yes ]; then
    printf 'MARKETING_VERSION=%s\n' "$MARKETING_VERSION"
    printf 'CURRENT_PROJECT_VERSION=%s\n' "$CURRENT_PROJECT_VERSION"
    printf 'SOURCE_COMMIT=%s\n' "$SOURCE_COMMIT"
    printf 'SIGNING_MODE=%s\n' "$SIGNING_MODE"
    printf 'SIGNING_IDENTITY=%s\n' "$IDENTITY"
    printf 'QA_FIXTURES=%s\n' "$QA_FIXTURES"
    if [ "$SIGNING_MODE" = developer-id ]; then
        printf 'TEAM_IDENTIFIER=%s\n' "$TEAM_IDENTIFIER"
        printf 'ENTITLEMENTS=%s\n' "$ENTITLEMENTS_TEMPLATE"
        printf 'KVS_IDENTIFIER=%s.com.omo.usage\n' "$TEAM_IDENTIFIER"
        printf 'HARDENED_RUNTIME=yes\nSECURE_TIMESTAMP=yes\nCLOUD_KVS_AVAILABLE=yes\n'
    else
        printf 'TEAM_IDENTIFIER=\nENTITLEMENTS=\nKVS_IDENTIFIER=\n'
        printf 'HARDENED_RUNTIME=no\nSECURE_TIMESTAMP=no\nCLOUD_KVS_AVAILABLE=no\n'
    fi
    exit 0
fi

cleanup() {
    [ -z "$TEMP_ENTITLEMENTS" ] || rm -f "$TEMP_ENTITLEMENTS"
    [ -z "$EXTRACTED_ENTITLEMENTS" ] || rm -f "$EXTRACTED_ENTITLEMENTS"
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT"
if [ "$QA_FIXTURES" = yes ]; then
    swift build -c release -Xswiftc -DOMO_USAGE_FIXTURES
else
    swift build -c release
fi

# Use the checksum-verified SwiftPM artifact, not a globally installed framework.
ACTUAL_SPARKLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$SPARKLE_FRAMEWORK/Resources/Info.plist")"
if [ "$ACTUAL_SPARKLE_VERSION" != "$SPARKLE_VERSION" ]; then
    printf 'error: expected Sparkle %s, found %s\n' "$SPARKLE_VERSION" "$ACTUAL_SPARKLE_VERSION" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/ProviderIcons" "$CONTENTS/Frameworks"
# ditto preserves the versioned framework's symlinks and executable permissions.
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"
cp ".build/release/OmoUsage" "$CONTENTS/MacOS/OmoUsage"
cp "Config/Info.plist" "$CONTENTS/Info.plist"
# SwiftPM does not expand Xcode build settings in the copied plist.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleDevelopmentRegion en" \
    -c "Set :CFBundleExecutable OmoUsage" \
    -c "Set :CFBundleIdentifier com.omo.usage" \
    -c "Set :CFBundleName OmoUsage" \
    -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" \
    -c "Set :OmoUsageSourceCommit $SOURCE_COMMIT" \
    "$CONTENTS/Info.plist"
cp Sources/OmoUsage/Resources/ProviderIcons/*.svg "$CONTENTS/Resources/ProviderIcons/"
cp Sources/OmoUsage/Resources/AppIcon.svg "$CONTENTS/Resources/AppIcon.svg"
cp Sources/OmoUsage/Resources/WebDashboard/index.html "$CONTENTS/Resources/index.html"

rm -rf "$ICONSET"
swift Scripts/generate-app-icon.swift Sources/OmoUsage/Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/OmoUsage.icns"
rm -rf "$ICONSET"

if [ "$SIGNING_MODE" = developer-id ]; then
    TEMP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/OmoUsage-entitlements.XXXXXX.plist")"
    EXTRACTED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/OmoUsage-signed-entitlements.XXXXXX.plist")"
    cp "$ENTITLEMENTS_TEMPLATE" "$TEMP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy \
        -c "Set :com.apple.developer.ubiquity-kvstore-identifier ${TEAM_IDENTIFIER}.com.omo.usage" \
        "$TEMP_ENTITLEMENTS"
    sh Scripts/sign-app.sh --developer-id "$APP" "$IDENTITY" "$TEMP_ENTITLEMENTS"
    codesign --verify --deep --strict --verbose=2 "$APP"
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
    sh Scripts/sign-app.sh --adhoc "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi
printf '%s\n' "$APP"
