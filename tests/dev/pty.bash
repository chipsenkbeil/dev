# shellcheck shell=bash

DEV_BIN="${DEV_BIN:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/target/debug/dev}"
PATH="${DEV_BIN%/*}:$PATH"

require_pty() {
    command -v script >/dev/null 2>&1 || skip "script not installed"
    [ -x "$DEV_BIN" ] || skip "dev is not built"
}

PTY_DEADLINE_SECS=30

pty_timeout() {
    local what=$1 started=$2
    echo "$what after $((SECONDS - started)) seconds." >&2
    ps -eo pid,ppid,pgid,stat,args | awk '/dev -l/ && !/awk/' >&2
    exit 1
}

pty_wait_for() {
    local file=$1 started=$SECONDS
    [ -n "$file" ] || return 0
    while [ ! -e "$file" ]; do
        if [ $((SECONDS - started)) -ge "$PTY_DEADLINE_SECS" ]; then
            pty_timeout "Timed out waiting for $file" "$started"
        fi
        sleep 0.05
    done
}

pty_wait_for_text() {
    local file=$1 text=$2 started=$SECONDS
    [ -n "$text" ] || return 0
    until grep -qF -- "$text" "$file" 2>/dev/null; do
        if [ $((SECONDS - started)) -ge "$PTY_DEADLINE_SECS" ]; then
            pty_timeout "Timed out waiting for $text in $file" "$started"
        fi
        sleep 0.05
    done
}

pty_run() {
    local keys=$1 before=$2 after=$3 inner=$4 ready=${5:-} finished=${6:-} shown=${7:-} text=${8:-}
    if script --version >/dev/null 2>&1; then
        {
            sleep "$before"
            pty_wait_for "$ready"
            pty_wait_for_text "$shown" "$text"
            printf '%b' "$keys"
            sleep "$after"
            pty_wait_for "$finished"
        } | script -qec "bash $inner" /dev/null
    else
        {
            sleep "$before"
            pty_wait_for "$ready"
            pty_wait_for_text "$shown" "$text"
            printf '%b' "$keys"
            sleep "$after"
            pty_wait_for "$finished"
        } | script -q /dev/null bash "$inner"
    fi
}
