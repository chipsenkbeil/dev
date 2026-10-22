#!/usr/bin/env bats

# pkg.sh install --force, and --force through dev tools install. uname reports
# Darwin so the brew driver runs, and every package manager is a stub that
# records its arguments.

bats_require_minimum_version 1.5.0

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PKG="$REPO/scripts/pkg.sh"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    LOG="$BATS_TEST_TMPDIR/calls"
    MANIFEST="$BATS_TEST_TMPDIR/tools.tsv"
    mkdir -p "$STUBS"
    : >"$LOG"
    stub uname 'echo Darwin'
    stub brew 'echo "brew $*" >>"'"$LOG"'"; [ "$1" != list ] || [ "${BREW_LISTED:-1}" = 1 ]'
    stub fx 'exit 0'
    stub sy 'exit 0'
    printf '#!/bin/sh\necho "script PKG_FORCE=$PKG_FORCE" >>"%s"\n' "$LOG" >"$BATS_TEST_TMPDIR/record.sh"
    printf 'name binary brew\nformula-x fx fx-formula\nscript-y sy script:%s\n' \
        "$BATS_TEST_TMPDIR/record.sh" >"$MANIFEST"
    export PATH="$STUBS:$PATH"
}

# stub <name> <body>: an executable under $STUBS.
stub() {
    printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

@test "an installed formula is skipped without --force" {
    run bash "$PKG" install --manifest "$MANIFEST" formula-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"formula-x already on PATH, skipping"* ]] || false
    [ "$(grep -c install "$LOG")" -eq 0 ]
}

@test "--force reinstalls a formula brew already lists" {
    run bash "$PKG" install --manifest "$MANIFEST" --force formula-x
    [ "$status" -eq 0 ]
    grep -qx 'brew reinstall fx-formula' "$LOG"
}

@test "--force installs a formula brew does not list" {
    BREW_LISTED=0 run bash "$PKG" install --manifest "$MANIFEST" --force formula-x
    [ "$status" -eq 0 ]
    grep -qx 'brew install fx-formula' "$LOG"
}

@test "--force runs a script: installer that is on PATH and passes PKG_FORCE to it" {
    run bash "$PKG" install --manifest "$MANIFEST" --force script-y
    [ "$status" -eq 0 ]
    grep -qx 'script PKG_FORCE=1' "$LOG"
}

@test "--force with no tool name is a usage error" {
    run --separate-stderr bash "$PKG" install --manifest "$MANIFEST" --force
    [ "$status" -eq 2 ]
    [ "$stderr" = "--force needs at least one tool name" ]
    [ ! -s "$LOG" ]
}

@test "dev tools install --force plans the muchsync rebuild even when muchsync is on PATH" {
    stub muchsync 'exit 0'
    cd "$REPO"
    run "$REPO/dotfiles/bin/.local/bin/dev" tools install --dry-run muchsync
    [ "$status" -eq 0 ]
    [[ "$output" == *"muchsync already on PATH, skipping"* ]] || false
    run "$REPO/dotfiles/bin/.local/bin/dev" tools install --force --dry-run muchsync
    [ "$status" -eq 0 ]
    [[ "$output" == *"bash scripts/install-muchsync.sh"* ]] || false
    [[ "$output" != *"skipping"* ]] || false
}

@test "under PKG_FORCE=1 the other drivers reinstall instead of skipping" {
    stub pacman 'exit 0'
    stub rpm 'exit 0'
    stub cargo 'exit 0'
    stub luarocks 'echo rock'
    out="$(PKG_FORCE=1 bash -c '
        dir=$1
        (source "$dir/pacman.sh" && pkg_install p fx p-pkg "" "" 1)
        (source "$dir/dnf.sh" && pkg_install d fx d-pkg "" "" 1)
        (source "$dir/cargo.sh" && pkg_install c fx c-crate "" "" 1)
        (source "$dir/luarocks.sh" && pkg_install l fx rock "" "" 1)
    ' _ "$REPO/scripts/pkg" 2>&1)"
    [[ "$out" == *"pacman -S --noconfirm -- p-pkg"* ]] || false
    [[ "$out" == *"dnf reinstall -y -- d-pkg"* ]] || false
    [[ "$out" == *"--force c-crate"* ]] || false
    [[ "$out" == *"luarocks install --force rock"* ]] || false
    [[ "$out" != *"skipping"* ]] || false
}
