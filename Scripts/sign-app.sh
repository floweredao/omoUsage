#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 --adhoc app | --developer-id app identity entitlements" >&2
    exit 64
}

MODE="${1-}"
case "$MODE" in
    --adhoc)
        [ "$#" -eq 2 ] || usage
        APP="$2"
        IDENTITY=-
        ;;
    --developer-id)
        [ "$#" -eq 4 ] || usage
        APP="$2"
        IDENTITY="$3"
        ENTITLEMENTS="$4"
        ;;
    *) usage ;;
esac

sign() {
    target="$1"
    shift
    if [ "$MODE" = --developer-id ]; then
        set -- --options runtime --timestamp "$@"
        if [ -n "${OMO_USAGE_SIGNING_KEYCHAIN:-}" ]; then
            set -- --keychain "$OMO_USAGE_SIGNING_KEYCHAIN" "$@"
        fi
    fi
    codesign --force --sign "$IDENTITY" "$@" "$target"
}

# Sparkle's nested code must be signed before its enclosing framework/app.
# Keep helper entitlements (especially Downloader's), never the host's KVS.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FRAMEWORK" ]; then
    for component in \
        Versions/B/XPCServices/Installer.xpc \
        Versions/B/XPCServices/Downloader.xpc \
        Versions/B/Autoupdate \
        Versions/B/Updater.app; do
        sign "$FRAMEWORK/$component" --preserve-metadata=entitlements
    done
    sign "$FRAMEWORK" --preserve-metadata=entitlements
fi

if [ "$MODE" = --developer-id ]; then
    sign "$APP" --entitlements "$ENTITLEMENTS"
else
    sign "$APP"
fi
