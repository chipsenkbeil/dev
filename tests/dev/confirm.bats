#!/usr/bin/env bats

load pty

CONFIRM="${BATS_TEST_DIRNAME}/../lua/fixtures/confirm.lua"
SPIN="${BATS_TEST_DIRNAME}/../lua/fixtures/spin.lua"
SPIN_CAPTURE="${BATS_TEST_DIRNAME}/../lua/fixtures/spin_capture.lua"

setup() {
    require_pty
    OUT="$BATS_TEST_TMPDIR/out"
}

in_pty() {
    local keys="$1" delay="$2" inner="$BATS_TEST_TMPDIR/inner.sh"
    shift 2
    {
        if [ -n "${PTY_COLS:-}" ]; then
            printf 'stty rows 24 cols %s\n' "$PTY_COLS"
        fi
        printf 'luajit'
        printf ' %q' "$@"
        printf '\n'
        printf 'echo $? >"%s"\n' "$OUT.status"
    } >"$inner"
    pty_run "$keys" "$delay" 2 "$inner" "${READY:-}" "$OUT.status" >"$OUT.pty"
}

@test "y then enter confirms" {
    in_pty 'y\r' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 0 ]
}

@test "enter alone declines" {
    in_pty '\r' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 1 ]
}

@test "n then enter declines" {
    in_pty 'n\r' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 1 ]
}

@test "ctrl-c at the prompt ends the line and exits 130 with no traceback" {
    in_pty '\003' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 130 ]
    out="$(tr -d '\r' <"$OUT.pty")"
    [[ "$out" != *traceback* ]] || false
    [[ "$out" != *interrupted* ]] || false
    [[ "$out" == *"^C" ]] || false
    [ "$(tail -c 1 "$OUT.pty" | od -An -c | tr -d ' ')" = '\n' ]
}

@test "no terminal exits 2 and names -y" {
    run luajit "$CONFIRM" </dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *"-y"* ]] || false
}

@test "spin on a terminal ends with a check mark line" {
    in_pty '' 0 "$SPIN" sh -c 'sleep 0.3; exit 0'
    [ "$(cat "$OUT.status")" = 0 ]
    last="$(tr '\r' '\n' <"$OUT.pty" | sd '\x1b\[[0-9;?]*[A-Za-z]' '' | grep -v '^$' | tail -n 1)"
    [[ "$last" == "✓ Working"* ]] || false
}

@test "spin with capture returns standard output apart from the spinner" {
    in_pty '' 0 "$SPIN_CAPTURE" sh -c 'sleep 0.3; echo json; echo noise >&2; exit 0'
    [ "$(cat "$OUT.status")" = 0 ]
    out="$(tr '\r' '\n' <"$OUT.pty" | sd '\x1b\[[0-9;?]*[A-Za-z]' '' | grep -v '^$')"
    [[ "$out" == *"[json"* ]] || false
    [[ "$out" == *"✓ Working"* ]] || false
    [[ "$out" != *noise* ]] || false
}

@test "spin with capture shows standard error and keeps the output back on failure" {
    in_pty '' 0 "$SPIN_CAPTURE" sh -c 'echo json; echo noise >&2; exit 3'
    [ "$(cat "$OUT.status")" = 3 ]
    out="$(tr '\r' '\n' <"$OUT.pty")"
    [[ "$out" == *"✗"*"Working"* ]] || false
    [[ "$out" == *noise* ]] || false
}

@test "ctrl-c with capture exits 130 without an error" {
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN_CAPTURE" sh -c 'touch "$1"; sleep 5.789' sh "$READY"
    [ "$(cat "$OUT.status")" = 130 ]
    run pgrep -f 'sleep 5.789'
    [ "$status" -ne 0 ]
}

@test "ctrl-c stops the command and exits 130" {
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 5.123' sh "$READY"
    [ "$(cat "$OUT.status")" = 130 ]
    run pgrep -f 'sleep 5.123'
    [ "$status" -ne 0 ]
}

@test "ctrl-c stops every process the command started" {
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 7.321; echo done' sh "$READY"
    [ "$(cat "$OUT.status")" = 130 ]
    run pgrep -f 'sleep 7.321'
    [ "$status" -ne 0 ]
}

@test "spin hands every argv word to the command intact" {
    local marker="$BATS_TEST_TMPDIR/pwned"
    in_pty '' 0 "$SPIN" sh -c 'printf "%s\n" "$@" >"$0"' "$OUT.words" "a b" "it's" '$HOME' -n ";touch $marker"
    [ "$(cat "$OUT.status")" = 0 ]
    [ ! -e "$marker" ]
    [ "$(cat "$OUT.words")" = "$(printf '%s\n' 'a b' "it's" '$HOME' -n ";touch $marker")" ]
}

@test "spin writes no escape bytes when stderr is a file" {
    local inner="$BATS_TEST_TMPDIR/inner2.sh"
    printf 'luajit %q sh -c %q 2>%q\necho $? >%q\n' "$SPIN" 'sleep 0.3; echo hi >&2; exit 0' "$OUT.errfile" "$OUT.status" >"$inner"
    pty_run '' 0 2 "$inner" >"$OUT.pty"
    [ "$(cat "$OUT.status")" = 0 ]
    [ "$(cat "$OUT.errfile")" = hi ]
    run grep -c $'\x1b' "$OUT.errfile"
    [ "$output" = 0 ]
}

@test "y in any case confirms" {
    in_pty 'YES\r' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 0 ]
    in_pty 'Y\r' 1 "$CONFIRM"
    [ "$(cat "$OUT.status")" = 0 ]
}

@test "a failing command prints the mark and its captured output" {
    in_pty '' 0 "$SPIN" sh -c 'echo boom; echo bang >&2; exit 3'
    [ "$(cat "$OUT.status")" = 3 ]
    out="$(tr '\r' '\n' <"$OUT.pty")"
    [[ "$out" == *"✗"*"Working"* ]] || false
    [[ "$out" == *boom* ]] || false
    [[ "$out" == *bang* ]] || false
}

@test "spin removes its temp files after success, failure and ctrl-c" {
    export TMPDIR="$BATS_TEST_TMPDIR/spin-tmp"
    mkdir "$TMPDIR"
    in_pty '' 0 "$SPIN" sh -c 'exit 0'
    [ -z "$(ls -A "$TMPDIR")" ]
    in_pty '' 0 "$SPIN" sh -c 'exit 3'
    [ -z "$(ls -A "$TMPDIR")" ]
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 5.456' sh "$READY"
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "spin writes no escape bytes when TERM is dumb" {
    TERM=dumb in_pty '' 0 "$SPIN" sh -c 'sleep 0.3; exit 0'
    [ "$(cat "$OUT.status")" = 0 ]
    run grep -c $'\x1b' "$OUT.pty"
    [ "$output" = 0 ]
}

with_dash_as_sh() {
    command -v dash >/dev/null 2>&1 || skip "dash not installed"
    mkdir -p "$BATS_TEST_TMPDIR/dashbin"
    ln -sf "$(command -v dash)" "$BATS_TEST_TMPDIR/dashbin/sh"
    PATH="$BATS_TEST_TMPDIR/dashbin:$PATH"
}

@test "ctrl-c stops every process the command started when sh is dash" {
    with_dash_as_sh
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 7.654; echo done' sh "$READY"
    [ "$(cat "$OUT.status")" = 130 ]
    run pgrep -f 'sleep 7.654'
    [ "$status" -ne 0 ]
}

confirm_lines() {
    tr -d '\r' <"$OUT.pty" | sd '\x1b\[[0-9;?]*[A-Za-z]' ''
}

@test "a narrow terminal wraps the consequence above the question" {
    PTY_COLS=30 in_pty 'n\r' 1 "$CONFIRM" "Delete box?" "Its projects are archived first and every box file is kept."
    [ "$(cat "$OUT.status")" = 1 ]
    lines="$(confirm_lines)"
    [ "$(sed -n 1p <<<"$lines")" = "Its projects are archived" ]
    [ "$(sed -n 2p <<<"$lines")" = "first and every box file is" ]
    [ "$(sed -n 3p <<<"$lines")" = "kept." ]
    [[ "$(sed -n 4p <<<"$lines")" == "Delete box? [y/N]"* ]] || false
}

@test "a wide terminal keeps a short consequence on one line above the question" {
    PTY_COLS=100 in_pty 'y\r' 1 "$CONFIRM" "Delete box?" "Its projects are archived first and every box file is kept."
    [ "$(cat "$OUT.status")" = 0 ]
    lines="$(confirm_lines)"
    [ "$(sed -n 1p <<<"$lines")" = "Its projects are archived first and every box file is kept." ]
    [[ "$(sed -n 2p <<<"$lines")" == "Delete box? [y/N]"* ]] || false
}

@test "the question is yellow and the N is bold" {
    NO_COLOR= TERM=xterm in_pty 'n\r' 1 "$CONFIRM" "Delete box?" "Its projects are archived first."
    [ "$(cat "$OUT.status")" = 1 ]
    [[ "$(cat "$OUT.pty")" == *$'\e[33mDelete box?\e[0m [y/\e[1mN\e[0m] '* ]] || false
}
