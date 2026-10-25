#!/usr/bin/env bats

load pty

FIXTURE="${BATS_TEST_DIRNAME}/../lua/fixtures/raw.lua"

setup() {
    require_pty
    INNER="$BATS_TEST_TMPDIR/inner.sh"
    OUT="$BATS_TEST_TMPDIR/out"
    cat >"$INNER" <<INNER
stty min 4 time 3
stty -a >"$OUT.before"
luajit "$FIXTURE" >"$OUT.key"
stty -a >"$OUT.after"
INNER
}

mode() {
    tr -s " ;" "\n" <"$1" | grep -xE -- "-?(icanon|echo|isig)"
    grep -oE "(min|time) = [0-9]+" "$1"
}

in_pty() {
    pty_run "$1" 1 1 "$INNER" >/dev/null
}

@test "raw mode reads one key and prints it" {
    in_pty 'x'
    [ "$(tr -d '\r' <"$OUT.key")" = x ]
}

@test "raw mode delivers ctrl-c as a key" {
    in_pty '\003'
    [ "$(tr -d '\r' <"$OUT.key")" = ctrl-c ]
}

@test "a lone escape is esc" {
    in_pty '\033'
    [ "$(tr -d '\r' <"$OUT.key")" = esc ]
}

@test "an arrow sequence is up" {
    in_pty '\033[A'
    [ "$(tr -d '\r' <"$OUT.key")" = up ]
}

@test "restore puts back the exact terminal state" {
    in_pty 'x'
    [ "$(mode "$OUT.before" | wc -l)" -eq 5 ]
    [ "$(mode "$OUT.before")" = "$(mode "$OUT.after")" ]
    grep -qx "icanon" <<<"$(mode "$OUT.after")"
    grep -qx "echo" <<<"$(mode "$OUT.after")"
    grep -q "min = 4" "$OUT.after"
    grep -q "time = 3" "$OUT.after"
}
