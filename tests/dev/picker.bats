#!/usr/bin/env bats

load pty

FIXTURE="${BATS_TEST_DIRNAME}/../lua/fixtures/pick.lua"

setup() {
    require_pty
    INNER="$BATS_TEST_TMPDIR/inner.sh"
    OUT="$BATS_TEST_TMPDIR/out"
    cat >"$INNER" <<INNER
stty -a >"$OUT.before"
printf 'one\tOne\ntwo\tTwo\n' | luajit "$FIXTURE" >"$OUT.choice" 2>"$OUT.err"
echo \$? >"$OUT.status"
stty -a >"$OUT.after"
INNER
}

in_pty() {
    pty_run "$1" 1 1 "$INNER" >"$OUT.pty"
}

mode() {
    tr -s " ;" "\n" <"$1" | grep -xE -- "-?(icanon|echo|isig|opost|onlcr)"
    grep -oE "(min|time) = [0-9]+" "$1"
}

left_screen() {
    local out entered
    out="$(<"$OUT.pty")"
    entered="${out#*$'\e[?1049h'}"
    [ "$entered" != "$out" ]
    [[ "$entered" == *$'\e[?1049l'* ]] || false
}

same_terminal() {
    [ -s "$OUT.before" ]
    [ "$(mode "$OUT.before" | wc -l)" -ge 5 ]
    [ "$(mode "$OUT.before")" = "$(mode "$OUT.after")" ]
}

@test "j then enter prints the second value" {
    in_pty 'j\r'
    [ "$(cat "$OUT.choice")" = two ]
    [ "$(cat "$OUT.status")" = 0 ]
    same_terminal
    left_screen
}

@test "enter alone prints the first value" {
    in_pty '\r'
    [ "$(cat "$OUT.choice")" = one ]
    same_terminal
    left_screen
}

@test "esc prints nothing and exits 1" {
    in_pty '\033'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" = 1 ]
    same_terminal
    left_screen
}

@test "q prints nothing and exits 1" {
    in_pty 'q'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" = 1 ]
    same_terminal
    left_screen
}

@test "ctrl-c prints nothing and exits 1" {
    in_pty '\003'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" = 1 ]
    same_terminal
    left_screen
}

@test "an error while drawing exits non-zero and still restores the terminal" {
    export PICK_BREAK=1
    in_pty 'j\r'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" -ne 0 ]
    grep -q "attempt to" "$OUT.err"
    same_terminal
    left_screen
}

@test "a malformed item raises before the terminal is touched" {
    export PICK_BAD_TOGGLE=1
    in_pty 'j\r'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" -ne 0 ]
    grep -q "attempt to" "$OUT.err"
    same_terminal
    [[ "$(<"$OUT.pty")" != *$'\e[?1049h'* ]] || false
}

tall_pty() {
    cat >"$INNER" <<INNER
stty rows 8 cols 60
stty -a >"$OUT.before"
for i in \$(seq 1 30); do printf 'v%s\tRow %s\n' "\$i" "\$i"; done | luajit "$FIXTURE" >"$OUT.choice" 2>"$OUT.err"
echo \$? >"$OUT.status"
stty -a >"$OUT.after"
INNER
    in_pty "$1"
}

@test "a list taller than the terminal scrolls and shows the rows cut off" {
    tall_pty 'jj\r'
    [ "$(cat "$OUT.choice")" = v3 ]
    [[ "$(<"$OUT.pty")" == *"↓ 25 more"* ]] || false
    same_terminal
    left_screen
}

@test "G is not a key and pgdn moves down a window" {
    tall_pty 'G\033[6~\r'
    [ "$(cat "$OUT.choice")" = v7 ]
    same_terminal
    left_screen
}

@test "end reaches the last row and esc still restores the terminal" {
    tall_pty '\033[F\033'
    [[ "$(<"$OUT.pty")" == *"↑ 25 more"* ]] || false
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" = 1 ]
    same_terminal
    left_screen
}

@test "esc after paging restores the terminal" {
    tall_pty '\033[6~\033'
    [ ! -s "$OUT.choice" ]
    [ "$(cat "$OUT.status")" = 1 ]
    same_terminal
    left_screen
}
