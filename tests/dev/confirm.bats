#!/usr/bin/env bats

load pty

CONFIRM="${BATS_TEST_DIRNAME}/../lua/fixtures/confirm.luau"
SPIN="${BATS_TEST_DIRNAME}/../lua/fixtures/spin.luau"
SPIN_CAPTURE="${BATS_TEST_DIRNAME}/../lua/fixtures/spin_capture.luau"
RUN_CHILD="${BATS_TEST_DIRNAME}/../lua/fixtures/run_child.luau"
COUNT_INT='trap "echo i >>\"\$1\"" INT; echo Working; touch "$2"; n=0; while [ $n -lt 30 ]; do sleep 0.1; n=$((n+1)); done'

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
        printf 'dev -l'
        printf ' %q' "$@"
        printf '\n'
        printf 'echo $? >"%s"\n' "$OUT.status"
    } >"$inner"
    pty_run "$keys" "$delay" "${PTY_AFTER:-2}" "$inner" "${READY:-}" "$OUT.status" "$OUT.pty" "${READY:+Working}" >"$OUT.pty"
}

status_is_130() {
    local status
    status="$(cat "$OUT.status")"
    if [ "$status" != 130 ]; then
        printf 'status %s, terminal output:\n' "$status" >&3
        tr -d '\r' <"$OUT.pty" >&3
        return 1
    fi
}

process_gone() {
    if pgrep -f "$1" >/dev/null; then
        printf 'still running after the run ended:\n' >&3
        ps -eo pid,ppid,pgid,stat,args | grep -F -- "$1" | grep -v grep >&3
        return 1
    fi
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
    status_is_130
    out="$(tr -d '\r' <"$OUT.pty")"
    [[ "$out" != *traceback* ]] || false
    [[ "$out" != *interrupted* ]] || false
    [[ "$out" == *"^C" ]] || false
    [ "$(tail -c 1 "$OUT.pty" | od -An -c | tr -d ' ')" = '\n' ]
}

@test "no terminal exits 2 and names -y" {
    run dev -l "$CONFIRM" </dev/null
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
    status_is_130
    process_gone 'sleep 5.789'
}

@test "ctrl-c stops the command and exits 130" {
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 5.123' sh "$READY"
    status_is_130
    process_gone 'sleep 5.123'
}

@test "ctrl-c stops every process the command started" {
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$SPIN" sh -c 'touch "$1"; sleep 7.321; echo done' sh "$READY"
    status_is_130
    process_gone 'sleep 7.321'
}

@test "ctrl-c right after the command starts exits 130 on every one of eight runs" {
    local run
    for run in 1 2 3 4 5 6 7 8; do
        rm -f "$OUT.status"
        READY="$BATS_TEST_TMPDIR/ready$run"
        in_pty '\003' 0 "$SPIN_CAPTURE" sh -c 'touch "$1"; sleep 5.987' sh "$READY"
        status_is_130
        process_gone 'sleep 5.987'
    done
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
    printf 'dev -l %q sh -c %q 2>%q\necho $? >%q\n' "$SPIN" 'sleep 0.3; echo hi >&2; exit 0' "$OUT.errfile" "$OUT.status" >"$inner"
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

@test "dev box delete on a terminal shows the Deleting label and the Deleted line" {
    local stubs="$BATS_TEST_TMPDIR/stubs" inner="$BATS_TEST_TMPDIR/inner.sh"
    local dev="${DEV_BIN:-${BATS_TEST_DIRNAME}/../../target/debug/dev}" out
    mkdir -p "$stubs"
    cat >"$stubs/ci" <<'STUB'
#!/bin/sh
sleep 0.5
printf '%s\n' '{"ok":true,"box":{"name":"ci-abc","archive":null}}'
STUB
    chmod +x "$stubs/ci"
    {
        printf 'cd "%s" || exit 1\n' "$BATS_TEST_TMPDIR"
        printf 'PATH="%s:$PATH" DEV_REMOTE=0 TERM=xterm "%s" box delete ci-abc -y\n' "$stubs" "$dev"
        printf 'echo $? >"%s"\n' "$OUT.status"
    } >"$inner"
    pty_run '' 0 2 "$inner" "" "$OUT.status" >"$OUT.pty"
    [ "$(cat "$OUT.status")" = 0 ]
    out="$(tr '\r' '\n' <"$OUT.pty" | sd '\x1b\[[0-9;?]*[A-Za-z]' '' | grep -v '^$')"
    [[ "$out" == *"Deleting ci-abc"* ]] || false
    [ "$(tail -n 1 <<<"$out")" = "Deleted ci-abc · no archive" ]
}

@test "a SIGINT sent to dev's pid alone stops a child in dev's group" {
    local ready="$BATS_TEST_TMPDIR/ready" started=$SECONDS devpid
    set -m
    dev -l "$RUN_CHILD" sh -c ': >"$1"; exec sleep 8.654' sh "$ready" >/dev/null 2>&1 &
    devpid=$!
    set +m
    pty_wait_for "$ready"
    kill -INT "$devpid"
    local status=0
    wait "$devpid" || status=$?
    [ "$status" -eq 130 ]
    [ $((SECONDS - started)) -lt 6 ]
    process_gone 'sleep 8.654'
}

@test "a SIGINT sent to dev's pid alone reaches a child in dev's group once" {
    local ready="$BATS_TEST_TMPDIR/ready" log="$BATS_TEST_TMPDIR/ints" devpid
    set -m
    dev -l "$RUN_CHILD" sh -c "$COUNT_INT" sh "$log" "$ready" >/dev/null 2>&1 &
    devpid=$!
    set +m
    pty_wait_for "$ready"
    kill -INT "$devpid"
    local status=0
    wait "$devpid" || status=$?
    [ "$status" -eq 130 ]
    [ "$(grep -c i "$log")" -eq 1 ]
}

@test "a ctrl-c from the terminal reaches a child in dev's group once" {
    local log="$BATS_TEST_TMPDIR/ints"
    READY="$BATS_TEST_TMPDIR/ready"
    in_pty '\003' 0 "$RUN_CHILD" sh -c "$COUNT_INT" sh "$log" "$READY"
    status_is_130
    [ "$(grep -c i "$log")" -eq 1 ]
}

