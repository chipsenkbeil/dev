#!/usr/bin/env bash
# Pure-bash tests for `dev box` and `dev connect`. ci and et are stubs first on PATH that
# log their arguments, one per line, and ci answers from fixture files in $FX. LUA_INIT loads
# tests/lua/fake_env.lua, where FAKE_PICK picks a box and PICK_LOG records the picker items. dev gets no jq.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE CI LOGNAME
export DEV_REMOTE=0
export USER=tester

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
LUABIN="$TMP/luabin"
mkdir -p "$LUABIN"
ln -s "$(command -v luajit)" "$LUABIN/luajit"
STUBS="$TMP/stubs"
FX="$TMP/fx"
JQ="$(command -v jq)"
export LOG="$TMP/log" ITEMS="$TMP/items" FX JQ
export LUA_INIT="@$REPO/tests/lua/fake_env.lua" PICK_LOG="$TMP/items"
export XDG_STATE_HOME="$TMP/state"
KH="$TMP/state/ci/known_hosts"
mkdir -p "$STUBS" "$FX"
TARGET=linux-x86-dev
TARGETS_DOC="$(jq -nc --arg t "$TARGET" '{ok: true, targets: [{target: $t, os: "linux", machines: ["example-box"], image: "devbox", min_shape: null, can_take_box_now: true, reason: null}]}')"
SHAPES_DOC="$(jq -nc --arg t "$TARGET" '{ok: true, default_shape: "medium", shapes: [{name: "medium", cpu: 8, memory_gib: 16, default: true, targets: [{target: $t, below_min: false, machines: [{machine: "example-box", fits: "start", reason: null, warning: null}]}]}], cap: {running: 1, running_max: 3, memory_limits_gib: 16, memory_max_gib: 32}, machines: [{name: "example-box", running: 1, memory_limits_gib: 16, new_box_room_gib: 8, reachable: true}]}')"

cat >"$STUBS/ci" <<'STUB'
#!/bin/sh
{ echo ci; printf '%s\n' "$@"; echo '#'; } >>"$LOG"
sub=$2
if [ "$1" = connect ]; then
    sub=connect.$2
elif [ "$1" = ssh ] && [ "$2" = ls ]; then
    sub=ssh.ls
    if [ ! -f "$FX/$sub.json" ]; then
        echo '{"protocol":1,"things":[],"notes":[]}'
        exit 0
    fi
fi
if [ "$sub" = show ] && [ ! -f "$FX/show.json" ]; then
    for src in resume create; do
        if [ -f "$FX/$src.json" ]; then
            "$JQ" -c '.box.ssh_user = "user"' "$FX/$src.json"
            exit 0
        fi
    done
    "$JQ" -c --arg n "$3" '{ok: true, box: (.boxes[] | select(.name == $n) | .ssh_user = "user")}' "$FX/ls.json"
    exit 0
fi
[ ! -f "$FX/$sub.err" ] || cat "$FX/$sub.err" >&2
[ ! -f "$FX/$sub.json" ] || cat "$FX/$sub.json"
exit "$(cat "$FX/$sub.rc" 2>/dev/null || echo 0)"
STUB
for tool in et ssh; do
    cat >"$STUBS/$tool" <<STUB
#!/bin/sh
{ echo $tool; printf '%s\n' "\$@"; echo '#'; } >>"\$LOG"
STUB
done
chmod +x "$STUBS"/*

BASE_PATH="$LUABIN:/usr/bin:/bin:/usr/sbin:/sbin"
fails=0

assert_eq() {
    local desc="$1" got="$2" want="$3"
    got=$(printf '%s' "$got" | sed -E 's/[0-9]+h[0-9]+m left/NhNm left/g')
    want=$(printf '%s' "$want" | sed -E 's/[0-9]+h[0-9]+m left/NhNm left/g')
    if [ "$got" = "$want" ]; then
        printf 'ok   - %s\n' "$desc"
    else
        printf 'FAIL - %s\n       got:  %q\n       want: %q\n' "$desc" "$got" "$want"
        fails=$((fails + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    haystack=$(printf '%s' "$haystack" | sed -E 's/[0-9]+h[0-9]+m left/NhNm left/g')
    needle=$(printf '%s' "$needle" | sed -E 's/[0-9]+h[0-9]+m left/NhNm left/g')
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
    rm -f "${FX:?}"/* "$LOG" "$ITEMS"
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
    jq -nc --arg target "$TARGET" --arg name "$1" --arg state "$2" --argjson names "$3" --argjson exp "$4" --argjson del "$5" '{
        name: $name, state: $state, target: $target, shape: "medium", machine: "example-box", created_by: "human:tester", cpu: 8, memory_gib: 16,
        projects: ($names | map({name: ., path: "/srv/projects/\(.)"})),
        tailnet_name: $name, ttl_hours: 4,
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
    jq -nc --argjson cap "$CAP" '{ok: true, boxes: $ARGS.positional | map(fromjson), cap: $cap, machines: []}' --args "$@"
}

CAP='{"running":2,"running_max":3,"memory_limits_gib":24,"memory_max_gib":32}'
PROJECTS_DIR=/srv/projects
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
assert_eq "ls prints the hub line from the cap" "$(printf '%s\n' "$out" | sed -n 1p)" "Boxes   2 of 3 running · 1 more can start"
assert_eq "ls renders a header and a row per box" "$(printf '%s\n' "$out" | tail -n +3 | tr -s ' ')" "NAME TARGET STATE ACTIVITY WHO SHAPE PROJECTS TIME LEFT
● myproject-k3x $TARGET @ example-box running ? you medium myproject $RUN_LEFT
○ ci-abc $TARGET @ example-box stopped - you medium ci,dotfiles $STOP_LEFT
● scratch-a1b $TARGET @ example-box running ? you medium - kept
 new-111 $TARGET @ example-box creating - you medium - -"
assert_not_contains "ls has no escape bytes when piped" "$out" "$(printf '\033')"
assert_eq "ls asks ci for json" "$(calls)" "ci box ls --json"
reset
fx ls "$(lsdoc)"
out="$(box box ls --all)"
assert_eq "ls with no boxes says so after the hub line" "$out" "Boxes   2 of 3 running · 1 more can start
no boxes"
assert_eq "ls --all passes --all" "$(calls)" "ci box ls --json --all"
reset
fx ls "$(lsdoc "$RUNNING")"
assert_eq "ls --json prints ci's document" "$(box box ls --json)" "$(cat "$FX/ls.json")"
out="$(box box ls extra 2>&1)"
assert_eq "ls rejects an argument" "$?" "2"

reset
fx targets '{"ok":true,"targets":[]}'
assert_eq "targets --json prints ci's document" "$(box box targets --json)" "$(cat "$FX/targets.json")"
assert_eq "targets reads the structured list" "$(calls)" "ci box targets --json"

# --- create ---

reset
fx create "$(doc "$(mkbox myproject-k3x running '["myproject"]' "$NEW_OFF" null)")"
out="$(inproj box create)"
assert_eq "create prints the summary" "$out" "Created myproject-k3x · $TARGET @ example-box · medium · $NEW_LEFT · dev connect myproject-k3x"
assert_eq "create inside a project defaults --project to its basename" "$(calls)" "ci box create --by human:tester --json -- myproject"
reset
fx create "$(doc "$KEPT")"
out="$(inproj box create --target windows-vm-dev --shape large --by agent:s1 --keep a b)"
assert_eq "create with explicit projects skips the default" "$(calls)" "ci box create --target windows-vm-dev --shape large --by agent:s1 --keep --json -- a b"
assert_contains "create shows kept and no projects" "$out" "Created scratch-a1b · $TARGET @ example-box · medium · kept · dev connect scratch-a1b"
reset
box box create >/dev/null 2>&1
assert_eq "create outside a project passes no project" "$(calls)" "ci box create --by human:tester --json"
reset
box box create --ttl 6 >/dev/null 2>&1
assert_eq "create passes --ttl" "$(calls)" "ci box create --by human:tester --ttl 6 --json"
reset
(
    unset USER
    LOGNAME=lg box box create >/dev/null 2>&1
)
assert_eq "create falls back to LOGNAME for --by" "$(calls)" "ci box create --by human:lg --json"
reset
out="$(
    unset USER
    box box create 2>&1
)"
assert_eq "create with no USER or LOGNAME fails" "$?" "1"
assert_eq "ci is not called without an identity" "$(calls)" ""
reset
out="$(box box create --ttl 3 --keep 2>&1)"
assert_eq "create refuses --ttl with --keep" "$?" "2"
assert_contains "the --ttl and --keep refusal says why" "$out" "--ttl and --keep cannot be combined"
assert_eq "ci is not called for --ttl with --keep" "$(calls)" ""
out="$(box box create --profile large 2>&1)"
assert_eq "create refuses the removed --profile" "$?" "2"
out="$(box box create --project x 2>&1)"
assert_eq "create refuses the removed --project" "$?" "2"
out="$(box box create --nope 2>&1)"
assert_contains "create names an unknown flag" "$out" "dev box create: unknown flag --nope"

# --- show, stop, resume, extend, delete ---

reset
fx show "$(doc "$(jq -c '.tmux_sessions = [{name: "main", attached: true, idle_seconds: 0}, {name: "build", attached: false, idle_seconds: 300}] | .expires_at = "2026-10-20T02:03:11Z"' <<<"$RUNNING")")"
out="$(box box show myproject-k3x)"
assert_eq "show argv" "$(calls)" "ci box show myproject-k3x --json"
assert_eq "show renders key: value lines" "$out" "name: myproject-k3x
state: running
target: $TARGET
shape: medium
cpu: 8
memory_gib: 16
projects: myproject
tailnet_name: myproject-k3x
created_by: human:tester
ttl_hours: 4
expires_at: 2026-10-20T02:03:11Z
tmux_sessions: main (attached), build (idle 5m)"
reset
fx show "$(doc "$KEPT")"
out="$(box box show scratch-a1b)"
assert_contains "show prints unknown for a null tmux_sessions" "$out" "tmux_sessions: unknown"
reset
fx show "$(doc "$(jq -c '.tmux_sessions = []' <<<"$KEPT")")"
out="$(box box show scratch-a1b)"
assert_contains "show prints none for an empty tmux_sessions" "$out" "tmux_sessions: none"
reset
fx show "$(doc "$STOPPED")"
out="$(box box show ci-abc)"
assert_not_contains "show leaves tmux_sessions out for a stopped box" "$out" "tmux_sessions"
reset
DASH="$TMP/-dash"
mkdir -p "$DASH/.git"
fx create "$(doc "$KEPT")"
out="$(cd "$DASH" && PATH="$STUBS:$BASE_PATH" "$DEV" box create 2>&1)"
assert_eq "create skips a default project that starts with a dash" "$(calls)" "ci box create --by human:tester --json"
assert_contains "the skipped default is warned about" "$out" "not using -dash as the default project"
reset
NOHOST="$(jq -c '.tailnet_name = null | .state = "creating" | .expires_at = null' <<<"$RUNNING")"
fx show "$(doc "$NOHOST")"
out="$(box box show myproject-k3x)"
assert_contains "show prints - for a null tailnet_name" "$out" "tailnet_name: -"
reset
fx create "$(doc "$NOHOST")"
out="$(box box create)"
assert_eq "create prints the state while the box has no expiry yet" "$out" "Created myproject-k3x · $TARGET @ example-box · medium · creating · dev connect myproject-k3x"
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
assert_eq "resume output" "$out" "resumed myproject-k3x ($TARGET, medium, myproject), $RUN_LEFT, host myproject-k3x"

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
fx install-tools "$(jq -c '. + {installed: [{project: "myproject", manifest: true}, {project: "dotfiles", manifest: false}]}' <<<"$(doc "$RUNNING")")"
out="$(box box tools install myproject-k3x)"
assert_eq "tools install argv" "$(calls)" "ci box install-tools myproject-k3x --json"
assert_eq "tools install output" "$out" "myproject: tools installed
dotfiles: no .dev/tools.tsv, nothing installed"
reset
fx install-tools "$(doc "$RUNNING")"
box box tools install myproject-k3x myproject dotfiles >/dev/null 2>&1
assert_eq "tools install sends projects after --" "$(calls)" "ci box install-tools myproject-k3x --json -- myproject dotfiles"
out="$(box box tools install myproject-k3x --project x 2>&1)"
assert_eq "tools install refuses the removed --project" "$?" "2"
reset
fx install-tools '{"ok":false,"error":{"code":"bad_state","message":"Box ci-abc is stopped, and only a running box can have its tools installed","state":"stopped"}}' 6
out="$(box box tools install ci-abc 2>&1)"
assert_eq "tools install on a stopped box exits with ci's 6" "$?" "6"
assert_eq "tools install passes ci's message on" "$out" "dev box tools install: Box ci-abc is stopped, and only a running box can have its tools installed"
reset
out="$(box box tools install 2>&1)"
assert_eq "tools install needs a box name" "$?" "2"
assert_eq "tools install says to pass a name" "$out" "dev box tools install: no box given and no terminal to pick one; pass a name, like dev box tools install ci-abc"
assert_eq "ci is not called for tools install without a name" "$(calls)" ""

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
assert_eq "delete -y output" "$out" "Deleted ci-abc · archive /var/lib/devbox-archive/x.tar.gz"
reset
fx delete "$(doc "$(jq -c '.state = "deleted"' <<<"$STOPPED")")"
out="$(box box delete ci-abc -y --no-archive)"
assert_eq "delete --no-archive argv" "$(calls)" "ci box delete ci-abc --no-archive --json"
assert_eq "delete --no-archive output" "$out" "Deleted ci-abc · no archive"

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
        fx ls "$(lsdoc "$STOPPED")"
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
        assert_contains "the delete prompt states the consequence" "$out" "Its projects are archived first."
        assert_contains "the delete prompt asks the question" "$(printf '%s' "$out" | tr -d '\r')" "Delete ci-abc? [y/N]"
        if [ "$answer" = n ]; then
            assert_eq "answering n exits 1" "$rc" "1"
            assert_eq "answering n only lists the boxes" "$(calls)" "ci box ls --json"
        else
            assert_eq "answering y exits 0" "$rc" "0"
            assert_eq "answering y deletes" "$(calls)" "ci box ls --json
ci box delete ci-abc --json"
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

# --- connect ---

reset
fx ls "$(lsdoc "$RUNNING")"
box connect myproject-k3x
assert_eq "connect to a running box runs et" "$(calls)" "ci box ls --json
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c $PROJECTS_DIR/myproject user@myproject-k3x"
reset
fx ls "$(lsdoc "$RUNNING")"
box box connect myproject-k3x --ssh
assert_eq "--ssh runs ssh" "$(calls)" "ci box ls --json
ci ssh myproject-k3x -- tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$KEPT")"
box connect scratch-a1b --ssh
assert_contains "a box with no project uses its name as the session" "$(calls)" "tmux new -A -s scratch-a1b -c $PROJECTS_DIR"
reset
fx ls "$(lsdoc "$STOPPED")"
fx resume "$(doc "$(mkbox ci-abc running '["ci","dotfiles"]' "$NEW_OFF" null)")"
out="$(box connect ci-abc)"
assert_eq "connect to a stopped box resumes then runs et" "$(calls)" "ci box ls --json
ci box resume ci-abc --json
ci box show ci-abc --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s ci -c $PROJECTS_DIR/ci user@ci-abc"
assert_eq "connect prints the resume line" "$out" "resumed ci-abc ($TARGET, medium, ci,dotfiles), $NEW_LEFT, host ci-abc"
reset
fx ls "$(lsdoc "$RUNNING")"
mkdir -p "$TMP/noet"
ln -sf "$STUBS/ci" "$STUBS/ssh" "$TMP/noet/"
for tool in bash sh awk paste wc realpath dirname basename tr cut sed grep cat head sort id uname luajit env; do
    found="$(PATH="$BASE_PATH" command -v "$tool")" && ln -sf "$found" "$TMP/noet/$tool"
done
if PATH="$TMP/noet" command -v et >/dev/null 2>&1; then
    echo "FAIL - the no-et PATH still finds et"
    fails=$((fails + 1))
fi
out="$(cd "$NOPROJ" && PATH="$TMP/noet" "$DEV" connect myproject-k3x 2>&1)"
assert_contains "a missing et warns once" "$out" "et not found, using ssh"
assert_eq "a missing et falls back to ssh" "$(calls)" "ci box ls --json
ci ssh myproject-k3x -- tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$CREATING")"
out="$(box connect new-111 2>&1)"
assert_eq "connect to a box in another state exits 6" "$?" "6"
assert_contains "the bad state is named" "$out" "new-111 is creating"
assert_not_contains "no et for a bad state" "$(calls)" "et -c"
reset
fx ls "$(lsdoc "$RUNNING")"
out="$(box connect nope 2>&1)"
assert_eq "connect to an unknown box exits 3" "$?" "3"

reset
fx ls "$(lsdoc)"
out="$(box connect 2>&1)"
assert_eq "connect with no boxes outside a project exits 1" "$?" "1"
assert_eq "connect with no boxes says how to create one" "$out" "no boxes; create one with dev box create"

reset
fx ls "$(lsdoc "$KEPT" "$STOPPED" "$RUNNING")"
FAKE_TTY=1 FAKE_PICK=myproject-k3x inproj connect
assert_eq "the picker lists the project's boxes first, with a new-box item last" "$(cat "$ITEMS")" "picker title=Connect to a box auto=true
myproject-k3x	myproject-k3x	running	$TARGET	myproject	$RUN_LEFT
scratch-a1b	scratch-a1b	running	$TARGET	-	kept
ci-abc	ci-abc	stopped	$TARGET	ci,dotfiles	$STOP_LEFT
__new__	new box for myproject"
assert_eq "picking a box attaches to it" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c $PROJECTS_DIR/myproject user@myproject-k3x"
reset
fx ls "$(lsdoc "$KEPT")"
FAKE_TTY=1 FAKE_PICK=scratch-a1b box connect
assert_not_contains "outside a project the picker has no new-box item" "$(cat "$ITEMS")" "__new__"
reset
fx ls "$(lsdoc "$RUNNING")"
fx create "$(doc "$(mkbox myproject-n3w running '["myproject"]' "$NEW_OFF" null)")"
fx targets "$TARGETS_DOC"
fx shapes "$SHAPES_DOC"
out="$(FAKE_TTY=1 FAKE_PICK="__new__ $TARGET medium" inproj connect)"
assert_eq "the new-box item runs the create pickers, creates for the project then attaches" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ci box targets --json
ci box shapes --json
ci box shapes --target $TARGET --json
ci box create --target $TARGET --shape medium --by human:tester --json -- myproject
ci box show myproject-n3w --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c $PROJECTS_DIR/myproject user@myproject-n3w"
assert_contains "the new box is reported" "$out" "Created myproject-n3w"
reset
fx ls "$(lsdoc)"
fx create "$(doc "$RUNNING")"
fx targets "$TARGETS_DOC"
fx shapes "$SHAPES_DOC"
FAKE_TTY=1 FAKE_PICK="__new__ $TARGET medium" inproj connect >/dev/null
assert_contains "inside a project with no boxes the picker still asks" "$(cat "$ITEMS")" "picker title=Connect to a box auto=false"
reset
fx ls "$(lsdoc "$RUNNING")"
FAKE_TTY=1 FAKE_PICK=CANCEL box connect >/dev/null 2>&1
assert_eq "cancelling the picker exits 1" "$?" "1"
assert_eq "cancelling the picker calls ci only for the lists" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json"
CONNECTABLES='{"protocol":1,"things":[{"name":"myproject-k3x","machine":"example-box","kind":"box","address":"10.0.0.3","user":"dev","state":"running"},{"name":"s-1","machine":"example-box","kind":"session","address":"10.0.0.4","user":"dev","state":"running"},{"name":"host-a","machine":"host-a","kind":"host","address":"10.0.0.5","user":"chip","state":"running"},{"name":"scratch-vm","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"stopped"}],"notes":[]}'
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls "$CONNECTABLES"
FAKE_TTY=1 FAKE_PICK=host-a box connect
assert_eq "the picker lists the connectables after the boxes, with their kind" "$(cat "$ITEMS")" "picker title=Connect to a box auto=true
myproject-k3x	myproject-k3x	running	$TARGET	myproject	$RUN_LEFT
host-a	host-a	running	host	host-a	chip
scratch-vm	scratch-vm	stopped	host	example-box	dev"
assert_eq "picking a connectable syncs, lists and runs ssh ci-NAME" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ssh ci-host-a"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls "$CONNECTABLES"
box connect scratch-vm
assert_eq "a named connectable runs ssh ci-NAME" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ssh ci-scratch-vm"
reset
fx ls "$(lsdoc)"
fx ssh.ls "$CONNECTABLES"
FAKE_TTY=1 FAKE_PICK=host-a box connect
assert_eq "connectables alone fill the picker when there are no boxes" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ssh ci-host-a"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls "$CONNECTABLES"
out="$(box connect nope 2>&1)"
assert_eq "an unknown name among connectables exits 3" "$?" "3"
assert_not_contains "no ssh for an unknown name" "$(calls)" "ssh ci-"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls '{"protocol":1,"things":[{"name":"-oProxyCommand=x","machine":"m","kind":"host","user":"u","state":"running"},{"name":"ok-vm","machine":"m","kind":"host","user":"u","state":"running"}],"notes":["example-box is unreachable"]}'
out="$(FAKE_TTY=1 FAKE_PICK=ok-vm box connect 2>&1)"
assert_not_contains "a connectable with a bad name is not offered" "$(cat "$ITEMS")" "ProxyCommand"
assert_contains "a bad connectable name is reported" "$out" "skipping a connectable with an invalid name"
assert_contains "ci's notes are shown" "$out" "dev connect: example-box is unreachable"
assert_contains "the good connectable still connects" "$(calls)" "ssh ci-ok-vm"
reset
fx ls "$(lsdoc "$RUNNING")"
echo 2 >"$FX/connect.sync.rc"
out="$(FAKE_TTY=1 FAKE_PICK=myproject-k3x box connect 2>&1)"
assert_eq "an old ci without connect still connects a box" "$(calls)" "ci box ls --json
ci connect sync
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c $PROJECTS_DIR/myproject user@myproject-k3x"
assert_eq "an old ci gets one note" "$(printf '%s\n' "$out" | grep -c 'this ci has no ssh command, listing boxes only')" "1"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls "error: unrecognized subcommand 'ssh'" 2
out="$(FAKE_TTY=1 FAKE_PICK=myproject-k3x box connect 2>&1)"
assert_eq "a ci with connect but no ssh lists boxes only" "$(calls)" "ci box ls --json
ci connect sync
ci ssh ls --json
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c $PROJECTS_DIR/myproject user@myproject-k3x"
assert_eq "a ci with no ssh gets one note" "$(printf '%s\n' "$out" | grep -c 'this ci has no ssh command, listing boxes only')" "1"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls 'hub unreachable' 1
out="$(FAKE_TTY=1 FAKE_PICK=myproject-k3x box connect 2>&1)"
assert_eq "a failing ci connect still lets the picker attach a box" "$?" "0"
assert_contains "a failing ci connect prints ci's message" "$out" "dev connect: hub unreachable"
assert_contains "a failing ci connect still offers the boxes" "$(cat "$ITEMS")" "myproject-k3x"
assert_contains "the box attaches over et" "$(calls)" "et --ssh-option"
reset
fx ls "$(lsdoc "$RUNNING")"
fx ssh.ls 'hub unreachable' 1
out="$(box connect host-a 2>&1)"
assert_eq "a named non-box keeps ci's code when ci connect fails" "$?" "1"
assert_contains "a named non-box prints ci's message" "$out" "dev connect: hub unreachable"
reset
out="$(box connect __new__ 2>&1)"
assert_eq "connect refuses the new-box sentinel as a name" "$?" "2"
assert_contains "the sentinel is named" "$out" "bad box name __new__"
assert_eq "ci is not called for the sentinel" "$(calls)" ""
reset
fx ls "$(lsdoc "$(jq -c '.tailnet_name = null' <<<"$RUNNING")")"
out="$(box connect myproject-k3x 2>&1)"
assert_eq "connect to a box with no tailnet name exits 6" "$?" "6"
assert_eq "connect names the missing tailnet name" "$out" "dev box connect: myproject-k3x has no tailnet name yet (state running)"
assert_eq "no et or ssh for a box with no tailnet name" "$(calls)" "ci box ls --json"
reset
fx ls "$(lsdoc "$STOPPED")"
fx resume "$(doc "$(jq -c '.tailnet_name = null | .state = "running"' <<<"$STOPPED")")"
out="$(box connect ci-abc --ssh 2>&1)"
assert_eq "a resumed box with no tailnet name exits 6" "$?" "6"
assert_contains "the resumed box is named" "$out" "ci-abc has no tailnet name yet (state running)"
assert_not_contains "no ssh after a resume without a tailnet name" "$(calls)" "ssh"
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].path = "/srv/projects/dotfiles"' <<<"$RUNNING")")"
box connect myproject-k3x
assert_eq "connect starts tmux in the first project's path" "$(calls)" "ci box ls --json
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s myproject -c /srv/projects/dotfiles user@myproject-k3x"
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].path = "/srv/projects/dotfiles"' <<<"$RUNNING")")"
box connect myproject-k3x --ssh
assert_eq "ssh starts tmux in the first project's path" "$(calls)" "ci box ls --json
ci ssh myproject-k3x -- tmux new -A -s myproject -c /srv/projects/dotfiles"
LONG65="$(printf '%065d' 0 | tr 0 a)"
for bad in '/srv/projects/x; rm -rf ~' '/srv' '/home/user/projects' '/home/user/projects/myproject' '/srv/projects/a/b' "/srv/projects/\$(id)" '/srv/projects/.hidden' '/srv/projects/-x' '/srv/projects/..' "/srv/projects/$LONG65"; do
    reset
    fx ls "$(lsdoc "$(jq -c --arg p "$bad" '.projects[0].path = $p' <<<"$RUNNING")")"
    out="$(box connect myproject-k3x 2>&1)"
    assert_eq "connect refuses the project path $bad" "$?" "1"
    assert_contains "the refused path is named" "$out" "refusing the project path"
    assert_eq "nothing is run for the path $bad" "$(calls)" "ci box ls --json"
done
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].path = null' <<<"$RUNNING")")"
out="$(box connect myproject-k3x 2>&1)"
assert_eq "connect to a box with a null project path exits 6" "$?" "6"
assert_eq "connect names the missing project path" "$out" "dev box connect: myproject-k3x has no project path yet (state running)"
assert_eq "no et or ssh for a null project path" "$(calls)" "ci box ls --json"
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].path = "/srv/projects/MyProject"' <<<"$RUNNING")")"
box connect myproject-k3x
assert_contains "connect accepts a capitalised project path" "$(calls)" "-c /srv/projects/MyProject"
reset
fx ls "$(lsdoc "$(jq -c --arg p "/srv/projects/$(printf '%064d' 0 | tr 0 a)" '.projects[0].path = $p' <<<"$RUNNING")")"
box connect myproject-k3x
assert_contains "connect accepts a 64-character project path" "$(calls)" "-c /srv/projects/aaaaaaaa"
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].name = "my.proj" | .projects[0].path = "/srv/projects/my.proj"' <<<"$RUNNING")")"
box connect myproject-k3x
assert_eq "a dot in the project name becomes an underscore in the tmux session" "$(calls)" "ci box ls --json
ci box show myproject-k3x --json
et --ssh-option UserKnownHostsFile=$KH --ssh-option StrictHostKeyChecking=yes -c tmux new -A -s my_proj -c /srv/projects/my.proj user@myproject-k3x"
reset
fx ls "$(lsdoc "$RUNNING")"
(cd "$NOPROJ" && PATH="$STUBS:$BASE_PATH" XDG_STATE_HOME=relative/state HOME="$TMP/home" "$DEV" connect myproject-k3x)
assert_contains "a relative XDG_STATE_HOME falls back to ~/.local/state" "$(calls)" "UserKnownHostsFile=$TMP/home/.local/state/ci/known_hosts "
reset
fx ls "$(lsdoc "$RUNNING")"
fx show "$(doc "$(jq -c '.ssh_user = null' <<<"$RUNNING")")"
out="$(box connect myproject-k3x 2>&1)"
assert_eq "a shown box with no ssh user exits 6" "$?" "6"
assert_contains "the missing ssh user is named" "$out" "has no tailnet name or ssh user"
assert_not_contains "no et without an ssh user" "$(calls)" "et --ssh-option"

# --- dispatch ---

out="$(box --remote box ls 2>&1)"
assert_eq "--remote refuses box ls" "$?" "2"
assert_contains "--remote names the refused subcommand" "$out" "dev box ls: runs on this machine only, so --remote does not apply"
out="$(box --remote connect 2>&1)"
assert_eq "--remote refuses connect" "$?" "2"
assert_contains "--remote names connect" "$out" "dev connect: runs on this machine only, so --remote does not apply"
out="$(box help)"
assert_contains "dev help lists box" "$out" "box "
assert_contains "dev help lists connect" "$out" "connect "
out="$(box help box)"
for sub in ls create show stop resume extend tools delete connect; do
    assert_contains "dev help box lists $sub" "$out" "  $sub "
done
out="$(box help box create)"
assert_contains "create help states the default lifetime" "$out" "4 hours"
assert_contains "create help names the target and shape" "$out" "--target T] [--shape S]"
assert_contains "create help lists --keep" "$out" "--keep"
assert_eq "__subs box lists the subcommands" "$(box __subs box | cut -f1 | paste -sd' ' -)" "ls targets create show stop resume extend retag tools delete connect"
assert_eq "__flags box create" "$(box __flags box create | paste -sd' ' -)" "--target --shape --arch --by --ttl --keep -v --verbose -vv --remote --local --detach -C"
assert_eq "__flags box delete" "$(box __flags box delete | sed -n 1,2p | paste -sd' ' -)" "--yes -y"
assert_eq "__flags connect" "$(box __flags connect | sed -n 1p)" "--ssh"
assert_eq "__flags box ls" "$(box __flags box ls | sed -n 1p)" "--all"
TOPICPROJ="$TMP/topicproj"
mkdir -p "$TOPICPROJ/.dev/topics" "$TOPICPROJ/.git"
FENCE="$(printf '\140\140\140')"
printf '%s\n' '# frob: scratch' '' "$FENCE" 'dev box ls --all' 'dev box frob' 'dev box ls --nope' "$FENCE" >"$TOPICPROJ/.dev/topics/frob.md"
out="$(cd "$TOPICPROJ" && "$DEV" __topics check 2>&1)"
assert_eq "__topics check fails on a bad box line" "$?" "1"
assert_contains "__topics check names the bad box subcommand" "$out" "dev box has no subcommand frob"
assert_contains "__topics check names the bad box flag" "$out" "dev box ls takes no flag --nope"
assert_not_contains "__topics check accepts a good box line" "$out" "--all"
out="$(box box frobnicate 2>&1)"
assert_eq "an unknown box subcommand exits 2" "$?" "2"
assert_contains "an unknown box subcommand is named" "$out" "dev box: unknown subcommand frobnicate"

out="$(box box install-tools myproject-k3x 2>&1)"
assert_eq "box install-tools is no longer a subcommand" "$?" "2"
assert_contains "box install-tools is unknown" "$out" "dev box: unknown subcommand install-tools"
out="$(box help box tools)"
assert_contains "dev help box tools lists install" "$out" "  install "
assert_eq "__subs box tools lists install" "$(box __subs box tools | cut -f1)" "install"
assert_eq "__flags box tools install has no flag of its own" "$(box __flags box tools install | sed -n 1p)" "-v"

if [ "$fails" -gt 0 ]; then
    printf '\n%d failure(s)\n' "$fails"
    exit 1
fi
printf '\nall box tests passed\n'
