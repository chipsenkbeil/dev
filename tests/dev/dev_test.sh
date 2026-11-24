#!/usr/bin/env bash
# Pure-bash tests for the `dev` dispatcher. Each case builds a throwaway repo in a
# temp dir and puts logging stubs for the build tools first on PATH.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"
export DOTFILES="$REPO"
unset VERBOSE CI DEV_AGENT
export DEV_REMOTE=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export STUB_LOG="$TMP/stub.log"
mkdir -p "$STUBS"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_SYSTEM=/dev/null JJ_CONFIG="$TMP/jj.toml"
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' >"$GIT_CONFIG_GLOBAL"
printf 'user.name = "t"\nuser.email = "t@t"\nsigning.behavior = "drop"\n' >"$JJ_CONFIG"
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

cp "$STUBS/cargo" "$TMP/cargo.ok"

# shellcheck disable=SC2016  # $* expands in the generated stub
printf '#!/usr/bin/env bash\ncase "$*" in *--version) exit 1 ;; esac\nexit 0\n' >"$STUBS/cargo"
touch "$rust/deny.toml"
out="$(run_dev "$rust" lint 2>&1)"
assert_eq "a missing nightly rustfmt ends the rust lint with 1" "$?" "1"
assert_contains "a missing nightly rustfmt gets a sentence" "$out" "Tool nightly rustfmt not found. Install it with rustup toolchain install nightly --component rustfmt."
out="$(run_dev "$rust" test 2>&1)"
assert_contains "a missing cargo-nextest gets a sentence" "$out" "Tool cargo-nextest not found. Install it with cargo install cargo-nextest --locked."
out="$(run_dev "$rust" fetch 2>&1)"
assert_contains "a missing cargo-deny gets a sentence" "$out" "Tool cargo-deny not found. Install it with cargo install cargo-deny --locked."
rm "$rust/deny.toml"
cp "$TMP/cargo.ok" "$STUBS/cargo"

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
assert_contains "undetected project explains" "$out" "There is no built-in lint for an undetected project."
assert_contains "a .lua file in a dot directory does not make a lua project" "$(run_dev "$none")" "dev: project at"

# A local override wins over the built-in
mkdir -p "$rust/.dev/commands"

# shellcheck disable=SC2016  # ${DEV_FLAG_*} expands in the generated script
printf '#!/usr/bin/env bash\n# flag: flag kind=boolean\necho override ${DEV_FLAG_FLAG:+--flag}\n' >"$rust/.dev/commands/lint.sh"
chmod +x "$rust/.dev/commands/lint.sh"
out="$(run_dev "$rust" lint --flag)"
assert_eq "override runs with args" "$out" "override --flag"
assert_eq "override skips the built-in" "$(log)" ""

# shellcheck disable=SC2016  # ${DEV_FLAG_*} expands in the generated script
printf '#!/usr/bin/env bash\n# flag: dry-run kind=boolean\necho init override ${DEV_FLAG_DRY_RUN:+--dry-run}\n' >"$rust/.dev/commands/init.sh"
chmod +x "$rust/.dev/commands/init.sh"
out="$(run_dev "$rust" init --dry-run)"
assert_eq "local init.sh wins over the built-in init" "$out" "init override --dry-run"
rm "$rust/.dev/commands/init.sh"

# Global verbosity flags
vp="$(project verbose)"
mkdir -p "$vp/.dev/commands"

# shellcheck disable=SC2016  # $* and ${VERBOSE} expand in the generated script
printf '#!/usr/bin/env bash\n# flag: flag kind=boolean\necho "args=$*${DEV_FLAG_FLAG:+--flag} verbose=${VERBOSE:-unset}"\nbash inner.sh\n' >"$vp/.dev/commands/lint.sh"
chmod +x "$vp/.dev/commands/lint.sh"
printf 'true\n' >"$vp/inner.sh"
assert_eq "-v before the verb sets VERBOSE=1" "$(run_dev "$vp" -v lint 2>/dev/null)" "args= verbose=1"
assert_eq "-v after the verb sets VERBOSE=1" "$(run_dev "$vp" lint -v 2>/dev/null)" "args= verbose=1"
assert_eq "--verbose sets VERBOSE=1" "$(run_dev "$vp" lint --verbose 2>/dev/null)" "args= verbose=1"
assert_eq "lint --flag -v passes only --flag" "$(run_dev "$vp" lint --flag -v 2>/dev/null)" "args=--flag verbose=1"
assert_eq "-- passes -v through untouched" "$(run_dev "$vp" lint -- -v 2>/dev/null)" "args=-v verbose=unset"
assert_eq "-vv sets VERBOSE=2" "$(run_dev "$vp" -vv lint 2>/dev/null)" "args= verbose=2"
assert_eq "-v -v equals -vv" "$(run_dev "$vp" -v lint -v 2>/dev/null)" "args= verbose=2"
assert_eq "-vvv sets VERBOSE=3" "$(run_dev "$vp" -vvv lint 2>/dev/null)" "args= verbose=3"
assert_eq "-vvvvv clamps to 4" "$(run_dev "$vp" -vvvvv lint 2>/dev/null)" "args= verbose=4"
assert_eq "VERBOSE=yes from the environment is level 1" "$(VERBOSE=yes run_dev "$vp" lint 2>/dev/null)" "args= verbose=1"
assert_eq "VERBOSE=0 from the environment is not exported" "$(VERBOSE=0 run_dev "$vp" lint 2>/dev/null)" "args= verbose=unset"
assert_eq "-v wins over VERBOSE from the environment" "$(VERBOSE=2 run_dev "$vp" -v lint 2>/dev/null)" "args= verbose=1"
err="$(run_dev "$vp" -vvv lint 2>&1 >/dev/null)"
assert_contains "-vvv traces the override script" "$err" "+ echo 'args= verbose=3'"
printf '#!/usr/bin/env bash\nset -euo pipefail\nbash child.sh\n' >"$vp/.dev/commands/chain.sh"
chmod +x "$vp/.dev/commands/chain.sh"
printf 'set -euo pipefail\nbash grandchild.sh\n' >"$vp/child.sh"
printf 'false\necho survived\n' >"$vp/grandchild.sh"
assert_eq "-vvv leaks no errexit into a grandchild script" "$(run_dev "$vp" -vvv chain 2>/dev/null)" "survived"
out="$(VERBOSE=3 run_dev "$vp" lint 2>"$TMP/err")"
assert_eq "VERBOSE=3 from the environment equals -vvv" "$out" "args= verbose=3"
assert_contains "VERBOSE=3 from the environment traces" "$(cat "$TMP/err")" "+ echo 'args= verbose=3'"
assert_eq "-v prints the override command on stderr" "$(run_dev "$vp" -v lint --flag 2>&1 >/dev/null)" "+ .dev/commands/lint.sh"
assert_eq "no flag prints nothing on stderr" "$(run_dev "$vp" lint --flag 2>&1 >/dev/null)" ""

# shellcheck disable=SC2016  # $DEV_ROOT expands in the generated script
printf '#!/usr/bin/env bash\ncat "$DEV_ROOT/.dev/helpers/note.txt"\n' >"$vp/.dev/commands/where.sh"
chmod +x "$vp/.dev/commands/where.sh"
mkdir -p "$vp/.dev/helpers"
printf 'helper found\n' >"$vp/.dev/helpers/note.txt"
assert_eq "DEV_ROOT names the project root for a .sh command" "$(cd "$vp/.dev" && "$DEV" where 2>/dev/null)" "helper found"
assert_contains "-v prints the built-in command on stderr" "$(run_dev "$rust" -v build 2>&1 >/dev/null)" "+ cargo build --release"
assert_contains "complete lists --verbose among lint's flags" "$(run_dev "$vp" __complete lint -)" "--verbose"
assert_contains "help lists the global flags" "$(run_dev "$vp" help)" "global flags"

# Usage
run_dev "$rust" bogus >/dev/null 2>&1
assert_eq "unknown command exits 2" "$?" "2"
out="$(run_dev "$rust" help nosuch 2>&1)"
assert_eq "help of an unknown command exits 2" "$?" "2"
assert_contains "help names the unknown command" "$out" "dev help: Unknown command nosuch, and no help page has that name."

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
bounded_dev "$rust" builtin:init --name
assert_eq "init --name with no value exits 2" "$BOUNDED_RC" "2"
assert_contains "init names the --name with no value" "$BOUNDED_OUT" "dev init: The flag \`--name\` needs a value."
out="$(run_dev "$rust" builtin:init --bogus 2>&1)"
assert_eq "init with a bad flag exits 2" "$?" "2"
assert_contains "init names the bad flag" "$out" "dev init: Unknown flag --bogus"
out="$(run_dev "$rust")"
assert_eq "no verb exits 0" "$?" "0"
assert_contains "bare dev names the project type" "$out" "rust project at"
assert_contains "help marks the override" "$out" "(override)"
assert_not_contains "help hides the hidden commands" "$out" "__commands"

# A local-only verb runs, and the listings carry it with its description
# shellcheck disable=SC2016  # ${DEV_FLAG_*} expands in the generated script
printf '#!/usr/bin/env bash\n# Install the thing.\n# flag: now kind=boolean\n# flag: later kind=boolean\necho installed "$@" ${DEV_FLAG_NOW:+--now}\n' >"$rust/.dev/commands/install.sh"
chmod +x "$rust/.dev/commands/install.sh"
out="$(run_dev "$rust" install --now)"
assert_eq "local-only verb runs its script" "$out" "installed --now"
assert_contains "-h on a script verb gives help" "$(run_dev "$rust" install -h)" "dev install"
assert_eq "-- lets -h through to a script verb" "$(run_dev "$rust" install -- -h)" "installed -h"
assert_eq "-h after the -- of a built-in reaches its command" "$(run_dev "$rust" run -- -h >/dev/null && log)" "cargo run -- -h"
out="$(run_dev "$rust" __complete "")"
assert_contains "complete lists a local command with its description" "$out" "install	Install the thing."
assert_contains "complete lists a built-in" "$out" "fmt	Format the source for the project type"
assert_contains "complete lists an override" "$out" "lint"
assert_not_contains "complete hides hidden commands" "$out" "__"
out="$(run_dev "$rust" help)"
assert_contains "help lists a local verb under the project's group" "$out" "$(printf '\nrust\n  install')"
assert_contains "help shows a local verb description" "$out" "Install the thing."
out="$(run_dev "$rust" help init)"
for flag in --name --dry-run; do
    assert_contains "help init lists $flag" "$out" "$flag"
done
help_out="$(run_dev "$rust" help -a)"
commands_out="$(run_dev "$rust" __complete "")"
for verb in lint fmt test build run push pull init help; do
    assert_contains "help lists built-in $verb" "$help_out" "  $verb "
done
for verb in lint fmt test build run push pull init; do
    assert_eq "complete lists built-in $verb once" "$(printf '%s\n' "$commands_out" | cut -f1 | grep -cx "$verb")" "1"
done
out="$(run_dev "$vp" __complete lint -)"
assert_contains "complete reads the flags a script declares" "$out" "--flag"
assert_contains "complete adds the global flags" "$out" "--remote"
out="$(run_dev "$rust" help install)"
assert_contains "help <verb> mentions the global flags" "$out" "Global flags:"
assert_contains "help <verb> lists the script's flags" "$out" "--now"
out="$(run_dev "$rust" help build)"
assert_contains "help <verb> shows the built-in command" "$out" "cargo build --release"
out="$(run_dev "$rust" help)"
case "$out" in
*$'\033'*) assert_eq "help is plain when piped" "color escapes" "none" ;;
*) assert_eq "help is plain when piped" "none" "none" ;;
esac
printf '#!/usr/bin/env bash\necho "custom help $*"\n' >"$rust/.dev/commands/help.sh"
chmod +x "$rust/.dev/commands/help.sh"
assert_eq "help.sh replaces dev help" "$(run_dev "$rust" help x)" "custom help x"
assert_eq "help.sh replaces bare dev" "$(run_dev "$rust")" "custom help "
rm "$rust/.dev/commands/help.sh"
run_dev "$rust" nothere >/dev/null 2>&1
assert_eq "verb with no script and no built-in exits 2" "$?" "2"

# Missing tool
if ! PATH=/usr/bin:/bin command -v cargo >/dev/null 2>&1; then
    touch "$rust/.dev/skip"
    rm "$rust/.dev/commands/lint.sh"
    out="$(cd "$rust" && env PATH=/usr/bin:/bin "$DEV" lint 2>&1)"
    assert_eq "missing cargo exits 1" "$?" "1"
    assert_contains "missing cargo prints one install hint" "$out" "Tool cargo not found. Install it with"
fi

wtmain="$(project wtmain)"
git -C "$wtmain" init -q
git -C "$wtmain" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$wtmain" worktree add -q "$TMP/wt" 2>/dev/null
printf '[package]\nname = "wt"\nversion = "0.1.0"\nedition = "2024"\n' >"$TMP/wt/Cargo.toml"
out="$(run_dev "$TMP/wt" builtin:init --dry-run)"
assert_contains "init skips jj in a git worktree" "$out" "this is a git worktree"
assert_not_contains "init plans no jj colocate in a git worktree" "$out" "jj git init --colocate"

if ! PATH=/usr/bin:/bin command -v jj >/dev/null 2>&1; then
    nojj="$(project nojj)"
    git -C "$nojj" init -q
    out="$(cd "$nojj" && env HOME="$nojj" PATH=/usr/bin:/bin "$DEV" builtin:init 2>&1)"
    assert_eq "init without jj exits 0" "$?" "0"
    assert_contains "init without jj skips jj and says why" "$out" "skipped: .jj (jj not installed, git only)"
    assert_contains "init without jj prints the git remote command" "$out" "run: git remote add origin git@github.com:OWNER/nojj.git"
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
assert_contains "git push names the remote and branch" "$out" "Pushed main to origin."
assert_contains "git push -v shows the push command" "$out" "git push -- origin $(git -C "$gp" rev-parse HEAD):refs/heads/main"
assert_eq "git push puts the commit on the remote" "$(git -C "$gremote" rev-parse main)" "$(git -C "$gp" rev-parse HEAD)"
clean="$(git -C "$gp" rev-parse HEAD)"
git init -q --bare -b main "$TMP/gerrit.git"
git -C "$gp" remote add gerrit "$TMP/gerrit.git"
out="$(run_dev "$gp" push gerrit 2>&1)"
assert_eq "push gerrit exits 0" "$?" "0"
assert_contains "push gerrit pushes to gerrit" "$out" "Pushed main to gerrit."
assert_not_contains "push gerrit leaves origin alone" "$out" "to origin."
echo g >"$gp/g"
git -C "$gp" add g
gitc -C "$gp" commit -q -m "feat: only for the remote of record"
second="$(git -C "$gp" rev-parse HEAD)"
out="$(run_dev "$gp" push 2>&1)"
assert_eq "push in a gerrit project exits 0" "$?" "0"
assert_contains "push in a gerrit project names the forge" "$out" "forge gerrit, remote of record gerrit (detected: the project has a gerrit remote)"
assert_contains "push in a gerrit project pushes to gerrit" "$out" "Pushed main to gerrit."
assert_not_contains "push in a gerrit project leaves origin alone" "$out" "to origin."
assert_eq "gerrit gets the new commit" "$(git -C "$TMP/gerrit.git" rev-parse main)" "$second"
assert_eq "origin keeps the old commit" "$(git -C "$gremote" rev-parse main)" "$clean"
git -C "$gp" config forge.kind github
out="$(run_dev "$gp" push 2>&1)"
assert_contains "forge.kind github pushes to origin" "$out" "forge github, remote of record origin (git config forge.kind=github)"
assert_contains "forge.kind github reports the origin push" "$out" "Pushed main to origin."
assert_not_contains "forge.kind github leaves gerrit out" "$out" "to gerrit."
git -C "$gremote" update-ref refs/heads/main "$clean"
git -C "$gp" config forge.kind plain
git -C "$gp" config forge.remote origin
out="$(run_dev "$gp" push 2>&1)"
assert_contains "forge.remote names the remote of record" "$out" "forge plain, remote of record origin (git config forge.kind=plain; remote from git config forge.remote)"
git -C "$gremote" update-ref refs/heads/main "$clean"
git -C "$gp" config forge.remote nosuch
out="$(run_dev "$gp" push 2>&1)"
assert_eq "a remote of record the project lacks exits 1" "$?" "1"
assert_contains "push names the missing remote of record" "$out" "The remote of record nosuch is not a remote of this project"
assert_contains "help push gives the same reason" "$(run_dev "$gp" help push)" "The remote of record nosuch is not a remote"
git -C "$gp" config forge.kind bogus
out="$(run_dev "$gp" push 2>&1)"
assert_eq "an unknown forge exits 1" "$?" "1"
assert_contains "push names the unknown forge" "$out" "Forge must be gerrit, github or plain (got: bogus"
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
assert_eq "push with a bad flag exits 2" "$?" "2"
assert_contains "push names the bad flag" "$out" "dev push: Unknown flag --force"
out="$(run_dev "$gp" pull extra 2>&1)"
assert_eq "pull with an argument exits 2" "$?" "2"
assert_contains "pull names the argument" "$out" "dev pull: Unknown argument extra."

git -C "$gp" checkout -q --detach
out="$(run_dev "$gp" push 2>&1)"
assert_eq "git push on a detached HEAD exits 1" "$?" "1"
assert_contains "git push explains a detached HEAD" "$out" "HEAD is detached"
assert_contains "help push gives the detached HEAD reason" "$(run_dev "$gp" help push)" "HEAD is detached in $gp"
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
preview="$(run_dev "$gp" help push | grep 'git push' | sed 's/^ *//')"
shown="$(run_dev "$gp" -v push 2>&1 | grep '^+ ' | sed 's/^+ //' | grep 'git push')"
assert_eq "help push previews the command push runs" "$preview" "$shown"
assert_contains "help pull shows the git command" "$(run_dev "$gp" help pull)" "pull --rebase origin main"
echo dirty >>"$gp/a"
assert_contains "help pull gives the dirty tree reason" "$(run_dev "$gp" help pull)" "$gp has uncommitted changes"
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
    assert_contains "jj push without a trunk bookmark explains" "$out" "No master or main bookmark in"
    assert_contains "help push gives the same reason push dies with" "$help_out" "No master or main bookmark in"
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
mkdir -p "$nn/.dev/commands/widget"
printf '#!/usr/bin/env bash\n# Save the widget.\n# flag: now kind=boolean\n# flag: later kind=boolean\necho "save $*"\n' >"$nn/.dev/commands/widget/save.sh"
printf '#!/usr/bin/env bash\n# Diff the widget.\necho "diff $*"\n' >"$nn/.dev/commands/widget/diff.sh"
printf '#!/usr/bin/env bash\n# Not executable.\n' >"$nn/.dev/commands/widget/skipped.sh"
printf '#!/usr/bin/env bash\n# Verify prod.\n# flag: fast kind=boolean\necho "verify $*"\n' >"$nn/.dev/commands/verify-prod.sh"
chmod +x "$nn/.dev/commands/widget/save.sh" "$nn/.dev/commands/widget/diff.sh" "$nn/.dev/commands/verify-prod.sh"
out="$(run_dev "$nn" widget save a b)"
assert_eq "a subcommand runs its script with the arguments" "$out" "save a b"
out="$(run_dev "$nn" verify-prod x)"
assert_eq "a flat hyphenated project verb still dispatches" "$out" "verify x"

# shellcheck disable=SC2016  # $* expands in the generated script
printf '#!/usr/bin/env bash\n# Loose words.\necho "loose $*"\n' >"$nn/.dev/commands/loose.sh"

# shellcheck disable=SC2016  # $* expands in the generated script
printf '#!/usr/bin/env bash\n# Strict words.\n# arg: one -- The one word\necho "strict $*"\n' >"$nn/.dev/commands/strict.sh"
chmod +x "$nn/.dev/commands/loose.sh" "$nn/.dev/commands/strict.sh"
assert_eq "a .sh with no # arg: line accepts any words" "$(run_dev "$nn" loose a -- -x b)" "loose a -x b"
assert_eq "a .sh with one # arg: line takes its declared word" "$(run_dev "$nn" strict a)" "strict a"
out="$(run_dev "$nn" strict a b 2>&1)"
assert_contains "one # arg: line turns on strict checking" "$out" "Unexpected argument b."
out="$(run_dev "$nn" help)"
assert_contains "help lists a flat hyphenated verb" "$out" "verify-prod  Verify prod."
assert_contains "help lists the noun" "$out" "  widget "
assert_eq "help lists the noun on one line" "$(printf '%s\n' "$out" | grep -c '^  widget ')" "1"
assert_not_contains "help does not list subcommands as verbs" "$out" "  save "
printf 'Manage the widget.\nmore\n' >"$nn/.dev/commands/widget/DESCRIPTION"
assert_contains "a DESCRIPTION file describes the noun in help" "$(run_dev "$nn" help)" "Manage the widget."
out="$(run_dev "$nn" help widget)"
assert_contains "help <noun> shows the description" "$out" "Manage the widget."
assert_contains "help <noun> lists a subcommand with its description" "$out" "save  "
assert_contains "help <noun> lists the other subcommand" "$out" "Diff the widget."
assert_not_contains "help <noun> hides a script that is not executable" "$out" "skipped"
out="$(run_dev "$nn" help widget save)"
assert_contains "help <noun> <sub> shows the flags" "$out" "--now"
assert_contains "help <noun> <sub> shows the description" "$out" "Save the widget."
out="$(run_dev "$nn" help widget zap 2>&1)"
assert_eq "help <noun> <unknown> exits 2" "$?" "2"
assert_contains "help <noun> <unknown> names it" "$out" "Unknown subcommand zap of widget."
out="$(run_dev "$nn" widget zap 2>&1)"
assert_eq "an unknown subcommand exits 2" "$?" "2"
assert_contains "an unknown subcommand names it" "$out" "dev widget: unknown subcommand zap"
assert_contains "an unknown subcommand lists the choices" "$out" "Save the widget."
out="$(run_dev "$nn" widget 2>&1)"
assert_eq "a noun with no subcommand exits 2" "$?" "2"
assert_contains "a noun with no subcommand says so" "$out" "dev widget: needs a subcommand"
out="$(run_dev "$nn" widget --help)"
assert_eq "noun --help exits 0" "$?" "0"
assert_contains "noun --help lists the subcommands" "$out" "Diff the widget."
out="$(run_dev "$nn" __complete "")"
assert_contains "complete lists a command with subcommands" "$out" "widget	Manage the widget."
assert_contains "complete lists a flat hyphenated command" "$out" "verify-prod	Verify prod."
out="$(run_dev "$nn" __complete widget "")"
assert_eq "complete lists the subcommands with descriptions" "$out" "diff	Diff the widget.
save	Save the widget."
out="$(run_dev "$nn" __complete widget save -)"
assert_contains "complete reads a subcommand script's flags" "$out" "--now"
assert_eq "-v prints the subcommand script on stderr" "$(run_dev "$nn" -v widget save 2>&1 >/dev/null)" "+ .dev/commands/widget/save.sh"
printf '#!/usr/bin/env bash\n# Flat widget.\necho "flat $*"\n' >"$nn/.dev/commands/widget.sh"
chmod +x "$nn/.dev/commands/widget.sh"
assert_eq "a flat script takes the whole noun name" "$(run_dev "$nn" widget save)" "flat save"
rm "$nn/.dev/commands/widget.sh"
nn_none="$(project nonoun)"
mkdir -p "$nn_none/.dev/commands/lint" "$nn_none/.dev/commands/empty"
printf '#!/usr/bin/env bash\necho x\n' >"$nn_none/.dev/commands/lint/x.sh"
chmod +x "$nn_none/.dev/commands/lint/x.sh"
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
case "$1 ${2:-}" in
"run --list"*) printf '{"jobs":[{"name":"lint","targets":["%s"]},{"name":"test","targets":["%s"]},{"name":"widget-save","targets":["%s"]},{"name":"check","targets":["%s"]},{"name":"gadget","targets":["%s"]}]}\n' "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" "$JOB_TARGET" ;;
run*)
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
cirun "$TMP" --remote -C "$sub" lint >/dev/null 2>&1
assert_eq "-C makes --remote run the job for that directory's project" "$(log)" "ci -C $cip [run] [--local] [--follow] [--job] [lint] [--]"
mkdir -p "$cip/.dev/commands"
printf '#!/usr/bin/env bash\n# Print the directory.\npwd -P\n' >"$cip/.dev/commands/where.sh"
chmod +x "$cip/.dev/commands/where.sh"
out="$(cirun "$TMP" -C "$sub" where 2>&1)"
assert_eq "-C runs a local verb in that directory" "$out" "$(cd "$sub" && pwd -P)"
out="$(cd "$cip" && PATH="$cistubs:$STUBS:$PATH" "$DEV" -C sub -C .. where 2>&1)"
assert_eq "-C twice applies each in turn and a relative one starts at the current directory" "$out" "$(cd "$cip" && pwd -P)"
rm "$cip/.dev/commands/where.sh"
cirun "$cip" --remote lint -- -C x >/dev/null 2>&1
assert_eq "-C after -- reaches the job as an argument" "$(log)" "ci -C $cip [run] [--local] [--follow] [--job] [lint] [--] [-C] [x]"
out="$(cirun "$cip" --remote -C "$TMP/no-such-dir" lint 2>&1)"
assert_eq "-C with a missing directory exits 2" "$?" "2"
assert_contains "-C with a missing directory names it" "$out" "The flag \`-C\` cannot enter $TMP/no-such-dir."
assert_eq "-C with a missing directory runs nothing" "$(log)" ""
out="$(cirun "$cip" --remote -C 2>&1)"
assert_eq "-C with no directory exits 2" "$?" "2"
assert_contains "-C with no directory says so" "$out" "The flag \`-C\` needs a directory."
DEV_REMOTE=1 cirun "$cip" test >/dev/null 2>&1
assert_contains "DEV_REMOTE=1 counts as --remote" "$(log)" "[--job] [test]"
DEV_REMOTE=0 cirun "$cip" lint >/dev/null 2>&1
assert_not_contains "DEV_REMOTE=0 runs locally" "$(log)" "[run]"
CI_STUB_RC=7 cirun "$cip" --remote test >/dev/null 2>&1
assert_eq "--remote exits with ci's status" "$?" "7"
cirun "$cip" --remote test -- a "b c" "\$(x)" >/dev/null 2>&1
assert_contains "--remote hands the arguments after -- over as separate words" "$(log)" "[--job] [test] [--] [a] [b c] [\$(x)]"
cirun "$cip" --remote --detach test >/dev/null 2>&1
assert_contains "--detach replaces --follow" "$(log)" "[--detach] [--job] [test]"
assert_not_contains "--detach drops --follow" "$(log)" "[--follow]"
out="$(cirun "$cip" --detach test 2>&1)"
assert_eq "--detach without --remote exits 2" "$?" "2"
assert_contains "--detach without --remote says so" "$out" "The flag \`--detach\` needs \`--remote\`."
assert_eq "--detach without --remote runs nothing" "$(log)" ""
cirun "$cip" --remote --priority test >/dev/null 2>&1
assert_contains "--priority passes --priority to ci run" "$(log)" "[--job] [test] [--priority] [--]"
out="$(cirun "$cip" --priority test 2>&1)"
assert_eq "--priority without --remote exits 2" "$?" "2"
assert_eq "--priority without --remote runs nothing" "$(log)" ""
cirun "$cip" --remote --job-timeout 3600 test >/dev/null 2>&1
assert_contains "--job-timeout 3600 hands ci run --timeout 3600" "$(log)" "[--job] [test] [--timeout] [3600] [--]"
out="$(cirun "$cip" --job-timeout 3600 test 2>&1)"
assert_eq "--job-timeout without --remote exits 2" "$?" "2"
assert_contains "--job-timeout without --remote says so" "$out" "The flag \`--job-timeout\` needs \`--remote\`."
assert_eq "--job-timeout without --remote runs nothing" "$(log)" ""
out="$(cirun "$cip" --remote --job-timeout 2>&1)"
assert_eq "--job-timeout duration missing exits 2" "$?" "2"
assert_contains "--job-timeout duration missing says so" "$out" "The flag \`--job-timeout\` needs a duration."
assert_eq "--job-timeout duration missing runs nothing" "$(log)" ""
out="$(cirun "$cip" --remote --job-timeout -- test 2>&1)"
assert_eq "--job-timeout dashes as the duration exits 2" "$?" "2"
assert_contains "--job-timeout dashes as the duration says so" "$out" "The flag \`--job-timeout\` needs a duration."
assert_eq "--job-timeout dashes as the duration runs nothing" "$(log)" ""

out="$(cirun "$cip" --remote build 2>&1)"
assert_eq "--remote with no such job exits 1" "$?" "1"
assert_contains "--remote with no such job hints at the pipeline" "$out" "No job named build exists in the project's default pipeline (.ci/jobs.lua). Add one"
assert_eq "--remote with no such job runs nothing" "$(log)" ""
out="$(cirun "$cip" --remote lint --extra -- more 2>&1)"
assert_eq "--remote refuses arguments on both sides of -- with 2" "$?" "2"
assert_contains "--remote prints the working command" "$out" "Run \`dev --remote lint -- --extra more\` instead."

mkdir -p "$cip/.dev/commands/widget"
printf '#!/usr/bin/env bash\necho x\n' >"$cip/.dev/commands/widget/save.sh"
chmod +x "$cip/.dev/commands/widget/save.sh"
cirun "$cip" --remote widget save >/dev/null 2>&1
assert_contains "--remote maps a subcommand to the job noun-sub" "$(log)" "[--job] [widget-save]"
out="$(cirun "$cip" --remote widget zap 2>&1)"
assert_eq "--remote with an unknown subcommand exits 2" "$?" "2"
assert_contains "--remote with an unknown subcommand names it" "$out" "unknown subcommand zap"
for verb in fmt fetch help init push pull; do
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

printf '#!/usr/bin/env bash\nexit 99\n' >"$cip/.dev/commands/lint.sh"
mkdir -p "$cip/.dev/helpers"
mkdir -p "$cip/.dev/commands"
cat >"$cip/.dev/helpers/remote.luau" <<'LUA'
return function(run)
    require("@dev/os").stdout:write(table.concat(run.words, " "), "|", table.concat(run.args, ","), "|", tostring(run.detach), "|", run.root, "\n")
    return 5
end
LUA
out="$(cirun "$cip" --remote lint -- a 'b c' 2>&1)"
assert_eq "a helpers/remote.luau runner's integer is the exit code" "$?" "5"
assert_eq "a helpers/remote.luau runner gets words, args, detach and root" "$out" "lint|a,b c|false|$cip"
assert_eq "a helpers/remote.luau runner replaces ci" "$(log)" ""
out="$(cirun "$cip" --remote --detach lint 2>&1)"
assert_contains "a helpers/remote.luau runner sees --detach" "$out" "|true|"
rm "$cip/.dev/helpers/remote.luau"

agent="$(project agent)"
mkdir -p "$agent/.ci" "$agent/.dev/commands"
printf 'return {}\n' >"$agent/.ci/jobs.lua"
git -C "$agent" init -q
printf '#!/usr/bin/env bash\necho check ran\n' >"$agent/.dev/commands/check.sh"
printf '#!/usr/bin/env bash\n# runs_local\necho gadget ran\n' >"$agent/.dev/commands/gadget.sh"
printf '#!/usr/bin/env bash\necho notes ran\n' >"$agent/.dev/commands/notes.sh"
chmod +x "$agent/.dev/commands/check.sh" "$agent/.dev/commands/gadget.sh" "$agent/.dev/commands/notes.sh"
touch "$TMP/ci-box"
out="$(DEV_AGENT=w cirun "$agent" --local check 2>&1)"
assert_eq "an agent's --local run of a verb with a ci job exits 2" "$?" "2"
assert_contains "an agent's --local refusal names dev --remote" "$out" "dev check: DEV_AGENT is set. Use \`dev --remote check\` instead, which runs it on ci."
assert_not_contains "an agent's --local refusal runs nothing" "$out" "check ran"
out="$(DEV_AGENT=w cirun "$agent" check 2>&1)"
assert_eq "an agent's DEV_REMOTE=0 run of a verb with a ci job exits 2" "$?" "2"
assert_contains "an agent's DEV_REMOTE=0 refusal names dev --remote" "$out" "dev check: DEV_AGENT is set. Use \`dev --remote check\` instead, which runs it on ci."
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
mkdir -p "$TMP/agent-home"
out="$(HOME="$TMP/agent-home" DEV_REMOTE='' DEV_AGENT=w cirun "$agent" check 2>&1)"
assert_eq "an agent's default run of a verb with a ci job still goes to ci" "$?" "0"
assert_contains "an agent's default run goes to ci with remote default remote" "$(log)" "[--job] [check]"
agentlocal="$(project agentlocal)"
mkdir -p "$agentlocal/.ci" "$agentlocal/.dev/commands"
printf 'return {}\n' >"$agentlocal/.ci/jobs.lua"
git -C "$agentlocal" init -q
printf '[remote]\ndefault = "local"\n' >"$agentlocal/.dev/config.toml"
printf '#!/usr/bin/env bash\necho check ran\n' >"$agentlocal/.dev/commands/check.sh"
printf '#!/usr/bin/env bash\n# runs_local\necho gadget ran\n' >"$agentlocal/.dev/commands/gadget.sh"
chmod +x "$agentlocal/.dev/commands/check.sh" "$agentlocal/.dev/commands/gadget.sh"
out="$(HOME="$TMP/agent-home" DEV_REMOTE='' DEV_AGENT=w cirun "$agentlocal" check 2>&1)"
assert_eq "an agent's default run of a verb with a ci job under remote default local exits 2" "$?" "2"
assert_contains "an agent's default refusal under remote default local names dev --remote" "$out" "dev check: DEV_AGENT is set. Use \`dev --remote check\` instead, which runs it on ci."
assert_not_contains "an agent's default refusal under remote default local runs nothing" "$out" "check ran"
out="$(HOME="$TMP/agent-home" DEV_REMOTE='' DEV_AGENT=w cirun "$agentlocal" gadget 2>&1)"
assert_contains "an agent's default run of a # local verb under remote default local runs here" "$out" "gadget ran"
out="$(HOME="$TMP/agent-home" DEV_REMOTE='' cirun "$agentlocal" check 2>&1)"
assert_contains "DEV_AGENT unset runs a default run here under remote default local" "$out" "check ran"

prim="$(project prim)"
mkdir -p "$prim/.dev/commands"
git -C "$prim" init -q
printf '#!/usr/bin/env bash\n# requires: workspace\necho install ran\n' >"$prim/.dev/commands/install.sh"
printf '#!/usr/bin/env bash\necho notes ran\n' >"$prim/.dev/commands/notes.sh"
chmod +x "$prim/.dev/commands/install.sh" "$prim/.dev/commands/notes.sh"
git -C "$prim" add -A
git -C "$prim" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$prim" worktree add -q "$TMP/primwt" 2>/dev/null
out="$(DEV_AGENT=repo/implementer/c cirun "$prim" install 2>&1)"
assert_eq "workspace role install in the primary checkout exits 2" "$?" "2"
assert_contains "workspace role refusal names the verb and dev -C WS" "$out" "dev install: DEV_AGENT is the workspace role implementer, which never runs it in the primary checkout. Use \`dev -C WS install\` from your own workspace."
assert_not_contains "workspace role install in the primary checkout runs nothing" "$out" "install ran"
out="$(DEV_AGENT=repo/runner/c cirun "$prim" install 2>&1)"
assert_eq "runner role install in the primary checkout exits 2" "$?" "2"
assert_not_contains "runner role install in the primary checkout runs nothing" "$out" "install ran"
for role in planner reviewer verifier; do
    out="$(DEV_AGENT=repo/$role/c cirun "$prim" install 2>&1)"
    assert_eq "the $role role is refused in the primary checkout" "$?" "2"
done
out="$(DEV_AGENT=repo/lead/c cirun "$prim" land 2>&1)"
assert_eq "the lead role land in the primary checkout exits 2" "$?" "2"
assert_contains "the lead role land refusal says the lead role" "$out" "dev land: DEV_AGENT is the lead role, which never runs it in the primary checkout. Use \`dev -C WS land\` from your own workspace."
assert_not_contains "the lead role land refusal does not call lead a workspace role" "$out" "workspace role lead"
out="$(DEV_AGENT=repo/lead/c cirun "$prim" clean 2>&1)"
assert_eq "the lead role clean in the primary checkout exits 2" "$?" "2"
out="$(DEV_AGENT=repo/lead/c cirun "$prim" fmt 2>&1)"
assert_eq "the lead role fmt in the primary checkout exits 2" "$?" "2"
out="$(DEV_AGENT=repo/implementer/c cirun "$prim" tools install 2>&1)"
assert_eq "workspace role tools install in the primary checkout exits 2" "$?" "2"
assert_contains "workspace role tools install refusal names both words" "$out" "dev tools install: DEV_AGENT is the workspace role"
out="$(DEV_AGENT=repo/implementer/c cirun "$prim" board land 2>&1)"
assert_eq "workspace role board land in the primary checkout exits 2" "$?" "2"
assert_contains "workspace role board land refusal names both words" "$out" "dev board land: DEV_AGENT is the workspace role"
out="$(DEV_AGENT=repo/implementer/c cirun "$prim" notes 2>&1)"
assert_contains "workspace role read only verb in the primary checkout runs" "$out" "notes ran"
out="$(DEV_AGENT=repo/lead cirun "$prim" install 2>&1)"
assert_contains "the lead role install in the primary checkout runs" "$out" "install ran"
out="$(cirun "$prim" install 2>&1)"
assert_contains "lead and human install in the primary checkout run for a human" "$out" "install ran"
out="$(DEV_AGENT=repo/implementer/c cirun "$TMP/primwt" install 2>&1)"
assert_contains "workspace role install in a git worktree runs" "$out" "install ran"
out="$(DEV_AGENT=repo/implementer/c cirun "$TMP" -C "$TMP/primwt" install 2>&1)"
assert_contains "workspace role install with C on a worktree runs" "$out" "install ran"
out="$(DEV_AGENT=repo/implementer/c cirun "$TMP" -C "$prim" install 2>&1)"
assert_eq "workspace role install with -C on the primary checkout exits 2" "$?" "2"
out="$(DEV_AGENT=repo/implementer/c DEV_BOX_MARKER="$TMP/ci-box" cirun "$prim" install 2>&1)"
assert_contains "the box marker runs a workspace role install in the primary checkout" "$out" "install ran"
bprim="$(project repoguard)"
mkdir -p "$bprim/.dev/commands"
git -C "$bprim" init -q
printf '[agent]\nprimary_guarded = ["bump"]\n' >"$bprim/.dev/config.toml"
printf '#!/usr/bin/env bash\necho bump ran\n' >"$bprim/.dev/commands/bump.sh"
printf '#!/usr/bin/env bash\necho capture ran\n' >"$bprim/.dev/commands/capture.sh"
chmod +x "$bprim/.dev/commands/bump.sh" "$bprim/.dev/commands/capture.sh"
git -C "$bprim" add -A
git -C "$bprim" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$bprim" worktree add -q "$TMP/bprimwt" 2>/dev/null
out="$(DEV_AGENT=repo/implementer/c cirun "$bprim" bump 2>&1)"
assert_eq "a repo guarded verb in the primary checkout exits 2" "$?" "2"
assert_contains "a repo guarded verb names agent.primary_guarded and dev -C WS" "$out" "dev bump: the repo's \`agent.primary_guarded\` lists it, and DEV_AGENT never runs it in the primary checkout. Use \`dev -C WS bump\` from your own workspace."
assert_not_contains "a repo guarded verb in the primary checkout runs nothing" "$out" "bump ran"
out="$(DEV_AGENT=repo/lead/c cirun "$bprim" bump 2>&1)"
assert_eq "a repo guarded verb is refused for the lead role" "$?" "2"
assert_not_contains "a repo guarded verb is refused for the lead role and runs nothing" "$out" "bump ran"
out="$(DEV_AGENT=repo/implementer/c cirun "$bprim" capture 2>&1)"
assert_contains "a repo verb not in the guarded list runs in the primary checkout" "$out" "capture ran"
out="$(DEV_AGENT=repo/implementer/c cirun "$TMP/bprimwt" bump 2>&1)"
assert_contains "a repo guarded verb in a worktree runs" "$out" "bump ran"
out="$(cirun "$bprim" bump 2>&1)"
assert_contains "a repo guarded verb runs for a human" "$out" "bump ran"
badp="$(project repobad)"
mkdir -p "$badp/.dev/commands"
printf '[agent]\nprimary_guarded = "bump"\n' >"$badp/.dev/config.toml"
out="$(DEV_AGENT=repo/implementer/c cirun "$badp" bump 2>&1)"
assert_contains "a non-list agent.primary_guarded is a malformed config" "$out" "must be a list of command names."

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall dev tests passed\n'
