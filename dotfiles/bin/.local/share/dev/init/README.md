# dev in this repo

## Using dev

`dev <verb>` runs the verb `.dev/<verb>.lua` or `.dev/<verb>.sh` at the repo
root, or a built-in of the same name. Run `dev` for the curated help and
`dev help <verb>` for one verb.

`dev help -a` lists every command, hidden ones included, and marks a script
that replaces a built-in with `(override)`. `dev help --topics` lists the
topics and `dev help <topic>` prints one. The project's own topics are the
`.md` files in `.dev/topics/`.

`-h` after a verb prints its description, usage and flags. `--help` after a
verb prints the long form.

Seven global flags work before a `--` on every verb:

- `-v` or `--verbose`: print each command before it runs
- `-vv`: also trace every line of dev and of each bash script it runs
- `--remote`: run the verb's job from `.ci/jobs.lua` on ci
- `--local`: run here, whatever `[remote] default` says
- `--detach`: with `--remote`, start the job and return
- `--priority`: with `--remote`, start the job ahead of normal ci jobs
- `--job-timeout DURATION`: with `--remote`, give the ci run a time limit
- `-C DIR`: run as if dev started in `DIR`
- `--agent NAME`: export `DEV_AGENT=NAME` to the command

A command with a ci job runs remote by default. `DEV_REMOTE=0` or `--local`
runs it here, and `--local` with `--remote` is a usage error.

A script gets a flag only when its `flags:` header line declares it. Everything
after the first `--` reaches the script untouched.

## The dev modules

A Lua verb loads each module below with `require` by its dotted name. The
doc comments of the module hold every function.

### dev.verb

The helpers a verb needs: `usage_error(ctx, msg)` exits 2, `no_args(ctx)`
refuses any positional argument, `note(msg)` writes to standard error,
`die(msg)` exits 1, `show(ctx, argv)` prints `+ <argv>` at `-v`, and
`need(binary, install)` exits 1 when `binary` is not on `PATH`.

```lua
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
verb.need("rg", "brew install ripgrep")
verb.note("searching " .. ctx.root)
```

### dev.fs

File and path helpers: `exists`, `is_dir`, `is_file`, `is_link`, `is_exec`,
`read`, `write`, `mkdir`, `remove`, `list`, `stat`, `realpath`, `readlink`,
`mktemp`, `symlink`, `join`, `dirname` and `basename`. A call that can fail
returns nil and a message.

```lua
local fs = require("dev.fs")

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
local dev_os = require("dev.os")

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
local ui = require("dev.ui")

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
local text = require("dev.text")

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
local config = require("dev.config")

local mode = config.get(ctx.root, "remote.default")
print(mode or "unset")
```

### dev.project

`root()` finds the project root, `detect_type(root)` names the project's
language from the files in its root, `dotfiles_root()` finds the dotfiles
clone that holds dev, and `share` is dev's own share directory.

```lua
local project = require("dev.project")

local root = project.root()
print(root, project.detect_type(root) or "no type")
```

### dev.vcs

Picks the project's backend and lists what it holds. `backend(root)` returns
the jj or git backend, and `remotes(root, backend)` and
`branches(root, backend)` list names.

```lua
local vcs = require("dev.vcs")
local verb = require("dev.verb")

local backend, err = vcs.backend(ctx.root)
if not backend then
    return verb.die(err)
end
for _, name in ipairs(vcs.branches(ctx.root, backend)) do
    print(name)
end
```

### dev.templates

The lint set directory and its manifest. `set_for(kind)` names the set for a
project type, `dir(kind)` returns its directory, and `manifest(dir, kind)`
lists the files the set copies into a project.

```lua
local project = require("dev.project")
local templates = require("dev.templates")

local kind = project.detect_type(ctx.root)
local dir = kind and templates.dir(kind)
if dir then
    for _, entry in ipairs(templates.manifest(dir, kind)) do
        print(entry.dest)
    end
end
```

## Adding a verb, a subcommand or a flag in Lua

### A verb

`.dev/VERB.lua` is a verb. A `.lua` file needs no exec bit and wins over a
`.sh` file of the same name. dev loads the file and calls the chunk with one
argument, the context, which `local ctx = ...` reads.

- `ctx.name`: the command as typed
- `ctx.words`: the command words
- `ctx.root`: the project root, an absolute path
- `ctx.args`: the positional arguments, with each `KEY=value` word whose key
  starts with an uppercase letter removed, unless the header has a
  `positional` line
- `ctx.vars`: the `KEY=value` arguments whose key starts with an uppercase
  letter, by key, and empty under a `positional` line
- `ctx.after`: how many of `ctx.args` follow a `--`
- `ctx.dashed`: whether a `--` was typed
- `ctx.verbose`: 0, 1 or 2
- `ctx.interpreter`: the luajit dev runs under

The chunk returns the exit code as an integer, and nothing means 0. A Lua
error ends the run with `dev <name>: <message>` and exit 1.

The first header line that is not a `group:`, `hidden`, `local`, `positional`
or `flags:` line is the description in `dev help`. This verb runs as
`dev greet NAME=you`.

```lua
--[[
Print a greeting.
usage: greet [NAME=who]
]]
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
print("hello " .. (ctx.vars.NAME or "world"))
return 0
```

### A subcommand

`.dev/NOUN/SUB.lua` runs as `dev NOUN SUB`. A directory of scripts is a noun,
and the first line of `.dev/NOUN/DESCRIPTION` describes it.

A noun with no subcommand, or an unknown one, exits 2 and lists the
subcommands. Saved as `.dev/cache/show.lua`, this verb runs as
`dev cache show` and prints `cache show`.

```lua
--[[
Print the noun's state.
]]
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
print(ctx.name)
```

### A flag

A script gets a flag only when its header declares it. Before a `--`, any
other word that starts with `-` stops dev with exit 2, and `-h` and `--help`
stay reserved, so a `flags:` line cannot declare them.

```lua
--[[
Print a greeting.
usage: greet [--loud]
flags: --loud
]]
local verb = require("dev.verb")

local ctx = ...
local loud = false
for _, arg in ipairs(ctx.args) do
    if arg == "--loud" then
        loud = true
    else
        verb.usage_error(ctx, "unknown argument " .. arg)
    end
end
print(loud and "HELLO" or "hello")
```

### Group and hidden lines

`group: <name>` sets the heading `dev help` lists the verb under, and a verb
with none lands in a group named after the project directory. `hidden` keeps
the verb out of `dev help` and `dev help -a` still lists it. Scripts named
`__*.sh` or `__*.lua` never appear in any listing.

```lua
--[[
group: Check your work
hidden
Print the checks this repo runs.
]]
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
print("lint")
```

### Your own modules

`.dev/lua/` is on `package.path` while a Lua verb runs, so
`.dev/lua/myproj/checks.lua` loads with `require("myproj.checks")`. dev never
lists `lua` or `topics` as a noun.

## Commands in this repo

Replace this sentence with the project's own verbs and their flags.
