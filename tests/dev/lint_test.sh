#!/usr/bin/env bash
# Pure-bash tests for .dev/lint.lua, run on scratch files.
# The script is copied into a temp tree with the repo's lint set, so the repo is never linted.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
export RIPGREP_CONFIG_PATH=/dev/null
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEV="$REPO/bin/dev"
mkdir -p "$TMP/.dev/lua/devrepo" "$TMP/bin" "$TMP/tests"
cp "$REPO/.dev/lint.lua" "$TMP/.dev/"
cp "$REPO/.dev/lua/devrepo/checks.lua" "$TMP/.dev/lua/devrepo/"
cp "$REPO/.dev/lua/lintset.lua" "$TMP/.dev/lua/"
cp -R "$REPO/.dev/ast-grep" "$TMP/.dev/"
cp "$REPO/stylua.toml" "$REPO/selene.toml" "$REPO/luajit.yml" "$REPO/sgconfig.yml" "$TMP/"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n    echo ok\nfi\n' >"$TMP/bin/clean.sh"

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

# lint: run dev lint on the scratch tree, capturing stdout and stderr together.
lint() {
    (cd "$TMP" && "$DEV" lint 2>&1)
}

out="$(lint)"
rc=$?
assert_eq "a clean tree exits 0" "$rc" "0"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n  echo drifted\nfi\n' >"$TMP/bin/drift.sh"
out="$(lint)"
rc=$?
assert_eq "shfmt drift exits non-zero" "$((rc != 0))" "1"
assert_contains "shfmt drift names the file" "$out" "bin/drift.sh"
rm "$TMP/bin/drift.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nvalue=1\n# explains the next line\necho done\n' >"$TMP/bin/spacing.sh"
out="$(lint)"
rc=$?
assert_eq "a comment under code exits non-zero" "$((rc != 0))" "1"
assert_contains "a comment under code names file and line" "$out" "bin/spacing.sh:5: full-line comment directly after code"
rm "$TMP/bin/spacing.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\necho a \\\n    b\n# explains the next line\necho done\n' >"$TMP/bin/deeper.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\ncase b in\na)\n    echo a\n    ;;\n# The b arm\nb)\n    echo b\n    ;;\nesac\n' >"$TMP/bin/arms.sh"
out="$(lint)"
assert_contains "a comment under deeper code fails" "$out" "bin/deeper.sh:6: full-line comment directly after code"
assert_not_contains "a comment heading the next case arm passes" "$out" "bin/arms.sh:"
rm "$TMP/bin/deeper.sh" "$TMP/bin/arms.sh"

printf '@test "bare" {\n    true\n    [[ hi == *hi* ]]\n    true\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a bare [[ ]] assertion in a bats file exits non-zero" "$((rc != 0))" "1"
assert_contains "a bare [[ ]] assertion names file and line" "$out" "tests/bare.bats:3: a bare [[ ]] assertion never fails a test under bash 3.2"
printf '@test "guarded" {\n    [[ hi == *hi* ]] || false\n    run zsh -c "[[ -n x ]] && print ok"\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a [[ ]] assertion ending in || false passes" "$rc" "0"
assert_not_contains "a [[ ]] inside a command string passes" "$out" "tests/bare.bats"
rm "$TMP/tests/bare.bats"

if command -v selene >/dev/null 2>&1; then
    printf 'local unused = 1\n' >"$TMP/.dev/x.lua"
    out="$(lint)"
    rc=$?
    assert_eq "a lua violation under .dev exits non-zero" "$((rc != 0))" "1"
    assert_contains "a lua violation under .dev is named by selene" "$out" ".dev/x.lua"
    rm "$TMP/.dev/x.lua"
    out="$(lint)"
    rc=$?
    assert_eq "the tree passes again once the .dev violation is gone" "$rc" "0"
else
    printf 'skip - the .dev lua violation (needs selene)\n'
fi

BARE="$TMP/bare"
mkdir -p "$BARE"
for dir in /usr/bin /bin; do
    for exe in "$dir"/*; do
        case "${exe##*/}" in
        ast-grep | sg | stylua | selene) continue ;;
        esac
        [ -x "$exe" ] && [ ! -e "$BARE/${exe##*/}" ] && ln -s "$exe" "$BARE/${exe##*/}"
    done
done
if command -v luajit >/dev/null 2>&1; then
    [ -e "$BARE/luajit" ] || ln -s "$(command -v luajit)" "$BARE/luajit"
    out="$(cd "$TMP" && env -u CI PATH="$BARE" bash "$DEV" lint 2>&1)"
    assert_contains "dev lint names a missing stylua in a sentence" "$out" "Tool stylua not found. The stylua check is skipped. Install it with brew install stylua."
else
    printf 'skip - the missing stylua note (needs luajit)\n'
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall lint tests passed\n'
