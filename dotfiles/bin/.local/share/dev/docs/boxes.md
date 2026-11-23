# boxes: Dev boxes through ci box, and dev connect

`dev box` is a client for `ci box ... --json`. It needs only `ci` on PATH and
never talks to Incus, ssh-keys or Tailscale itself.

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

## Listing and targets

### dev box ls

`dev box ls` opens with the room. A hub `Boxes` line comes first, such as
`2 of 3 running · 1 more can start` (from the cap). Then each machine ci
reports gets its name, a `Boxes` line with the running count and a `Memory`
line.

The `Memory` line reads `24 of 32 GiB used · 8 GiB free`. It is the memory
promised to running boxes against that plus the room left for a new box.

A machine ci could not reach shows `unreachable` instead. On a terminal the
lines carry green bars, and piped output has the words only.

Below the room is one row per box, or `no boxes` when there are none. The
columns are name, target (`<target> @ <machine>`), state, activity, who,
shape, projects and time left. `--json` on `ls` and `show` prints ci's
document unchanged.

- activity: `attached` when a tmux session is attached, else `idle` and the
  shortest idle time. It is `-` for no sessions or a box that is not running,
  and `?` when ci could not read them.
- who: `you` for a box you made, `agent` for one an agent made, the name for
  another human's, and ci's own label (such as `adopted`) otherwise.
- time left: `3h12m left` or `kept` for a running box, and `deleted in 6d` for
  a stopped one. A running box past its expiry shows `expired`, a stopped one
  past its deletion time shows `deleted soon`, and other states show `-`.

### dev box targets

`dev box targets` shows what a box can run, grouped by machine. Each machine
heads its block with its room (`8 GiB free · 2 more boxes`, or `unreachable`).

Below the room is one row per target. The columns are OS, image, the smallest
shape it takes (the smallest shape overall when ci names none) and NOW, which
is `✓ fits` or ci's reason in dim. `--json` prints ci's document unchanged.

## Creating

`dev box create` blocks until the box runs. Projects are positional:

```
dev box create [--target T] [--shape S] [--arch ARCH] [--by LABEL]
[--ttl HOURS | --keep] [PROJECT...]
```

Inside a project with no project named, dev passes the project root's
directory name. `--arch` takes `x86_64` or `aarch64` and goes to `ci box create`
as it is. Without it ci gets no `--arch` flag and picks `x86_64`.

The lifetime is 4 hours unless you pass `--ttl HOURS` or `--keep`. `--ttl`
takes a whole number of hours, and `--ttl` with `--keep` exits 2.

`--by` defaults to `$DEV_AGENT`, else `human:$USER` (or `human:$LOGNAME`) when
stdin is a terminal, and dev always passes it. With none of those, dev exits
with a message naming `DEV_AGENT` and calls no ci. Claude Code's `!`
prefix runs with no terminal, and there you pass `--by human:$USER`.

The last line is:

```
Created <name> · <target> @ <machine> · <shape> · <time left>
· dev connect <name>
```

### The pickers

On a terminal, `create` asks two questions, target first. A target's minimum
rules shapes out.

- The target picker lists each target with its OS, image and smallest shape. A
  target that cannot take a box now but could once room frees can be picked
  and says `waits for room` with ci's reason. One whose smallest shape can
  never fit, or whose machine ci could not ask, is greyed with ci's reason.
- The shape picker lists the shapes for that target with CPU and memory. A
  shape is greyed when it is below the target's minimum or can never fit. A
  shape that fits only after a wait can be picked and says `waits for room`.
- A warning (such as the last running slot) shows beside a row that can be
  picked. The cursor starts on ci's default shape.

When no target, or no shape, can be picked, dev names the running boxes to
stop and exits 1. Cancelling a picker exits 1 and creates nothing.

`--target T` skips both pickers and takes ci's default shape. `--shape S`
skips only the second. With no terminal there are no pickers and ci applies its
defaults, and ci alone refuses a shape below the target's minimum.

### Agents

An agent creates a box with `--ttl HOURS`, and with `--keep` only when the
owner asks for a kept box. It deletes the box when its work ends.

On a box an agent writes scratch files only under `~/scratch/<session>/` and
removes that folder when the work ends. Projects live under `/srv/projects`.

## The other subcommands

### Leaving the box out

Leave the box out of `show`, `stop`, `resume`, `extend`, `tools install` or
`delete` and a terminal gets the same box picker `dev connect` uses. It lists
only the boxes the command can act on: running ones for `stop`, `extend` and
`tools install`, stopped ones for `resume`.

Without a terminal a missing name exits 2 and says to pass a name, with an
example command such as `dev box delete ci-abc -y`.

### show

`dev box show` prints the box as `key: value` lines. It prints `tmux_sessions`
as items such as `main (attached)` or `build (idle 5m)`, `none` when there is
no tmux server and `unknown` when ci could not read them. A box that is not
running has no such line.

dev sends the projects after `--`, and skips a default project whose name
starts with `-`, with a warning. A null `tailnet_name` prints as `-`.

### retag

`dev box retag BOX --target T` moves a box to another target its machine
offers. It runs `ci box retag BOX --target T --json` and prints
`retagged BOX to T`, after ci changes the target in the store and in the
instance's config.

A box with no `--target`, or with no name, is a usage error before ci runs.
When ci cannot retag the box, its reason prints on standard error, as for the
other box commands, and dev exits with ci's code.

### tools install

`dev box tools install BOX [PROJECT...]` reinstalls a running box's tools, for
every project or the projects named after the box. It prints one line per
project. A box that is not running exits 6.

### extend

`dev box extend` needs `--ttl HOURS` or `--keep`. It prints the same summary
line as `resume`, led by `extended`.

### delete

`dev box delete` asks on `/dev/tty` unless you pass `-y`, and exits 2 with no
terminal. Answering no prints `not deleted` and exits 1.

The prompt wraps its consequence to the terminal width on lines above the
`[y/N]` question. It says `You're attached to it.` when a tmux session of the
box is attached.

The command ends with `Deleted <name> · archive <path>` or
`Deleted <name> · no archive`.

`dev box delete --no-archive` deletes the box without archiving its projects,
so anything not pushed is lost, and its question says so.

### Names and limits

A box name is 1 to 40 of `a-z`, `0-9` and `-`, else exit 2.

## Plain ssh

`ci ssh config` writes a Host block for every box and every connectable host
into `~/.local/state/ci/ssh_config` (`$XDG_STATE_HOME/ci/ssh_config`), with the
host key file and strict checking.

For plain `ssh <box>` to work, `~/.ssh/config` needs an `Include` of that file
as its first line, before any `Host *`. `dotfiles/ssh/.ssh/config` already
starts with it, and `dev install ssh` links it.

`bootstrap.sh` reminds you to add this line to a config you keep by hand:

```
Include ~/.local/state/ci/ssh_config
```

The connection options (ControlMaster and the keepalives) live in
`[box] ssh_options` of `dotfiles/ci/.config/ci/config.toml`.

## Connecting

```
dev connect
dev connect myproject-k3x --ssh
```

`dev connect` and `dev box connect` are the same command. With no name it
lists the boxes, the current project's first, and you pick one.

Inside a project the last item, `new box for <project>`, asks for the target
and the shape as `dev box create` does, then creates a box and attaches. A
stopped box is resumed first.

Any other state than running or stopped exits 6, as does a box with no
`tailnet_name` or no project path yet.

dev then runs `ci box show <box>`, which writes the box's host keys to ci's
known_hosts. It replaces itself with this command, told to trust only that
file, so a box's host key is never accepted on first use:

```
et -c "tmux new -A -s <session> -c <dir>" <ssh_user>@<tailnet_name>
```

The session is the first project's name or the box name, with `.` and `:`
turned into `_`. The directory is the first project's `path`, or
`/srv/projects` with no project, so a session never starts in `$HOME`. A path
outside `/srv/projects[/<name>]` exits 1.

`--ssh`, or an `et` missing from PATH (with one warning), runs
`ci ssh <box> -- tmux ...` with the same tmux command. It checks the same host
keys.

### Machines that are not boxes

The host setup can mark a machine or an instance as connectable: an Incus
instance, a tart VM, the Mac host or example-box. `dev connect` reaches them
too, and it never talks to Incus or accepts a host key on first use.

After listing boxes it runs `ci ssh config`, then reads `ci ssh ls --json` and
keeps its host rows. The picker shows the connectables after the boxes, one row
each with the name, state, kind, machine and login user.

```
dev connect host-a
```

`dev connect NAME` takes a box or a connectable. A box name goes the way above,
without asking `ci ssh config` or `ci ssh ls`. Any other name that ci lists as
a connectable runs `ssh ci-NAME`, which relays through the hub and checks the
host key ci pinned.

A ci that has no `ssh config` command makes dev list boxes only, with one note.
Any other ci failure prints ci's message as one line and the picker still
offers the boxes, while a name that is no box exits with ci's code.

## Errors

When ci exits non-zero with an `{"ok":false}` document, dev prints
`dev box <sub>: <message>` to stderr and exits with ci's code (2 to 11, 10 and
11 included). Other output passes through, such as clap usage text, with ci's
exit code. Progress lines ci writes to stderr reach the terminal.

`dev --remote` refuses `box` and `connect`.

## Reference: the subcommands in detail

`dev box` is a built-in command with subcommands for any project. It reads
ci's JSON with `dev.json` and needs `ci` on PATH, else it dies saying so.
Every box is named by ci, and dev takes the host only from the box's
`tailnet_name`.

- `ls [--all] [--json]`: prints the room, then one row per box.
  - The room starts with a hub line
    `Boxes  <bar> 2 of 3 running · 1 more can start`, from `cap.running` and
    `cap.running_max`. Then come the entries of `machines`, each with its name,
    a `Boxes` line with its `running` count and a `Memory` line
    `24 of 32 GiB used · 8 GiB free`. ci gives no per-machine cap yet
    (`max_boxes` is null).
  - On the `Memory` line, used is `memory_limits_gib`, free is
    `new_box_room_gib` and the bar's total is the two added. A machine with
    `reachable: false` shows `unreachable` in dim instead.
  - Bars come from `dev.ui.bar`, so they appear on a terminal only. Piped
    output has the words alone with no color codes.
  - The table has NAME (a `●` or `○` mark and the name, bold), TARGET
    (`<target> @ <machine>`), STATE, ACTIVITY, WHO, SHAPE, PROJECTS and
    TIME LEFT.
  - ACTIVITY is `attached` when any `tmux_sessions` entry is attached, else
    `idle <shortest idle_seconds>`. It is `-` for `[]` and for a box that is
    not running, and `?` for null.
  - WHO is `you` for `human:<USER, else LOGNAME>`, `agent` for any `agent:`
    value, the name for another `human:`, else `created_by` as it is.
  - Time left is `3h12m left` or `kept` for a running box, `deleted in 6d` for
    a stopped one, and `-` for other states.
  - `no boxes` follows the room when there are none.
  - `--json` prints ci's document byte for byte and draws nothing.
- `targets [--json]`: reads `ci fleet targets --box --json`, then prints one
  block per machine.
  - It reads the targets document, then the shapes document for the room, one
    per line, never the text.
  - Each block holds the machine name and its room (`8 GiB free · 2 more
    boxes`, from `machines[].new_box_room_gib` and the hub cap, `unreachable`
    for a machine ci could not ask). A table follows with TARGET, OS (`Linux`,
    `Windows`, `macOS`), IMAGE, MIN SHAPE and NOW.
  - MIN SHAPE is `min_shape`, else the shape with the least memory. NOW is
    `✓ fits` when `can_take_box_now`, else `reason` dim.
  - `--json` prints ci's targets document (the first line) unchanged, without
    the shapes document.
- `create [--target T] [--shape S] [--arch ARCH] [--by LABEL] [--ttl HOURS or
  --keep] [PROJECT...]`: creates a box and prints its line.
  - On a terminal (standard input and output are both terminals) with no
    `--target`, it asks which target to run (`What should the <project> box
    run?`). Rows are `<target>  <OS> · <image>  from <min shape>  @ <machines>`
    with the machines' room in the note.
  - A target whose smallest shape fits only after a wait can be picked and
    shows `waits for room · <reason>` as its note. A target whose smallest
    shape can never fit, or whose machine ci could not ask, is greyed with
    ci's `reason`.
  - With no `--shape`, it then asks which shape, from the shapes document of
    `ci fleet targets --box --target T --json` (`Pick a shape for T on
    <machine>`). Rows are `<name>  <cpu> CPU  <memory_gib> GiB  <notes>`, and
    the cursor starts on `default: true`. A `warning` shows beside a
    pickable row.
  - A shape row is greyed with the reason for `below_min` (`below T's
    minimum`) or `fits: never`. A machine ci could not ask counts as never.
    A `fits: wait` row can be picked and says `waits for room`.
  - When no target, or no shape, can be picked, it names the running boxes on
    the machines to stop and exits 1. Cancelling a picker exits 1 and creates
    nothing.
  - `--target` skips both pickers and takes ci's default shape, and `--shape`
    alone skips only the second. With no terminal there are no pickers and ci
    applies its defaults (a shape below the minimum is refused by ci alone).
  - It then prints `Created <name> · <target> @ <machine> · <shape> ·
    <time left> · dev connect <name>`. The time left is `kept` for a box with
    no expiry, and the state while it has none yet.
  - Projects are positional. Inside a project with none given, it passes the
    project root's basename.
  - `--arch` is passed to ci only when given (`x86_64` or `aarch64`). It
    always passes `--by`: the given label, else `$DEV_AGENT`, else `human:$USER`
    (or `human:$LOGNAME`) at a terminal, else it refuses naming `DEV_AGENT`.
  - `--ttl` with `--keep` is a usage error before ci runs.
- `show [BOX] [--json]`: with `--json` prints ci's document unchanged, else
  the box as `key: value` lines.
  - `tmux_sessions` shows as `name (attached)` or `name (idle 5m)` items,
    `none` for `[]` and `unknown` for null, on a running box only.
  - Projects reach ci after `--`. A default project whose name starts with `-`
    is skipped with a warning.
- `stop [BOX]`: prints `stopped <name>, deleted in Nd unless resumed`, with N
  the days to the box's `delete_after`, rounded up.
- `resume [BOX] [--ttl HOURS or --keep]`: keeps the box's lifetime unless a
  flag changes it. It prints `resumed <name> (<target>, <shape>, <projects>),
  <time left>, host <tailnet_name>`, the line `create` used to print.
- `extend [BOX] (--ttl HOURS or --keep)`: one of the two is required.
- `retag BOX --target T`: moves the box to target T through
  `ci box retag BOX --target T --json` and prints `retagged BOX to T`.
  - Both the box name and `--target` are required, and a missing one is a
    usage error before ci runs.
  - When ci cannot retag the box, its reason prints on standard error, as for
    the other box commands, and dev exits with ci's code.
- `tools install [BOX] [PROJECT...]`: reinstalls a running box's tools through
  `ci box install-tools BOX --json`, with the projects after `--`.
  - It prints `<project>: tools installed` or
    `<project>: no .dev/tools.tsv, nothing installed` per project, and
    `no projects` when ci installed none.
  - A box that is not running exits with ci's 6, and a ci error prints as
    dev box tools install: <message>.
- `delete [BOX] [-y] [--no-archive]`: asks on `/dev/tty`, with the consequence
  wrapped to the terminal width on lines above the question.
  - The consequence is `Its projects are archived first.` then
    `Delete <box>? [y/N]`. With `--no-archive` it is `Anything not pushed is
    lost.` then `Delete <box> without an archive? [y/N]`, and `--no-archive`
    goes to ci.
  - When a tmux session of the box is attached (read from `ci box ls --json`),
    the consequence starts with `You're attached to it.`.
  - With no terminal and no `-y` it is a usage error.
  - It prints `Deleted <name> · archive <path>`, or `Deleted <name> · no
    archive` when ci wrote none. dev prints no archive-days number of its own.
- `connect [BOX] [--ssh]`: same as `dev connect`, below.

### Picking a box

When the box is left out, `show`, `stop`, `resume`, `extend`, `tools install`
and `delete` pick one with the shared picker (`dev.ui.picker`, rows as in
`ls`). It runs when standard input and output are both terminals.

- titles: `Show which box?`, `Stop which box?` and so on.
- rows: every box for `show` and `delete`, only the boxes the command can act
  on for the others (running ones for `stop`, `extend` and `tools install`,
  stopped ones for `resume`).
- skipped screen: `stop` and `delete` always show the screen, and the others
  skip it when one row is left.
- no such box: dev prints `dev <command>: no running boxes to stop` (or the
  matching words) and exits 1.

Without a terminal a missing name is a usage error with exit 2. The line ends
like this, in the command's own words, with `-y` only for `delete`:

```
No box given and no terminal to pick one. Pass a name,
like dev box delete ci-abc -y.
```

### Errors and data

- ci's `{"ok":false,...}` document: `dev box <sub>` prints `error.message` to
  stderr and exits with ci's code (2 to 11, 10 and 11 included).
- Output that is not JSON, such as clap usage text, passes through with ci's
  exit code. Progress lines ci writes to stderr reach the terminal.
- `tailnet_name`: null from ci while the box has none, shown as `-` as its
  host.
- `projects`: a list of `{name, path}` objects from ci, and dev shows the
  names.
- `ci ssh config`: writes a Host block per box into
  `~/.local/state/ci/ssh_config`, which `~/.ssh/config` includes as its first
  line. It takes the ssh options from `[box] ssh_options` in
  `dotfiles/ci/.config/ci/config.toml`.
- box name: must match `^[a-z0-9-]{1,40}$`, else exit 2.
- times: computed in Lua from the RFC 3339 stamps, so macOS and Linux agree.
- `dev --remote`: refuses every `box` subcommand.

### dev connect in detail

`dev connect [BOX] [--ssh]` is the same handler as `dev box connect`. With no
box it lists them as `ls` does, the current project's boxes first, and picks
one with the shared picker (`dev.ui.picker`, titled `Connect to a box`). Outside
a project the picker skips the screen when exactly one row would be left.

Inside a project it offers a last item `new box for <project>`. That item asks
for the target and the shape with the pickers of `create`, then creates and
attaches.

With no name and no terminal, once boxes exist, it is a usage error like the
other box commands (exit 2). With no boxes outside a project it prints
`There are no boxes. Create one with dev box create.` and exits 1.

A stopped box is resumed first. Any state other than running or stopped exits
6, as does a box whose `tailnet_name` is still null.

dev then runs `ci box show <box> --json`, which writes the box's host keys to
ci's known_hosts. The file is `$XDG_STATE_HOME/ci/known_hosts` when
`XDG_STATE_HOME` is absolute, else `~/.local/state/ci/known_hosts`. dev then
execs this command, so no host key is trusted on first use:

```
et --ssh-option UserKnownHostsFile=<that file>
  --ssh-option StrictHostKeyChecking=yes
  -c "tmux new -A -s <session> -c <dir>" <ssh_user>@<tailnet_name>
```

A shown box with no `tailnet_name` or `ssh_user` exits 6.

The session is the first project's name or the box name, with every character
outside `A-Za-z0-9_-` (so `.` and `:`, which tmux reserves) turned into `_`.
The directory is the first project's `path` or `BOX_PROJECTS_DIR`
(`/srv/projects`) for a box with no project, so a session never starts in
`$HOME`.

`dir` must match `^/srv/projects(/[A-Za-z0-9][A-Za-z0-9._-]{0,63})?$`, the
names ci can produce, else exit 1. A running box whose first project has a null
`path` exits 6.

`--ssh`, or a missing `et` with one warning, execs
`ci ssh <box> -- tmux new -A -s <session> -c <dir>` instead. It checks the same
host keys and allocates a terminal.

### Connectables in detail

`dev connect` also reaches what the host setup marks as connectable (Incus
instances, tart VMs, the Mac host, example-box), through `ci ssh`. After
`ci box ls --json` it runs `ci ssh config`. That writes a `Host` block per box
and host into ci's ssh_config include, and the blocks of hosts run
`ci ssh proxy NAME` as their ProxyCommand.

dev then runs `ci ssh ls --json`, read as
`{protocol, things:[{name, kind, machine, state, address, user}], notes}`. The
`kind` is `box`, `session` or `host`, and rows are ordered boxes, sessions,
hosts. dev keeps only the rows of kind `host` and takes the boxes from
`ci box ls --json`.

The picker shows the connectables after the boxes and before the new-box item.
A row is name, state, kind, machine and user, and `dev connect NAME` takes
either.

- A name that ci lists as a box takes the box path above and never calls
  `ci ssh config` or `ci ssh ls`.
- A name that is no box asks `ci ssh ls`. When ci lists the name, dev execs
  `ssh ci-<name>` (`ssh <name>` when the name already starts with `ci-`, which
  ci uses as its own alias) through `dev.os` exec with no shell.
- ci's ProxyCommand and pinned known_hosts decide the host key, and `--ssh`
  changes nothing.

Each string in `notes` goes to standard error as "Ci said: <note>". A host
whose name is not 1 to 40 of `a-z`, `0-9` and `-` is skipped with the note
"Skipping a connectable with an invalid name.". A host whose `ci-` alias is the
name of another connectable is skipped with the note "Skipping <name>, because
its alias <alias> is the name of another connectable.".

A ci that lacks either command exits 2 from `ssh config` or `ssh ls`. That
makes dev list boxes only, with the note "This ci has no ssh command, so only
the boxes are listed.".

Any other non-zero exit prints ci's `error.message` (or the first line of its
standard error that starts with `error:`, else the first line) as one line,
"Ci said: <message>". The picker then still offers the boxes, and a name that
is no box exits with ci's code. On success ci's standard error goes through to
the terminal unchanged. When dev cannot make a temporary file for that standard
error, it prints "Cannot make a temporary path for the standard error of ci."
and runs ci anyway.

`tests/lua/connect_test.lua` and `tests/dev/box_test.sh` run all of it against
a fake `ci` and `ssh`.
