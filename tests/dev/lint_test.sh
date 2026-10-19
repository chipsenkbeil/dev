#!/usr/bin/env bash
# Pure-bash tests for .dev/lint.sh: shfmt drift and a comment under code both fail the lint.
# The script is copied into a temp tree with scratch shell files, so the repo is never linted.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.dev" "$TMP/scripts" "$TMP/tests" "$TMP/dotfiles/bin" "$TMP/dotfiles/jj/.config/jj/scripts"
cp "$REPO/.dev/lint.sh" "$REPO/.dev/lib.sh" "$TMP/.dev/"
cp "$REPO/scripts/helpers.sh" "$TMP/scripts/helpers.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n    echo ok\nfi\n' >"$TMP/scripts/clean.sh"

fails=0

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$desc" "$got" "$want"
        fails=$((fails + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)
        printf 'FAIL - %s\n       missing: %q\n       in:      %q\n' "$desc" "$needle" "$haystack"
        fails=$((fails + 1))
        ;;
    esac
}

# lint: run the copied lint script, capturing stdout and stderr together.
lint() {
    bash "$TMP/.dev/lint.sh" 2>&1
}

out="$(lint)"
rc=$?
assert_eq "a clean tree exits 0" "$rc" "0"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n  echo drifted\nfi\n' >"$TMP/scripts/drift.sh"
out="$(lint)"
rc=$?
assert_eq "shfmt drift exits non-zero" "$((rc != 0))" "1"
assert_contains "shfmt drift names the file" "$out" "scripts/drift.sh"
rm "$TMP/scripts/drift.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nvalue=1\n# explains the next line\necho done\n' >"$TMP/scripts/spacing.sh"
out="$(lint)"
rc=$?
assert_eq "a comment under code exits non-zero" "$((rc != 0))" "1"
assert_contains "a comment under code names file and line" "$out" "scripts/spacing.sh:5: full-line comment directly after code"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall lint tests passed\n'
