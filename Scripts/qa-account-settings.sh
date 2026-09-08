#!/bin/sh
# Native, isolated account-settings QA. Requires an integrated fixture build,
# Accessibility and Screen Recording. Never touches the user's account store.
# See qa-account-settings-driver.swift for the fixture and AX contracts.
set -eu
umask 077

usage() {
    printf '%s\n' 'Usage: sh Scripts/qa-account-settings.sh --scenario ordering|tiers|gating|accounts|aliases|identity|all --evidence-dir PATH [--app-path PATH/OmoUsage.app]'
}
scenario= evidence_dir= app=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --scenario|--evidence-dir|--app-path)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            case "$1" in
                --scenario) scenario=$2 ;;
                --evidence-dir) evidence_dir=$2 ;;
                --app-path) app=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
done
case "$scenario" in
    ordering|tiers|gating|accounts|aliases|identity|all) ;;
    *) usage >&2; exit 64 ;;
esac
[ -n "$evidence_dir" ] || { usage >&2; exit 64; }
repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$evidence_dir"
evidence_dir=$(CDPATH= cd -- "$evidence_dir" && pwd)
# Evidence is never put under a fixture root that teardown will remove.
case "$evidence_dir" in
    /tmp/omousage-companion-qa-*|/private/tmp/omousage-companion-qa-*)
        printf '%s\n' 'Evidence must be outside the disposable fixture root.' >&2; exit 64 ;;
esac
# Never clobber evidence from an earlier run.
[ ! -e "$evidence_dir/action-log.txt" ] || {
    printf 'Evidence directory already contains a run: %s\n' "$evidence_dir" >&2; exit 64;
}
log="$evidence_dir/action-log.txt"
cleanup_report="$evidence_dir/cleanup.txt"
: > "$log"
: > "$cleanup_report"
app_pid= fixture_root= driver_root= driver= current_scenario=
cleanup_failed=0

note() { printf '%s\n' "$*" | tee -a "$log"; }

stop_app() {
    [ -n "$app_pid" ] || return 0
    # app_pid is only ever assigned from this shell's own $!, never pgrep.
    if kill -0 "$app_pid" 2>/dev/null; then
        if ! "$driver" --action terminate --pid "$app_pid" --timeout 10 >> "$cleanup_report" 2>&1; then
            cleanup_failed=1
        fi
    fi
    if wait "$app_pid" 2>/dev/null; then
        printf 'reaped owned pid=%s status=0\n' "$app_pid" >> "$cleanup_report"
    else
        printf 'reaped owned pid=%s after requested termination\n' "$app_pid" >> "$cleanup_report"
    fi
    if kill -0 "$app_pid" 2>/dev/null; then
        printf 'FAIL owned process remains pid=%s\n' "$app_pid" >> "$cleanup_report"
        cleanup_failed=1
    fi
    app_pid=
}

remove_fixture() {
    [ -n "$fixture_root" ] || return 0
    suite="CompanionAccountQA-$(basename "$fixture_root")"
    # defaults delete failing is only acceptable if read confirms absence.
    if defaults read "$suite" >/dev/null 2>&1; then
        if ! defaults delete "$suite" >> "$cleanup_report" 2>&1; then
            printf 'FAIL deleting defaults suite=%s\n' "$suite" >> "$cleanup_report"
            cleanup_failed=1
        fi
    fi
    if defaults read "$suite" >/dev/null 2>&1; then
        printf 'FAIL defaults remain suite=%s\n' "$suite" >> "$cleanup_report"
        cleanup_failed=1
    else
        printf 'PASS fixture-defaults-absent suite=%s\n' "$suite" >> "$cleanup_report"
    fi
    case "$fixture_root" in
        /tmp/omousage-companion-qa-*)
            if ! rm -rf -- "$fixture_root"; then cleanup_failed=1; fi ;;
        *) printf 'FAIL unsafe cleanup path\n' >> "$cleanup_report"; cleanup_failed=1 ;;
    esac
    if [ -e "$fixture_root" ]; then
        printf 'FAIL fixture remains root=%s\n' "$fixture_root" >> "$cleanup_report"
        cleanup_failed=1
    else
        printf 'PASS fixture-files-absent root=%s\n' "$fixture_root" >> "$cleanup_report"
    fi
    fixture_root=
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    stop_app
    remove_fixture
    if [ -n "$driver_root" ]; then
        if ! rm -rf -- "$driver_root"; then cleanup_failed=1; fi
        if [ -e "$driver_root" ]; then cleanup_failed=1
        else printf 'PASS driver-files-absent root=%s\n' "$driver_root" >> "$cleanup_report"; fi
    fi
    [ "$cleanup_failed" -eq 0 ] || status=1
    printf 'exit_status=%s cleanup_failures=%s completed=%s\n' "$status" "$cleanup_failed" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$cleanup_report"
    if [ "$status" -eq 0 ]; then
        printf 'PASS scenario=%s evidence=%s cleanup=verified\n' "$scenario" "$evidence_dir"
    else
        printf 'FAIL scenario=%s evidence=%s exit=%s\n' "$scenario" "$evidence_dir" "$status" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

note "started=$(date -u +%Y-%m-%dT%H:%M:%SZ) scenario=$scenario"
note "commit=$(git -C "$repo_root" rev-parse HEAD)"
driver_root=$(mktemp -d /tmp/omousage-account-settings-driver-XXXXXX)
driver="$driver_root/qa-driver"
note 'compile: env -u DEVELOPER_DIR /usr/bin/swiftc -O -o <temporary-driver> Scripts/qa-account-settings-driver.swift'
if ! env -u DEVELOPER_DIR /usr/bin/swiftc -O -o "$driver" "$repo_root/Scripts/qa-account-settings-driver.swift" > "$evidence_dir/driver-compile.log" 2>&1; then
    printf 'Driver compile failed; see %s\n' "$evidence_dir/driver-compile.log" >&2
    exit 1
fi
"$driver" --action preflight > "$evidence_dir/permissions.txt" 2>&1 || {
    printf 'Native permissions denied; see %s\n' "$evidence_dir/permissions.txt" >&2; exit 3;
}
if [ -z "$app" ]; then
    note 'build: env -u DEVELOPER_DIR sh Scripts/package-app.sh --adhoc --qa-fixtures (once for this run)'
    if ! env -u DEVELOPER_DIR sh "$repo_root/Scripts/package-app.sh" --adhoc --qa-fixtures > "$evidence_dir/package.log" 2>&1; then
        printf 'Packaging failed; see %s\n' "$evidence_dir/package.log" >&2; exit 1;
    fi
    app="$repo_root/dist/OmoUsage.app"
else
    app=$(CDPATH= cd -- "$app" && pwd)
    note "reuse-app=$app build=skipped"
fi
executable="$app/Contents/MacOS/OmoUsage"
[ -x "$executable" ] || { printf 'Missing executable: %s\n' "$executable" >&2; exit 1; }
# Fail BEFORE launching a production/nonintegrated binary that ignores fixture
# environment. The readiness receipt then confirms the resolved isolated branch.
strings "$executable" > "$driver_root/app-strings.txt"
grep -Fq 'OMO_USAGE_ACCOUNT_SETTINGS_UI_QA' "$driver_root/app-strings.txt" || {
    printf '%s\n' 'App lacks the account-settings fixture contract; package integrated sources with --qa-fixtures.' >&2; exit 1;
}
grep -Fq '/tmp/omousage-companion-qa-' "$driver_root/app-strings.txt" || {
    printf '%s\n' 'App lacks confined CompanionAccountFixture support.' >&2; exit 1;
}
shasum -a 256 "$executable" > "$evidence_dir/app-sha256.txt"

launch_app() {
    phase=$1
    rm -f "$fixture_root/account-settings-ready.json"
    OMO_USAGE_FIXTURE_MODE=1 \
    OMO_USAGE_WEB_PORT=17827 \
    OMO_USAGE_COMPANION_ACCOUNT_UI_QA=1 \
    OMO_USAGE_ACCOUNT_SETTINGS_UI_QA=1 \
    OMO_USAGE_COMPANION_ACCOUNT_QA_ROOT="$fixture_root" \
    OMO_USAGE_SINGLE_INSTANCE_LOCK_PATH="$fixture_root/instance.lock" \
    OMO_USAGE_SINGLE_INSTANCE_NOTIFICATION="com.omo.usage.qa.$(basename "$fixture_root")" \
        "$executable" -OmoUsage.appLanguage english -OmoUsage.appLanguageExplicitlySelected YES \
        > "$scenario_dir/$phase-app.log" 2>&1 &
    app_pid=$!
    note "launch scenario=$current_scenario phase=$phase owned_pid=$app_pid fixture=$fixture_root"
    "$driver" --action await-ready --fixture-root "$fixture_root" --timeout 40 >> "$log" 2>&1
    cp "$fixture_root/account-settings-ready.json" "$scenario_dir/$phase-fixture-ready.json"
}

run_scenario() {
    current_scenario=$1
    scenario_dir="$evidence_dir/$current_scenario"
    mkdir -p "$scenario_dir"
    fixture_root=$(mktemp -d /tmp/omousage-companion-qa-XXXXXX)
    "$driver" --action seed --fixture-root "$fixture_root" >> "$log" 2>&1
    for phase in exercise verify; do
        if [ "$current_scenario" = gating ] && [ "$phase" = verify ]; then
            # Mutate only the isolated, stopped fixture. Disconnecting via the
            # provider header can hide every sibling and miss the regression.
            "$driver" --action seed-primary-disconnected --fixture-root "$fixture_root" >> "$log" 2>&1
        fi
        launch_app "$phase"
        if "$driver" --action run --pid "$app_pid" --scenario "$current_scenario" --phase "$phase" \
            --fixture-root "$fixture_root" --evidence-dir "$scenario_dir" --timeout 25 \
            > "$scenario_dir/$phase-assertions.txt" 2>&1; then
            note "PASS scenario=$current_scenario phase=$phase assertions=$scenario_dir/$phase-assertions.txt"
        else
            printf 'FAIL scenario=%s phase=%s; see %s\n' "$current_scenario" "$phase" "$scenario_dir/$phase-assertions.txt" >&2
            exit 1
        fi
        # Registry has aliases and stable identities only, never credentials.
        cp "$fixture_root/accounts.json" "$scenario_dir/$phase-accounts.json"
        stop_app
        [ "$cleanup_failed" -eq 0 ] || exit 1
    done
    remove_fixture
    [ "$cleanup_failed" -eq 0 ] || exit 1
}
if [ "$scenario" = all ]; then
    for item in ordering tiers gating accounts aliases identity; do run_scenario "$item"; done
else
    run_scenario "$scenario"
fi
note "PASS all-requested-scenarios-completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
