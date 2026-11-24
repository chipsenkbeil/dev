#!/usr/bin/env bash
# Pure-bash tests for the dev binary's start-up: the global flags, the environment it exports and what
# root drops. Each case reads the environment through the probe fixture run by `dev -l`.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd -P)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"
PROBE="$DIR/fixtures/launcher_probe.luau"
unset DOTFILES VERBOSE DEV_UID DEV_OS CI
export DEV_REMOTE=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ "$EUID" -eq 0 ]; then REAL_ROOT=1; else REAL_ROOT=0; fi

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

HOSTILE="BASH_ENV ENV DEV_UID DEV_OS"

for name in $HOSTILE; do
    got="$(env "$name=kept" "$DEV" -l "$PROBE" "$name" 2>&1)"
    if [ "$REAL_ROOT" -eq 1 ]; then
        assert_eq "root drops $name" "$got" "$name=<unset>"
    else
        assert_eq "a user keeps $name" "$got" "$name=kept"
    fi
done

got="$("$DEV" -l "$PROBE" DEV_SELF 2>&1)"
assert_eq "dev exports its real path as DEV_SELF" "$got" "DEV_SELF=$(cd -P "$(dirname "$DEV")" && pwd -P)/$(basename "$DEV")"

mkdir -p "$TMP/with space"
ln -s "$DEV" "$TMP/with space/dev"
got="$("$TMP/with space/dev" -l "$PROBE" DEV_SELF 2>&1)"
assert_eq "a symlink under a path with a space runs" "$?" "0"
assert_eq "a symlink reports the binary's real path" "$got" "$(DEV_SELF="" "$DEV" -l "$PROBE" DEV_SELF)"

got="$(cd "$TMP" && "$DEV" -C nope -l "$PROBE" 2>&1)"
assert_eq "-C with a relative directory it cannot enter exits 2" "$?" "2"
assert_eq "-C names a relative directory as it was given" "$got" "The flag \`-C\` cannot enter nope."
got="$("$DEV" -C "" lint 2>&1)"
assert_eq "-C with an empty word exits 2" "$?" "2"
assert_eq "-C with an empty word says it needs a directory" "$got" "The flag \`-C\` needs a directory."
got="$("$DEV" -C "$TMP" -l "$PROBE" PWD 2>&1)"
assert_eq "-C enters the folder and sets PWD" "$got" "PWD=$(cd -P "$TMP" && pwd -P)"

got="$("$DEV" --agent dotfiles/implementer/x -l "$PROBE" DEV_AGENT 2>&1)"
assert_eq "--agent exports DEV_AGENT to the command" "$got" "DEV_AGENT=dotfiles/implementer/x"
got="$("$DEV" --agent "" lint 2>&1)"
assert_eq "--agent with an empty word exits 2" "$?" "2"
assert_eq "--agent with an empty word says it needs a name" "$got" "The --agent flag needs a name."
got="$("$DEV" --agent 2>&1)"
assert_eq "--agent with no word after it exits 2" "$?" "2"
assert_eq "--agent with no word after it says it needs a name" "$got" "The --agent flag needs a name."

got="$("$DEV" --nope lint 2>&1)"
assert_eq "an unknown flag before the command word exits 2" "$?" "2"
assert_eq "an unknown flag before the command word is named" "$got" "The flag \`--nope\` is not a global flag of dev."
got="$("$DEV" -l "$TMP/missing.luau" 2>&1)"
assert_eq "-l with a missing file exits 2" "$?" "2"
assert_eq "-l with a missing file names it" "$got" "The file $TMP/missing.luau does not exist."
got="$("$DEV" -l 2>&1)"
assert_eq "-l with no file exits 2" "$?" "2"
assert_eq "-l with no file says it needs a file" "$got" "The flag \`-l\` needs a file."
got="$("$DEV" -l "$PROBE" -C nope 2>&1)"
assert_eq "words after the -l file go to the file" "$got" $'-C=<unset>\nnope=<unset>'
assert_contains "the file's own arguments are not read as flags" "$got" "-C"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall launcher tests passed\n'
