#!/usr/bin/env bash
# dev: the fallback for verbs the Lua dispatcher does not handle.
#
# `dev <verb>` runs `.dev/<verb>.sh` at the repo root when it is executable.
# `dev <noun> <sub>` runs `.dev/<noun>/<sub>.sh` the same way, and built-in nouns
# sit beside the flat verbs. `dev help` lists a noun once and `dev help <noun>`
# lists its subcommands.
#
# This file serves what dev has no handler for: an unknown verb or a project noun.
# DOTFILES overrides where the dotfiles repo is found.
set -euo pipefail

die() {
    printf 'dev: %s\n' "$*" >&2
    exit 1
}

# dev_uid: the uid the launcher saw, else id -u.
dev_uid() {
    if [ -n "${DEV_UID:-}" ]; then printf '%s\n' "$DEV_UID"; else id -u; fi
}

# dev_os: the system name the launcher saw, else uname.
dev_os() {
    if [ -n "${DEV_OS:-}" ]; then printf '%s\n' "$DEV_OS"; else uname; fi
}

# verbose_level <value>: 0, 1 or 2 for a VERBOSE value, where empty, no and false are 0 and any other word is 1.
verbose_level() {
    case "$1" in
    "" | no | false) echo 0 ;;
    *[!0-9]*) echo 1 ;;
    *) echo $((10#$1 > 2 ? 2 : 10#$1)) ;;
    esac
}

# show <command...>: print "+ command" on stderr when VERBOSE is 1 or more.
show() {
    if [ "$VERBOSE" -ge 1 ]; then
        printf '+ %s\n' "$*" >&2
    fi
}

# script_path <verb>: the .dev script for a verb, where "noun sub" maps to .dev/noun/sub.sh.
script_path() {
    printf '%s/.dev/%s.sh\n' "$ROOT" "${1// //}"
}

# run_script <verb> [args...]: show and exec the verb's .dev script.
run_script() {
    local script
    script=$(script_path "$1")
    [ "$(dev_uid)" -ne 0 ] || die "refusing to run ${script#"$ROOT"/} as root"
    show "${script#"$ROOT"/}" "${@:2}"
    shift
    exec "$script" "$@"
}

# trace_file: the BASH_ENV file that turns on xtrace, beside dev in the stow package.
trace_file() {
    local self
    self=$DEV_SELF
    printf '%s\n' "$(dirname "$self")/../share/dev/xtrace.bash"
}

has_override() {
    case "$1" in
    *" "*)
        case " $(builtin_subs "${1% *}" | tr '\n' ' ')" in *" ${1#* } "*) return 1 ;; esac
        ;;
    *) [ "$(builtin_field "$1" 2)" = noun ] && return 1 ;;
    esac
    [ -x "$(script_path "$1")" ]
}

# root_allowed <verb> [sub]: whether dev may run this as root, which is tools install and tools check only.
root_allowed() {
    case "$1" in
    tools)
        case "${2:-}" in install | check) return 0 ;; esac
        ;;
    esac
    return 1
}

repo_root() {
    local root dir
    if command -v jj >/dev/null 2>&1 && root=$(jj root 2>/dev/null); then
        printf '%s\n' "$root"
        return
    fi
    if root=$(git rev-parse --show-toplevel 2>/dev/null); then
        printf '%s\n' "$root"
        return
    fi
    dir=$(pwd -P)
    while [ "$dir" != / ]; do
        if [ -d "$dir/.dev" ]; then
            printf '%s\n' "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
    pwd -P
}

# --- help ---

# builtin_table: one row per built-in verb, "name|handler|flags|usage|description|group".
# The handler runs when no .dev script overrides the verb, and is empty for a verb that
# runs the project type's builtin_<type>. Usage is the fixed command line `dev help <verb>` shows.
# A noun has a row with the handler `noun`, and each of its subcommands a row named "noun sub" that takes the noun's group.
# The group heads the verb in `dev help`, and `hidden` keeps it to `dev help -a`.
builtin_table() {
    cat <<'TABLE'
TABLE
}

BUILTIN_ROWS=$(builtin_table)
VERBS=$(cut -d"|" -f1 <<<"$BUILTIN_ROWS" | grep -v " " | tr "\n" " ")

# builtin_field <verb> <column>: that column of the verb's row, 2 handler, 3 flags, 4 usage, 5 description, 6 group.
builtin_field() {
    awk -F'|' -v v="$1" -v n="$2" '$1 == v { print $n }' <<<"$BUILTIN_ROWS"
}

builtin_desc() {
    builtin_field "$1" 5
}

# script_desc <script>: the first comment line after the shebang, without "# ".
# Shellcheck directives and the flags, group and hidden lines do not count.
script_desc() {
    awk '
        NR == 1 { next }
        /^[[:space:]]*$/ { next }
        /^# *shellcheck / { next }
        /^# *flags:/ { next }
        /^# *group:/ { next }
        /^# *hidden *$/ { next }
        /^#/ { sub(/^# ?/, ""); print; exit }
        { exit }
    ' "$1"
}

# project_subs <noun>: the names of the executable scripts in .dev/<noun>/, one per line.
project_subs() {
    local script name
    for script in "$ROOT/.dev/$1"/*.sh; do
        [ -x "$script" ] || continue
        name=$(basename "$script" .sh)
        case "$name" in __*) continue ;; esac
        printf '%s\n' "$name"
    done
}

# builtin_subs <noun>: the subcommand names of a built-in noun, one per line.
builtin_subs() {
    awk -F'|' -v n="$1 " 'index($1, n) == 1 { print substr($1, length(n) + 1) }' <<<"$BUILTIN_ROWS"
}

# is_noun <name>: true for a built-in noun or a .dev/<name>/ directory of scripts,
# unless a flat .dev/<name>.sh takes the whole name.
is_noun() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    has_override "$1" && return 1
    [ "$(builtin_field "$1" 2)" = noun ] && return 0
    case " $VERBS " in *" $1 "*) return 1 ;; esac
    [ -n "$(project_subs "$1")" ]
}

# noun_subs_table <noun>: "sub<TAB>origin<TAB>description" per subcommand, built-ins first.
noun_subs_table() {
    local noun=$1 sub script desc origin
    for sub in $(builtin_subs "$noun"); do
        origin=builtin
        desc=$(builtin_desc "$noun $sub")
        if has_override "$noun $sub"; then
            origin=override
            desc=$(script_desc "$(script_path "$noun $sub")")
            : "${desc:=$(builtin_desc "$noun $sub")}"
        fi
        printf '%s\t%s\t%s\n' "$sub" "$origin" "$desc"
    done
    for sub in $(project_subs "$noun"); do
        case " $(builtin_subs "$noun" | tr '\n' ' ')" in *" $sub "*) continue ;; esac
        script=$(script_path "$noun $sub")
        printf '%s\tlocal\t%s\n' "$sub" "$(script_desc "$script")"
    done
}

# noun_has_sub <noun> <sub>: true when the noun has that subcommand.
noun_has_sub() {
    noun_subs_table "$1" | awk -F'\t' -v s="$2" '$1 == s { found = 1 } END { exit !found }'
}

# builtin_commands <verb> <type>: the command lines the built-in runs, one per line.
builtin_commands() {
    local verb=$1 type=$2
    echo "(none: no built-in $verb for $type projects)"
}

# usage: the curated overview on stderr, for a bad verb or bad arguments.
usage() {
    if [ "$(dev_uid)" -ne 0 ]; then
        "$DEV_SELF" help >&2
    fi
}

detect_type() {
    if [ -f "$ROOT/Cargo.toml" ]; then
        echo rust
    elif [ -f "$ROOT/main.lua" ] && [ -f "$ROOT/conf.lua" ]; then
        echo love2d
    elif [ -f "$ROOT/project.godot" ]; then
        echo godot
    elif [ -f "$ROOT/package.json" ]; then
        echo node
    elif [ -n "$(find "$ROOT" -mindepth 1 \( -name '.*' -o -name node_modules -o -name target \) -prune -o -type f -name '*.lua' -print -quit)" ]; then
        echo lua
    elif [ -f "$ROOT/Makefile" ]; then
        echo make
    else
        echo none
    fi
}

main() {
    local verb sub trace count=0
    local -a args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --)
            shift
            args+=("$@")
            break
            ;;
        --verbose) count=$((count + 1)) ;;
        --remote | --detach) ;;
        -v*)
            if [[ "$1" =~ ^-v+$ ]]; then
                count=$((count + ${#1} - 1))
            else
                args+=("$1")
            fi
            ;;
        *) args+=("$1") ;;
        esac
        shift
    done
    set -- ${args[@]+"${args[@]}"}
    if [ "$count" -gt 0 ]; then
        VERBOSE=$(verbose_level "$count")
    else
        VERBOSE=$(verbose_level "${VERBOSE:-}")
    fi
    if [ "$VERBOSE" -ge 1 ]; then
        export VERBOSE
    else
        export -n VERBOSE
    fi
    if [ "$VERBOSE" -ge 2 ]; then
        trace=$(trace_file)
        if [ -f "$trace" ]; then
            export BASH_ENV=$trace PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
            set -x
        else
            printf 'dev: trace file %s is missing, showing commands only\n' "$trace" >&2
            VERBOSE=1
        fi
    fi

    if [ "$(dev_uid)" -eq 0 ]; then
        if ! root_allowed "${1:-help}" "${2:-}"; then
            printf 'dev: as root, dev runs only tools install and tools check\n' >&2
            exit 2
        fi
        if [ "$(dev_os)" != Linux ]; then
            printf 'dev: as root, dev runs only on Linux\n' >&2
            exit 2
        fi
        printf 'dev: dev tools needs luajit in /usr/bin or /usr/local/bin\n' >&2
        exit 1
    fi
    ROOT=$(repo_root)
    if [ "$#" -eq 0 ]; then
        set -- help
    fi
    verb=$1
    shift
    case "$verb" in
    __commands)
        builtin_commands "${1:-}" "$(detect_type)"
        return 0
        ;;
    esac
    if is_noun "$verb"; then
        sub=${1:-}
        case "$sub" in
        "")
            printf 'dev %s: needs a subcommand\n\n' "$verb" >&2
            "$DEV_SELF" help "$verb" >&2
            exit 2
            ;;
        esac
        if ! noun_has_sub "$verb" "$sub"; then
            printf 'dev %s: unknown subcommand %s\n\n' "$verb" "$sub" >&2
            "$DEV_SELF" help "$verb" >&2
            exit 2
        fi
        shift
        verb="$verb $sub"
    fi
    case "$verb" in
    *" "*)
        if has_override "$verb"; then
            run_script "$verb" "$@"
        fi
        "$(builtin_field "$verb" 2)" "$@"
        return
        ;;
    esac
    case " $VERBS " in
    *" $verb "*) ;;
    *)
        if [[ "$verb" =~ ^[A-Za-z0-9_-]+$ ]] && has_override "$verb"; then
            run_script "$verb" "$@"
        fi
        printf 'dev: unknown verb %s\n\n' "$verb" >&2
        usage >&2
        exit 2
        ;;
    esac

    if has_override "$verb"; then
        run_script "$verb" "$@"
    fi
    "$(builtin_field "$verb" 2)" "$@"
}

main "$@"
