# shellcheck shell=bash
# Shared state and functions for the .dev/<verb>.sh scripts. Sourced, never run.
#
# Environment: TARGET_DIR (default $HOME) is where symlinks land and SRC_DIR
# (default <repo>/dotfiles) holds the stow packages. Tests point both at a
# temp tree.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

SRC_DIR="${SRC_DIR:-$ROOT/dotfiles}"
TARGET_DIR="${TARGET_DIR:-$HOME}"

STOW_WEB_BIN=https://ftp.gnu.org/gnu/stow/stow-2.4.1.tar.gz
STOW_ARCHIVE=stow.tar.gz
STOW_DIR=stow-2.4.1

if [ "${OS:-}" = Windows_NT ]; then
    HOST_OS=Windows
else
    HOST_OS="$(uname)"
fi

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

# `mail` needs no overloaded installer: the maildir and the client's notmuch
# config are both created by `muchsync --init` at first sync, not by stow. There
# is deliberately nothing to pre-create -- ~/mail must be EMPTY before the first
# init, because muchsync's BUGS section is explicit that a replica built by
# another tool produces artifacts including deleted files reappearing.
DEFAULT_DEPS=(bin cargo ci claude git jj mail aide neomutt pi ripgrep scribe ssh zsh nvim tmux readline gpg ghostty lazygit)
if [ "$HOST_OS" = Darwin ]; then
    DEFAULT_DEPS+=(antinote hammerspoon)
fi
_sorted=()
while IFS= read -r _dep; do
    _sorted+=("$_dep")
done < <(printf '%s\n' "${DEFAULT_DEPS[@]}" | LC_ALL=C sort -u)
DEFAULT_DEPS=("${_sorted[@]}")
unset _sorted _dep

# ARGS and PKGS are read by the scripts that source this file.
# shellcheck disable=SC2034
# split_vars <args...>: export each NAME=value argument (the form `dev sync
# SYNC_DST=host` takes) and leave the rest in ARGS.
split_vars() {
    ARGS=()
    local a
    for a in "$@"; do
        case "$a" in
        [A-Z]*=*) export "${a?}" ;;
        *) ARGS+=("$a") ;;
        esac
    done
}

# set_pkgs <pkg...>: PKGS becomes the arguments, or DEFAULT_DEPS when none.
# shellcheck disable=SC2034  # PKGS is read by the scripts that source this file
set_pkgs() {
    if [ "$#" -gt 0 ]; then
        PKGS=("$@")
    else
        PKGS=("${DEFAULT_DEPS[@]}")
    fi
}

# Ensures stow is available on path, otherwise attempts to download
ensure_stow() {
    if command -v stow >/dev/null 2>&1; then
        return 0
    fi
    local download
    printf 'Attempting to download %s\n' "$STOW_WEB_BIN"
    if command -v wget >/dev/null 2>&1; then
        download=(wget --output-document "$STOW_ARCHIVE" "$STOW_WEB_BIN")
    elif command -v curl >/dev/null 2>&1; then
        download=(curl --output "$STOW_ARCHIVE" "$STOW_WEB_BIN")
    elif command -v fetch >/dev/null 2>&1; then
        download=(fetch -o "$STOW_ARCHIVE" "$STOW_WEB_BIN")
    else
        die "Download $STOW_WEB_BIN and place it on your path!"
    fi
    "${download[@]}"
    tar -zxf "$STOW_ARCHIVE"
    (cd "$STOW_DIR" && ./configure && make && make install)
    rm -rf "${STOW_DIR:?}"
    rm -f "${STOW_ARCHIVE:?}"
}

# stow_run <stow args...>: stow against SRC_DIR into TARGET_DIR.
stow_run() {
    stow -t "$TARGET_DIR" -d "$SRC_DIR" "$@"
}

install_pkg() {
    local pkg=$1
    ensure_stow
    case "$pkg" in
    work) install_work ;;
    lazygit) install_lazygit ;;
    gpg) install_gpg ;;
    ssh) install_ssh ;;
    antinote) install_antinote ;;
    pi) install_pi ;;
    jj) install_jj ;;
    *)
        printf '> Installing %s... ' "$pkg"
        stow_run -S "$pkg"
        printf 'DONE\n'
        ;;
    esac
}

install_jj() {
    local dir="$SRC_DIR/jj/.config/jj/conf.d"
    mkdir -p "$dir"
    printf 'git.executable-path = "%s"\n' "$SRC_DIR/bin/.local/bin/commit-guard" >"$dir/git-guard.toml"
    printf '> Installing jj... '
    stow_run -S jj
    printf 'DONE\n'
}

restow_pkg() {
    ensure_stow
    printf '> Restowing %s... ' "$1"
    stow_run -R "$1"
    printf 'DONE\n'
}

uninstall_pkg() {
    ensure_stow
    printf '> Uninstalling %s... ' "$1"
    stow_run -D "$1"
    printf 'DONE\n'
}

# purge_path <physical-src> <relative-path>: remove one target path. A symlinked
# parent is a folded stow directory: unlink that link alone when it points into
# the source tree, and never touch anything beneath it.
purge_path() {
    local src=$1 rest=$2 cur=${TARGET_DIR:?} part real
    while [[ $rest == */* ]]; do
        part=${rest%%/*}
        rest=${rest#*/}
        cur=$cur/$part
        if [ -L "$cur" ]; then
            real=$(cd -P "$cur" 2>/dev/null && pwd) || return 0
            case "$real/" in
            "$src"/*) rm -f "$cur" ;;
            esac
            return 0
        fi
        [ -d "$cur" ] || return 0
    done
    cur=$cur/$rest
    if [ -L "$cur" ] || [ -f "$cur" ]; then
        rm -f "$cur"
    fi
}

# Removes the regular files and per-file symlinks the package would link, and
# the folded directory links that stow made for it.
purge_pkg() {
    local pkg=$1 file src
    printf '> Purging %s... ' "$pkg"
    if [ -d "$SRC_DIR/$pkg" ]; then
        src=$(cd -P "$SRC_DIR" && pwd)
        while IFS= read -r file; do
            purge_path "$src" "${file#./}"
        done < <(cd "$SRC_DIR/$pkg" && find . -type f)
    fi
    printf 'DONE\n'
}

# Overloaded installer to ensure no conflicts: work replaces git, so git is
# uninstalled first.
install_work() {
    uninstall_pkg git
    printf '> Installing work... '
    stow_run -S work
    printf 'DONE\n'
}

# lazygit reads ~/Library/Application Support on macOS, so symlink the stowed
# .config there.
install_lazygit() {
    printf '> Installing lazygit... '
    stow_run -S lazygit
    printf 'DONE\n'
    if [ "$HOST_OS" = Darwin ]; then
        printf '> Symlinking lazygit Unix config -> MacOS config\n'
        mkdir -p "$TARGET_DIR/Library/Application Support/lazygit"
        ln -sf "$TARGET_DIR/.config/lazygit/config.yml" "$TARGET_DIR/Library/Application Support/lazygit/config.yml"
    fi
}

# Keep ~/.gnupg a real 0700 dir so only the configs are symlinked (keyring and
# runtime files stay out of the repo).
install_gpg() {
    printf '> Installing gpg... '
    mkdir -p "$TARGET_DIR/.gnupg"
    chmod 700 "$TARGET_DIR/.gnupg"
    stow_run --no-folding -S gpg
    printf 'DONE\n'
}

# Same shape as install_gpg and for the same reason: ~/.ssh must stay a real
# 0700 directory or ssh refuses to use the keys in it. --no-folding keeps stow
# from symlinking the whole directory into the repo, so only config.d/*.conf is
# ours and keys, known_hosts and the hand-maintained config stay untracked.
install_ssh() {
    printf '> Installing ssh... '
    mkdir -p "$TARGET_DIR/.ssh/config.d"
    chmod 700 "$TARGET_DIR/.ssh"
    stow_run --no-folding -S ssh
    printf 'DONE\n'
    grep -qs 'config.d/\*.conf' "$TARGET_DIR/.ssh/config" ||
        printf '>> Add near the TOP of ~/.ssh/config: Include ~/.ssh/config.d/*.conf\n'
}

# Antinote keeps every setting in one sandboxed plist that cfprefsd rewrites in
# place, so a symlink there is replaced by a real file the first time the app
# writes a setting. Stow places the tracked copy under ~/.config/antinote and
# antinote.sh imports it into the app's domain with `defaults import`, which
# merges key by key and so leaves the app's runtime state alone.
install_antinote() {
    printf '> Installing antinote... '
    stow_run -S antinote
    printf 'DONE\n'
    bash scripts/antinote.sh import --skip-if-running
}

# settings.json is ignored by stow and copied by pi-settings.sh instead. pi
# writes runtime state into that file -- `theme` on every system appearance
# change, `lastChangelogVersion` after showing a changelog -- so a symlink makes
# the repo dirty every time the Mac switches to light mode. ~/.pi/agent stays a
# real dir so pi's sessions, auth and caches stay out of the repo.
install_pi() {
    printf '> Installing pi... '
    mkdir -p "$TARGET_DIR/.pi/agent"
    stow_run --no-folding --ignore='settings\.json' -S pi
    printf 'DONE\n'
    bash scripts/pi-settings.sh install
}
