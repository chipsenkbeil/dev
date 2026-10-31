#!/usr/bin/env bash
set -u

entry=$1

lock=${DEV_PASS_LOCK:-/tmp/dev-pass-$(id -u).lock}
poll_secs=0.1
wait_polls=${DEV_PASS_LOCK_POLLS:-1200}
orphan_polls=30
max_age_secs=30

held=0
release() {
    if [ "$held" = 1 ]; then
        held=0
        if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
            rm -rf "$lock"
        fi
    fi
}
trap release EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT

take_over() {
    local grave="$lock.stale.$$" seen
    mv "$lock" "$grave" 2>/dev/null || return 1
    seen=$(cat "$grave/pid" 2>/dev/null)
    if [ "$seen" = "$1" ]; then
        rm -rf "$grave"
    else
        mv "$grave" "$lock" 2>/dev/null || rm -rf "$grave"
    fi
}

n=0
orphan=0
until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$owner" ]; then
        orphan=0
        at=$(cat "$lock/at" 2>/dev/null)
        if ! kill -0 "$owner" 2>/dev/null || [ $(($(date +%s) - ${at:-0})) -gt "$max_age_secs" ]; then
            take_over "$owner" && continue
        fi
    else
        orphan=$((orphan + 1))
        if [ "$orphan" -ge "$orphan_polls" ]; then
            orphan=0
            take_over "" && continue
        fi
    fi
    n=$((n + 1))
    if [ "$n" -ge "$wait_polls" ]; then
        exit 124
    fi
    sleep "$poll_secs"
done
held=1
date +%s >"$lock/at"
printf '%s\n' "$$" >"$lock/pid"

PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch" timeout 10 pass show "$entry" </dev/null 2>/dev/null
