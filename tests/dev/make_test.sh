#!/usr/bin/env bash
# Pure-bash tests for the dotfiles verbs behind `dev` and the Makefile aliases.
# TARGET_DIR and SRC_DIR point at a temp tree, so nothing touches $HOME.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SRC_DIR="$TMP/src"
export TARGET_DIR="$TMP/target"
mkdir -p "$SRC_DIR/throwaway/.config/throwaway" "$TARGET_DIR"
echo hello >"$SRC_DIR/throwaway/.config/throwaway/conf"

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

# dev <args...>: run the dispatcher from the repo root.
dev() {
    (cd "$REPO" && "$DEV" "$@")
}

# --- list ---
out="$(dev list)"
assert_contains "list prints a default package" "$out" "+ nvim"
assert_contains "list prints the shell package" "$out" "+ zsh"
assert_eq "list prints one line per default" "$(printf '%s\n' "$out" | grep -c '^+ ')" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_eq "make list agrees with dev list" "$(cd "$REPO" && make -s list)" "$out"

# --- install and uninstall ---
out="$(dev install throwaway)"
assert_eq "install reports the package" "$out" "> Installing throwaway... DONE"
assert_eq "install links into the target" "$(find "$TARGET_DIR" -type l | grep -q . && echo linked)" "linked"
assert_eq "linked file reads through" "$(cat "$TARGET_DIR/.config/throwaway/conf")" "hello"

out="$(dev uninstall throwaway)"
assert_eq "uninstall reports the package" "$out" "> Uninstalling throwaway... DONE"
assert_eq "uninstall removes the link" "$([ -e "$TARGET_DIR/.config/throwaway/conf" ] && echo present || echo gone)" "gone"

out="$(cd "$REPO" && make -s install-throwaway)"
assert_eq "make install-% delegates the package" "$out" "> Installing throwaway... DONE"
dev uninstall throwaway >/dev/null
# Purge deletes real files too, which stow would refuse to replace.
mkdir -p "$TARGET_DIR/.config/throwaway"
echo stray >"$TARGET_DIR/.config/throwaway/conf"
dev purge throwaway >/dev/null
assert_eq "purge removes the file" "$([ -e "$TARGET_DIR/.config/throwaway/conf" ] && echo present || echo gone)" "gone"
assert_eq "purge leaves the source alone" "$(cat "$SRC_DIR/throwaway/.config/throwaway/conf")" "hello"

# --- check ---
manifest="$TMP/tools.tsv"
header="$(rg -v '^\s*#|^\s*$' "$REPO/tools.tsv" | head -n1)"
cols="$(printf '%s\n' "$header" | wc -w | tr -d ' ')"
row="no-such-tool no-such-binary-zzz"
for ((i = 2; i < cols; i++)); do
    row="$row no-such-package-zzz"
done
printf '%s\n%s\n' "$header" "$row" >"$manifest"
out="$(dev check --manifest "$manifest" 2>&1)"
assert_contains "check reports a missing binary" "$out" "[ ] no-such-tool"

# --- make help ---
help="$(cd "$REPO" && make -s help)"
missing=""
for target in all help check install-tools list lint test check-pi stow clean sync setup install install-work install-lazygit install-gpg install-ssh install-antinote antinote-export antinote-diff install-pi pi-save pi-diff 'install-%' 'restow-%' uninstall 'uninstall-%' purge 'purge-%'; do
    if ! printf '%s\n' "$help" | grep -Fq "$target "; then
        missing="$missing $target"
    fi
done
assert_eq "make help lists every target" "$missing" ""

# --- make delegates ---
assert_eq "make -n install-nvim delegates" "$(cd "$REPO" && make -n install-nvim)" "bash .dev/install.sh nvim"
assert_eq "make -n uninstall-nvim delegates" "$(cd "$REPO" && make -n uninstall-nvim)" "bash .dev/uninstall.sh nvim"
assert_eq "make -n restow-nvim delegates" "$(cd "$REPO" && make -n restow-nvim)" "bash .dev/restow.sh nvim"
assert_eq "make -n purge-nvim delegates" "$(cd "$REPO" && make -n purge-nvim)" "bash .dev/purge.sh nvim"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall make tests passed\n'
