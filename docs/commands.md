# commands: How the files in .dev/commands/ become commands

`dev <command>` runs the command file `.dev/commands/<command>.luau`,
`.sh` or `.ps1` at the repo root. A `.luau` command runs inside dev and
needs no exec bit. A `.sh` command must be executable. A `.ps1` command runs
under `pwsh -File` on Windows only. dev refuses a file that ends in `.lua`
and names the `.luau` spelling.

When one name has several files in a layer, `.luau` wins over `.sh`, and
`.sh` wins over `.ps1`.

Every command that works in a repository supports jj when the repo uses it and
git otherwise, a worktree included. That holds for a project command and for a
built-in alike, and a new command ships with both.

```
dev help -a
dev help lint
```

## The .dev folder

A project's `.dev/` holds these and nothing else dev reads:

- `config.toml`: the project's settings.
- `commands/`: the only place dev looks for the project's commands.
- `help/`: help pages, one `.md` file each. See "Project help pages".
- `lib/`: Lua modules. The `lib` alias of the project's `.luaurc` names it, so
  `.dev/lib/myproj/checks.luau` loads with `require("@lib/myproj/checks")`.
  `dev init` writes that alias. `dev help porting` has the require forms.
- `tests/`: the project's own `*_test.luau` suites, which `dev test` runs.
- `helpers/`: scripts that commands call. dev never lists them, never runs
  them as commands and never completes them. They have no `__` prefix.

`lib`, `helpers`, `help` and `tests` are not commands, and dev lists and runs
nothing inside them. Names have no `__` rule. The built-in `__complete`,
`__board` and `__pkg` are ordinary specs with `hidden = true`.

## The three layers

dev merges three layers of commands, each laid out like `.dev/commands/`:

- built-in: the commands baked into dev.
- global: `~/.config/dev/commands/`, for every project. The config folder is
  `XDG_CONFIG_HOME` when that is an absolute path, else `~/.config`.
- project: `.dev/commands/` at the repo root.

For one command, and for each subcommand of a command with subcommands, a
project command beats a global one, which beats a built-in. `dev help -a`
names each command's layer and what it overrides. A global command runs with
the project you are in as its root, and `-v` prints its path relative to the
global folder.

A command file replaces a built-in of the same name, and `dev help` marks it
`(override)`. A global file that replaces a built-in with a ci job runs here
under the remote default (ci never has the global folder). A command that
matches no built-in is a local command. A built-in command with subcommands
(`dev tools`) is never replaced by a file, but a file replaces one of its
subcommands and can add new ones.

## Commands with subcommands

`dev <command> <sub>` runs `.dev/commands/<command>/<sub>.luau`. A folder of
command files is a command with subcommands, unless a flat file takes the
whole name, and dev then warns once that the file shadows the folder.
Subcommands nest to any depth. Such a command run with no subcommand, or an
unknown one, exits 2 and lists the subcommands.

A command word has no hyphen. A hyphen reads as two words, so a name such as
`install-tools` is a command and a subcommand. Flags keep their hyphens.

The first line of `<command>/DESCRIPTION` describes the command. Without it,
`dev help` lists the subcommand names.

## Reaching an overridden command

A first word of the form `builtin:<command>` or `global:<command>` answers
from that layer alone, whatever the project holds:

```
dev builtin:init
dev builtin:board ls
```

`builtin:` runs the built-in, to let a global `init` call the built-in one
first. `global:` runs the command in the global folder and skips a project
command of the same name. The rest of the line reads as it does without the
prefix: `dev help builtin:board` and shell completion take the prefix too.

A prefixed command always runs on this machine. `--remote` with one exits 2,
and the remote default does not send it.

A source other than `builtin` or `global`, or a command the source lacks, exits
2 with one sentence on standard error:

- `The source <name> is not builtin or global.`
- `The built-in commands have no command <words>.`
- `The global commands have no command <words>.`

There is no `project:` prefix.

## The built-in project commands

`dev lint`, `dev fmt` and `dev test` are built-ins that run a fixed sequence
for the project's type. `dev build`, `dev run` and `dev fetch` work the same
way. dev reads the type from the files at the project root, and the first
match in this order wins:

1. `Cargo.toml`: rust
2. `main.lua` and `conf.lua` together: love2d
3. `project.godot`: godot
4. `package.json`: node
5. a `.lua` file at most four levels below the root (`find -maxdepth 4`, so a
   file in a folder three levels down counts and one in a fourth-level folder
   does not), skipping hidden folders, `node_modules` and `target`: lua
6. `Makefile`: make

A project that matches none is undetected. Every built-in then prints `There
is no built-in COMMAND for an undetected project.` and exits 1. A type with no
sequence for one command prints `There is no built-in COMMAND for TYPE
projects.` and exits 1 the same way.

What each type runs:

- rust, `lint`: `cargo +nightly fmt --check`, then `cargo clippy --all-targets
  --all-features -- -D warnings`, then `ast-grep scan` when `sgconfig.yml`
  exists.
- rust, `fmt`: `cargo +nightly fmt`.
- rust, `test`: `cargo nextest run --all-features`, then `cargo test --doc
  --all-features`.
- love2d, `lint` and `test`: `make lint` or `make test`, so the Makefile needs
  that target. `fmt` runs stylua over the project's `.lua` files.
- lua, `fmt`: stylua over the project's `.lua` files. `lint` and `test` run
  the Makefile target of that name.
- make: `make -C ROOT lint`, `fmt` or `test`, refused when the Makefile has no
  such target.
- node: `npm --prefix ROOT run lint`, `fmt` or `test`, refused when
  `package.json` has no script of that name.
- godot: no `lint`, `fmt` or `test`.

A sequence stops at the first step that fails and exits with that step's code.
The words after the command, and everything after `--`, reach the last step as
typed, and both steps of rust `test`. Rust `lint` ignores them. A `fmt` with no
`.lua` file to format says so and exits 0. `dev help lint` prints the lines the
built-in would run in the current project.

A file named `lint`, `fmt` or `test` in `.dev/commands/` replaces the built-in
for that project, as the three layers above describe, and the built-in no
longer runs there. dev's own repo does this, so its checks differ from the
sequence above. `CONTRIBUTING.md` describes them.

## The dev.command spec

A `.luau` command file returns `dev_command({...})`, where
`dev_command = require("@dev/command")` validates the table and returns it.

```luau
local dev_command = require("@dev/command")

return dev_command({
    summary = "Wait for a card",
    group = "Check your work",
    flags = {
        { name = "wait", short = "w", kind = "number", default = 30 },
        { name = "label", kind = "string", repeatable = true },
    },
    args = { { name = "card", required = true, complete = "board-card" } },
    run = function(opts, args, ctx)
        return 0
    end,
})
```

The fields:

- `summary`: the one line `dev help` shows.
- `group`: the heading `dev help` lists the command under. A command with
  subcommands takes the group of its first subcommand that has one.
- `long`: markdown text for `dev help` and `--help`. See "Long text and help
  pages".
- `hidden`: keeps the command out of `dev help`. `dev help -a` still lists it.
  A hidden subcommand is left out of its parent's listing and description, and
  a command whose subcommands are all hidden is hidden too.
- `remote = false`: the command never runs on a remote runner, whatever the
  remote default says. `--remote` with it exits 2.
- `requires = { "workspace" }`: refuses the command in a primary checkout. It
  holds only when `DEV_AGENT` names a workspace role (runner, implementer,
  planner, reviewer or verifier) and the project is a jj or git checkout that
  is the main one. A tempdir with no `.jj` or `.git` is never refused. A test
  that makes a checkout there leaves `DEV_AGENT` out of the environment it
  passes, or runs the command in a workspace made with `dev ws new`.
- `requires = { "lead" }`: refuses the command in a primary checkout when
  `DEV_AGENT` names the lead role, under the same checkout test. A command
  lists both words to refuse every agent role there.
- `runs_local`: the command runs here under the remote default.
- `positional`: keep `KEY=value` words in the arguments. Without it, every word
  shaped `KEY=value` whose key starts with an uppercase letter goes to
  `ctx.vars` and is dropped from the words, before the spec parses them. A
  command that takes such a word as a plain argument, such as a scenario named
  `FOO=bar`, sets `positional = true`. Only a project or global command has
  its words split, and the words after a `--` stay where they are.
  - A `KEY=value` word never reaches the spec's refusal of unknown words, so
    a mistyped variable is dropped with no message, even when the command
    reads none of its keys. dev gives no warning, with no declared
    variables to check the key against.
- `fetch = { job, file }` and `patch = { job, file }`: fetch a ci file or run
  a patch job, as `dev help remote` describes.
- `flags`: each has a `name`, an optional one-letter `short`, a `kind` of
  `string`, `number` or `boolean`, `default`, `choices` (strings only),
  `repeatable`, `required`, `hidden`, `help` and `complete`. A `string` or
  `number` flag without `repeatable` that appears twice is a usage error, exit
  2 with a sentence naming the flag and then the usage line. A `boolean` flag
  given twice is accepted.
- `args`: each has a `name`, `required`, `list` (the last one only), `rest`,
  `help` and `complete`. `rest` needs `list`: from its first word on, the arg
  takes every word verbatim, so a word that starts with `-` stays text.
- `pass_unknown`: a word that looks like a flag the spec does not declare goes
  to the last argument instead of being refused. That argument needs `list`.
- `globals = false`: the command takes the global flags as its own words.
- `passthrough`: the words after `--` reach `ctx.passthrough`. Without it they
  are plain arguments, and a command with no argument for them refuses them.
- `run(opts, args, ctx)`: `opts` is keyed by flag name with `-` as `_`, `args`
  by argument name, and `ctx` holds `name`, `words`, `root`, `verbose`,
  `source`, `passthrough`, `vars` and `argv`, the unparsed words.

A flag that takes a value takes the next word verbatim, even one that
starts with a dash. A word that holds whitespace before any `=` is never a
flag.

`-h` and `--help` are never parsed by a spec. They always print help. A flag
named `help` or with the short `h` is refused by `dev help --check-topics`.
An unknown field, a bad kind, `choices` on a non-string, a `list` argument
that is not last, a required argument after an optional one and a `requires`
word other than `workspace` and `lead` fail at load.

`complete` is a list of values, a provider name or a function. The providers
are `board-card`, `board-column`, `box` and `file`. A function takes the
completion context and returns values or `{ value, description }` pairs. A
`choices` list completes a flag without a `complete` field.

`run` returns an integer exit code or nothing. A load or run error prints
`dev <name>: <message>` with no traceback and exits 1.

### Usage errors

A bad flag or argument prints one sentence, then the usage line drawn from the
spec, on standard error and exits 2. The sentence starts with the command name
and a colon, and the usage line reads `usage: dev tools check [--group NAME]`
for that command. A usage error that a command raises from its own checks, in
`run`, prints the usage line too. No curated help follows it.

## Header lines of .sh and .ps1

A `.sh` or `.ps1` command declares the same fields in the comment lines under
the shebang, up to the first line that is not a comment. Blank lines do not
end the block, and shellcheck lines are skipped.

- `# summary: TEXT`. Without it the first plain comment line is the summary
  and the rest is the long text. The summary is never repeated in the long
  text. With `# summary:` set, every plain comment line is long text.
- `# group: TEXT`
- `# see_also: NAME [NAME...]`
- `# hidden`
- `# flag: NAME [short=S] [kind=string|number|boolean] [choices=a,b]
  [repeatable] [required] [hidden] [default=V] -- HELP` declares one flag, on
  one line. `kind` defaults to `string`.
- `# arg: NAME [required] [list] -- HELP` declares one argument. A `.sh`
  command with no `# arg:` line accepts any plain words and passes them on,
  but still refuses a flag it does not declare. One `# arg:` line turns on
  strict checking, and the script then gets only the declared arguments. A
  `.luau` spec with no `args` still refuses extra words.
- `# remote: false`
- `# requires: WORD...`
  A script that overrides a built-in declares only its own header facts, so it
  must repeat any `remote` or `requires` line of the built-in it replaces.
- `# passthrough`
- `# runs_local`
- `# positional`
- `# globals: false`
- `# fetch JOB FILE` and `# patch JOB FILE`

The old `# flags:` and `# local` lines fail at load with a sentence naming the
replacement. At run time each parsed flag reaches the script as
`DEV_FLAG_NAME`, upper case with `_` for `-`. A boolean is `1` or unset, and a
repeatable flag's values are joined by newlines. The arguments are the
script's positional parameters, and a flag the spec consumed is not among them.
A `.sh` file needs the exec bit. dev also sets `DEV_ROOT`, the absolute project
root, so `"$DEV_ROOT/.dev/helpers/NAME"` finds a helper from any folder.

The global Lua library folder is `~/.config/dev/lib`, the global match for
`.dev/lib/`. A global command reaches it through a `.luaurc` in `~/.config/dev`
that aliases `lib` to `lib`.

## Completion

`dev completion <shell>` prints a completion script for `bash`, `zsh`, `fish`
or `powershell`. An unknown shell exits 2 and names the four. Each script
passes the words typed so far to `dev __complete` and offers its lines, one
`value`, a tab and a description per line. A provider that fails or takes too
long prints nothing and exits 0.

Load a script once per shell:

```
source <(dev completion bash)
dev completion zsh > "${fpath[1]}/_dev"
dev completion fish | source
dev completion powershell | Out-String | Invoke-Expression
```

Card ids come from a cache that `dev __complete` refreshes in the background
once it is 60 seconds old.

## Project help pages

A `.md` file in `.dev/help/` is a help page, shown by `dev help <page>`. Its
first line is `# <name>: <summary>`, where the name is the file name. The
built-in help pages are baked into dev.

A help page may not share a name with a top-level command or a built-in help
page, and `dev help --check-topics` reports a clash. The words of a nested
command such as `gerrit listen-build` never collide with a page name, which is
one word.

The one built-in name a project may reuse is `overview`. A project that has
`.dev/help/overview.md` says what it is for there, and `dev help overview` and
the `topic_text` function of `@dev/help` print dev's overview followed by that
page, which keeps its own `# overview: <summary>` heading. A project without
the file sees dev's overview alone, and the page cannot replace it.

Run `dev help --check-topics` to check the format, the names and every quoted
`dev` line. It also flags a prose line wider than 80 columns that has a space
past column 80. Fenced lines and table rows may run longer. In the dev repo
it checks `docs/` on disk.

## Running as root

As root, dev runs only `dev tools install`, `dev tools check` and the `__pkg`
driver, and refuses every other command.

## Long text and help pages

A spec's `long` is markdown. A command's `--help` and `dev help` print the
usage, the flags and the arguments drawn from the spec, then `long` rendered
through `dev.ui.markdown`.

The spec field `see_also` lists the help pages the help points at, as in
`see_also = { "boards", "flags" }`, and the help then ends with "See `dev help
boards` and `dev help flags`." One name gives "See `dev help boards`." A single
string is refused with a message naming the list form. A shell command writes
`# see_also: boards flags`. `dev help --check-topics` reports a listed name that
is no help page. The field name is one constant, `SEE_ALSO_FIELD`, that
`dev.spec` exports.
