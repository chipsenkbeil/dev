#!/usr/bin/env bash
# Pure-bash tests for the `dev` dispatcher. Each case builds a throwaway repo in a
# temp dir and puts logging stubs for the build tools first on PATH.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
export DOTFILES="$REPO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export STUB_LOG="$TMP/stub.log"
mkdir -p "$STUBS"
for tool in cargo love godot npm make stylua ast-grep; do
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n' "$tool" >"$STUBS/$tool"
    chmod +x "$STUBS/$tool"
done

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

# project <name>: create an empty project directory and print its path.
project() {
    mkdir -p "$TMP/$1"
    (cd "$TMP/$1" && pwd -P)
}

# run_dev <dir> <args...>: run dev inside a project with the stubs first on PATH.
run_dev() {
    local dir="$1"
    shift
    : >"$STUB_LOG"
    (cd "$dir" && PATH="$STUBS:$PATH" "$DEV" "$@")
}

log() {
    cat "$STUB_LOG"
}

# Detection per type
rust="$(project rust)"
touch "$rust/Cargo.toml"
run_dev "$rust" lint >/dev/null
assert_contains "rust lint runs rustfmt check" "$(log)" "cargo +nightly fmt --check"
assert_contains "rust lint runs clippy" "$(log)" "cargo clippy --all-targets --all-features -- -D warnings"
assert_not_contains "rust lint skips ast-grep without sgconfig.yml" "$(log)" "ast-grep"
touch "$rust/sgconfig.yml"
run_dev "$rust" lint >/dev/null
assert_contains "rust lint runs ast-grep with sgconfig.yml" "$(log)" "ast-grep scan"
run_dev "$rust" test --lib >/dev/null
assert_contains "rust test runs nextest with args" "$(log)" "cargo nextest run --all-features --lib"
assert_contains "rust test runs doctests" "$(log)" "cargo test --doc --all-features"
run_dev "$rust" run a b >/dev/null
assert_contains "rust run passes args after --" "$(log)" "cargo run -- a b"
run_dev "$rust" build >/dev/null
assert_contains "rust build is release" "$(log)" "cargo build --release"

love="$(project love)"
touch "$love/main.lua" "$love/conf.lua"
printf 'test:\n\ttrue\n' >"$love/Makefile"
run_dev "$love" run >/dev/null
assert_contains "love2d run" "$(log)" "love $love"
run_dev "$love" test >/dev/null
assert_contains "love2d test uses the Makefile target" "$(log)" "make -C $love test"
out="$(run_dev "$love" lint 2>&1)"
assert_contains "love2d lint without a target explains" "$out" "no built-in lint for love2d"

godot="$(project godot)"
touch "$godot/project.godot"
run_dev "$godot" run >/dev/null
assert_contains "godot run" "$(log)" "godot --path $godot"

node="$(project node)"
printf '{"scripts":{"test":"echo hi"}}\n' >"$node/package.json"
run_dev "$node" test >/dev/null
assert_contains "node test runs the npm script" "$(log)" "npm --prefix $node run test"
out="$(run_dev "$node" lint 2>&1)"
assert_contains "node without the script explains" "$out" "no built-in lint for node"

mk="$(project make)"
printf 'build:\n\ttrue\n' >"$mk/Makefile"
run_dev "$mk" build >/dev/null
assert_contains "make build uses the target" "$(log)" "make -C $mk build"

none="$(project none)"
out="$(run_dev "$none" lint 2>&1)"
assert_eq "undetected project exits 1" "$?" "1"
assert_contains "undetected project explains" "$out" "no built-in lint for undetected"

# A local override wins over the built-in
mkdir -p "$rust/.dev"
printf '#!/usr/bin/env bash\necho "override $*"\n' >"$rust/.dev/lint.sh"
chmod +x "$rust/.dev/lint.sh"
out="$(run_dev "$rust" lint --flag)"
assert_eq "override runs with args" "$out" "override --flag"
assert_eq "override skips the built-in" "$(log)" ""

printf '#!/usr/bin/env bash\necho "sync override $*"\n' >"$rust/.dev/sync.sh"
chmod +x "$rust/.dev/sync.sh"
out="$(run_dev "$rust" sync SYNC_DST=host)"
assert_eq "local sync.sh wins over the template sync" "$out" "sync override SYNC_DST=host"
rm "$rust/.dev/sync.sh"

# Usage
run_dev "$rust" bogus >/dev/null 2>&1
assert_eq "unknown verb exits 2" "$?" "2"
out="$(run_dev "$rust")"
assert_eq "no verb exits 0" "$?" "0"
assert_contains "usage marks the override" "$out" "lint      (local override)"

# A local-only verb runs, and the usage lists it
printf '#!/usr/bin/env bash\necho "installed $*"\n' >"$rust/.dev/install.sh"
chmod +x "$rust/.dev/install.sh"
out="$(run_dev "$rust" install --now)"
assert_eq "local-only verb runs its script" "$out" "installed --now"
out="$(run_dev "$rust")"
assert_contains "usage lists local verbs" "$out" "local verbs:
  install"
run_dev "$rust" nothere >/dev/null 2>&1
assert_eq "verb with no script and no built-in exits 2" "$?" "2"

# Missing tool
if ! PATH=/usr/bin:/bin command -v cargo >/dev/null 2>&1; then
    touch "$rust/.dev/skip"
    rm "$rust/.dev/lint.sh"
    out="$(cd "$rust" && env PATH=/usr/bin:/bin bash "$DEV" lint 2>&1)"
    assert_eq "missing cargo exits 1" "$?" "1"
    assert_contains "missing cargo prints one WARNING" "$out" "WARNING: cargo not found. Install with:"
fi

# sync --check
sync="$(project sync)"
touch "$sync/Cargo.toml"
tpl="$REPO/dotfiles/claude/.claude/skills/style/lint/rust"
cp "$tpl/rustfmt.toml" "$sync/rustfmt.toml"
printf '# drifted\n' >"$sync/clippy.toml"
out="$(run_dev "$sync" sync --check)"
assert_eq "sync --check exits 1 on drift" "$?" "1"
assert_contains "sync --check reports a drifted file" "$out" "differs: clippy.toml"
assert_contains "sync --check reports a missing file" "$out" "missing: deny.toml"
assert_not_contains "sync --check ignores a matching file" "$out" "rustfmt.toml"
out="$(run_dev "$sync" sync 2>&1 </dev/null)"
assert_contains "sync refuses without a terminal" "$out" "needs a terminal"

# init
if command -v jj >/dev/null 2>&1; then
    init="$(project init)"
    printf '[package]\nname = "init"\nversion = "0.1.0"\nedition = "2024"\n' >"$init/Cargo.toml"
    git -C "$init" init -q

    out="$(run_dev "$init" init --dry-run --no-gerrit --public)"
    assert_contains "init --dry-run plans the lint script" "$out" "would create: .dev/lint.sh"
    assert_contains "init --dry-run plans the pipeline" "$out" "would create: .ci/pipeline.lua"
    assert_contains "init --dry-run plans the workflow" "$out" "would create: .github/workflows/ci.yml"
    assert_contains "init --dry-run prints the origin command" "$out" "jj git remote add origin hub:init"
    assert_eq "init --dry-run writes nothing" "$(find "$init" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2"

    out="$(run_dev "$init" init --no-gerrit --public)"
    assert_contains "init creates the lint script" "$out" "created: .dev/lint.sh"
    assert_eq "init makes the lint script executable" "$([ -x "$init/.dev/lint.sh" ] && echo yes)" "yes"
    assert_contains "init points the lint script cd at the root" "$(cat "$init/.dev/lint.sh")" 'BASH_SOURCE[0]}")/.."'
    assert_contains "init points ast-grep at the root sgconfig.yml" "$(cat "$init/.dev/lint.sh")" "--config sgconfig.yml"
    assert_contains "init relocates the ast-grep rules" "$(cat "$init/sgconfig.yml")" ".dev/ast-grep/rules"
    assert_contains "init pins the stable channel" "$(cat "$init/rust-toolchain.toml")" "channel = \"$(rustc +stable --version | cut -d' ' -f2)\""
    assert_contains "init appends the workspace lints" "$(cat "$init/Cargo.toml")" "[workspace.lints.rust]"
    assert_contains "init writes the pipeline" "$(cat "$init/.ci/pipeline.lua")" ".dev/lint.sh"
    assert_contains "init writes the workflow for windows" "$(cat "$init/.github/workflows/ci.yml")" "windows-latest"
    assert_eq "init creates .jj" "$([ -d "$init/.jj" ] && echo yes)" "yes"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check is clean after init" "$out" "up to date"

    before="$(cat "$init/Cargo.toml")"
    out="$(run_dev "$init" init --no-gerrit --public)"
    assert_not_contains "init rerun creates nothing" "$out" "created:"
    assert_contains "init rerun skips existing files" "$out" "skipped: .dev/lint.sh exists"
    assert_eq "init rerun leaves Cargo.toml alone" "$(cat "$init/Cargo.toml")" "$before"
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall dev tests passed\n'
