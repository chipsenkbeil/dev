# boxes: Create, connect to, stop and delete dev boxes through ci box, and each subcommand in detail

`dev box` is a client for `ci box ... --json`. It needs only `ci` on PATH
and never talks to Incus, ssh-keys or Tailscale itself.

```
dev box ls
dev box ls --json
dev box targets
dev box create --shape large --ttl 8 myproject
dev box stop myproject-k3x
dev box resume myproject-k3x --keep
dev box extend myproject-k3x --ttl 2
dev box tools install myproject-k3x myproject
dev box delete myproject-k3x -y
dev box delete myproject-k3x -y --no-archive
```

## Listing and creating

`dev box ls` opens with the room: a hub `Boxes` line (`2 of 3 running · 1 more
can start`, from the cap), then for each machine ci reports its name, a
`Boxes` line with the running count and a `Memory` line (`24 of 32 GiB used ·
8 GiB free`, the memory promised to running boxes against that plus the room
left for a new box). A machine ci could not reach shows `unreachable` instead.
On a terminal the lines carry green bars, and piped output has the words only.

Below that is one row per box: name, target (`<target> @ <machine>`), state,
activity, who, shape, projects and time left. Activity is `attached` when a
tmux session is attached, else `idle` and the shortest idle time, `-` for no
sessions or a box that is not running, and `?` when ci could not read them.
Who is `you` for a box you made, `agent` for one an agent made, the name for
another human's, and ci's own label (such as `adopted`) otherwise. Time left is
`3h12m left` or `kept` for a running box and `deleted in 6d` for a stopped one.
`--json` on `ls` and `show` prints ci's document unchanged.

`dev box targets` shows what a box can run, grouped by machine. Each machine
heads its block with its room (`8 GiB free · 2 more boxes`, or `unreachable`),
then one row per target: OS, image, the smallest shape it takes (the smallest
shape overall when ci names none) and NOW, which is `✓ fits` or ci's reason in
dim. `--json` prints ci's document unchanged.

`dev box create` blocks until the box runs. Projects are positional:
`dev box create [--target T] [--shape S] [--by LABEL] [--ttl HOURS | --keep] [PROJECT...]`.
On a terminal it asks two questions, target first (a target's minimum
rules shapes out). The target picker lists each target with its OS, image and
smallest shape. A target that cannot take a box now but could once room
frees (its smallest shape fits after a wait) can be picked and says
`waits for room` with ci's reason. One whose smallest shape can never fit, or
whose machine ci could not ask, is greyed with ci's reason. The shape picker
lists the shapes for that target with CPU and memory. A shape is greyed when
it is below the target's minimum or can never fit, a shape that fits only
after a wait can be picked and says `waits for room`, a warning (such as the
last running slot) shows beside a row that can be picked, and the cursor
starts on ci's default shape. When no target, or no shape, can be picked, dev
names the running boxes to stop and exits 1. `--target T` skips the first picker and
takes ci's default shape, `--shape S` skips only the second, and with no
terminal there are no pickers and ci applies its defaults. A shape below the
target's minimum is refused by ci alone. The lifetime is 4 hours unless you
pass `--ttl HOURS` or `--keep`. `--ttl` with `--keep` exits 2. Inside a project
with no project named, dev passes the project root's directory name. `--by`
defaults to `human:$USER`, else `human:$LOGNAME`, and dev always passes it.
The last line is `Created <name> · <target> @ <machine> · <shape> · <time left> · dev connect <name>`.

An agent creates a box with `--ttl HOURS`, and with `--keep` only when the
owner asks for a kept box, and deletes the box when its work ends. On a box an
agent writes scratch files only under `~/scratch/<session>/` and removes that
folder when the work ends. Projects live under `/srv/projects`.

Leave the box out of `show`, `stop`, `resume`, `extend`, `tools install` or
`delete` and a terminal gets the same box picker `dev connect` uses, with only
the boxes the verb can act on: running ones for `stop`, `extend` and
`tools install`, stopped ones for `resume`. Without a terminal a missing name
exits 2 and says to pass a name, with an example command such as
`dev box delete ci-abc -y`.

`dev box show` prints `tmux_sessions` as items such as `main (attached)` or
`build (idle 5m)`, `none` when there is no tmux server and `unknown` when ci
could not read them. A box that is not running has no such line. dev sends
the projects after `--`, and skips a default project whose name starts with
`-`, with a warning.

A box name is 1 to 40 of `a-z`, `0-9` and `-`, else exit 2. A null
`tailnet_name` prints as `-`.

`dev box tools install` reinstalls a running box's tools, for every project or
the projects named after the box (`dev box tools install BOX [PROJECT...]`), and prints one line per project. A box that is
not running exits 6.

## Plain ssh

ci writes a Host block for every box into `~/.local/state/ci/ssh_config`
(`$XDG_STATE_HOME/ci/ssh_config`), with the host key file and strict checking.
`~/.ssh/config` is not in this repo, so add this as its first line, before any
`Host *`, for plain `ssh <box>` to work:

```
Include ~/.local/state/ci/ssh_config
```

`dev install ssh` and `bootstrap.sh` remind you. The connection options
(ControlMaster and the keepalives) live in `[box] ssh_options` of
`dotfiles/ci/.config/ci/config.toml`.

## Connecting

```
dev connect
dev connect myproject-k3x --ssh
```

`dev connect` and `dev box connect` are the same command. With no name it
lists the boxes, the current project's first, and you pick one. Inside a
project the last item, `new box for <project>`, asks for the target and the shape, as `dev box create` does, then creates a
box and attaches. A
stopped box is resumed first. Any other state than running exits 6, as does a
box with no `tailnet_name` or no project path yet.

dev then runs `ci box show <box>`, which writes the box's host keys to ci's
known_hosts, and replaces itself with
`et -c "tmux new -A -s <session> -c <dir>" <ssh_user>@<tailnet_name>`, told
to trust only that file, so a box's host key is never accepted on first use.
The session is the first project's name or the box name, with `.` and `:`
turned into `_`. The directory is the first project's `path`, or
`/srv/projects` with no project, so a session never starts in `$HOME`. A path
outside `/srv/projects[/<name>]` exits 1. `--ssh`, or an `et` missing from
PATH (with one warning), runs `ci box ssh <box> -- tmux ...` with the same
tmux command, which checks the same host keys.

## Connecting to machines that are not boxes

Infra can mark a machine or an instance as connectable: an Incus instance,
a tart VM, the Mac host or example-box. `dev connect` reaches them too, and it
never talks to Incus or accepts a host key on first use. After listing boxes
it runs `ci connect sync`, which writes a `Host ci-<name>` block for each
connectable into ci's ssh_config include, then reads `ci connect ls --json`.
The picker shows the connectables after the boxes, one row each with the
name, state, kind, machine and login user.

```
dev connect host-a
```

`dev connect NAME` takes a box or a connectable. A box name goes the way
above, without asking `ci connect`. Any other name that ci lists as a
connectable runs `ssh ci-NAME`, which relays through the hub and checks the
host key ci pinned. A ci that has no `connect` command makes dev list boxes
only, with one note. Any other ci failure prints ci's message as one line and
the picker still offers the boxes, while a name that is no box exits with ci's
code.

## Errors

When ci exits non-zero with an `{"ok":false}` document, dev prints
`dev box <sub>: <message>` to stderr and exits with ci's code (2 to 11).
Other output passes through. `dev box delete` asks on `/dev/tty` unless you
pass `-y`, and exits 2 with no terminal. The prompt wraps its consequence to the
terminal width on lines above the `[y/N]` question. It says `You're attached to it.` when
a tmux session of the box is attached, and ends with
`Deleted <name> · archive <path>` or `Deleted <name> · no archive`. `dev --remote` refuses `box` and `connect`.

`dev box delete --no-archive` deletes the box without archiving its projects,
so anything not pushed is lost, and its question says so.

## Reference: the subcommands in detail

A built-in noun for any project, and a thin client over `ci box ... --json`: it never talks to Incus, ssh-keys or Tailscale, and it needs only `ci` on PATH (else `dev box` dies saying so) and reads its JSON with `dev.json`. Every box is named by ci, and `dev box` takes the host only from the box's `tailnet_name`.

| Subcommand | Does |
|---|---|
| `ls [--all] [--json]` | The room, then one row per box. The room is a hub line `Boxes  <bar> 2 of 3 running · 1 more can start` from `cap.running` and `cap.running_max`, then each entry of `machines`: its name, a `Boxes` line with its `running` count (ci gives no per-machine cap yet, `max_boxes` is null) and a `Memory` line `24 of 32 GiB used · 8 GiB free`, where used is `memory_limits_gib`, free is `new_box_room_gib` and the bar's total is the two added. A machine with `reachable: false` shows `unreachable` in dim instead. Bars come from `dev.ui.bar`, so they appear on a terminal only and piped output has the words alone with no color codes. The table has NAME (a `●` or `○` mark and the name, bold), TARGET (`<target> @ <machine>`), STATE, ACTIVITY, WHO, SHAPE, PROJECTS and TIME LEFT. ACTIVITY is `attached` when any `tmux_sessions` entry is attached, else `idle <shortest idle_seconds>`, `-` for `[]` and for a box that is not running, `?` for null. WHO is `you` for `human:<USER, else LOGNAME>`, `agent` for any `agent:` value, the name for another `human:`, else `created_by` as it is. `no boxes` follows the room when there are none. Time left is `3h12m left` or `kept` for a running box, `deleted in 6d` for a stopped one, and `-` for other states. `--json` prints ci's document byte for byte and draws nothing. |
| `targets [--json]` | Reads `ci box targets --json` (the structured list, never the text) and `ci box shapes --json` for the room, and prints one block per machine: the machine name, its room (`8 GiB free · 2 more boxes`, from `machines[].new_box_room_gib` and the hub cap, `unreachable` for a machine ci could not ask), then a table with TARGET, OS (`Linux`, `Windows`, `macOS`), IMAGE, MIN SHAPE (`min_shape`, else the shape with the least memory) and NOW (`✓ fits` when `can_take_box_now`, else `reason` dim). `--json` prints ci's targets document unchanged. |
| `create [--target T] [--shape S] [--by LABEL] [--ttl HOURS or --keep] [PROJECT...]` | On a terminal (standard input and output are both terminals) with no `--target`, asks which target to run (`What should the <project> box run?`, rows `<target>  <OS> · <image>  from <min shape>  @ <machines>`, the machines' room in the note, a target whose smallest shape fits only after a wait can be picked and shows `waits for room · <reason>` as its note, and a target whose smallest shape can never fit, or whose machine ci could not ask, is greyed with ci's `reason`), then, with no `--shape`, which shape from `ci box shapes --target T --json` (`Pick a shape for T on <machine>`, rows `<name>  <cpu> CPU  <memory_gib> GiB  <notes>`; greyed with the reason for `below_min` (`below T's minimum`) or `fits: never`, and a machine ci could not ask counts as never. A `fits: wait` row can be picked and says `waits for room`. A `warning` shows beside a pickable row, and the cursor starts on `default: true`). When no target, or no shape, can be picked, it names the running boxes on the machines to stop and exits 1; cancelling a picker exits 1 and creates nothing. `--target` skips both pickers and takes ci's default shape, `--shape` alone skips only the second, and with no terminal there are no pickers and ci applies its defaults (a shape below the minimum is refused by ci alone). It then prints `Created <name> · <target> @ <machine> · <shape> · <time left> · dev connect <name>` (`kept` for a box with no expiry, the state while it has none yet). Projects are positional. Inside a project with none given, it passes the project root's basename. It always passes `--by`, `human:$USER` (else `human:$LOGNAME`) unless given. `--ttl` with `--keep` is a usage error before ci runs. `dev connect` creating a new box runs no picker. |
| `show [BOX] [--json]` | With `--json` ci's document unchanged, else the box as `key: value` lines, with `tmux_sessions` as `name (attached)` or `name (idle 5m)` items, `none` for `[]` and `unknown` for null, on a running box only. Projects reach ci after `--`, and a default project whose name starts with `-` is skipped with a warning. |
| `stop [BOX]` | `stopped <name>, deleted in Nd unless resumed`, with N the days to the box's `delete_after`, rounded up. |
| `resume [BOX] [--ttl HOURS or --keep]` | Prints `resumed <name> (<target>, <shape>, <projects>), <time left>, host <tailnet_name>`, the line `create` used to print. |
| `extend [BOX] (--ttl HOURS or --keep)` | One of the two is required. |
| `tools install [BOX] [PROJECT...]` | Reinstalls a running box's tools through `ci box install-tools BOX --json`, with the projects after `--`, and prints `<project>: tools installed` or `<project>: no .dev/tools.tsv, nothing installed` per project, `no projects` when ci installed none. A box that is not running exits with ci's 6, and a ci error prints as dev box tools install: <message>. |
| `delete [BOX] [-y] [--no-archive]` | Asks on `/dev/tty`, with the consequence wrapped to the terminal width on lines above the question: `Its projects are archived first.` then `Delete <box>? [y/N]`, or with `--no-archive` `Anything not pushed is lost.` then `Delete <box> without an archive? [y/N]`, and passes `--no-archive` to ci; when a tmux session of the box is attached (read from `ci box ls --json`), the consequence starts with `You're attached to it.`. With no terminal and no `-y` it is a usage error. Prints `Deleted <name> · archive <path>`, or `Deleted <name> · no archive` when ci wrote none, and dev prints no archive-days number of its own. |
| `connect [BOX] [--ssh]` | Same as `dev connect`, below. |

When the box is left out, `show`, `stop`, `resume`, `extend`, `tools install` and `delete` pick one with the shared picker (`dev.ui.picker`, rows as in `ls`, titled `Show which box?`, `Stop which box?` and so on) when standard input and output are both terminals, listing only the boxes the verb can act on: running ones for `stop`, `extend` and `tools install`, stopped ones for `resume`, every box for `show` and `delete`. `stop` and `delete` always show the screen, the others skip it when one row is left. With no such box it prints `dev <verb>: no running boxes to stop` (or the matching words) and exits 1. Without a terminal a missing name is a usage error, the line ending `no box given and no terminal to pick one; pass a name, like dev box delete ci-abc -y` (the verb's own words, and `-y` only for `delete`), exit 2.

When ci exits non-zero with an `{"ok":false,...}` document, `dev box <sub>` prints `error.message` to stderr and exits with ci's code (2 to 11, 10 and 11 included). Output that is not JSON, such as clap usage text, passes through with ci's exit code. Progress lines ci writes to stderr reach the terminal. A box that has no `tailnet_name` yet (null from ci) shows `-` as its host. ci gives `projects` as a list of `{name, path}` objects and dev shows the names. ci writes a Host block per box into `~/.local/state/ci/ssh_config`, which `~/.ssh/config` includes as its first line, and takes the ssh options from `[box] ssh_options` in `dotfiles/ci/.config/ci/config.toml`. A box name must match `^[a-z0-9-]{1,40}$`, else exit 2.  Times are computed in Lua from the RFC 3339 stamps, so macOS and Linux agree. `dev --remote` refuses every `box` subcommand.

`dev connect [BOX] [--ssh]` is the same handler as `dev box connect`. With no box it lists them as `ls` does, the current project's boxes first, picks one with the shared picker (`dev.ui.picker`, titled `Connect to a box`, which skips the screen when exactly one row would be left outside a project) and, inside a project, offers a last item `new box for <project>` that asks for the target and the shape with the pickers of `create` and then creates and attaches. With no name and no terminal, once boxes exist, it is a usage error like the other box verbs (exit 2). With no boxes outside a project it prints `no boxes; create one with dev box create` and exits 1. A stopped box is resumed first, and any state other than running or stopped exits 6, as does a box whose `tailnet_name` is still null. It then runs `ci box show <box> --json`, which writes the box's host keys to ci's known_hosts (`$XDG_STATE_HOME/ci/known_hosts` when `XDG_STATE_HOME` is absolute, else `~/.local/state/ci/known_hosts`), and execs `et --ssh-option UserKnownHostsFile=<that file> --ssh-option StrictHostKeyChecking=yes -c "tmux new -A -s <session> -c <dir>" <ssh_user>@<tailnet_name>`, so no host key is trusted on first use and a shown box with no `tailnet_name` or `ssh_user` exits 6. The session is the first project's name or the box name with every character outside `A-Za-z0-9_-` (so `.` and `:`, which tmux reserves) turned into `_`, and the directory is the first project's `path` or `BOX_PROJECTS_DIR` (`/srv/projects`) for a box with no project, so a session never starts in `$HOME`. `dir` must match `^/srv/projects(/[A-Za-z0-9][A-Za-z0-9._-]{0,63})?$`, the names ci can produce, else exit 1, and a running box whose first project has a null `path` exits 6. `--ssh`, or a missing `et` with one warning, execs `ci box ssh <box> -- tmux new -A -s <session> -c <dir>` instead, which checks the same host keys and allocates a terminal.

`dev connect` also reaches what infra marks as connectable (Incus instances, tart VMs, the Mac host, example-box), through `ci connect`. After `ci box ls --json` it runs `ci connect sync`, which writes a `Host ci-<name>` block per connectable into ci's ssh_config include, then `ci connect ls --json`, read as `{protocol, connectables:[{name, machine, kind, address, user, state}], notes}` (ci never lists a dev box there). The picker shows the connectables after the boxes and before the new-box item, a row being name, state, kind, machine and user, and `dev connect NAME` takes either. A name that ci lists as a box takes the box path above and never calls `ci connect`; a name that is no box asks `ci connect` and, when it finds the name, execs `ssh ci-<name>` (`ssh <name>` when the name already starts with `ci-`, which ci uses as its own alias) through `dev.os` exec with no shell, so ci's ProxyCommand and pinned known_hosts decide the host key and `--ssh` changes nothing. Each string in `notes` goes to standard error as "dev connect: <note>", and a connectable whose name is not 1 to 40 of a-z, 0-9 and `-` is skipped with one line. A ci with no `connect` exits 2 from `sync` or `ls`, and dev then lists boxes only with one note, "dev connect: this ci has no connect command, listing boxes only". Any other non-zero exit prints ci's `error.message` (or the first line of its output) as one line, "dev connect: <message>". The picker then still offers the boxes, and a name that is no box exits with ci's code. `tests/lua/connect_test.lua` and `tests/dev/box_test.sh` run all of it against a fake `ci` and `ssh`.

