#!/usr/bin/env bash
# Pure-bash end-to-end tests for the package driver's entry (no external test framework).
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${DEV_BIN:-$(cd "$DIR/../.." && pwd)/target/debug/dev}"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"
printf '#!/bin/sh\necho Darwin\n' >"$TMP/stubs/uname"
chmod +x "$TMP/stubs/uname"

# A quoted script: cell must print the script path with its args in the dry run.
iout="$(PATH="$TMP/stubs:$PATH" "$DEV" __pkg install --manifest "$DIR/fixtures/script-args.tsv" --dry-run script-args 2>&1)"
assert_eq "install dry-run passes args through" "$iout" $'  + script-args (dry-run):\n      bash /tmp/echo-args.sh --flag value'

if [ "$fails" -gt 0 ]; then
    printf '\n%d test(s) failed\n' "$fails"
    exit 1
fi
printf '\nall tests passed\n'
