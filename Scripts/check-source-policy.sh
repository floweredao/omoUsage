#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'source policy: %s\n' "$1" >&2
    exit 1
}

fixed_waits='(Task|Thread)\.sleep|usleep\(|nanosleep\(|asyncAfter\(|(^|[^[:alnum:]_])sleep[[:space:]]+[0-9]'
# git grep searches tracked and untracked, non-ignored files, like ripgrep,
# without requiring ripgrep to be installed.
if git grep -n -I -E --untracked -e "$fixed_waits" -- 'Tests/*.swift'; then
    fail 'tests contain a fixed sleep or delayed dispatch'
fi

secret_material='AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
if git grep -n -I -E --untracked -e "$secret_material" -- . \
    ':!dist' ':!OmoUsage.xcodeproj'; then
    fail 'repository contains material resembling a credential or private key'
fi

snapshot_fields='(let|var)[[:space:]]+(accessToken|refreshToken|apiKey|cookie|credential|authorization|password|secret)[[:space:]]*:'
if grep -n -E "$snapshot_fields" \
    Sources/OmoUsageCore/Models/DashboardSnapshot.swift \
    Sources/OmoUsageCore/Sync/UsageSnapshotSync.swift; then
    fail 'mobile snapshot schema contains a private-data field'
fi

printf '%s\n' 'source policy: PASS'
