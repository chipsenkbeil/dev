#!/usr/bin/env bash
set -u

entry=$1
pass_timeout_secs=10
here=$(cd "$(dirname "$0")" && pwd)

lock=${DEV_PASS_LOCK:-/tmp/dev-pass-$(id -u).lock}
wait_secs=${DEV_PASS_LOCK_SECS:-120}

read_keychain() {
    local cached
    cached=$(bash "$here/keychain.sh" get "$entry" | head -n 1)
    case $cached in
    '' | *[!A-Za-z0-9._~+/=-]*) return 1 ;;
    esac
    printf '%s\nkeychain\n' "$cached"
}

if [ -z "${DEV_PASS_LOCKED:-}" ]; then
    read_keychain && exit 0
    export DEV_PASS_LOCKED=1
    if command -v flock >/dev/null 2>&1; then
        exec flock -w "$wait_secs" -E 124 "$lock" bash "$0" "$entry"
    elif command -v lockf >/dev/null 2>&1; then
        lockf -k -t "${wait_secs%%.*}" "$lock" bash "$0" "$entry" &
        child=$!
        trap 'pkill -P "$child" 2>/dev/null; kill "$child" 2>/dev/null' TERM HUP INT
        wait "$child"
        code=$?
        [ "$code" = 75 ] && code=124
        exit "$code"
    fi
    printf 'Neither flock nor lockf is installed.\n' >&2
    exit 1
fi

read_keychain && exit 0

out=$(PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch" timeout "$pass_timeout_secs" pass show "$entry" </dev/null 2>/dev/null 3>&- 4>&- 5>&- 6>&-)
code=$?
if [ "$code" = 0 ]; then
    first=${out%%$'\n'*}
    printf '%s\n' "$first"
    printf '%s\n' "$first" | bash "$here/keychain.sh" put "$entry" 3>&- 4>&- 5>&- 6>&-
fi
exit "$code"
