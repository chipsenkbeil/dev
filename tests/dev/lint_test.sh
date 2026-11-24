#!/usr/bin/env bash
# Pure-bash tests for .dev/commands/lint.luau, run on scratch files copied into a temp tree so the repo is never linted.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
export RIPGREP_CONFIG_PATH=/dev/null
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DEV="${DEV_BIN:-$REPO/target/debug/dev}"
mkdir -p "$TMP/.dev/lib/devrepo" "$TMP/.dev/commands" "$TMP/scripts" "$TMP/tests" "$TMP/dotfiles/bin" "$TMP/dotfiles/jj/.config/jj/scripts" "$TMP/.ci"
cp "$REPO/.dev/commands/lint.luau" "$TMP/.dev/commands/"
cp "$REPO/stylua.toml" "$REPO/selene.toml" "$REPO/sgconfig.yml" "$REPO/ci.yml" "$REPO/.luaurc" "$TMP/"
cp "$REPO/.dev/lib/devrepo/checks.luau" "$TMP/.dev/lib/devrepo/"
cp "$REPO/.dev/lib/lintset.luau" "$TMP/.dev/lib/"
cp -R "$REPO/.dev/ast-grep" "$TMP/.dev/"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n    echo ok\nfi\n' >"$TMP/scripts/clean.sh"

fails=0

assert_eq() {
    local desc="$1" got="$2" want="$3" output="${4-}"
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$desc" "$got" "$want"
        [ -z "$output" ] || printf '       output: %q\n' "$output"
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
assert_eq "a clean tree exits 0" "$rc" "0" "$out"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nif true; then\n  echo drifted\nfi\n' >"$TMP/scripts/drift.sh"
out="$(lint)"
rc=$?
assert_eq "shfmt drift exits non-zero" "$((rc != 0))" "1"
assert_contains "shfmt drift names the file" "$out" "scripts/drift.sh"
rm "$TMP/scripts/drift.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\nvalue=1\n# explains the next line\necho done\n' >"$TMP/scripts/spacing.sh"
out="$(lint)"
rc=$?
assert_eq "a comment under code exits non-zero" "$((rc != 0))" "1"
assert_contains "a comment under code names file and line" "$out" "scripts/spacing.sh:5: full-line comment directly after code"
rm "$TMP/scripts/spacing.sh"

printf '#!/usr/bin/env bash\nset -euo pipefail\n\necho a \\\n    b\n# explains the next line\necho done\n' >"$TMP/scripts/deeper.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\n\ncase b in\na)\n    echo a\n    ;;\n# The b arm\nb)\n    echo b\n    ;;\nesac\n' >"$TMP/scripts/arms.sh"
out="$(lint)"
assert_contains "a comment under deeper code fails" "$out" "scripts/deeper.sh:6: full-line comment directly after code"
assert_not_contains "a comment heading the next case arm passes" "$out" "scripts/arms.sh:"
rm "$TMP/scripts/deeper.sh" "$TMP/scripts/arms.sh"

printf '@test "bare" {\n    true\n    [[ hi == *hi* ]]\n    true\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a bare [[ ]] assertion in a bats file exits non-zero" "$((rc != 0))" "1"
assert_contains "a bare [[ ]] assertion names file and line" "$out" "tests/bare.bats:3: a bare [[ ]] assertion never fails a test under bash 3.2"
printf '@test "guarded" {\n    [[ hi == *hi* ]] || false\n    run zsh -c "[[ -n x ]] && print ok"\n}\n' >"$TMP/tests/bare.bats"
out="$(lint)"
rc=$?
assert_eq "a [[ ]] assertion ending in || false passes" "$rc" "0" "$out"
assert_not_contains "a [[ ]] inside a command string passes" "$out" "tests/bare.bats"
rm "$TMP/tests/bare.bats"

if command -v luau-analyze >/dev/null 2>&1; then
    mkdir -p "$TMP/tests/lua"
    printf 'local unused = 1\nreturn arg\n' >"$TMP/tests/lua/ok.luau"
    out="$(lint)"
    rc=$?
    assert_eq "a luau file with a global from the definitions file passes" "$rc" "0" "$out"
    assert_contains "a luau file is type-checked" "$out" "Type-checking luau with luau-analyze"
    assert_not_contains "a luau file never reaches selene" "$out" "Linting lua with selene"
    assert_not_contains "a luau file never reaches ast-grep" "$out" "Linting lua with ast-grep"
    rm "$TMP/tests/lua/ok.luau"

    printf 'return no_such_global\n' >"$TMP/tests/lua/bad.luau"
    out="$(lint)"
    rc=$?
    assert_eq "a luau type error exits non-zero" "$((rc != 0))" "1"
    assert_contains "a luau type error is named by luau-analyze" "$out" "tests/lua/bad.luau(1,"
    assert_contains "a luau type error carries luau-analyze's message" "$out" "Unknown global 'no_such_global'"
    rm "$TMP/tests/lua/bad.luau"
else
    printf 'skip - the luau type check (needs luau-analyze)\n'
fi

if command -v selene >/dev/null 2>&1; then
    printf 'local unused = 1\n' >"$TMP/.ci/x.lua"
    out="$(lint)"
    rc=$?
    assert_eq "a lua violation under .ci exits non-zero" "$((rc != 0))" "1"
    assert_contains "a lua violation under .ci is named by selene" "$out" ".ci/x.lua"
    assert_contains "a lua file under .ci gets selene" "$out" "Linting lua with selene"
    assert_not_contains "a lua file under .ci is never type-checked" "$out" "x.lua(1,"
    rm "$TMP/.ci/x.lua"
    out="$(lint)"
    rc=$?
    assert_eq "the tree passes again once the .ci violation is gone" "$rc" "0" "$out"
else
    printf 'skip - the .dev lua violation (needs selene)\n'
fi

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall lint tests passed\n'
