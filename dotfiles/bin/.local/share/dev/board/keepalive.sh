#!/usr/bin/env bash
set -u

state=$1
card=$2
fence=$3
ticks=$4
url=$5
entry=$6
tick=$7
here=$(cd "$(dirname "$0")" && pwd)

n=0
while [ "$n" -lt "$ticks" ]; do
    sleep "$tick"
    grep -qx "fence=$fence" "$state" 2>/dev/null || exit 0
    token=$(bash "$here/passlock.sh" "$entry" | head -n 1)
    case $token in
    '' | *[!A-Za-z0-9._~+/=-]*)
        n=$((n + 1))
        continue
        ;;
    esac
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
        curl -sS --connect-timeout 10 --max-time 30 -K - -X POST \
            -H 'Content-Type: application/json' --data-raw "{\"fence\":$fence}" \
            -o /dev/null -w '%{http_code}' "$url/api/tasks/$card/claim/heartbeat" 2>/dev/null)
    token=
    code=${out##*[!0-9]}
    case $code in
    2??) ;;
    4??) break ;;
    esac
    n=$((n + 1))
done

if grep -qx "fence=$fence" "$state" 2>/dev/null; then
    rm -f "$state"
fi
