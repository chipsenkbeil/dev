#!/usr/bin/env bash
# scripts/pkg/dnf.sh — Fedora dnf driver. Mirrors brew.sh/pacman.sh. The
# manifest's dnf column carries bare official packages and copr: cells (cargo:
# cells are routed to pkg/cargo.sh by pkg.sh, never reach this driver). Source
# this file, do not execute it.

# Run dnf as root directly (containers) or via sudo (normal user). Computed once
# at source time so both pkg_status and pkg_install agree.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# _dnf_ensure_copr_plugin
#   The `dnf copr` subcommand ships in dnf-plugins-core. The Fedora orchestrator
#   installs it during bootstrap, but defensively ensure it is present before
#   enabling a COPR so a driver-only invocation still works.
_dnf_ensure_copr_plugin() {
    if dnf copr --help >/dev/null 2>&1; then
        return 0
    fi

    # shellcheck disable=SC2086  # $SUDO is intentionally word-split (empty or "sudo")
    $SUDO dnf install -y dnf-plugins-core
}

# pkg_status <name> <binary> <package>
#   Print one status line:
#     [x] name   (/path)                  -> binary is on PATH
#     [~] name   (installed, not on PATH) -> rpm knows it but PATH does not
#     [ ] name                            -> not found by PATH or rpm
#   <binary> may be "-" for GUI-only apps (the PATH probe is skipped).
pkg_status() {
    local name="$1" binary="$2" package="$3" path=""
    if [ "$binary" != "-" ]; then
        path="$(command -v "$binary" 2>/dev/null || true)"
        if [ -n "$path" ]; then
            printf '[x] %s\t(%s)\n' "$name" "$path"
            return 0
        fi
    fi
    if rpm -q "$package" >/dev/null 2>&1; then
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
}

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Install <package> via dnf unless already present. Supported channels:
#     ""     bare official package: dnf install -y <package>
#     copr   enable <repo> COPR then install: dnf copr enable -y <repo>
#            followed by dnf install -y <package>
#   Any other channel is an error (cargo: cells never reach this driver — pkg.sh
#   routes them to pkg/cargo.sh). <dry_run>=1 prints the command(s) only.
pkg_install() {
    local name="$1" binary="$2" package="$3" channel="$4" repo="$5" dry_run="$6"

    # Already present? PATH (source-agnostic) -> rpm registry.
    if [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    fi
    if rpm -q "$package" >/dev/null 2>&1; then
        printf '  = %s already installed via dnf, skipping\n' "$name"
        return 0
    fi

    # Build the install command(s).
    local -a cmds=()
    case "$channel" in
    "") cmds=("$SUDO dnf install -y $package") ;;
    copr) cmds=("$SUDO dnf copr enable -y $repo" "$SUDO dnf install -y $package") ;;
    *)
        printf '  ! %s: unknown dnf channel "%s", skipping\n' "$name" "$channel" >&2
        return 1
        ;;
    esac

    if [ "$dry_run" = "1" ]; then
        printf '  + %s (dry-run):\n' "$name"
        local c
        for c in "${cmds[@]}"; do printf '      %s\n' "$c"; done
        return 0
    fi

    # Ensure the copr plugin is present before attempting to enable a COPR.
    [ "$channel" = "copr" ] && { _dnf_ensure_copr_plugin || return 1; }

    printf '  + installing %s...\n' "$name"
    local c
    for c in "${cmds[@]}"; do
        if ! pkg_run "$c"; then
            printf '  ! %s: "%s" failed\n' "$name" "$c" >&2
            return 1
        fi
    done
    return 0
}
