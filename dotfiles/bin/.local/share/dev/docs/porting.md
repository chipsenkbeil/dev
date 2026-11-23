# porting: Port a .dev bash command to Lua

## Overview

A project command is a script in `.dev/`. It can be bash
(`.dev/<command>.sh`) or Lua (`.dev/<command>.lua`).

dev runs both the same way from the user's side: the same `dev help` listing,
the same `-h`, the same flag check. A Lua command runs inside the dev process,
so it gets dev's modules and skips a process spawn.

## Which script runs

When `.dev/<command>.lua` and `.dev/<command>.sh` both exist, the `.lua` file
wins. A `.lua` command needs no exec bit and a `.sh` command does. The rule is
the same for `.dev/<command>/<sub>.lua`.

A `.sh` command is a separate process and cannot call Lua. dev's modules are
not on its path, so port the whole command or leave it in bash.

## The command contract

dev loads the file with `load` and calls the chunk with one argument, the
context. Read it with `local ctx = ...`.

- `ctx.name`: the command as typed, a command and its subcommand joined by a
  space
- `ctx.words`: the command words
- `ctx.root`: the project root, an absolute path
- `ctx.args`: the positional arguments, with every `KEY=value` word removed
  unless the header has a `positional` line
- `ctx.vars`: the `KEY=value` arguments whose key starts with an uppercase
  letter, by key, and empty when the header has a `positional` line
- `ctx.after`: how many of `ctx.args` follow a `--`, 0 when none was typed
- `ctx.dashed`: whether a `--` was typed, even with nothing after it
- `ctx.verbose`: 0, 1 or 2, after `-v`, `-vv` and `VERBOSE`
- `ctx.interpreter`: the luajit dev runs under, as the launcher started it

### The exit code

The chunk returns the exit code as an integer, and nothing means 0. dev takes
the code modulo 256.

Any other return value, a Lua error or a syntax error ends the run with
`dev <name>: <message>` and exit 1, with no traceback. To stop early with
another code, return it, or call `os.exit`.

### The command helpers

`require("dev.command")` holds the helpers a command needs:

- `dev_command.usage_error(ctx, msg)`: print `dev <name>: <msg>` and exit 2
- `dev_command.no_args(ctx)`: refuse any positional argument, for a command
  that takes no positional arguments
- `dev_command.note(msg)`: write `msg` and a newline to standard error
- `dev_command.die(msg)`: print `msg` and exit 1
- `dev_command.show(ctx, argv)`: print `+ <argv>` on standard error when
  `ctx.verbose` is 1 or more
- `dev_command.need(binary, install)`: exit 1 with one warning when `binary` is
  not on `PATH`

### Cleanup on exit

Register `dev.os.on_exit(fn)` where a bash command would write `trap fn EXIT`.
Each cleanup runs once, newest first, on a return, on an error and when
`SIGTERM`, `SIGHUP` or `SIGINT` ends the command, which then exits with 143,
129 or 130. A signal that arrives while the command waits on a child process
takes effect once the child returns, and `SIGKILL` runs no cleanup.

## Header lines

A Lua command keeps the header lines of a shell script in one leading block
comment. The block starts with `--[[` alone on the first line and ends with
`]]` alone on its own line.

The first line inside it that is not a `group:`, `hidden`, `local`,
`positional` or `flags:` line is the description. The other lines are:

- `group: <name>`: the heading `dev help` lists the command under
- `hidden`: keep the command out of `dev help`, so only `dev help -a` lists it
- `local`: keep the remote default from sending the command to ci
- `positional`: keep `KEY=value` words in `ctx.args` for a Lua command
- `flags: --a --b`: the flags `dev help <command>` and completion offer, and
  the only flags dev lets through to the script before a `--`

`dev help commands` and `dev help flags` have the rules. `-h` and `--help` stay
reserved, so a `flags:` line cannot declare them.

## Modules

Every module below is `require`d by its dotted name and documents its
functions in its doc comments.

- `dev.os`: run and capture commands (`run`, `capture`, `capture_input`,
  `capture_timed`), `which`, `exec`, `getuid`, `isatty`, `quote`, and
  `on_exit(fn)` for a cleanup in place of a bash `trap` on `EXIT`
- `dev.fs`: `exists`, `is_dir`, `is_file`, `is_link`, `is_exec`, `read`,
  `write`, `mkdir`, `remove`, `move`, `list`, `stat`, `realpath`,
  `readlink`, `mktemp`, `symlink`, `join`, `dirname`, `basename`
- `dev.json`: `decode` and `encode`
- `dev.toml`: `parse`
- `dev.config`: `get(root, "a.b")` reads `~/.config/dev/config.toml` and then
  `<root>/.dev/config.toml` over it, `prefer_user(root, "a.b")` lets the user
  file win, and `user("a.b")` reads the user file alone
- `dev.text`: `width`, `fit`, `words`, `wrap`, `trim`, `contains`
- `dev.term`: raw mode that is always restored, key decoding and `size`
- `dev.ui`: `context`, colors through `paint` and `mark`, `table`, `bar`,
  `confirm` and `spin`
- `dev.ui.picker`: the list picker, `run(ctx, items, opts)`
- `dev.project`: `root`, `dotfiles_root`, `share` and `detect_type`
- `dev.testing`, `dev.testrun` and `dev.testenv`: the test registry, the
  runner and the helpers (see "Testing a command")

## Your own modules

A directory `.dev/lua/` is on `package.path` as `.dev/lua/?.lua` while a Lua
command runs. `.dev/lua/myproj/checks.lua` therefore loads with
`require("myproj.checks")`.

dev never lists `lua` or `topics` as a command with subcommands.

## Headless rules

A command runs under CI, in a box and from agents, where no terminal is
attached.

- Take every answer from an argument. Ask only when `ui.context().interactive`
  is true (standard input and output are both terminals).
- `ui.confirm` and `ui.require_terminal` exit 2 with a message that names the
  flag to pass when `interactive` is false. `ui.picker.run` reads `/dev/tty`,
  so guard it the same way.
- Color is on only when the stream is a terminal, `NO_COLOR` is empty or unset
  and `TERM` is not `dumb`. Print plain text and let `dev.ui` decide.
- dev refuses to run any project script as root, and `dev.config` reads no file
  as root.
- A command that takes only `KEY=value` calls `dev_command.no_args(ctx)`
  first.

## Standalone shell

Some scripts run where dev does not exist: a production server, a test sandbox
or GitHub Actions. They stay shell and live in `.dev/standalone/`, a folder dev
never lists or runs.

Line 2 of each script reads `# standalone: runs on <where>, where dev is
absent`, and `<where>` is one of `production server`, `test sandbox` or
`GitHub Actions`. The list is `M.WHERE` in `dev/standalone.lua`, and widening it
is a dotfiles change.

`dev lint` fails on a `.sh` file anywhere else under `.dev` and on a
standalone script with a bad line 2. It names each file and exits 1.

The one exemption is a hidden helper named `.dev/__*.sh`. AGENTS.md sanctions
that path for a raw script a command needs, so the lint does not fail on it.

Adding a file under `.dev/standalone/` is a deliberate choice. `dev board land`
refuses the commit unless the card carries the `standalone-ok` label, and only
the owner adds it. `dev board label` refuses it for an agent, and an agent
files a `needs:human` card instead.

The check is `dev.standalone.land_problem(added, labels)`.

## Running somewhere else

`dev --remote <command>` runs the command's job from the project's pipeline
through `ci`. A project replaces that with `.dev/__remote.lua`, a chunk that
returns `function(run)`.

`dev help remote` has the fields of `run`, the refusals and the `dev.remote`
helper a runner can reuse.

## Testing a command

A project's Lua command tests live in `.dev/tests/NAME_test.lua`. Each file
requires `dev.testing` and registers cases with `t.test(name, fn)`, then
asserts with `t.eq`, `t.ok` and `t.raises`.

The project's `.dev/test.lua` ends with
`return require("dev.testrun").run(ctx.root)`, so `dev --remote test` runs
these files on ci. Cargo and the project's other suites never see them.

`run` loads the files in sorted order with `.dev/lua` on `package.path`. It
prints `ok - NAME` or `not ok - NAME` with the error, and returns 1 when a case
fails or a file fails to load.

A project with no `.dev/tests` prints `SKIP .dev/tests (none)` and returns 0.

`dev.testenv` helps a test drive a command:

- `tempdir()` makes a scratch directory
- `fake(root, name, {code, out, err})` writes an executable `root/bin/NAME`
  that prints `out` and `err`, appends its arguments to `root/bin/NAME.log` and
  exits `code`
- `calls(root, name)` returns the logged lines
- the launcher helper, called with `(root, words, opts)`, runs the dev
  launcher in `root` with `root/bin` first on PATH and `opts.env`, and returns
  `out, code, err`

## One command before and after

A command that lists targets, first in bash:

```bash
#!/usr/bin/env bash
# hidden
# Print the installable default targets.
set -eo pipefail

if [ "$#" -gt 0 ]; then
    case "$1" in
    -*) printf 'dev list: Unknown flag %s.\n' "$1" >&2 ;;
    *) printf 'dev list: Unknown argument %s. This command takes no positional arguments.\n' "$1" >&2 ;;
    esac
    exit 2
fi
for pkg in git nvim zsh; do
    printf '+ %s\n' "$pkg"
done
```

and the same command in Lua:

```lua
--[[
hidden
Print the installable default targets.
]]
local dev_command = require("dev.command")

local ctx = ...
dev_command.no_args(ctx)
for _, pkg in ipairs({ "git", "nvim", "zsh" }) do
    print("+ " .. pkg)
end
```

## The lint set commands

The dotfiles global `dev init` and `dev sync` write the Rust and Lua lint sets
as Lua commands: `.dev/lint.lua`, `.dev/fmt.lua` and, for Rust,
`.dev/test.lua`. The code they share is in `.dev/lua/lintset.lua`
(`require("lintset")`). A Rust project also gets the shared `stylua.toml`, and
its `fmt` and `lint` commands run stylua over the Lua under `.dev` and `.ci`
only, which `lint:dev_lua()` lists.

They write no `.sh` file. The templates live in the style skill's `lint/`
folder.

### Project checks

A project keeps its own checks in `.dev/lint.lua` below the
`-- --- project-specific checks below ---` line. Put them above the final
`return lint:finish()` line, which `dev sync` keeps at the end.

Inside the chunk, `lint` is the run:

- `lint:check(name, argv)`
- `lint:fail(name, message)`
- `lint:have(binary, install, name)`
- `lint:files(globs)`
- `lint:dev_lua()`
- `lint:grep(pattern, files)`

`ctx` is the command context and `lint.root` the project root.

### A project still on bash

A project still on bash is not forced over. While any of `.dev/lint.sh`,
`.dev/fmt.sh` or `.dev/test.sh` exists, `dev sync` writes no Lua command the
project lacks, not even one whose bash file is absent. It prints one
`pending:` line naming the bash files.

A Lua command the project already ported stays synced. A check-only `dev sync`
exits 0 for it.

To port the commands:

1. Run `dev sync` with its yes flag after moving the bash command out of the
   way, or copy the template from the style skill's `lint/<set>/` folder to
   `.dev/`, plus `lint/lintset.lua` to `.dev/lua/lintset.lua`.
2. Move the checks below the bash marker into Lua below the Lua marker.
3. Delete `.dev/lint.sh`, `.dev/fmt.sh`, `.dev/test.sh` and `.dev/lint-lib.sh`,
   and point the project's ci jobs at `dev lint` and `dev test`.

A leftover `.sh` file keeps the `pending:` line until it is deleted. Once the
Lua command exists, dev runs the `.lua` command (see "Which script runs"). The
global `dev init` follows the same rule and prints
`skipped: .dev/lint.sh exists, left on bash`.
