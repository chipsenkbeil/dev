#!/usr/bin/env bash
# Pure-bash tests for dev fetch. A fake cargo logs its argv and CARGO_NET_OFFLINE, so no test touches the network.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
export DOTFILES="$REPO"
unset VERBOSE CI
export DEV_REMOTE=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"
export CARGO_LOG="$TMP/cargo.log"
mkdir -p "$STUBS"
cat >"$STUBS/cargo" <<'STUB'
#!/usr/bin/env bash
echo "cargo $* offline=${CARGO_NET_OFFLINE-unset}" >>"$CARGO_LOG"
if [ "$1" = fetch ] && [ -n "${FAIL_FETCH:-}" ]; then exit "$FAIL_FETCH"; fi
exit 0
STUB
chmod +x "$STUBS/cargo"

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

# project <name> <type>: a throwaway project of that type, printed as its path.
project() {
    local dir="$TMP/$1"
    mkdir -p "$dir/.dev"
    case "$2" in
    rust) printf '[package]\nname = "p"\nversion = "0.1.0"\n' >"$dir/Cargo.toml" ;;
    lua) printf 'return 1\n' >"$dir/x.lua" ;;
    esac
    printf '%s\n' "$dir"
}

# run_fetch <dir> <args...>: run dev in the project with the fake cargo first on PATH and a clean log.
run_fetch() {
    local dir="$1"
    shift
    : >"$CARGO_LOG"
    (cd "$dir" && PATH="$STUBS:$PATH" "$DEV" "$@" 2>&1)
}

plain="$(project plain rust)"
out="$(CARGO_NET_OFFLINE=true run_fetch "$plain" fetch)"
assert_eq "fetch exits 0" "$?" "0"
assert_eq "fetch runs cargo fetch --locked with the network on, only that" "$(cat "$CARGO_LOG")" "cargo fetch --locked offline=false"

: >"$CARGO_LOG"
out="$(run_fetch "$plain" fetch)"
assert_eq "fetch sets CARGO_NET_OFFLINE when the caller left it unset" "$(cat "$CARGO_LOG")" "cargo fetch --locked offline=false"

deny="$(project deny rust)"
: >"$deny/deny.toml"
out="$(CARGO_NET_OFFLINE=true run_fetch "$deny" fetch)"
assert_eq "fetch with deny.toml exits 0" "$?" "0"
assert_eq "fetch with deny.toml also runs cargo deny fetch" "$(cat "$CARGO_LOG")" "cargo fetch --locked offline=false
cargo deny --version offline=true
cargo deny fetch offline=false"

bad="$(project bad rust)"
: >"$bad/deny.toml"
out="$(FAIL_FETCH=7 run_fetch "$bad" fetch)"
assert_eq "a failing cargo fetch exits with its code" "$?" "7"
assert_eq "a failing cargo fetch runs no deny fetch" "$(cat "$CARGO_LOG")" "cargo fetch --locked offline=false"

nodeny="$TMP/nodeny-stubs"
mkdir -p "$nodeny"
cat >"$nodeny/cargo" <<'STUB'
#!/usr/bin/env bash
[ "$1" = deny ] && exit 1
exit 0
STUB
chmod +x "$nodeny/cargo"
out="$(cd "$deny" && PATH="$nodeny:$PATH" "$DEV" fetch 2>&1)"
assert_eq "deny.toml without cargo-deny exits 1" "$?" "1"
assert_contains "the missing cargo-deny is named" "$out" "cargo-deny not found"

out="$(cd "$plain" && PATH="$STUBS:$PATH" "$DEV" -v fetch 2>&1)"
assert_contains "-v shows the command" "$out" "+ env CARGO_NET_OFFLINE=false cargo fetch --locked"

over="$(project over rust)"
printf '#!/usr/bin/env bash\n# Overridden.\necho override ran\n' >"$over/.dev/fetch.sh"
chmod +x "$over/.dev/fetch.sh"
out="$(run_fetch "$over" fetch)"
assert_eq "a project .dev/fetch.sh replaces the built-in" "$out" "override ran"
assert_eq "the override runs no cargo" "$(cat "$CARGO_LOG")" ""

lua="$(project lua lua)"
out="$(run_fetch "$lua" fetch)"
assert_eq "a lua project exits 1" "$?" "1"
assert_contains "a lua project gets the unsupported message" "$out" "There is no built-in fetch for lua projects."

out="$(run_fetch "$plain" --remote fetch)"
assert_eq "--remote fetch exits 2" "$?" "2"
assert_contains "--remote names fetch" "$out" "dev fetch: runs on this machine only, so --remote does not apply"

out="$(run_fetch "$deny" help fetch)"
assert_contains "help fetch shows the fetch command" "$out" "env CARGO_NET_OFFLINE=false cargo fetch --locked"
assert_contains "help fetch shows the deny command with deny.toml" "$out" "env CARGO_NET_OFFLINE=false cargo deny fetch"
out="$(run_fetch "$plain" help fetch)"
case "$out" in
*"cargo deny"*)
    printf 'FAIL - help fetch shows no deny command without deny.toml\n'
    fails=$((fails + 1))
    ;;
*) printf 'ok   - help fetch shows no deny command without deny.toml\n' ;;
esac

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall fetch tests passed\n'
