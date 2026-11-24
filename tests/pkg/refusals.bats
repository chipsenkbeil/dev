#!/usr/bin/env bats

# A manifest row the driver refuses (a name or repo that is not a plain word, a
# NUL byte in a cell) fails that row only: the other rows are still processed
# and the summary names it. uname reports Darwin so the brew driver runs, and
# brew is a stub that records its arguments and lists nothing.

bats_require_minimum_version 1.5.0

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    LOG="$BATS_TEST_TMPDIR/calls"
    MANIFEST="$BATS_TEST_TMPDIR/tools.tsv"
    mkdir -p "$STUBS"
    : >"$LOG"
    printf '#!/bin/sh\necho "$*" >>"%s"\n[ "$1" != list ] || exit 1\n' "$LOG" >"$STUBS/brew"
    printf '#!/bin/sh\necho Darwin\n' >"$STUBS/uname"
    chmod +x "$STUBS/brew" "$STUBS/uname"
    export PATH="$STUBS:$PATH"
}

@test "install refuses a repo with a leading dash, names the row and still installs the next" {
    printf 'name binary brew\nbad-repo zzz-bad tap:ok,repo:-x/y\nlast zzz-last last-formula\n' >"$MANIFEST"
    run --separate-stderr "$DEV" __pkg install --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"! bad-repo: refusing the package or repo "* ]] || false
    [[ "$stderr" == *"install failed: bad-repo" ]] || false
    grep -qx 'install last-formula' "$LOG"
    ! grep -q -- '-x/y' "$LOG"
}

@test "install refuses an option-like name, a name with a space and a bad repo, one line each" {
    printf 'name binary brew\nopt zzz-a -U\nspc zzz-b "a b"\nrepo zzz-c tap:ok,repo:a/b/c\nlast zzz-last last-formula\n' >"$MANIFEST"
    run --separate-stderr "$DEV" __pkg install --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"! opt: refusing the package or repo "* ]] || false
    [[ "$stderr" == *"! spc: refusing the package or repo "* ]] || false
    [[ "$stderr" == *"! repo: refusing the package or repo "* ]] || false
    [[ "$stderr" == *"install failed: opt spc repo" ]] || false
    grep -qx 'install last-formula' "$LOG"
}

@test "install refuses a NUL byte in a package cell, processes the later rows and names the row" {
    printf 'name binary brew\nnul-cell zzz-a ripgre\0p\nlast zzz-last last-formula\n' >"$MANIFEST"
    run --separate-stderr "$DEV" __pkg install --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"! nul-cell: refusing the package or repo "* ]] || false
    [[ "$stderr" == *"install failed: nul-cell" ]] || false
    [[ "$stderr" != *traceback* ]] || false
    grep -qx 'install last-formula' "$LOG"
}

@test "install refuses a NUL byte in a name and in a binary" {
    printf 'name binary brew\nna\0me zzz-a first-formula\nnul-bin zzz\0b second-formula\nlast zzz-last last-formula\n' >"$MANIFEST"
    run --separate-stderr "$DEV" __pkg install --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'! na\0me: refusing the package or repo '* ]] || false
    [[ "$stderr" == *"! nul-bin: refusing the package or repo "* ]] || false
    [[ "$stderr" == *'install failed: na\0me nul-bin' ]] || false
    grep -qx 'install last-formula' "$LOG"
    ! grep -q 'first-formula' "$LOG"
}

@test "check refuses a NUL byte in a cell and a repo with a leading dash, and reports the later rows" {
    printf 'name binary brew\nnul-cell zzz-a ripgre\0p\nbad-repo zzz-b tap:ok,repo:-x/y\nlast zzz-last last-formula\n' >"$MANIFEST"
    run --separate-stderr "$DEV" __pkg check --manifest "$MANIFEST"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[ ] nul-cell"*"(refusing the package or repo "* ]] || false
    [[ "$output" == *"[ ] bad-repo"*"(refusing the package or repo "* ]] || false
    [[ "$output" == *"[ ] last"* ]] || false
    [[ "$stderr" != *traceback* ]] || false
}
