#!/usr/bin/env bats

# pkg.sh install tries every row, then exits nonzero naming the rows that
# failed. uname reports Darwin so the brew driver runs, and brew is a stub that
# records its arguments and fails for the package named bad-formula.

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PKG="$REPO/scripts/pkg.sh"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    LOG="$BATS_TEST_TMPDIR/calls"
    MANIFEST="$BATS_TEST_TMPDIR/tools.tsv"
    mkdir -p "$STUBS"
    : >"$LOG"
    printf '#!/bin/sh\necho "$*" >>"%s"\n[ "$1" != list ] || exit 1\n[ "$*" != "install bad-formula" ]\n' "$LOG" >"$STUBS/brew"
    printf '#!/bin/sh\necho Darwin\n' >"$STUBS/uname"
    chmod +x "$STUBS/brew" "$STUBS/uname"
    printf 'name binary brew\nfirst-tool zzz-first first-formula\nbad-tool zzz-bad bad-formula\nlast-tool zzz-last last-formula\n' >"$MANIFEST"
    export PATH="$STUBS:$PATH"
}

@test "a failing middle row exits nonzero and the last row still installs" {
    run bash "$PKG" install --manifest "$MANIFEST"
    [ "$status" -ne 0 ]
    grep -qx 'install first-formula' "$LOG"
    grep -qx 'install last-formula' "$LOG"
    [[ "$output" == *"install failed: bad-tool" ]] || false
}

@test "every failed row is named in the one summary line" {
    printf '#!/bin/sh\necho "$*" >>"%s"\n[ "$1" != list ] || exit 1\n[ "$1" != install ]\n' "$LOG" >"$STUBS/brew"
    run bash "$PKG" install --manifest "$MANIFEST"
    [ "$status" -ne 0 ]
    [[ "$output" == *"install failed: first-tool bad-tool last-tool" ]] || false
}

@test "a run where every row succeeds exits zero with no summary" {
    run bash "$PKG" install --manifest "$MANIFEST" first-tool last-tool
    [ "$status" -eq 0 ]
    [[ "$output" != *"install failed"* ]] || false
}

@test "naming only the failing tool exits nonzero" {
    run bash "$PKG" install --manifest "$MANIFEST" bad-tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"install failed: bad-tool" ]] || false
}

@test "a bin: override that is an absolute path counts as present for check and install" {
    printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/app-cli"
    chmod +x "$BATS_TEST_TMPDIR/app-cli"
    printf 'name binary brew\napp-tool - cask:app-cask,bin:%s\n' "$BATS_TEST_TMPDIR/app-cli" >"$MANIFEST"
    run bash "$PKG" check --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[x] app-tool"*"$BATS_TEST_TMPDIR/app-cli"* ]] || false
    run bash "$PKG" install --manifest "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$output" == *"app-tool already on PATH, skipping"* ]] || false
    ! grep -q '^install' "$LOG"
}
