#!/usr/bin/env bats

# The groups column of tools.tsv and --group on the package driver's install and check.
# uname reports Darwin so the brew driver runs; brew lists nothing and every
# binary is missing, so check reports every selected row.

bats_require_minimum_version 1.5.0

REPO="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
PKG="$REPO/dotfiles/bin/.local/share/dev/pkg.lua"

setup() {
    STUBS="$BATS_TEST_TMPDIR/stubs"
    MANIFEST="$BATS_TEST_TMPDIR/tools.tsv"
    mkdir -p "$STUBS"
    printf '#!/bin/sh\necho Darwin\n' >"$STUBS/uname"
    printf '#!/bin/sh\nexit 1\n' >"$STUBS/brew"
    chmod +x "$STUBS/uname" "$STUBS/brew"
    cat >"$MANIFEST" <<'TSV'
name   binary    brew    groups
aa     aa-zzz    aa-f    base
bb     bb-zzz    bb-f    rust
cc     cc-zzz    cc-f    base,rust
dd     dd-zzz    dd-f    -
TSV
    export PATH="$STUBS:$PATH"
}

@test "install --group base plans the base rows, comma lists included" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group base
    [ "$status" -eq 0 ]
    [[ "$output" == *aa-f* ]] || false
    [[ "$output" == *cc-f* ]] || false
    [[ "$output" != *bb-f* ]] || false
    [[ "$output" != *dd-f* ]] || false
}

@test "install --group rust plans the rust rows, comma lists included" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group rust
    [ "$status" -eq 0 ]
    [[ "$output" == *bb-f* ]] || false
    [[ "$output" == *cc-f* ]] || false
    [[ "$output" != *aa-f* ]] || false
    [[ "$output" != *dd-f* ]] || false
}

@test "check --group base reports only the base rows" {
    run luajit "$PKG" check --manifest "$MANIFEST" --group base
    [ "$status" -eq 1 ]
    [[ "$output" == *aa* ]] || false
    [[ "$output" == *cc* ]] || false
    [[ "$output" != *bb* ]] || false
    [[ "$output" != *dd* ]] || false
}

@test "an unknown group is exit 2 on install and on check" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown group: nope"* ]] || false
    run luajit "$PKG" check --manifest "$MANIFEST" --group nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown group: nope"* ]] || false
}

@test "a named tool outside the group is exit 2 and names the tool" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group base bb
    [ "$status" -eq 2 ]
    [[ "$output" == *"tool bb is not in group base"* ]] || false
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group base zz
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown tool: zz"* ]] || false
}

@test "a named tool inside the group installs" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group base aa
    [ "$status" -eq 0 ]
    [[ "$output" == *aa-f* ]] || false
    [[ "$output" != *cc-f* ]] || false
}

@test "a manifest without a groups column still works and --group is unknown" {
    printf 'name binary brew\naa aa-zzz aa-f\n' >"$MANIFEST"
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *aa-f* ]] || false
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group base
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown group: base"* ]] || false
}

@test "an empty --group name is an unknown group on install and on check" {
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --group ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown group: "* ]] || false
    [[ "$output" != *aa-f* ]] || false
    run luajit "$PKG" check --manifest "$MANIFEST" --group ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown group: "* ]] || false
}

@test "--force with --group installs a named tool in the group" {
    printf '#!/bin/sh\necho "brew $*" >>"%s"\n[ "" != list ]\n' "$BATS_TEST_TMPDIR/calls" >"$STUBS/brew"
    printf '#!/bin/sh\nexit 0\n' >"$STUBS/aa-zzz"
    chmod +x "$STUBS/aa-zzz"
    run luajit "$PKG" install --manifest "$MANIFEST" --group base --force aa
    [ "$status" -eq 0 ]
    grep -q "install.*aa-f" "$BATS_TEST_TMPDIR/calls"
    ! grep -q "cc-f" "$BATS_TEST_TMPDIR/calls"
    run luajit "$PKG" install --manifest "$MANIFEST" --group base --force bb
    [ "$status" -eq 2 ]
}

@test "--scope system --group rust with only user-scope rows is a successful no-op" {
    printf 'name binary brew groups\nu1 u1-zzz script:%s/x.sh rust\nu2 u2-zzz cargo:u2 rust\nsys sys-zzz sys-f base\n' "$BATS_TEST_TMPDIR" >"$MANIFEST"
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --scope system --group rust
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run luajit "$PKG" install --manifest "$MANIFEST" --dry-run --scope system --group base
    [ "$status" -eq 0 ]
    [[ "$output" == *sys-f* ]] || false
}
