#!/usr/bin/env bats

# The cargo driver gives rustup a default toolchain before a crate install, since the
# distro rustup packages ship none. rustup, cargo and cargo-binstall are stubs
# that record their arguments.

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    LOG="$BATS_TEST_TMPDIR/calls"
    mkdir -p "$STUBS"
    : >"$LOG"
    stub rustup 'echo "rustup $*" >>"'"$LOG"'"; [ "$1" != default ] || [ -z "${RUSTUP_DEFAULT_FAILS:-}" ] || exit 1; [ "$1 $2" != "show active-toolchain" ] || [ -n "${RUSTUP_HAS_DEFAULT:-}" ]'
    stub cargo-binstall 'echo "binstall $*" >>"'"$LOG"'"'
    stub uname 'echo Darwin'
    printf 'name binary brew\nzzz-tool - cargo:zzz-crate\n' >"$BATS_TEST_TMPDIR/tools.tsv"
    export PATH="$STUBS:/usr/bin:/bin"
}

stub() {
    printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

install_crate() {
    "$DEV" __pkg install --manifest "$BATS_TEST_TMPDIR/tools.tsv" zzz-tool
}

@test "a rustup with no default toolchain gets stable before the crate installs" {
    run install_crate
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "$LOG")" = "rustup default stable" ]
    [ "$(sed -n 3p "$LOG")" = "binstall --no-confirm --disable-telemetry --locked zzz-crate" ]
}

@test "a rustup that already has a default toolchain is left alone" {
    RUSTUP_HAS_DEFAULT=1 run install_crate
    [ "$status" -eq 0 ]
    [ "$(grep -c 'rustup default' "$LOG")" -eq 0 ]
    [ "$(grep -c binstall "$LOG")" -eq 1 ]
}

@test "a failing rustup default stops the install before the crate" {
    RUSTUP_DEFAULT_FAILS=1 run install_crate
    [ "$status" -ne 0 ]
    [ "$(grep -c binstall "$LOG")" -eq 0 ]
    [ "$(grep -c 'cargo install' "$LOG")" -eq 0 ]
}
