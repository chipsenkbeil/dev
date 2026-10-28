# shellcheck shell=bash
# Shared state and functions for the .dev/<verb>.sh scripts. Sourced, never run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=../scripts/helpers.sh
source "$ROOT/scripts/helpers.sh"

VERB="$(basename "$0" .sh)"

# ARGS is read by the scripts that source this file.

# shellcheck disable=SC2034
# split_vars <args...>: export each NAME=value argument (the form `dev sync
# SYNC_DST=host` takes) and leave the rest in ARGS.
split_vars() {
    ARGS=()
    local a
    for a in "$@"; do
        case "$a" in
        [[:upper:]]*=*) export "${a?}" ;;
        *) ARGS+=("$a") ;;
        esac
    done
}

split_vars "$@"

# shellcheck disable=SC2034  # setup.sh reads HOST_OS
if [ "${OS:-}" = Windows_NT ]; then
    HOST_OS=Windows
else
    HOST_OS="$(uname)"
fi

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

usage_error() {
    printf 'dev %s: %s\n' "$VERB" "$*" >&2
    exit 2
}

no_args() {
    local a
    for a in ${ARGS[@]+"${ARGS[@]}"}; do
        case "$a" in
        -*) usage_error "unknown flag $a" ;;
        *) usage_error "unknown argument $a, $VERB takes only KEY=value arguments" ;;
        esac
    done
}
