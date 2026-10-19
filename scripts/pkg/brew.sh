#!/usr/bin/env bash
# scripts/pkg/brew.sh — Homebrew driver. Defines pkg_status now; pkg_install
# lands in Slice 2. Source this file, do not execute it.

# pkg_status <name> <binary> <package> <channel>
#   [x] name (/path)      -> binary on PATH
#   [x] name (/App.app)   -> a cask installed as an app bundle, even if not
#                            tracked by brew (e.g. installed manually)
#   [x] name (installed)  -> a binary-less formula/plugin brew has (binary "-")
#   [~] name (installed,  -> a CLI tool brew installed but not on PATH (a real
#            not on PATH)     warning worth surfacing)
#   [ ] name              -> not found
#   <binary> "-" = no CLI expected (GUI app / shell plugin): PATH probe skipped,
#   so "not on PATH" is never reported for it.
pkg_status() {
    local name="$1" binary="$2" package="$3" channel="$4" path=""
    if [ "$binary" != "-" ]; then
        path="$(command -v "$binary" 2>/dev/null || true)"
        if [ -n "$path" ]; then
            printf '[x] %s\t(%s)\n' "$name" "$path"
            return 0
        fi
    fi
    if brew list "$package" >/dev/null 2>&1; then
        if [ "$binary" = "-" ]; then
            printf '[x] %s\t(installed)\n' "$name"
        else
            printf '[~] %s\t(installed, not on PATH)\n' "$name"
        fi
        return 0
    fi

    # Not tracked by brew — a cask may still be present as an app bundle.
    if [ "$channel" = "cask" ]; then
        local app d
        app="$(_brew_cask_app "$package")"
        if [ -n "$app" ]; then
            for d in "/Applications" "$HOME/Applications"; do
                if [ -d "$d/$app" ]; then
                    printf '[x] %s\t(%s)\n' "$name" "$d/$app"
                    return 0
                fi
            done
        fi
    fi
    printf '[ ] %s\n' "$name"
    return 1
}

# _brew_cask_app <cask> -> prints the .app bundle name a cask installs (or nothing).
_brew_cask_app() {
    brew info --json=v2 --cask "$1" 2>/dev/null |
        jq -r '.casks[0].artifacts[]? | select(.app) | .app[0]' 2>/dev/null
}

# _brew_clear_quarantine <cask> -> clear the Gatekeeper quarantine xattr on the
# installed app if it is quarantined AND fails assessment (unsigned casks).
_brew_clear_quarantine() {
    local app path
    app="$(_brew_cask_app "$1")"
    [ -z "$app" ] && return 0
    path="/Applications/$app"
    [ -d "$path" ] || return 0
    if xattr -p com.apple.quarantine "$path" >/dev/null 2>&1 &&
        ! spctl --assess --type execute "$path" >/dev/null 2>&1; then
        printf '  ~ clearing quarantine on %s\n' "$app"
        xattr -cr "$path"
    fi
}

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Install <package> via Homebrew unless already present. <channel>: "" (formula),
#   "cask", or "tap" (<repo>=owner/tap). <dry_run>=1 prints the commands only.
pkg_install() {
    local name="$1" binary="$2" package="$3" channel="$4" repo="$5" dry_run="$6"

    # Already present? PATH (source-agnostic) -> brew registry -> cask app bundle.
    if [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    fi
    if brew list "$package" >/dev/null 2>&1; then
        printf '  = %s already installed via brew, skipping\n' "$name"
        return 0
    fi
    if [ "$channel" = "cask" ]; then
        local app
        app="$(_brew_cask_app "$package")"
        if [ -n "$app" ] && { [ -d "/Applications/$app" ] || [ -d "$HOME/Applications/$app" ]; }; then
            printf '  = %s already installed as app, skipping\n' "$name"
            return 0
        fi
    fi

    # Build the install command(s).
    local -a cmds=()
    case "$channel" in
    cask) cmds=("brew install --cask $package") ;;
    tap) cmds=("brew tap $repo" "brew install $package") ;;
    "") cmds=("brew install $package") ;;
    *)
        printf '  ! %s: unknown brew channel "%s", skipping\n' "$name" "$channel" >&2
        return 1
        ;;
    esac

    if [ "$dry_run" = "1" ]; then
        printf '  + %s (dry-run):\n' "$name"
        local c
        for c in "${cmds[@]}"; do printf '      %s\n' "$c"; done
        return 0
    fi

    printf '  + installing %s...\n' "$name"
    local c
    for c in "${cmds[@]}"; do
        if ! pkg_run "$c"; then
            printf '  ! %s: "%s" failed\n' "$name" "$c" >&2
            return 1
        fi
    done
    [ "$channel" = "cask" ] && _brew_clear_quarantine "$package"
    return 0
}
