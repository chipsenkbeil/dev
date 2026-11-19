#!/usr/bin/env bash
set -u

state=$1
card=$2
fence=$3
ticks=$4
url=$5
entry=$6
tick=$7
name=$8
lease=$9
here=$(cd "$(dirname "$0")" && pwd)

sleeper=
stop_sleeper() {
    if [ -n "$sleeper" ]; then
        kill "$sleeper" 2>/dev/null
    fi
}
trap 'exit 143' TERM INT HUP
trap stop_sleeper EXIT

n=0
healed=0
while [ "$n" -lt "$ticks" ]; do
    sleep "$tick" &
    sleeper=$!
    wait "$sleeper"
    grep -qx "fence=$fence" "$state" 2>/dev/null || exit 0
    if [ -n "${DEV_BOARD_TOKEN:-}" ]; then
        read_out=$DEV_BOARD_TOKEN
    else
        read_out=$(bash "$here/passlock.sh" "$entry")
    fi
    token=${read_out%%$'\n'*}
    origin=
    case $read_out in
    *$'\n'*) origin=${read_out#*$'\n'} ;;
    esac
    case $token in
    '' | *[!A-Za-z0-9._~+/=-]*)
        n=$((n + 1))
        continue
        ;;
    esac
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
        curl -sS --connect-timeout 10 --max-time 30 -K - -X POST \
            -H 'Content-Type: application/json' -H "If-Owner-Fence: $fence" \
            --data-raw "{\"name\":\"$name\",\"ttl_seconds\":$lease}" \
            -o /dev/null -w '%{http_code}' "$url/api/tasks/$card/owner/renew" 2>/dev/null)
    token=
    code=${out##*[!0-9]}
    case $code in
    2??)
        healed=0
        date +%s >"$state.beat" 2>/dev/null
        ;;
    401)
        if [ "$origin" = keychain ] && [ "$healed" = 0 ]; then
            healed=1
            bash "$here/keychain.sh" drop "$entry" || break
        else
            break
        fi
        ;;
    4??) break ;;
    esac
    n=$((n + 1))
done

if grep -qx "fence=$fence" "$state" 2>/dev/null; then
    rm -f "$state"
fi
