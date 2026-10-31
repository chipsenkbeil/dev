#!/usr/bin/env bash
# Pure-bash tests for the `dev` dispatcher. Each case builds a throwaway repo in a
# temp dir and puts logging stubs for the build tools first on PATH.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
export DOTFILES="$REPO"
unset VERBOSE CI DEV_AGENT
export DEV_REMOTE=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LUABIN="$TMP/luabin"
mkdir -p "$LUABIN"
ln -s "$(command -v luajit)" "$LUABIN/luajit"
STUBS="$TMP/stubs"
export STUB_LOG="$TMP/stub.log"
mkdir -p "$STUBS"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_SYSTEM=/dev/null JJ_CONFIG="$TMP/jj.toml"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' >"$GIT_CONFIG_GLOBAL"
printf 'user.name = "t"\nuser.email = "t@t"\nsigning.behavior = "drop"\ngit.sign-on-push = false\n' >"$JJ_CONFIG"
cp "$JJ_CONFIG" "$TMP/jj.base.toml"
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
assert_contains "lua wins over make" "$(run_dev "$plain")" "lua project at"
rm "$plain/Makefile"

none="$(project none)"
mkdir -p "$none/.ci"
printf 'return {}\n' >"$none/.ci/jobs.lua"
out="$(run_dev "$none" lint 2>&1)"
assert_eq "undetected project exits 1" "$?" "1"
assert_contains "undetected project explains" "$out" "no built-in lint for undetected"
assert_contains "a .lua file in a dot directory does not make a lua project" "$(run_dev "$none")" "dev: project at"

# A local override wins over the built-in
mkdir -p "$rust/.dev"
printf '#!/usr/bin/env bash\n# flags: --flag\necho "override $*"\n' >"$rust/.dev/lint.sh"
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

printf '#!/usr/bin/env bash\n# flags: --dry-run\necho "init override $*"\n' >"$rust/.dev/init.sh"
chmod +x "$rust/.dev/init.sh"
out="$(run_dev "$rust" init --dry-run)"
assert_eq "local init.sh wins over the built-in init" "$out" "init override --dry-run"
rm "$rust/.dev/init.sh"

# shellcheck disable=SC2016  # $* expands when the stub runs
printf '#!/usr/bin/env bash\necho "pass $*" >>"$STUB_LOG"\necho cf_secret\n' >"$STUBS/pass"

# shellcheck disable=SC2016  # $* and $BOARDS_JSON expand when the stub runs
printf '#!/usr/bin/env bash\necho "curl $*" >>"$STUB_LOG"\ncat >>"$STUB_LOG"\n[ -n "${CURL_FAIL:-}" ] && exit 7\nprintf "%%s" "$BOARDS_JSON"\n' >"$STUBS/curl"
chmod +x "$STUBS/pass" "$STUBS/curl"
initdir="$(project boardinit)"
export BOARDS_JSON='[{"id":"b1","name":"General"}]'
out="$(run_dev "$initdir" init --type lua --dry-run --no-gerrit --name proj 2>&1)"
assert_contains "init suggests a board when none is named after the project" "$out" "No Pomb board for proj"
assert_contains "init asks the board with a read-only GET" "$(log)" "curl -fsS --max-time 5 -K - https://pomb.example.com/api/boards"
assert_contains "init reads the worker token" "$(log)" "pass show secrets/worker/token/pomb.example.com"
assert_not_contains "init keeps the token off the command line" "$(log | grep '^curl')" "cf_secret"
export BOARDS_JSON='[{"id":"b1","name":"General"},{"id":"b2","name":"proj"}]'
out="$(run_dev "$initdir" init --type lua --dry-run --no-gerrit --name proj 2>&1)"
assert_not_contains "init stays quiet when the board exists" "$out" "No Pomb board"
out="$(CURL_FAIL=1 run_dev "$initdir" init --type lua --dry-run --no-gerrit --name proj 2>&1)"
assert_eq "init survives an unreachable board" "$?" "0"
assert_not_contains "init skips the hint when the board is unreachable" "$out" "No Pomb board"
printf '#!/usr/bin/env bash\nexit 1\n' >"$STUBS/pass"
export BOARDS_JSON='[]'
out="$(run_dev "$initdir" init --type lua --dry-run --no-gerrit --name proj 2>&1)"
assert_not_contains "init skips the hint when pass has no token" "$out" "No Pomb board"
unset BOARDS_JSON
rm -f "$STUBS/pass" "$STUBS/curl"

# Global verbosity flags
vp="$(project verbose)"
mkdir -p "$vp/.dev"

# shellcheck disable=SC2016  # $* and ${VERBOSE} expand in the generated script
printf '#!/usr/bin/env bash\n# flags: --flag\necho "args=$* verbose=${VERBOSE:-unset}"\nbash inner.sh\n' >"$vp/.dev/lint.sh"
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
assert_contains "-vv traces the override script" "$err" "+ lint.sh:3: echo"
assert_contains "-vv traces a bash script the override runs through BASH_ENV" "$err" "+ inner.sh:1: true"
printf '#!/usr/bin/env bash\nset -euo pipefail\nbash child.sh\n' >"$vp/.dev/chain.sh"
chmod +x "$vp/.dev/chain.sh"
printf 'set -euo pipefail\nbash grandchild.sh\n' >"$vp/child.sh"
printf 'false\necho survived\n' >"$vp/grandchild.sh"
assert_eq "-vv leaks no errexit into a grandchild script" "$(run_dev "$vp" -vv chain 2>/dev/null)" "survived"
mkdir -p "$TMP/bare"
cp "$DEV" "$TMP/bare/dev"
mkdir -p "$TMP/share"
cp -R "$REPO/dotfiles/bin/.local/share/dev" "$TMP/share/dev"
rm "$TMP/share/dev/xtrace.bash"
out="$(cd "$vp" && "$TMP/bare/dev" -vv lint 2>"$TMP/err")"
assert_eq "-vv without the trace file falls back to level 1" "$out" "args= verbose=1"
assert_contains "-vv without the trace file says so" "$(cat "$TMP/err")" "trace file"
out="$(VERBOSE=2 run_dev "$vp" lint 2>"$TMP/err")"
assert_eq "VERBOSE=2 from the environment equals -vv" "$out" "args= verbose=2"
assert_contains "VERBOSE=2 from the environment traces" "$(cat "$TMP/err")" "+ lint.sh:3: echo"
assert_eq "-v prints the override command on stderr" "$(run_dev "$vp" -v lint --flag 2>&1 >/dev/null)" "+ .dev/lint.sh --flag"
assert_eq "no flag prints nothing on stderr" "$(run_dev "$vp" lint --flag 2>&1 >/dev/null)" ""
assert_contains "-v prints the built-in command on stderr" "$(run_dev "$rust" -v build 2>&1 >/dev/null)" "+ cargo build --release"
assert_contains "-vv exports the trace to the built-in's bash children" "$(run_dev "$rust" -vv build 2>&1 >/dev/null)" "+ cargo:2: echo"
assert_contains "__flags lint includes --verbose" "$(run_dev "$vp" __flags lint)" "--verbose"
assert_contains "help lists the global flags" "$(run_dev "$vp" help)" "global flags"

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
assert_contains "bare dev names the project type" "$out" "rust project at"
assert_contains "help marks the override" "$out" "(override)"
assert_not_contains "help hides the hidden verbs" "$out" "__verbs"

# A local-only verb runs, and the listings carry it with its description
printf '#!/usr/bin/env bash\n# Install the thing.\n# flags: --now --later\necho "installed $*"\n' >"$rust/.dev/install.sh"
chmod +x "$rust/.dev/install.sh"
out="$(run_dev "$rust" install --now)"
assert_eq "local-only verb runs its script" "$out" "installed --now"
assert_contains "-h on a script verb gives help" "$(run_dev "$rust" install -h)" "dev install"
assert_eq "-- lets -h through to a script verb" "$(run_dev "$rust" install -- -h)" "installed -h"
assert_eq "-h after the -- of a built-in reaches its command" "$(run_dev "$rust" run -- -h >/dev/null && log)" "cargo run -- -h"
out="$(run_dev "$rust" __verbs)"
assert_contains "__verbs lists a local verb with its description" "$out" "install	local	Install the thing."
assert_contains "__verbs lists a built-in" "$out" "fmt	builtin	"
assert_contains "__verbs marks an override" "$out" "lint	override	"
assert_not_contains "__verbs hides hidden verbs" "$out" "__"
out="$(run_dev "$rust" help)"
assert_contains "help lists a local verb under the project's group" "$out" "$(printf '\nrust\n  install')"
assert_contains "help shows a local verb description" "$out" "Install the thing."
out="$(run_dev "$rust" help init)"
for flag in --type --public --name --dry-run --no-gerrit; do
    assert_contains "help init lists $flag" "$out" "$flag"
done
help_out="$(run_dev "$rust" help -a)"
verbs_out="$(run_dev "$rust" __verbs)"
for verb in lint fmt test build run deploy push pull sync init help; do
    assert_contains "help lists built-in $verb" "$help_out" "  $verb "
    assert_contains "__verbs lists built-in $verb" "$verbs_out" "$verb	"
done
out="$(run_dev "$rust" help deploy)"
assert_contains "help deploy shows the table's usage line" "$out" "(none: add .dev/deploy.sh)"
out="$(run_dev "$rust" __flags install)"
assert_eq "__flags reads the flags line of a script and adds the global flags" "$out" "--now
--later
-v
--verbose
-vv
--remote
--local
--detach"
out="$(run_dev "$rust" __flags sync)"
assert_eq "__flags sync" "$out" "--check
--yes
-y
-v
--verbose
-vv
--remote
--local
--detach"
out="$(run_dev "$rust" help sync)"
assert_contains "help sync lists --yes" "$out" "--yes"
assert_contains "help <verb> mentions the global flags" "$out" "Global flags:"
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
    out="$(cd "$rust" && env PATH="$LUABIN:/usr/bin:/bin" bash "$DEV" lint 2>&1)"
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
assert_contains "sync --check reports the missing shared lint library" "$out" "missing: .dev/lint-lib.sh"
assert_not_contains "sync --check ignores a matching file" "$out" "rustfmt.toml"
mkdir -p "$sync/.dev"
printf '.dev/evidence/**\n' >"$sync/.dev/lint-ignore"
out="$(run_dev "$sync" sync --check)"
assert_not_contains "sync --check leaves a project-owned lint-ignore alone" "$out" "lint-ignore"
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
    out="$(cd "$sync" && env PATH="$STUBS:$LUABIN:/usr/bin:/bin" bash "$DEV" sync --check 2>&1)"
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
    assert_contains "init --dry-run plans the pipeline" "$out" "would create: .ci/jobs.lua"
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
    assert_contains "init copies the shared lint library" "$out" "created: .dev/lint-lib.sh"
    assert_eq "init writes the shared lint library" "$([ -f "$init/.dev/lint-lib.sh" ] && echo yes)" "yes"
    assert_eq "init does not create .dev/lint-ignore" "$([ -e "$init/.dev/lint-ignore" ] && echo yes)" ""

    # shellcheck disable=SC2016  # the asserted line is matched literally, not expanded
    assert_contains "init sources the lint library from beside the lint script" "$(cat "$init/.dev/lint.sh")" '. "$(dirname "${BASH_SOURCE[0]}")/lint-lib.sh"'
    assert_not_contains "init leaves no path above .dev for the lint library" "$(cat "$init/.dev/lint.sh")" "/../lint-lib.sh"
    assert_contains "init copies the rust fmt script" "$out" "created: .dev/fmt.sh"

    # shellcheck disable=SC2016  # the asserted line is matched literally, not expanded
    assert_contains "init sources the lint library from beside the fmt script" "$(cat "$init/.dev/fmt.sh")" '. "$(dirname "${BASH_SOURCE[0]}")/lint-lib.sh"'
    assert_not_contains "init leaves no path above .dev in the fmt script" "$(cat "$init/.dev/fmt.sh")" "/../lint-lib.sh"
    assert_contains "init points the fmt script cd at the root" "$(cat "$init/.dev/fmt.sh")" 'BASH_SOURCE[0]}")/.."'
    assert_contains "init relocates the ast-grep rules" "$(cat "$init/sgconfig.yml")" ".dev/ast-grep/rules"
    assert_contains "init pins the lint set channel" "$(cat "$init/rust-toolchain.toml")" "$(grep "^channel = " "$REPO/dotfiles/claude/.claude/skills/style/lint/rust/rust-toolchain.toml")"
    assert_contains "init appends the workspace lints" "$(cat "$init/Cargo.toml")" "[workspace.lints.rust]"
    assert_contains "init writes the pipeline" "$(cat "$init/.ci/jobs.lua")" ".dev/lint.sh"
    assert_contains "init seeds a lint job" "$(cat "$init/.ci/jobs.lua")" "    lint = {"
    assert_contains "init seeds a test job" "$(cat "$init/.ci/jobs.lua")" "    test = {"
    assert_contains "init runs the jobs on the rust runner target" "$(cat "$init/.ci/jobs.lua")" "local LINUX = { target = \"linux-x86-rust\" }"
    assert_contains "init's pipeline creates ~/.cargo/bin before installing nextest" "$(cat "$init/.ci/jobs.lua")" "mkdir -p \$HOME/.cargo/bin && curl"
    assert_contains "init's pipeline reads the channel from rust-toolchain.toml at run time" "$(cat "$init/.ci/jobs.lua")" 'io.open("rust-toolchain.toml")'
    assert_contains "init writes the workflow for windows" "$(cat "$init/.github/workflows/ci.yml")" "windows-latest"
    assert_contains "init seeds docs/STYLE.md from the rust guide" "$out" "created: docs/STYLE.md"
    assert_contains "init copies the rust guide" "$(cat "$init/docs/STYLE.md")" "# Rust style"
    assert_contains "init ends docs/STYLE.md with a project section" "$(tail -n 3 "$init/docs/STYLE.md")" "Rules that apply only to this project"
    assert_contains "init tells project authors to number their rules with a P prefix" "$(tail -n 3 "$init/docs/STYLE.md")" "Number them P1, P2"
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

    marker='# --- project-specific entries below (dev sync keeps them) ---'
    assert_contains "init writes the deny.toml marker" "$(cat "$init/deny.toml")" "$marker"
    assert_eq "init writes no tail below the deny.toml marker" "$(sed -n "/^${marker}\$/,\$p" "$init/deny.toml" | wc -l | tr -d ' ')" "1"
    printf '\n[[licenses.exceptions]]\nname = "webpki-roots"\nallow = ["CDLA-Permissive-2.0"]\n' >>"$init/deny.toml"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check ignores a tail below the deny.toml marker" "$out" "up to date"
    sd 'allow-git = \[\]' 'allow-git = ["x"]' "$init/deny.toml"
    out="$(run_dev "$init" sync --check)"
    assert_contains "sync --check reports drift above the deny.toml marker" "$out" "differs: deny.toml"
    run_dev "$init" sync --yes >/dev/null
    assert_contains "sync keeps the deny.toml tail" "$(cat "$init/deny.toml")" 'name = "webpki-roots"'
    assert_contains "sync restores the template above the deny.toml marker" "$(cat "$init/deny.toml")" "allow-git = []"
    out="$(run_dev "$init" sync --check)"
    assert_eq "sync --check is clean after keeping the deny.toml tail" "$out" "up to date"

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
    assert_eq "love2d init writes the shared lint library" "$([ -f "$game/.dev/lint-lib.sh" ] && echo yes)" "yes"

    # shellcheck disable=SC2016  # the asserted line is matched literally, not expanded
    assert_contains "love2d init sources the lint library from beside the lint script" "$(cat "$game/.dev/lint.sh")" '. "$(dirname "${BASH_SOURCE[0]}")/lint-lib.sh"'
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
on_tty() {
    if sv=$(script --version 2>&1) && grep -q util-linux <<<"$sv"; then
        script -qec "$(printf '%q ' "$@")" /dev/null
    else
        script -q /dev/null "$@"
    fi
}
if command -v script >/dev/null 2>&1; then
    sd 'missing_safety_doc = "deny"' 'missing_safety_doc = "warn"' "$reg/Cargo.toml"
    (cd "$reg" && on_tty env PATH="$STUBS:$PATH" "$DEV" sync < <(
        printf 'y\n'
        sleep 30
    ) >"$TMP/sync.out" 2>&1)
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
    out="$(cd "$nojj" && env PATH="$LUABIN:/usr/bin:/bin" bash "$DEV" init --no-gerrit 2>&1)"
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
echo g >"$gp/g"
git -C "$gp" add g
gitc -C "$gp" commit -q -m "feat: only for the remote of record"
second="$(git -C "$gp" rev-parse HEAD)"
out="$(run_dev "$gp" push 2>&1)"
assert_eq "push in a gerrit project exits 0" "$?" "0"
assert_contains "push in a gerrit project names the forge" "$out" "forge gerrit, remote of record gerrit (detected: the project has a gerrit remote)"
assert_contains "push in a gerrit project pushes to gerrit" "$out" "gerrit: pushed main"
assert_not_contains "push in a gerrit project leaves origin alone" "$out" "origin:"
assert_eq "gerrit gets the new commit" "$(git -C "$TMP/gerrit.git" rev-parse main)" "$second"
assert_eq "origin keeps the old commit" "$(git -C "$gremote" rev-parse main)" "$clean"
git -C "$gp" config forge.kind github
out="$(run_dev "$gp" push 2>&1)"
assert_contains "forge.kind github pushes to origin" "$out" "forge github, remote of record origin (git config forge.kind=github)"
assert_contains "forge.kind github reports the origin push" "$out" "origin: pushed main"
assert_not_contains "forge.kind github leaves gerrit out" "$out" "gerrit:"
git -C "$gremote" update-ref refs/heads/main "$clean"
git -C "$gp" config forge.kind plain
git -C "$gp" config forge.remote origin
out="$(run_dev "$gp" push 2>&1)"
assert_contains "forge.remote names the remote of record" "$out" "forge plain, remote of record origin (git config forge.kind=plain; remote from git config forge.remote)"
git -C "$gremote" update-ref refs/heads/main "$clean"
git -C "$gp" config forge.remote nosuch
out="$(run_dev "$gp" push 2>&1)"
assert_eq "a remote of record the project lacks exits 1" "$?" "1"
assert_contains "push names the missing remote of record" "$out" "the remote of record nosuch is not a remote of this project"
assert_contains "help push gives the same reason" "$(run_dev "$gp" help push)" "(none: the remote of record nosuch is not a remote"
git -C "$gp" config forge.kind bogus
out="$(run_dev "$gp" push 2>&1)"
assert_eq "an unknown forge exits 1" "$?" "1"
assert_contains "push names the unknown forge" "$out" "forge must be gerrit, github or plain (got: bogus"
out="$(JJ_FORGE=github run_dev "$gp" push 2>&1)"
assert_contains "JJ_FORGE wins over the setting" "$out" "(JJ_FORGE=github; remote from git config forge.remote)"
git -C "$gp" config --unset forge.kind
git -C "$gp" config --unset forge.remote
git -C "$gp" reset -q --hard "$clean"
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
    git init -q --bare -b main "$TMP/jgerrit.git"
    git -C "$gremote" push -q "$TMP/jgerrit.git" main
    jj --no-pager -R "$jp" git remote add gerrit "$TMP/jgerrit.git"
    jj --no-pager -R "$jp" git fetch --remote gerrit >/dev/null 2>&1
    jj --no-pager -R "$jp" bookmark track main --remote gerrit >/dev/null 2>&1
    jj --no-pager -R "$jp" new main -m "feat: jj gerrit push" >/dev/null 2>&1
    jj --no-pager -R "$jp" bookmark set main -r @ >/dev/null 2>&1
    jtip="$(jj --no-pager -R "$jp" log --no-graph -r main -T 'commit_id')"
    assert_contains "jj help push previews only the remote of record" "$(run_dev "$jp" help push)" "git push --remote gerrit -b main"
    assert_not_contains "jj help push leaves origin out" "$(run_dev "$jp" help push)" "--remote origin"
    out="$(run_dev "$jp" push 2>&1)"
    assert_eq "jj push in a gerrit project exits 0" "$?" "0"
    assert_contains "jj push in a gerrit project names the forge" "$out" "forge gerrit, remote of record gerrit"
    assert_eq "jj push puts the bookmark on gerrit" "$(git -C "$TMP/jgerrit.git" rev-parse main)" "$jtip"
    assert_eq "jj push leaves origin alone" "$(git -C "$gremote" rev-parse main)" "$(git -C "$TMP/second" rev-parse main)"
    cp "$TMP/jj.base.toml" "$JJ_CONFIG"
else
    printf 'skip - jj pull and jj push (needs jj)\n'
fi

# Nouns: .dev/<noun>/<sub>.sh beside flat verbs
nn="$(project noun)"
mkdir -p "$nn/.dev/widget"
printf '#!/usr/bin/env bash\n# Save the widget.\n# flags: --now --later\necho "save $*"\n' >"$nn/.dev/widget/save.sh"
printf '#!/usr/bin/env bash\n# Diff the widget.\necho "diff $*"\n' >"$nn/.dev/widget/diff.sh"
printf '#!/usr/bin/env bash\n# Hidden helper.\necho helper\n' >"$nn/.dev/widget/__helper.sh"
printf '#!/usr/bin/env bash\n# Not executable.\n' >"$nn/.dev/widget/skipped.sh"
printf '#!/usr/bin/env bash\n# Verify prod.\n# flags: --fast\necho "verify $*"\n' >"$nn/.dev/verify-prod.sh"
chmod +x "$nn/.dev/widget/save.sh" "$nn/.dev/widget/diff.sh" "$nn/.dev/widget/__helper.sh" "$nn/.dev/verify-prod.sh"
out="$(run_dev "$nn" widget save a b)"
assert_eq "a subcommand runs its script with the arguments" "$out" "save a b"
out="$(run_dev "$nn" verify-prod x)"
assert_eq "a flat hyphenated project verb still dispatches" "$out" "verify x"
out="$(run_dev "$nn" help)"
assert_contains "help lists a flat hyphenated verb" "$out" "verify-prod  Verify prod."
assert_contains "help lists the noun once, with its subcommands" "$out" "widget       diff, save"
assert_eq "help lists the noun on one line" "$(printf '%s\n' "$out" | grep -c '^  widget ')" "1"
assert_not_contains "help does not list subcommands as verbs" "$out" "  save "
printf 'Manage the widget.\nmore\n' >"$nn/.dev/widget/DESCRIPTION"
assert_contains "a DESCRIPTION file describes the noun in help" "$(run_dev "$nn" help)" "Manage the widget."
out="$(run_dev "$nn" help widget)"
assert_contains "help <noun> shows the description" "$out" "Manage the widget."
assert_contains "help <noun> lists a subcommand with its description" "$out" "save  Save the widget."
assert_contains "help <noun> lists the other subcommand" "$out" "diff  Diff the widget."
assert_not_contains "help <noun> hides hidden scripts" "$out" "helper"
assert_not_contains "help <noun> hides a script that is not executable" "$out" "skipped"
out="$(run_dev "$nn" help widget save)"
assert_contains "help <noun> <sub> shows the flags" "$out" "--now"
assert_contains "help <noun> <sub> shows the header" "$out" ".dev/widget/save.sh header"
out="$(run_dev "$nn" help widget zap 2>&1)"
assert_eq "help <noun> <unknown> exits 2" "$?" "2"
assert_contains "help <noun> <unknown> names it" "$out" "unknown subcommand zap of widget"
out="$(run_dev "$nn" widget zap 2>&1)"
assert_eq "an unknown subcommand exits 2" "$?" "2"
assert_contains "an unknown subcommand names it" "$out" "dev widget: unknown subcommand zap"
assert_contains "an unknown subcommand lists the choices" "$out" "save  Save the widget."
out="$(run_dev "$nn" widget 2>&1)"
assert_eq "a noun with no subcommand exits 2" "$?" "2"
assert_contains "a noun with no subcommand says so" "$out" "dev widget: needs a subcommand"
out="$(run_dev "$nn" widget --help)"
assert_eq "noun --help exits 0" "$?" "0"
assert_contains "noun --help lists the subcommands" "$out" "diff  Diff the widget."
out="$(run_dev "$nn" widget __helper 2>&1)"
assert_eq "a hidden script is not a subcommand" "$?" "2"
out="$(run_dev "$nn" __verbs)"
assert_contains "__verbs lists a noun" "$out" "widget	local	Manage the widget."
assert_contains "__verbs lists a flat hyphenated verb" "$out" "verify-prod	local	Verify prod."
out="$(run_dev "$nn" __subs widget)"
assert_eq "__subs lists the subcommands with descriptions" "$out" "diff	local	Diff the widget.
save	local	Save the widget."
assert_eq "__subs of a plain verb is empty" "$(run_dev "$nn" __subs verify-prod)" ""
out="$(run_dev "$nn" __flags widget save)"
assert_eq "__flags <noun> <sub> reads the script's flags line" "$out" "--now
--later
-v
--verbose
-vv
--remote
--local
--detach"
assert_eq "-v prints the subcommand script on stderr" "$(run_dev "$nn" -v widget save 2>&1 >/dev/null)" "+ .dev/widget/save.sh"
printf '#!/usr/bin/env bash\n# Flat widget.\necho "flat $*"\n' >"$nn/.dev/widget.sh"
chmod +x "$nn/.dev/widget.sh"
assert_eq "a flat script takes the whole noun name" "$(run_dev "$nn" widget save)" "flat save"
rm "$nn/.dev/widget.sh"
nn_none="$(project nonoun)"
mkdir -p "$nn_none/.dev/lint" "$nn_none/.dev/empty"
printf '#!/usr/bin/env bash\necho x\n' >"$nn_none/.dev/lint/x.sh"
chmod +x "$nn_none/.dev/lint/x.sh"
out="$(run_dev "$nn_none" help)"
assert_not_contains "a directory named like a built-in verb is not a noun" "$out" "  x "
assert_not_contains "a directory with no scripts is not a noun" "$out" "empty"

# --remote
export JOB_TARGET=linux-x86-base
cistubs="$TMP/cistubs"
mkdir -p "$cistubs"
cat >"$cistubs/ci" <<'STUB'
#!/usr/bin/env bash
root=""
if [ "$1" = -C ]; then
    root="$2"
    shift 2
fi
case "$1" in
jobs) printf '{"jobs":[{"name":"lint","targets":["%s"]},{"name":"test","targets":["%s"]},{"name":"widget.save","targets":["%s"]},{"name":"check","targets":["%s"]},{"name":"gadget","targets":["%s"]}]}\n' "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" ;;
run)
    printf 'ci -C %s' "$root" >>"$STUB_LOG"
    printf ' [%s]' "$@" >>"$STUB_LOG"
    printf '\n' >>"$STUB_LOG"
    exit "${CI_STUB_RC:-0}"
    ;;
esac
STUB
chmod +x "$cistubs/ci"
cirun() {
    local dir="$1"
    shift
    : >"$STUB_LOG"
    (cd "$dir" && PATH="$cistubs:$STUBS:$PATH" "$DEV" "$@")
}
cip="$(project ci)"
sub="$cip/sub"
mkdir -p "$cip/.ci" "$sub"
printf 'return {}\n' >"$cip/.ci/jobs.lua"
git -C "$cip" init -q

out="$(cirun "$sub" --remote lint 2>&1)"
assert_eq "--remote runs the job through ci from the project root" "$out" ""
assert_eq "--remote passes the root, job and follow flags" "$(log)" "ci -C $cip [run] [--local] [--follow] [--job] [lint] [--]"
cirun "$cip" lint --remote >/dev/null 2>&1
assert_contains "--remote works after the verb" "$(log)" "[--follow] [--job] [lint]"
DEV_REMOTE=1 cirun "$cip" test >/dev/null 2>&1
assert_contains "DEV_REMOTE=1 counts as --remote" "$(log)" "[--job] [test]"
DEV_REMOTE=0 cirun "$cip" lint >/dev/null 2>&1
assert_not_contains "DEV_REMOTE=0 runs locally" "$(log)" "[run]"
CI_STUB_RC=7 cirun "$cip" --remote test >/dev/null 2>&1
assert_eq "--remote exits with ci's status" "$?" "7"
cirun "$cip" --remote test -- a "b c" "\$(x)" >/dev/null 2>&1
assert_contains "--remote hands the arguments after -- over as separate words" "$(log)" "[--job] [test] [--] [a] [b c] [\$(x)]"
cirun "$cip" test --remote -- a >/dev/null 2>&1
assert_contains "--remote after the verb passes the same arguments" "$(log)" "[--job] [test] [--] [a]"
cirun "$cip" --remote --detach test >/dev/null 2>&1
assert_contains "--detach replaces --follow" "$(log)" "[--detach] [--job] [test]"
assert_not_contains "--detach drops --follow" "$(log)" "[--follow]"
out="$(cirun "$cip" --detach test 2>&1)"
assert_eq "--detach without --remote exits 2" "$?" "2"
assert_contains "--detach without --remote says so" "$out" "--detach needs --remote"
assert_eq "--detach without --remote runs nothing" "$(log)" ""

out="$(cirun "$cip" --remote build 2>&1)"
assert_eq "--remote with no such job exits 1" "$?" "1"
assert_contains "--remote with no such job hints at the pipeline" "$out" "no job named build in the project's default pipeline (.ci/jobs.lua), add one"
assert_eq "--remote with no such job runs nothing" "$(log)" ""
out="$(cirun "$cip" --remote lint --extra 2>&1)"
assert_eq "--remote refuses arguments before -- with 2" "$?" "2"
assert_contains "--remote names the extra argument" "$out" "--remote passes arguments to the job only after --, got --extra"

mkdir -p "$cip/.dev/widget"
printf '#!/usr/bin/env bash\necho x\n' >"$cip/.dev/widget/save.sh"
chmod +x "$cip/.dev/widget/save.sh"
cirun "$cip" --remote widget save >/dev/null 2>&1
assert_contains "--remote maps a subcommand to the job noun.sub" "$(log)" "[--job] [widget.save]"
out="$(cirun "$cip" widget --remote zap 2>&1)"
assert_eq "--remote with an unknown subcommand exits 2" "$?" "2"
assert_contains "--remote with an unknown subcommand names it" "$out" "unknown subcommand zap"
for verb in install uninstall restow sync setup fmt fetch help init push pull; do
    out="$(cirun "$cip" --remote "$verb" 2>&1)"
    assert_eq "--remote refuses $verb with 2" "$?" "2"
    assert_contains "--remote names the refused verb $verb" "$out" "dev $verb: runs on this machine only, so --remote does not apply"
done
for flag in -h --help; do
    out="$(cirun "$cip" --remote "$flag" 2>&1)"
    assert_eq "--remote $flag is refused like help" "$?" "2"
    assert_contains "--remote $flag names help" "$out" "dev help: runs on this machine only, so --remote does not apply"
done
assert_eq "a refused verb runs nothing" "$(log)" ""
out="$(cirun "$cip" help)"
assert_contains "help mentions --remote" "$out" "--remote"

printf '#!/usr/bin/env bash\nexit 99\n' >"$cip/.dev/lint.sh"
chmod +x "$cip/.dev/lint.sh"
mkdir -p "$cip/.dev"
cat >"$cip/.dev/__remote.lua" <<'LUA'
return function(run)
    io.write(table.concat(run.words, " "), "|", table.concat(run.args, ","), "|", tostring(run.detach), "|", run.root, "\n")
    return 5
end
LUA
out="$(cirun "$cip" --remote lint -- a 'b c' 2>&1)"
assert_eq "a __remote.lua runner's integer is the exit code" "$?" "5"
assert_eq "a __remote.lua runner gets words, args, detach and root" "$out" "lint|a,b c|false|$cip"
assert_eq "a __remote.lua runner replaces ci" "$(log)" ""
out="$(cirun "$cip" --remote --detach lint 2>&1)"
assert_contains "a __remote.lua runner sees --detach" "$out" "|true|"
rm "$cip/.dev/__remote.lua"

agent="$(project agent)"
mkdir -p "$agent/.ci" "$agent/.dev"
printf 'return {}\n' >"$agent/.ci/jobs.lua"
git -C "$agent" init -q
printf '#!/usr/bin/env bash\necho check ran\n' >"$agent/.dev/check.sh"
printf '#!/usr/bin/env bash\n# local\necho gadget ran\n' >"$agent/.dev/gadget.sh"
printf '#!/usr/bin/env bash\necho notes ran\n' >"$agent/.dev/notes.sh"
chmod +x "$agent/.dev/check.sh" "$agent/.dev/gadget.sh" "$agent/.dev/notes.sh"
touch "$TMP/ci-box"
out="$(DEV_AGENT=w cirun "$agent" --local check 2>&1)"
assert_eq "an agent's --local run of a verb with a ci job exits 2" "$?" "2"
assert_contains "an agent's --local refusal names dev --remote" "$out" "dev check: DEV_AGENT is set, so it runs on ci; use dev --remote check"
assert_not_contains "an agent's --local refusal runs nothing" "$out" "check ran"
out="$(DEV_AGENT=w cirun "$agent" check 2>&1)"
assert_eq "an agent's DEV_REMOTE=0 run of a verb with a ci job exits 2" "$?" "2"
assert_contains "an agent's DEV_REMOTE=0 refusal names dev --remote" "$out" "use dev --remote check"
out="$(DEV_AGENT=w cirun "$agent" --remote check 2>&1)"
assert_eq "an agent's --remote run still exits with ci's status" "$?" "0"
assert_contains "an agent's --remote run still goes to ci" "$(log)" "[--job] [check]"
out="$(DEV_AGENT=w cirun "$agent" --local gadget 2>&1)"
assert_contains "an agent's --local run of a # local verb runs here" "$out" "gadget ran"
out="$(DEV_AGENT=w cirun "$agent" --local notes 2>&1)"
assert_contains "an agent's --local run of a verb with no ci job runs here" "$out" "notes ran"
out="$(DEV_AGENT=w CI=true cirun "$agent" --local check 2>&1)"
assert_contains "CI=true runs an agent's --local verb here" "$out" "check ran"
out="$(DEV_AGENT=w DEV_BOX_MARKER="$TMP/ci-box" cirun "$agent" --local check 2>&1)"
assert_contains "the box marker runs an agent's --local verb here" "$out" "check ran"
out="$(cirun "$agent" --local check 2>&1)"
assert_contains "DEV_AGENT unset runs --local here" "$out" "check ran"
out="$(DEV_AGENT='' cirun "$agent" --local check 2>&1)"
assert_contains "an empty DEV_AGENT runs --local here" "$out" "check ran"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall dev tests passed\n'
