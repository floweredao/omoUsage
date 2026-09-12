#!/bin/sh
set -eu

# Official Sparkle 2.9.6 release archive (not the SwiftPM ZIP).
SPARKLE_SHA256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
APP=""
SPARKLE_ARCHIVE=""
KEY_ACCOUNT=""
DOWNLOAD_URL_PREFIX=""
OUTPUT=""
STAGING=""

usage() {
    printf '%s\n' "usage: $0 --app app --sparkle-archive Sparkle-2.9.6.tar.xz --key-account account --download-url-prefix https://host/releases/version/ --output-dir new-directory" >&2
    exit 64
}

while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] && [ -n "$2" ] || usage
    case "$1" in
        --app) [ -z "$APP" ] || usage; APP="$2" ;;
        --sparkle-archive) [ -z "$SPARKLE_ARCHIVE" ] || usage; SPARKLE_ARCHIVE="$2" ;;
        --key-account) [ -z "$KEY_ACCOUNT" ] || usage; KEY_ACCOUNT="$2" ;;
        --download-url-prefix) [ -z "$DOWNLOAD_URL_PREFIX" ] || usage; DOWNLOAD_URL_PREFIX="$2" ;;
        --output-dir) [ -z "$OUTPUT" ] || usage; OUTPUT="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$APP" ] && [ -n "$SPARKLE_ARCHIVE" ] && [ -n "$KEY_ACCOUNT" ] \
    && [ -n "$DOWNLOAD_URL_PREFIX" ] && [ -n "$OUTPUT" ] || usage
case "$DOWNLOAD_URL_PREFIX" in
    *'?'*|*'#'*|*[[:space:]]*) usage ;;
    https://?*/*/) ;;
    *) usage ;;
esac
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
    printf '%s\n' 'error: output directory must not already exist' >&2
    exit 64
fi

ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
    printf '%s\n' 'error: tools archive does not match the official Sparkle 2.9.6 SHA-256' >&2
    exit 65
fi

INFO="$APP/Contents/Info.plist"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
case "$VERSION" in *[!A-Za-z0-9.+-]*|'') usage ;; esac
case "$BUILD" in *[!A-Za-z0-9.+-]*|'') usage ;; esac
codesign --verify --deep --strict --verbose=2 "$APP"

OUTPUT_PARENT="$(CDPATH= cd -- "$(dirname -- "$OUTPUT")" && pwd)"
OUTPUT="$OUTPUT_PARENT/$(basename -- "$OUTPUT")"
cleanup() {
    [ -z "$STAGING" ] || rm -rf "$STAGING"
}
trap cleanup EXIT HUP INT TERM
STAGING="$(mktemp -d "$OUTPUT_PARENT/.omo-update.XXXXXX")"
mkdir "$STAGING/tools" "$STAGING/release"
tar -xf "$SPARKLE_ARCHIVE" -C "$STAGING/tools"
TOOLS="$STAGING/tools/bin"
# -p only reads an existing key. Never generate/import/export keys here, and
# never fall back to Sparkle's default global account.
ACCOUNT_PUBLIC_KEY="$("$TOOLS/generate_keys" --account "$KEY_ACCOUNT" -p)"
if [ -z "$PUBLIC_KEY" ] || [ "$ACCOUNT_PUBLIC_KEY" != "$PUBLIC_KEY" ]; then
    printf '%s\n' 'error: selected Sparkle account does not match the app SUPublicEDKey' >&2
    exit 65
fi

ARCHIVE_NAME="OmoUsage-$VERSION.zip"
ARCHIVE="$STAGING/release/$ARCHIVE_NAME"
FEED="$STAGING/release/appcast.xml"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
"$TOOLS/generate_appcast" --account "$KEY_ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" -o "$FEED" "$STAGING/release"
xmllint --noout "$FEED"
SIGNATURE="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$FEED")"
[ -n "$SIGNATURE" ] || { printf '%s\n' 'error: appcast has no archive signature' >&2; exit 65; }
"$TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$ARCHIVE" "$SIGNATURE"
# Sign the feed too, even when the app does not require signed feeds yet.
"$TOOLS/sign_update" --account "$KEY_ACCOUNT" "$FEED"
"$TOOLS/sign_update" --account "$KEY_ACCOUNT" --verify "$FEED"
(
    cd "$STAGING/release"
    shasum -a 256 "$ARCHIVE_NAME" appcast.xml > SHA256SUMS
)
mv "$STAGING/release" "$OUTPUT"
printf '%s\n' "$OUTPUT/$ARCHIVE_NAME" "$OUTPUT/appcast.xml" "$OUTPUT/SHA256SUMS"
