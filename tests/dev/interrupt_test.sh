#!/usr/bin/env bash
# Tests that Ctrl-C on dev test stops the running suites and removes the scratch directory.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="${DEV_BIN:-$REPO/target/debug/dev}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v bats >/dev/null 2>&1; then
    printf 'skip - the test verb needs bats\n'
    exit 3
fi

fails=0
ALIVE_WAIT_POLLS=50
LAUNCH_WAIT_POLLS=150

count_alive() {
    local alive=0 pid waited
    while IFS= read -r pid; do
        waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$ALIVE_WAIT_POLLS" ]; do
            sleep 0.2
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            alive=$((alive + 1))
            printf 'survived %s\n' "$(ps -o pid=,pgid=,args= -p "$pid")" >&2
            kill -KILL "$pid" 2>/dev/null
        fi
    done <"$1"
    printf '%s\n' "$alive"
}

seed_project() {
    local dir="$1"
    mkdir -p "$dir/.dev/lib/devrepo" "$dir/.dev/commands" "$dir/tests/a"
    cp "$REPO/.dev/commands/test.luau" "$dir/.dev/commands/test.luau"
    cp "$REPO/.dev/lib/devrepo/checks.luau" "$REPO/.dev/lib/devrepo/supervise.luau" "$dir/.dev/lib/devrepo/"
    cp "$REPO/.luaurc" "$dir/"
}

assert_eq() {
    if [ "$2" = "$3" ]; then
        printf 'ok   - %s\n' "$1"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

seed_project "$TMP"
mkdir -p "$TMP/run"
for n in 1 2 3; do
    cat >"$TMP/tests/a/slow${n}_test.sh" <<'SUITE'
printf '%s\n' "$$" >>"$PIDS"
printf '%s\n' "$TMPDIR" >>"$TMPDIRS"
sleep 300 &
printf '%s\n' "$!" >>"$PIDS"
wait
SUITE
done

export PIDS="$TMP/run/pids" TMPDIRS="$TMP/run/tmpdirs" DEV_TEST_JOBS=3
: >"$PIDS"
: >"$TMPDIRS"

set -m
(cd "$TMP" && exec "$DEV" test) >"$TMP/run/out" 2>&1 &
devpid=$!
set +m

waited=0
while [ "$(wc -l <"$PIDS")" -lt 6 ] && [ "$waited" -lt 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "all three suites and their sleeps started" "$(wc -l <"$PIDS" | tr -d ' ')" "6"

too_long=0
while IFS= read -r path; do
    [ "${#path}" -lt 60 ] || too_long=$((too_long + 1))
done <"$TMPDIRS"
assert_eq "each suite's TMPDIR is under 60 characters" "$too_long" "0"

scratch="$(dirname "$(head -n 1 "$TMPDIRS")")"
assert_eq "the scratch directory exists while the suites run" "$([ -d "$scratch" ] && echo yes)" "yes"

kill -INT -- "-$devpid"
wait "$devpid"
rc=$?
assert_eq "dev test exits 130 on INT" "$rc" "130"

waited=0
while [ -d "$scratch" ] && [ "$waited" -lt 100 ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "the scratch directory is removed" "$([ -d "$scratch" ] && echo present || echo gone)" "gone"

assert_eq "no suite process is left running" "$(count_alive "$PIDS")" "0"

mkdir -p "$TMP/shim"
seed_project "$TMP/b"
cp "$TMP/tests/a/slow1_test.sh" "$TMP/b/tests/a/"
REAL_SH="$(command -v sh)"
cat >"$TMP/shim/sh" <<'SHIM'
#!/usr/bin/env bash
if [[ "$2" == *'pidfile=$4'* ]]; then
    trap : INT
    pidwrite='echo "$!" >"$pidfile"'
    script="${2/"$pidwrite"/"kill -INT 0; sleep ${HOLD:-1}; $pidwrite"}"
    out="$("$REAL_SH" -c "$script" "${@:3}")"
    printf '%s\n' "$out"
else
    exec "$REAL_SH" "$@"
fi
SHIM
chmod +x "$TMP/shim/sh"

export REAL_SH PIDS="$TMP/run/pids2" TMPDIRS="$TMP/run/tmpdirs2"
: >"$PIDS"
: >"$TMPDIRS"

set -m
(cd "$TMP/b" && PATH="$TMP/shim:$PATH" exec "$DEV" test) >"$TMP/run/out2" 2>&1 &
devpid=$!
set +m

waited=0
while [ "$(wc -l <"$PIDS")" -lt 2 ] && [ "$waited" -lt "$LAUNCH_WAIT_POLLS" ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "the suite and its sleep started" "$(wc -l <"$PIDS" | tr -d ' ')" "2"
wait "$devpid"
assert_eq "dev test exits 130 on an INT that lands while a suite is still being launched" "$?" "130"
scratch2="$(dirname "$(head -n 1 "$TMPDIRS")")"
assert_eq "the scratch directory is removed after the late INT" "$([ -d "$scratch2" ] && echo present || echo gone)" "gone"
assert_eq "a suite launched at the moment of INT is stopped" "$(count_alive "$PIDS")" "0"

seed_project "$TMP/c"
cp "$TMP/tests/a/slow1_test.sh" "$TMP/c/tests/a/"

export HOLD=7 PIDS="$TMP/run/pids3" TMPDIRS="$TMP/run/tmpdirs3"
: >"$PIDS"
: >"$TMPDIRS"

set -m
(cd "$TMP/c" && PATH="$TMP/shim:$PATH" exec "$DEV" test) >"$TMP/run/out3" 2>&1 &
devpid=$!
set +m

waited=0
while [ "$(wc -l <"$PIDS")" -lt 2 ] && [ "$waited" -lt "$LAUNCH_WAIT_POLLS" ]; do
    sleep 0.2
    waited=$((waited + 1))
done
assert_eq "the suite and its sleep started before the held launch" "$(wc -l <"$PIDS" | tr -d ' ')" "2"
wait "$devpid"
assert_eq "dev test exits 130 on an INT that lands during a launch held past the grace wait" "$?" "130"
assert_eq "a suite whose launch outlasts dev is stopped" "$(count_alive "$PIDS")" "0"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall interrupt tests passed\n'
