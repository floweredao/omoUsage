#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    printf '%s\n' "usage: sh Scripts/check-repository-hygiene.sh" >&2
}

case "${1-}" in
    '')
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage
        exit 64
        ;;
esac

failures=''

record_failure() {
    failures="${failures}$1\n"
}

[ ! -e "758588182_17891656152596285_1812746344893833058_n.jpg" ] \
    || record_failure 'unexpected root JPG: 758588182_17891656152596285_1812746344893833058_n.jpg'
[ -f .gitattributes ] || record_failure 'missing .gitattributes'
[ -f Scripts/check-repository-hygiene.sh ] \
    || record_failure 'missing Scripts/check-repository-hygiene.sh'

while IFS= read -r path; do
    [ -f "$path" ] || continue

    case "$path" in
        Scripts/check-repository-hygiene.sh|Scripts/package-app.sh|Scripts/qa-dev-six-fixes.sh|Scripts/release-app.sh|Scripts/with-signing-keychain.sh)
            expected_mode=755
            ;;
        *)
            expected_mode=644
            ;;
    esac

    actual_mode=$(stat -f '%Lp' "$path")
    [ "$actual_mode" = "$expected_mode" ] \
        || record_failure "$path has mode $actual_mode; expected $expected_mode"
done <<EOF_PATHS
$(git ls-files)
EOF_PATHS

if [ -n "$failures" ]; then
    printf '%b' "$failures" >&2
    exit 1
fi

printf '%s\n' 'repository hygiene check passed'
