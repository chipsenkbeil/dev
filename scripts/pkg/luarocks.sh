#!/usr/bin/env bash
# scripts/pkg/luarocks.sh — cross-OS luarocks handler. Defines pkg_install for
# `luarocks:` cells. Source, do not execute.

# Run luarocks as root directly (containers) or via sudo (normal user). Computed
# once at source time so the install path is consistent.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Install <package> as a rock via `luarocks install` unless already present
#   (PKG_FORCE=1 reinstalls).
#   <channel>/<repo> are unused (kept for a uniform driver signature).
pkg_install() {
    local name="$1" binary="$2" package="$3" dry_run="$6" force=""
    if [ "${PKG_FORCE:-0}" = 1 ]; then
        force=" --force"
    elif [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    elif installed=$(luarocks list "$package" 2>/dev/null) && grep -q "^$package$" <<<"$installed"; then
        printf '  = %s already installed via luarocks, skipping\n' "$name"
        return 0
    fi
    local cmd="$SUDO luarocks install$force $package"
    if [ "$dry_run" = "1" ]; then
        printf '  + %s (dry-run):\n      %s\n' "$name" "$cmd"
        return 0
    fi
    printf '  + installing %s (luarocks)...\n' "$name"
    pkg_run "$cmd"
}
