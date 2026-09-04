#!/bin/sh

# Drives the packaged OmoUsage UI through a companion Add Account flow in
# an isolated fixture mode: temporary registry, file-backed fixture
# Keychain, stub companion launch, fixture providers, and a fixture web
# port. It never reads or writes the real registry or Keychain and never
# starts a real companion login.

set -eu

usage() {
    printf '%s\n' \
        "Usage: sh Scripts/qa-companion-account-add.sh --scenario <changed|unchanged-cancel> --evidence-dir <path>"
}

scenario=
evidence_dir=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scenario)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            scenario=$2
            shift 2
            ;;
        --evidence-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            evidence_dir=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$scenario" in
    changed)
        account_alias="QA-Second"
        ;;
    unchanged-cancel)
        account_alias="QA-Unchanged"
        ;;
    *)
        printf 'Invalid or missing --scenario value: %s\n' "$scenario" >&2
        usage >&2
        exit 64
        ;;
esac

[ -n "$evidence_dir" ] || {
    printf '%s\n' "Missing --evidence-dir." >&2
    usage >&2
    exit 64
}

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mkdir -p "$evidence_dir"
evidence_dir=$(CDPATH= cd -- "$evidence_dir" && pwd)
log="$evidence_dir/action-log.md"
cleanup_report="$evidence_dir/cleanup.txt"

app_pid=
fixture_root=
driver_binary=
legacy_snapshot=
legacy_snapshot_checksum=

note() {
    printf '%s\n' "$1" | tee -a "$log"
}

cleanup() {
    status=$?
    if [ "$status" -ne 0 ] && [ -n "$app_pid" ] && [ -n "$driver_binary" ] \
        && kill -0 "$app_pid" 2>/dev/null
    then
        {
            printf '\n## failure state\n\n'
            printf -- '- exit status: %s\n' "$status"
            printf -- '- settings feedback: %s\n' \
                "$("$driver_binary" --pid "$app_pid" --action value \
                    --identifier settings-feedback --timeout 3 \
                    2>&1 || true)"
            if [ -n "$fixture_root" ] \
                && [ -f "$fixture_root/accounts.json" ]; then
                printf -- '- registry labels: %s\n' \
                    "$(grep '"label"' "$fixture_root/accounts.json" \
                        | tr -d ' \n' || true)"
            fi
        } >> "$log" 2>&1
        "$driver_binary" --pid "$app_pid" --action dump \
            > "$evidence_dir/failure-ax-tree.txt" 2>&1 || true
    fi
    {
        printf 'cleanup performed at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
            kill "$app_pid" 2>/dev/null || true
            wait "$app_pid" 2>/dev/null || true
            printf 'terminated fixture app pid %s\n' "$app_pid"
        else
            printf 'no fixture app process remained\n'
        fi
        if [ -n "$fixture_root" ]; then
            suite="CompanionAccountQA-$(basename "$fixture_root")"
            defaults delete "$suite" >/dev/null 2>&1 || true
            printf 'removed fixture defaults suite %s\n' "$suite"
            rm -rf "$fixture_root"
            printf 'removed fixture root %s\n' "$fixture_root"
        fi
        [ -z "$driver_binary" ] || {
            rm -f "$driver_binary"
            printf 'removed driver binary %s\n' "$driver_binary"
        }
        printf 'exit status %s\n' "$status"
    } > "$cleanup_report" 2>&1
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

: > "$log"
note "# Companion Add Account QA — $scenario"
note ""
note "- started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
note "- commit: $(git -C "$repo_root" rev-parse HEAD)"

note "- packaging: sh Scripts/package-app.sh --adhoc --qa-fixtures"
sh "$repo_root/Scripts/package-app.sh" --adhoc --qa-fixtures >/dev/null

app="$repo_root/dist/OmoUsage.app"
executable="$app/Contents/MacOS/OmoUsage"
[ -x "$executable" ] || {
    printf 'Missing packaged executable: %s\n' "$executable" >&2
    exit 1
}

fixture_root=$(mktemp -d /tmp/omousage-companion-qa-XXXXXX)
mkdir -p "$fixture_root/keychain" "$fixture_root/home"
printf 'qa-codex-token-a' > "$fixture_root/credential-codex.token"
note "- fixture root: $fixture_root"

driver_binary="$fixture_root/qa-driver"
note "- building accessibility driver"
swiftc -O -o "$driver_binary" \
    "$repo_root/Scripts/qa-companion-account-driver.swift"

drive() {
    "$driver_binary" --pid "$app_pid" "$@"
}

assert_refresh_count() {
    expected=$1
    observed=$(drive --action wait-file-value \
        --file "$fixture_root/account-registry-refresh-count" \
        --value "$expected" --timeout 40)
    [ "$observed" = "$expected" ] || {
        printf 'Unexpected account-registry refresh count: %s\n' \
            "$observed" >&2
        exit 1
    }
    note "- fixture account-registry refresh-count=$observed"
}

assert_registry_lacks_account() {
    if [ -f "$fixture_root/accounts.json" ] \
        && grep -Fq "\"$account_alias\"" "$fixture_root/accounts.json"
    then
        printf '%s\n' \
            "fixture registry already contains account $account_alias" >&2
        exit 1
    fi
}

assert_registry_has_account() {
    grep -Fq "\"$account_alias\"" "$fixture_root/accounts.json" || {
        printf '%s\n' \
            "fixture registry is missing account $account_alias" >&2
        exit 1
    }
}

capture_window() {
    target=$1
    layer_flag=$2
    if [ "$layer_flag" = "highest" ]; then
        window_id=$(drive --action window-id --highest-layer)
    else
        window_id=$(drive --action window-id)
    fi
    screencapture -x -o -l"$window_id" "$evidence_dir/$target" || {
        printf '%s\n' \
            "screencapture failed for $target. Grant Screen Recording to the terminal or automation host in System Settings > Privacy & Security > Screen Recording, then rerun." >&2
        exit 3
    }
    [ -s "$evidence_dir/$target" ] || {
        printf '%s\n' \
            "screencapture produced an empty $target; Screen Recording permission is missing." >&2
        exit 3
    }
    note "- captured $target"
}

OMO_USAGE_FIXTURE_MODE=1 \
OMO_USAGE_WEB_PORT=17827 \
OMO_USAGE_COMPANION_ACCOUNT_UI_QA=1 \
OMO_USAGE_COMPANION_ACCOUNT_QA_ROOT="$fixture_root" \
OMO_USAGE_SINGLE_INSTANCE_LOCK_PATH="$fixture_root/instance.lock" \
OMO_USAGE_SINGLE_INSTANCE_NOTIFICATION="com.omo.usage.qa.$(basename "$fixture_root")" \
    "$executable" &
app_pid=$!
note "- launched fixture app pid $app_pid"

drive --action wait --identifier account-alias-codex --timeout 40
note "- settings window is up"

account_identifier="account-codex-$account_alias"
dashboard_account_identifier="dashboard-provider-codex-$account_alias"

drive --action set-value --identifier account-alias-codex \
    --value "$account_alias"
note "- typed alias $account_alias"
drive --action press --identifier add-account-codex
note "- pressed Add Account for Codex"
drive --action wait --identifier account-waiting-codex --timeout 20 --scroll
note "- waiting state is shown for $account_alias (no account row yet)"
drive --action wait-absent --identifier "$account_identifier" --timeout 5
assert_registry_lacks_account
assert_refresh_count 0
note "- confirmed $account_alias was not persisted before authentication"
grep -q '^launched:codex$' "$fixture_root/launch-log.txt" || {
    printf '%s\n' "fixture companion launch was not recorded" >&2
    exit 1
}
note "- stub companion launch recorded"
legacy_snapshot=$(find "$fixture_root/keychain" -type f | head -n 1)
[ -n "$legacy_snapshot" ] && [ "$(find "$fixture_root/keychain" -type f | wc -l | tr -d ' ')" = 1 ] || {
    printf '%s\n' "legacy Codex snapshot was not preserved before launch" >&2
    exit 1
}
legacy_snapshot_checksum=$(shasum -a 256 "$legacy_snapshot" | awk '{print $1}')
note "legacy-credential-preserved=passed"

if [ "$scenario" = "changed" ]; then
    drive --action scroll-to --identifier account-waiting-codex
    capture_window settings-waiting.png normal

    printf 'qa-codex-token-b' > "$fixture_root/credential-codex.token"
    note "- companion credential replaced (simulated official login)"
    drive --action press --identifier check-again-codex --scroll
    drive --action wait --identifier "$account_identifier" \
        --timeout 40 --scroll
    assert_registry_has_account
    assert_refresh_count 1
    [ "$(shasum -a 256 "$legacy_snapshot" | awk '{print $1}')" = "$legacy_snapshot_checksum" ] || {
        printf '%s\n' "legacy Codex snapshot changed during account addition" >&2
        exit 1
    }
    [ "$(find "$fixture_root/keychain" -type f | wc -l | tr -d ' ')" = 2 ] || {
        printf '%s\n' "new Codex account snapshot was not isolated" >&2
        exit 1
    }
    note "new-account-credential-isolated=passed"
    note "- account row for $account_alias appeared after the credential changed"
    drive --action scroll-to --identifier "$account_identifier"
    capture_window settings-added.png normal

    drive --action menubar-press --timeout 20
    note "- opened the dashboard from the status item"
    drive --action wait --identifier "$dashboard_account_identifier" \
        --timeout 40 --scroll --highest-layer
    drive --action scroll-to --identifier "$dashboard_account_identifier" \
        --timeout 40 --highest-layer
    note "- dashboard visibly targeted account $account_alias after one completed refresh"
    capture_window dashboard-added.png highest
else
    drive --action press --identifier check-again-codex --scroll
    drive --action wait --identifier account-waiting-codex --timeout 20 \
        --scroll
    drive --action wait-absent --identifier "$account_identifier" \
        --timeout 5
    assert_registry_lacks_account
    assert_refresh_count 0
    feedback=$(drive --action value --identifier settings-feedback)
    note "- unchanged credential kept $account_alias pending: $feedback"
    drive --action scroll-to --identifier account-waiting-codex
    capture_window unchanged-waiting.png normal

    drive --action press --identifier cancel-addition-codex --scroll
    drive --action wait --identifier add-account-codex --timeout 20 --scroll
    drive --action wait-absent --identifier account-waiting-codex \
        --timeout 5
    drive --action wait-absent --identifier "$account_identifier" \
        --timeout 5
    capture_window cancelled-idle.png normal
    activation=$(drive --action reactivate --timeout 20)
    [ "$activation" = "target-left-active-and-reactivated" ] || {
        printf 'Post-cancel activation did not complete: %s\n' "$activation" >&2
        exit 1
    }
    note "- post-cancel activation: $activation"
    drive --action wait --identifier add-account-codex --timeout 20 --scroll
    drive --action wait-absent --identifier account-waiting-codex \
        --timeout 5
    drive --action wait-absent --identifier "$account_identifier" \
        --timeout 5
    note "- post-cancel idle UI observed for $account_alias"
    assert_registry_lacks_account
    note "- post-cancel registry lacks account $account_alias"
    note "- post-cancel alias scenario retained: $account_alias"
    assert_refresh_count 0
    [ "$(shasum -a 256 "$legacy_snapshot" | awk '{print $1}')" = "$legacy_snapshot_checksum" ] || {
        printf '%s\n' "legacy Codex snapshot changed during unchanged/cancel" >&2
        exit 1
    }
    [ "$(find "$fixture_root/keychain" -type f | wc -l | tr -d ' ')" = 1 ] || {
        printf '%s\n' "unchanged/cancel wrote an extra account snapshot" >&2
        exit 1
    }
    note "legacy-credential-preserved=passed"
    note "- cancel returned to idle without adding $account_alias"
fi

note "- finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'PASS scenario=%s evidence=%s\n' "$scenario" "$evidence_dir"
