#!/usr/bin/env bash
# scripts/pkg/cargo.sh — cross-OS cargo handler. Defines pkg_install for `cargo:`
# cells. Source, do not execute.

# pkg_install <name> <binary> <package> <channel> <repo> <dry_run>
#   Install <package> as a crate. Prefers `cargo-binstall` (fetches prebuilt
#   binaries instead of compiling from source — much faster) when available,
#   falling back to `cargo install --locked`. Skips if already present, unless
#   PKG_FORCE=1.
#   <channel>/<repo> are unused (kept for a uniform driver signature).
pkg_install() {
    local name="$1" binary="$2" package="$3" dry_run="$6" force=""
    if [ "${PKG_FORCE:-0}" = 1 ]; then
        force=" --force"
    elif [ "$binary" != "-" ] && command -v "$binary" >/dev/null 2>&1; then
        printf '  = %s already on PATH, skipping\n' "$name"
        return 0
    elif cargo install --list 2>/dev/null | grep -q "^${package} "; then
        printf '  = %s already installed via cargo, skipping\n' "$name"
        return 0
    fi

    # Detect cargo-binstall robustly: during an install run ~/.cargo/bin may not
    # yet be on PATH (cargo-binstall is installed earlier in the same run), so
    # probe that location explicitly as a fallback.
    local binstall=""
    if command -v cargo-binstall >/dev/null 2>&1; then
        binstall=cargo-binstall
    elif [ -x "$HOME/.cargo/bin/cargo-binstall" ]; then
        binstall="$HOME/.cargo/bin/cargo-binstall"
    fi

    local cmd
    if [ -n "$binstall" ]; then
        # Invoked directly (not as a `cargo` subcommand) the crate is a
        # positional arg. Flags (verified against `cargo-binstall --help`):
        #   --no-confirm         non-interactive (no y/N prompt)
        #   --disable-telemetry  opt out of anonymous usage reporting
        cmd="$binstall --no-confirm --disable-telemetry$force $package"
    else
        cmd="cargo install --locked$force $package"
    fi

    if [ "$dry_run" = "1" ]; then
        printf '  + %s (dry-run):\n      %s\n' "$name" "$cmd"
        return 0
    fi
    printf '  + installing %s (cargo)...\n' "$name"
    pkg_run "$cmd"
}
