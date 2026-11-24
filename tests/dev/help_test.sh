#!/usr/bin/env bash
# Tests for the dev help views: snapshots against a fixture project, one group per command, and the topic check.
# UPDATE_SNAPSHOTS=1 rewrites the snapshot files.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"
FIXTURES="$DIR/fixtures"
SNAPSHOTS="$FIXTURES/help-snapshots"
unset VERBOSE CI
export DEV_REMOTE=0
export NO_COLOR=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/help-project"
cp -R "$FIXTURES/help-project" "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
FIXCONFIG="$TMP/help-global"
cp -R "$FIXTURES/help-global" "$FIXCONFIG"
FIXDEV="$DEV"

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
        cd "$PROJ" && XDG_CONFIG_HOME="$FIXCONFIG" "$FIXDEV" "$@" 2>&1
        printf 'exit %s\n' "$?"
    ) |
        sed -e "s|$PROJ|<root>|g"
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

# group_count <listing> <name>: how many groups other than Hidden list the command in a dev help -a listing.
group_count() {
    awk -v n="$2" '
        /^[^ ]/ { section = $0; next }
        /^  / && section != "Hidden" && $1 == n { count++ }
        END { print count + 0 }
    ' <<<"$1"
}

# hidden_names <listing>: the commands listed under Hidden in a dev help -a listing.
hidden_names() {
    awk '
        /^[^ ]/ { section = $0; next }
        /^  / && section == "Hidden" { print $1 }
    ' <<<"$1"
}

snapshot dev
snapshot help help
snapshot help-a help -a
snapshot topic-fixture help fixture
for command in lint fmt test build run fetch push pull init tools help greet seed plumbing widget; do
    snapshot "help-$command" help "$command"
    snapshot "$command-h" "$command" -h
done
for sub in "tools install" "tools check" "widget save" "widget diff"; do
    read -r -a words <<<"$sub"
    name=${sub// /-}
    snapshot "help-$name" help "${words[@]}"
    snapshot "$name-h" "${words[@]}" -h
done

for command in lint greet seed widget; do
    assert_eq "help $command equals $command --help" "$(fixture_dev help "$command")" "$(fixture_dev "$command" --help)"
done
assert_eq "help widget save equals widget save --help" "$(fixture_dev help widget save)" "$(fixture_dev widget save --help)"
assert_eq "dev equals dev help" "$(fixture_dev)" "$(fixture_dev help)"
assert_contains "--topics prints the project topic as name, tab and summary" \
    "$(cd "$PROJ" && "$FIXDEV" help --topics)" \
    "$(printf 'fixture\tWhat the fixture project is for and where to start')"
assert_contains "help commands prints the commands topic" "$(fixture_dev help commands)" "# commands: "

# Every non-hidden command sits in exactly one group
for root in "$PROJ" "$REPO"; do
    listing="$(cd "$root" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" "$DEV" help -a)"
    hidden=" $(hidden_names "$listing" | tr '\n' ' ')"
    while IFS= read -r command; do
        want=1
        case "$hidden" in *" $command "*) want=0 ;; esac
        assert_eq "$(basename "$root"): $command is in $want group" "$(group_count "$listing" "$command")" "$want"
    done < <(cd "$root" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" "$DEV" __complete -- "" | cut -f1)
    if [ "$root" = "$PROJ" ]; then
        assert_contains "the fixture hides plumbing" "$hidden" " plumbing "
    else
        assert_contains "the repo hides __pkg" "$hidden" " __pkg "
    fi
done

# The topic check
out="$(cd "$REPO" && XDG_CONFIG_HOME="$REPO/dotfiles/dev/.config" "$DEV" help --check-topics 2>&1)"
assert_eq "help --check-topics passes on the real topics" "$?" "0"
assert_eq "help --check-topics is silent when the topics pass" "$out" ""
out="$(cd "$PROJ" && "$FIXDEV" help --check-topics 2>&1)"
assert_eq "help --check-topics passes on the fixture topics" "$?" "0"

check_topic() {
    printf '%s\n' "$2" >"$PROJ/.dev/help/$1.md"
    out="$(cd "$PROJ" && "$FIXDEV" help --check-topics 2>&1)"
    rc=$?
    rm "$PROJ/.dev/help/$1.md"
}
check_topic badflag $'# badflag: Quotes a flag that does not exist\n\nRun `dev lint --bogus` to see it fail.'
assert_eq "help --check-topics fails on a made-up flag" "$rc" "1"
assert_contains "help --check-topics names the file and line of a made-up flag" "$out" ".dev/help/badflag.md:3:"
assert_contains "help --check-topics names the made-up flag" "$out" "--bogus"
check_topic badcommand $'# badcommand: Quotes a command that does not exist\n\n```\ndev frobnicate\n```'
assert_eq "help --check-topics fails on a made-up command" "$rc" "1"
assert_contains "help --check-topics names the file and line of a made-up command" "$out" ".dev/help/badcommand.md:4:"
assert_contains "help --check-topics names the made-up command" "$out" "frobnicate"
check_topic "bad name" $'# bad name: A topic whose name cannot be typed'
assert_eq "help --check-topics fails on an untypeable topic name" "$rc" "1"
assert_contains "help --check-topics explains the topic name" "$out" "the help page name must use only"
check_topic stacked $'# stacked: Quotes stacked commandose flags\n\nRun `dev -vvv lint --fix`.'
assert_eq "help --check-topics accepts -vvv" "$rc" "0"
printf '#!/usr/bin/env bash\n# Declares a reserved flag.\n# flag: ok -- Fine\n# flag: help short=h -- Bad\n' >"$PROJ/.dev/commands/reserved.sh"
chmod +x "$PROJ/.dev/commands/reserved.sh"
out="$(cd "$PROJ" && "$FIXDEV" help --check-topics 2>&1)"
assert_eq "help --check-topics fails on a script that declares -h" "$?" "1"
assert_contains "help --check-topics names the script" "$out" ".dev/commands/reserved.sh:1:"
assert_contains "dev help warns about a reserved flag" "$(cd "$PROJ" && "$FIXDEV" help reserved 2>&1)" "\`--help\` is dev's own"
rm "$PROJ/.dev/commands/reserved.sh"
check_topic subcheck $'# subcheck: Quotes noun subcommands\n\nRun `dev tools install --dry-run`.'
assert_eq "help --check-topics accepts a real noun subcommand with its flag" "$rc" "0"
check_topic badsub $'# badsub: Quotes a subcommand the noun lacks\n\nRun `dev tools frob`.\n\n```\ndev tools frob\n```'
assert_eq "help --check-topics fails on a made-up subcommand of a built-in noun" "$rc" "1"
assert_contains "help --check-topics names the line and the bad subcommand" "$out" ".dev/help/badsub.md:3: \`dev tools frob\`: dev tools has no subcommand frob"
assert_contains "help --check-topics checks a fenced subcommand too" "$out" ".dev/help/badsub.md:6:"
check_topic subflag $'# subflag: Quotes a flag the subcommand lacks\n\nRun `dev tools check --no-such-flag`.'
assert_eq "help --check-topics fails on a flag the subcommand lacks" "$rc" "1"
assert_contains "help --check-topics names the subcommand's missing flag" "$out" "dev tools check takes no flag --no-such-flag"
printf '#!/usr/bin/env bash\n# group: Elsewhere\n# hidden\n# Ordered header lines.\n# flag: late -- Late\n' >"$PROJ/.dev/commands/ordered.sh"
chmod +x "$PROJ/.dev/commands/ordered.sh"
listing="$(cd "$PROJ" && "$FIXDEV" help -a)"
assert_contains "a hidden line after a group line still hides the command" " $(hidden_names "$listing" | tr '\n' ' ')" " ordered "
assert_eq "the hidden command is not in its group" "$(group_count "$listing" ordered)" "0"
assert_eq "the curated view omits it" "$(cd "$PROJ" && "$FIXDEV" help | grep -c '^  ordered ' || true)" "0"
assert_eq "a flags line after group and hidden lines is read" "$(cd "$PROJ" && "$FIXDEV" __complete -- ordered --l | cut -f1 | sed -n 1p)" "--late"
rm "$PROJ/.dev/commands/ordered.sh"
check_topic badnoun $'# badnoun: Quotes a subcommand that does not exist\n\nRun `dev widget zap`.'
assert_eq "help --check-topics fails on a made-up subcommand" "$rc" "1"
wide_words="de $(printf 'word %.0s' {1..20})end"
check_topic wide "$(printf '# wide: A wide prose line\n\n%s' "$wide_words")"
assert_eq "help --check-topics fails on a prose line over 80 columns" "$rc" "1"
assert_contains "help --check-topics names the wide line" "$out" ".dev/help/wide.md:3: the line is wider than 80 columns"
check_topic wide $'# wide: A wide fenced line\n\n```\n'"$wide_words"$'\n```'
assert_eq "help --check-topics accepts a long fenced line" "$rc" "0"
check_topic wide "$(printf '# wide: A long unbreakable token\n\n%s' "$(printf 'x%.0s' {1..90})")"
assert_eq "help --check-topics accepts a long unbreakable token" "$rc" "0"
check_topic badhead 'No heading here'
assert_eq "help --check-topics fails on a bad first line" "$rc" "1"
assert_contains "help --check-topics explains the first line" "$out" "the first line must be"
check_topic lint '# lint: A topic named like a command'
assert_eq "help --check-topics fails on a topic named like a command" "$rc" "1"
assert_contains "help --check-topics names the command collision" "$out" "is also a command"
check_topic flags '# flags: A project topic named like a built-in one'
assert_eq "help --check-topics fails on a topic that shadows a built-in" "$rc" "1"
assert_contains "help --check-topics names the built-in collision" "$out" "is also a built-in help page"

out="$(fixture_dev help nosuch)"
assert_contains "help of an unknown name says so" "$out" "Unknown command nosuch, and no help page has that name."
assert_contains "help of an unknown name exits 2" "$out" "exit 2"

printf '\n%s failed\n' "$fails"
[ "$fails" -eq 0 ]
