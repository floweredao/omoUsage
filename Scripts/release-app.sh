#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_CONFIGURATION="$ROOT/Config/Version.xcconfig"
APP="$ROOT/dist/OmoUsage.app"
DRY_RUN=no

usage() {
    printf '%s\n' "usage: $0 [--dry-run]" >&2
    exit 64
}

case "$#" in
    0) ;;
    1) [ "$1" = "--dry-run" ] || usage; DRY_RUN=yes ;;
    *) usage ;;
esac

required() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        printf 'error: %s is required\n' "$1" >&2
        exit 64
    fi
}

for name in OMO_USAGE_CODESIGN_IDENTITY OMO_USAGE_TEAM_IDENTIFIER \
    OMO_USAGE_NOTARY_PROFILE OMO_USAGE_RELEASE_REF; do
    required "$name"
done
IDENTITY="$OMO_USAGE_CODESIGN_IDENTITY"
TEAM_IDENTIFIER="$OMO_USAGE_TEAM_IDENTIFIER"
NOTARY_PROFILE="$OMO_USAGE_NOTARY_PROFILE"
NOTARY_KEYCHAIN="${OMO_USAGE_NOTARY_KEYCHAIN:-}"
RELEASE_REF="$OMO_USAGE_RELEASE_REF"

case "$IDENTITY" in
    "Developer ID Application: "*) ;;
    *) printf '%s\n' 'error: OMO_USAGE_CODESIGN_IDENTITY must be a Developer ID Application identity' >&2; exit 64 ;;
esac
case "$TEAM_IDENTIFIER" in
    *[!A-Za-z0-9]*|'') printf '%s\n' 'error: invalid OMO_USAGE_TEAM_IDENTIFIER' >&2; exit 64 ;;
esac
case "$NOTARY_PROFILE" in
    *[!A-Za-z0-9._-]*|'') printf '%s\n' 'error: invalid OMO_USAGE_NOTARY_PROFILE' >&2; exit 64 ;;
esac

version_setting() {
    value="$(awk -F ' = ' -v key="$1" '$1 == key { print $2; exit }' "$VERSION_CONFIGURATION")"
    [ -n "$value" ] || { printf 'error: missing %s\n' "$1" >&2; exit 1; }
    printf '%s\n' "$value"
}

VERSION="$(version_setting MARKETING_VERSION)"
BUILD="$(version_setting CURRENT_PROJECT_VERSION)"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
EXPECTED_REF="refs/tags/v$VERSION"
if [ "$RELEASE_REF" != "$EXPECTED_REF" ]; then
    printf 'error: release ref must be %s, got %s\n' "$EXPECTED_REF" "$RELEASE_REF" >&2
    exit 64
fi

ZIP="$ROOT/dist/OmoUsage-$VERSION.zip"
CHECKSUM="$ROOT/dist/OmoUsage-$VERSION.sha256"
MANIFEST="$ROOT/dist/OmoUsage-$VERSION-manifest.txt"
NOTARY_KEYCHAIN_ARGUMENT=""
if [ -n "$NOTARY_KEYCHAIN" ]; then
    NOTARY_KEYCHAIN_ARGUMENT=" --keychain $NOTARY_KEYCHAIN"
fi

print_plan() {
    printf 'SOURCE_COMMIT=%s\nVERSION=%s\nBUILD=%s\nRELEASE_REF=%s\n' \
        "$SOURCE_COMMIT" "$VERSION" "$BUILD" "$RELEASE_REF"
    printf '01 OMO_USAGE_CODESIGN_IDENTITY="%s" OMO_USAGE_TEAM_IDENTIFIER=%s sh Scripts/package-app.sh --developer-id\n' "$IDENTITY" "$TEAM_IDENTIFIER"
    printf '02 codesign --verify --deep --strict --verbose=2 %s\n' "$APP"
    printf '03 ditto -c -k --keepParent %s %s\n' "$APP" "$ZIP"
    printf '04 xcrun notarytool submit %s --keychain-profile %s%s --wait\n' "$ZIP" "$NOTARY_PROFILE" "$NOTARY_KEYCHAIN_ARGUMENT"
    printf '05 xcrun stapler staple %s\n' "$APP"
    printf '06 xcrun stapler validate %s\n' "$APP"
    printf '07 spctl --assess --type execute --verbose=2 %s\n' "$APP"
    printf '08 ditto -c -k --keepParent %s %s\n' "$APP" "$ZIP"
    printf '09 shasum -a 256 %s > %s\n' "$ZIP" "$CHECKSUM"
    printf '10 MANIFEST=%s\n' "$MANIFEST"
}

if [ "$DRY_RUN" = yes ]; then
    print_plan
    exit 0
fi

cd "$ROOT"
[ -z "$(git status --porcelain)" ] || {
    printf '%s\n' 'error: trusted releases require a clean tracked worktree' >&2
    exit 1
}
TAG_COMMIT="$(git rev-parse "$RELEASE_REF^{commit}" 2>/dev/null)" || {
    printf 'error: release tag does not exist locally: %s\n' "$RELEASE_REF" >&2
    exit 1
}
[ "$TAG_COMMIT" = "$SOURCE_COMMIT" ] || {
    printf '%s\n' 'error: release tag does not point at HEAD' >&2
    exit 1
}
[ -n "$NOTARY_KEYCHAIN" ] || {
    printf '%s\n' 'error: OMO_USAGE_NOTARY_KEYCHAIN is required for trusted release execution' >&2
    exit 64
}

rm -f "$ZIP" "$CHECKSUM" "$MANIFEST"
OMO_USAGE_CODESIGN_IDENTITY="$IDENTITY" OMO_USAGE_TEAM_IDENTIFIER="$TEAM_IDENTIFIER" \
    sh Scripts/package-app.sh --developer-id
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" \
    --keychain "$NOTARY_KEYCHAIN" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
ARTIFACT_SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
printf '%s  %s\n' "$ARTIFACT_SHA256" "$(basename "$ZIP")" > "$CHECKSUM"
cat > "$MANIFEST" <<EOF_MANIFEST
PRODUCT=OmoUsage
MARKETING_VERSION=$VERSION
CURRENT_PROJECT_VERSION=$BUILD
SOURCE_COMMIT=$SOURCE_COMMIT
RELEASE_REF=$RELEASE_REF
ARTIFACT=$(basename "$ZIP")
ARTIFACT_SHA256=$ARTIFACT_SHA256
SIGNING=Developer ID Application
HARDENED_RUNTIME=yes
SECURE_TIMESTAMP=yes
NOTARIZED=yes
STAPLED=yes
GATEKEEPER_ASSESSED=yes
EOF_MANIFEST
printf '%s\n%s\n%s\n' "$ZIP" "$CHECKSUM" "$MANIFEST"
