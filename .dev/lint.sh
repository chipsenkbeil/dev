#!/usr/bin/env bash
# Run shellcheck on every bash script under the shell roots, then report shfmt drift.
# Exit non-zero when shellcheck fails. shfmt findings are reported only.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ROOTS=(bootstrap.sh scripts tests .dev dotfiles/bin dotfiles/jj/.config/jj/scripts)

# Every regular file under the roots whose name ends in .sh or whose shebang names bash.
files=()
while IFS= read -r f; do
    if [[ $f == *.sh ]] || head -n1 "$f" | grep -q 'bash'; then
        files+=("$f")
    fi
done < <(find "${ROOTS[@]}" -type f ! -name '*.bats' | sort)

status=0
fmt_dirty=()
for f in "${files[@]}"; do
    printf '> Linting %s\n' "$f"
    if head -n1 "$f" | grep -q 'bash'; then
        shellcheck -x -P SCRIPTDIR "$f" || status=1
    elif head -n1 "$f" | grep -q 'zsh'; then
        printf '  skip (zsh)\n'
        continue
    else
        shellcheck -x -P SCRIPTDIR -s sh "$f" || status=1
    fi
    if command -v shfmt >/dev/null 2>&1 && ! shfmt -i 4 -d "$f" >/dev/null 2>&1; then
        fmt_dirty+=("$f")
    fi
done

if [ "${#fmt_dirty[@]}" -gt 0 ]; then
    printf '\nshfmt -i 4 would change (left as is):\n'
    printf '  %s\n' "${fmt_dirty[@]}"
fi
exit "$status"
