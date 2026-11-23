#!/usr/bin/env bash
# Pure-bash tests for the dev launcher. A stub id says 0 so the launcher sees root, a stub luajit records its environment,
# and a PATH without luajit checks the missing-luajit line.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd -P)"
DEV="$REPO/bin/dev"
SHARE_MAIN="$REPO/main.lua"

# shellcheck source=tests/dev/stage.bash
source "$DIR/stage.bash"
unset DOTFILES VERBOSE DEV_UID DEV_OS LUA_INIT LUA_PATH LUA_CPATH CI
export DEV_REMOTE=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_LUAJIT="$(command -v luajit)"
NOLUA="$TMP/nolua"
ROOTID="$TMP/rootid"
RECORDER="$TMP/recorder"
ROOT_REFUSAL="As root, dev runs only \`dev tools install\` and \`dev tools check\`."
mkdir -p "$NOLUA" "$ROOTID" "$RECORDER"
for tool in bash env id realpath dirname uname cat awk sed grep tr cut sort head tail paste wc basename stat date mktemp rm; do
    found="$(command -v "$tool")" && ln -s "$found" "$NOLUA/$tool"
done
printf '#!/bin/sh\necho 0\n' >"$ROOTID/id"
cat >"$RECORDER/luajit" <<'STUB'
#!/bin/sh
env >"$ENV_OUT"
echo "$*" >"$ARGS_OUT"
STUB
chmod +x "$ROOTID/id" "$RECORDER/luajit"
export ENV_OUT="$TMP/env.out" ARGS_OUT="$TMP/args.out"

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

system_launcher() {
    local dir="$TMP/lc-$1"
    mkdir -p "$dir/bin"
    sed "s|^SYSTEM_BIN_DIRS=.*|SYSTEM_BIN_DIRS=($2)|" "$DEV" >"$dir/bin/dev"
    chmod +x "$dir/bin/dev"
    mkdir -p "$dir/share"
    ln -s "$REPO" "$dir/share/dev"
    printf "%s\n" "$dir/bin/dev"
}
LC_REC="$(system_launcher rec "$RECORDER")"
mkdir -p "$TMP/realjit"
ln -s "$REAL_LUAJIT" "$TMP/realjit/luajit"
LC_REAL="$(system_launcher real "$TMP/realjit")"
LC_NONE="$(system_launcher none "$TMP/nowhere")"

missing="Luajit is not found. Install it with \`brew install luajit\`, \`pacman -S luajit\`, \`dnf install luajit\` or \`apt install luajit\`."
out="$(PATH="$NOLUA" "$DEV" lint 2>&1)"
assert_eq "no luajit exits 1" "$?" "1"
assert_eq "no luajit prints the one line" "$out" "$missing"

for name in BASH_ENV ENV LUA_PATH LUA_CPATH LUA_INIT LUA_PATH_5_1 LUA_CPATH_5_1 LUA_INIT_5_1 LUA_PATH_5_2 LUA_CPATH_5_2 LUA_INIT_5_2 DEV_UID DEV_OS; do
    rm -f "$ENV_OUT"
    env "$name=hostile" PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_REC" help >/dev/null 2>&1
    assert_eq "root drops $name" "$(grep -c "^$name=" "$ENV_OUT")" "0"
    rm -f "$ENV_OUT"
    env "$name=kept" PATH="$RECORDER:$NOLUA" "$DEV" help >/dev/null 2>&1
    assert_eq "a user keeps $name" "$(grep -c "^$name=kept" "$ENV_OUT")" "1"
done

assert_eq "the launcher exports its real path" "$(grep '^DEV_SELF=' "$ENV_OUT")" "DEV_SELF=$DEV"
assert_eq "the launcher hands luajit main.lua and the arguments" "$(cat "$ARGS_OUT")" "$SHARE_MAIN help"

rm -f "$ENV_OUT"
out="$(PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_NONE" lint 2>&1)"
assert_eq "root without a system luajit refuses a verb with exit 2" "$?" "2"
assert_eq "root without a system luajit gets the root refusal" "$out" "$ROOT_REFUSAL"
assert_eq "root never runs a luajit found on PATH" "$([ -e "$ENV_OUT" ] && echo ran || echo absent)" "absent"
out="$(DEV_UID=1000 PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_NONE" lint 2>&1)"
assert_eq "root without a system luajit ignores an inherited DEV_UID" "$?" "2"
rm -f "$ENV_OUT"
out="$(PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_REC" help 2>&1)"
assert_eq "root runs the luajit from the system directory" "$([ -e "$ENV_OUT" ] && echo ran || echo absent)" "ran"

for flag in -h --help -v -vv -vvv --verbose --remote; do
    rm -f "$ARGS_OUT"
    PATH="$RECORDER:$NOLUA" "$DEV" lint "$flag" >/dev/null 2>&1
    assert_eq "lint $flag goes to main.lua" "$(cat "$ARGS_OUT")" "$SHARE_MAIN lint $flag"
done

mkdir -p "$TMP/spy"
cat >"$TMP/spy/realpath" <<'STUB'
#!/bin/sh
echo spied >>"$SPY_OUT"
exec /usr/bin/realpath "$@"
STUB
chmod +x "$TMP/spy/realpath"
export SPY_OUT="$TMP/spy.out"
rm -f "$SPY_OUT"
PATH="$ROOTID:$TMP/spy:$NOLUA" "$LC_REC" help >/dev/null 2>&1
assert_eq "root resolves realpath from the system PATH, not the caller's" "$([ -e "$SPY_OUT" ] && echo spied || echo clean)" "clean"
rm -f "$SPY_OUT"
PATH="$TMP/spy:$NOLUA" "$LC_REC" help >/dev/null 2>&1
assert_eq "a user resolves realpath from PATH" "$([ -e "$SPY_OUT" ] && echo spied || echo clean)" "spied"

marker="$TMP/marker"
printf 'io.open("%s", "w"):close()\n' "$marker" >"$TMP/init.lua"
out="$(PATH="$ROOTID:$TMP/realjit:$NOLUA:/usr/bin:/bin" LUA_INIT="@$TMP/init.lua" "$LC_REAL" help 2>&1)"
assert_eq "root never runs LUA_INIT" "$([ -e "$marker" ] && echo written || echo absent)" "absent"
out="$(PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" LUA_INIT="@$TMP/init.lua" "$DEV" help 2>&1)"
assert_eq "a user does run LUA_INIT" "$([ -e "$marker" ] && echo written || echo absent)" "written"

out="$(PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=0 FAKE_OS=Linux "$DEV" help 2>&1)"
assert_eq "a fake uid of 0 is refused with exit 2" "$?" "2"
assert_contains "the fake root gets the root refusal" "$out" "$ROOT_REFUSAL"
out="$(PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=0 FAKE_OS=Darwin "$DEV" tools check 2>&1)"
assert_contains "a fake OS of Darwin refuses root" "$out" "As root, dev runs only on Linux."

out="$(DEV_UID=0 DEV_OS=Plan9 PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" bash -c 'cd "$1" && "$2" help' _ "$REPO" "$DEV" 2>&1)"
assert_eq "main.lua replaces a DEV_UID and DEV_OS from the caller" "$?" "0"
assert_contains "a user with a forged DEV_UID still gets help" "$out" "lint"

mkdir -p "$TMP/with space"
ln -s "$DEV" "$TMP/with space/dev"
out="$(cd "$REPO" && PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" "$TMP/with space/dev" help 2>&1)"
assert_eq "a symlink under a path with a space runs" "$?" "0"
assert_contains "the symlinked launcher lists verbs" "$out" "lint"

NOPROJ="$TMP/noproj"
mkdir -p "$NOPROJ"
out="$(cd "$NOPROJ" && PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" "$TMP/with space/dev" help --topics 2>&1)"
assert_contains "the symlinked launcher finds the built-in topics" "$out" "remote"

CLONE="$TMP/a clone"
mkdir -p "$CLONE/bin"
cp "$DEV" "$CLONE/bin/dev"
stage_share "$CLONE"
out="$(cd "$NOPROJ" && PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" "$CLONE/bin/dev" help --topics 2>&1)"
assert_contains "a clone under a path with a space finds the built-in topics" "$out" "remote"

CIBIN="$TMP/cibin"
CILOG="$TMP/ci.log"
PROJ="$TMP/ciproj"
mkdir -p "$CIBIN" "$PROJ/.dev/widget"
cat >"$CIBIN/ci" <<'STUB'
#!/bin/sh
echo "ci $*" >>"$CI_LOG"
[ "$3" = run ] && [ "$4" = --list ] && echo '{"jobs":[]}'
exit 0
STUB
chmod +x "$CIBIN/ci"
printf '#!/bin/sh\ntouch "%s"\n' "$TMP/widget-marker" >"$PROJ/.dev/widget/save.sh"
chmod +x "$PROJ/.dev/widget/save.sh"
export CI_LOG="$CILOG"

# ran_nothing <desc>: the ci log and the markers are all absent.
ran_nothing() {
    local seen=absent
    if [ -e "$CILOG" ] || [ -e "$TMP/widget-marker" ]; then seen=ran; fi
    assert_eq "$1 ran nothing" "$seen" "absent"
    rm -f "$CILOG" "$TMP/widget-marker"
}

rm -f "$CILOG" "$TMP/widget-marker"

out="$(cd "$TMP" && PATH="$NOLUA" "$DEV" -C nope lint 2>&1)"
assert_eq "-C with a relative directory it cannot enter exits 2" "$?" "2"
assert_eq "-C names a relative directory as it was given" "$out" "The flag \`-C\` cannot enter nope."
out="$(PATH="$NOLUA" "$DEV" -C "" lint 2>&1)"
assert_eq "-C with an empty word exits 2" "$?" "2"
assert_eq "-C with an empty word says it needs a directory" "$out" "The flag \`-C\` needs a directory."

rm -f "$ENV_OUT"
PATH="$RECORDER:$NOLUA" "$DEV" --agent dotfiles/implementer/x lint >/dev/null 2>&1
assert_eq "--agent exports DEV_AGENT to the verb" "$(grep '^DEV_AGENT=' "$ENV_OUT")" "DEV_AGENT=dotfiles/implementer/x"
assert_eq "--agent is taken out of the arguments" "$(sed "s/^[^ ]* //" "$ARGS_OUT")" "lint"
out="$(PATH="$NOLUA" "$DEV" --agent "" lint 2>&1)"
assert_eq "--agent with an empty word exits 2" "$?" "2"
assert_eq "--agent with an empty word says it needs a name" "$out" "The --agent flag needs a name."
out="$(PATH="$NOLUA" "$DEV" lint --agent 2>&1)"
assert_eq "--agent with no word after it exits 2" "$?" "2"
assert_eq "--agent with no word after it says it needs a name" "$out" "The --agent flag needs a name."

NOJIT="$CIBIN:$NOLUA"
remote_missing="The flag \`--remote\` needs luajit. Install it with \`brew install luajit\`, \`pacman -S luajit\`, \`dnf install luajit\` or \`apt install luajit\`."
out="$(cd "$PROJ" && PATH="$NOJIT" "$DEV" lint --remote 2>&1)"
assert_eq "no luajit, dev lint --remote exits 1" "$?" "1"
assert_eq "no luajit, dev lint --remote says --remote needs luajit" "$out" "$remote_missing"
ran_nothing "no luajit with --remote"
out="$(cd "$PROJ" && PATH="$NOJIT" DEV_REMOTE=1 "$DEV" lint -v 2>&1)"
assert_eq "no luajit, DEV_REMOTE=1 dev lint -v exits 1" "$?" "1"
assert_eq "no luajit, DEV_REMOTE=1 dev lint -v says --remote needs luajit" "$out" "$remote_missing"

for words in "--remote tools install" "lint --detach" "lint --priority"; do
    # shellcheck disable=SC2086
    out="$(cd "$PROJ" && PATH="$ROOTID:$CIBIN:$NOLUA" "$LC_NONE" $words 2>&1)"
    assert_eq "root without luajit, dev $words exits 2" "$?" "2"
    assert_eq "root without luajit, dev $words gets the root refusal" "$out" "$ROOT_REFUSAL"
    ran_nothing "root without luajit, dev $words"
done
out="$(cd "$PROJ" && PATH="$ROOTID:$CIBIN:$NOLUA" DEV_REMOTE=1 "$LC_NONE" tools check 2>&1)"
assert_eq "root without luajit, DEV_REMOTE=1 exits 2" "$?" "2"
assert_eq "root without luajit, DEV_REMOTE=1 gets the root refusal" "$out" "$ROOT_REFUSAL"
ran_nothing "root without luajit, DEV_REMOTE"

SNAPHOME="$TMP/snaphome"
SNAP="$SNAPHOME/.local/state/dev/snapshot"
for version in v1 v2; do
    mkdir -p "$SNAP/versions/$version/lua"
    printf 'return "%s"\n' "$version" >"$SNAP/versions/$version/lua/mod.lua"
    printf '%s\n' "$REPO" >"$SNAP/versions/$version/ORIGIN"
    cat >"$SNAP/versions/$version/main.lua" <<'LUA'
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
package.path = here .. "/lua/?.lua"
local snap = os.getenv("SNAP")
if os.getenv("SWAP") then
    assert(os.rename(snap .. "/current.new", snap .. "/current"))
end
print(require("mod"))
LUA
done
V1_REAL="$(cd -P "$SNAP/versions/v1" && pwd -P)"
snap_dev() {
    env -u XDG_STATE_HOME -u DEV_FROM HOME="$SNAPHOME" SNAP="$SNAP" PATH="$TMP/realjit:$NOLUA" "$@"
}
snap_rec() {
    env -u XDG_STATE_HOME -u DEV_FROM HOME="$SNAPHOME" PATH="$RECORDER:$NOLUA" "$@"
}

rm -f "$ARGS_OUT"
snap_rec "$DEV" help >/dev/null 2>&1
assert_eq "with no snapshot luajit gets the checkout main.lua" "$(cat "$ARGS_OUT")" "$SHARE_MAIN help"

ln -s versions/v1 "$SNAP/current"
rm -f "$ARGS_OUT" "$ENV_OUT"
snap_rec "$DEV" help >/dev/null 2>&1
assert_eq "a snapshot gives luajit its resolved version directory" "$(cat "$ARGS_OUT")" "$V1_REAL/main.lua help"
assert_eq "a snapshot run still reports the checkout launcher as DEV_SELF" "$(grep '^DEV_SELF=' "$ENV_OUT")" "DEV_SELF=$DEV"

rm -f "$ARGS_OUT"
snap_rec DEV_FROM=checkout "$DEV" help >/dev/null 2>&1
assert_eq "DEV_FROM=checkout runs the checkout copy" "$(cat "$ARGS_OUT")" "$SHARE_MAIN help"

LC_CHECKOUT="$(cd "$(dirname "$LC_REC")/.." && pwd -P)"
printf '%s\n' "$LC_CHECKOUT" >"$SNAP/versions/v1/ORIGIN"
rm -f "$ARGS_OUT"
env -u XDG_STATE_HOME -u DEV_FROM HOME="$SNAPHOME" PATH="$RECORDER:$NOLUA" "$LC_REC" help >/dev/null 2>&1
assert_eq "a user's launcher takes a snapshot published from its checkout" "$(cat "$ARGS_OUT")" "$V1_REAL/main.lua help"
rm -f "$ARGS_OUT"
env -u XDG_STATE_HOME -u DEV_FROM HOME="$SNAPHOME" PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_REC" help >/dev/null 2>&1
assert_eq "root ignores the snapshot" "$(cat "$ARGS_OUT")" "$SHARE_MAIN help"
printf '%s\n' "$REPO" >"$SNAP/versions/v1/ORIGIN"

printf '%s\n' "$TMP/elsewhere" >"$SNAP/versions/v1/ORIGIN"
rm -f "$ARGS_OUT"
snap_rec "$DEV" help >/dev/null 2>&1
assert_eq "a snapshot published from another checkout is ignored" "$(cat "$ARGS_OUT")" "$SHARE_MAIN help"
printf '%s\n' "$REPO" >"$SNAP/versions/v1/ORIGIN"

rm -f "$ARGS_OUT"
env -u DEV_FROM HOME="$SNAPHOME" XDG_STATE_HOME=relative/state PATH="$RECORDER:$NOLUA" "$DEV" help >/dev/null 2>&1
assert_eq "a relative XDG_STATE_HOME falls back to the home state directory" "$(cat "$ARGS_OUT")" "$V1_REAL/main.lua help"

ln -s versions/v2 "$SNAP/current.new"
out="$(SWAP=1 snap_dev "$DEV" help 2>&1)"
assert_eq "a run whose snapshot is swapped under it loads every module from its own version" "$out" "v1"
out="$(snap_dev "$DEV" help 2>&1)"
assert_eq "the next run starts on the swapped snapshot" "$out" "v2"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall launcher tests passed\n'
