#!/usr/bin/env bash
# Pure-bash tests for `dev box` and `dev connect`. ci, mosh and ssh are stubs first on PATH that
# log their arguments, one per line, and ci answers from fixture files in $FX. A fake dotfiles
# clone in DOTFILES holds a stub scripts/select-items.sh that records the items and picks FAKE_PICK.
set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
DEV="$REPO/dotfiles/bin/.local/bin/dev"
unset DOTFILES VERBOSE DEV_CI

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
STUBS="$TMP/stubs"
FX="$TMP/fx"
FAKE_DOTFILES="$TMP/dotfiles"
export LOG="$TMP/log" ITEMS="$TMP/items" FX
mkdir -p "$STUBS" "$FX" "$FAKE_DOTFILES/scripts"

cat >"$STUBS/ci" <<'STUB'
#!/bin/sh
{ echo ci; printf '%s\n' "$@"; echo '#'; } >>"$LOG"
sub=$2
[ ! -f "$FX/$sub.err" ] || cat "$FX/$sub.err" >&2
[ ! -f "$FX/$sub.json" ] || cat "$FX/$sub.json"
exit "$(cat "$FX/$sub.rc" 2>/dev/null || echo 0)"
STUB
for tool in mosh ssh; do
    cat >"$STUBS/$tool" <<STUB
#!/bin/sh
{ echo $tool; printf '%s\n' "\$@"; echo '#'; } >>"\$LOG"
STUB
done
cat >"$FAKE_DOTFILES/scripts/select-items.sh" <<'STUB'
#!/bin/sh
{ echo "picker $*"; cat; } >"$ITEMS"
[ "$FAKE_PICK" != CANCEL ] || exit 1
echo "$FAKE_PICK"
STUB
chmod +x "$STUBS"/* "$FAKE_DOTFILES/scripts/select-items.sh"

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
    rm -f "${FX:?}"/* "$LOG" "$ITEMS"
    : >"$LOG"
}

# box <args...>: run dev from a directory outside any project, with the stubs on PATH.
NOPROJ="$TMP/noproj"
mkdir -p "$NOPROJ"
box() {
    (cd "$NOPROJ" && PATH="$STUBS:$BASE_PATH" DOTFILES="$FAKE_DOTFILES" "$DEV" "$@")
}

PROJ="$TMP/myproject"
mkdir -p "$PROJ/.git"
inproj() {
    (cd "$PROJ" && PATH="$STUBS:$BASE_PATH" DOTFILES="$FAKE_DOTFILES" "$DEV" "$@")
}

# mkbox <name> <state> <projects json> <expires offset s|null> <delete offset s|null>
mkbox() {
    jq -nc --arg name "$1" --arg state "$2" --argjson names "$3" --argjson exp "$4" --argjson del "$5" '{
        name: $name, state: $state, profile: "medium", cpu: 8, memory_gib: 16, projects: ($names | map({name: ., path: "/srv/projects/\(.)"})),
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
fx install-tools "$(jq -c '. + {installed: [{project: "myproject", manifest: true}, {project: "dotfiles", manifest: false}]}' <<<"$(doc "$RUNNING")")"
out="$(box box install-tools myproject-k3x)"
assert_eq "install-tools argv" "$(calls)" "ci box install-tools myproject-k3x --json"
assert_eq "install-tools output" "$out" "myproject: tools installed
dotfiles: no .dev/tools.tsv, nothing installed"
reset
fx install-tools "$(doc "$RUNNING")"
box box install-tools myproject-k3x --project myproject --project dotfiles >/dev/null 2>&1
assert_eq "install-tools --project argv" "$(calls)" "ci box install-tools myproject-k3x --project myproject --project dotfiles --json"
reset
fx install-tools '{"ok":false,"error":{"code":"bad_state","message":"Box ci-abc is stopped, and only a running box can have its tools installed","state":"stopped"}}' 6
out="$(box box install-tools ci-abc 2>&1)"
assert_eq "install-tools on a stopped box exits with ci's 6" "$?" "6"
assert_eq "install-tools passes ci's message on" "$out" "dev box install-tools: Box ci-abc is stopped, and only a running box can have its tools installed"
reset
out="$(box box install-tools 2>&1)"
assert_eq "install-tools needs a box name" "$?" "2"
assert_eq "ci is not called for install-tools without a name" "$(calls)" ""

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

# --- connect ---

reset
fx ls "$(lsdoc "$RUNNING")"
box connect myproject-k3x
assert_eq "connect to a running box runs mosh" "$(calls)" "ci box ls --json
mosh box-myproject-k3x -- tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$RUNNING")"
box box connect myproject-k3x --ssh
assert_eq "--ssh runs ssh" "$(calls)" "ci box ls --json
ssh -t box-myproject-k3x tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$KEPT")"
box connect scratch-a1b --ssh
assert_contains "a box with no project uses its name as the session" "$(calls)" "tmux new -A -s scratch-a1b -c $PROJECTS_DIR"
reset
fx ls "$(lsdoc "$STOPPED")"
fx resume "$(doc "$(mkbox ci-abc running '["ci","dotfiles"]' "$NEW_OFF" null)")"
out="$(box connect ci-abc)"
assert_eq "connect to a stopped box resumes then runs mosh" "$(calls)" "ci box ls --json
ci box resume ci-abc --json
mosh box-ci-abc -- tmux new -A -s ci -c $PROJECTS_DIR/ci"
assert_eq "connect prints the resume line" "$out" "resumed ci-abc (medium, ci,dotfiles), $NEW_LEFT, host box-ci-abc"
reset
fx ls "$(lsdoc "$RUNNING")"
mkdir -p "$TMP/nomosh"
ln -sf "$STUBS/ci" "$STUBS/ssh" "$TMP/nomosh/"
for tool in bash jq awk paste wc realpath dirname basename tr cut sed grep cat head sort id uname; do
    found="$(PATH="$BASE_PATH" command -v "$tool")" && ln -sf "$found" "$TMP/nomosh/$tool"
done
if PATH="$TMP/nomosh" command -v mosh >/dev/null 2>&1; then
    echo "FAIL - the no-mosh PATH still finds mosh"
    fails=$((fails + 1))
fi
out="$(cd "$NOPROJ" && PATH="$TMP/nomosh" "$DEV" connect myproject-k3x 2>&1)"
assert_contains "a missing mosh warns once" "$out" "mosh not found, using ssh"
assert_eq "a missing mosh falls back to ssh" "$(calls)" "ci box ls --json
ssh -t box-myproject-k3x tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$CREATING")"
out="$(box connect new-111 2>&1)"
assert_eq "connect to a box in another state exits 6" "$?" "6"
assert_contains "the bad state is named" "$out" "new-111 is creating"
assert_not_contains "no mosh for a bad state" "$(calls)" "mosh"
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
FAKE_PICK=myproject-k3x inproj connect
assert_eq "the picker lists the project's boxes first, with a new-box item last" "$(cat "$ITEMS")" "picker --title Connect to a box
myproject-k3x	myproject-k3x  running  medium  myproject    $RUN_LEFT
scratch-a1b	scratch-a1b    running  medium  -            kept
ci-abc	ci-abc         stopped  medium  ci,dotfiles  $STOP_LEFT
__new__	new box for myproject"
assert_eq "picking a box attaches to it" "$(calls)" "ci box ls --json
mosh box-myproject-k3x -- tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
reset
fx ls "$(lsdoc "$KEPT")"
FAKE_PICK=scratch-a1b box connect
assert_not_contains "outside a project the picker has no new-box item" "$(cat "$ITEMS")" "__new__"
reset
fx ls "$(lsdoc "$RUNNING")"
fx create "$(doc "$(mkbox myproject-n3w running '["myproject"]' "$NEW_OFF" null)")"
out="$(FAKE_PICK=__new__ inproj connect)"
assert_eq "the new-box item creates for the project then attaches" "$(calls)" "ci box ls --json
ci box create --project myproject --json
mosh box-myproject-n3w -- tmux new -A -s myproject -c $PROJECTS_DIR/myproject"
assert_contains "the new box is reported" "$out" "created myproject-n3w"
reset
fx ls "$(lsdoc)"
fx create "$(doc "$RUNNING")"
FAKE_PICK=__new__ inproj connect >/dev/null
assert_contains "inside a project with no boxes the picker still asks" "$(cat "$ITEMS")" "picker --title Connect to a box --no-auto"
reset
fx ls "$(lsdoc "$RUNNING")"
FAKE_PICK=CANCEL box connect >/dev/null 2>&1
assert_eq "cancelling the picker exits 1" "$?" "1"
assert_eq "cancelling the picker calls ci only for ls" "$(calls)" "ci box ls --json"
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
assert_eq "no mosh or ssh for a box with no tailnet name" "$(calls)" "ci box ls --json"
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
mosh box-myproject-k3x -- tmux new -A -s myproject -c /srv/projects/dotfiles"
reset
fx ls "$(lsdoc "$(jq -c '.projects[0].path = "/srv/projects/dotfiles"' <<<"$RUNNING")")"
box connect myproject-k3x --ssh
assert_eq "ssh starts tmux in the first project's path" "$(calls)" "ci box ls --json
ssh -t box-myproject-k3x tmux new -A -s myproject -c /srv/projects/dotfiles"
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
assert_eq "no mosh or ssh for a null project path" "$(calls)" "ci box ls --json"
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
mosh box-myproject-k3x -- tmux new -A -s my_proj -c /srv/projects/my.proj"

# --- dispatch ---

out="$(box --ci box ls 2>&1)"
assert_eq "--ci refuses box ls" "$?" "2"
assert_contains "--ci names the refused subcommand" "$out" "dev box ls: --ci cannot run this verb"
out="$(box --ci connect 2>&1)"
assert_eq "--ci refuses connect" "$?" "2"
assert_contains "--ci names connect" "$out" "dev connect: --ci cannot run this verb"
out="$(box help)"
assert_contains "dev help lists box" "$out" "box "
assert_contains "dev help lists connect" "$out" "connect "
out="$(box help box)"
for sub in ls create show stop resume extend install-tools delete connect; do
    assert_contains "dev help box lists $sub" "$out" "  $sub "
done
out="$(box help box create)"
assert_contains "create help states the default lifetime" "$out" "4 hours"
assert_contains "create help states the default profile" "$out" "profile medium"
assert_contains "create help lists --keep" "$out" "--keep"
assert_eq "__subs box lists the subcommands" "$(box __subs box | cut -f1 | paste -sd' ' -)" "ls create show stop resume extend install-tools delete connect"
assert_eq "__flags box create" "$(box __flags box create | paste -sd' ' -)" "--profile --project --ttl --keep -v --verbose -vv --ci"
assert_eq "__flags box delete" "$(box __flags box delete | sed -n 1,2p | paste -sd' ' -)" "--yes -y"
assert_eq "__flags connect" "$(box __flags connect | sed -n 1p)" "--ssh"
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
