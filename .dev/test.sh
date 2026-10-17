#!/usr/bin/env bash
# Run every test suite under tests/ and report each by name.
# Suites: each .bats file via bats, each *_test.sh and test-*.sh script, and the
# neomutt scripts (only when neomutt and tmux are both on PATH).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v bats >/dev/null 2>&1; then
    printf 'WARNING: bats not found. Install with: brew install bats-core\n' >&2
    exit 1
fi

failed=0
passed=0

# run_suite <name> <command...>: run one suite and record pass or fail.
run_suite() {
    local name=$1
    shift
    printf '> %s\n' "$name"
    if "$@"; then
        printf 'PASS %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$name"
        failed=$((failed + 1))
    fi
}

while IFS= read -r f; do
    run_suite "$f" bats "$f"
done < <(find tests -name '*.bats' | sort)

while IFS= read -r f; do
    run_suite "$f" bash "$f"
done < <(find tests \( -name '*_test.sh' -o -name 'test-*.sh' \) | sort)

# The neomutt scripts are not named test-*, and they drive a live neomutt in tmux.
if command -v neomutt >/dev/null 2>&1 && command -v tmux >/dev/null 2>&1; then
    for f in tests/neomutt/filter-bytes.sh tests/neomutt/pager-passthrough.sh; do
        run_suite "$f" bash "$f"
    done
else
    printf 'SKIP tests/neomutt/*.sh (needs neomutt and tmux on PATH)\n'
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
