#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
    printf 'core boundary: %s\n' "$1" >&2
    exit 1
}

PACKAGE_JSON=$(mktemp "${TMPDIR:-/tmp}/omousage-package.XXXXXX")
DRIVER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omousage-core-driver.XXXXXX")
trap 'rm -f "$PACKAGE_JSON"; rm -rf "$DRIVER_DIR"' EXIT
swift package dump-package > "$PACKAGE_JSON"
python3 - "$PACKAGE_JSON" <<'PY'
import json, sys
package = json.load(open(sys.argv[1]))
targets = {target["name"]: target for target in package["targets"]}
core = targets.get("OmoUsageCore")
if core is None:
    raise SystemExit("core boundary: SwiftPM OmoUsageCore target is absent")
if core.get("path") != "Sources/OmoUsageCore":
    raise SystemExit("core boundary: SwiftPM Core must own Sources/OmoUsageCore")
desktop_dependencies = {
    item.get("byName", [None])[0]
    for item in targets["OmoUsage"].get("dependencies", [])
}
if "OmoUsageCore" not in desktop_dependencies:
    raise SystemExit("core boundary: SwiftPM desktop does not depend on Core")
test_dependencies = {
    item.get("byName", [None])[0]
    for item in targets["OmoUsageTests"].get("dependencies", [])
}
if "OmoUsageCore" not in test_dependencies:
    raise SystemExit("core boundary: SwiftPM tests cannot consume Core directly")
PY

python3 - project.yml <<'PY'
import os
import sys
text = open(sys.argv[1]).read()
required = [
    "  OmoUsageCore:\n",
    "      - path: Sources/OmoUsageCore\n",
    "      - target: OmoUsageCore\n",
    "      - path: Sources/OmoUsage/Mobile\n",
]
for token in required:
    if token not in text:
        raise SystemExit(f"core boundary: project.yml is missing {token.strip()}")
mobile = text.split("  OmoUsageMobile:\n", 1)[1].split("\nschemes:", 1)[0]
sources = mobile.split("    sources:\n", 1)[1].split("    entitlements:\n", 1)[0]
compiled = []
for entry in sources.split("      - path: ")[1:]:
    path, _, options = entry.partition("\n")
    if "buildPhase: resources" not in {line.strip() for line in options.splitlines()}:
        compiled.append(path)
        continue
    if not path.startswith("Sources/OmoUsage/Resources/"):
        raise SystemExit(f"core boundary: mobile resource {path} must live under Sources/OmoUsage/Resources")
    for root, _, files in os.walk(path):
        if any(name.endswith(".swift") for name in files):
            raise SystemExit(f"core boundary: mobile resource {root} contains Swift sources")
if compiled != ["Sources/OmoUsage/Mobile"]:
    raise SystemExit("core boundary: mobile must compile only Mobile sources")
if "- target: OmoUsageCore" not in mobile:
    raise SystemExit("core boundary: Xcode mobile does not depend on Core")
desktop = text.split("  OmoUsage:\n", 1)[1].split("\n  OmoUsageCore:\n", 1)[0]
if "- target: OmoUsageCore" not in desktop:
    raise SystemExit("core boundary: Xcode desktop does not depend on Core")
PY

forbidden_imports='^(import|@_exported import) (AppKit|Security|SQLite3|LocalAuthentication)([[:space:]]|$)'
if rg -n "$forbidden_imports" Sources/OmoUsageCore Sources/OmoUsage/Mobile; then
    fail "Core or Mobile imports a forbidden framework"
fi
if find Sources/OmoUsageCore Sources/OmoUsage/Mobile -type f | rg '/(Credentials|Providers|Diagnostics|Settings)/'; then
    fail "Core or Mobile includes a forbidden source folder"
fi

PBX=OmoUsage.xcodeproj/project.pbxproj
[ -f "$PBX" ] || fail "generated Xcode project is absent"
rg -q 'OmoUsageCore' "$PBX" || fail "generated Xcode project has no Core target"

swift build --target OmoUsageCore >/dev/null
BIN_PATH=$(swift build --show-bin-path)
cat > "$DRIVER_DIR/main.swift" <<'SWIFT'
import Foundation
import OmoUsageCore

let checkedAt = Date(timeIntervalSince1970: 1_786_867_200)
let successAt = checkedAt.addingTimeInterval(-3_600)
let snapshot = DashboardSnapshot(
    providers: [
        ProviderUsage(
            provider: .openrouter,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "typed",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "spend",
                            title: "Last 30 days",
                            period: .extra,
                            metric: .spend(amount: 3, currency: .usd)
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: checkedAt,
            refreshFailure: .network
        )
    ],
    generatedAt: checkedAt,
    lastRefreshAttemptAt: checkedAt,
    oldestDisplayedSuccessAt: successAt
)
let decoded = try UsageSnapshotCodec.decode(
    UsageSnapshotCodec.encode(snapshot)
)
let freshness = MobileFreshnessPresentation(
    snapshot: decoded,
    now: checkedAt.addingTimeInterval(15 * 60),
    hasSyncIssue: false
)
precondition(UsageSnapshotCodec.currentVersion == 4)
precondition(decoded.providers[0].groups[0].meters[0].metric.kind == .spend)
precondition(decoded.providers[0].freshness == .stale)
precondition(freshness.age == .stale)
print("schema=4 metric=spend providerFreshness=stale mobileFreshness=stale")
SWIFT
# The native build system emits the module and one prelinked Core object
# beside the products; the legacy layout keeps per-file objects and a
# Modules directory.
if [ -f "$BIN_PATH/OmoUsageCore.o" ] && [ -d "$BIN_PATH/OmoUsageCore.swiftmodule" ]; then
    set -- -I "$BIN_PATH" "$BIN_PATH/OmoUsageCore.o"
else
    set -- -I "$BIN_PATH/Modules" \
        "$BIN_PATH/OmoUsageCore.build/AppLanguage.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/AppStrings.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/ProviderTextLocalization.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/DashboardSnapshot.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/ProviderID.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/ProviderMark.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/ProviderVisualStyle.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/UsageModels.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/ProviderDisplayOrder.swift.o" \
        "$BIN_PATH/OmoUsageCore.build/UsageSnapshotSync.swift.o"
fi
swiftc "$@" "$DRIVER_DIR/main.swift" -o "$DRIVER_DIR/core-import-driver"
"$DRIVER_DIR/core-import-driver"

printf 'core boundary: PASS\n'
