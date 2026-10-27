#!/usr/bin/env bash
# dev: the verbs not ported to Lua yet.
#
# `dev <verb>` runs `.dev/<verb>.sh` at the repo root when it is executable.
# `dev <noun> <sub>` runs `.dev/<noun>/<sub>.sh` the same way, and built-in nouns
# sit beside the flat verbs. `dev help` lists a noun once and `dev help <noun>`
# lists its subcommands.
#
# `dev help` and the completion and topic helpers, the project-type built-ins, deploy, guide
# and bootstrap run in Lua. This file serves what is left: push, pull, sync, init, tools and box.
#
# `dev sync` compares a project's copied lint files against the templates in
# the dotfiles repo, unless the project has its own .dev/sync.sh. DOTFILES
# overrides where that repo is found.
set -euo pipefail

TEMPLATE_BASE="dotfiles/claude/.claude/skills/style/lint"
PROJECT_TYPE=""
VCS_BACKEND="" VCS_ERROR=""
PUSH_REF="" PUSH_SHA="" PUSH_GUARD="" PUSH_REMOTES="" PUSH_NAMED="" PUSH_ERROR=""
FORGE_KIND="" FORGE_REMOTE="" FORGE_WHY=""
PULL_SYNC=0 PULL_BRANCH="" PULL_ERROR=""

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

has_line() { grep -Fxq -- "$2" <<<"$1"; }

usage_error() {
    printf 'dev %s: %s\n' "$1" "${*:2}" >&2
    exit 2
}

bad_arg() {
    local kind=argument
    case "$2" in -*) kind=flag ;; esac
    printf 'dev %s: unknown %s %s\n\n' "$1" "$kind" "$2" >&2
    usage >&2
    exit 2
}

no_more_args() {
    [ "$#" -le 1 ] || bad_arg "$1" "$2"
}

# need <binary> <install command>: one WARNING and exit 1 when the binary is missing.
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'WARNING: %s not found. Install with: %s\n' "$1" "$2" >&2
        exit 1
    fi
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

# run_cmd <command...>: show the command and run it.
run_cmd() {
    show "$@"
    "$@"
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

# root_project_dir: the first directory from the cwd up holding .jj, .git or .dev, else the cwd. It only tests that they exist and reads nothing in them.
root_project_dir() {
    local dir
    dir=$(pwd -P)
    while [ "$dir" != / ]; do
        if [ -e "$dir/.jj" ] || [ -e "$dir/.git" ] || [ -e "$dir/.dev" ]; then
            printf '%s\n' "$dir"
            return
        fi
        dir=$(dirname "$dir")
    done
    pwd -P
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
    if [ "$(dev_uid)" -eq 0 ]; then
        root_project_dir
        return
    fi
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

# vcs_backend: set VCS_BACKEND to jj when the repo has .jj, git when it has .git, else set VCS_ERROR and fail.
vcs_backend() {
    if [ -d "$ROOT/.jj" ]; then
        VCS_BACKEND=jj
    elif [ -e "$ROOT/.git" ]; then
        VCS_BACKEND=git
    else
        VCS_BACKEND=""
        VCS_ERROR="neither .jj nor .git found in $ROOT"
        return 1
    fi
}

# vcs_require: vcs_backend, plus jj installed when the backend is jj. Sets VCS_ERROR on failure.
vcs_require() {
    vcs_backend || return 1
    if [ "$VCS_BACKEND" = jj ] && ! command -v jj >/dev/null 2>&1; then
        VCS_ERROR="jj not found, install with: brew install jj"
        return 1
    fi
}

# vcs <op> [args]: an operation both backends offer, run on the backend vcs_backend set.
# Ops: remotes, branches, remote-add NAME URL, remote-add-hint.
vcs() {
    local op=$1
    shift
    case "$VCS_BACKEND:$op" in
    jj:remotes) jj --no-pager --color never -R "$ROOT" git remote list | awk '{print $1}' ;;
    git:remotes) git -C "$ROOT" remote ;;
    jj:branches) jj --no-pager --color never -R "$ROOT" bookmark list -T 'name ++ "\n"' ;;
    git:branches) git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads ;;
    jj:remote-add) run_cmd jj --no-pager -R "$ROOT" git remote add "$@" ;;
    git:remote-add) run_cmd git -C "$ROOT" remote add "$@" ;;
    jj:remote-add-hint) echo "jj git remote add" ;;
    git:remote-add-hint) echo "git remote add" ;;
    esac
}

# --- help ---

# builtin_table: one row per built-in verb, "name|handler|flags|usage|description|group".
# The handler runs when no .dev script overrides the verb, and is empty for a verb that
# runs the project type's builtin_<type>. Usage is the fixed command line `dev help <verb>` shows.
# A noun has a row with the handler `noun`, and each of its subcommands a row named "noun sub" that takes the noun's group.
# The group heads the verb in `dev help`, and `hidden` keeps it to `dev help -a`.
builtin_table() {
    cat <<'TABLE'
push|cmd_push|||Push the trunk bookmark (jj) or the current branch (git) to the remote of record (gerrit in a gerrit project, else origin), or to the remotes named|Share it
pull|cmd_pull|||Fetch the remote and rebase local work onto it|Share it
sync|cmd_sync|--check --yes -y||Compare copied lint files, the lints block, lib.rs attributes and docs/STYLE.md with the dotfiles templates|Set up a machine or project
init|cmd_init|--type --public --name --dry-run --no-gerrit|dev init [--type T] [--public] [--name N] [--dry-run] [--no-gerrit]|Seed a project with lint, CI and remotes|Set up a machine or project
tools|noun|||Install and check the tools in .dev/tools.tsv|Set up a machine or project
tools install|cmd_tools_install|--dry-run --force --group --system --user|dev tools install [--system or --user] [--group NAME] [--dry-run] [--force] [tool...]|Install the manifest's tools, only the package rows with --system or only the script and cargo rows with --user
tools check|cmd_tools_check|--group|dev tools check [--group NAME]|Report which of the manifest's tools are on PATH, exit 1 when one is missing
connect|cmd_box_connect|--ssh|dev connect [<box>] [--ssh]|Attach to a box over Eternal Terminal in a tmux session, picking, resuming or creating one first|Boxes
box|noun|||List, create, show, stop, resume, extend, delete and connect to dev boxes through ci box|Boxes
box ls|cmd_box_ls|--all|dev box ls [--all]|List the boxes with state, target, projects and time left, then the cap
box create|cmd_box_create|--target --shape --by --ttl --keep|dev box create [--target T] [--shape S] [--by LABEL] [--ttl HOURS or --keep] [PROJECT...]|Create a box and wait until it runs, with the hub's default target and shape, 4 hours unless told otherwise, and the current project by default
box show|cmd_box_show||dev box show BOX|Show one box as key: value lines
box stop|cmd_box_stop||dev box stop BOX|Stop a box, which ci deletes later unless it is resumed
box resume|cmd_box_resume|--ttl --keep|dev box resume BOX [--ttl HOURS or --keep]|Start a stopped box again, keeping its lifetime unless told otherwise
box extend|cmd_box_extend|--ttl --keep|dev box extend BOX (--ttl HOURS or --keep)|Replace a running box's lifetime, counted from now
box install-tools|cmd_box_install_tools||dev box install-tools BOX [PROJECT...]|Reinstall a running box's tools, for every project unless some are named
box delete|cmd_box_delete|--yes -y --no-archive|dev box delete BOX [-y or --yes] [--no-archive]|Archive a box's projects and delete it, or delete it with no archive under --no-archive, after asking unless -y
box connect|cmd_box_connect|--ssh|dev box connect [<box>] [--ssh]|Same as dev connect
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
    local verb=$1 type=$2 remote step
    case "$verb" in
    sync)
        if lint_set_for "$type" >/dev/null; then
            echo "diff the project's lint files against $(dotfiles_root)/$TEMPLATE_BASE/$(lint_set_for "$type")"
        else
            echo "(none: no lint templates for $type projects)"
        fi
        return
        ;;
    push)
        if ! push_resolve; then
            echo "(none: $PUSH_ERROR)"
            return
        fi
        for remote in $PUSH_REMOTES; do
            push_cmd "$remote"
            echo "${PUSH_CMD[*]}"
        done
        return
        ;;
    pull)
        if ! pull_resolve; then
            echo "(none: $PULL_ERROR)"
            return
        fi
        step=1
        while pull_cmd "$step"; do
            echo "${PULL_CMD[*]}"
            step=$((step + 1))
        done
        return
        ;;
    esac
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

# lint_set_for <type>: the lint set directory under TEMPLATE_BASE, or failure.
lint_set_for() {
    case "$1" in
    rust) echo rust ;;
    love2d | lua) echo lua ;;
    *) return 1 ;;
    esac
}

# trunk_name <bookmark list>: master or main, whichever the list holds.
trunk_name() {
    local name
    for name in master main; do
        if has_line "$1" "$name"; then
            echo "$name"
            return
        fi
    done
    return 1
}

# forge_store <args>: git config against the repo's own store, where the forge setting lives.
forge_store() {
    if [ "$VCS_BACKEND" = jj ]; then
        git --git-dir="$(jj --no-pager -R "$ROOT" git root)" config "$@"
    else
        git -C "$ROOT" config "$@"
    fi
}

# origin_on_github: true when the origin URL names github.com.
origin_on_github() {
    case "$(forge_store --get remote.origin.url 2>/dev/null || true)" in
    *github.com*) return 0 ;;
    esac
    return 1
}

# forge_resolve: set FORGE_KIND (gerrit, github or plain), FORGE_REMOTE and FORGE_WHY after vcs_require, or set PUSH_ERROR and fail.
# The order matches the jj scripts: JJ_FORGE, then git config forge.kind, then detection.
forge_resolve() {
    local remotes kind="${JJ_FORGE:-}" remote why=""
    remotes=$(remote_names)
    if [ -n "$kind" ]; then
        why="JJ_FORGE=$kind"
    else
        kind=$(forge_store --get forge.kind 2>/dev/null || true)
        if [ -n "$kind" ]; then why="git config forge.kind=$kind"; fi
    fi
    if [ -z "$kind" ]; then
        if has_line "$remotes" gerrit; then
            kind=gerrit
            why="detected: the project has a gerrit remote"
        elif origin_on_github; then
            kind=github
            why="detected: origin is on github.com"
        else
            kind=plain
            why="detected: no gerrit remote and origin is not on github.com"
        fi
    fi
    case "$kind" in
    gerrit | github | plain) ;;
    *)
        PUSH_ERROR="forge must be gerrit, github or plain (got: $kind, from $why)"
        return 1
        ;;
    esac
    remote=$(forge_store --get forge.remote 2>/dev/null || true)
    if [ -n "$remote" ]; then
        why="$why; remote from git config forge.remote"
    elif [ "$kind" = gerrit ]; then
        remote=gerrit
    else
        remote=origin
    fi
    if ! has_line "$remotes" "$remote"; then
        PUSH_ERROR="the remote of record $remote is not a remote of this project ($why)"
        return 1
    fi
    FORGE_KIND=$kind FORGE_REMOTE=$remote FORGE_WHY=$why
}

# push_resolve: set VCS_BACKEND, PUSH_REF, PUSH_SHA, PUSH_GUARD, PUSH_REMOTES (the default target) and PUSH_NAMED (every remote push accepts by name), or set PUSH_ERROR and fail.
push_resolve() {
    local remotes remote
    vcs_require || {
        PUSH_ERROR=$VCS_ERROR
        return 1
    }
    if [ "$VCS_BACKEND" = jj ]; then
        PUSH_REF=$(trunk_name "$(jj --no-pager --color never -R "$ROOT" bookmark list -T 'name ++ "\n"')") || {
            PUSH_ERROR="no master or main bookmark in $ROOT"
            return 1
        }
    else
        PUSH_REF=$(git -C "$ROOT" symbolic-ref --short -q HEAD) || {
            PUSH_ERROR="HEAD is detached in $ROOT, check out a branch to push"
            return 1
        }
        PUSH_SHA=$(git -C "$ROOT" rev-parse HEAD)
        PUSH_GUARD="$(dirname "$DEV_SELF")/commit-guard"
        if [ ! -x "$PUSH_GUARD" ]; then
            PUSH_ERROR="commit-guard is missing at $PUSH_GUARD, refusing to push without the attribution check"
            return 1
        fi
    fi
    remotes=$(remote_names)
    PUSH_NAMED=""
    for remote in origin gerrit; do
        if has_line "$remotes" "$remote"; then
            PUSH_NAMED+="$remote "
        fi
    done
    if [ -z "$PUSH_NAMED" ]; then
        PUSH_ERROR="no origin or gerrit remote"
        return 1
    fi
    forge_resolve || return 1
    PUSH_REMOTES="$FORGE_REMOTE "
    case " $PUSH_NAMED" in
    *" $FORGE_REMOTE "*) ;;
    *) PUSH_NAMED+="$FORGE_REMOTE " ;;
    esac
}

# push_cmd <remote>: set PUSH_CMD to the command that pushes to that remote, after push_resolve.
push_cmd() {
    if [ "$VCS_BACKEND" = jj ]; then
        PUSH_CMD=(jj --no-pager --color never -R "$ROOT" git push --remote "$1" -b "$PUSH_REF")
    else
        PUSH_CMD=("$PUSH_GUARD" push -- "$1" "$PUSH_SHA:refs/heads/$PUSH_REF")
    fi
}

cmd_push() {
    local remote out rc status=0 remotes
    for remote in "$@"; do
        case "$remote" in -*) bad_arg push "$remote" ;; esac
    done
    push_resolve || die "$PUSH_ERROR"
    remotes=$PUSH_REMOTES
    if [ "$#" -gt 0 ]; then
        remotes=""
        for remote in "$@"; do
            case " $PUSH_NAMED" in
            *" $remote "*) remotes+="$remote " ;;
            *) usage_error push "no remote $remote to push to, the project has: $PUSH_NAMED" ;;
            esac
        done
    fi
    printf 'forge %s, remote of record %s (%s)\n' "$FORGE_KIND" "$FORGE_REMOTE" "$FORGE_WHY"
    for remote in $remotes; do
        push_cmd "$remote"
        show "${PUSH_CMD[@]}"
        out=$(cd "$ROOT" && "${PUSH_CMD[@]}" 2>&1) && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s: pushed %s\n' "$remote" "$PUSH_REF"
        else
            printf '%s: push of %s failed\n' "$remote" "$PUSH_REF"
            status=1
        fi
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | sed 's/^/    /'
        fi
    done
    return "$status"
}

# pull_resolve: set VCS_BACKEND, PULL_SYNC and PULL_BRANCH, or set PULL_ERROR and fail.
pull_resolve() {
    vcs_require || {
        PULL_ERROR=$VCS_ERROR
        return 1
    }
    if [ "$VCS_BACKEND" = jj ]; then
        PULL_SYNC=0
        if jj --no-pager -R "$ROOT" config get aliases.sync >/dev/null 2>&1; then
            PULL_SYNC=1
        fi
        return 0
    fi
    PULL_BRANCH=$(git -C "$ROOT" symbolic-ref --short -q HEAD) || {
        PULL_ERROR="HEAD is detached in $ROOT, check out a branch to pull"
        return 1
    }
    if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
        PULL_ERROR="$ROOT has uncommitted changes, commit or stash them before pulling"
        return 1
    fi
}

# pull_cmd <step>: set PULL_CMD to that step of the pull, after pull_resolve, or fail past the last step.
pull_cmd() {
    case "$VCS_BACKEND:$PULL_SYNC:$1" in
    jj:1:1) PULL_CMD=(jj --no-pager -R "$ROOT" sync) ;;
    jj:0:1) PULL_CMD=(jj --no-pager -R "$ROOT" git fetch --all-remotes) ;;
    jj:0:2) PULL_CMD=(jj --no-pager -R "$ROOT" rebase -o 'trunk()' --skip-emptied) ;;
    git:*:1) PULL_CMD=(git -C "$ROOT" pull --rebase origin "$PULL_BRANCH") ;;
    *) return 1 ;;
    esac
}

cmd_pull() {
    local step=1
    no_more_args pull "$@"
    pull_resolve || die "$PULL_ERROR"
    while pull_cmd "$step"; do
        run_cmd "${PULL_CMD[@]}"
        step=$((step + 1))
    done
}

# --- tools ---

# tools_manifest: print the project's .dev/tools.tsv path, or say there is none and fail.
tools_manifest() {
    local manifest="$ROOT/.dev/tools.tsv"
    if [ ! -f "$manifest" ]; then
        echo "no .dev/tools.tsv"
        return 1
    fi
    printf '%s\n' "$manifest"
}

# root_trusted <manifest> <path> <strict>: die unless path is a non-symlink owned by uid 0 and not group or other writable. A sticky directory may be other-writable unless strict.
root_trusted() {
    local uid mode bits
    if [ -L "$2" ] || ! read -r uid mode < <(stat -c '%u %a' -- "$2" 2>/dev/null) || [ "$uid" != 0 ]; then
        die "refusing $1 as root: $2 must be owned by root and not writable by others"
    fi
    bits=$((8#$mode))
    if [ "$((bits & 8#022))" -ne 0 ]; then
        if [ "$3" = strict ] || [ "$((bits & 8#1000))" -eq 0 ]; then
            die "refusing $1 as root: $2 must be owned by root and not writable by others"
        fi
    fi
}

# root_manifest_copy <manifest>: require a root-owned chain, open the manifest once on fd 3, check that the opened file is a regular file inside the project, and copy it to a root-owned temp file. Sets MANIFEST_COPY.
root_manifest_copy() {
    local opened inside size dir
    [ -d /proc/$$/fd ] || die "as root, dev needs /proc to read $1"
    [ ! -e /proc/$$/fd/3 ] || die "fd 3 is already open, cannot read $1"
    root_trusted "$1" "$1" strict
    root_trusted "$1" "$ROOT/.dev" strict
    root_trusted "$1" "$ROOT" strict
    dir=$(dirname "$ROOT")
    while [ "$dir" != / ]; do
        root_trusted "$1" "$dir" ancestor
        dir=$(dirname "$dir")
    done
    root_trusted "$1" / ancestor
    exec 3<"$1" || die "cannot open $1"
    opened=$(readlink /proc/$$/fd/3) || die "cannot resolve $1"
    inside=$(realpath "$ROOT")
    if [ ! -f /proc/$$/fd/3 ]; then
        die "refusing $1 as root, it is not a regular file"
    fi
    case "$opened" in
    "$inside"/*) ;;
    *) die "refusing $1 as root, it resolves outside the project" ;;
    esac
    MANIFEST_COPY=$(mktemp /tmp/dev-tools.XXXXXX) || die "cannot make a temp file"
    trap 'rm -f "$MANIFEST_COPY"' EXIT
    head -c 262145 <&3 >"$MANIFEST_COPY"
    exec 3<&-
    size=$(wc -c <"$MANIFEST_COPY")
    if [ "$((size))" -gt 262144 ]; then
        die "refusing $1 as root: larger than 256 KiB"
    fi
    if LC_ALL=C awk 'length > 4096 { bad = 1 } END { exit !bad }' "$MANIFEST_COPY"; then
        die "refusing $1 as root: a line is longer than 4096 bytes"
    fi
}

# tools_pkg <sub> <manifest> <args...>: scripts/pkg.sh from the dotfiles clone, so the project needs no copy.
# It runs from the project root, where a manifest's script: paths are relative to.
# As root it reads a copy of the manifest and runs with a scrubbed environment.
tools_pkg() {
    local pkg sub=$1 manifest=$2 status
    local -a envv
    shift 2
    pkg="$(dotfiles_root)/scripts/pkg.sh"
    [ -f "$pkg" ] || die "no $pkg (set DOTFILES to the dotfiles repo)"
    cd "$ROOT"
    if [ "$(dev_uid)" -ne 0 ]; then
        show bash "$pkg" "$sub" --manifest "$manifest" "$@"
        exec bash "$pkg" "$sub" --manifest "$manifest" "$@"
    fi
    root_manifest_copy "$manifest"
    envv=(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8)
    if [ "$VERBOSE" -ge 1 ]; then envv+=("VERBOSE=$VERBOSE"); fi

    # shellcheck disable=SC2016  # PS4 is expanded by the traced shell
    if [ "$VERBOSE" -ge 2 ]; then envv+=("BASH_ENV=$(trace_file)" 'PS4=+ ${BASH_SOURCE##*/}:${LINENO}: '); fi
    show env -i "${envv[@]}" bash "$pkg" "$sub" --manifest "$MANIFEST_COPY" "$@"
    status=0
    env -i "${envv[@]}" bash "$pkg" "$sub" --manifest "$MANIFEST_COPY" "$@" || status=$?
    return "$status"
}

cmd_tools_install() {
    local manifest scope="" uid arg
    local -a opts=() tools=()
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        case "$arg" in
        --dry-run | --force) opts+=("$arg") ;;
        --group)
            [ "$#" -gt 0 ] || usage_error "tools install" "--group needs a name"
            opts+=(--group "$1")
            shift
            ;;
        --system | --user)
            [ -z "$scope" ] || [ "$scope" = "${arg#--}" ] || usage_error "tools install" "--system and --user cannot be combined"
            scope=${arg#--}
            ;;
        -*) usage_error "tools install" "unknown flag $arg" ;;
        *) tools+=("$arg") ;;
        esac
    done
    manifest=$(tools_manifest) || {
        echo "$manifest"
        return 0
    }
    uid=$(dev_uid)
    if [ -z "$scope" ] && [ "$uid" -eq 0 ]; then
        usage_error "tools install" "as root, pass --system"
    fi
    case "$scope" in
    system)
        if [ "$uid" -ne 0 ] && [ "$(dev_os)" != Darwin ]; then
            die "tools install --system installs packages and needs root, run it as root"
        fi
        ;;
    user)
        if [ "$uid" -eq 0 ]; then
            die "tools install --user installs into the user's home and refuses to run as root"
        fi
        ;;
    esac
    if [ -n "$scope" ]; then opts+=(--scope "$scope"); fi
    tools_pkg install "$manifest" ${opts[@]+"${opts[@]}"} ${tools[@]+"${tools[@]}"}
}

cmd_tools_check() {
    local manifest
    local -a opts=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --group)
            [ "$#" -gt 1 ] || usage_error "tools check" "--group needs a name"
            opts+=(--group "$2")
            shift 2
            ;;
        *) bad_arg "tools check" "$1" ;;
        esac
    done
    manifest=$(tools_manifest) || {
        echo "$manifest"
        return 0
    }
    tools_pkg check "$manifest" ${opts[@]+"${opts[@]}"}
}

# --- box ---

BOX_PROJECTS_DIR=/srv/projects

# shellcheck disable=SC2016  # jq programs, not shell expansions
BOX_JQ='
def span($s):
    if $s >= 86400 then "\($s / 86400 | floor)d"
    elif $s >= 3600 then "\($s / 3600 | floor)h"
    else "\($s / 60 | floor)m" end;
def left:
    if .state == "running" then
        if .expires_at == null then "kept"
        else ((.expires_at | fromdateiso8601) - now | floor) as $s
            | if $s <= 0 then "expired"
              elif $s >= 3600 then "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m left"
              else "\($s / 60 | floor)m left" end
        end
    elif .state == "stopped" and .delete_after != null then
        ((.delete_after | fromdateiso8601) - now | floor) as $s
            | if $s <= 0 then "deleted soon" else "deleted in \(span($s))" end
    else "" end;
def projs: if (.projects | length) == 0 then "-" else [.projects[].name] | join(",") end;
def tmux:
    if .tmux_sessions == null then "unknown"
    elif (.tmux_sessions | length) == 0 then "none"
    else [.tmux_sessions[] | "\(.name) (\(if .attached then "attached" else "idle \(span(.idle_seconds))" end))"] | join(", ") end;
def row: [.name, .state, .target, projs, left] | @tsv;
'

# box_need: die unless ci and jq are on PATH.
box_need() {
    command -v ci >/dev/null 2>&1 || die "ci not found on PATH, dev box runs ci box (install it from the ci repo)"
    command -v jq >/dev/null 2>&1 || die "jq not found on PATH, install it with: brew install jq"
}

# box_parse <sub> <allowed flags> [args...]: set B_TARGET, B_SHAPE, B_BY, B_TTL, B_KEEP, B_YES, B_ALL, B_SSH, B_NOARCH and B_POS.
box_parse() {
    local sub=$1 allowed=" $2 " arg value
    shift 2
    B_TARGET="" B_SHAPE="" B_BY="" B_TTL="" B_KEEP=0 B_YES=0 B_ALL=0 B_SSH=0 B_NOARCH=0
    B_POS=()
    while [ "$#" -gt 0 ]; do
        arg=$1
        shift
        case "$arg" in
        -?*)
            case "$allowed" in
            *" $arg "*) ;;
            *) usage_error "box $sub" "unknown flag $arg" ;;
            esac
            ;;
        esac
        case "$arg" in
        --target | --shape | --by | --ttl)
            [ "$#" -gt 0 ] || usage_error "box $sub" "$arg needs a value"
            value=$1
            shift
            case "$arg" in
            --target) B_TARGET=$value ;;
            --shape) B_SHAPE=$value ;;
            --by) B_BY=$value ;;
            --ttl)
                [[ "$value" =~ ^[1-9][0-9]*$ ]] || usage_error "box $sub" "--ttl is a whole number of hours, not $value"
                B_TTL=$value
                ;;
            esac
            ;;
        --keep) B_KEEP=1 ;;
        -y | --yes) B_YES=1 ;;
        --no-archive) B_NOARCH=1 ;;
        --all) B_ALL=1 ;;
        --ssh) B_SSH=1 ;;
        *) B_POS+=("$arg") ;;
        esac
    done
    if [ -n "$B_TTL" ] && [ "$B_KEEP" -eq 1 ]; then
        usage_error "box $sub" "--ttl and --keep cannot be combined"
    fi
}

# box_one <sub>: the single box name in B_POS, else a usage error.
box_one() {
    [ "${#B_POS[@]}" -gt 0 ] || usage_error "box $1" "needs a box name"
    [ "${#B_POS[@]}" -eq 1 ] || usage_error "box $1" "unexpected argument ${B_POS[1]}"
    BOX_NAME=${B_POS[0]}
    [[ "$BOX_NAME" =~ ^[a-z0-9-]{1,40}$ ]] || usage_error "box $1" "bad box name $BOX_NAME, a name is 1 to 40 of a-z, 0-9 and -"
}

# box_call <sub> <ci box args...>: run ci box with --json, keep its document in BOX_OUT, and exit with ci's code on failure.
box_call() {
    local sub=$1 rc=0 msg
    shift
    show ci box "$@"
    BOX_OUT=$(ci box "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
        if msg=$(printf '%s' "$BOX_OUT" | jq -er 'select(.ok == false) | .error.message' 2>/dev/null); then
            printf 'dev box %s: %s\n' "$sub" "$msg" >&2
        elif [ -n "$BOX_OUT" ]; then
            printf '%s\n' "$BOX_OUT" >&2
        fi
        exit "$rc"
    fi
    printf '%s' "$BOX_OUT" | jq -e '.ok == true' >/dev/null 2>&1 || die "ci box $1 printed no ok document"
}

# box_field <json> <jq filter>: a raw value from a JSON document.
box_field() {
    printf '%s' "$1" | jq -r "$2"
}

# box_project: the basename of the project root, failing outside a project.
box_project() {
    [ -d "$ROOT/.jj" ] || [ -e "$ROOT/.git" ] || [ -d "$ROOT/.dev" ] || return 1
    case "$(basename "$ROOT")" in
    -*)
        echo "dev box: not using $(basename "$ROOT") as the default project, a project name cannot start with -" >&2
        return 1
        ;;
    esac
    basename "$ROOT"
}

# box_summary <verb> <document>: "<verb> <name> (<target>, <shape>, <projects>), <time left>, host <tailnet_name>".
box_summary() {
    printf '%s' "$2" | jq -r --arg v "$1" "$BOX_JQ"'.box
        | "\($v) \(.name) (\(.target), \(.shape), \(projs)), \(if left == "" then .state else left end), host \(.tailnet_name // "-")"'
}

# box_table: pad tab-separated rows from stdin into aligned columns.
box_table() {
    awk -F'\t' '
        { rows[NR] = $0; for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i) }
        END {
            for (r = 1; r <= NR; r++) {
                n = split(rows[r], f, "\t"); line = ""
                for (i = 1; i <= n; i++) line = line (i < n ? sprintf("%-*s  ", w[i], f[i]) : f[i])
                sub(/ +$/, "", line)
                print line
            }
        }'
}

# box_cap <ls document>: the cap line.
box_cap() {
    box_field "$1" '.cap | "\(.running) of \(.running_max) running, \(.memory_limits_gib) of \(.memory_max_gib) GiB"'
}

cmd_box_ls() {
    box_parse ls "--all" "$@"
    [ "${#B_POS[@]}" -eq 0 ] || usage_error "box ls" "unexpected argument ${B_POS[0]}"
    box_need
    if [ "$B_ALL" -eq 1 ]; then box_call ls ls --json --all; else box_call ls ls --json; fi
    if [ "$(box_field "$BOX_OUT" '.boxes | length')" -eq 0 ]; then
        echo "no boxes"
    else
        printf '%s' "$BOX_OUT" | jq -r "$BOX_JQ"'.boxes[] | row' | box_table
    fi
    box_cap "$BOX_OUT"
}

# box_create_call: ci box create from B_TARGET, B_SHAPE, B_BY, B_POS (the projects), B_TTL and B_KEEP, then the summary line.
box_create_call() {
    local by=$B_BY
    local -a args=(create)
    [ -n "$by" ] || by=${USER:+human:$USER}
    [ -n "$by" ] || by=${LOGNAME:+human:$LOGNAME}
    [ -n "$by" ] || die "dev box create: neither USER nor LOGNAME is set, pass --by LABEL"
    [ -z "$B_TARGET" ] || args+=(--target "$B_TARGET")
    [ -z "$B_SHAPE" ] || args+=(--shape "$B_SHAPE")
    args+=(--by "$by")
    [ -z "$B_TTL" ] || args+=(--ttl "$B_TTL")
    [ "$B_KEEP" -eq 0 ] || args+=(--keep)
    args+=(--json)
    [ "${#B_POS[@]}" -eq 0 ] || args+=(-- "${B_POS[@]}")
    box_call create "${args[@]}"
    box_summary created "$BOX_OUT"
}

cmd_box_create() {
    local project
    box_parse create "--target --shape --by --ttl --keep" "$@"
    box_need
    if [ "${#B_POS[@]}" -eq 0 ] && project=$(box_project); then B_POS=("$project"); fi
    box_create_call
}

cmd_box_show() {
    box_parse show "" "$@"
    box_one show
    box_need
    box_call show show "$BOX_NAME" --json
    printf '%s' "$BOX_OUT" | jq -r "$BOX_JQ"'.box
        | "name: \(.name)", "state: \(.state)", "target: \(.target)", "shape: \(.shape)", "cpu: \(.cpu)", "memory_gib: \(.memory_gib)",
          "projects: \(projs)",
          "tailnet_name: \(.tailnet_name // "-")", "created_by: \(.created_by)",
          "ttl_hours: \(.ttl_hours // "kept")",
          (if .expires_at != null then "expires_at: \(.expires_at)" else empty end),
          (if .stopped_at != null then "stopped_at: \(.stopped_at)" else empty end),
          (if .delete_after != null then "delete_after: \(.delete_after)" else empty end),
          (if .state == "running" then "tmux_sessions: \(tmux)" else empty end),
          (if .archive != null then "archive: \(.archive.path)" else empty end),
          (if .error != null then "error: \(.error)" else empty end)'
}

cmd_box_stop() {
    box_parse stop "" "$@"
    box_one stop
    box_need
    box_call stop stop "$BOX_NAME" --json
    printf '%s' "$BOX_OUT" | jq -r '.box | "stopped \(.name)" + (if .delete_after == null then "" else
        ", deleted in \(((.delete_after | fromdateiso8601) - now) / 86400 | ceil | if . < 0 then 0 else . end)d unless resumed" end)'
}

cmd_box_resume() {
    local -a args=()
    box_parse resume "--ttl --keep" "$@"
    box_one resume
    box_need
    [ -z "$B_TTL" ] || args+=(--ttl "$B_TTL")
    [ "$B_KEEP" -eq 0 ] || args+=(--keep)
    box_call resume resume "$BOX_NAME" ${args[@]+"${args[@]}"} --json
    box_summary resumed "$BOX_OUT"
}

cmd_box_extend() {
    local -a args=()
    box_parse extend "--ttl --keep" "$@"
    box_one extend
    [ -n "$B_TTL" ] || [ "$B_KEEP" -eq 1 ] || usage_error "box extend" "needs --ttl HOURS or --keep"
    box_need
    [ -z "$B_TTL" ] || args+=(--ttl "$B_TTL")
    [ "$B_KEEP" -eq 0 ] || args+=(--keep)
    box_call extend extend "$BOX_NAME" "${args[@]}" --json
    box_summary extended "$BOX_OUT"
}

cmd_box_install_tools() {
    local -a args=()
    box_parse install-tools "" "$@"
    [ "${#B_POS[@]}" -gt 0 ] || usage_error "box install-tools" "needs a box name"
    BOX_NAME=${B_POS[0]}
    [[ "$BOX_NAME" =~ ^[a-z0-9-]{1,40}$ ]] || usage_error "box install-tools" "bad box name $BOX_NAME, a name is 1 to 40 of a-z, 0-9 and -"
    [ "${#B_POS[@]}" -eq 1 ] || args=(-- "${B_POS[@]:1}")
    box_need
    box_call install-tools install-tools "$BOX_NAME" --json ${args[@]+"${args[@]}"}
    printf '%s' "$BOX_OUT" | jq -r 'if (.installed | length) == 0 then "no projects" else .installed[]
        | if .manifest then "\(.project): tools installed" else "\(.project): no .dev/tools.tsv, nothing installed" end end'
}

cmd_box_delete() {
    local answer question args=()
    box_parse delete "--yes -y --no-archive" "$@"
    box_one delete
    question="Delete $BOX_NAME? Its projects are archived first."
    if [ "$B_NOARCH" -eq 1 ]; then
        question="Delete $BOX_NAME without an archive? Anything not pushed is lost."
        args=(--no-archive)
    fi
    if [ "$B_YES" -eq 0 ]; then
        { : </dev/tty; } 2>/dev/null || usage_error "box delete" "no terminal to ask on, pass -y to delete $BOX_NAME"
        printf '%s [y/N] ' "$question" >/dev/tty
        read -r answer </dev/tty || answer=""
        case "$answer" in
        y | Y | yes | YES) ;;
        *)
            echo "not deleted" >&2
            exit 1
            ;;
        esac
    fi
    box_need
    box_call delete delete "$BOX_NAME" ${args[@]+"${args[@]}"} --json
    printf '%s' "$BOX_OUT" | jq -r '.box | "deleted \(.name), " + (if .archive == null then "no archive" else "archive \(.archive.path)" end)'
}

# box_items <ls document> <project>: "name<TAB>label" per box, the project's boxes first, then the new-box item inside a project.
box_items() {
    local names rows
    names=$(printf '%s' "$1" | jq -r --arg p "$2" "$BOX_JQ"'.boxes | sort_by(if (any(.projects[]; .name == $p)) then 0 else 1 end)[] | .name')
    rows=$(printf '%s' "$1" | jq -r --arg p "$2" "$BOX_JQ"'.boxes | sort_by(if (any(.projects[]; .name == $p)) then 0 else 1 end)[] | row' | box_table)
    if [ -n "$names" ]; then paste -d '\t' <(printf '%s\n' "$names") <(printf '%s\n' "$rows"); fi
    if [ -n "$2" ]; then printf '__new__\tnew box for %s\n' "$2"; fi
}

# ci_known_hosts: the known_hosts file where ci keeps the host keys of the boxes it shows.
ci_known_hosts() {
    local state=${XDG_STATE_HOME:-}
    case "$state" in
    /*) ;;
    *) state=$HOME/.local/state ;;
    esac
    printf '%s/ci/known_hosts\n' "$state"
}

# box_attach <box object>: exec et into the box's tmux session, or ci box ssh when asked or et is missing.
box_attach() {
    local name host session dir user
    name=$(box_field "$1" .name)
    host=$(box_field "$1" '.tailnet_name // empty')
    if [ -z "$host" ]; then
        printf 'dev box connect: %s has no tailnet name yet (state %s)\n' "$name" "$(box_field "$1" .state)" >&2
        exit 6
    fi
    if [ "$(box_field "$1" '(.projects | length) > 0 and .projects[0].path == null')" = true ]; then
        printf 'dev box connect: %s has no project path yet (state %s)\n' "$name" "$(box_field "$1" .state)" >&2
        exit 6
    fi
    dir=$(printf '%s' "$1" | jq -r --arg d "$BOX_PROJECTS_DIR" '.projects[0].path // $d')
    if ! [[ "$dir" =~ ^/srv/projects(/[A-Za-z0-9][A-Za-z0-9._-]{0,63})?$ ]]; then
        printf 'dev box connect: refusing the project path %q of %s\n' "$dir" "$name" >&2
        exit 1
    fi
    session=$(box_field "$1" '(.projects[0].name // .name) | gsub("[^A-Za-z0-9_-]"; "_")')
    if [ "$B_SSH" -eq 0 ] && ! command -v et >/dev/null 2>&1; then
        echo "dev box connect: et not found, using ssh" >&2
        B_SSH=1
    fi
    if [ "$B_SSH" -eq 1 ]; then
        show ci box ssh "$name" -- tmux new -A -s "$session" -c "$dir"
        exec ci box ssh "$name" -- tmux new -A -s "$session" -c "$dir"
    fi
    box_call connect show "$name" --json
    host=$(box_field "$BOX_OUT" '.box.tailnet_name // empty')
    user=$(box_field "$BOX_OUT" '.box.ssh_user // empty')
    if [ -z "$host" ] || [ -z "$user" ]; then
        printf 'dev box connect: %s has no tailnet name or ssh user (state %s)\n' "$name" "$(box_field "$BOX_OUT" .box.state)" >&2
        exit 6
    fi
    show et --ssh-option "UserKnownHostsFile=$(ci_known_hosts)" --ssh-option StrictHostKeyChecking=yes \
        -c "tmux new -A -s $session -c $dir" "$user@$host"
    exec et --ssh-option "UserKnownHostsFile=$(ci_known_hosts)" --ssh-option StrictHostKeyChecking=yes \
        -c "tmux new -A -s $session -c $dir" "$user@$host"
}

cmd_box_connect() {
    local project="" ls items picker choice="" box state noauto=()
    box_parse connect "--ssh" "$@"
    [ "${#B_POS[@]}" -le 1 ] || usage_error "box connect" "unexpected argument ${B_POS[1]}"
    [ "${#B_POS[@]}" -eq 0 ] || box_one connect
    box_need
    project=$(box_project) || project=""
    box_call connect ls --json
    ls=$BOX_OUT
    if [ "${#B_POS[@]}" -eq 1 ]; then
        choice=$BOX_NAME
    else
        items=$(box_items "$ls" "$project")
        if [ -z "$items" ]; then
            echo "no boxes; create one with dev box create" >&2
            exit 1
        fi
        if [ "$(printf '%s\n' "$items" | wc -l)" -eq 1 ] && [ -n "$project" ]; then noauto=(--no-auto); fi
        picker="$(dotfiles_root)/scripts/select-items.sh"
        [ -f "$picker" ] || die "no $picker (set DOTFILES to the dotfiles repo)"
        choice=$(printf '%s\n' "$items" | bash "$picker" --title "Connect to a box" ${noauto[@]+"${noauto[@]}"}) || exit 1
        [ -n "$choice" ] || exit 1
    fi
    if [ "$choice" = __new__ ]; then
        B_TARGET="" B_SHAPE="" B_BY="" B_TTL="" B_KEEP=0 B_POS=()
        [ -z "$project" ] || B_POS=("$project")
        box_create_call
        box=$(printf '%s' "$BOX_OUT" | jq -c .box)
    else
        box=$(printf '%s' "$ls" | jq -c --arg n "$choice" '.boxes[] | select(.name == $n)')
        if [ -z "$box" ]; then
            printf 'dev box connect: no box named %s\n' "$choice" >&2
            exit 3
        fi
        state=$(box_field "$box" .state)
        case "$state" in
        running) ;;
        stopped)
            box_call connect resume "$choice" --json
            box_summary resumed "$BOX_OUT"
            box=$(printf '%s' "$BOX_OUT" | jq -c .box)
            ;;
        *)
            printf 'dev box connect: %s is %s, it must be running or stopped to connect\n' "$choice" "$state" >&2
            exit 6
            ;;
        esac
    fi
    box_attach "$box"
}

# --- templates ---

dotfiles_root() {
    local self
    if [ -n "${DOTFILES:-}" ] && [ "$(dev_uid)" -ne 0 ]; then
        printf '%s\n' "$DOTFILES"
    else
        self=$DEV_SELF

        # <dotfiles>/dotfiles/bin/.local/bin/dev, four levels below the repo.
        (cd "$(dirname "$self")/../../../.." && pwd)
    fi
}

# templates_dir <type>: the lint set directory for a project type.
templates_dir() {
    local repo set
    repo=$(dotfiles_root)
    set=$(lint_set_for "$1") || die "no lint templates for $1 projects"
    if [ ! -d "$repo/$TEMPLATE_BASE/$set" ]; then
        die "no lint templates at $repo/$TEMPLATE_BASE/$set (set DOTFILES to the dotfiles repo)"
    fi
    printf '%s\n' "$repo/$TEMPLATE_BASE/$set"
}

stable_channel() {
    local version
    version=$(rustc +stable --version 2>/dev/null || rustc --version 2>/dev/null) || return 1
    version=${version#rustc }
    printf '%s\n' "${version%% *}"
}

# The channel a project already pins wins, so a sync never moves the pin.
channel_for_project() {
    local line
    if [ -f "$ROOT/rust-toolchain.toml" ]; then
        line=$(sed -n '/^channel[[:space:]]*=/{p;q;}' "$ROOT/rust-toolchain.toml" || true)
        if [ -n "$line" ]; then
            line=${line#*=}
            line=${line//[ \"]/}
            printf '%s\n' "$line"
            return
        fi
    fi
    stable_channel || echo stable
}

# manifest <template dir>: lines of "project path<TAB>template path". The set is
# named by the template directory, and the Lua set ships love.yml to love2d only.
manifest() {
    local t=$1 f roots scripts rules
    rules=$(cd "$t/ast-grep" && find rules rule-test -type f | sort)
    case "$(basename "$t")" in
    rust)
        roots="rustfmt.toml rust-toolchain.toml clippy.toml deny.toml"
        scripts="lint.sh fmt.sh test.sh"
        ;;
    lua)
        roots="stylua.toml selene.toml luajit.yml"
        if [ "$PROJECT_TYPE" = love2d ]; then roots+=" love.yml"; fi
        scripts="lint.sh fmt.sh"
        ;;
    esac
    for f in $roots; do
        printf '%s\t%s\n' "$f" "$t/$f"
    done
    printf 'sgconfig.yml\t%s\n' "$t/ast-grep/sgconfig.yml"
    for f in $scripts; do
        printf '.dev/%s\t%s\n' "$f" "$t/$f"
    done
    printf '.dev/lint-lib.sh\t%s\n' "$t/../lint-lib.sh"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '.dev/ast-grep/%s\t%s\n' "$f" "$t/ast-grep/$f"
    done <<<"$rules"
}

# lint_project_tail: the project's own checks below the marker in .dev/lint.sh, with
# a leading newline, so a rendered template keeps them and sync never reports them.
lint_project_tail() {
    local marker='# --- project-specific checks below ---' tail
    [ -f "$ROOT/.dev/lint.sh" ] || return 0
    tail=$(sed -n "/^${marker}\$/,\$p" "$ROOT/.dev/lint.sh" | sed '1d')
    [ -n "$tail" ] && printf '\n%s' "$tail"
    return 0
}

# deny_with_project_tail <template text>: the template with the project's own text below the
# deny.toml marker kept as it is, or the template alone when the project has no marker.
deny_with_project_tail() {
    local content=$1 marker='# --- project-specific entries below (dev sync keeps them) ---' tail
    if [ -f "$ROOT/deny.toml" ] && grep -qxF "$marker" "$ROOT/deny.toml"; then
        tail=$(sed -n "/^${marker}\$/,\$p" "$ROOT/deny.toml" | sed '1d')
        printf '%s\n%s' "${content%%"$marker"*}$marker" "$tail"
    else
        printf '%s' "$content"
    fi
}

# render <project path> <template path> <channel>: the project copy of a template.
render() {
    local dest=$1 src=$2 channel=$3 content cd_old cd_new sg_old sg_new lib_old lib_new
    lib_old='/../lint-lib.sh'
    lib_new='/lint-lib.sh'
    sg_old='--config ast-grep/sgconfig.yml'
    sg_new='--config sgconfig.yml'

    # shellcheck disable=SC2016  # the template line is matched literally, not expanded
    cd_old='cd "$(dirname "${BASH_SOURCE[0]}")"'

    # shellcheck disable=SC2016  # the replacement line is written literally, not expanded
    cd_new='cd "$(dirname "${BASH_SOURCE[0]}")/.."'
    content=$(<"$src")
    case "$dest" in
    sgconfig.yml)
        content=${content/"  - rules"/"  - .dev/ast-grep/rules"}
        content=${content/"testDir: rule-test"/"testDir: .dev/ast-grep/rule-test"}
        ;;
    .dev/lint.sh)
        content=${content/"$cd_old"/"$cd_new"}
        content=${content/"$lib_old"/"$lib_new"}
        content=${content//"$sg_old"/"$sg_new"}
        content+=$(lint_project_tail)
        ;;
    .dev/fmt.sh)
        content=${content/"$cd_old"/"$cd_new"}
        content=${content/"$lib_old"/"$lib_new"}
        ;;
    .dev/test.sh)
        content=${content/"$cd_old"/"$cd_new"}
        ;;
    deny.toml)
        content=$(deny_with_project_tail "$content")
        ;;
    rust-toolchain.toml)
        content=$(printf '%s\n' "$content" | sed "s/^channel = .*/channel = \"$channel\"/")
        ;;
    selene.toml)
        if [ "$PROJECT_TYPE" = lua ]; then
            content=${content/'std = "love"'/'std = "luajit"'}
        fi
        ;;
    esac
    printf '%s\n' "$content"
}

# install_rendered <project path> <template path> <channel>
install_rendered() {
    local content
    mkdir -p "$(dirname "$ROOT/$1")"
    content=$(render "$1" "$2" "$3")
    printf '%s\n' "$content" >"$ROOT/$1"
    case "$1" in *.sh) chmod +x "$ROOT/$1" ;; esac
}

# lints_template_block <template dir>: the workspace lints without the paste header.
lints_template_block() {
    local block
    block=$(<"$1/workspace-lints.toml")
    printf '%s\n' "${block#*$'\n\n'}"
}

# lints_project_block: the [workspace.lints*] tables of the project Cargo.toml, from the
# first such line to the next other top-level table or the end, without trailing blanks.
lints_project_block() {
    local block
    [ -f "$ROOT/Cargo.toml" ] || return 0
    block=$(awk '
        done { next }
        /^\[/ { if ($0 ~ /^\[workspace\.lints/) { on = 1 } else if (on) { done = 1; next } }
        on { print }
    ' "$ROOT/Cargo.toml")
    [ -n "$block" ] && printf '%s\n' "$block"
    return 0
}

# lints_replace <block file>: swap the project block for the file, or append it.
lints_replace() {
    local out
    out=$(mktemp)
    if grep -q '^\[workspace\.lints' "$ROOT/Cargo.toml"; then
        awk -v blockfile="$1" '
            function emit(   l) { while ((getline l < blockfile) > 0) print l; close(blockfile) }
            done { print; next }
            /^\[/ {
                if ($0 ~ /^\[workspace\.lints/) { if (!on) { emit(); on = 1 } next }
                if (on) { on = 0; done = 1; print ""; print; next }
            }
            on { next }
            { print }
        ' "$ROOT/Cargo.toml" >"$out"
    else
        {
            cat "$ROOT/Cargo.toml"
            printf '\n'
            cat "$1"
        } >"$out"
    fi
    cat "$out" >"$ROOT/Cargo.toml"
    rm -f "$out"
}

# crate_dirs: the member crate directories (relative to the root), one per line.
crate_dirs() {
    local m d
    [ -f "$ROOT/Cargo.toml" ] || return 0
    if [ "$(yq -p toml -oy '.package.name' "$ROOT/Cargo.toml" 2>/dev/null)" != null ]; then
        echo .
    fi
    while IFS= read -r m; do
        [ -n "$m" ] && [ "$m" != null ] || continue
        for d in "$ROOT"/$m; do
            if [ -f "$d/Cargo.toml" ]; then
                d=${d#"$ROOT"/}
                echo "$d"
            fi
        done
    done < <(yq -p toml -oy '.workspace.members[]' "$ROOT/Cargo.toml" 2>/dev/null)
}

# crate_is_app <dir>: succeeds for a crate with publish = false.
crate_is_app() {
    grep -Eq '^publish[[:space:]]*=[[:space:]]*false' "$ROOT/$1/Cargo.toml"
}

# lib_crates: crate directories in library register that have a src/lib.rs.
lib_crates() {
    local d
    while IFS= read -r d; do
        [ -f "$ROOT/$d/src/lib.rs" ] || continue
        crate_is_app "$d" || echo "$d"
    done < <(crate_dirs)
}

# app_crates: crate directories with publish = false.
app_crates() {
    local d
    while IFS= read -r d; do
        ! crate_is_app "$d" || echo "$d"
    done < <(crate_dirs)
}

# lib_attr_line <template dir>: the attribute line of the lib-lints snippet.
lib_attr_line() {
    tail -n 1 "$1/lib-lints.rs.snippet"
}

# lib_attr_present <template dir> <crate dir>
lib_attr_present() {
    grep -Fxq "$(lib_attr_line "$1")" "$ROOT/$2/src/lib.rs"
}

# lib_attr_insert <template dir> <crate dir>: put the snippet after the leading //! block.
lib_attr_insert() {
    local file="$ROOT/$2/src/lib.rs" out
    out=$(mktemp)
    awk -v snip="$1/lib-lints.rs.snippet" '
        { lines[NR] = $0 }
        END {
            n = 0
            while (n < NR && lines[n + 1] ~ /^\/\/!/) n++
            for (i = 1; i <= n; i++) print lines[i]
            if (n > 0) print ""
            while ((getline s < snip) > 0) print s
            if (n < NR && lines[n + 1] != "") print ""
            for (i = n + 1; i <= NR; i++) print lines[i]
        }
    ' "$file" >"$out"
    cat "$out" >"$file"
    rm -f "$out"
}

cmd_sync() {
    local check=0 yes=0 t type channel dest src tmp rc=0 drifted=0 answer lib missing_libs="" guide style_drift=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --check) check=1 ;;
        -y | --yes) yes=1 ;;
        *) bad_arg sync "$1" ;;
        esac
        shift
    done
    if [ "$check" -eq 1 ] && [ "$yes" -eq 1 ]; then
        printf 'dev: sync takes --check or --yes, not both\n\n' >&2
        usage >&2
        exit 2
    fi
    type=$(detect_type)
    if ! lint_set_for "$type" >/dev/null; then
        echo "dev: no lint templates for $type projects"
        return 0
    fi
    PROJECT_TYPE=$type
    t=$(templates_dir "$type")
    if [ -f "$ROOT/Cargo.toml" ]; then
        need yq "brew install yq"
    fi
    channel=$(channel_for_project)
    SYNC_TMP=$(mktemp -d)
    tmp=$SYNC_TMP
    trap 'rm -rf "$SYNC_TMP"' EXIT

    while IFS=$'\t' read -r dest src; do
        mkdir -p "$(dirname "$tmp/$dest")"
        render "$dest" "$src" "$channel" >"$tmp/$dest"
        if [ ! -f "$ROOT/$dest" ]; then
            printf 'missing: %s\n' "$dest"
            drifted=1
        elif ! diff -q "$ROOT/$dest" "$tmp/$dest" >/dev/null; then
            printf 'differs: %s\n' "$dest"
            drifted=1
        fi
    done < <(manifest "$t")

    if [ -f "$ROOT/Cargo.toml" ]; then
        lints_template_block "$t" >"$tmp/lints.new"
        lints_project_block >"$tmp/lints.old"
        if [ ! -s "$tmp/lints.old" ]; then
            printf 'missing: [workspace.lints] block in Cargo.toml\n'
            drifted=1
        elif ! diff -q "$tmp/lints.old" "$tmp/lints.new" >/dev/null; then
            printf 'differs: [workspace.lints] block in Cargo.toml\n'
            drifted=1
        fi
    fi
    while IFS= read -r lib; do
        if ! lib_attr_present "$t" "$lib"; then
            printf 'missing: library-register attribute in %s/src/lib.rs\n' "$lib"
            missing_libs+="$lib"$'\n'
            drifted=1
        fi
    done < <(lib_crates)
    if [ -f "$ROOT/docs/STYLE.md" ] && grep -qx "$STYLE_MARKER" "$ROOT/docs/STYLE.md" &&
        guide=$(style_guide_for "$type") && [ -f "$guide" ]; then
        render_style "$guide" >"$tmp/STYLE.md"
        if ! diff -q "$ROOT/docs/STYLE.md" "$tmp/STYLE.md" >/dev/null; then
            printf 'differs: docs/STYLE.md above "%s"\n' "$STYLE_MARKER"
            style_drift=1
            drifted=1
        fi
    fi

    if [ "$drifted" -eq 0 ]; then
        echo "up to date"
        return 0
    fi
    if [ "$check" -eq 1 ]; then
        return 1
    fi
    if [ "$yes" -eq 0 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
        die "sync overwrites files and needs a terminal to confirm, pass --yes to apply without asking, or --check to list drift"
    fi
    while IFS=$'\t' read -r dest src; do
        if [ ! -f "$ROOT/$dest" ]; then
            diff -u /dev/null "$tmp/$dest" || true
        else
            diff -u "$ROOT/$dest" "$tmp/$dest" || true
        fi
    done < <(manifest "$t")
    if [ -f "$ROOT/Cargo.toml" ] && ! diff -q "$tmp/lints.old" "$tmp/lints.new" >/dev/null; then
        diff -u "$tmp/lints.old" "$tmp/lints.new" || true
    fi
    while IFS= read -r lib; do
        [ -n "$lib" ] && printf 'would insert into %s/src/lib.rs:\n%s\n' "$lib" "$(<"$t/lib-lints.rs.snippet")"
    done <<<"$missing_libs"
    [ "$style_drift" -eq 0 ] || diff -u "$ROOT/docs/STYLE.md" "$tmp/STYLE.md" || true
    if [ "$yes" -eq 1 ]; then
        answer=y
    else
        printf 'Overwrite these files, the lints block, the lib.rs attributes and the guide part of docs/STYLE.md with the templates? [y/N] '
        read -r answer
    fi
    case "$answer" in
    y | Y | yes)
        while IFS=$'\t' read -r dest src; do
            install_rendered "$dest" "$src" "$channel" || rc=1
        done < <(manifest "$t")
        if [ -f "$ROOT/Cargo.toml" ] && ! diff -q "$tmp/lints.old" "$tmp/lints.new" >/dev/null; then
            lints_replace "$tmp/lints.new" || rc=1
        fi
        while IFS= read -r lib; do
            [ -z "$lib" ] || lib_attr_insert "$t" "$lib" || rc=1
        done <<<"$missing_libs"
        [ "$style_drift" -eq 0 ] || cat "$tmp/STYLE.md" >"$ROOT/docs/STYLE.md" || rc=1
        echo "synced"
        ;;
    *) echo "aborted" ;;
    esac
    return "$rc"
}

# --- init ---

CREATED=""
SKIPPED=""
HUMAN=""
DRY=0

created() {
    CREATED+="$1"$'\n'
    if [ "$DRY" -eq 1 ]; then
        printf 'would create: %s\n' "$1"
    else
        printf 'created: %s\n' "$1"
    fi
}

skipped() {
    SKIPPED+="$1"$'\n'
    printf 'skipped: %s\n' "$1"
}

human() {
    HUMAN+="$1"$'\n'
}

# remote_names: the remotes the project already has, one per line.
remote_names() {
    vcs_backend 2>/dev/null || return 0
    if [ "$VCS_BACKEND" = jj ]; then
        need jj "brew install jj"
    fi
    vcs remotes
}

# init_trunk: the trunk branch name for a project, master when nothing says otherwise.
init_trunk() {
    local names=""
    if vcs_backend 2>/dev/null; then
        names=$(vcs branches 2>/dev/null || true)
    fi
    trunk_name "$names" 2>/dev/null ||
        git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null ||
        echo master
}

# put_template <project path> <template path> <channel>
put_template() {
    if [ -e "$ROOT/$1" ]; then
        skipped "$1 exists"
        return
    fi
    if [ "$DRY" -eq 0 ]; then
        install_rendered "$1" "$2" "$3"
    fi
    created "$1"
}

# put_generated <project path> <generator function> [generator args...]
put_generated() {
    local dest=$1
    shift
    if [ -e "$ROOT/$dest" ]; then
        skipped "$dest exists"
        return
    fi
    if [ "$DRY" -eq 0 ]; then
        mkdir -p "$(dirname "$ROOT/$dest")"
        "$@" >"$ROOT/$dest"
    fi
    created "$dest"
}

STYLE_MARKER='## This project'

# style_guide_for <type>: the dotfiles guide a project of this type copies into docs/STYLE.md.
style_guide_for() {
    case "$1" in
    rust) printf '%s\n' "$(dotfiles_root)/docs/style/rust.md" ;;
    love2d | lua) printf '%s\n' "$(dotfiles_root)/docs/style/lua.md" ;;
    *) return 1 ;;
    esac
}

# render_style <guide>: the guide followed by the project's own section of docs/STYLE.md.
render_style() {
    cat "$1"
    printf '\n'
    sed -n "/^${STYLE_MARKER}\$/,\$p" "$ROOT/docs/STYLE.md"
}

# put_style_guide <language>: seed docs/STYLE.md from the dotfiles repo's guide.
put_style_guide() {
    local guide
    guide="$(dotfiles_root)/docs/style/$1.md"
    if [ -e "$ROOT/docs/STYLE.md" ]; then
        skipped "docs/STYLE.md exists"
        return
    fi
    if [ ! -f "$guide" ]; then
        skipped "docs/STYLE.md: no $1 guide at $guide"
        return
    fi
    if [ "$DRY" -eq 0 ]; then
        mkdir -p "$ROOT/docs"
        {
            cat "$guide"
            printf '\n%s\n\nRules that apply only to this project go here. Number them P1, P2, and so on. The numbers above only grow, so a project rule never shares a number with a guide rule.\n' "$STYLE_MARKER"
        } >"$ROOT/docs/STYLE.md"
    fi
    created "docs/STYLE.md"
}

# emit_pipeline <type>
emit_pipeline() {
    local body
    if [ "$1" = rust ]; then
        read -r -d '' body <<'LUA' || true
-- Lint and test on a linux container with .dev/lint.sh and .dev/test.sh
--
--   ci run --local
--   ci run --local --job test

-- Run the lint and test jobs on an image that bakes the toolchain
local LINUX = { os = "linux-base", image = "linux-rust" }

local function toolchain()
  local file = assert(io.open("rust-toolchain.toml"), "rust-toolchain.toml is missing")
  local text = file:read("*a")
  file:close()
  return assert(text:match('channel%s*=%s*"([^"]+)"'), "rust-toolchain.toml names no channel")
end

-- Prefix cargo's directory on every command, since each ci.sh gets a fresh shell
local function run(command)
  return ci.sh("export PATH=$HOME/.cargo/bin:$PATH; " .. command)
end

-- Install the project's pinned channel, which the runner image usually bakes in
local function install_rust()
  local channel = toolchain()
  ci.group("install rust " .. channel, function()
    run("rustup toolchain install " .. channel .. " --component clippy,rustfmt")
    run("rustup toolchain install nightly --profile minimal --component rustfmt")
    run("command -v cargo-nextest >/dev/null || { mkdir -p $HOME/.cargo/bin && curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C $HOME/.cargo/bin; }")
  end)
end

return {
  jobs = {
    lint = {
      matrix = { LINUX },
      run = function()
        install_rust()
        run(".dev/lint.sh")
      end,
    },
    test = {
      matrix = { LINUX },
      run = function()
        install_rust()
        run(".dev/test.sh")
      end,
    },
  },
}
LUA
    else
        read -r -d '' body <<'LUA' || true
-- Lint and test on a linux container with .dev/lint.sh and .dev/test.sh when present
--
--   ci run --local
--   ci run --local --job test

local LINUX = { os = "linux-base" }

return {
  jobs = {
    lint = {
      matrix = { LINUX },
      run = function()
        ci.sh("if [ -x .dev/lint.sh ]; then .dev/lint.sh; fi")
      end,
    },
    test = {
      matrix = { LINUX },
      run = function()
        ci.sh("if [ -x .dev/test.sh ]; then .dev/test.sh; fi")
      end,
    },
  },
}
LUA
    fi
    printf '%s\n' "$body"
}

# emit_workflow <trunk>
emit_workflow() {
    local body
    read -r -d '' body <<'YAML' || true
name: ci

on:
  pull_request:
  push:
    branches: [@TRUNK@]
    tags: ["*"]

jobs:
  check:
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v4
      - name: Install nightly rustfmt
        run: rustup toolchain install nightly --profile minimal --component rustfmt
      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-nextest
      - name: Lint
        run: .dev/lint.sh
        shell: bash
      - name: Test
        run: .dev/test.sh
        shell: bash
YAML
    printf '%s\n' "${body/@TRUNK@/$1}"
}

# init_lint_files <template dir> <channel>: every file of the manifest that is not there yet.
init_lint_files() {
    local t=$1 channel=$2 dest src
    while IFS=$'\t' read -r dest src; do
        put_template "$dest" "$src" "$channel"
    done < <(manifest "$t")
}

# init_workspace_lints <template dir>: the [workspace.lints] block of a rust project.
init_workspace_lints() {
    local t=$1 block
    if [ ! -f "$ROOT/Cargo.toml" ]; then
        skipped "workspace lints: no Cargo.toml"
        return
    fi
    if grep -q '^\[workspace\.lints' "$ROOT/Cargo.toml"; then
        skipped "workspace lints in Cargo.toml exist"
        return
    fi
    if [ "$DRY" -eq 0 ]; then
        block=$(<"$t/workspace-lints.toml")

        # Drop the template's leading comment header, which ends at the first blank line.
        block=${block#*$'\n\n'}
        printf '\n%s\n' "$block" >>"$ROOT/Cargo.toml"

        # cargo-sort wants [workspace.*] tables ahead of [dependencies].
        if command -v cargo-sort >/dev/null 2>&1; then
            show cargo sort --workspace
            (cd "$ROOT" && cargo sort --workspace >/dev/null 2>&1) || true
        fi
    fi
    created "[workspace.lints] block in Cargo.toml"
    human 'add "[lints]" with "workspace = true" to each member crate Cargo.toml'
    printf 'reminder: each member crate needs [lints] with workspace = true\n'
    printf 'note: the lints deny warnings, so fix every finding in the same change that adds this block\n'
}

# init_lib_attrs <template dir>: the library-register attribute in each library crate.
init_lib_attrs() {
    local t=$1 d
    while IFS= read -r d; do
        if lib_attr_present "$t" "$d"; then
            skipped "$d/src/lib.rs has the library-register attribute"
            continue
        fi
        if [ "$DRY" -eq 0 ]; then
            lib_attr_insert "$t" "$d"
        fi
        created "$d/src/lib.rs library-register attribute"
    done < <(lib_crates)
    while IFS= read -r d; do
        printf 'application register, no doc lints: %s\n' "$d"
    done < <(app_crates)
}

init_gerrit() {
    local name=$1 projects
    if [ "$DRY" -eq 1 ]; then
        created "gerrit project $name (create-project when absent) and remote gerrit gr:$name"
        return
    fi
    show ssh -p 29418 user@gerrit.example.com gerrit ls-projects
    if ! projects=$(ssh -p 29418 user@gerrit.example.com gerrit ls-projects 2>&1); then
        printf 'warning: gerrit ls-projects failed: %s\n' "$projects" >&2
        human "create the Gerrit project and remote: ssh -p 29418 user@gerrit.example.com gerrit create-project $name, then $(vcs remote-add-hint) gerrit gr:$name"
        return
    fi
    if has_line "$projects" "$name"; then
        skipped "gerrit project $name exists"
    elif run_cmd ssh -p 29418 user@gerrit.example.com gerrit create-project "$name"; then
        created "gerrit project $name"
    else
        human "create the Gerrit project: ssh -p 29418 user@gerrit.example.com gerrit create-project $name"
        return
    fi
    vcs remote-add gerrit "gr:$name"
    created "remote gerrit gr:$name"
}

# init_board_hint <name>: when the Pomb board answers a read-only GET and has no board named after the project,
# leaves a line for the owner. Anything missing (pass entry, tailscale, tools) skips it silently.
init_board_hint() {
    local url=${POMB_URL:-https://pomb.example.com} token boards has
    command -v pass >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
    token=$(pass show secrets/worker/token/pomb.example.com 2>/dev/null) && [ -n "$token" ] || return 0
    boards=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS --max-time 5 -K - "$url/api/boards" 2>/dev/null) || return 0
    has=$(jq -r --arg n "$1" 'if any(.[]; .name == $n) then "yes" else "no" end' <<<"$boards" 2>/dev/null)
    if [ "$has" = no ]; then
        human "No Pomb board for $1, create one in $url or tell agents to use General"
    fi
}

cmd_init() {
    local type="" name="" public=0 gerrit=1 remotes t channel trunk
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --type)
            [ "$#" -ge 2 ] || usage_error init "--type needs a value"
            type=$2
            shift 2
            ;;
        --name)
            [ "$#" -ge 2 ] || usage_error init "--name needs a value"
            name=$2
            shift 2
            ;;
        --public)
            public=1
            shift
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        --no-gerrit)
            gerrit=0
            shift
            ;;
        *) bad_arg init "$1" ;;
        esac
    done
    case "$type" in
    "") type=$(detect_type) ;;
    rust | love2d | lua | godot | node) ;;
    *) usage_error init "--type takes rust, love2d, lua, godot or node" ;;
    esac
    if [ "$type" = rust ] && [ -f "$ROOT/Cargo.toml" ]; then
        need yq "brew install yq"
    fi
    PROJECT_TYPE=$type
    : "${name:=$(basename "$ROOT")}"
    printf 'init %s: type %s, public %s, dry run %s\n' "$name" "$type" "$public" "$DRY"

    # VCS
    if [ -d "$ROOT/.jj" ]; then
        VCS_BACKEND=jj
        skipped ".jj exists"
    elif [ -f "$ROOT/.git" ]; then
        VCS_BACKEND=git
        skipped ".jj: this is a git worktree, colocate jj in the main checkout"
    else
        if [ -e "$ROOT/.git" ]; then
            skipped ".git exists"
        else
            if [ "$DRY" -eq 0 ]; then
                run_cmd git -C "$ROOT" init -q
            fi
            created ".git (git init)"
        fi
        if command -v jj >/dev/null 2>&1; then
            VCS_BACKEND=jj
            if [ "$DRY" -eq 0 ]; then
                show jj git init --colocate
                (cd "$ROOT" && jj git init --colocate >/dev/null 2>&1)
            fi
            created ".jj (jj git init --colocate)"
        else
            VCS_BACKEND=git
            skipped ".jj (jj not installed, git only)"
        fi
    fi

    # Lint set
    case "$type" in
    rust)
        t=$(templates_dir rust)
        channel=$(channel_for_project)
        init_lint_files "$t" "$channel"
        init_workspace_lints "$t"
        init_lib_attrs "$t"
        ;;
    love2d | lua)
        t=$(templates_dir "$type")
        init_lint_files "$t" ""
        ;;
    *)
        skipped "lint set: none yet for $type projects"
        ;;
    esac

    # Style guide
    case "$type" in
    rust) put_style_guide rust ;;
    love2d | lua) put_style_guide lua ;;
    *) skipped "docs/STYLE.md: no style guide for $type projects" ;;
    esac

    # CI pipeline
    channel=$(channel_for_project)
    put_generated .ci/jobs.lua emit_pipeline "$type"

    # GitHub workflow
    if [ "$public" -eq 1 ]; then
        if [ "$type" = rust ]; then
            trunk=$(init_trunk)
            put_generated .github/workflows/ci.yml emit_workflow "$trunk"
        else
            skipped ".github/workflows/ci.yml: no workflow for $type projects"
        fi
    else
        skipped ".github/workflows/ci.yml: project is not public"
    fi

    # Remotes
    remotes=$(remote_names)
    if has_line "$remotes" origin; then
        skipped "remote origin exists"
    else
        printf 'remote origin is missing, create the GitHub repo and run: %s origin hub:%s\n' "$(vcs remote-add-hint)" "$name"
        human "create the GitHub repo, then run: $(vcs remote-add-hint) origin hub:$name"
    fi
    if [ "$gerrit" -eq 0 ]; then
        skipped "gerrit: --no-gerrit"
    elif has_line "$remotes" gerrit; then
        skipped "remote gerrit exists"
    else
        init_gerrit ""
    fi

    init_board_hint "$name"

    # Summary
    printf '\nSummary%s\n' "$([ "$DRY" -eq 1 ] && echo ' (dry run, nothing written)')"
    printf 'Created:\n'
    printf '%s' "$CREATED" | sed 's/^/  /'
    printf 'Skipped:\n'
    printf '%s' "$SKIPPED" | sed 's/^/  /'
    if [ -n "$HUMAN" ]; then
        printf 'Left for you:\n'
        printf '%s' "$HUMAN" | sed 's/^/  /'
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
