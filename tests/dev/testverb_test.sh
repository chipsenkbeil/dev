#!/usr/bin/env bash
# Tests for the accounting of .dev/test.lua, run through dev on a scratch tree of fake suites.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v bats >/dev/null 2>&1; then
    printf 'skip - the test verb needs bats\n'
    exit 3
fi

fails=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        printf 'ok   - %s\n' "$1"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

assert_line() {
    case $'\n'"$2"$'\n' in
    *$'\n'"$3"$'\n'*) printf 'ok   - %s\n' "$1" ;;
    *)
        printf 'FAIL - %s\n       missing line: %q\n' "$1" "$3"
        fails=$((fails + 1))
        ;;
    esac
}

mkdir -p "$TMP/.dev/lua/dotfiles" "$TMP/tests/a" "$TMP/tests/neomutt"
cp "$REPO/.dev/test.lua" "$TMP/.dev/"
cp "$REPO/.dev/lua/dotfiles/checks.lua" "$TMP/.dev/lua/dotfiles/"
for name in filter-bytes pager-passthrough parse-check; do
    printf 'exit 0\n' >"$TMP/tests/neomutt/$name.sh"
done
extra=0
if command -v neomutt >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
    extra=3
fi
printf 'exit 0\n' >"$TMP/tests/a/pass_test.sh"
printf 'exit 1\n' >"$TMP/tests/a/fail_test.sh"
printf 'exit 3\n' >"$TMP/tests/a/skip_test.sh"
printf 'exit 4\n' >"$TMP/tests/a/four_test.sh"
printf 'kill -9 $$\n' >"$TMP/tests/a/killed_test.sh"
printf '#!/usr/bin/env bats\n@test "only" { skip "x"; }\n' >"$TMP/tests/a/skips.bats"
printf '#!/usr/bin/env bats\n@test "ok" { true; }\n' >"$TMP/tests/a/runs.bats"

out="$(cd "$TMP" && "$DEV" test 2>&1)"
rc=$?
assert_eq "a failing suite makes dev test exit 1" "$rc" "1"
assert_line "a passing script is PASS" "$out" "PASS tests/a/pass_test.sh"
assert_line "an exit 1 script is FAIL" "$out" "FAIL tests/a/fail_test.sh"
assert_line "an exit 3 script is SKIP" "$out" "SKIP tests/a/skip_test.sh (every case skipped)"
assert_line "an exit 4 script is FAIL" "$out" "FAIL tests/a/four_test.sh"
assert_line "a script that kills itself is FAIL" "$out" "FAIL tests/a/killed_test.sh"
assert_line "a bats file whose only case skips is SKIP" "$out" "SKIP tests/a/skips.bats (every case skipped)"
assert_line "a bats file with a passing case is PASS" "$out" "PASS tests/a/runs.bats"
assert_line "the summary counts every suite" "$out" "$((2 + extra)) passed, 3 failed, 2 skipped"

rm "$TMP/tests/a/fail_test.sh" "$TMP/tests/a/four_test.sh" "$TMP/tests/a/killed_test.sh"
out="$(cd "$TMP" && "$DEV" test 2>&1)"
rc=$?
assert_eq "no failing suite makes dev test exit 0" "$rc" "0"
assert_line "the summary has no failure" "$out" "$((2 + extra)) passed, 0 failed, 2 skipped"

out="$(cd "$TMP" && "$DEV" test tests/a/pass_test.sh 2>&1)"
rc=$?
assert_eq "a named suite exits 0" "$rc" "0"
assert_line "a named suite runs only that suite" "$out" "PASS tests/a/pass_test.sh"
assert_line "a named suite is the only one counted" "$out" "1 passed, 0 failed, 0 skipped"

out="$(cd "$TMP" && "$DEV" test tests/a/pass_test.sh tests/a/runs.bats 2>&1)"
assert_line "two named suites are both counted" "$out" "2 passed, 0 failed, 0 skipped"

out="$(cd "$TMP" && "$DEV" test tests/a 2>&1)"
assert_line "a directory runs every suite under it" "$out" "2 passed, 0 failed, 2 skipped"

out="$(cd "$TMP" && "$DEV" test tests/a/missing_test.sh 2>&1)"
rc=$?
assert_eq "a path that names no suite exits 2" "$rc" "2"
assert_line "a path that names no suite is refused" "$out" "dev test: no suite at tests/a/missing_test.sh"

out="$(cd "$TMP" && "$DEV" test ./tests/a/pass_test.sh 2>&1)"
assert_line "a dot slash path names the same suite as the plain path" "$out" "PASS tests/a/pass_test.sh"

out="$(cd "$TMP" && "$DEV" test tests/a/ 2>&1)"
assert_line "a trailing slash path names the same suite as the plain path" "$out" "2 passed, 0 failed, 2 skipped"

out="$(cd "$TMP" && "$DEV" test -x 2>&1)"
rc=$?
assert_eq "a dash flag is refused with exit 2" "$rc" "2"
assert_line "a dash flag is refused with the unknown flag message" "$out" "dev test: Unknown flag -x. Pass it after -- to reach the script, or add it to the script's # flags: line."

out="$(cd "$TMP" && "$DEV" test -- -x 2>&1)"
rc=$?
assert_eq "a dash flag after the double dash is refused with exit 2" "$rc" "2"
assert_line "a dash flag after the double dash is refused by the verb" "$out" "dev test: Unknown flag -x."

if [ "$extra" -eq 0 ]; then
    out="$(cd "$TMP" && "$DEV" test tests/neomutt/parse-check.sh 2>&1)"
    rc=$?
    assert_eq "a suite skipped here exits 2" "$rc" "2"
    assert_line "a suite skipped here is named as skipped here" "$out" "dev test: tests/neomutt/parse-check.sh is skipped here. It needs neomutt and tmux on PATH."
else
    printf 'skip - neomutt and tmux are on PATH, so no suite is skipped here\n'
fi

printf 'exit 0\n' >"$TMP/tests/a/sp ace_test.sh"
out="$(cd "$TMP" && "$DEV" test "tests/a/sp ace_test.sh" 2>&1)"
assert_line "a path with a space is one word" "$out" "PASS tests/a/sp ace_test.sh"
rm "$TMP/tests/a/sp ace_test.sh"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall test verb tests passed\n'
