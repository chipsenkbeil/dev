#!/usr/bin/env bats

# The package driver check probes a script: row whose binary is "-" by running the script
# with --check from the project root. uname reports Darwin so the brew driver
# loads, and curl is a stub that fails loudly when called.

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PKG="$REPO/dotfiles/bin/.local/share/dev/pkg.lua"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    ROOT="$BATS_TEST_TMPDIR/root"
    MANIFEST="$BATS_TEST_TMPDIR/tools.tsv"
    mkdir -p "$STUBS" "$ROOT"
    printf '#!/bin/sh\necho Darwin\n' >"$STUBS/uname"
    printf '#!/bin/sh\nexit 1\n' >"$STUBS/brew"
    printf '#!/bin/sh\necho curl called >&2\nexit 99\n' >"$STUBS/curl"
    chmod +x "$STUBS/uname" "$STUBS/brew" "$STUBS/curl"
    export PATH="$STUBS:$PATH"
}

@test "a script row with no binary is present when the script exits 0 on --check" {
    printf '#!/bin/sh\n[ "$1" = --check ]\n' >"$ROOT/probe.sh"
    printf 'name binary brew\nprobe-tool - script:probe.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run luajit "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[x] probe-tool\t(script --check)'* ]] || false
}

@test "a script row with no binary is missing when the script exits 1 on --check" {
    printf '#!/bin/sh\nexit 1\n' >"$ROOT/probe.sh"
    printf 'name binary brew\nprobe-tool - script:probe.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run luajit "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ ] probe-tool"* ]] || false
}

@test "a --check script that reads stdin does not swallow the rows after it" {
    printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$ROOT/probe.sh"
    printf '#!/bin/sh\nexit 0\n' >"$ROOT/probe2.sh"
    printf 'name binary brew\nprobe-tool - script:probe.sh\nprobe-two - script:probe2.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run luajit "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[x] probe-two\t(script --check)'* ]] || false
}

@test "check as root never runs a script row and shows it as unknown" {
    printf '#!/bin/sh\necho ran >"%s/ran"\nexit 0\n' "$BATS_TEST_TMPDIR" >"$ROOT/probe.sh"
    export LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=0
    printf 'name binary brew\nprobe-tool - script:probe.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run luajit "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[?] probe-tool\t(script row, never run as root)'* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "every script row with no binary in the real manifest takes --check" {
    local script
    while read -r script; do
        grep -q -- '--check' "$REPO/$script" || {
            echo "$script has no --check" >&2
            false
        }
    done < <(awk '!/^#/ && NF && $2 == "-" { for (i = 3; i <= NF; i++) if ($i ~ /^script:/ && $i !~ /^script:https?:/) { sub(/^script:/, "", $i); print $i } }' "$REPO/.dev/tools.tsv" | sort -u)
}

@test "an https script row with no binary is never fetched and does not fail check" {
    printf 'name binary brew\nremote-tool - script:https://example.invalid/x.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run luajit "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[?] remote-tool\t(remote script, no probe)'* ]] || false
    [[ "$output" != *"curl called"* ]] || false
}

@test "install-rustfmt-nightly --check exits 0 when cargo +nightly fmt works and never calls rustup" {
    printf '#!/bin/sh\nexit 0\n' >"$STUBS/cargo"
    printf '#!/bin/sh\necho "$*" >>"%s/rustup.log"\n' "$BATS_TEST_TMPDIR" >"$STUBS/rustup"
    chmod +x "$STUBS/cargo" "$STUBS/rustup"
    run bash "$REPO/scripts/install-rustfmt-nightly.sh" --check
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$BATS_TEST_TMPDIR/rustup.log" ]
}

@test "install-rustfmt-nightly --check exits 1 when cargo +nightly fmt fails and never calls rustup" {
    printf '#!/bin/sh\nexit 1\n' >"$STUBS/cargo"
    printf '#!/bin/sh\necho "$*" >>"%s/rustup.log"\n' "$BATS_TEST_TMPDIR" >"$STUBS/rustup"
    chmod +x "$STUBS/cargo" "$STUBS/rustup"
    run bash "$REPO/scripts/install-rustfmt-nightly.sh" --check
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/rustup.log" ]
}
