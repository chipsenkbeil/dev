#!/usr/bin/env bash
# Run shellcheck, shfmt and the comment-spacing check on every bash script under the shell roots.
# Exit non-zero when any of them reports a finding.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

no_args

ROOTS=(bootstrap.sh scripts tests .dev dotfiles/bin dotfiles/jj/.config/jj/scripts)

status=0

# comment_spacing <file>: fail on a full-line comment that directly follows a
# line of code at the same or a deeper indentation. A blank line, another comment
# line, an opening brace line or the top of the file before it passes, and so does
# a comment after a `;;` that heads the next case arm.
comment_spacing() {
    local file=$1 number=0 kind=none prev_indent="" prev_text=""
    local line text indent arm
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        text=${line#"${line%%[![:space:]]*}"}
        indent=${line%"$text"}
        if [ -z "$text" ]; then
            kind=blank
            continue
        fi
        case "$text" in
        '#!'*)
            kind=comment
            continue
            ;;
        '#'*)
            if [ "$kind" = code ] && [ "${#indent}" -le "${#prev_indent}" ]; then
                case "$prev_text" in
                ';;' | ';&' | ';;&') arm=1 ;;
                *) arm=0 ;;
                esac
                if [ "$arm" -eq 0 ] || [ "$indent" = "$prev_indent" ]; then
                    printf '%s:%s: full-line comment directly after code, add a blank line before it\n' "$file" "$number" >&2
                    status=1
                fi
            fi
            kind=comment
            ;;
        *'{')
            kind=open
            prev_indent=$indent
            prev_text=$text
            ;;
        *)
            kind=code
            prev_indent=$indent
            prev_text=$text
            ;;
        esac
    done <"$file"
}

# Every regular file under the roots whose name ends in .sh or whose shebang names bash.
files=()
while IFS= read -r f; do
    if [[ $f == *.sh ]] || head -n1 "$f" | grep -q 'bash'; then
        files+=("$f")
    fi
done < <(find "${ROOTS[@]}" -type f ! -name '*.bats' | sort)

have_shfmt=1
if ! command -v shfmt >/dev/null 2>&1; then
    have_shfmt=0
    printf 'WARNING: shfmt not found, skipping. Install with: brew install shfmt\n' >&2
fi

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
    if [ "$have_shfmt" -eq 1 ] && ! shfmt -i 4 -d "$f" >/dev/null 2>&1; then
        fmt_dirty+=("$f")
    fi
    comment_spacing "$f"
done

if [ "${#fmt_dirty[@]}" -gt 0 ]; then
    printf '\nshfmt -i 4 would change:\n' >&2
    printf '  %s\n' "${fmt_dirty[@]}" >&2
    status=1
fi
exit "$status"
