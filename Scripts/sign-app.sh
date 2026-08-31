#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 --adhoc app | --developer-id app identity entitlements" >&2
    exit 64
}

case "${1-}" in
    --adhoc)
        [ "$#" -eq 2 ] || usage
        codesign --force --deep --sign - "$2"
        ;;
    --developer-id)
        [ "$#" -eq 4 ] || usage
        APP="$2"
        IDENTITY="$3"
        ENTITLEMENTS="$4"
        if [ -n "${OMO_USAGE_SIGNING_KEYCHAIN:-}" ]; then
            codesign --force --deep --sign "$IDENTITY" --options runtime \
                --timestamp --entitlements "$ENTITLEMENTS" \
                --keychain "$OMO_USAGE_SIGNING_KEYCHAIN" "$APP"
        else
            codesign --force --deep --sign "$IDENTITY" --options runtime \
                --timestamp --entitlements "$ENTITLEMENTS" "$APP"
        fi
        ;;
    *) usage ;;
esac
