#!/usr/bin/env bash
# scripts/pkg.sh — package dispatch over tools.tsv.
#   pkg.sh check [--manifest FILE]   report tool availability (Slice 1)
#   pkg.sh install ...               (Slice 2)
set -o pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pkg/lib.sh
# shellcheck disable=SC1091
source "$PKG_DIR/pkg/lib.sh"

MANIFEST="$PKG_DIR/../tools.tsv"

PKG_LOADED_DRIVER=""
load_driver() {
    [ "$1" = "$PKG_LOADED_DRIVER" ] && return 0
    local d="$PKG_DIR/pkg/$1.sh"
    if [ ! -f "$d" ]; then
        printf 'error: no driver %s (add it in a later slice)\n' "$d" >&2
        return 1
    fi
    # shellcheck disable=SC1090,SC1091
    source "$d"
    PKG_LOADED_DRIVER="$1"
}

_in_list() {
    local x="$1"
    shift
    local i
    for i in "$@"; do [ "$i" = "$x" ] && return 0; done
    return 1
}

usage() {
    printf 'usage: pkg.sh check [--manifest FILE]\n'
    printf '       pkg.sh install [--manifest FILE] [--dry-run] [--log-file FILE] [name...]\n'
}

# PKG_LOG_FILE — when non-empty, drivers route the real install command's
# stdout+stderr here (via pkg_run in pkg/lib.sh) instead of the terminal. Set
# by cmd_install's --log-file option; drivers are sourced into this process
# so they see the global directly.
PKG_LOG_FILE=""

cmd_check() {
    local manifest="$MANIFEST"
    while [ $# -gt 0 ]; do
        case "$1" in
        --manifest)
            manifest="$2"
            shift 2
            ;;
        *)
            printf 'unknown arg: %s\n' "$1" >&2
            return 2
            ;;
        esac
    done

    local mgr
    mgr="$(detect_primary_manager)"
    if [ -z "$mgr" ]; then
        printf 'error: no supported package manager detected on this OS\n' >&2
        return 1
    fi

    local driver="$PKG_DIR/pkg/$mgr.sh"
    if [ ! -f "$driver" ]; then
        printf 'error: no driver %s (added in a later slice)\n' "$driver" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$driver"

    local col
    col="$(manifest_column_index "$manifest" "$mgr")"
    if [ -z "$col" ]; then
        printf 'error: manager column "%s" not found in %s header\n' "$mgr" "$manifest" >&2
        return 1
    fi

    # Capture (not process-substitute) so an undefined-variable failure in
    # manifest_rows propagates: process substitution would swallow its exit code.
    local rows
    if ! rows="$(manifest_rows "$manifest" "$col")"; then
        return 1 # error already printed to stderr by manifest_rows
    fi

    [ -n "$rows" ] || return 0

    local name binary cell parsed effbin
    # Safe: manifest_rows' first field (name) is never empty, so the leading-empty
    # -field collapse that breaks cell parsing cannot occur here.
    while IFS=$'\t' read -r name binary cell; do
        parsed="$(parse_cell "$cell")" || continue
        split_cell "$parsed"
        effbin="$(resolve_binary "$binary" "$PC_BIN")"
        pkg_status "$name" "$effbin" "$PC_PACKAGE" "$PC_CHANNEL"
    done <<<"$rows"
}

cmd_install() {
    local manifest="$MANIFEST" dry_run=0
    local -a names=()
    while [ $# -gt 0 ]; do
        case "$1" in
        --manifest)
            manifest="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --log-file)
            # shellcheck disable=SC2034  # consumed by pkg_run() in the
            # dynamically-sourced pkg/lib.sh and pkg/*.sh drivers
            PKG_LOG_FILE="$2"
            shift 2
            ;;
        -*)
            printf 'unknown arg: %s\n' "$1" >&2
            return 2
            ;;
        *)
            names+=("$1")
            shift
            ;;
        esac
    done

    local mgr
    mgr="$(detect_primary_manager)"
    if [ -z "$mgr" ]; then
        printf 'error: no supported package manager detected on this OS\n' >&2
        return 1
    fi
    local col
    col="$(manifest_column_index "$manifest" "$mgr")"
    if [ -z "$col" ]; then
        printf 'error: manager column "%s" not found in %s header\n' "$mgr" "$manifest" >&2
        return 1
    fi

    # Capture (not process-substitute) so an undefined-variable failure in
    # manifest_rows propagates: process substitution would swallow its exit code.
    local rows
    if ! rows="$(manifest_rows "$manifest" "$col")"; then
        return 1 # error already printed to stderr by manifest_rows
    fi
    [ -n "$rows" ] || return 0

    local name binary cell parsed channel pkg repo binover effbin handler
    # Safe: manifest_rows' first field (name) is never empty, so the leading-empty
    # -field collapse that breaks cell parsing cannot occur here.
    while IFS=$'\t' read -r name binary cell; do
        if [ "${#names[@]}" -gt 0 ] && ! _in_list "$name" "${names[@]}"; then
            continue
        fi
        parsed="$(parse_cell "$cell")" || continue
        split_cell "$parsed"
        channel="$PC_CHANNEL"
        pkg="$PC_PACKAGE"
        repo="$PC_REPO"
        binover="$PC_BIN"
        effbin="$(resolve_binary "$binary" "$binover")"
        handler="$(channel_handler "$channel" "$mgr")"
        load_driver "$handler" || continue
        pkg_install "$name" "$effbin" "$pkg" "$channel" "$repo" "$dry_run"
    done <<<"$rows"
}

main() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
    check) cmd_check "$@" ;;
    install) cmd_install "$@" ;;
    "" | -h | --help) usage ;;
    *)
        printf 'unknown subcommand: %s\n' "$sub" >&2
        usage
        return 2
        ;;
    esac
}

main "$@"
