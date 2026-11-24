#!/usr/bin/env bats

# The package driver check probes a script: row whose binary is "-" by running the script
# with --check from the project root. uname reports Darwin so the brew driver
# loads, and curl is a stub that fails loudly when called.

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"

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
    run "$DEV" __pkg check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[x] probe-tool\t(script --check)'* ]] || false
}

@test "a script row with no binary is missing when the script exits 1 on --check" {
    printf '#!/bin/sh\nexit 1\n' >"$ROOT/probe.sh"
    printf 'name binary brew\nprobe-tool - script:probe.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run "$DEV" __pkg check --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ ] probe-tool"* ]] || false
}

@test "a --check script that reads stdin does not swallow the rows after it" {
    printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$ROOT/probe.sh"
    printf '#!/bin/sh\nexit 0\n' >"$ROOT/probe2.sh"
    printf 'name binary brew\nprobe-tool - script:probe.sh\nprobe-two - script:probe2.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run "$DEV" __pkg check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[x] probe-two\t(script --check)'* ]] || false
}

@test "check as root never runs a script row and shows it as unknown" {
    printf '#!/bin/sh\necho ran >"%s/ran"\nexit 0\n' "$BATS_TEST_TMPDIR" >"$ROOT/probe.sh"
    export FAKE_UID=0 FAKE_OS=Darwin
    printf 'name binary brew\nprobe-tool - script:probe.sh\n' >"$MANIFEST"
    cd "$ROOT"
    printf 'require("@dev/runtime").dofile("%s/tests/lua/fake_env.luau")\nrequire("@dev/os").exit(require("@dev/pkg").main({ table.unpack(arg) }))\n' "$REPO" >"$BATS_TEST_TMPDIR/driver.luau"
    run "$DEV" -l "$BATS_TEST_TMPDIR/driver.luau" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[?] probe-tool\t(script row, never run as root)'* ]] || false
    [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "an https script row with no binary is never fetched and does not fail check" {
    printf 'name binary brew\nremote-tool - script:https://example.invalid/x.sh\n' >"$MANIFEST"
    cd "$ROOT"
    run "$DEV" __pkg check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'[?] remote-tool\t(remote script, no probe)'* ]] || false
    [[ "$output" != *"curl called"* ]] || false
}
