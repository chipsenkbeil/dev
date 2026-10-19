#!/usr/bin/env bash
# Pure-bash tests for .dev/lint.sh and the style skill's Rust and Lua lint.sh, each run on scratch files.
# Each script is copied into a temp tree, so the repo is never linted, and the style sets run on stubbed tools.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.dev" "$TMP/scripts" "$TMP/tests" "$TMP/dotfiles/bin" "$TMP/dotfiles/jj/.config/jj/scripts"
cp "$REPO/.dev/lint.sh" "$REPO/.dev/lib.sh" "$TMP/.dev/"
cp "$REPO/scripts/helpers.sh" "$TMP/scripts/helpers.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n    echo ok\nfi\n' >"$TMP/scripts/clean.sh"

fails=0

assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$desc" "$got" "$want"
        fails=$((fails + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
    *"$needle"*) printf 'ok   - %s\n' "$desc" ;;
    *)
        printf 'FAIL - %s\n       missing: %q\n       in:      %q\n' "$desc" "$needle" "$haystack"
        fails=$((fails + 1))
        ;;
    esac
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
    *"$needle"*)
        printf 'FAIL - %s\n       unexpected: %q\n' "$desc" "$needle"
        fails=$((fails + 1))
        ;;
    *) printf 'ok   - %s\n' "$desc" ;;
    esac
}

# lint: run the copied lint script, capturing stdout and stderr together.
lint() {
    bash "$TMP/.dev/lint.sh" 2>&1
}

out="$(lint)"
rc=$?
assert_eq "a clean tree exits 0" "$rc" "0"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n  echo drifted\nfi\n' >"$TMP/scripts/drift.sh"
out="$(lint)"
rc=$?
assert_eq "shfmt drift exits non-zero" "$((rc != 0))" "1"
assert_contains "shfmt drift names the file" "$out" "scripts/drift.sh"
rm "$TMP/scripts/drift.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nvalue=1\n# explains the next line\necho done\n' >"$TMP/scripts/spacing.sh"
out="$(lint)"
rc=$?
assert_eq "a comment under code exits non-zero" "$((rc != 0))" "1"
assert_contains "a comment under code names file and line" "$out" "scripts/spacing.sh:5: full-line comment directly after code"
rm "$TMP/scripts/spacing.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\necho a \\\n    b\n# explains the next line\necho done\n' >"$TMP/scripts/deeper.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\ncase b in\na)\n    echo a\n    ;;\n# The b arm\nb)\n    echo b\n    ;;\nesac\n' >"$TMP/scripts/arms.sh"
out="$(lint)"
assert_contains "a comment under deeper code fails" "$out" "scripts/deeper.sh:6: full-line comment directly after code"
assert_not_contains "a comment heading the next case arm passes" "$out" "scripts/arms.sh:"
rm "$TMP/scripts/deeper.sh" "$TMP/scripts/arms.sh"

printf '@test "bare" {\n    true\n    [[ hi == *hi* ]]\n    true\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a bare [[ ]] assertion in a bats file exits non-zero" "$((rc != 0))" "1"
assert_contains "a bare [[ ]] assertion names file and line" "$out" "tests/bare.bats:3: a bare [[ ]] assertion never fails a test under bash 3.2"
printf '@test "guarded" {\n    [[ hi == *hi* ]] || false\n    run zsh -c "[[ -n x ]] && print ok"\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a [[ ]] assertion ending in || false passes" "$rc" "0"
assert_not_contains "a [[ ]] inside a command string passes" "$out" "tests/bare.bats"
rm "$TMP/tests/bare.bats"

STYLE="$REPO/dotfiles/claude/.claude/skills/style/lint"
STUBS="$TMP/stubs"
BARE="$TMP/bare"
mkdir -p "$STUBS" "$BARE"
for tool in cargo-sort cargo-deny ast-grep stylua selene; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/$tool"
done

# shellcheck disable=SC2016  # $1, CARGO_LOG and NO_NIGHTLY expand in the generated stub
printf '#!/usr/bin/env bash\nif [ -n "${CARGO_LOG:-}" ]; then echo "$*" >>"$CARGO_LOG"; fi\nif [ -n "${NO_NIGHTLY:-}" ] && [ "$1" = +nightly ]; then exit 1; fi\nexit 0\n' >"$STUBS/cargo"
chmod +x "$STUBS"/*
cp "$STUBS/cargo" "$BARE/cargo"

style_lint() {
    local project=$1 path=$2
    shift 2
    env -u CI PATH="$path" "$@" bash "$project/lint.sh" 2>&1
}

missing_tools=""
for tool in rg yq; do
    if command -v "$tool" >/dev/null 2>&1; then
        ln -s "$(command -v "$tool")" "$BARE/$tool"
    else
        missing_tools="$missing_tools $tool"
    fi
done

if [ -n "$missing_tools" ]; then
    printf 'SKIP style lint set tests (needs%s on PATH)\n' "$missing_tools"
else
    full_path="$STUBS:$BARE:/usr/bin:/bin"
    bare_path="$BARE:/usr/bin:/bin"

    rust="$TMP/rust"
    mkdir -p "$rust/src" "$rust/scripts"
    cp "$STYLE/lint-lib.sh" "$TMP/lint-lib.sh"
    cp "$STYLE/rust/lint.sh" "$rust/lint.sh"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n' >"$rust/Cargo.toml"
    printf 'pub fn noop() {}\n' >"$rust/src/lib.rs"

    out="$(style_lint "$rust" "$full_path")"
    assert_eq "the rust set passes a clean project" "$?" "0"
    assert_not_contains "the rust set warns about no tool when all are present" "$out" "WARNING"

    calls="$TMP/cargo-calls"
    : >"$calls"
    out="$(style_lint "$rust" "$full_path" CARGO_LOG="$calls")"
    assert_contains "the debug clippy pass always runs" "$(cat "$calls")" "clippy --all-targets --all-features -- -D warnings"
    assert_not_contains "a project without debug_assertions gets no release clippy pass" "$(cat "$calls")" "--release"
    printf '#[cfg(not(debug_assertions))]\nfn release_only() {}\n' >"$rust/src/release.rs"
    : >"$calls"
    out="$(style_lint "$rust" "$full_path" CARGO_LOG="$calls")"
    assert_contains "a project with debug_assertions gets the release clippy pass" "$(cat "$calls")" "clippy --release --all-targets --all-features -- -D warnings"
    assert_contains "the release clippy pass is announced" "$out" "> cargo clippy release"
    rm "$rust/src/release.rs"

    printf 'pub fn names(map: &mut Map) {\n    map.entries\n        .remove(&name);\n    // Drop the stale entry\n    map.flush();\n}\n' >"$rust/src/chain.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a comment after the end of a method chain fails" "$out" "src/chain.rs:4: full-line comment directly after code"
    printf 'pub fn names(map: &mut Map) {\n    map.entries\n        .remove(&name);\n\n    // Drop the stale entry\n    map.flush();\n}\n' >"$rust/src/chain.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a blank line after the end of a method chain passes" "$out" "src/chain.rs"
    printf 'pub fn names(map: &mut Map) {\n    map.entries\n        .iter()\n        // Keep live entries\n        .filter(|e| e.live);\n    let list = vec![\n        1,\n        // The second\n        2,\n    ];\n}\n' >"$rust/src/chain.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a comment inside a method chain or a literal still passes" "$out" "src/chain.rs"
    printf 'pub fn pick(x: u8) -> u8 {\n    match x {\n        0 => 1,\n        // The rest\n        _ => 2,\n    }\n}\n' >"$rust/src/chain.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a comment between match arms fails" "$out" "src/chain.rs:4: full-line comment directly after code"
    printf 'pub fn pick(x: u8) -> u8 {\n    match x {\n        0 => 1,\n\n        // The rest\n        _ => 2,\n    }\n}\n' >"$rust/src/chain.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a blank line before a comment between match arms passes" "$out" "src/chain.rs"
    rm "$rust/src/chain.rs"

    mkdir -p "$rust/.dev/evidence"
    printf 'pub fn names(map: &mut Map) {\n    map.entries\n        .remove(&name);\n    // Drop the stale entry\n    map.flush();\n}\n' >"$rust/.dev/evidence/old.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a violation under .dev/evidence fails with no lint-ignore" "$out" ".dev/evidence/old.rs:4: full-line comment directly after code"
    printf '# Snapshots of old code\n\n.dev/evidence/**\n' >"$rust/.dev/lint-ignore"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a path matched by lint-ignore is not linted, comments and blank lines skipped" "$out" ".dev/evidence/old.rs"
    printf '# Snapshots of old code\n\nother/**\n' >"$rust/.dev/lint-ignore"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "the file is linted again once its pattern is removed" "$out" ".dev/evidence/old.rs:4: full-line comment directly after code"
    rm "$rust/.dev/lint-ignore"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a missing lint-ignore changes nothing" "$out" ".dev/evidence/old.rs:4: full-line comment directly after code"

    gitfix="$TMP/gitfix"
    mkdir -p "$gitfix/.dev/evidence" "$gitfix/src"
    : >"$gitfix/.dev/evidence/old.rs"
    : >"$gitfix/src/new.rs"
    git -C "$gitfix" init -q
    printf '# comment\n\n.dev/evidence/**\n' >"$gitfix/.dev/lint-ignore"

    # shellcheck disable=SC1091  # the library path is only known at run time
    out="$(cd "$gitfix" && . "$TMP/lint-lib.sh" && lint_files '*.rs' | sort)"
    assert_eq "the git walk leaves lint-ignore paths out" "$out" "src/new.rs"
    rm "$gitfix/.dev/lint-ignore"

    # shellcheck disable=SC1091  # the library path is only known at run time
    out="$(cd "$gitfix" && . "$TMP/lint-lib.sh" && lint_files '*.rs' | sort)"
    assert_eq "the git walk keeps every path without a lint-ignore" "$out" ".dev/evidence/old.rs
src/new.rs"
    rm -rf "$rust/.dev"

    printf 'use std::io;\n#[cfg(windows)]\nuse std::os::windows::process::CommandExt;\nuse std::process::Command;\n' >"$rust/src/gated.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a top-level cfg-gated use fails" "$out" "src/gated.rs:2: a #[cfg]-gated use sits at the top level of the file"
    printf 'use std::io;\n#[cfg(unix)]\n#[expect(unused_imports, reason = "only some targets")]\nuse std::os::unix::process::CommandExt;\n' >"$rust/src/gated.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a cfg-gated attribute run above a top-level use fails" "$out" "src/gated.rs:2: a #[cfg]-gated use"
    printf '#[cfg(windows)]\nfn detach() {\n    use std::os::windows::process::CommandExt;\n}\n\n#[cfg(unix)]\nmod unix {\n    use std::os::unix::process::CommandExt;\n}\n' >"$rust/src/gated.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a cfg-gated use inside its function or mod passes" "$out" "src/gated.rs"
    printf '#[cfg(feature = "x")]\npub use crate::x::Thing;\n#[cfg(unix)]\npub(crate) use crate::unix::detach;\n' >"$rust/src/gated.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a cfg-gated pub use re-export passes" "$out" "src/gated.rs"
    rm "$rust/src/gated.rs"

    printf 'pub fn run() {\n    // Drop the stale entry.\n    flush();\n}\n' >"$rust/src/period.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a // one-liner ending in a period fails" "$out" "src/period.rs:2: a // one-liner ends in a period"
    printf 'pub fn run() {\n    // Drop the stale entry\n    flush();\n\n    // Keep the first.\n    // Drop the second.\n    flush();\n    let url = "a"; // Ends here.\n}\n\n/// Runs once.\npub fn other() {}\n' >"$rust/src/period.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a period-free one-liner, a two-line comment, a trailing comment and a doc line pass" "$out" "src/period.rs"
    rm "$rust/src/period.rs"

    printf 'pub fn run() {\n    // First line\n    // second line\n    // third line\n    flush();\n}\n' >"$rust/src/runs.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "three consecutive // lines fail" "$out" "src/runs.rs:2: 3 consecutive comment lines"
    printf 'pub fn run() {\n    // First line\n    // second line\n    flush();\n\n    // 1. First case\n    // 2. Second case\n    // 3. Third case\n    flush();\n}\n\n/// A doc\n/// that runs\n/// long enough\npub fn other() {}\n' >"$rust/src/runs.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "two // lines, a numbered list and a doc comment run pass" "$out" "src/runs.rs"
    rm "$rust/src/runs.rs"

    printf 'pub struct Name;\n\nimpl Name {\n    pub fn get_value(&self) -> u8 {\n        0\n    }\n\n    pub(crate) async fn get_other(&self) {}\n}\n' >"$rust/src/getter.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a pub fn get_ fails" "$out" "src/getter.rs:4: pub fn get_ names an accessor with a verb"
    assert_contains "a pub(crate) async fn get_ fails" "$out" "src/getter.rs:8: pub fn get_ names an accessor with a verb"
    printf 'pub struct Name;\n\nimpl Name {\n    pub fn value(&self) -> u8 {\n        0\n    }\n\n    fn get_private(&self) {}\n\n    pub fn target(&self) -> u8 {\n        0\n    }\n}\n' >"$rust/src/getter.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a noun accessor, a private get_ and a name containing get_ pass" "$out" "src/getter.rs"
    rm "$rust/src/getter.rs"

    printf '/// Does a thing.\n///\n/// ## Examples\n///\n/// ### Note\npub fn run() {}\n' >"$rust/src/heading.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a /// ## heading fails" "$out" "src/heading.rs:3: a doc comment heading below h1"
    assert_contains "a /// ### heading fails" "$out" "src/heading.rs:5: a doc comment heading below h1"
    printf '/// Does a thing.\n///\n/// # Examples\n///\n/// Shows x = 1 // ## not a heading\npub fn run() {}\n' >"$rust/src/heading.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "an h1 doc heading passes" "$out" "src/heading.rs:"
    rm "$rust/src/heading.rs"

    printf '#!/usr/bin/env bash\ncase b in\na)\n    echo a\n    ;;\n# The b arm\nb)\n    echo b\n    ;;\nesac\n' >"$rust/scripts/arms.sh"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a shell comment heading the next case arm passes" "$out" "scripts/arms.sh:"
    printf '#!/usr/bin/env bash\nrun \\\n    --flag\n# Then finish\nfinish\n' >"$rust/scripts/arms.sh"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a shell comment after a deeper continuation line fails" "$out" "scripts/arms.sh:4: full-line comment directly after code"
    rm "$rust/scripts/arms.sh"

    out="$(style_lint "$rust" "$bare_path")"
    rc=$?
    assert_eq "a missing tool outside CI only warns" "$rc" "0"
    assert_contains "the warning names the check a missing tool skips" "$out" "WARNING: cargo-sort not found, skipping the cargo sort check"
    out="$(style_lint "$rust" "$bare_path" CI=1 NO_NIGHTLY=1)"
    assert_contains "a missing cargo-sort fails under CI" "$out" "cargo-sort not found, so the cargo sort check cannot run"
    assert_contains "a missing cargo-deny fails under CI" "$out" "cargo-deny not found, so the cargo deny check cannot run"
    assert_contains "a missing nightly rustfmt fails under CI" "$out" "nightly rustfmt not found, so the cargo fmt check cannot run"
    assert_contains "the CI failure lists each skipped check" "$out" "FAILED: cargo fmt ast-grep scan cargo sort cargo deny"

    if [ -e "$BARE/sd" ] || [ -x /usr/bin/sd ] || [ -x /bin/sd ]; then
        printf 'SKIP manifests without sd (sd is on the bare PATH)\n'
    else
        printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2021"\npublish = false\n' >"$rust/Cargo.toml"
        out="$(style_lint "$rust" "$bare_path")"
        assert_contains "the manifests check runs without sd" "$out" "Cargo.toml: edition is '2021', want 2024"
        assert_contains "the run reaches the later checks without sd" "$out" "> comment spacing"
    fi

    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a crate with no publish key needs rust-version" "$out" "Cargo.toml: declares no rust-version, but the crate is published"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\nrust-version = "1.85"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a crate with no publish key and a rust-version passes" "$out" "rust-version"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\nrust-version = "1.85"\n' >"$rust/Cargo.toml"
    printf '[toolchain]\nchannel = "1.85.0"\n' >"$rust/rust-toolchain.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "an unpublished crate with a pin and a rust-version fails" "$out" "Cargo.toml: declares rust-version 1.85, but the crate sets publish = false"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "an unpublished crate with a pin and no rust-version passes" "$out" "rust-version"
    rm "$rust/rust-toolchain.toml"

    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n\n[dependencies]\nonce_cell = "1"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "a once_cell dependency fails" "$out" "Cargo.toml: depends on once_cell, use std::sync::LazyLock"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n\n[dependencies]\nserde = "1"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "an allowed dependency passes" "$out" "depends on"

    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\nrust-version = "1.85"\n\n[dependencies]\nthiserror = "2"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "thiserror in a published library crate fails" "$out" "Cargo.toml: a library crate depends on thiserror"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n\n[dependencies]\nthiserror = "2"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "thiserror in an unpublished crate passes" "$out" "depends on thiserror"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\nrust-version = "1.85"\n\n[dev-dependencies]\nthiserror = "2"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "thiserror as a dev-dependency of a library passes" "$out" "depends on thiserror"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\nrust-version = "1.85"\n\n[dependencies]\nserde = "1"\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "a published library crate without thiserror passes" "$out" "depends on thiserror"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n\n[dependencies]\nserde = "1"\n' >"$rust/Cargo.toml"

    mkdir -p "$rust/crates/core/src" "$rust/crates/app/src"
    printf '[package]\nname = "core"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n' >"$rust/crates/core/Cargo.toml"
    printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n' >"$rust/crates/app/Cargo.toml"
    printf '#[expect(unsafe_code, reason = "a transparent cast")]\npub fn cast() {}\n' >"$rust/crates/core/src/lib.rs"
    printf '#![allow(clippy::all, unsafe_code)]\n' >"$rust/crates/app/src/lib.rs"
    printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n\n[workspace.metadata.style]\nallow-unsafe = ["./crates/core/"]\n' >"$rust/Cargo.toml"
    out="$(style_lint "$rust" "$full_path")"
    assert_not_contains "an expect(unsafe_code) in a listed crate passes" "$out" "crates/core/src/lib.rs"
    assert_contains "an allow(unsafe_code) in an unlisted crate fails" "$out" "crates/app/src/lib.rs:1: allows unsafe_code, but [workspace.metadata.style] allow-unsafe in Cargo.toml does not list the crate at 'crates/app'"
    printf '#[expect(unsafe_code, reason = "root")]\npub fn noop() {}\n' >"$rust/src/lib.rs"
    out="$(style_lint "$rust" "$full_path")"
    assert_contains "an expect(unsafe_code) in the unlisted root crate fails" "$out" "src/lib.rs:1: allows unsafe_code, but [workspace.metadata.style] allow-unsafe in Cargo.toml does not list the crate at '.'"
    rm -r "$rust/crates"
    printf 'pub fn noop() {}\n' >"$rust/src/lib.rs"

    lua="$TMP/lua"
    mkdir -p "$lua/src"
    cp "$STYLE/lua/lint.sh" "$lua/lint.sh"
    printf 'local M = {}\n\nreturn M\n' >"$lua/src/mod.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_eq "the lua set passes a clean project" "$?" "0"

    printf 'local list = items\n    :filter(live)\n    :map(name)\n-- Hand the names back\nreturn list\n' >"$lua/src/chain.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_contains "a lua comment after the end of a method chain fails" "$out" "src/chain.lua:4: full-line comment directly after code"
    printf 'local list = items\n    :filter(live)\n    :map(name)\n\n-- Hand the names back\nreturn list\n' >"$lua/src/chain.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_not_contains "a blank line after a lua method chain passes" "$out" "src/chain.lua"
    printf 'local list = items\n    :filter(live)\n    -- Keep the names\n    :map(name)\nreturn list\n' >"$lua/src/chain.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_not_contains "a comment inside a lua method chain still passes" "$out" "src/chain.lua"
    rm "$lua/src/chain.lua"

    printf 'local a = 1\n-- One\n-- Two\n-- Three\nlocal b = 2\n' >"$lua/src/runs.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_contains "three consecutive lua comment lines fail" "$out" "src/runs.lua:2: 3 consecutive comment lines"
    printf 'local a = 1\n\n-- One\n-- Two\nlocal b = 2\n\n--- Doc one\n--- Doc two\n--- Doc three\nlocal c = 3\n' >"$lua/src/runs.lua"
    out="$(style_lint "$lua" "$full_path")"
    assert_not_contains "two lua comment lines and a doc comment run pass" "$out" "src/runs.lua"
    rm "$lua/src/runs.lua"

    printf '#!/usr/bin/env bash\ncase b in\na)\n    echo a\n    ;;\n# The b arm\nb)\n    echo b\n    ;;\nesac\n' >"$lua/arms.sh"
    out="$(style_lint "$lua" "$full_path")"
    assert_not_contains "the lua set passes a shell comment heading a case arm" "$out" "arms.sh"
    printf '#!/usr/bin/env bash\nif true; then\n    echo a\n# Then b\nfi\n' >"$lua/arms.sh"
    out="$(style_lint "$lua" "$full_path")"
    assert_contains "the lua set fails a shell comment after deeper code" "$out" "arms.sh:4: full-line comment directly after code"
    rm "$lua/arms.sh"

    out="$(style_lint "$lua" "$bare_path")"
    assert_contains "the lua warning names the check a missing tool skips" "$out" "WARNING: stylua not found, skipping the stylua check"
    out="$(style_lint "$lua" "$bare_path" CI=1)"
    assert_contains "a missing lua tool fails under CI" "$out" "stylua not found, so the stylua check cannot run"
    assert_contains "the lua CI failure lists each skipped check" "$out" "FAILED: stylua selene ast-grep"
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall lint tests passed\n'
