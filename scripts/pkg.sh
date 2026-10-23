#!/usr/bin/env bash
# scripts/pkg.sh — package dispatch over a tools.tsv manifest (default .dev/tools.tsv).
#   pkg.sh check [--manifest FILE] [--group NAME]   report tool availability
#   pkg.sh install ...               install tools
set -o pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=pkg/lib.sh
# shellcheck disable=SC1091
source "$PKG_DIR/pkg/lib.sh"

MANIFEST="$PKG_DIR/../.dev/tools.tsv"

PKG_LOADED_DRIVER=""
load_driver() {
    [ "$1" = "$PKG_LOADED_DRIVER" ] && return 0
    local d="$PKG_DIR/pkg/$1.sh"
    if [ ! -f "$d" ]; then
        printf 'error: no driver %s\n' "$d" >&2
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
    printf 'usage: pkg.sh check [--manifest FILE] [--group NAME]\n'
    printf '       pkg.sh install [--manifest FILE] [--dry-run] [--force] [--group NAME] [--scope system|user] [--log-file FILE] [name...]\n'
}

# PKG_LOG_FILE — when non-empty, drivers route the real install command's
# stdout+stderr here (via pkg_run in pkg/lib.sh) instead of the terminal. Set
# by cmd_install's --log-file option; drivers are sourced into this process
# so they see the global directly.
PKG_LOG_FILE=""

export PKG_FORCE=0

need_value() {
    if [ $# -lt 2 ]; then
        printf '%s needs a value\n' "$1" >&2
        return 1
    fi
}

cmd_check() {
    local manifest="$MANIFEST" group="" group_set=0
    while [ $# -gt 0 ]; do
        case "$1" in
        --manifest)
            need_value "$@" || return 2
            manifest="$2"
            shift 2
            ;;
        --group)
            need_value "$@" || return 2
            group="$2"
            group_set=1
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
        printf 'error: no driver %s\n' "$driver" >&2
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
    if ! rows="$(manifest_rows "$manifest" "$col" "$group")"; then
        return 1 # error already printed to stderr by manifest_rows
    fi
    if [ "$group_set" = 1 ] && { [ -z "$group" ] || [ -z "$rows" ]; }; then
        printf 'unknown group: %s\n' "$group" >&2
        return 2
    fi

    [ -n "$rows" ] || return 0

    local name binary cell parsed effbin missing=0

    # Safe: manifest_rows' first field (name) is never empty, so the leading-empty
    # -field collapse that breaks cell parsing cannot occur here.
    while IFS=$'\t' read -r name binary cell; do
        parsed="$(parse_cell "$cell")" || continue
        split_cell "$parsed"
        effbin="$(resolve_binary "$binary" "$PC_BIN")"
        if [ "$PC_CHANNEL" = script ] && [ "$effbin" = "-" ]; then
            case "$PC_PACKAGE" in
            http://* | https://*)
                printf '[?] %s\t(remote script, no probe)\n' "$name"
                ;;
            *)
                # shellcheck disable=SC2086  # the cell is "path [args]", split as the install path does
                if [ "$(id -u)" -eq 0 ]; then
                    printf '[?] %s\t(script row, never run as root)\n' "$name"
                elif bash $PC_PACKAGE --check </dev/null >/dev/null 2>&1; then
                    printf '[x] %s\t(script --check)\n' "$name"
                else
                    printf '[ ] %s\n' "$name"
                    missing=1
                fi
                ;;
            esac
            continue
        fi
        if ! valid_package "$PC_CHANNEL" "$PC_PACKAGE" "$PC_REPO"; then
            printf '[ ] %s\t(refusing the package or repo %q in the manifest)\n' "$name" "$PC_PACKAGE ${PC_REPO}"
            missing=1
            continue
        fi
        pkg_status "$name" "$effbin" "$PC_PACKAGE" "$PC_CHANNEL" || missing=1
    done <<<"$rows"
    return "$missing"
}

cmd_install() {
    local manifest="$MANIFEST" dry_run=0 scope="" group="" group_set=0
    local -a names=()
    while [ $# -gt 0 ]; do
        case "$1" in
        --manifest)
            need_value "$@" || return 2
            manifest="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --force)
            PKG_FORCE=1
            shift
            ;;
        --group)
            need_value "$@" || return 2
            group="$2"
            group_set=1
            shift 2
            ;;
        --scope)
            need_value "$@" || return 2
            case "$2" in
            system | user) scope="$2" ;;
            *)
                printf -- '--scope takes system or user, got %s\n' "$2" >&2
                return 2
                ;;
            esac
            shift 2
            ;;
        --log-file)
            need_value "$@" || return 2

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
    if [ "$PKG_FORCE" = 1 ] && [ "${#names[@]}" -eq 0 ]; then
        printf -- '--force needs at least one tool name\n' >&2
        return 2
    fi

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
    local rows allrows
    if ! allrows="$(manifest_rows "$manifest" "$col")"; then
        return 1 # error already printed to stderr by manifest_rows
    fi
    rows="$allrows"
    if [ "$group_set" = 1 ]; then
        rows=""
        [ -z "$group" ] || rows="$(manifest_rows "$manifest" "$col" "$group")"
        if [ -z "$rows" ]; then
            printf 'unknown group: %s\n' "$group" >&2
            return 2
        fi
    fi
    [ -n "$rows" ] || return 0

    local name binary cell parsed channel pkg repo binover effbin handler row_scope
    local -a failed=() third_party=()
    for name in ${names[@]+"${names[@]}"}; do
        if ! grep -Fxq -- "$name" <<<"$(cut -f1 <<<"$rows")"; then
            if grep -Fxq -- "$name" <<<"$(cut -f1 <<<"$allrows")"; then
                printf 'tool %s is not in group %s\n' "$name" "$group" >&2
            else
                printf 'unknown tool: %s\n' "$name" >&2
            fi
            return 2
        fi
    done

    # Safe: manifest_rows' first field (name) is never empty, so the leading-empty
    # -field collapse that breaks cell parsing cannot occur here.
    while IFS=$'\t' read -r name binary cell; do
        if [ "${#names[@]}" -gt 0 ] && ! _in_list "$name" "${names[@]}"; then
            continue
        fi
        parsed="$(parse_cell "$cell")" || continue
        split_cell "$parsed"
        channel="$PC_CHANNEL"
        row_scope="$(channel_scope "$channel")"
        case "$scope:$row_scope" in
        system:user | user:system | user:third_party) continue ;;
        system:third_party)
            third_party+=("$name ($channel:)")
            continue
            ;;
        esac
        pkg="$PC_PACKAGE"
        repo="$PC_REPO"
        if ! valid_package "$channel" "$pkg" "$repo"; then
            printf '  ! %s: refusing the package or repo %q in the manifest\n' "$name" "$pkg ${repo}" >&2
            failed+=("$name")
            continue
        fi
        binover="$PC_BIN"
        effbin="$(resolve_binary "$binary" "$binover")"
        handler="$(channel_handler "$channel" "$mgr")"
        if ! load_driver "$handler" || ! pkg_install "$name" "$effbin" "$pkg" "$channel" "$repo" "$dry_run"; then
            failed+=("$name")
        fi
    done <<<"$rows"
    if [ "${#third_party[@]}" -gt 0 ]; then
        printf 'skipped third-party rows (built into the image, not installed with root): %s\n' "${third_party[*]}"
    fi
    if [ "${#failed[@]}" -gt 0 ]; then
        printf 'install failed: %s\n' "${failed[*]}" >&2
        return 1
    fi
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
