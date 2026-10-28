# porting: Port a .dev bash verb to Lua

A project verb is a script in `.dev/`. It can be bash (`.dev/<verb>.sh`) or Lua
(`.dev/<verb>.lua`), and dev runs both the same way from the user's side: the
same `dev help` listing, the same `-h`, the same flag check. A Lua verb runs
inside the dev process, so it gets dev's modules and skips a process spawn.

## Which script runs

When `.dev/<verb>.lua` and `.dev/<verb>.sh` both exist, the `.lua` file wins.
A `.lua` verb needs no exec bit and a `.sh` verb does. The rule is the same for
`.dev/<noun>/<sub>.lua`.

A `.sh` verb is a separate process and cannot call Lua: dev's modules are not
on its path. Port the whole verb, or leave it in bash.

## The verb contract

dev loads the file with `load` and calls the chunk with one argument, the
context. Read it with `local ctx = ...`.

- `ctx.name`: the command as typed, a noun and its subcommand joined by a space
- `ctx.words`: the command words
- `ctx.root`: the project root, an absolute path
- `ctx.args`: the positional arguments, with every `KEY=value` word removed
- `ctx.vars`: the `KEY=value` arguments whose key starts with an uppercase
  letter, by key
- `ctx.verbose`: 0, 1 or 2, after `-v`, `-vv` and `VERBOSE`
- `ctx.interpreter`: the luajit dev runs under, as the launcher started it

The chunk returns the exit code as an integer, and nothing means 0. Dev takes
the code modulo 256. Any other return value, a Lua error or a syntax error ends
the run with `dev <name>: <message>` and exit 1, with no traceback. To stop
early with another code, return it, or call `os.exit`.

`require("dev.verb")` holds the helpers a verb needs:

- `verb.usage_error(ctx, msg)`: print `dev <name>: <msg>` and exit 2
- `verb.no_args(ctx)`: refuse any positional argument, as a verb that takes only
  `KEY=value` does
- `verb.die(msg)`: print `msg` and exit 1
- `verb.show(ctx, argv)`: print `+ <argv>` on standard error when `ctx.verbose`
  is 1 or more
- `verb.need(binary, install)`: exit 1 with one warning when `binary` is not on
  `PATH`

## Header lines

A Lua verb keeps the header lines of a shell script in one leading block
comment. The block starts with `--[[` alone on the first line and ends with
`]]` alone on its own line. The first line inside it that is not a `group:`,
`hidden` or `flags:` line is the description.

- `group: <name>`: the heading `dev help` lists the verb under
- `hidden`: keep the verb out of `dev help`, so only `dev help -a` lists it
- `flags: --a --b`: the flags `dev help <verb>` and completion offer, and the
  only flags dev lets through to the script before a `--`

`dev help nouns` and `dev help flags` have the rules. `-h` and `--help` stay
reserved, so a `flags:` line cannot declare them.

## Modules

Every module below is `require`d by its dotted name and documents its
functions in its doc comments.

- `dev.os`: run and capture commands (`run`, `capture`, `capture_input`,
  `capture_timed`), `which`, `exec`, `getuid`, `isatty`, `quote`
- `dev.fs`: `exists`, `is_dir`, `is_file`, `is_exec`, `read`, `write`, `mkdir`,
  `remove`, `list`, `stat`, `realpath`, `mktemp`, `symlink`, `join`, `dirname`,
  `basename`
- `dev.json`: `decode` and `encode`
- `dev.toml`: `parse`
- `dev.config`: `get(root, "a.b")` reads `~/.config/dev/config.toml` and then
  `<root>/.dev/config.toml` over it, and `user("a.b")` reads the user file
  alone
- `dev.text`: `width`, `fit`, `trim`, `contains`
- `dev.term`: raw mode that is always restored, key decoding and `size`
- `dev.ui`: `context`, colors through `paint` and `mark`, `table`, `bar`,
  `confirm` and `spin`
- `dev.ui.picker`: the list picker, `run(ctx, items, opts)`
- `dev.project`: `root`, `dotfiles_root` and `detect_type`

## Your own modules

A directory `.dev/lua/` is on `package.path` as `.dev/lua/?.lua` while a Lua
verb runs, so `.dev/lua/myproj/checks.lua` loads with
`require("myproj.checks")`. dev never lists `lua` or `topics` as a noun.

## Headless rules

A verb runs under CI, in a box and from agents, where no terminal is attached.

- Take every answer from an argument. Ask only when `ui.context().interactive`
  is true (standard input and output are both terminals).
- `ui.confirm` and `ui.require_terminal` exit 2 with a message that names the
  flag to pass when `interactive` is false. `ui.picker.run` reads `/dev/tty`,
  so guard it the same way.
- Color is on only when the stream is a terminal, `NO_COLOR` is empty or unset
  and `TERM` is not `dumb`. Print plain text and let `dev.ui` decide.
- dev refuses to run any project script as root, and `dev.config` reads no file
  as root.
- A verb that takes only `KEY=value` calls `verb.no_args(ctx)` first.

## Running somewhere else

`dev --remote <verb>` runs the verb's job from the project's pipeline through
`ci`. A project replaces that with `.dev/__remote.lua`, a chunk that returns
`function(run)`. `dev help remote` has the fields of `run`, the refusals and
the `dev.remote` helper a runner can reuse.

## One verb before and after

A verb that lists targets, first in bash:

```bash
#!/usr/bin/env bash
# hidden
# Print the installable default targets.
set -eo pipefail

if [ "$#" -gt 0 ]; then
    case "$1" in
    -*) printf 'dev list: unknown flag %s\n' "$1" >&2 ;;
    *) printf 'dev list: unknown argument %s, list takes only KEY=value arguments\n' "$1" >&2 ;;
    esac
    exit 2
fi
for pkg in git nvim zsh; do
    printf '+ %s\n' "$pkg"
done
```

and the same verb in Lua:

```lua
--[[
hidden
Print the installable default targets.
]]
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
for _, pkg in ipairs({ "git", "nvim", "zsh" }) do
    print("+ " .. pkg)
end
```
