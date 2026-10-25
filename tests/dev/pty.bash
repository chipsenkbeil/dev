# shellcheck shell=bash

require_pty() {
    command -v script >/dev/null 2>&1 || skip "script not installed"
    command -v luajit >/dev/null 2>&1 || skip "luajit not installed"
}

pty_wait_for() {
    local file=$1 tries=0
    [ -n "$file" ] || return 0
    while [ ! -e "$file" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 200 ]; then
            echo "timed out waiting for $file" >&2
            exit 1
        fi
        sleep 0.05
    done
}

pty_run() {
    local keys=$1 before=$2 after=$3 inner=$4 ready=${5:-} finished=${6:-}
    if script --version >/dev/null 2>&1; then
        {
            sleep "$before"
            pty_wait_for "$ready"
            printf '%b' "$keys"
            sleep "$after"
            pty_wait_for "$finished"
        } | script -qec "bash $inner" /dev/null
    else
        {
            sleep "$before"
            pty_wait_for "$ready"
            printf '%b' "$keys"
            sleep "$after"
            pty_wait_for "$finished"
        } | script -q /dev/null bash "$inner"
    fi
}
