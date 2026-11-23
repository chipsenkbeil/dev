#!/usr/bin/env bash
set -u

subcommand=${1:-}
entry=${2:-}
timeout_secs=3
not_found=44

command -v security >/dev/null 2>&1 || exit 1
case $entry in
'' | *[!A-Za-z0-9_./\ -]*) exit 1 ;;
esac

service="dev-pomb-token:$entry"
account=${USER:-$(id -un)}

case $subcommand in
get)
    timeout "$timeout_secs" security find-generic-password -a "$account" -s "$service" -w </dev/null 2>/dev/null
    ;;
put)
    IFS= read -r token
    case $token in
    '' | *[!A-Za-z0-9._~+/=-]*) exit 1 ;;
    esac
    printf 'add-generic-password -U -a "%s" -s "%s" -T /usr/bin/security -w "%s"\n' \
        "$account" "$service" "$token" |
        timeout "$timeout_secs" security -i >/dev/null 2>&1
    ;;
drop)
    timeout "$timeout_secs" security delete-generic-password -a "$account" -s "$service" \
        </dev/null >/dev/null 2>&1
    status=$?
    [ "$status" = 0 ] || [ "$status" = "$not_found" ]
    ;;
*)
    exit 2
    ;;
esac
