#!/usr/bin/env bash
# Pure-bash unit tests for scripts/pkg/lib.sh (no external test framework).
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/pkg/lib.sh
# shellcheck disable=SC1091
source "$DIR/../../scripts/pkg/lib.sh"

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

assert_unavailable() {
    local desc="$1" cell="$2"
    if parse_cell "$cell" >/dev/null; then
        printf 'FAIL - %s (expected unavailable)\n' "$desc"
        fails=$((fails + 1))
    else
        printf 'ok   - %s\n' "$desc"
    fi
}

# parse_cell
assert_eq "plain package" "$(parse_cell 'ripgrep')" $'\tripgrep\t\t'
assert_eq "cask channel" "$(parse_cell 'cask:ghostty')" $'cask\tghostty\t\t'
assert_eq "bin override" "$(parse_cell 'fd-find,bin:fdfind')" $'\tfd-find\t\tfdfind'
assert_eq "tap with repo" "$(parse_cell 'tap:browserpass,repo:amar1729/formulae')" $'tap\tbrowserpass\tamar1729/formulae\t'
assert_eq "copr with repo" "$(parse_cell 'copr:ghostty,repo:pgdev/ghostty')" $'copr\tghostty\tpgdev/ghostty\t'
assert_unavailable "dash is unavailable" '-'

# resolve_binary
assert_eq "resolve default" "$(resolve_binary 'fd' '')" "fd"
assert_eq "resolve override" "$(resolve_binary 'fd' 'fdfind')" "fdfind"

# detect_primary_manager (only assert on this machine's OS)
if [ "$(uname)" = "Darwin" ]; then
    assert_eq "primary manager on darwin" "$(detect_primary_manager)" "brew"
fi

# Regression tests for bash 3.2 compatibility and header-scoped column index
assert_eq "repo and bin together" "$(parse_cell 'tap:browserpass,repo:amar1729/formulae,bin:bpass')" $'tap\tbrowserpass\tamar1729/formulae\tbpass'

# manifest_column_index tests with temp manifest
tmp="$(mktemp)"
printf 'name\tbinary\tbrew\nripgrep\trg\tripgrep\n' >"$tmp"
assert_eq "column index found" "$(manifest_column_index "$tmp" brew)" "3"
assert_eq "column index missing" "$(manifest_column_index "$tmp" ripgrep)" ""
rm -f "$tmp"

# Quote-aware tokenizer: a double-quoted cell containing spaces is one field
# (quotes stripped); unquoted rows tokenize exactly as before.
qtmp="$(mktemp)"
printf 'name\tbinary\tbrew\nplain\tpl\tripgrep\nscript-args\tzzznope\t"script:/tmp/x.sh --flag value"\n' >"$qtmp"
qcol="$(manifest_column_index "$qtmp" brew)"
assert_eq "quoted-cell column index" "$qcol" "3"
assert_eq "unquoted row still tokenizes" "$(manifest_rows "$qtmp" "$qcol" | head -n1)" $'plain\tpl\tripgrep'
assert_eq "quoted row yields full cell" "$(manifest_rows "$qtmp" "$qcol" | tail -n1)" $'script-args\tzzznope\tscript:/tmp/x.sh --flag value'
rm -f "$qtmp"

# The quoted cell parses to channel=script, package="path --flag value".
split_cell "$(parse_cell 'script:/tmp/x.sh --flag value')"
assert_eq "quoted script channel" "$PC_CHANNEL" "script"
assert_eq "quoted script package (path + args)" "$PC_PACKAGE" "/tmp/x.sh --flag value"

# End-to-end: pkg.sh install --dry-run against the quoted-args fixture must print
# the script path WITH its args. The fixture carries the quoted cell in every
# manager column so the lookup succeeds whatever primary manager this OS uses.
PKG_SH="$(cd "$DIR/../../scripts" && pwd)/pkg.sh"
if [ -n "$(detect_primary_manager)" ]; then
    iout="$(bash "$PKG_SH" install --manifest "$DIR/fixtures/script-args.tsv" --dry-run script-args 2>&1)"
    case "$iout" in
    *"bash /tmp/echo-args.sh --flag value"*)
        assert_eq "install dry-run passes args through" "ok" "ok"
        ;;
    *)
        printf 'FAIL - install dry-run passes args through\n       got:  %q\n' "$iout"
        fails=$((fails + 1))
        ;;
    esac
fi

# channel_handler
assert_eq "handler: bare -> primary" "$(channel_handler '' brew)" "brew"
assert_eq "handler: cask -> primary" "$(channel_handler cask brew)" "brew"
assert_eq "handler: aur -> primary" "$(channel_handler aur pacman)" "pacman"
assert_eq "handler: cargo -> cargo" "$(channel_handler cargo brew)" "cargo"

# --- aur: channel --------------------------------------------------------------
assert_eq "aur channel parses" "$(parse_cell 'aur:jjui-bin')" $'aur\tjjui-bin\t\t'

# The pacman driver must RENDER an aur: install, not reject it. It long accepted
# only the empty channel, so an aur: cell parsed fine and then died at install
# time as an "unknown pacman channel". A bogus package name keeps this from
# short-circuiting on "already installed" when the suite runs on real Arch.
# shellcheck source=../../scripts/pkg/pacman.sh
# shellcheck disable=SC1091
aout="$(source "$DIR/../../scripts/pkg/pacman.sh" && pkg_install jjui zzz-no-such-binary zzz-no-such-aur-pkg aur '' 1 2>&1)"
case "$aout" in
*"aur.archlinux.org/zzz-no-such-aur-pkg.git"*"makepkg -si"*)
    assert_eq "pacman aur dry-run renders clone + makepkg" "ok" "ok"
    ;;
*)
    printf 'FAIL - pacman aur dry-run renders clone + makepkg\n       got:  %q\n' "$aout"
    fails=$((fails + 1))
    ;;
esac

# An unknown channel must still be rejected -- adding aur must not turn the
# default arm into a catch-all that silently installs the wrong thing.
# shellcheck source=../../scripts/pkg/pacman.sh
# shellcheck disable=SC1091
bout="$(source "$DIR/../../scripts/pkg/pacman.sh" && pkg_install x zzz-no-such-binary zzz-pkg bogus '' 1 2>&1)"
case "$bout" in
*"unknown pacman channel"*)
    assert_eq "pacman rejects unknown channel" "ok" "ok"
    ;;
*)
    printf 'FAIL - pacman rejects unknown channel\n       got:  %q\n' "$bout"
    fails=$((fails + 1))
    ;;
esac

# split_cell (bash 3.2 field-splitting safety for bare and bare+bin cells)
split_cell "$(parse_cell 'ripgrep')"
assert_eq "split_cell bare channel" "$PC_CHANNEL" ""
assert_eq "split_cell bare package" "$PC_PACKAGE" "ripgrep"
split_cell "$(parse_cell 'fd-find,bin:fdfind')"
assert_eq "split_cell bare+bin package" "$PC_PACKAGE" "fd-find"
assert_eq "split_cell bare+bin bin" "$PC_BIN" "fdfind"
split_cell "$(parse_cell 'tap:tz,repo:owner/tap')"
assert_eq "split_cell tap channel" "$PC_CHANNEL" "tap"
assert_eq "split_cell tap package" "$PC_PACKAGE" "tz"
assert_eq "split_cell tap repo" "$PC_REPO" "owner/tap"

# --- manifest variables (@env defaults + $VAR/${VAR} references) ---------------
# cell_for <manifest> <col> <name>: the expanded cell (field 3) for a data row.
cell_for() {
    manifest_rows "$1" "$2" | awk -F'\t' -v n="$3" '$1 == n { print $3 }'
}

vfx="$DIR/fixtures/vars.tsv"

# manifest_column_index must skip `# @env` lines like ordinary comments.
vcol="$(manifest_column_index "$vfx" brew)"
assert_eq "column index past @env comments" "$vcol" "3"

# @env unquoted value: both $FOO and ${FOO} expand to it.
assert_eq "bare \$FOO expands" "$(cell_for "$vfx" "$vcol" bare-foo)" "bar_value"
assert_eq "braced \${FOO} expands" "$(cell_for "$vfx" "$vcol" braced-foo)" "bar_value"

# @env quoted value with spaces: expands, spaces preserved.
assert_eq "quoted \"\$SP\" expands (spaces kept)" "$(cell_for "$vfx" "$vcol" quoted-sp)" "asdf asdf"
assert_eq "quoted \"\${SP}\" expands (spaces kept)" "$(cell_for "$vfx" "$vcol" braced-sp)" "asdf asdf"

# Quoted literal, no var: unchanged.
assert_eq "quoted literal unchanged" "$(cell_for "$vfx" "$vcol" quoted-lit)" "/x --y"

# Mid-cell, in-place expansion.
assert_eq "mid-cell script:\${FOO}" "$(cell_for "$vfx" "$vcol" mid-script)" "script:bar_value"
assert_eq "mid-cell copr repo:\${FOO}" "$(cell_for "$vfx" "$vcol" mid-copr)" "copr:p,repo:bar_value"

# Escape: \$\$ -> literal \$; \$\$FOO -> literal \$FOO (not a reference).
assert_eq "\$\$ escapes to literal \$" "$(cell_for "$vfx" "$vcol" escape)" "price\$5"
assert_eq "\$\$FOO is literal, not a ref" "$(cell_for "$vfx" "$vcol" escape-name)" "\$FOO"

# Env override beats the @env default (export so awk's ENVIRON sees it; subshell
# isolates the export from the rest of the suite).
override="$(
    export FOO=env_wins
    cell_for "$vfx" "$vcol" bare-foo
)"
assert_eq "env var overrides @env default" "$override" "env_wins"

# Undefined var: manifest_rows exits non-zero and writes the error to stderr,
# without printing any rows.
ufx="$DIR/fixtures/vars-undef.tsv"
ucol="$(manifest_column_index "$ufx" brew)"
uerr="$(manifest_rows "$ufx" "$ucol" 2>&1 >/dev/null)"
urc=$?
if [ "$urc" -ne 0 ]; then
    assert_eq "undefined var exits non-zero" "ok" "ok"
else
    printf 'FAIL - undefined var exits non-zero (got rc=%d)\n' "$urc"
    fails=$((fails + 1))
fi
case "$uerr" in
*"undefined variable \${NOPE}"*"nope-row"*)
    assert_eq "undefined var error names var + row" "ok" "ok"
    ;;
*)
    printf 'FAIL - undefined var error names var + row\n       got:  %q\n' "$uerr"
    fails=$((fails + 1))
    ;;
esac

if [ "$fails" -gt 0 ]; then
    printf '\n%d test(s) failed\n' "$fails"
    exit 1
fi
printf '\nall tests passed\n'
