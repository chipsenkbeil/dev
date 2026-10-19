#!/usr/bin/env bash
# Pure-bash tests for the `dev` dispatcher. Each case builds a throwaway repo in a
# temp dir and puts logging stubs for the build tools first on PATH.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
export DOTFILES="$REPO"
unset VERBOSE

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export STUB_LOG="$TMP/stub.log"
mkdir -p "$STUBS"
for tool in cargo love godot npm make stylua ast-grep; do
    # shellcheck disable=SC2016  # $* and $STUB_LOG expand in the generated stub
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

plain="$(project plain)"
mkdir -p "$plain/src"
printf 'local M = {}\n\nreturn M\n' >"$plain/src/mod.lua"
run_dev "$plain" fmt >/dev/null
assert_contains "lua fmt runs stylua" "$(log)" "stylua $plain"
out="$(run_dev "$plain" lint 2>&1)"
assert_contains "lua lint without a target explains" "$out" "no built-in lint for lua"
printf 'test:\n\ttrue\n' >"$plain/Makefile"
run_dev "$plain" test >/dev/null
assert_contains "lua test uses the Makefile target" "$(log)" "make -C $plain test"
assert_contains "lua wins over make" "$(run_dev "$plain")" "project lua"
rm "$plain/Makefile"

none="$(project none)"
mkdir -p "$none/.ci"
printf 'return {}\n' >"$none/.ci/pipeline.lua"
out="$(run_dev "$none" lint 2>&1)"
assert_eq "undetected project exits 1" "$?" "1"
assert_contains "undetected project explains" "$out" "no built-in lint for undetected"
assert_contains "a .lua file in a dot directory does not make a lua project" "$(run_dev "$none")" "project none"

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
assert_eq "an overridden sync without a flags line offers no flags" "$(run_dev "$rust" __flags sync | grep -c '^--check$')" "0"
rm "$rust/.dev/sync.sh"

printf '#!/usr/bin/env bash\necho "init override $*"\n' >"$rust/.dev/init.sh"
chmod +x "$rust/.dev/init.sh"
out="$(run_dev "$rust" init --dry-run)"
assert_eq "local init.sh wins over the built-in init" "$out" "init override --dry-run"
rm "$rust/.dev/init.sh"

# Global verbosity flags
vp="$(project verbose)"
mkdir -p "$vp/.dev"

# shellcheck disable=SC2016  # $* and ${VERBOSE} expand in the generated script
printf '#!/usr/bin/env bash\necho "args=$* verbose=${VERBOSE:-unset}"\nbash inner.sh\n' >"$vp/.dev/lint.sh"
chmod +x "$vp/.dev/lint.sh"
printf 'true\n' >"$vp/inner.sh"
assert_eq "-v before the verb sets VERBOSE=1" "$(run_dev "$vp" -v lint 2>/dev/null)" "args= verbose=1"
assert_eq "-v after the verb sets VERBOSE=1" "$(run_dev "$vp" lint -v 2>/dev/null)" "args= verbose=1"
assert_eq "--verbose sets VERBOSE=1" "$(run_dev "$vp" lint --verbose 2>/dev/null)" "args= verbose=1"
assert_eq "lint --flag -v passes only --flag" "$(run_dev "$vp" lint --flag -v 2>/dev/null)" "args=--flag verbose=1"
assert_eq "-- passes -v through untouched" "$(run_dev "$vp" lint -- -v 2>/dev/null)" "args=-v verbose=unset"
assert_eq "-vv sets VERBOSE=2" "$(run_dev "$vp" -vv lint 2>/dev/null)" "args= verbose=2"
assert_eq "-v -v equals -vv" "$(run_dev "$vp" -v lint -v 2>/dev/null)" "args= verbose=2"
assert_eq "-vvv clamps to 2" "$(run_dev "$vp" -vvv lint 2>/dev/null)" "args= verbose=2"
assert_eq "VERBOSE=yes from the environment is level 1" "$(VERBOSE=yes run_dev "$vp" lint 2>/dev/null)" "args= verbose=1"
assert_eq "VERBOSE=0 from the environment is not exported" "$(VERBOSE=0 run_dev "$vp" lint 2>/dev/null)" "args= verbose=unset"
assert_eq "-v wins over VERBOSE from the environment" "$(VERBOSE=2 run_dev "$vp" -v lint 2>/dev/null)" "args= verbose=1"
err="$(run_dev "$vp" -vv lint 2>&1 >/dev/null)"
assert_contains "-vv traces the override script" "$err" "+ lint.sh:2: echo"
assert_contains "-vv traces a bash script the override runs through BASH_ENV" "$err" "+ inner.sh:1: true"
printf '#!/usr/bin/env bash\nset -euo pipefail\nbash child.sh\n' >"$vp/.dev/chain.sh"
chmod +x "$vp/.dev/chain.sh"
printf 'set -euo pipefail\nbash grandchild.sh\n' >"$vp/child.sh"
printf 'false\necho survived\n' >"$vp/grandchild.sh"
assert_eq "-vv leaks no errexit into a grandchild script" "$(run_dev "$vp" -vv chain 2>/dev/null)" "survived"
mkdir -p "$TMP/bare"
cp "$DEV" "$TMP/bare/dev"
out="$(cd "$vp" && "$TMP/bare/dev" -vv lint 2>"$TMP/err")"
assert_eq "-vv without the trace file falls back to level 1" "$out" "args= verbose=1"
assert_contains "-vv without the trace file says so" "$(cat "$TMP/err")" "trace file"
out="$(VERBOSE=2 run_dev "$vp" lint 2>"$TMP/err")"
assert_eq "VERBOSE=2 from the environment equals -vv" "$out" "args= verbose=2"
assert_contains "VERBOSE=2 from the environment traces" "$(cat "$TMP/err")" "+ lint.sh:2: echo"
assert_eq "-v prints the override command on stderr" "$(run_dev "$vp" -v lint --flag 2>&1 >/dev/null)" "+ .dev/lint.sh --flag"
assert_eq "no flag prints nothing on stderr" "$(run_dev "$vp" lint --flag 2>&1 >/dev/null)" ""
assert_contains "-v prints the built-in command on stderr" "$(run_dev "$rust" -v build 2>&1 >/dev/null)" "+ cargo build --release"
assert_contains "-vv exports the trace to the built-in's bash children" "$(run_dev "$rust" -vv build 2>&1 >/dev/null)" "+ cargo:2: echo"
assert_contains "__flags lint includes --verbose" "$(run_dev "$vp" __flags lint)" "--verbose"
assert_contains "help lists the global flags" "$(run_dev "$vp" help)" "global flags"
assert_eq "verbose_printf prints for VERBOSE=1" "$(
    # shellcheck source=../../scripts/helpers.sh
    source "$REPO/scripts/helpers.sh"
    VERBOSE=1 verbose_printf 'seen'
)" "seen"
assert_eq "verbose_printf prints for VERBOSE=yes" "$(
    # shellcheck source=../../scripts/helpers.sh
    source "$REPO/scripts/helpers.sh"
    VERBOSE=yes verbose_printf 'seen'
)" "seen"

# Usage
run_dev "$rust" bogus >/dev/null 2>&1
assert_eq "unknown verb exits 2" "$?" "2"
out="$(run_dev "$rust" help nosuch 2>&1)"
assert_eq "help of an unknown verb exits 2" "$?" "2"
assert_contains "help names the unknown verb" "$out" "dev help: unknown verb nosuch"

BOUNDED_TIMEOUT_SECS=10
bounded_dev() {
    local dir=$1 pid _
    shift
    (cd "$dir" && PATH="$STUBS:$PATH" exec "$DEV" "$@") >"$TMP/bounded.out" 2>&1 &
    pid=$!
    for _ in $(seq "$BOUNDED_TIMEOUT_SECS"); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        wait "$pid" 2>/dev/null
        BOUNDED_RC=hung
    else
        wait "$pid"
        BOUNDED_RC=$?
    fi
    BOUNDED_OUT=$(cat "$TMP/bounded.out")
}
bounded_dev "$rust" init --type
assert_eq "init --type with no value exits 2" "$BOUNDED_RC" "2"
assert_contains "init names the --type with no value" "$BOUNDED_OUT" "dev init: --type needs a value"
bounded_dev "$rust" init --name
assert_eq "init --name with no value exits 2" "$BOUNDED_RC" "2"
assert_contains "init names the --name with no value" "$BOUNDED_OUT" "dev init: --name needs a value"
out="$(run_dev "$rust" init --bogus 2>&1)"
assert_eq "init with an unknown flag exits 2" "$?" "2"
assert_contains "init names the unknown flag" "$out" "dev init: unknown flag --bogus"
out="$(run_dev "$rust" init --type cobol 2>&1)"
assert_eq "init with an unknown type exits 2" "$?" "2"
out="$(run_dev "$rust")"
assert_eq "no verb exits 0" "$?" "0"
assert_contains "bare dev names the project type" "$out" "project rust"
assert_contains "help marks the override" "$out" "(override)"
assert_not_contains "help hides the hidden verbs" "$out" "__verbs"

# A local-only verb runs, and the listings carry it with its description
printf '#!/usr/bin/env bash\n# Install the thing.\n# flags: --now --later\necho "installed $*"\n' >"$rust/.dev/install.sh"
chmod +x "$rust/.dev/install.sh"
out="$(run_dev "$rust" install --now)"
assert_eq "local-only verb runs its script" "$out" "installed --now"
out="$(run_dev "$rust" __verbs)"
assert_contains "__verbs lists a local verb with its description" "$out" "install	local	Install the thing."
assert_contains "__verbs lists a built-in" "$out" "fmt	builtin	"
assert_contains "__verbs marks an override" "$out" "lint	override	"
assert_not_contains "__verbs hides hidden verbs" "$out" "__"
out="$(run_dev "$rust" help)"
assert_contains "help lists local verbs" "$out" "local verbs"
assert_contains "help shows a local verb description" "$out" "Install the thing."
out="$(run_dev "$rust" help init)"
for flag in --type --public --name --dry-run --no-gerrit; do
    assert_contains "help init lists $flag" "$out" "$flag"
done
out="$(run_dev "$rust" __flags install)"
assert_eq "__flags reads the flags line of a script and adds the global flags" "$out" "--now
--later
-v
--verbose
-vv"
out="$(run_dev "$rust" __flags sync)"
assert_eq "__flags sync" "$out" "--check
--yes
-y
-v
--verbose
-vv"
out="$(run_dev "$rust" help sync)"
assert_contains "help sync lists --yes" "$out" "--yes"
assert_contains "help <verb> mentions the global flags" "$out" "-v and -vv work anywhere"
out="$(run_dev "$rust" help install)"
assert_contains "help <verb> shows the script header" "$out" ".dev/install.sh header"
out="$(run_dev "$rust" help build)"
assert_contains "help <verb> shows the built-in command" "$out" "cargo build --release"
out="$(run_dev "$rust" help)"
case "$out" in
*$'\033'*) assert_eq "help is plain when piped" "color escapes" "none" ;;
*) assert_eq "help is plain when piped" "none" "none" ;;
esac
printf '#!/usr/bin/env bash\necho "custom help $*"\n' >"$rust/.dev/help.sh"
chmod +x "$rust/.dev/help.sh"
assert_eq "help.sh replaces dev help" "$(run_dev "$rust" help x)" "custom help x"
assert_eq "help.sh replaces bare dev" "$(run_dev "$rust")" "custom help "
rm "$rust/.dev/help.sh"
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
assert_contains "the sync refusal names --yes" "$out" "pass --yes to apply without asking"
run_dev "$sync" sync --yes --check >/dev/null 2>&1
assert_eq "sync --yes --check exits 2" "$?" "2"
out="$(run_dev "$sync" sync --bogus 2>&1)"
assert_eq "sync with an unknown flag exits 2" "$?" "2"
assert_contains "sync names the unknown flag" "$out" "dev sync: unknown flag --bogus"
if [ -x /usr/bin/yq ] || [ -x /bin/yq ]; then
    printf 'skip - rust sync without yq (yq is in /usr/bin or /bin)\n'
else
    out="$(cd "$sync" && env PATH="$STUBS:/usr/bin:/bin" bash "$DEV" sync --check 2>&1)"
    assert_eq "rust sync without yq exits 1" "$?" "1"
    assert_contains "rust sync without yq names it" "$out" "yq not found"
fi

# init
if command -v jj >/dev/null 2>&1; then
    init="$(project init)"
    printf '[package]\nname = "init"\nversion = "0.1.0"\nedition = "2024"\n' >"$init/Cargo.toml"
    git -C "$init" init -q

    out="$(run_dev "$init" init --dry-run --no-gerrit --public)"
    assert_contains "init --dry-run plans the lint script" "$out" "would create: .dev/lint.sh"
    assert_contains "init --dry-run plans the pipeline" "$out" "would create: .ci/pipeline.lua"
    assert_contains "init --dry-run plans the workflow" "$out" "would create: .github/workflows/ci.yml"
    assert_contains "init --dry-run plans the style guide" "$out" "would create: docs/STYLE.md"
    assert_contains "init --dry-run prints the origin command" "$out" "jj git remote add origin hub:init"
    assert_eq "init --dry-run writes nothing" "$(find "$init" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2"
    out="$(run_dev "$init" init --dry-run -v --no-gerrit --public 2>/dev/null)"
    assert_contains "init --dry-run -v still dry-runs" "$out" "would create: .dev/lint.sh"
    assert_eq "init --dry-run -v writes nothing" "$(find "$init" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2"

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
    assert_contains "init seeds docs/STYLE.md from the rust guide" "$out" "created: docs/STYLE.md"
    assert_contains "init copies the rust guide" "$(cat "$init/docs/STYLE.md")" "# Rust style"
    assert_contains "init ends docs/STYLE.md with a project section" "$(tail -n 3 "$init/docs/STYLE.md")" "Rules that apply only to this project"
    assert_eq "init creates .jj" "$([ -d "$init/.jj" ] && echo yes)" "yes"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check is clean after init" "$out" "up to date"
    printf '\ncheck "project extra" true\n' >>"$init/.dev/lint.sh"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check keeps the project checks below the lint.sh marker" "$out" "up to date"
    printf '# drifted above the marker\n' | cat - "$init/.dev/lint.sh" >"$init/.dev/lint.sh.new"
    mv "$init/.dev/lint.sh.new" "$init/.dev/lint.sh"
    out="$(run_dev "$init" sync --check)"
    assert_contains "sync --check still sees drift above the marker" "$out" "differs: .dev/lint.sh"
    tail -n +2 "$init/.dev/lint.sh" >"$init/.dev/lint.sh.new"
    mv "$init/.dev/lint.sh.new" "$init/.dev/lint.sh"

    cp "$init/docs/STYLE.md" "$TMP/STYLE.md.orig"
    printf 'Name every lock after what it guards.\n' >>"$init/docs/STYLE.md"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check keeps the project rules in docs/STYLE.md" "$out" "up to date"
    printf '# drifted guide\n' | cat - "$init/docs/STYLE.md" >"$init/docs/STYLE.md.new"
    mv "$init/docs/STYLE.md.new" "$init/docs/STYLE.md"
    out="$(run_dev "$init" sync --check)"
    assert_contains "sync --check reports a drifted guide in docs/STYLE.md" "$out" 'differs: docs/STYLE.md above "## This project"'
    printf '# Our own style\n\nA ratified project guide.\n' >"$init/docs/STYLE.md"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check ignores a docs/STYLE.md the project wrote itself" "$out" "up to date"
    cp "$TMP/STYLE.md.orig" "$init/docs/STYLE.md"

    before="$(cat "$init/Cargo.toml")"
    out="$(run_dev "$init" init --no-gerrit --public)"
    assert_not_contains "init rerun creates nothing" "$out" "created:"
    assert_contains "init rerun skips an existing docs/STYLE.md" "$out" "skipped: docs/STYLE.md exists"
    assert_contains "init rerun skips existing files" "$out" "skipped: .dev/lint.sh exists"
    assert_eq "init rerun leaves Cargo.toml alone" "$(cat "$init/Cargo.toml")" "$before"

    # love2d gets the Lua lint set with the love std
    game="$(project game)"
    mkdir -p "$game/src"
    printf 'function love.load() end\n' >"$game/main.lua"
    printf 'function love.conf(t)\n    t.window.title = "game"\nend\n' >"$game/conf.lua"
    printf 'local M = {}\n\nreturn M\n' >"$game/src/mod.lua"
    git -C "$game" init -q
    out="$(run_dev "$game" init --dry-run --no-gerrit)"
    assert_contains "love2d init --dry-run plans the lint script" "$out" "would create: .dev/lint.sh"
    assert_contains "love2d init --dry-run plans selene.toml" "$out" "would create: selene.toml"
    assert_eq "love2d init --dry-run writes nothing" "$(find "$game" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "4"
    out="$(run_dev "$game" init --no-gerrit)"
    for f in .dev/lint.sh .dev/fmt.sh selene.toml stylua.toml luajit.yml love.yml sgconfig.yml .dev/ast-grep/rules/comment-period.yml; do
        assert_contains "love2d init creates $f" "$out" "created: $f"
        assert_eq "love2d init writes $f" "$([ -f "$game/$f" ] && echo yes)" "yes"
    done
    assert_not_contains "love2d init writes no pending README" "$out" ".dev/README.md"
    assert_eq "love2d init makes the lint script executable" "$([ -x "$game/.dev/lint.sh" ] && echo yes)" "yes"
    assert_contains "love2d init points the lint script cd at the root" "$(cat "$game/.dev/lint.sh")" 'BASH_SOURCE[0]}")/.."'
    assert_not_contains "love2d init repoints every ast-grep config path" "$(cat "$game/.dev/lint.sh")" "ast-grep/sgconfig.yml"
    assert_contains "love2d init relocates the ast-grep rules" "$(cat "$game/sgconfig.yml")" ".dev/ast-grep/rules"
    assert_contains "love2d init relocates the ast-grep rule tests" "$(cat "$game/sgconfig.yml")" ".dev/ast-grep/rule-test"
    assert_contains "love2d init picks the love std" "$(cat "$game/selene.toml")" 'std = "love"'
    assert_contains "love2d init seeds docs/STYLE.md from the lua guide" "$(cat "$game/docs/STYLE.md")" "# Lua style"
    out="$(run_dev "$game" sync --check)"
    assert_eq "love2d sync --check is clean after init" "$out" "up to date"
    printf 'column_width = 80\n' >>"$game/stylua.toml"
    out="$(run_dev "$game" sync --check)"
    assert_eq "love2d sync --check exits 1 on a drifted stylua.toml" "$?" "1"
    assert_contains "love2d sync --check reports the drifted stylua.toml" "$out" "differs: stylua.toml"
    assert_not_contains "love2d sync --check ignores a matching file" "$out" "selene.toml"
    cp "$REPO/dotfiles/claude/.claude/skills/style/lint/lua/stylua.toml" "$game/stylua.toml"
    out="$(run_dev "$game" init --no-gerrit)"
    assert_not_contains "love2d init rerun creates nothing" "$out" "created:"
    assert_contains "love2d init rerun skips an existing lint script" "$out" "skipped: .dev/lint.sh exists"

    if command -v stylua >/dev/null 2>&1 && command -v selene >/dev/null 2>&1 && command -v ast-grep >/dev/null 2>&1; then
        out="$(cd "$game" && .dev/lint.sh 2>&1)"
        assert_eq "installed lint.sh passes on a clean love2d project" "$?" "0"
        printf -- '-- Advance generation to invalidate handles.\nlocal M = {}\n\nreturn M\n' >"$game/src/mod.lua"
        out="$(cd "$game" && .dev/lint.sh 2>&1)"
        assert_eq "installed lint.sh exits 1 on a violation" "$?" "1"
        assert_contains "installed lint.sh names the ast-grep rule" "$out" "error[comment-period]"
        assert_contains "installed lint.sh lists the failed check" "$out" "FAILED: ast-grep scan"
    else
        printf 'skip - installed lua lint.sh on a love2d project (needs stylua, selene and ast-grep)\n'
    fi

    # Plain lua gets the same set with the luajit std and no love.yml
    lib="$(project lib)"
    mkdir -p "$lib/src"
    printf 'local M = {}\n\nreturn M\n' >"$lib/src/mod.lua"
    git -C "$lib" init -q
    out="$(run_dev "$lib" init --no-gerrit)"
    assert_contains "lua init reports the type" "$out" "type lua"
    assert_contains "lua init creates the lint script" "$out" "created: .dev/lint.sh"
    assert_contains "lua init picks the luajit std" "$(cat "$lib/selene.toml")" 'std = "luajit"'
    assert_eq "lua init ships no love.yml" "$([ -e "$lib/love.yml" ] || echo absent)" "absent"
    assert_eq "lua init ships luajit.yml" "$([ -f "$lib/luajit.yml" ] && echo yes)" "yes"
    out="$(run_dev "$lib" sync --check)"
    assert_eq "lua sync --check is clean after init" "$out" "up to date"
else
    printf 'skip - rust, love2d and lua init (needs jj)\n'
fi

# Library register: the doc lints go to crates without publish = false
reg="$(project register)"
mkdir -p "$reg/crates/lib/src" "$reg/crates/app/src" "$reg/crates/bin/src"
printf '[workspace]\nmembers = ["crates/*"]\nresolver = "3"\n' >"$reg/Cargo.toml"
printf '[package]\nname = "lib"\nversion = "0.1.0"\nedition = "2024"\n' >"$reg/crates/lib/Cargo.toml"
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2024"\npublish = false\n' >"$reg/crates/app/Cargo.toml"
printf '[package]\nname = "bin"\nversion = "0.1.0"\nedition = "2024"\n' >"$reg/crates/bin/Cargo.toml"
printf '//! Lib docs.\n\npub fn f() {}\n' >"$reg/crates/lib/src/lib.rs"
printf 'pub fn g() {}\n' >"$reg/crates/app/src/lib.rs"
printf 'fn main() {}\n' >"$reg/crates/bin/src/main.rs"
attr='#![deny(clippy::missing_errors_doc, clippy::missing_panics_doc)]'
out="$(run_dev "$reg" init --dry-run --no-gerrit)"
assert_contains "init --dry-run plans the attribute" "$out" "would create: crates/lib/src/lib.rs library-register attribute"
assert_not_contains "init --dry-run leaves lib.rs alone" "$(cat "$reg/crates/lib/src/lib.rs")" "missing_errors_doc"
out="$(run_dev "$reg" init --no-gerrit)"
assert_contains "init adds the attribute to the library crate" "$out" "created: crates/lib/src/lib.rs library-register attribute"
assert_contains "init writes the attribute line" "$(cat "$reg/crates/lib/src/lib.rs")" "$attr"
assert_eq "init puts the attribute after the //! block" "$(sed -n 1p "$reg/crates/lib/src/lib.rs")" "//! Lib docs."
assert_eq "init leaves a blank line after the //! block" "$(sed -n 2p "$reg/crates/lib/src/lib.rs")" ""
assert_contains "init lists the publish = false crate" "$out" "application register, no doc lints: crates/app"
assert_not_contains "init skips the publish = false crate" "$(cat "$reg/crates/app/src/lib.rs")" "missing_errors_doc"
assert_eq "init leaves the binary crate alone" "$(cat "$reg/crates/bin/src/main.rs")" "fn main() {}"
assert_not_contains "workspace lints omit the library-only lints" "$(cat "$reg/Cargo.toml")" 'missing_errors_doc = '
assert_contains "workspace lints keep missing_safety_doc" "$(cat "$reg/Cargo.toml")" 'missing_safety_doc = "deny"'
out="$(run_dev "$reg" init --no-gerrit)"
assert_contains "init rerun skips the attribute" "$out" "skipped: crates/lib/src/lib.rs has the library-register attribute"
assert_not_contains "init rerun creates no attribute" "$out" "library-register attribute
created"
assert_eq "init rerun keeps one attribute" "$(grep -c 'missing_errors_doc' "$reg/crates/lib/src/lib.rs")" "1"
out="$(run_dev "$reg" sync --check)"
assert_eq "sync --check is clean after init in a workspace" "$out" "up to date"

sd 'missing_safety_doc = "deny"' 'missing_safety_doc = "warn"' "$reg/Cargo.toml"
sd -F "$attr" '' "$reg/crates/lib/src/lib.rs"
out="$(run_dev "$reg" sync --check)"
assert_eq "sync --check exits 1 on a modified lints block" "$?" "1"
assert_contains "sync --check reports the lints block" "$out" "differs: [workspace.lints] block in Cargo.toml"
assert_contains "sync --check reports the removed attribute" "$out" "missing: library-register attribute in crates/lib/src/lib.rs"
assert_not_contains "sync --check ignores the application crate" "$out" "crates/app"
printf '\ncheck "project extra" true\n' >>"$reg/.dev/lint.sh"
printf '# drifted guide\n' | cat - "$reg/docs/STYLE.md" >"$reg/docs/STYLE.md.new"
mv "$reg/docs/STYLE.md.new" "$reg/docs/STYLE.md"
out="$(run_dev "$reg" sync --yes </dev/null 2>&1)"
assert_eq "sync --yes without a terminal exits 0" "$?" "0"
assert_contains "sync --yes prints the diffs it applies" "$out" "would insert into crates/lib/src/lib.rs"
assert_contains "sync --yes applies without asking" "$out" "synced"
out="$(run_dev "$reg" sync --check)"
assert_eq "sync --yes restores the lints block, the attribute and the guide" "$out" "up to date"
assert_contains "sync --yes keeps the project checks below the lint.sh marker" "$(cat "$reg/.dev/lint.sh")" 'check "project extra" true'
if command -v script >/dev/null 2>&1; then
    sd 'missing_safety_doc = "deny"' 'missing_safety_doc = "warn"' "$reg/Cargo.toml"
    (cd "$reg" && script -q /dev/null env PATH="$STUBS:$PATH" "$DEV" sync < <(
        printf 'y\n'
        sleep 30
    ) >"$TMP/sync.out" 2>&1) || true
    assert_contains "sync asks on a terminal" "$(cat "$TMP/sync.out")" "[y/N]"
    out="$(run_dev "$reg" sync --check)"
    assert_eq "sync on a terminal applies a y answer" "$out" "up to date"
else
    printf 'skip - sync on a terminal (needs script)\n'
fi

wtmain="$(project wtmain)"
git -C "$wtmain" init -q
git -C "$wtmain" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$wtmain" worktree add -q "$TMP/wt" 2>/dev/null
printf '[package]\nname = "wt"\nversion = "0.1.0"\nedition = "2024"\n' >"$TMP/wt/Cargo.toml"
out="$(run_dev "$TMP/wt" init --dry-run --no-gerrit)"
assert_contains "init skips jj in a git worktree" "$out" "this is a git worktree"
assert_not_contains "init plans no jj colocate in a git worktree" "$out" "jj git init --colocate"

if ! PATH=/usr/bin:/bin command -v jj >/dev/null 2>&1; then
    nojj="$(project nojj)"
    git -C "$nojj" init -q
    out="$(cd "$nojj" && env PATH=/usr/bin:/bin bash "$DEV" init --no-gerrit 2>&1)"
    assert_eq "init without jj exits 0" "$?" "0"
    assert_contains "init without jj skips jj and says why" "$out" "skipped: .jj (jj not installed, git only)"
    assert_contains "init without jj prints the git remote command" "$out" "run: git remote add origin hub:nojj"
    assert_eq "init without jj creates no .jj" "$([ -e "$nojj/.jj" ] || echo absent)" "absent"
else
    printf 'skip - init without jj (jj is in /usr/bin or /bin)\n'
fi

# gitc <args...>: git with a fixed identity and no signing.
gitc() {
    git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"
}

gremote="$TMP/gremote.git"
git init -q --bare -b main "$gremote"
gp="$(project gitpush)"
git -C "$gp" init -q -b main
git -C "$gp" remote add origin "$gremote"
echo a >"$gp/a"
git -C "$gp" add a
gitc -C "$gp" commit -q -m "feat: clean"
out="$(run_dev "$gp" -v push 2>&1)"
assert_eq "git push exits 0" "$?" "0"
assert_contains "git push names the remote and branch" "$out" "origin: pushed main"
assert_contains "git push -v shows the guarded command" "$out" "commit-guard push -- origin $(git -C "$gp" rev-parse HEAD):refs/heads/main"
assert_eq "git push puts the commit on the remote" "$(git -C "$gremote" rev-parse main)" "$(git -C "$gp" rev-parse HEAD)"
clean="$(git -C "$gp" rev-parse HEAD)"
git init -q --bare -b main "$TMP/gerrit.git"
git -C "$gp" remote add gerrit "$TMP/gerrit.git"
out="$(run_dev "$gp" push gerrit 2>&1)"
assert_eq "push gerrit exits 0" "$?" "0"
assert_contains "push gerrit pushes to gerrit" "$out" "gerrit: pushed main"
assert_not_contains "push gerrit leaves origin alone" "$out" "origin:"
git -C "$gp" remote remove gerrit
out="$(run_dev "$gp" push nosuch 2>&1)"
assert_eq "push to a remote the project lacks exits 2" "$?" "2"
assert_contains "push names the missing remote" "$out" "no remote nosuch"
out="$(run_dev "$gp" push --force 2>&1)"
assert_eq "push with an unknown flag exits 2" "$?" "2"
assert_contains "push names the unknown flag" "$out" "dev push: unknown flag --force"
out="$(run_dev "$gp" pull extra 2>&1)"
assert_eq "pull with an argument exits 2" "$?" "2"
assert_contains "pull names the argument" "$out" "dev pull: unknown argument extra"

echo b >"$gp/b"
git -C "$gp" add b
gitc -C "$gp" commit -q -m "fix: tagged" -m "Claude-Session: https://claude.ai/code/session_x"
out="$(run_dev "$gp" push 2>&1)"
assert_eq "git push of an attributed commit exits 1" "$?" "1"
assert_contains "git push names the guard refusal" "$out" "commit-guard: refusing to push to origin"
assert_eq "git push leaves the remote unchanged on a refusal" "$(git -C "$gremote" rev-parse main)" "$clean"
git -C "$gp" reset -q --hard "$clean"

mkdir -p "$TMP/lonely"
cp "$DEV" "$TMP/lonely/dev"
out="$(cd "$gp" && PATH="$STUBS:$PATH" "$TMP/lonely/dev" push 2>&1)"
assert_eq "git push without the guard exits 1" "$?" "1"
assert_contains "git push without the guard says so" "$out" "commit-guard is missing"

git -C "$gp" checkout -q --detach
out="$(run_dev "$gp" push 2>&1)"
assert_eq "git push on a detached HEAD exits 1" "$?" "1"
assert_contains "git push explains a detached HEAD" "$out" "HEAD is detached"
assert_contains "help push gives the detached HEAD reason" "$(run_dev "$gp" help push)" "(none: HEAD is detached"
out="$(run_dev "$gp" pull 2>&1)"
assert_eq "git pull on a detached HEAD exits 1" "$?" "1"
git -C "$gp" checkout -q main

git clone -q "$gremote" "$TMP/second"
echo c >"$TMP/second/c"
git -C "$TMP/second" add c
gitc -C "$TMP/second" commit -q -m "feat: from the second clone"
git -C "$TMP/second" push -q origin main
out="$(run_dev "$gp" pull 2>&1)"
assert_eq "git pull exits 0" "$?" "0"
assert_eq "git pull brings the second clone's commit" "$(git -C "$gp" log -1 --format=%s)" "feat: from the second clone"
echo dirty >>"$gp/a"
out="$(run_dev "$gp" pull 2>&1)"
assert_eq "git pull on a dirty tree exits 1" "$?" "1"
assert_contains "git pull explains a dirty tree" "$out" "uncommitted changes"
git -C "$gp" checkout -q -- a
assert_eq "push and pull never create .jj" "$([ -e "$gp/.jj" ] || echo absent)" "absent"
preview="$(run_dev "$gp" help push | grep 'commit-guard push' | sed 's/^ *//')"
shown="$(run_dev "$gp" -v push 2>&1 | grep '^+ ' | sed 's/^+ //')"
assert_eq "help push previews the command push runs" "$preview" "$shown"
assert_contains "help pull shows the git command" "$(run_dev "$gp" help pull)" "pull --rebase origin main"
echo dirty >>"$gp/a"
assert_contains "help pull gives the dirty tree reason" "$(run_dev "$gp" help pull)" "(none: $gp has uncommitted changes"
git -C "$gp" checkout -q -- a

if command -v jj >/dev/null 2>&1; then
    export JJ_CONFIG="$TMP/jj.toml"
    printf 'user.name = "t"\nuser.email = "t@t"\nsigning.behavior = "drop"\ngit.sign-on-push = false\n' >"$JJ_CONFIG"
    jj git clone -q "$gremote" "$TMP/jjpull" >/dev/null 2>&1 || jj git clone "$gremote" "$TMP/jjpull" >/dev/null 2>&1
    jp="$(cd "$TMP/jjpull" && pwd -P)"
    echo d >"$TMP/second/d"
    git -C "$TMP/second" add d
    gitc -C "$TMP/second" commit -q -m "feat: for the jj clone"
    git -C "$TMP/second" push -q origin main
    out="$(run_dev "$jp" -v pull 2>&1)"
    assert_eq "jj pull exits 0" "$?" "0"
    assert_contains "jj pull fetches every remote" "$out" "git fetch --all-remotes"
    assert_eq "jj pull rebases the working copy onto the fetched commit" "$(jj --no-pager -R "$jp" log --no-graph -r @- -T 'description.first_line()')" "feat: for the jj clone"
    printf 'aliases.sync = ["git", "fetch"]\n' >>"$JJ_CONFIG"
    out="$(run_dev "$jp" -v pull 2>&1)"
    assert_contains "jj pull runs the sync alias when the config has one" "$out" "-R $jp sync"
    notrunk="$(project notrunk)"
    jj git init "$notrunk" >/dev/null 2>&1
    jj --no-pager -R "$notrunk" git remote add origin "$gremote"
    help_out="$(run_dev "$notrunk" help push)"
    out="$(run_dev "$notrunk" push 2>&1)"
    assert_eq "jj push without a trunk bookmark exits 1" "$?" "1"
    assert_contains "jj push without a trunk bookmark explains" "$out" "no master or main bookmark"
    assert_contains "help push gives the same reason push dies with" "$help_out" "(none: ${out#dev: })"
    unset JJ_CONFIG
else
    printf 'skip - jj pull and jj push (needs jj)\n'
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall dev tests passed\n'
