#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'source policy: %s\n' "$1" >&2
    exit 1
}

fixed_waits='(Task|Thread)\.sleep|usleep\(|nanosleep\(|asyncAfter\(|(^|[^[:alnum:]_])sleep[[:space:]]+[0-9]'
if rg -n "$fixed_waits" Tests --glob '*.swift'; then
    fail 'tests contain a fixed sleep or delayed dispatch'
fi

secret_material='AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
if rg -n "$secret_material" . \
    --glob '!.git/**' --glob '!.build/**' --glob '!dist/**' \
    --glob '!OmoUsage.xcodeproj/**'; then
    fail 'repository contains material resembling a credential or private key'
fi

snapshot_fields='(let|var)[[:space:]]+(accessToken|refreshToken|apiKey|cookie|credential|authorization|password|secret)[[:space:]]*:'
if rg -n "$snapshot_fields" \
    Sources/OmoUsageCore/Models/DashboardSnapshot.swift \
    Sources/OmoUsageCore/Sync/UsageSnapshotSync.swift; then
    fail 'mobile snapshot schema contains a private-data field'
fi

printf '%s\n' 'source policy: PASS'
