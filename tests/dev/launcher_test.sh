#!/usr/bin/env bash
# Pure-bash tests for the dev launcher. A stub id says 0 so the launcher sees root, a stub luajit records its environment,
# and a PATH without luajit checks the missing-luajit line and the bootstrap route.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE DEV_UID DEV_OS LUA_INIT LUA_PATH LUA_CPATH

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_LUAJIT="$(command -v luajit)"
NOLUA="$TMP/nolua"
ROOTID="$TMP/rootid"
RECORDER="$TMP/recorder"
FAKE_DOTFILES="$TMP/dotfiles"
mkdir -p "$NOLUA" "$ROOTID" "$RECORDER" "$FAKE_DOTFILES"
for tool in bash env id realpath dirname uname cat awk sed grep tr cut sort head tail paste wc basename stat date mktemp rm; do
    found="$(command -v "$tool")" && ln -s "$found" "$NOLUA/$tool"
done
printf '#!/bin/sh\necho 0\n' >"$ROOTID/id"
cat >"$RECORDER/luajit" <<'STUB'
#!/bin/sh
env >"$ENV_OUT"
echo "$*" >"$ARGS_OUT"
STUB
printf '#!/bin/sh\necho "bootstrap plan (dry run, nothing will change)"\necho "args: $*"\n' >"$FAKE_DOTFILES/bootstrap.sh"
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
    ln -s "$REPO/dotfiles/bin/.local/share" "$dir/share"
    printf "%s\n" "$dir/bin/dev"
}
LC_REC="$(system_launcher rec "$RECORDER")"
mkdir -p "$TMP/realjit"
ln -s "$REAL_LUAJIT" "$TMP/realjit/luajit"
LC_REAL="$(system_launcher real "$TMP/realjit")"
LC_NONE="$(system_launcher none "$TMP/nowhere")"

missing='dev: luajit not found. Run dev bootstrap, or install it with brew install luajit, pacman -S luajit or dnf install luajit'
out="$(PATH="$NOLUA" "$DEV" lint 2>&1)"
assert_eq "no luajit exits 1" "$?" "1"
assert_eq "no luajit prints the one line" "$out" "$missing"

out="$(PATH="$NOLUA" DOTFILES="$FAKE_DOTFILES" "$DEV" bootstrap --dry-run 2>&1)"
assert_eq "bootstrap needs no luajit" "$?" "0"
assert_contains "bootstrap prints the plan" "$out" "bootstrap plan (dry run, nothing will change)"
assert_contains "bootstrap passes its arguments on" "$out" "args: --dry-run"

out="$(PATH="$ROOTID:$NOLUA" DOTFILES="$FAKE_DOTFILES" "$DEV" bootstrap --dry-run 2>&1)"
assert_eq "root is refused bootstrap with exit 2" "$?" "2"
assert_eq "root gets the refusal line" "$out" "dev: as root, dev runs only tools install and tools check"

for name in BASH_ENV ENV LUA_PATH LUA_CPATH LUA_INIT LUA_PATH_5_1 LUA_CPATH_5_1 LUA_INIT_5_1 LUA_PATH_5_2 LUA_CPATH_5_2 LUA_INIT_5_2 DEV_UID DEV_OS; do
    rm -f "$ENV_OUT"
    env "$name=hostile" PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_REC" help >/dev/null 2>&1
    assert_eq "root drops $name" "$(grep -c "^$name=" "$ENV_OUT")" "0"
    rm -f "$ENV_OUT"
    env "$name=kept" PATH="$RECORDER:$NOLUA" "$DEV" help >/dev/null 2>&1
    assert_eq "a user keeps $name" "$(grep -c "^$name=kept" "$ENV_OUT")" "1"
done

assert_eq "the launcher exports its real path" "$(grep '^DEV_SELF=' "$ENV_OUT")" "DEV_SELF=$DEV"
assert_eq "the launcher hands luajit main.lua and the arguments" "$(cat "$ARGS_OUT")" "$REPO/dotfiles/bin/.local/bin/../share/dev/main.lua help"

rm -f "$ENV_OUT"
out="$(PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_NONE" help 2>&1)"
assert_eq "root without a system luajit still runs legacy" "$?" "0"
assert_contains "root without a system luajit reaches legacy and lists verbs" "$out" "lint"
assert_eq "root never runs a luajit found on PATH" "$([ -e "$ENV_OUT" ] && echo ran || echo absent)" "absent"
out="$(DEV_UID=0 PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_NONE" help 2>&1)"
assert_eq "root without a system luajit ignores an inherited DEV_UID" "$?" "0"
rm -f "$ENV_OUT"
out="$(PATH="$ROOTID:$RECORDER:$NOLUA" "$LC_REC" help 2>&1)"
assert_eq "root runs the luajit from the system directory" "$([ -e "$ENV_OUT" ] && echo ran || echo absent)" "ran"

out="$(PATH="$NOLUA" "$DEV" bootstrap --help 2>&1)"
assert_eq "bootstrap --help without luajit exits 0" "$?" "0"
assert_contains "bootstrap --help without luajit prints dev's own help" "$out" "dev bootstrap [--dry-run] [--no-login]"
for flag in -h --help -v -vv -vvv --verbose --ci; do
    rm -f "$ARGS_OUT"
    PATH="$RECORDER:$NOLUA" DOTFILES="$FAKE_DOTFILES" "$DEV" bootstrap "$flag" >/dev/null 2>&1
    assert_eq "bootstrap $flag goes to main.lua" "$(cat "$ARGS_OUT")" "$REPO/dotfiles/bin/.local/bin/../share/dev/main.lua bootstrap $flag"
done
out="$(PATH="$RECORDER:$NOLUA" DOTFILES="$FAKE_DOTFILES" "$DEV" bootstrap --dry-run -- --help 2>&1)"
assert_contains "bootstrap routes its own arguments after --" "$out" "args: --dry-run -- --help"

REALPATH="$TMP/realjit:$NOLUA:/usr/bin:/bin"
out="$(cd "$REPO" && PATH="$REALPATH" "$DEV" bootstrap --help 2>&1)"
assert_contains "bootstrap --help prints dev's own help" "$out" "dev bootstrap [--dry-run] [--no-login]"
out="$(cd "$REPO" && PATH="$REALPATH" "$DEV" bootstrap -h 2>&1)"
assert_contains "bootstrap -h prints dev's own short help" "$out" "dev bootstrap [--dry-run] [--no-login]"
out="$(cd "$REPO" && PATH="$REALPATH" "$DEV" bootstrap --ci 2>&1)"
assert_eq "--ci refuses bootstrap with exit 2" "$?" "2"
assert_contains "--ci names bootstrap as machine-local" "$out" "dev bootstrap: --ci cannot run this verb"
out="$(cd "$REPO" && PATH="$REALPATH" DOTFILES="$FAKE_DOTFILES" "$DEV" bootstrap -v --dry-run 2>&1)"
assert_contains "bootstrap -v is a global flag and still reaches bootstrap.sh" "$out" "args: --dry-run"

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
assert_eq "a fake uid of 0 reaches legacy and is refused with exit 2" "$?" "2"
assert_contains "the fake root gets the root refusal" "$out" "as root, dev runs only tools install and tools check"
out="$(PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=0 FAKE_OS=Darwin "$DEV" tools check 2>&1)"
assert_contains "a fake OS of Darwin reaches legacy and root is refused" "$out" "as root, dev runs only on Linux"

out="$(DEV_UID=0 DEV_OS=Plan9 PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" bash -c 'cd "$1" && "$2" help' _ "$REPO" "$DEV" 2>&1)"
assert_eq "main.lua replaces a DEV_UID and DEV_OS from the caller" "$?" "0"
assert_contains "a user with a forged DEV_UID still gets help" "$out" "lint"

mkdir -p "$TMP/with space"
ln -s "$DEV" "$TMP/with space/dev"
out="$(cd "$REPO" && PATH="$TMP/realjit:$NOLUA:/usr/bin:/bin" "$TMP/with space/dev" help 2>&1)"
assert_eq "a symlink under a path with a space runs" "$?" "0"
assert_contains "the symlinked launcher lists verbs" "$out" "lint"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall launcher tests passed\n'
