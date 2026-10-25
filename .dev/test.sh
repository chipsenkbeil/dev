#!/usr/bin/env bash
# Run every test suite under tests/ and report each by name.
# Suites: each .bats file via bats, each *_test.sh and test-*.sh script, each *_test.lua via luajit, and the
# neomutt scripts (only when neomutt and tmux are both on PATH).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

no_args

if ! command -v bats >/dev/null 2>&1; then
    printf 'WARNING: bats not found. Install with: brew install bats-core\n' >&2
    exit 1
fi

failed=0
passed=0
skipped=0
SKIPPED=3

# run_suite <name> <command...>: run one suite and record pass, skip or fail. A command that
# exits with SKIPPED ran nothing.
run_suite() {
    local name=$1 rc=0
    shift
    printf '> %s\n' "$name"
    "$@" || rc=$?
    case "$rc" in
    0)
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
        ;;
    "$SKIPPED")
        printf 'SKIP %s (every case skipped)\n' "$name"
        skipped=$((skipped + 1))
        ;;
    *)
        printf 'FAIL %s\n' "$name"
        failed=$((failed + 1))
        ;;
    esac
}

run_bats() {
    local out rc=0 line
    out=$(bats --tap "$1" 2>&1) || rc=$?
    printf '%s\n' "$out"
    [ "$rc" -eq 0 ] || return "$rc"
    while IFS= read -r line; do
        case "$line" in
        'ok '*'# skip'*) ;;
        'ok '*) return 0 ;;
        esac
    done <<<"$out"
    return "$SKIPPED"
}

while IFS= read -r f; do
    run_suite "$f" run_bats "$f"
done < <(find tests -name '*.bats' | sort)

while IFS= read -r f; do
    run_suite "$f" bash "$f"
done < <(find tests \( -name '*_test.sh' -o -name 'test-*.sh' \) | sort)

if command -v luajit >/dev/null 2>&1; then
    while IFS= read -r f; do
        run_suite "$f" luajit tests/lua/run.lua "$f"
    done < <(find tests -name '*_test.lua' | sort)
else
    printf 'SKIP tests/lua (needs luajit)\n'
fi

# The neomutt scripts are not named test-*, and they drive a live neomutt in tmux.
if command -v neomutt >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
    for f in tests/neomutt/filter-bytes.sh tests/neomutt/pager-passthrough.sh; do
        run_suite "$f" bash "$f"
    done
    run_suite tests/neomutt/parse-check.sh bash tests/neomutt/parse-check.sh dotfiles/neomutt/.config/neomutt/colors.mutt
else
    printf 'SKIP tests/neomutt/*.sh (needs neomutt and tmux on PATH)\n'
fi

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
