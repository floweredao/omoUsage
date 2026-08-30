#!/bin/sh

set -eu

usage() {
    printf '%s\n' \
        "Usage: sh Scripts/qa-dev-six-fixes.sh --case <all|hover|auth|fresh-install|multi-account|ordering|dock> --evidence-dir <path>"
}

case_name=
evidence_dir=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --case)
            [ "$#" -ge 2 ] || {
                usage >&2
                exit 64
            }
            case_name=$2
            shift 2
            ;;
        --evidence-dir)
            [ "$#" -ge 2 ] || {
                usage >&2
                exit 64
            }
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

case "$case_name" in
    all|hover|auth|fresh-install|multi-account|ordering|dock)
        ;;
    *)
        printf 'Invalid or missing --case value: %s\n' "$case_name" >&2
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
current_branch=$(git -C "$repo_root" branch --show-current)
case "$current_branch" in
    dev|main)
        ;;
    *)
        printf 'Refusing QA outside dev/main; current branch is %s.\n' \
            "$current_branch" >&2
        exit 1
        ;;
esac

app="$repo_root/dist/OmoUsage.app"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/OmoUsage"
[ -f "$plist" ] || {
    printf 'Missing packaged Info.plist: %s\n' "$plist" >&2
    exit 1
}
[ -x "$executable" ] || {
    printf 'Missing packaged executable: %s\n' "$executable" >&2
    exit 1
}

ls_ui_element=$(
    /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$plist"
)
[ "$ls_ui_element" = "true" ] || {
    printf 'Packaged LSUIElement is %s, expected true.\n' \
        "$ls_ui_element" >&2
    exit 1
}

/usr/bin/codesign --verify --deep --strict "$app"

[ -d "$evidence_dir" ] || {
    printf 'Missing evidence directory: %s\n' "$evidence_dir" >&2
    exit 1
}

expected_tree=$(git -C "$repo_root" rev-parse --short "HEAD^{tree}")
[ -s "$evidence_dir/TREE" ] || {
    printf 'Missing evidence tree stamp: %s/TREE\n' "$evidence_dir" >&2
    exit 1
}
recorded_tree=$(tr -d '[:space:]' < "$evidence_dir/TREE")
[ "$recorded_tree" = "$expected_tree" ] || {
    printf 'Stale evidence tree %s; expected %s.\n' \
        "$recorded_tree" "$expected_tree" >&2
    exit 1
}

worktree_fingerprint() {
    {
        git -C "$repo_root" diff HEAD --binary --no-ext-diff
        git -C "$repo_root" ls-files --others --exclude-standard \
            | LC_ALL=C sort \
            | while IFS= read -r relative_path; do
                [ -n "$relative_path" ] || continue
                printf 'untracked:%s\n' "$relative_path"
                shasum -a 256 "$repo_root/$relative_path"
            done
    } | shasum -a 256 | awk '{ print $1 }'
}

app_fingerprint() {
    (
        cd "$app"
        find . -type f -print \
            | LC_ALL=C sort \
            | while IFS= read -r relative_path; do
                [ -n "$relative_path" ] || continue
                printf 'file:%s mode:%s\n' \
                    "$relative_path" \
                    "$(stat -f '%Lp' "$relative_path")"
                shasum -a 256 "$relative_path"
            done
    ) | shasum -a 256 | awk '{ print $1 }'
}

expected_worktree=$(worktree_fingerprint)
[ -s "$evidence_dir/WORKTREE-SHA256" ] || {
    printf 'Missing worktree fingerprint: %s/WORKTREE-SHA256\n' \
        "$evidence_dir" >&2
    exit 1
}
recorded_worktree=$(
    tr -d '[:space:]' < "$evidence_dir/WORKTREE-SHA256"
)
[ "$recorded_worktree" = "$expected_worktree" ] || {
    printf 'Stale worktree fingerprint %s; expected %s.\n' \
        "$recorded_worktree" "$expected_worktree" >&2
    exit 1
}

expected_app=$(app_fingerprint)
[ -s "$evidence_dir/APP-SHA256" ] || {
    printf 'Missing packaged app fingerprint: %s/APP-SHA256\n' \
        "$evidence_dir" >&2
    exit 1
}
recorded_app=$(tr -d '[:space:]' < "$evidence_dir/APP-SHA256")
[ "$recorded_app" = "$expected_app" ] || {
    printf 'Stale packaged app fingerprint %s; expected %s.\n' \
        "$recorded_app" "$expected_app" >&2
    exit 1
}

verify_case() {
    scenario=$1
    scenario_dir="$evidence_dir/$scenario"

    [ -d "$scenario_dir" ] || {
        printf 'Missing %s evidence directory: %s\n' \
            "$scenario" "$scenario_dir" >&2
        exit 1
    }
    [ -s "$scenario_dir/PASS" ] || {
        printf 'Missing %s PASS marker.\n' "$scenario" >&2
        exit 1
    }
    if [ ! -s "$scenario_dir/action-log.md" ] \
        && [ ! -s "$scenario_dir/action-log.txt" ]; then
        printf 'Missing %s action log.\n' "$scenario" >&2
        exit 1
    fi
    if ! find "$scenario_dir" -type f -name '*.png' -size +0c \
        -print -quit | grep -q .; then
        printf 'Missing non-empty %s screenshot.\n' "$scenario" >&2
        exit 1
    fi

    printf 'PASS %s\n' "$scenario"
}

if [ "$case_name" = "all" ]; then
    for scenario in \
        hover auth fresh-install multi-account ordering dock
    do
        verify_case "$scenario"
    done
    [ -s "$evidence_dir/PASS" ] || {
        printf 'Missing aggregate PASS marker: %s/PASS\n' \
            "$evidence_dir" >&2
        exit 1
    }
else
    verify_case "$case_name"
fi

printf 'PASS tree=%s worktree=%s app=%s case=%s evidence=%s\n' \
    "$expected_tree" "$expected_worktree" "$expected_app" \
    "$case_name" "$evidence_dir"
