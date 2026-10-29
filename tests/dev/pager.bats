#!/usr/bin/env bats

load pty

DEV="${BATS_TEST_DIRNAME}/../../dotfiles/bin/.local/bin/dev"

setup() {
    require_pty
    OUT="$BATS_TEST_TMPDIR/out"
    PAGED="$BATS_TEST_TMPDIR/paged"
    PROJ="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$PROJ/.dev/topics"
    {
        printf '# long: A topic taller than the screen\n\n'
        for i in $(seq 1 120); do
            printf 'line %s\n\n' "$i"
        done
    } >"$PROJ/.dev/topics/long.md"
    printf '# short: A topic that fits\n\nonly line\n' >"$PROJ/.dev/topics/short.md"
}

in_pty() {
    local inner="$BATS_TEST_TMPDIR/inner.sh"
    {
        printf 'cd %q\n' "$PROJ"
        printf 'export PAGER=%q\n' "cat >$PAGED"
        printf 'export NO_COLOR=1\n'
        printf '%s\n' "$1"
        printf 'echo $? >"%s"\n' "$OUT.status"
    } >"$inner"
    pty_run '' 1 2 "$inner" "" "$OUT.status" >"$OUT.pty"
}

@test "a topic taller than the screen goes through the pager" {
    in_pty "bash $DEV help long"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -q 'line 120' "$PAGED"
    ! grep -q 'line 120' "$OUT.pty"
}

@test "a topic that fits prints directly" {
    in_pty "bash $DEV help short"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'only line' "$OUT.pty"
}

@test "--no-pager prints a long topic directly" {
    in_pty "bash $DEV help --no-pager long"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'line 120' "$OUT.pty"
}

@test "DEV_PAGER=0 prints a long topic directly" {
    in_pty "DEV_PAGER=0 bash $DEV help -k long"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'line 120' "$OUT.pty"
}

@test "dev guide with no question pages the overview and the curated help" {
    printf '# overview: Intro\n\nintro text\n' >"$PROJ/.dev/topics/overview.md"
    in_pty "bash $DEV guide"
    [ "$(cat "$OUT.status")" = 0 ]
    grep -q 'intro text' "$PAGED"
    grep -q 'Topics' "$PAGED"
}

@test "DEV_PAGER=0 prints dev guide directly" {
    printf '# overview: Intro\n\nintro text\n' >"$PROJ/.dev/topics/overview.md"
    in_pty "DEV_PAGER=0 bash $DEV guide"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$PAGED" ]
    grep -q 'intro text' "$OUT.pty"
}
