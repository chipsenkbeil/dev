#!/usr/bin/env bash
# Tests for the dev help views: snapshots against a fixture project, one group per verb, and the topic check.
# UPDATE_SNAPSHOTS=1 rewrites the snapshot files.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
FIXTURES="$DIR/fixtures"
SNAPSHOTS="$FIXTURES/help-snapshots"
unset VERBOSE CI
export DEV_REMOTE=0
export NO_COLOR=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/help-project"
FIXDOT="$TMP/help-dotfiles"
cp -R "$FIXTURES/help-project" "$PROJ"
cp -R "$FIXTURES/help-dotfiles" "$FIXDOT"
PROJ="$(cd "$PROJ" && pwd -P)"
FIXDOT="$(cd "$FIXDOT" && pwd -P)"
FIXCONFIG="$TMP/help-global"
cp -R "$FIXTURES/help-global" "$FIXCONFIG"
FIXHOME="$TMP/help-home"
cp -R "$REPO/dotfiles/bin/.local" "$FIXHOME"
rm -r "$FIXHOME/share/dev/docs"
cp -R "$FIXTURES/help-dotfiles/docs" "$FIXHOME/share/dev/docs"
FIXDEV="$FIXHOME/bin/dev"

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

# fixture_dev <args...>: run dev in the fixture project against the fixture dotfiles, with the temp paths named.
fixture_dev() {
    (
        cd "$PROJ" && XDG_CONFIG_HOME="$FIXCONFIG" DOTFILES="$FIXDOT" "$FIXDEV" "$@" 2>&1
        printf 'exit %s\n' "$?"
    ) |
        sed -e "s|$PROJ|<root>|g" -e "s|$FIXDOT|<dotfiles>|g"
}

# snapshot <name> <args...>: compare dev's output with its snapshot file, or write the file when UPDATE_SNAPSHOTS is set.
snapshot() {
    local name=$1 file out
    shift
    file="$SNAPSHOTS/$name.txt"
    out="$(fixture_dev "$@")"
    if [ -n "${UPDATE_SNAPSHOTS:-}" ]; then
        printf '%s\n' "$out" >"$file"
        printf 'wrote %s\n' "$file"
        return
    fi
    if [ ! -f "$file" ]; then
        printf 'FAIL - snapshot %s: no file %s\n' "$name" "$file"
        fails=$((fails + 1))
        return
    fi
    assert_eq "snapshot $name" "$out" "$(cat "$file")"
}

# group_count <listing> <name>: how many groups other than Hidden list the verb in a dev help -a listing.
group_count() {
    awk -v n="$2" '
        /^[^ ]/ { section = $0; next }
        /^  / && section != "Hidden" && $1 == n { count++ }
        END { print count + 0 }
    ' <<<"$1"
}

# hidden_names <listing>: the verbs listed under Hidden in a dev help -a listing.
hidden_names() {
    awk '
        /^[^ ]/ { section = $0; next }
        /^  / && section == "Hidden" { print $1 }
    ' <<<"$1"
}

snapshot dev
snapshot help help
snapshot help-a help -a
snapshot help-topics help --topics
snapshot topic-overview help overview
snapshot topic-flags help -k flags
for verb in lint fmt test build run fetch push pull sync init tools help greet seed plumbing widget; do
    snapshot "help-$verb" help "$verb"
    snapshot "$verb-h" "$verb" -h
done
for sub in "tools install" "tools check" "widget save" "widget diff"; do
    read -r -a words <<<"$sub"
    name=${sub// /-}
    snapshot "help-$name" help "${words[@]}"
    snapshot "$name-h" "${words[@]}" -h
done

for verb in lint greet seed widget; do
    assert_eq "help $verb equals $verb --help" "$(fixture_dev help "$verb")" "$(fixture_dev "$verb" --help)"
done
assert_eq "help widget save equals widget save --help" "$(fixture_dev help widget save)" "$(fixture_dev widget save --help)"
assert_eq "dev equals dev help" "$(fixture_dev)" "$(fixture_dev help)"
assert_eq "--topics prints name and summary separated by a tab" \
    "$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" help --topics)" \
    "$(printf 'commands\tHow the fixture commands work\nflags\tThe global flags of the fixture\noverview\tWhat the fixture project is for and where to start')"
assert_contains "help commands prints the commands topic" "$(fixture_dev help commands)" "A directory of scripts is a command with subcommands"

# Every non-hidden verb sits in exactly one group
for root in "$PROJ" "$REPO"; do
    listing="$(cd "$root" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" DOTFILES="$REPO" "$DEV" help -a)"
    hidden=" $(hidden_names "$listing" | tr '\n' ' ')"
    while IFS= read -r verb; do
        want=1
        case "$hidden" in *" $verb "*) want=0 ;; esac
        assert_eq "$(basename "$root"): $verb is in $want group" "$(group_count "$listing" "$verb")" "$want"
    done < <(cd "$root" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" DOTFILES="$REPO" "$DEV" __commands | cut -f1)
    if [ "$root" = "$PROJ" ]; then
        assert_contains "the fixture hides plumbing" "$hidden" " plumbing "
    else
        assert_contains "the repo hides bootstrap" "$hidden" " bootstrap "
    fi
done

# The topic check
out="$(cd "$REPO" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" DOTFILES="$REPO" "$DEV" __topics check 2>&1)"
assert_eq "__topics check passes on the real topics" "$?" "0"
assert_eq "__topics check is silent when the topics pass" "$out" ""
out="$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" __topics check 2>&1)"
assert_eq "__topics check passes on the fixture topics" "$?" "0"

check_topic() {
    printf '%s\n' "$2" >"$PROJ/.dev/topics/$1.md"
    out="$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" __topics check 2>&1)"
    rc=$?
    rm "$PROJ/.dev/topics/$1.md"
}
check_topic badflag $'# badflag: Quotes a flag that does not exist\n\nRun `dev lint --bogus` to see it fail.'
assert_eq "__topics check fails on a made-up flag" "$rc" "1"
assert_contains "__topics check names the file and line of a made-up flag" "$out" ".dev/topics/badflag.md:3:"
assert_contains "__topics check names the made-up flag" "$out" "--bogus"
check_topic badverb $'# badverb: Quotes a verb that does not exist\n\n```\ndev frobnicate\n```'
assert_eq "__topics check fails on a made-up verb" "$rc" "1"
assert_contains "__topics check names the file and line of a made-up verb" "$out" ".dev/topics/badverb.md:4:"
assert_contains "__topics check names the made-up verb" "$out" "frobnicate"
check_topic "bad name" $'# bad name: A topic whose name cannot be typed'
assert_eq "__topics check fails on an untypeable topic name" "$rc" "1"
assert_contains "__topics check explains the topic name" "$out" "the topic name must use only"
check_topic stacked $'# stacked: Quotes stacked verbose flags\n\nRun `dev -vvv lint --fix`.'
assert_eq "__topics check accepts -vvv" "$rc" "0"
printf '#!/usr/bin/env bash\n# Declares a reserved flag.\n# flags: --ok -h\n' >"$PROJ/.dev/reserved.sh"
chmod +x "$PROJ/.dev/reserved.sh"
out="$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" __topics check 2>&1)"
assert_eq "__topics check fails on a script that declares -h" "$?" "1"
assert_contains "__topics check names the script" "$out" ".dev/reserved.sh:1:"
assert_contains "dev help warns about a reserved flag" "$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" help reserved 2>&1)" "declares -h"
rm "$PROJ/.dev/reserved.sh"
check_topic subcheck $'# subcheck: Quotes noun subcommands\n\nRun `dev tools install --dry-run`.'
assert_eq "__topics check accepts a real noun subcommand with its flag" "$rc" "0"
check_topic badsub $'# badsub: Quotes a subcommand the noun lacks\n\nRun `dev tools frob`.\n\n```\ndev tools frob\n```'
assert_eq "__topics check fails on a made-up subcommand of a built-in noun" "$rc" "1"
assert_contains "__topics check names the line and the bad subcommand" "$out" ".dev/topics/badsub.md:3: \`dev tools frob\`: dev tools has no subcommand frob"
assert_contains "__topics check checks a fenced subcommand too" "$out" ".dev/topics/badsub.md:6:"
check_topic subflag $'# subflag: Quotes a flag the subcommand lacks\n\nRun `dev tools check --no-such-flag`.'
assert_eq "__topics check fails on a flag the subcommand lacks" "$rc" "1"
assert_contains "__topics check names the subcommand's missing flag" "$out" "dev tools check takes no flag --no-such-flag"
printf '#!/usr/bin/env bash\n# group: Elsewhere\n# hidden\n# Ordered header lines.\n# flags: --late\n' >"$PROJ/.dev/ordered.sh"
chmod +x "$PROJ/.dev/ordered.sh"
listing="$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" help -a)"
assert_contains "a hidden line after a group line still hides the verb" " $(hidden_names "$listing" | tr '\n' ' ')" " ordered "
assert_eq "the hidden verb is not in its group" "$(group_count "$listing" ordered)" "0"
assert_eq "the curated view omits it" "$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" help | grep -c '^  ordered ' || true)" "0"
assert_eq "a flags line after group and hidden lines is read" "$(cd "$PROJ" && DOTFILES="$FIXDOT" "$FIXDEV" __flags ordered | sed -n 1p)" "--late"
rm "$PROJ/.dev/ordered.sh"
check_topic badnoun $'# badnoun: Quotes a subcommand that does not exist\n\nRun `dev widget zap`.'
assert_eq "__topics check fails on a made-up subcommand" "$rc" "1"
wide_words="de $(printf 'word %.0s' {1..20})end"
check_topic wide "$(printf '# wide: A wide prose line\n\n%s' "$wide_words")"
assert_eq "__topics check fails on a prose line over 80 columns" "$rc" "1"
assert_contains "__topics check names the wide line" "$out" ".dev/topics/wide.md:3: the line is wider than 80 columns"
check_topic wide $'# wide: A wide fenced line\n\n```\n'"$wide_words"$'\n```'
assert_eq "__topics check accepts a long fenced line" "$rc" "0"
check_topic wide "$(printf '# wide: A long unbreakable token\n\n%s' "$(printf 'x%.0s' {1..90})")"
assert_eq "__topics check accepts a long unbreakable token" "$rc" "0"
check_topic badhead 'No heading here'
assert_eq "__topics check fails on a bad first line" "$rc" "1"
assert_contains "__topics check explains the first line" "$out" "the first line must be"
check_topic lint '# lint: A topic named like a verb'
assert_eq "__topics check fails on a topic named like a verb" "$rc" "1"
assert_contains "__topics check names the command collision" "$out" "is also a command"
check_topic flags '# flags: A project topic named like a built-in one'
assert_eq "__topics check fails on a topic that shadows a built-in" "$rc" "1"
assert_contains "__topics check names the built-in collision" "$out" "is also a built-in topic"

out="$(fixture_dev help nosuch)"
assert_contains "help of an unknown name says so" "$out" "unknown command nosuch, and no topic of that name"
assert_contains "help of an unknown name exits 2" "$out" "exit 2"

# The porting topic's before and after verbs behave the same
assert_contains "the real topics list porting" "$(cd "$REPO" && DOTFILES="$REPO" "$DEV" help --topics)" $'porting\tPort a .dev bash verb to Lua'
fence() {
    awk -v lang="$1" '
        $0 == "```" lang { on = 1; next }
        $0 == "```" { on = 0 }
        on { print }
    ' "$REPO/dotfiles/bin/.local/share/dev/docs/porting.md"
}
for pair in sh:bash lua:lua; do
    ext=${pair%%:*}
    mkdir -p "$TMP/port-$ext/.dev"
    fence "${pair##*:}" >"$TMP/port-$ext/.dev/list.$ext"
    chmod +x "$TMP/port-$ext/.dev/list.$ext"
done
assert_contains "the topic holds a bash verb" "$(cat "$TMP/port-sh/.dev/list.sh")" "set -eo pipefail"
assert_contains "the topic holds a Lua verb" "$(cat "$TMP/port-lua/.dev/list.lua")" 'require("dev.command")'
port_run() {
    (
        cd "$TMP/port-$1" && DOTFILES="$REPO" "$DEV" list "${@:2}" 2>&1
        printf 'exit %s\n' "$?"
    )
}
assert_contains "the bash verb lists the targets" "$(port_run sh)" "+ nvim"
assert_eq "the Lua verb prints what the bash verb prints" "$(port_run lua)" "$(port_run sh)"
assert_eq "the Lua verb refuses an argument as the bash verb does" "$(port_run lua extra)" "$(port_run sh extra)"
assert_contains "the refusal exits 2" "$(port_run lua extra)" "exit 2"
assert_eq "the Lua verb refuses a flag after -- as the bash verb does" "$(port_run lua -- -x)" "$(port_run sh -- -x)"
assert_eq "the hidden header of both verbs hides list" \
    "$(cd "$TMP/port-lua" && DOTFILES="$REPO" "$DEV" help | grep -c '^  list ' || true)" "0"

printf '\n%s failed\n' "$fails"
[ "$fails" -eq 0 ]
