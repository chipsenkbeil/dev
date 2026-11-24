#!/usr/bin/env bats

load pty

FIXTURE="${BATS_TEST_DIRNAME}/../lua/fixtures/raw.luau"

setup() {
    require_pty
    INNER="$BATS_TEST_TMPDIR/inner.sh"
    OUT="$BATS_TEST_TMPDIR/out"
    cat >"$INNER" <<INNER
kind=pipe
if test -t 1; then kind=tty; fi
echo "\$kind" >"$OUT.tty"
stty min 4 time 3
stty -a >"$OUT.before"
dev -l "$FIXTURE" \${KEYS:-1} >"$OUT.key"
stty -a >"$OUT.after"
INNER
}

mode() {
    tr -s " ;" "\n" <"$1" | grep -xE -- "-?(icanon|echo|isig)"
    grep -oE "(min|time) = [0-9]+" "$1"
}

in_pty() {
    pty_run "$1" 1 1 "$INNER" >/dev/null
    [ "$(cat "$OUT.tty")" = tty ]
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

@test "an escape followed by a letter gives esc then the letter" {
    KEYS=2 in_pty '\033x'
    [ "$(tr -d '\r' <"$OUT.key")" = $'esc\nx' ]
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

@test "require_terminal exits 2 with the message when stdin is not a terminal" {
    run dev -l "${BATS_TEST_DIRNAME}/../lua/fixtures/require_terminal.luau" </dev/null
    [ "$status" -eq 2 ]
    [ "$output" = "✗ dev connect: No box given and no terminal to pick one. Pass a box name." ]
}

@test "require_terminal writes no escapes to a redirected stderr while stdout is a terminal" {
    local fixture="${BATS_TEST_DIRNAME}/../lua/fixtures/require_terminal.luau"
    local inner="$BATS_TEST_TMPDIR/rt.sh"
    printf 'TERM=xterm dev -l "%s" </dev/null 2>"%s"\n' "$fixture" "$BATS_TEST_TMPDIR/err" >"$inner"
    pty_run '' 0 1 "$inner" >/dev/null || true
    [ "$(cat "$BATS_TEST_TMPDIR/err")" = "✗ dev connect: No box given and no terminal to pick one. Pass a box name." ]
    ! grep -q $'\033' "$BATS_TEST_TMPDIR/err"
}
