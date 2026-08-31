#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

usage() {
    printf '%s\n' 'usage: sh Scripts/ci-check.sh [all|policy|swiftpm|xcode|package-smoke]' >&2
    exit 64
}

policy() {
    sh Scripts/check-repository-hygiene.sh
    sh Scripts/check-core-boundary.sh
    sh Scripts/check-source-policy.sh
    command -v xcodegen >/dev/null 2>&1 || {
        printf '%s\n' 'ci: xcodegen is required' >&2
        exit 1
    }
    xcodegen generate
    git diff --exit-code -- OmoUsage.xcodeproj
}

swiftpm() {
    swift test
    swift build -c debug
    swift build -c release
}

xcode() {
    DERIVED_DATA=$(mktemp -d "${TMPDIR:-/tmp}/omousage-derived-data.XXXXXX")
    trap 'rm -rf "$DERIVED_DATA"' EXIT HUP INT TERM

    xcodebuild -project OmoUsage.xcodeproj -scheme OmoUsage \
        -configuration Debug -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project OmoUsage.xcodeproj -scheme OmoUsageMobile \
        -configuration Debug \
        -destination 'generic/platform=macOS,variant=Mac Catalyst' \
        -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project OmoUsage.xcodeproj -target OmoUsageMobile \
        -configuration Debug -sdk iphoneos \
        SYMROOT="$DERIVED_DATA/Products" OBJROOT="$DERIVED_DATA/Intermediates" \
        SUPPORTED_PLATFORMS=iphoneos SUPPORTS_MACCATALYST=NO \
        CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project OmoUsage.xcodeproj -target OmoUsageMobile \
        -configuration Debug -sdk iphonesimulator \
        SYMROOT="$DERIVED_DATA/Products" OBJROOT="$DERIVED_DATA/Intermediates" \
        SUPPORTED_PLATFORMS=iphonesimulator SUPPORTS_MACCATALYST=NO \
        CODE_SIGNING_ALLOWED=NO build

    rm -rf "$DERIVED_DATA"
    trap - EXIT HUP INT TERM
}

package_smoke() {
    swift test --filter PackageSmokeTests
}

case "${1-all}" in
    all)
        policy
        swiftpm
        xcode
        package_smoke
        ;;
    policy)
        policy
        ;;
    swiftpm)
        swiftpm
        ;;
    xcode)
        xcode
        ;;
    package-smoke)
        package_smoke
        ;;
    *)
        usage
        ;;
esac
