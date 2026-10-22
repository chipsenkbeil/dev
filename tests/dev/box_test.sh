#!/usr/bin/env bash
# Pure-bash tests for `dev box`. ci is a stub first on PATH that logs its arguments, one per
# line, and answers from fixture files in $FX.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE DEV_CI

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
STUBS="$TMP/stubs"
FX="$TMP/fx"
export LOG="$TMP/log" FX
mkdir -p "$STUBS" "$FX"

cat >"$STUBS/ci" <<'STUB'
#!/bin/sh
{ echo ci; printf '%s\n' "$@"; echo '#'; } >>"$LOG"
sub=$2
[ ! -f "$FX/$sub.err" ] || cat "$FX/$sub.err" >&2
[ ! -f "$FX/$sub.json" ] || cat "$FX/$sub.json"
exit "$(cat "$FX/$sub.rc" 2>/dev/null || echo 0)"
STUB
chmod +x "$STUBS"/*

BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")"
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

# calls: the logged commands, one line each with the arguments joined by spaces.
calls() {
    awk '$0 == "#" { print line; line = ""; next } { line = line (line == "" ? "" : " ") $0 }' "$LOG"
}

# fx <sub> <json> [rc]: the fixture ci answers for a subcommand.
fx() {
    printf '%s\n' "$2" >"$FX/$1.json"
    if [ -n "${3:-}" ]; then echo "$3" >"$FX/$1.rc"; fi
}

reset() {
    rm -f "${FX:?}"/* "$LOG"
    : >"$LOG"
}

# box <args...>: run dev from a directory outside any project, with the stubs on PATH.
NOPROJ="$TMP/noproj"
mkdir -p "$NOPROJ"
box() {
    (cd "$NOPROJ" && PATH="$STUBS:$BASE_PATH" "$DEV" "$@")
}

PROJ="$TMP/myproject"
mkdir -p "$PROJ/.git"
inproj() {
    (cd "$PROJ" && PATH="$STUBS:$BASE_PATH" "$DEV" "$@")
}

# mkbox <name> <state> <projects json> <expires offset s|null> <delete offset s|null>
mkbox() {
    jq -nc --arg name "$1" --arg state "$2" --argjson names "$3" --argjson exp "$4" --argjson del "$5" '{
        name: $name, state: $state, profile: "medium", cpu: 8, memory_gib: 16, projects: ($names | map({name: ., path: "/home/user/projects/\(.)"})),
        tailnet_name: "box-\($name)", created_at: "2026-10-19T14:03:11Z", ttl_hours: 4,
        expires_at: (if $exp == null then null else now + $exp | floor | todate end),
        stopped_at: null,
        delete_after: (if $del == null then null else now + $del | floor | todate end),
        tmux_sessions: null, archive: null, error: null}'
}

answer_late() {
    while printf '%s\n' "$1"; do sleep 0.2; done
}

left_str() {
    local s=$(($1 - 60))
    printf '%dh%dm left' $((s / 3600)) $(((s % 3600) / 60))
}

doc() {
    jq -nc --argjson b "$1" '{ok: true, box: $b}'
}

lsdoc() {
    jq -nc --argjson cap "$CAP" '{ok: true, boxes: $ARGS.positional | map(fromjson), cap: $cap}' --args "$@"
}

CAP='{"running":2,"running_max":3,"memory_gib":24,"memory_max_gib":32}'
RUN_OFF=12600
NEW_OFF=16200
STOP_OFF=561600
RUN_LEFT="$(left_str "$RUN_OFF")"
NEW_LEFT="$(left_str "$NEW_OFF")"
STOP_LEFT="deleted in $((STOP_OFF / 86400))d"
RUNNING="$(mkbox myproject-k3x running '["myproject"]' "$RUN_OFF" null)"
STOPPED="$(mkbox ci-abc stopped '["ci","dotfiles"]' null "$STOP_OFF")"
KEPT="$(mkbox scratch-a1b running '[]' null null)"
CREATING="$(mkbox new-111 creating '[]' null null)"

# --- ls ---

reset
fx ls "$(lsdoc "$RUNNING" "$STOPPED" "$KEPT" "$CREATING")"
out="$(box box ls)"
assert_eq "ls renders a row per box and the cap line" "$out" "myproject-k3x  running   medium  myproject    $RUN_LEFT
ci-abc         stopped   medium  ci,dotfiles  $STOP_LEFT
scratch-a1b    running   medium  -            kept
new-111        creating  medium  -
2 of 3 running, 24 of 32 GiB"
assert_eq "ls asks ci for json" "$(calls)" "ci box ls --json"
reset
fx ls "$(lsdoc)"
out="$(box box ls --all)"
assert_eq "ls with no boxes says so before the cap line" "$out" "no boxes
2 of 3 running, 24 of 32 GiB"
assert_eq "ls --all passes --all" "$(calls)" "ci box ls --json --all"
out="$(box box ls extra 2>&1)"
assert_eq "ls rejects an argument" "$?" "2"

# --- create ---

reset
fx create "$(doc "$(mkbox myproject-k3x running '["myproject"]' "$NEW_OFF" null)")"
out="$(inproj box create)"
assert_eq "create prints the summary" "$out" "created myproject-k3x (medium, myproject), $NEW_LEFT, host box-myproject-k3x"
assert_eq "create inside a project defaults --project to its basename" "$(calls)" "ci box create --project myproject --json"
reset
fx create "$(doc "$KEPT")"
out="$(inproj box create --profile large --project a --project b --keep)"
assert_eq "create with explicit projects skips the default" "$(calls)" "ci box create --profile large --project a --project b --keep --json"
assert_contains "create shows kept and no projects" "$out" "created scratch-a1b (medium, -), kept, host box-scratch-a1b"
reset
box box create >/dev/null 2>&1
assert_eq "create outside a project passes no project" "$(calls)" "ci box create --json"
reset
box box create --ttl 6 >/dev/null 2>&1
assert_eq "create passes --ttl" "$(calls)" "ci box create --ttl 6 --json"
reset
out="$(box box create --ttl 3 --keep 2>&1)"
assert_eq "create refuses --ttl with --keep" "$?" "2"
assert_contains "the --ttl and --keep refusal says why" "$out" "--ttl and --keep cannot be combined"
assert_eq "ci is not called for --ttl with --keep" "$(calls)" ""
out="$(box box create --profile huge 2>&1)"
assert_eq "create refuses an unknown profile" "$?" "2"
out="$(box box create --nope 2>&1)"
assert_contains "create names an unknown flag" "$out" "dev box create: unknown flag --nope"

# --- show, stop, resume, extend, delete ---

reset
fx show "$(doc "$(jq -c '.tmux_sessions = ["myproject", "main"] | .expires_at = "2026-10-20T02:03:11Z"' <<<"$RUNNING")")"
out="$(box box show myproject-k3x)"
assert_eq "show argv" "$(calls)" "ci box show myproject-k3x --json"
assert_eq "show renders key: value lines" "$out" "name: myproject-k3x
state: running
profile: medium
cpu: 8
memory_gib: 16
projects: myproject
tailnet_name: box-myproject-k3x
created_at: 2026-10-19T14:03:11Z
ttl_hours: 4
expires_at: 2026-10-20T02:03:11Z
tmux_sessions: myproject,main"
reset
fx show "$(doc "$KEPT")"
out="$(box box show scratch-a1b)"
assert_not_contains "show leaves out a null tmux_sessions" "$out" "tmux_sessions"
reset
NOHOST="$(jq -c '.tailnet_name = null | .state = "creating" | .expires_at = null' <<<"$RUNNING")"
fx show "$(doc "$NOHOST")"
out="$(box box show myproject-k3x)"
assert_contains "show prints - for a null tailnet_name" "$out" "tailnet_name: -"
reset
fx create "$(doc "$NOHOST")"
out="$(box box create)"
assert_eq "create prints host - for a null tailnet_name" "$out" "created myproject-k3x (medium, myproject), creating, host -"
reset
fx resume "$(doc "$NOHOST")"
out="$(box box resume myproject-k3x)"
assert_contains "resume prints host - for a null tailnet_name" "$out" ", host -"
out="$(box box show 2>&1)"
assert_eq "show needs a box" "$?" "2"
reset
out="$(box box show 'Bad Name' 2>&1)"
assert_eq "show refuses a bad box name" "$?" "2"
assert_contains "the bad name is named" "$out" "bad box name Bad Name"
assert_eq "ci is not called for a bad box name" "$(calls)" ""

reset
fx stop "$(doc "$STOPPED")"
out="$(box box stop ci-abc)"
assert_eq "stop argv" "$(calls)" "ci box stop ci-abc --json"
assert_eq "stop output" "$out" "stopped ci-abc, deleted in $(((STOP_OFF + 86399) / 86400))d unless resumed"

reset
fx resume "$(doc "$RUNNING")"
out="$(box box resume myproject-k3x --ttl 2)"
assert_eq "resume argv" "$(calls)" "ci box resume myproject-k3x --ttl 2 --json"
assert_eq "resume output" "$out" "resumed myproject-k3x (medium, myproject), $RUN_LEFT, host box-myproject-k3x"

reset
fx extend "$(doc "$RUNNING")"
box box extend myproject-k3x --ttl 8 >/dev/null 2>&1
assert_eq "extend --ttl argv" "$(calls)" "ci box extend myproject-k3x --ttl 8 --json"
reset
box box extend myproject-k3x --keep >/dev/null 2>&1
assert_eq "extend --keep argv" "$(calls)" "ci box extend myproject-k3x --keep --json"
reset
out="$(box box extend myproject-k3x 2>&1)"
assert_eq "extend needs --ttl or --keep" "$?" "2"
assert_contains "extend names what it needs" "$out" "needs --ttl HOURS or --keep"
assert_eq "ci is not called for a bare extend" "$(calls)" ""
out="$(box box extend myproject-k3x --ttl 2 --keep 2>&1)"
assert_eq "extend refuses --ttl with --keep" "$?" "2"

reset
fx delete "$(doc "$(jq -c '.state = "deleted" | .archive = {path: "/var/lib/devbox-archive/x.tar.gz", bytes: 5, created_at: "2026-10-20T00:00:00Z"}' <<<"$STOPPED")")"
if { : </dev/tty; } 2>/dev/null; then
    echo "SKIP - delete without a terminal (this shell has a controlling tty and no way to drop it)"
else
    out="$(box box delete ci-abc 2>&1 </dev/null)"
    assert_eq "delete without a tty or -y exits 2" "$?" "2"
    assert_contains "the delete refusal names -y" "$out" "pass -y"
    assert_eq "ci is not called by a refused delete" "$(calls)" ""
fi
out="$(box box delete ci-abc -y)"
assert_eq "delete -y argv" "$(calls)" "ci box delete ci-abc --json"
assert_eq "delete -y output" "$out" "deleted ci-abc, archive /var/lib/devbox-archive/x.tar.gz"

if script -q /dev/null true </dev/null >/dev/null 2>&1; then
    PTY=bsd
elif script -qec true /dev/null </dev/null >/dev/null 2>&1; then
    PTY=gnu
else
    PTY=""
fi
if [ -z "$PTY" ]; then
    echo "SKIP - the delete prompt tests (script is missing or unusable)"
else
    cat >"$TMP/delete.sh" <<RUN
cd "$NOPROJ" && PATH="$STUBS:$BASE_PATH" exec "$DEV" box delete ci-abc
RUN
    for answer in n y; do
        reset
        fx delete "$(doc "$STOPPED")"
        if [ "$PTY" = bsd ]; then
            out="$(
                answer_late "$answer" 2>/dev/null | script -q /dev/null bash "$TMP/delete.sh" 2>&1
                exit "${PIPESTATUS[1]}"
            )"
        else
            out="$(
                answer_late "$answer" 2>/dev/null | script -qec "bash $TMP/delete.sh" /dev/null 2>&1
                exit "${PIPESTATUS[1]}"
            )"
        fi
        rc=$?
        assert_contains "the delete prompt asks the question" "$out" "Delete ci-abc? Its projects are archived first. [y/N]"
        if [ "$answer" = n ]; then
            assert_eq "answering n exits 1" "$rc" "1"
            assert_eq "answering n never calls ci" "$(calls)" ""
        else
            assert_eq "answering y exits 0" "$rc" "0"
            assert_eq "answering y deletes" "$(calls)" "ci box delete ci-abc --json"
        fi
    done
fi

# --- errors ---

reset
fx create '{"ok":false,"error":{"code":"over_cap","message":"Box cap is full (3 of 3 running): a, b, c. Stop one with ci box stop NAME"}}' 4
out="$(box box create 2>&1)"
assert_eq "over_cap exits with ci's code" "$?" "4"
assert_eq "over_cap prints the message" "$out" "dev box create: Box cap is full (3 of 3 running): a, b, c. Stop one with ci box stop NAME"
reset
fx show '{"ok":false,"error":{"code":"not_found","message":"no box named nope"}}' 3
out="$(box box show nope 2>&1)"
assert_eq "not_found exits 3" "$?" "3"
assert_eq "not_found prints the message" "$out" "dev box show: no box named nope"
reset
fx ls '{"ok":false,"error":{"code":"hub_unreachable","message":"cannot reach the hub"}}' 10
out="$(box box ls 2>&1)"
assert_eq "hub_unreachable exits 10" "$?" "10"
assert_contains "hub_unreachable prints the message" "$out" "dev box ls: cannot reach the hub"
reset
fx ls '{"ok":false,"error":{"code":"protocol_mismatch","message":"hub speaks another protocol"}}' 11
out="$(box box ls 2>&1)"
assert_eq "protocol_mismatch exits 11" "$?" "11"
reset
echo "error: unexpected argument '--bogus'" >"$FX/ls.err"
echo 2 >"$FX/ls.rc"
out="$(box box ls 2>&1)"
assert_eq "non-JSON usage text keeps ci's exit code" "$?" "2"
assert_eq "non-JSON usage text passes through" "$out" "error: unexpected argument '--bogus'"
reset
fx ls "usage: ci box ls [--all]" 2
out="$(box box ls 2>&1 >/dev/null)"
assert_eq "text on ci's stdout with a failure keeps ci's code" "$?" "2"
assert_eq "text on ci's stdout with a failure passes through on stderr" "$out" "usage: ci box ls [--all]"
reset
fx ls '{"ok":false,"error":{"code":"internal"}}' 1
out="$(box box ls 2>&1 >/dev/null)"
assert_eq "an error document with no message exits with ci's code" "$?" "1"
assert_contains "an error document with no message is printed as it is" "$out" '"code":"internal"'
reset
fx create "$(doc "$RUNNING")"
echo "ci: cloning myproject" >"$FX/create.err"
out="$(box box create 2>&1 >/dev/null)"
assert_eq "ci's progress lines reach stderr" "$out" "ci: cloning myproject"
out="$(cd "$NOPROJ" && PATH="$BASE_PATH" "$DEV" box ls 2>&1)"
assert_eq "a missing ci is an error" "$?" "1"
assert_contains "the missing ci is named" "$out" "ci not found"

# --- dispatch ---

out="$(box --ci box ls 2>&1)"
assert_eq "--ci refuses box ls" "$?" "2"
assert_contains "--ci names the refused subcommand" "$out" "dev box ls: --ci cannot run this verb"
out="$(box help)"
assert_contains "dev help lists box" "$out" "box "
out="$(box help box)"
for sub in ls create show stop resume extend delete; do
    assert_contains "dev help box lists $sub" "$out" "  $sub "
done
out="$(box help box create)"
assert_contains "create help states the default lifetime" "$out" "4 hours"
assert_contains "create help states the default profile" "$out" "profile medium"
assert_contains "create help lists --keep" "$out" "--keep"
assert_eq "__subs box lists the subcommands" "$(box __subs box | cut -f1 | paste -sd' ' -)" "ls create show stop resume extend delete"
assert_eq "__flags box create" "$(box __flags box create | paste -sd' ' -)" "--profile --project --ttl --keep -v --verbose -vv --ci"
assert_eq "__flags box delete" "$(box __flags box delete | sed -n 1,2p | paste -sd' ' -)" "--yes -y"
assert_eq "__flags box ls" "$(box __flags box ls | sed -n 1p)" "--all"
TOPICPROJ="$TMP/topicproj"
mkdir -p "$TOPICPROJ/.dev/topics" "$TOPICPROJ/.git"
FENCE="$(printf '\140\140\140')"
printf '%s\n' '# frob: scratch' '' "$FENCE" 'dev box ls --all' 'dev box frob' 'dev box ls --nope' "$FENCE" >"$TOPICPROJ/.dev/topics/frob.md"
out="$(cd "$TOPICPROJ" && "$DEV" __check-topics 2>&1)"
assert_eq "__check-topics fails on a bad box line" "$?" "1"
assert_contains "__check-topics names the bad box subcommand" "$out" "dev box has no subcommand frob"
assert_contains "__check-topics names the bad box flag" "$out" "dev box ls takes no flag --nope"
assert_not_contains "__check-topics accepts a good box line" "$out" "--all"
out="$(box box frobnicate 2>&1)"
assert_eq "an unknown box subcommand exits 2" "$?" "2"
assert_contains "an unknown box subcommand is named" "$out" "dev box: unknown subcommand frobnicate"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall box tests passed\n'
