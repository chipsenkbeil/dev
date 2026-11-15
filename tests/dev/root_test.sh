#!/usr/bin/env bash
# Pure-bash tests for dev as root. LUA_INIT loads tests/lua/fake_env.lua, so FAKE_UID says 0 and FAKE_OS says Linux, and jj and git are stubs
# that log every call and fail,
# so a log line means dev ran a VCS command with a project it must treat as data.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE

TMP="$(mktemp -d)"
chmod 755 "$TMP"
if [ "$EUID" -eq 0 ]; then REAL_ROOT=1; else REAL_ROOT=0; fi
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=0 FAKE_OS=Linux
export VCSLOG="$TMP/vcs.log" RECORD="$TMP/record"
mkdir -p "$STUBS"
for tool in jj git; do
    cat >"$STUBS/$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >>"\$VCSLOG"
exit 1
STUB
done
cat >"$STUBS/pacman" <<'STUB'
#!/bin/sh
[ "$1" != -Q ]
STUB
chmod +x "$STUBS"/*

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

# dev <dir> <args...>: run dev in dir with the stubs first on PATH, the log cleared.
dev() {
    local dir="$1"
    shift
    : >"$VCSLOG"
    (cd "$dir" && PATH="$STUBS:$PATH" "$DEV" "$@")
}

MSG="as root, dev runs only tools install and tools check"
MANIFEST='name binary pacman
zzz-tool zzz-tool-not-here zzz-tool'

outside="$TMP/outside"
mkdir -p "$outside/dir"
printf 'SECRET-MARKER\n%s\n' "$MANIFEST" >"$outside/tools.tsv"
printf 'SECRET-MARKER\n%s\n' "$MANIFEST" >"$outside/dir/tools.tsv"
printf 'SECRET-MARKER\n' >"$outside/shadow"
printf '#!/bin/sh\n# SECRET-MARKER\n' >"$outside/dir/bar.sh"

proj="$TMP/proj"
mkdir -p "$proj/.jj" "$proj/.dev/n" "$proj/a/b"
printf '%s\n' "$MANIFEST" >"$proj/.dev/tools.tsv"
printf '#!/bin/sh\necho foo ran\n' >"$proj/.dev/foo.sh"
chmod +x "$proj/.dev/foo.sh"
ln -s "$outside/shadow" "$proj/.dev/n/DESCRIPTION"
ln -s "$outside/dir" "$proj/.dev/linked"
printf '#!/bin/sh\n' >"$proj/.dev/n/sub.sh"
chmod +x "$proj/.dev/n/sub.sh"

for verb in push lint fetch init foo test tools "tools frobnicate" help -h --help "" __verbs __subs __flags "__subs n" "help n"; do
    # shellcheck disable=SC2086
    out="$(dev "$proj/a" $verb 2>&1)"
    status=$?
    assert_eq "root dev '$verb' exits 2" "$status" "2"
    assert_contains "root dev '$verb' says what root may run" "$out" "$MSG"
    assert_not_contains "root dev '$verb' prints no outside file" "$out" "SECRET-MARKER"
    assert_not_contains "root dev '$verb' runs no project script" "$out" "foo ran"
    assert_eq "root dev '$verb' runs no jj or git" "$(cat "$VCSLOG")" ""
done

if [ "$REAL_ROOT" = 1 ]; then
    rm -f "$TMP/remote-marker"
    printf 'return function() io.open("%s", "w"):close() return 0 end\n' "$TMP/remote-marker" >"$proj/.dev/__remote.lua"
    for words in "tools check" "test" "-- tools check" "-- test"; do
        # shellcheck disable=SC2086
        out="$(dev "$proj/a" --remote $words 2>&1)"
        assert_eq "root dev --remote $words exits 2" "$?" "2"
    done
    assert_eq "root never loads a project __remote.lua" "$([ -e "$TMP/remote-marker" ] && echo loaded || echo absent)" "absent"
    rm -f "$proj/.dev/__remote.lua"
    mkdir -p "$TMP/lc/bin"
    sed "s|^SYSTEM_BIN_DIRS=.*|SYSTEM_BIN_DIRS=($TMP/nowhere)|" "$DEV" >"$TMP/lc/bin/dev"
    chmod +x "$TMP/lc/bin/dev"
    ln -s "$REPO/dotfiles/bin/.local/share" "$TMP/lc/share"
    printf 'return function() io.open("%s", "w"):close() return 0 end\n' "$TMP/remote-marker" >"$proj/.dev/__remote.lua"
    out="$(cd "$proj/a" && "$TMP/lc/bin/dev" --remote tools install --dry-run 2>&1)"
    assert_eq "root without luajit, dev --remote tools install exits 2" "$?" "2"
    assert_eq "root without luajit, dev --remote says what root may run" "$out" "dev: $MSG"
    out="$(cd "$proj/a" && DEV_REMOTE=1 "$TMP/lc/bin/dev" tools check 2>&1)"
    assert_eq "root without luajit, DEV_REMOTE=1 tools check exits 2" "$?" "2"
    assert_eq "root without luajit, DEV_REMOTE=1 says what root may run" "$out" "dev: $MSG"
    out="$(cd "$proj/a" && "$TMP/lc/bin/dev" tools check 2>&1)"
    assert_eq "root without luajit, tools check exits 1" "$?" "1"
    assert_eq "root without luajit, tools check says it needs luajit" "$out" "dev: dev tools needs luajit in /usr/bin or /usr/local/bin"
    out="$(cd "$proj/a" && "$TMP/lc/bin/dev" tools install --system 2>&1)"
    assert_eq "root without luajit, tools install exits 1" "$?" "1"
    assert_eq "root without luajit, tools install says it needs luajit" "$out" "dev: dev tools needs luajit in /usr/bin or /usr/local/bin"
    out="$(cd "$proj/a" && "$TMP/lc/bin/dev" push 2>&1)"
    assert_eq "root without luajit, push is still refused with exit 2" "$?" "2"
    assert_eq "root without luajit runs no project __remote.lua" "$([ -e "$TMP/remote-marker" ] && echo loaded || echo absent)" "absent"
    rm -f "$proj/.dev/__remote.lua"
else
    printf 'SKIP real-root - the __remote.lua root test needs real root\n'
fi

if [ "$REAL_ROOT" = 0 ]; then
    out="$(FAKE_OS=Darwin dev "$proj/a" tools check 2>&1)"
    assert_eq "root on another OS exits 2" "$?" "2"
    assert_contains "root on another OS says Linux only" "$out" "dev: as root, dev runs only on Linux"
    assert_eq "root on another OS runs no jj or git" "$(cat "$VCSLOG")" ""
else
    printf 'SKIP user-only - runs on another OS through FAKE_OS, which a real uid 0 never loads\n'
fi

out="$(dev "$proj/a" tools install 2>&1)"
assert_eq "root tools install with no scope exits 2" "$?" "2"
assert_eq "root tools install runs no jj or git" "$(cat "$VCSLOG")" ""

out="$(dev "$proj/a" tools check --bogus 2>&1)"
assert_eq "root tools check with a bad flag exits 2" "$?" "2"
assert_contains "root tools check names the bad flag" "$out" "dev tools check: Unknown flag --bogus."
assert_contains "root tools check hints the accepted form" "$out" "usage: dev tools check [--group NAME]"
out="$(dev "$proj/a" tools install --system --bogus 2>&1)"
assert_eq "root tools install with a bad flag exits 2" "$?" "2"
assert_contains "root tools install hints the accepted form" "$out" "usage: dev tools install [--system or --user] [--group NAME] [--dry-run] [--force] [tool...]"
out="$(dev "$proj/a" tools check --help 2>&1)"
assert_eq "root tools check --help is a usage error" "$?" "2"
assert_contains "root tools check --help names the flag" "$out" "dev tools check: Unknown flag --help."
assert_contains "root tools check --help hints the accepted form" "$out" "usage: dev tools check [--group NAME]"
out="$(dev "$proj/a" tools check --group 2>&1)"
assert_contains "root tools check hints a missing group name" "$out" "usage: dev tools check [--group NAME]"

out="$(DOTFILES=/tmp/evil-dotfiles dev "$proj/a/b" tools check 2>&1)"
assert_not_contains "root ignores DOTFILES" "$out" "evil-dotfiles"

nojj="$TMP/nojj"
mkdir -p "$nojj/.dev"
printf '%s\n' "$MANIFEST" >"$nojj/.dev/tools.tsv"

linkfile="$TMP/linkfile"
mkdir -p "$linkfile/.jj" "$linkfile/.dev"
ln -s "$outside/tools.tsv" "$linkfile/.dev/tools.tsv"
linkdir="$TMP/linkdir"
mkdir -p "$linkdir/.jj"
ln -s "$outside/dir" "$linkdir/.dev"

count_tmp() { find /tmp -maxdepth 1 -name 'dev-tools.*' | wc -l; }
before="$(count_tmp)"
OWN="must be owned by root and not writable by others"

out="$(dev "$linkfile" tools check 2>&1)"
assert_eq "root tools check refuses a symlinked manifest" "$?" "1"
assert_contains "root tools check names the manifest" "$out" "$linkfile/.dev/tools.tsv"
assert_not_contains "root tools check does not run the package driver on it" "$out" "SECRET-MARKER"
out="$(dev "$linkfile" tools install --system 2>&1)"
assert_eq "root tools install refuses a symlinked manifest" "$?" "1"
assert_contains "root tools install names the manifest" "$out" "$linkfile/.dev/tools.tsv"
assert_not_contains "root tools install does not run the package driver on it" "$out" "SECRET-MARKER"
assert_eq "no temp copy is left after a symlink refusal" "$(count_tmp)" "$before"

out="$(dev "$linkdir" tools check 2>&1)"
assert_eq "root tools check refuses a symlinked .dev" "$?" "1"
assert_contains "root tools check names the manifest under the symlinked .dev" "$out" "$linkdir/.dev/tools.tsv"
assert_not_contains "root tools check does not run the package driver on the outside file" "$out" "SECRET-MARKER"
assert_eq "the refusals run no jj or git" "$(cat "$VCSLOG")" ""

owned="$TMP/owned"
mkdir -p "$owned/.dev"
printf '%s\n' "$MANIFEST" >"$owned/.dev/tools.tsv"
if [ "$REAL_ROOT" = 1 ]; then chown -R 65534:65534 "$owned"; fi
out="$(dev "$owned" tools check 2>&1)"
assert_eq "root refuses a user-owned chain" "$?" "1"
assert_contains "the ownership refusal names the manifest" "$out" "refusing $(cd "$owned" && pwd -P)/.dev/tools.tsv as root: "
assert_contains "the ownership refusal says what is required" "$out" "$OWN"
assert_eq "no temp copy is left after an ownership refusal" "$(count_tmp)" "$before"

out="$(DOTFILES=/tmp/evil-dotfiles dev "$nojj" tools check 2>&1)"
assert_not_contains "root does not use a DOTFILES package driver" "$out" "evil-dotfiles"

if [ "$REAL_ROOT" = 1 ]; then
    gw="$TMP/gw"
    mkdir -p "$gw/.dev"
    printf '%s\n' "$MANIFEST" >"$gw/.dev/tools.tsv"
    chmod g+w "$gw/.dev"
    hostile="$TMP/x'\$(touch PWNED)"
    mkdir -p "$hostile/.dev"

    # shellcheck disable=SC2016  # the cell is literal text
    printf 'name binary pacman\n$(>PWNED) zzz-none-bin x\n' >"$hostile/.dev/tools.tsv"
    out="$(dev "$hostile" tools check 2>&1)"
    assert_eq "root reads a manifest under a hostile project name" "$?" "1"

    # shellcheck disable=SC2016  # the cell is literal text
    assert_contains "root passes the hostile cell to the package driver as text" "$out" '$(>PWNED)'
    assert_eq "a hostile project name and cell run nothing" "$(find "$TMP" -name PWNED | wc -l | tr -d ' ')" "0"

    out="$(dev "$gw" tools check 2>&1)"
    assert_eq "root refuses a group-writable .dev" "$?" "1"
    assert_contains "the .dev refusal names the offending path" "$out" "refusing $gw/.dev/tools.tsv as root: $gw/.dev $OWN"

    ow="$TMP/ow"
    mkdir -p "$ow/.dev"
    printf '%s\n' "$MANIFEST" >"$ow/.dev/tools.tsv"
    chmod o+w "$ow"
    out="$(dev "$ow" tools check 2>&1)"
    assert_eq "root refuses an other-writable project root" "$?" "1"
    assert_contains "the project root refusal names the offending path" "$out" "$ow $OWN"

    out="$(dev "$proj/a/b" tools check 2>&1)"
    assert_eq "root tools check from a nested dir exits 1 for the missing tool" "$?" "1"
    assert_contains "root tools check reads the project's manifest" "$out" "zzz-tool"
    assert_eq "root tools check runs no jj or git" "$(cat "$VCSLOG")" ""

    out="$(dev "$nojj" tools check 2>&1)"
    assert_eq "root tools check in a project with only .dev exits 1" "$?" "1"
    assert_contains "root tools check reads that manifest" "$out" "zzz-tool"
    assert_eq "no temp copy is left after a package driver failure" "$(count_tmp)" "$before"

    leak="$TMP/leak"
    mkdir -p "$leak/.dev"

    # shellcheck disable=SC2016  # the manifest variable is literal text
    printf 'name binary pacman\n${SECRET} ${SECRET} x\n' >"$leak/.dev/tools.tsv"
    out="$(SECRET=leakvalue-9 dev "$leak" tools check 2>&1)"
    assert_not_contains "root's environment does not reach the manifest" "$out" "leakvalue-9"
    assert_contains "the manifest variable is undefined for the package driver" "$out" "is undefined"

    evil="$TMP/evil"
    mkdir -p "$evil/dotfiles/bin/.local/share/dev"
    printf 'io.write("EVIL-RAN\\n")\n' >"$evil/dotfiles/bin/.local/share/dev/pkg.lua"
    out="$(DOTFILES="$evil" dev "$nojj" tools check 2>&1)"
    assert_not_contains "root does not run a package driver from DOTFILES" "$out" "EVIL-RAN"

    good="$TMP/good"
    mkdir -p "$good/.dev"
    printf 'name binary pacman\nsh-tool sh sh\n' >"$good/.dev/tools.tsv"
    out="$(BASH_ENV=/tmp/evil-bash-env PS4=evil-ps4 dev "$good" -vv tools check 2>&1)"
    assert_eq "root tools check -vv exits 0" "$?" "0"
    assert_contains "-vv gives the driver dev's own trace file" "$out" "BASH_ENV=$REPO/dotfiles/bin/.local/share/dev/xtrace.bash"
    assert_not_contains "-vv keeps the caller's BASH_ENV out of the driver" "$out" "evil-bash-env"
    assert_not_contains "-vv keeps the caller's PS4 out of the driver" "$out" "evil-ps4"
    out="$(dev "$good" tools check 2>&1)"
    assert_eq "root tools check passes for a present tool" "$?" "0"
    assert_eq "no temp copy is left after success" "$(count_tmp)" "$before"

    big="$TMP/big"
    mkdir -p "$big/.dev"
    truncate -s 2M "$big/.dev/tools.tsv"
    out="$(dev "$big" tools check 2>&1)"
    assert_eq "root refuses an oversize manifest" "$?" "1"
    assert_contains "the oversize refusal names the path" "$out" "refusing $big/.dev/tools.tsv as root: larger than 256 KiB"
    mid="$TMP/mid"
    mkdir -p "$mid/.dev"
    mkline() { awk -v n="$1" 'BEGIN { s = "#"; for (i = 1; i < n; i++) s = s "x"; print s }'; }
    for _ in $(seq 1 257); do mkline 1023; done >"$mid/.dev/tools.tsv"
    out="$(dev "$mid" tools check 2>&1)"
    assert_eq "root refuses a 257 KiB manifest" "$?" "1"
    assert_contains "the 257 KiB refusal names the size" "$out" "larger than 256 KiB"
    long="$TMP/long"
    mkdir -p "$long/.dev"
    mkline 5000 >"$long/.dev/tools.tsv"
    out="$(dev "$long" tools check 2>&1)"
    assert_eq "root refuses a 5000-byte line" "$?" "1"
    assert_contains "the long-line refusal names the path" "$out" "refusing $long/.dev/tools.tsv as root: a line is longer than 4096 bytes"
    assert_eq "no temp copy is left after the long-line refusal" "$(count_tmp)" "$before"
    assert_eq "no temp copy is left after the oversize refusal" "$(count_tmp)" "$before"

    edge="$TMP/edge"
    mkdir -p "$edge/.dev"
    for _ in $(seq 1 256); do mkline 1023; done >"$edge/.dev/tools.tsv"
    out="$(dev "$edge" tools check 2>&1)"
    assert_not_contains "a manifest of exactly 256 KiB is accepted" "$out" "larger than 256 KiB"
    mkline 4096 >"$edge/.dev/tools.tsv"
    out="$(dev "$edge" tools check 2>&1)"
    assert_not_contains "a 4096-byte line is accepted" "$out" "longer than 4096"

    mkchain() {
        c_anc="$TMP/chain-$1"
        c_proj="$c_anc/proj"
        mkdir -p "$c_proj/.dev"
        printf 'name binary pacman\nsh-tool sh sh\n' >"$c_proj/.dev/tools.tsv"
        c_man="$c_proj/.dev/tools.tsv"
    }
    mkchain a
    chown 65534:65534 "$c_proj"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (a): only ROOT user-owned is refused" "$?" "1"
    assert_contains "chain (a): names ROOT" "$out" "refusing $c_man as root: $c_proj $OWN"
    mkchain b
    chown 65534:65534 "$c_proj/.dev"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (b): only .dev user-owned is refused" "$?" "1"
    assert_contains "chain (b): names .dev" "$out" "refusing $c_man as root: $c_proj/.dev $OWN"
    mkchain c
    chmod 0775 "$c_anc"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (c): a group-writable ancestor is refused" "$?" "1"
    assert_contains "chain (c): names the ancestor" "$out" "refusing $c_man as root: $c_anc $OWN"
    mkchain d
    chown 65534:65534 "$c_anc"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (d): a user-owned ancestor is refused" "$?" "1"
    assert_contains "chain (d): names the ancestor" "$out" "refusing $c_man as root: $c_anc $OWN"
    mkchain e
    chmod 1777 "$c_anc"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (e): a root-owned sticky ancestor is accepted" "$?" "0"
    mkchain f
    chown 65534:65534 "$c_anc"
    chmod 1777 "$c_anc"
    out="$(dev "$c_proj" tools check 2>&1)"
    assert_eq "chain (f): a user-owned sticky ancestor is refused" "$?" "1"
    assert_contains "chain (f): names the ancestor" "$out" "refusing $c_man as root: $c_anc $OWN"

    if [ -x /usr/bin/pacman ]; then
        out="$(dev "$nojj" tools install --system --dry-run 2>&1)"
        assert_eq "root tools install --system plans from the copy" "$?" "0"
        assert_contains "root tools install --system plans the package row" "$out" "pacman -S --needed --noconfirm -- zzz-tool"
        out="$(dev "$nojj" tools install --system --force --dry-run zzz-tool 2>&1)"
        assert_contains "--force reaches the package driver as root" "$out" "pacman -S --noconfirm -- zzz-tool"
        assert_not_contains "--force drops --needed" "$out" "--needed"
        grp="$TMP/grp"
        mkdir -p "$grp/.dev"
        printf 'name binary pacman groups\nzzz-in zzz-in-not-here zzz-in base\nzzz-out zzz-out-not-here zzz-out -\n' >"$grp/.dev/tools.tsv"
        out="$(dev "$grp" tools install --system --group base --dry-run 2>&1)"
        assert_eq "--group reaches the package driver as root" "$?" "0"
        assert_contains "--group base as root plans the group row" "$out" "pacman -S --needed --noconfirm -- zzz-in"
        assert_not_contains "--group base as root leaves out the other row" "$out" "zzz-out"
        out="$(dev "$grp" tools install --system --group nope --dry-run 2>&1)"
        assert_eq "an unknown --group as root exits 2" "$?" "2"
        assert_contains "an unknown --group as root is named" "$out" "unknown group: nope"
        out="$(dev "$grp" tools check --group base 2>&1)"
        assert_contains "check --group reaches the package driver as root" "$out" "zzz-in"
        assert_not_contains "check --group as root leaves out the other row" "$out" "zzz-out"
    else
        printf 'SKIP real-root - the --force test needs the real /usr/bin/pacman\n'
    fi
else
    printf 'SKIP real-root - the root-owned-chain success tests need real root\n'
fi

: >"$VCSLOG"
if [ "$REAL_ROOT" = 0 ]; then
    (cd "$proj/a" && FAKE_UID=1000 PATH="$STUBS:$PATH" "$DEV" tools check >/dev/null 2>&1)
    assert_contains "a normal user's repo_root still runs jj root" "$(cat "$VCSLOG")" "jj root"
else
    printf 'SKIP user-only - runs as a user through FAKE_UID, which a real uid 0 never loads\n'
    out="$(FAKE_UID=1000 FAKE_OS=Darwin dev "$proj/a" foo 2>&1)"
    assert_eq "at real root the seam is inert and a fake user is refused" "$?" "2"
    assert_contains "at real root a fake user uid still gets the root refusal" "$out" "$MSG"
    assert_not_contains "at real root the fake user runs no project script" "$out" "foo ran"
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall root tests passed\n'
