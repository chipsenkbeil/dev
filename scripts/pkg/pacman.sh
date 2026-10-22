#!/usr/bin/env bash
# scripts/pkg/pacman.sh — Arch Linux pacman driver. Mirrors brew.sh. Handles the
# empty channel (bare official package) and `aur:` (build from the AUR with
# makepkg), the way brew.sh owns cask:/tap: and dnf.sh owns copr:. Source this
# file, do not execute it.
#
# AUR TRUST MODEL
#   A PKGBUILD is arbitrary code written by an AUR user, fetched and executed at
#   install time. Listing an `aur:` cell is the (hand-editing) author's explicit
#   authorization to run that code -- the same trust model as a `script:` cell
#   or a brew `tap:`. Dry-run prints the clone URL so the source is visible
#   before anything executes.

# Run pacman as root directly (containers) or via sudo (normal user). Computed
# once at source time so both pkg_status and pkg_install agree.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# Unprivileged account used to build AUR packages when this driver runs as root
# (containers/CI). makepkg refuses to run as root and offers no override, so a
# build user is the only option there.
AUR_BUILD_USER="${AUR_BUILD_USER:-aurbuild}"
AUR_SUDOERS="/etc/sudoers.d/99-${AUR_BUILD_USER}"

# pkg_status <name> <binary> <package>
#   Print one status line:
#     [x] name   (/path)                  -> binary is on PATH
#     [~] name   (installed, not on PATH) -> pacman knows it but PATH does not
#     [ ] name                            -> not found by PATH or pacman
#   <binary> may be "-" for GUI-only apps (the PATH probe is skipped).
#   AUR packages register in pacman's local DB, so `pacman -Q` finds them too
#   and this needs no aur-specific branch.
pkg_status() {
    local name="$1" binary="$2" package="$3" path=""
    if [ "$binary" != "-" ]; then
        path="$(command -v "$binary" 2>/dev/null || true)"
        if [ -n "$path" ]; then
            printf '[x] %s\t(%s)\n' "$name" "$path"
            return 0
        fi
    fi
    if pacman -Q -- "$package" >/dev/null 2>&1; then
        # binary "-" = a package with no CLI (shell plugin etc.): "not on PATH"
        # would be misleading, so just report it installed.
        if [ "$binary" = "-" ]; then
            printf '[x] %s\t(installed)\n' "$name"
        else
            printf '[~] %s\t(installed, not on PATH)\n' "$name"
        fi
        return 0
    fi
    printf '[ ] %s\n' "$name"
    return 1
}

# _aur_teardown
#   Remove the temporary sudoers drop-in. Registered on EXIT by _aur_install so
#   a failed build cannot leave passwordless pacman behind for the build user.
_aur_teardown() {
    # Clears the trap too, so calling this directly on an early-return path is
    # enough and every exit route converges here exactly once.
    trap - EXIT
    [ -f "$AUR_SUDOERS" ] && rm -f "$AUR_SUDOERS"
    return 0
}

# _aur_prepare_root
#   Create the build user and grant it passwordless pacman. Only called when
#   this driver is already root. makepkg -si shells out to `sudo pacman` for
#   both dependency syncing and the final -U, hence the drop-in.
_aur_prepare_root() {
    if ! id -u "$AUR_BUILD_USER" >/dev/null 2>&1; then
        if ! pkg_run "useradd -m -s /bin/bash $AUR_BUILD_USER"; then
            printf '  ! could not create AUR build user %s\n' "$AUR_BUILD_USER" >&2
            return 1
        fi
    fi
    mkdir -p "$(dirname "$AUR_SUDOERS")"
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$AUR_BUILD_USER" >"$AUR_SUDOERS"
    chmod 0440 "$AUR_SUDOERS"
    return 0
}

# _aur_install <name> <package>
#   Clone <package> from the AUR and build+install it with makepkg. Deliberately
#   NOT routed through an AUR helper (paru/yay): every helper is itself an AUR
#   package, so this manual path would be needed to bootstrap one anyway, and
#   supporting both would be two mechanisms for one job.
_aur_install() {
    local name="$1" package="$2"
    local url="https://aur.archlinux.org/${package}.git"

    # base-devel supplies makepkg, fakeroot and sudo; git clones the AUR repo.
    if ! pkg_run "$SUDO pacman -S --needed --noconfirm base-devel git"; then
        printf '  ! %s: could not install AUR build prerequisites\n' "$name" >&2
        return 1
    fi

    local tmp
    tmp="$(mktemp -d)" || return 1

    if [ "$(id -u)" -eq 0 ]; then
        trap '_aur_teardown' EXIT
        _aur_prepare_root || {
            rm -rf "$tmp"
            return 1
        }
        chown -R "$AUR_BUILD_USER" "$tmp"
        if ! pkg_run "sudo -u $AUR_BUILD_USER git clone --depth 1 $url $tmp/$package"; then
            printf '  ! %s: could not clone %s\n' "$name" "$url" >&2
            rm -rf "$tmp"
            _aur_teardown
            return 1
        fi

        # cd in a subshell, NOT inside the pkg_run string: pkg_run word-splits
        # and runs a SIMPLE command, so a `&&` there lands as an argv entry
        # ("cd: too many arguments") instead of a shell operator.
        if ! (
            cd "$tmp/$package" || exit 1
            pkg_run "sudo -u $AUR_BUILD_USER makepkg -si --noconfirm"
        ); then
            printf '  ! %s: makepkg failed\n' "$name" >&2
            rm -rf "$tmp"
            _aur_teardown
            return 1
        fi
        _aur_teardown
    else
        if ! pkg_run "git clone --depth 1 $url $tmp/$package"; then
            printf '  ! %s: could not clone %s\n' "$name" "$url" >&2
            rm -rf "$tmp"
            return 1
        fi

        # makepkg calls sudo itself for dependency syncing and the final -U.
        # cd in a subshell -- see the note on the root branch above.
        if ! (
            cd "$tmp/$package" || exit 1
            pkg_run "makepkg -si --noconfirm"
        ); then
            printf '  ! %s: makepkg failed\n' "$name" >&2
            rm -rf "$tmp"
            return 1
        fi
    fi

    rm -rf "$tmp"
    return 0
}

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Install <package> unless already present (PKG_FORCE=1 reinstalls, without
#   --needed). Supported channels:
#     ""     bare official package: pacman -S --needed --noconfirm <package>
#     aur    clone https://aur.archlinux.org/<package>.git and makepkg -si
#   Any other channel is an error (cargo:/script: cells never reach this driver
#   -- pkg.sh routes them to their own handlers). <dry_run>=1 prints only.
pkg_install() {
    # shellcheck disable=SC2034  # repo unused by pacman (no repo-bearing channels); kept for driver-signature parity
    local name="$1" binary="$2" package="$3" channel="$4" repo="$5" dry_run="$6"

    # Already present? PATH (source-agnostic) -> pacman registry.
    local needed=" --needed"
    if [ "${PKG_FORCE:-0}" = 1 ]; then
        needed=""
    elif [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    elif pacman -Q "$package" >/dev/null 2>&1; then
        printf '  = %s already installed via pacman, skipping\n' "$name"
        return 0
    fi

    case "$channel" in
    "")
        local cmd="$SUDO pacman -S$needed --noconfirm -- $package"
        if [ "$dry_run" = "1" ]; then
            printf '  + %s (dry-run):\n      %s\n' "$name" "$cmd"
            return 0
        fi
        printf '  + installing %s...\n' "$name"
        if ! pkg_run "$cmd"; then
            printf '  ! %s: "%s" failed\n' "$name" "$cmd" >&2
            return 1
        fi
        ;;
    aur)
        if [ "$dry_run" = "1" ]; then
            printf '  + %s (dry-run):\n' "$name"
            printf '      %s pacman -S --needed --noconfirm base-devel git\n' "$SUDO"
            printf '      git clone --depth 1 https://aur.archlinux.org/%s.git <tmp>\n' "$package"
            printf '      makepkg -si --noconfirm   (in <tmp>%s)\n' \
                "$([ "$(id -u)" -eq 0 ] && printf ', as %s' "$AUR_BUILD_USER")"
            return 0
        fi
        printf '  + installing %s from the AUR...\n' "$name"
        _aur_install "$name" "$package" || return 1
        ;;
    *)
        printf '  ! %s: unknown pacman channel "%s", skipping\n' "$name" "$channel" >&2
        return 1
        ;;
    esac
    return 0
}
