#!/usr/bin/env bash
# Tests that Ctrl-C on dev test stops the running suites and removes the scratch directory.
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

mkdir -p "$TMP/.dev/lua/dotfiles" "$TMP/tests/a" "$TMP/tests/neomutt" "$TMP/run"
cp "$REPO/.dev/test.lua" "$TMP/.dev/"
cp "$REPO/.dev/lua/dotfiles/checks.lua" "$TMP/.dev/lua/dotfiles/"
for name in filter-bytes pager-passthrough parse-check; do
    printf 'exit 0\n' >"$TMP/tests/neomutt/$name.sh"
done
for n in 1 2 3; do
    cat >"$TMP/tests/a/slow${n}_test.sh" <<'SUITE'
printf '%s\n' "$$" >>"$PIDS"
printf '%s\n' "$TMPDIR" >>"$TMPDIRS"
sleep 300 &
printf '%s\n' "$!" >>"$PIDS"
wait
SUITE
done

export PIDS="$TMP/run/pids" TMPDIRS="$TMP/run/tmpdirs" DEV_TEST_JOBS=3
: >"$PIDS"
: >"$TMPDIRS"

set -m
(cd "$TMP" && exec "$DEV" test) >"$TMP/run/out" 2>&1 &
devpid=$!
set +m

waited=0
while [ "$(wc -l <"$PIDS")" -lt 6 ] && [ "$waited" -lt 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "all three suites and their sleeps started" "$(wc -l <"$PIDS" | tr -d ' ')" "6"

too_long=0
while IFS= read -r path; do
    [ "${#path}" -lt 60 ] || too_long=$((too_long + 1))
done <"$TMPDIRS"
assert_eq "each suite's TMPDIR is under 60 characters" "$too_long" "0"

scratch="$(dirname "$(head -n 1 "$TMPDIRS")")"
assert_eq "the scratch directory exists while the suites run" "$([ -d "$scratch" ] && echo yes)" "yes"

kill -INT -- "-$devpid"
wait "$devpid"
rc=$?
assert_eq "dev test exits 130 on INT" "$rc" "130"

waited=0
while [ -d "$scratch" ] && [ "$waited" -lt 100 ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "the scratch directory is removed" "$([ -d "$scratch" ] && echo present || echo gone)" "gone"

alive=0
while IFS= read -r pid; do
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.2
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
        kill -KILL "$pid" 2>/dev/null
    fi
done <"$PIDS"
assert_eq "no suite process is left running" "$alive" "0"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall interrupt tests passed\n'
