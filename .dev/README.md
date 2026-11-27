# dev in this repo

## Using dev

`dev <command>` runs the script `.dev/commands/<command>.luau` or
`.dev/commands/<command>.sh` at the repo root, or a built-in of the same
name. Run `dev` for the curated help and `dev help <command>` for one
command.

`dev help -a` lists every command, hidden ones included, and marks a script
that replaces a built-in with `(override)`. `dev help --topics` lists the
topics and `dev help <topic>` prints one. The project's own topics are the
`.md` files in `.dev/help/`.

`-h` after a command prints its description, usage and flags. `--help` after a
command prints the long form.

Global flags work before the command word on every command, and `-v` and `-q`
also work after it:

- `-v` or `--verbose`: print each command before it runs
- `-vv`: also log every spawn with its folder, exit code and time
- `-vvv`: also trace every native `dev.*` call, and run each `.sh` command
  under `bash -x`
- `-vvvv`: also trace calls between dev's Luau modules
- `-q` or `--quiet`: show errors only
- `--remote`: run the command's job from `.ci/jobs.lua` on ci
- `--local`: run here, whatever `[remote] default` says
- `--detach`: with `--remote`, start the job and return
- `--priority`: with `--remote`, start the job ahead of normal ci jobs
- `--job-timeout DURATION`: with `--remote`, give the ci run a time limit
- `-C DIR`: run as if dev started in `DIR`
- `--agent NAME`: export `DEV_AGENT=NAME` to the command

A command with a ci job runs remote by default. `DEV_REMOTE=0` or `--local`
runs it here, and `--local` with `--remote` is a usage error.

Past the first command word, every other word belongs to the command. A
command gets a flag only when its spec declares it (or, in a `.sh` file, a
`# flag:` header line). Words after the first `--` are plain arguments, unless
the spec sets `passthrough`, and then they reach the command untouched.

## The dev modules

A Lua command loads each module below with `require("@dev/NAME")`. The
doc comments of the module hold every function.

### dev.command

The spec constructor and the helpers a command needs: `usage_error(ctx, msg)`
exits 2, `say(msg)` writes to standard output, `note(msg)` writes to standard
error, `die(msg)` exits 1, `show(ctx, argv)` prints `+ <argv>` at `-v`, and
`need(binary, install)` exits 1 when `binary` is not on `PATH`.

```lua
local dev_command = require("@dev/command")

return dev_command({
    summary = "Search the project",
    run = function(_opts, _args, ctx)
        dev_command.need("rg", "brew install ripgrep")
        dev_command.note("searching " .. ctx.root)
        return 0
    end,
})
```

### dev.fs

File and path helpers: `exists`, `is_dir`, `is_file`, `is_link`, `is_exec`,
`read`, `write`, `mkdir`, `remove`, `list`, `stat`, `realpath`, `readlink`,
`mktemp`, `symlink`, `join`, `dirname` and `basename`. A call that can fail
returns nil and a message.

```lua
local fs = require("@dev/fs")

local path = fs.join(ctx.root, ".dev", "config.toml")
if fs.is_file(path) then
    local text, err = fs.read(path)
    print(text or err)
end
```

### dev.os

Run and capture commands with `run`, `capture`, `capture_input` and
`capture_timed`, and find a program with `which`. `exec`, `getuid`, `isatty`
and `quote` live here too.

```lua
local dev_os = require("@dev/os")

local out, code = dev_os.capture({ "git", "-C", ctx.root, "status", "--short" })
if code == 0 and out ~= "" then
    print(out)
end
```

### dev.ui

Terminal drawing: `context`, colors through `paint` and `mark`, `table`, `bar`,
`confirm` and `spin`. Color is on only when the stream is a terminal,
`NO_COLOR` is empty or unset and `TERM` is not `dumb`.

```lua
local ui = require("@dev/ui")

local view = ui.context()
local rows = { { "lint", "ok" }, { "test", "ok" } }
for _, line in ipairs(ui.table(view, { "job", "state" }, rows)) do
    print(line)
end
```

### dev.text

Display-width text helpers: `width`, `fit`, `words`, `wrap`, `trim` and
`contains`. `wrap` fills lines from a word list and leaves a word wider than
the width on a line of its own.

```lua
local text = require("@dev/text")

local lines = text.wrap(text.words("one two three four"), 10)
for _, line in ipairs(lines) do
    print(text.fit(line, 8))
end
```

### dev.config

Reads `~/.config/dev/config.toml` and then `<root>/.dev/config.toml` over it.
`get(root, "a.b")` reads a dotted key, `prefer_user(root, "a.b")` lets the
user file win, and `user("a.b")` reads the user file alone.

```lua
local config = require("@dev/config")

local mode = config.get(ctx.root, "remote.default")
print(mode or "unset")
```

### dev.project

`root()` finds the project root, `detect_type(root)` names the project's
language from the files in its root, and `share` is dev's own share directory.

```lua
local project = require("@dev/project")

local root = project.root()
print(root, project.detect_type(root) or "no type")
```

### dev.vcs

Picks the project's backend and lists what it holds. `backend(root)` returns
the jj or git backend, and `remotes(root, backend)` and
`branches(root, backend)` list names.

```lua
local vcs = require("@dev/vcs")
local dev_command = require("@dev/command")

local backend, err = vcs.backend(ctx.root)
if not backend then
    return dev_command.die(err)
end
for _, name in ipairs(vcs.branches(ctx.root, backend)) do
    print(name)
end
```

## Adding a command, a subcommand or a flag in Lua

### A command

`.dev/commands/NAME.luau` is a command. A `.luau` file needs no exec bit and
wins over a `.sh` file of the same name. The file returns the table that
`require("@dev/command")` validates, called a spec, and its `run(opts, args,
ctx)` gets the parsed flags, the parsed arguments and the context.

- `ctx.name`: the command as typed
- `ctx.words`: the command words
- `ctx.root`: the project root, an absolute path
- `ctx.argv`: the unparsed words after the command words
- `ctx.passthrough`: the words after a `--`, when the spec sets `passthrough`
- `ctx.vars`: the `KEY=value` arguments whose key starts with an uppercase
  letter, by key, and empty when the spec sets `positional`
- `ctx.verbose`: 0 to 4

`run` returns the exit code as an integer, and nothing means 0. A Lua error
ends the run with `dev <name>: <message>` and exit 1. `summary` is the line
`dev help` shows. This command runs as `dev greet NAME=you`.

```lua
local dev_command = require("@dev/command")

return dev_command({
    summary = "Print a greeting",
    run = function(_opts, _args, ctx)
        dev_command.say("hello " .. (ctx.vars.NAME or "world"))
        return 0
    end,
})
```

### A subcommand

`.dev/commands/CMD/SUB.luau` runs as `dev CMD SUB`. A directory of scripts
is a command with subcommands, and the first line of
`.dev/commands/CMD/DESCRIPTION` describes it.

Such a command with no subcommand, or an unknown one, exits 2 and lists the
subcommands. Saved as `.dev/commands/cache/show.luau`, this subcommand runs as
`dev cache show` and prints `cache show`.

```lua
local dev_command = require("@dev/command")

return dev_command({
    summary = "Print the command's state",
    run = function(_opts, _args, ctx)
        dev_command.say(ctx.name)
        return 0
    end,
})
```

### A flag

A command gets a flag only when its spec declares it in `flags`. Each flag has
a `name`, a `kind` of `string`, `number` or `boolean`, and optional `short`,
`default`, `choices`, `repeatable`, `required`, `hidden` and `help` fields. Any
other word that starts with `-` stops dev with exit 2, and `-h` and `--help`
stay reserved, so a spec cannot declare them. `opts` holds each flag by name
with `-` as `_`. A `.sh` or `.ps1` command declares each flag on a `# flag:`
header line under the shebang, as in
`# flag: loud kind=boolean -- Shout the greeting`. The old `# flags:` and
`# local` lines fail at load, and `dev help commands` has the header grammar.

```lua
local dev_command = require("@dev/command")

return dev_command({
    summary = "Print a greeting",
    flags = {
        { name = "loud", kind = "boolean", help = "Shout the greeting" },
    },
    run = function(opts, _args, _ctx)
        dev_command.say(opts.loud and "HELLO" or "hello")
        return 0
    end,
})
```

### Group and hidden fields

`group` sets the heading `dev help` lists the command under, and a command with
none lands in a group named after the project directory. `hidden = true` keeps
the command out of `dev help` and `dev help -a` still lists it. Scripts in
`helpers/` never appear in any listing.

```lua
local dev_command = require("@dev/command")

return dev_command({
    summary = "Print the checks this repo runs",
    group = "Check your work",
    hidden = true,
    run = function(_opts, _args, _ctx)
        dev_command.say("lint")
        return 0
    end,
})
```

### Your own modules

The `lib` alias of the project's `.luaurc` names `.dev/lib/`, so
`.dev/lib/myproj/checks.luau` loads with `require("@lib/myproj/checks")`. dev
never lists `lib`, `helpers` or `help` as a command.

## Commands in this repo

These are the project commands in `.dev/`. Each lists the flags and
`KEY=value` arguments it declares.

### Check your work

- `dev lint`: run the shell, bats and Lua checks over the repo. No flags.
- `dev fmt`: format the Lua roots with stylua. No flags.
- `dev test [PATH...]`: run every suite under `tests/`, or only the suites at
  each `PATH`. Arguments after `--` reach the suites. `DEV_TEST_JOBS` sets the
  parallel suite count.
- `dev --remote soak [-- --runs N]`: run the signal tests in a loop beside CPU
  burners, on a ci host only. Flag: `--runs` (default 50).

### Release

The workflow in `.github/workflows/release.yml` runs these on a pushed `v*`
tag. Push the tag with `dev push --tag TAG`.

- `dev release build TARGET [--tag TAG] [--zigbuild]`: run `cargo build
  --release --locked --target TARGET` with `DEV_RELEASE_TAG` set to TAG, and
  print the binary's path. Flags: `--tag`, `--zigbuild`.
- `dev release test BINARY [--tag TAG]`: run `BINARY --version`, which must
  print `dev TAG`, then the native suite on BINARY. Flag: `--tag`.
- `dev release publish TAG [--dir DIR]`: write `SHA256SUMS` over the
  `dev-TAG-TRIPLE` binaries under DIR, then create the GitHub release for TAG
  or upload to it, as a pre-release when TAG holds `-pre.`. It refuses to
  overwrite an asset. Flag: `--dir` (default `artifacts`).
- `dev release dispatch [--timeout SECONDS] [--interval SECONDS] [--lines N]
  [--keep]`: push the current change to a `review-` branch on origin, start
  the workflow on it, wait, and print each job's result with the end of each
  failed job's log, then delete the branch. Exits 1 when any job did not pass.
  Flags: `--timeout` (default 3600), `--interval` (default 20), `--lines`
  (default 40), `--keep` (leave the branch).
