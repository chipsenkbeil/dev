# commands: How the scripts in .dev/ become commands

`dev <command>` runs `.dev/<command>.lua` or `.dev/<command>.sh` at the repo
root. A `.sh` script must be executable, a `.lua` script needs no exec bit, and
the `.lua` file wins when both exist.

A script replaces a built-in of the same name, and `dev help -a` marks it
`(override)`. A script that matches no built-in is a local command.

`dev land` is the one land command, so a project's `.dev/land.lua` replaces the
built-in whole and owns its own turn, landed note and move to the release
column. `dev help land` marks it `(override)`.

Every command that works in a repository supports jj when the repo uses it and
git otherwise, a worktree included. That holds for a project script and for a
built-in alike, and a new command ships with both.

```
dev help -a
dev help lint
```

## Commands with subcommands

`dev <command> <sub>` runs `.dev/<command>/<sub>.sh` (or `.lua`). A directory
of executable scripts is a command with subcommands, unless a flat
`.dev/<command>.sh` takes the whole name, and dev then warns once that the
script shadows the directory.

A built-in command with subcommands (`dev tools`) is never replaced by a
script, but a script replaces one of its subcommands, as it does a built-in
command, and a script can add new ones. Such a command run with no
subcommand, or an unknown one, exits 2 and lists the subcommands.

Subcommands nest to any depth. `.dev/<command>/<sub>/<sub2>.sh` runs as
`dev <command> <sub> <sub2>`, and a directory of scripts inside a command with
subcommands is one too, with its own `DESCRIPTION`, listing and exit 2.
`dev help`, `dev __subs` and `dev __flags` take one word per level.

A command word has no hyphen. A hyphen reads as two words, so a name such as
`install-tools` is a command and a subcommand (`dev box tools install`). Flags
keep their hyphens.

The first line of `.dev/<command>/DESCRIPTION` describes the command. Without
it, `dev help` lists the subcommand names.

## Global commands

The folder `dev/commands` under the user config folder holds commands for
every project. The config folder is `XDG_CONFIG_HOME` when that is an absolute
path, else `~/.config`, so the usual folder is `~/.config/dev/commands/`. It
has the layout of `.dev/`: scripts, folders of subcommands, `DESCRIPTION`
files, the `lua` folder and the reserved folders below.

For one command, and for each subcommand of a command with subcommands, a
project script beats a global script, which beats a built-in. A global script
runs with the project you are in as its root. A global Lua command finds its
modules in the `lua` folder of the global folder and in the `lua` folder
beside it, not in the project's `.dev/lua`. `-v` prints its path relative to
the global folder.

## Reaching an overridden command

A script that replaces a command hides the one it replaced. A first word of
the form `builtin:<command>` or `global:<command>` answers from that source
alone, whatever the project holds:

```
dev builtin:init
dev builtin:board ls
```

`builtin:` runs the built-in, to let a global `init` call the built-in one
first. `global:` runs the script in the global folder and skips a project
script of the same name. Both work for a command with subcommands, and the
rest of the line reads as it does without the prefix: `dev help builtin:board`,
`dev builtin:board ls --help` and shell completion take the prefix too.

A prefixed command always runs on this machine. `--remote` with one exits 2,
and the remote default does not send it.

A source other than `builtin` or `global`, or a command the source lacks, exits
2 with one sentence on standard error:

- `The source <name> is not builtin or global.`
- `The built-in commands have no command <words>.`
- `The global commands have no command <words>.`

There is no `project:` prefix.

## Reserved folders

`.dev/lua`, `.dev/topics` and `.dev/standalone` are never commands, and dev
lists and runs nothing inside them. `standalone` holds shell that must run
where dev cannot.

Line 2 of each script there reads
`# standalone: runs on <where>, where dev is absent`. `dev help porting` has
the list of places.

## Header lines

dev reads the comment block under the shebang of each script.

- the first comment line is the description in `dev help`.
- `# flags: --a --b` declares the flags that `dev help <command>` and shell
  completion offer, and the only flags dev lets through to the script.
  `dev help flags` has the rule.
- `# group: <name>` sets the heading `dev help` lists a command under. A
  command with no group lands in a group named after the project directory. A
  command with subcommands takes the group of its first subcommand script that
  has the line.
- `# hidden` keeps a flat command out of `dev help`, and `dev help -a` still
  lists it.
- `# local`, `# fetch JOB FILE`, `# patch JOB FILE` and `# positional` change
  how a command is called. `dev help flags` describes them.

A Lua command (`.lua`) takes the same lines in one leading `--[[ ... ]]`
block, with no `# ` prefix. The `group:` line comes first and the description
on the line after it, as every Lua command in `.dev` has it. The bare `hidden`,
`local` and `positional` lines and the `flags:` line sit in the same block.

Project scripts named `__*.sh` or `__*.lua` never appear in any listing.

## Project topics

A `.md` file in `.dev/topics/` is a topic, shown by `dev help <topic>`. Its
first line is `# <name>: <summary>`, where the name is the file name.

Run `dev __topics check` to check the format, the names and every quoted `dev`
line. It also flags a prose line wider than 80 columns that has a space past
column 80. Fenced lines and table rows may run longer.

dev refuses to run any project script as root.
