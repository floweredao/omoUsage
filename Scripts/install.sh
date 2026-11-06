#!/bin/sh
# Install or update OmoUsage from its GitHub release:
#   curl -fsSL https://github.com/floweredao/omoUsage/releases/latest/download/install.sh | sh
# A file downloaded by curl carries no quarantine attribute, so the installed
# app opens without the Gatekeeper "Open Anyway" step.
set -eu

BUNDLE_ID=com.omo.usage
BASE="${OMO_USAGE_RELEASE_BASE_URL:-https://github.com/floweredao/omoUsage/releases}"
VERSION="${OMO_USAGE_VERSION:-}"
INSTALL_DIR="${OMO_USAGE_INSTALL_DIR:-}"
NO_LAUNCH="${OMO_USAGE_NO_LAUNCH:-}"

fail() {
    printf 'OmoUsage install: %s\n' "$1" >&2
    exit 1
}

[ "$(uname -s)" = Darwin ] || fail 'macOS is required'

if [ -z "$VERSION" ]; then
    LATEST="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$BASE/latest")" \
        || fail 'could not find the latest release'
    VERSION="${LATEST##*/tag/v}"
fi
case "$VERSION" in
    *[!A-Za-z0-9.+-]*|'') fail "invalid version: $VERSION" ;;
esac

if [ -z "$INSTALL_DIR" ]; then
    if [ -w /Applications ]; then
        INSTALL_DIR=/Applications
    else
        INSTALL_DIR="$HOME/Applications"
    fi
fi
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/OmoUsage.app"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

ARCHIVE="OmoUsage-$VERSION.zip"
printf 'Downloading OmoUsage %s...\n' "$VERSION"
curl -fsSL -o "$WORK/$ARCHIVE" "$BASE/download/v$VERSION/$ARCHIVE" \
    || fail "could not download $ARCHIVE"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE/download/v$VERSION/SHA256SUMS" \
    || fail 'could not download SHA256SUMS'
(
    cd "$WORK"
    grep "  $ARCHIVE\$" SHA256SUMS > archive.sha256 || exit 1
    shasum -a 256 -c archive.sha256 > /dev/null
) || fail "checksum mismatch for $ARCHIVE"

mkdir "$WORK/unpacked"
ditto -x -k "$WORK/$ARCHIVE" "$WORK/unpacked"
APP="$WORK/unpacked/OmoUsage.app"
[ -d "$APP" ] || fail 'the archive does not contain OmoUsage.app'
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
    || fail 'unexpected bundle identifier'
codesign --verify --deep --strict "$APP" 2> /dev/null || fail 'code signature is invalid'

if pgrep -f "$DEST/Contents/MacOS/OmoUsage" > /dev/null 2>&1; then
    printf '%s\n' 'Quitting the running OmoUsage...'
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" > /dev/null 2>&1 || true
    tries=0
    while pgrep -f "$DEST/Contents/MacOS/OmoUsage" > /dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -le 20 ] || fail 'OmoUsage is still running; quit it and try again'
        sleep 0.5
    done
fi

rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2> /dev/null || true
printf 'Installed OmoUsage %s in %s\n' "$VERSION" "$INSTALL_DIR"

if [ -z "$NO_LAUNCH" ]; then
    open "$DEST"
fi
