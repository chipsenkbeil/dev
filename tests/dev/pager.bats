#!/usr/bin/env bats

load pty

DEV="${DEV_BIN:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/target/debug/dev}"

setup() {
    require_pty
    OUT="$BATS_TEST_TMPDIR/out"
    PAGED="$BATS_TEST_TMPDIR/paged"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$PROJ/.dev/help"
    {
        printf '# long: A topic taller than the screen\n\n'
        for i in $(seq 1 120); do
            printf 'line %s\n\n' "$i"
        done
    } >"$PROJ/.dev/help/long.md"
    printf '# short: A topic that fits\n\nonly line\n' >"$PROJ/.dev/help/short.md"
    ARGV="$BATS_TEST_TMPDIR/argv"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$#" "$@" >"%s"\n' "$ARGV"
        printf 'cat >"%s"\n' "$PAGED"
    } >"$BATS_TEST_TMPDIR/bin/less"
    cp "$BATS_TEST_TMPDIR/bin/less" "$BATS_TEST_TMPDIR/bin/other"
    printf '#!/bin/sh\ncat >"%s"\n' "$PAGED" >"$BATS_TEST_TMPDIR/bin/capture"
    chmod +x "$BATS_TEST_TMPDIR/bin/capture"
    chmod +x "$BATS_TEST_TMPDIR/bin/less" "$BATS_TEST_TMPDIR/bin/other"
}

in_pty() {
    local inner="$BATS_TEST_TMPDIR/inner.sh"
    {
        printf 'cd %q\n' "$PROJ"
        printf 'export PAGER=%q\n' "${PAGER_CMD:-$BATS_TEST_TMPDIR/bin/capture}"
        if [ -n "${PTY_COLS:-}" ]; then
            printf 'unset NO_COLOR\n'
            printf 'export TERM=xterm\n'
            printf 'stty rows 24 cols %s\n' "$PTY_COLS"
        else
            printf 'export NO_COLOR=1\n'
        fi
        printf '%s\n' "$1"
        printf 'echo $? >"%s"\n' "$OUT.status"
    } >"$inner"
    pty_run '' 1 2 "$inner" "" "$OUT.status" >"$OUT.pty"
}

@test "a topic taller than the screen goes through the pager" {
    in_pty "$DEV help long"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -q 'line 120' "$PAGED"
    ! grep -q 'line 120' "$OUT.pty"
}

@test "a topic that fits prints directly" {
    in_pty "$DEV help short"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'only line' "$OUT.pty"
}

@test "--no-pager prints a long topic directly" {
    in_pty "$DEV help --no-pager long"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'line 120' "$OUT.pty"
}

@test "DEV_PAGER=0 prints a long topic directly" {
    in_pty "DEV_PAGER=0 $DEV help -k long"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'line 120' "$OUT.pty"
}

@test "the curated help goes through a less pager with -+F and ends in the hint" {
    PAGER_CMD="$BATS_TEST_TMPDIR/bin/less" in_pty "$DEV help"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -qx -- '-+F' "$ARGV"
    grep -q 'Help pages' "$PAGED"
    [ "$(tail -n 1 "$PAGED" | tr -d '\r')" = '& filters · / searches · q quits' ]
}

@test "the curated help ends in no hint for another pager and gets no -+F" {
    PAGER_CMD="$BATS_TEST_TMPDIR/bin/other" in_pty "$DEV help"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -qx 0 "$ARGV"
    grep -q 'Help pages' "$PAGED"
    ! grep -q 'filters' "$PAGED"
}

@test "dev help --no-pager prints the curated help directly with no hint" {
    PAGER_CMD="$BATS_TEST_TMPDIR/bin/less" in_pty "$DEV help --no-pager"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'Help pages' "$OUT.pty"
    ! grep -q 'filters' "$OUT.pty"
}

@test "a failing less pager falls back to the text without the hint" {
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/less"
    PAGER_CMD="$BATS_TEST_TMPDIR/bin/less" in_pty "$DEV help"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -q 'The pager failed' "$OUT.pty"
    grep -q 'Help pages' "$OUT.pty"
    ! grep -q 'filters' "$OUT.pty"
}

@test "on a colour terminal the pointer line is cut to the width with no raw backticks" {
    PTY_COLS=40 PAGER_CMD="$BATS_TEST_TMPDIR/bin/other" in_pty "$DEV help"
    [ "$(cat "$OUT.status")" = 0 ]
    line="$(grep '^Run ' "$PAGED" | tail -n 1 | tr -d '\r')"
    [[ "$line" == *$'\e[36mdev help -a\e[0m'* ]] || false
    [[ "$line" != *'`'* ]] || false
    [[ "$line" == *'…'* ]] || false
}
