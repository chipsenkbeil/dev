# boxes: Create, connect to, stop and delete dev boxes through ci box

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
