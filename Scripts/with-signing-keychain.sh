#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 command [argument ...]" >&2
    exit 64
}
[ "$#" -gt 0 ] || usage

required() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || { printf 'error: %s is required\n' "$1" >&2; exit 64; }
}
for name in CERTIFICATE_P12_BASE64 CERTIFICATE_PASSWORD NOTARY_APPLE_ID \
    NOTARY_PASSWORD OMO_USAGE_TEAM_IDENTIFIER OMO_USAGE_NOTARY_PROFILE; do
    required "$name"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/omousage-signing.XXXXXX")"
KEYCHAIN="$WORK/release.keychain-db"
CERTIFICATE="$WORK/certificate.p12"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"

cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

umask 077
printf '%s' "$CERTIFICATE_P12_BASE64" | /usr/bin/base64 -D > "$CERTIFICATE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
xcrun notarytool store-credentials "$OMO_USAGE_NOTARY_PROFILE" \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$OMO_USAGE_TEAM_IDENTIFIER" \
    --password "$NOTARY_PASSWORD" --keychain "$KEYCHAIN"

rm -f "$CERTIFICATE"
export OMO_USAGE_NOTARY_KEYCHAIN="$KEYCHAIN"
export OMO_USAGE_SIGNING_KEYCHAIN="$KEYCHAIN"
"$@"
