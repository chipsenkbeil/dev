# porting: Port a .dev bash command to Luau

## Overview

A project command is a file in `.dev/commands/`. It can be bash
(`.dev/commands/<command>.sh`) or Luau (`.dev/commands/<command>.luau`).

dev runs both the same way from the user's side: the same `dev help` listing,
the same `-h`, the same flag check. A Luau command runs inside the dev
process, so it gets dev's modules and skips a process spawn.

## Formatting the Luau

A ported project sets `syntax = "Luau"` in its `stylua.toml`, as dev's own does.
stylua reads a `.luau` file as LuaJIT otherwise and rejects Luau types.

## Which file runs

When `<command>.luau` and `<command>.sh` both exist in one folder, the `.luau`
file wins. A `.luau` command needs no exec bit and a `.sh` command does. The
rule is the same for `<command>/<sub>.luau`. A file that ends in `.lua` is
refused, so name every command file `.luau`.

A `.sh` command is a separate process and cannot call Luau. dev's modules are
not on its path, so port the whole command or leave it in bash.

## The command contract

A `.luau` file returns a `dev.command` spec, and dev parses the words through
it before `run` starts. `dev help commands` has every field and the header
grammar of a `.sh` file. A command looks like this:

```luau
local dev_command = require("@dev/command")

return dev_command({
    summary = "Print the installable default targets",
    hidden = true,
    run = function(opts, args, ctx)
        return 0
    end,
})
```

`run(opts, args, ctx)` gets these.

- `opts`: the flags by name, with `-` as `_`.
- `args`: the arguments by name.
- `ctx.name`: the command as typed, a command and its subcommand joined by a
  space
- `ctx.words`: the command words
- `ctx.root`: the project root, an absolute path
- `ctx.argv`: the unparsed words after the command words
- `ctx.passthrough`: the words after a `--`, when the spec sets `passthrough`
- `ctx.vars`: the `KEY=value` arguments whose key starts with an uppercase
  letter, by key, and empty when the spec sets `positional`
- `ctx.verbose`: 0 to 4, after the `-v` flags and `VERBOSE`

### The exit code

`run` returns the exit code as an integer, and nothing means 0. dev takes the
code modulo 256.

Any other return value, a Luau error or a syntax error ends the run with
`dev <name>: <message>` and exit 1, with no traceback. To stop early with
another code, return it, or call `dev_os.exit`.

### The command helpers

`require("@dev/command")` holds the helpers a command needs:

- `dev_command.usage_error(ctx, msg)`: print `dev <name>: <msg>`, then the
  command's usage line drawn from its spec, on standard error and exit 2
- `dev_command.say(msg)`: write `msg` and a newline to standard output
- `dev_command.relay(text)`: write a captured `text` to standard output without
  its one trailing newline, and nothing for an empty text
- `dev_command.note(msg)`: write `msg` and a newline to standard error
- `dev_command.die(msg)`: print `msg` and exit 1
- `dev_command.show(ctx, argv)`: print `+ <argv>` on standard error when
  `ctx.verbose` is 1 or more
- `dev_command.need(binary, install)`: exit 1 with one warning when `binary` is
  not on `PATH`

An unknown flag or argument, a missing required argument and a flag without
its value are refused by the spec before `run`. The refusal replaces any
message and exit code the old command gave: one sentence, then the usage line
drawn from the spec, on standard error, exit 2. A command needs no check of
its own, and a test that pinned the old wording pins the spec's instead.

A golden file that pinned the old wording of a refusal is recaptured with the
real `dev` binary, never edited by hand. The change description states the
reason, that the spec's refusal replaced the old message and exit code.

### Passing words on to another tool

A command that hands its words to another tool, as `dev test` and `dev build`
hand them to cargo, has three spec fields to pick from:

- `rest = true` on a last `list` argument: every word from its first plain
  word on is taken verbatim, so a later word that starts with `-` stays text.
- `pass_unknown = true` with a trailing `list` argument: flags the spec does
  not declare go to that argument, and the declared flags still parse.
- `passthrough = true`: the words after a `--` reach `ctx.passthrough`.

```luau
return dev_command({
    summary = "Run the project's tests",
    args = { { name = "rest", list = true, rest = true } },
    pass_unknown = true,
    run = function(opts, args, ctx)
        local argv = { "cargo", "test" }
        for _, word in ipairs(args.rest or {}) do
            argv[#argv + 1] = word
        end
        return dev_os.run(argv)
    end,
})
```

The words reach cargo in the order typed, whether a flag comes before or after
the plain word.

### Finding the project from a .sh command

A `.sh` command gets `DEV_ROOT`, the absolute path of the project root, so
`"$DEV_ROOT/.dev/helpers/tool.sh"` finds a helper without a path relative to
`$0`. Every flag the header declares arrives as `DEV_FLAG_NAME`.

### Cleanup on exit

Register `dev.os.on_exit(fn)` where a bash command would write `trap fn EXIT`.
Each cleanup runs once, newest first, on a return, on an error and when
`SIGTERM`, `SIGHUP` or `SIGINT` ends the command, which then exits with 143,
129 or 130. dev passes the signal on to the child process it waits for, and
the command stops once that child returns. A `SIGINT` that another process sends
to dev's pid alone reaches that child too. The `dev.os` notes in the modules
reference say which children a signal reaches. `SIGKILL` runs no cleanup. A
`SIGINT` or `SIGHUP` that was ignored at start, as `nohup` leaves it, stays
ignored where dev can read that (Linux), and `SIGTERM` is always handled.

## Modules

Every module below is `require`d as `@dev/NAME`, such as
`require("@dev/os")`, and a nested one is `@dev/ui/picker`. The old dotted
form, `require("dev.os")`, is refused with a message that names the `@dev/`
form. `dev help modules` lists the native ones function by function.

- `@dev/os`: run and capture commands (`run`, `capture`, `capture_input`,
  `capture_timed`, `spawn`), `which`, `exec`, `getuid`, `isatty`, `quote`, and
  `on_exit(fn)` for a cleanup in place of a bash `trap` on `EXIT`
- `@dev/fs`: `exists`, `is_dir`, `is_file`, `is_link`, `is_exec`, `read`,
  `write`, `append`, `mkdir`, `remove`, `move`, `list`, `stat`, `realpath`,
  `readlink`, `mktemp`, `symlink`, `join`, `dirname`, `basename`
- `@dev/json`: `decode` and `encode`
- `@dev/toml`: `parse`, `set` and `encode`
- `@dev/config`: `get(root, "a.b")` reads `~/.config/dev/config.toml` and then
  `<root>/.dev/config.toml` over it, `prefer_user(root, "a.b")` lets the user
  file win, and `user("a.b")` reads the user file alone
- `@dev/text`: `width`, `fit`, `words`, `wrap`, `trim`, `contains`
- `@dev/term`: raw mode that is always restored, key decoding and `size`
- `@dev/ui`: `context`, colors through `paint` and `mark`, `table`, `bar`,
  `confirm` and `spin`
- `@dev/ui/picker`: the list picker, `run(ctx, items, opts)`
- `@dev/project`: `root` and `detect_type`
- `@dev/testing`, `@dev/testrun` and `@dev/testenv`: the test registry, the
  runner and the helpers (see "Testing a command")

## Your own modules

A Luau file loads another with the same require-by-string rule that
`luau-analyze` and editors follow, so they can follow the call too:

- `require("./x")` and `require("../x")` load `x.luau`, or `x/init.luau`,
  from the folder of the file that calls `require`. A file named `init.luau`
  counts as any other file here, so its `./x` is the `x` beside it, and dev
  does not read the `@self` alias.
- `require("@alias/x")` loads `x.luau` from the folder the alias names. dev
  reads the aliases of the nearest `.luaurc` that defines the alias, searching
  from the requiring file's folder upward. It never reads the `.luaurc` of the
  project dev started in, so a file copied into another tree loads from that
  tree.
- `require("@dev/NAME")` loads a dev module and needs no `.luaurc`.
- A dotted or bare name, such as `require("myproj.checks")`, is refused with a
  message that names the `./` or `@alias/` form to write.

A project that keeps modules under `.dev/lib/` needs this `.luaurc` at its
root, which `dev init` writes and merges into an existing file:

```json
{ "aliases": { "lib": ".dev/lib" } }
```

`.dev/lib/myproj/checks.luau` then loads with
`require("@lib/myproj/checks")`, from a command, a test or another library
file. A command in `~/.config/dev/commands` finds its own library through a
`.luaurc` in `~/.config/dev`. dev reads the file as plain JSON, so keep
comments out of it.

`runtime.add_path` is gone, and a `.luaurc` alias replaces it. A command
that called `runtime.add_path(root .. "/.dev/lib")` before a dotted
`require` now declares the folder once as the `lib` alias in `.luaurc`:

```lua
-- before
runtime.add_path(root .. "/.dev/lib")
local checks = require("myproj.checks")

-- after, with { "aliases": { "lib": ".dev/lib" } } in `.luaurc`
local checks = require("@lib/myproj/checks")
```

Scripts that a command calls but that are not commands live in
`.dev/helpers/`. dev never lists, completes or runs anything there as a
command. dev never lists `lib`, `helpers` or `help` as a command with
subcommands.

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
- dev refuses to run any project command as root, and `dev.config` reads no
  file as root.

## Standalone shell

Some scripts run where dev does not exist: a production server, a test sandbox
or GitHub Actions. They stay shell and live in `.dev/standalone/`, a folder dev
never lists or runs.

Line 2 of each script reads `# standalone: runs on <where>, where dev is
absent`, and `<where>` is one of `production server`, `test sandbox` or
`GitHub Actions`. The list is `M.WHERE` in `luau/dev/standalone.luau`, and
widening it is a dev change.

`dev lint` fails on a `.sh` file anywhere else under `.dev` outside
`commands/` and `helpers/`, and on a standalone script with a bad line 2. It
names each file and exits 1.

Adding a file under `.dev/standalone/` is a deliberate choice. `dev board land`
refuses the commit unless the card carries the `standalone-ok` label, and only
the owner adds it. `dev board label` refuses it for an agent, and an agent
files a `needs:human` card instead.

The check is `dev.standalone.land_problem(added, labels)`.

## Running somewhere else

`dev --remote <command>` runs the command's job from the project's pipeline
through `ci`. A project replaces that with `.dev/helpers/remote.luau`, a chunk
that returns `function(run)`. A command that must stay on this machine sets
`remote = false` in its spec.

`dev help remote` has the fields of `run`, the refusals and the `dev.remote`
helper a runner can reuse.

## Testing a command

A project's Luau command tests live in `.dev/tests/NAME_test.luau`. Each file
requires `@dev/testing` and registers cases with `t.test(name, fn)`, then
asserts with `t.eq`, `t.ok` and `t.raises`.

The project's `test` command ends with
`return require("@dev/testrun").run(ctx.root)`, so `dev --remote test` runs
these files on ci. Cargo and the project's other suites never see them.

`run` loads the files in sorted order. Each finds `.dev/lib` through the
project's `.luaurc`. It prints `ok - NAME` or `not ok - NAME` with the error,
and returns 1 when a case fails or a file fails to load.

A single file runs with `dev -l .dev/tests/NAME_test.luau`. `dev -l` runs the
file, which finds its modules by the rules above, then runs every
`@dev/testing` case the file registered. It
prints the same `ok` and `not ok` lines and exits 1 when a case fails. A file
that returns a non-zero number exits with it. This is also how a ci step runs
one named project test: the step's command is
`dev -l .dev/tests/NAME_test.luau`, and its exit code is the step's result.

Every word after the file belongs to the file, so `dev -l FILE a b` reaches it
in two places. The global `arg` holds the path at `arg[0]` and the words at
`arg[1]` and `arg[2]`. The chunk's varargs `...` hold the words alone, `a` and
`b`. A word that starts with `-` is passed on like any other.

A project with no `.dev/tests` prints `SKIP .dev/tests (none)` and returns 0.

`@dev/testenv` helps a test drive a command:

- `tempdir()` makes a scratch directory
- `fake(root, name, {code, out, err})` writes an executable `root/bin/NAME`
  that prints `out` and `err`, appends its arguments to `root/bin/NAME.log` and
  exits `code`
- `calls(root, name)` returns the logged lines
- `command(root, words, opts)` runs the dev binary in
  `root` with `root/bin` first on PATH and `opts.env`, and returns
  `out, code, err`

`dev.http` does the fetching, so a test cannot stub a download with a fake
`curl`. A `release:` pin or a `script:` source takes a `file://` url with an
absolute path (`file://` plus `root/mirror/tool.tar.gz`), which is copied
through the same sha256 check and unpacking as an https download. A test writes
the archive under its temp directory and points the pin at it.

### A golden-output harness

dev has no golden or snapshot helper, and `command` takes only `env` in its
`opts`, so it cannot set a working folder or feed standard input. A project that
compares a command's output with stored files keeps that harness as its own
library under `.dev/lib`, which a test loads with `require("@lib/...")`. The
harness runs the program through `@dev/os`:

- `capture(argv, opts)` returns `out, code`
- `capture_input(argv, input, opts)` adds standard input
- `capture_timed(argv, secs, opts)` adds a time limit

`opts` takes `cwd` and `env` there. The harness reads the stored file with
`dev.fs.read`, compares it with the output, and registers one `dev.testing`
case per golden file, so each file passes or fails on its own.

## One command before and after

A command that lists targets, first in bash:

```bash
#!/usr/bin/env bash
# hidden
# Print the installable default targets.
set -eo pipefail

for pkg in git nvim zsh; do
    printf '+ %s\n' "$pkg"
done
```

and the same command in Luau:

```luau
local dev_command = require("@dev/command")
local dev_os = require("@dev/os")

return dev_command({
    summary = "Print the installable default targets",
    hidden = true,
    run = function()
        for _, pkg in ipairs({ "git", "nvim", "zsh" }) do
            dev_os.stdout:write("+ ", pkg, "\n")
        end
        return 0
    end,
})
```

The spec refuses an argument or flag the command does not declare with exit 2,
as the bash command did by hand.
