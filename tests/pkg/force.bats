#!/usr/bin/env bats

# The package driver's install --force, and --force through dev tools install. uname reports
# Darwin so the brew driver runs, and every package manager is a stub that
# records its arguments.

bats_require_minimum_version 1.5.0

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"

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
    run "$DEV" __pkg install --manifest "$MANIFEST" formula-x
    [ "$status" -eq 0 ]
    [[ "$output" == *"formula-x already on PATH, skipping"* ]] || false
    [ "$(grep -c install "$LOG")" -eq 0 ]
}

@test "--force reinstalls a formula brew already lists" {
    run "$DEV" __pkg install --manifest "$MANIFEST" --force formula-x
    [ "$status" -eq 0 ]
    grep -qx 'brew reinstall fx-formula' "$LOG"
}

@test "--force installs a formula brew does not list" {
    BREW_LISTED=0 run "$DEV" __pkg install --manifest "$MANIFEST" --force formula-x
    [ "$status" -eq 0 ]
    grep -qx 'brew install fx-formula' "$LOG"
}

@test "--force runs a script: installer that is on PATH and passes PKG_FORCE to it" {
    run "$DEV" __pkg install --manifest "$MANIFEST" --force script-y
    [ "$status" -eq 0 ]
    grep -qx 'script PKG_FORCE=1' "$LOG"
}

@test "--force with no tool name is a usage error" {
    run --separate-stderr "$DEV" __pkg install --manifest "$MANIFEST" --force
    [ "$status" -eq 2 ]
    [ "$stderr" = "--force needs at least one tool name" ]
    [ ! -s "$LOG" ]
}

@test "under force the other drivers reinstall instead of skipping" {
    stub pacman 'exit 0'
    stub rpm 'exit 0'
    stub cargo 'exit 0'
    stub luarocks 'echo rock'
    cat >"$BATS_TEST_TMPDIR/drive.luau" <<'LUA'
local opts = { dry_run = true, force = true, log_file = "" }
local function row(name, package)
    return { name = name, binary = "fx", package = package, channel = "", repo = "" }
end
require("@dev/pkg/pacman").install(row("p", "p-pkg"), opts)
require("@dev/pkg/dnf").install(row("d", "d-pkg"), opts)
require("@dev/pkg/cargo").install(row("c", "c-crate"), opts)
require("@dev/pkg/luarocks").install(row("l", "rock"), opts)
LUA
    out="$("$DEV" -l "$BATS_TEST_TMPDIR/drive.luau" 2>&1)"
    [[ "$out" == *"pacman -S --noconfirm -- p-pkg"* ]] || false
    [[ "$out" == *"dnf reinstall -y -- d-pkg"* ]] || false
    [[ "$out" == *"--force c-crate"* ]] || false
    [[ "$out" == *"luarocks install --force rock"* ]] || false
    [[ "$out" != *"skipping"* ]] || false
}
