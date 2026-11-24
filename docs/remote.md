# remote: Run a command somewhere else, by default or with --remote

## Overview

A command that has a ci job runs remote by default. A forgotten flag never
spikes the laptop.

`dev test` and `dev --remote test` are the same, and `dev test --local` runs
here. A set `DEV_AGENT` refuses a local run of a command that has a ci job
(see "Agents").

`--remote` runs the command on a remote runner instead of this machine. It
works for every command.

`DEV_REMOTE=1` in the environment is the same as the flag. Empty means unset,
and `0`, `no` and `false` mean `--local`.

`--remote` and `--local` work anywhere before a `--`. Together they are a usage
error (exit 2).

`--local` sets `DEV_LOCAL=1` in the environment before any command runs, to
let a command tell that a local run was asked for. Without the flag dev leaves
`DEV_LOCAL` alone, so a value inherited from an outer dev run still shows.

dev strips `--remote` and `--detach`. The launcher has already entered the
directory of any `-C DIR`. dev then hands the runner the command words and the
arguments, untouched, spaces and quotes included. With no `--` every argument
after the command words goes to the job, so `dev --remote test NAME` and
`dev --remote test -- NAME` are the same run. Arguments on both sides of a `--`
are a usage error (exit 2), and the message prints the one command that works,
with every argument after the `--`.

The runner inherits the terminal, and its exit code is dev's.

The ci run starts on the ci target the user config names when the job names
none: `ci.rust_target` for a project with a `Cargo.toml` and `ci.target` for
any other. dev passes it as `CI_DEFAULT_TARGET`. With neither key set, or with
`CI_DEFAULT_TARGET` already in the environment, dev adds nothing and ci uses
its own default. A job that names its own target keeps it.

These runs show the shapes:

```
dev --remote test
dev --remote test -- tests/dev/testverb_test.sh
dev --remote --detach lint
```

### Test and lint rows

A checks row for `test` or `lint` reads `dev --remote test -- PATH`, and
`dev board checks` refuses the bare form.

The test job hands each word after the `--` to `dev test` as one quoted word.
`dev test PATH` runs only the suites at each path under `tests/`, and a path
that names no suite is a usage error. The test job runs the real root group
only for the root test files that a path selects.

## The remote default

The default is `[remote] default = "remote"` or `"local"`. It lives in
`~/.config/dev/config.toml` or the project's `.dev/config.toml`.

The user file wins over the project file, so a host chooses its own default.
With neither set the default is remote, and any other value exits 1. With
`"local"`, only `--remote` and `DEV_REMOTE` go to ci.

The default applies only to a command whose job `ci run --list --json` lists.
It never applies to a command that declares `remote: false` (see "What it
refuses") or as root, which reads no config.

A project with no `.ci/*.lua` pipeline file has no job, and ci is not asked. A
command the listing does not name runs here with no message, so `dev board ls`
is the same under either default.

The default passes every argument to the job, as an explicit `--remote` does.
A command with no job is not an error.

### Commands that stay local

A command whose spec sets `runs_local` (or whose header has a `# runs_local`
line) is never sent to ci by the
default. It suits a script that prepares something and then drives ci itself,
beside a job of the same name.

`--remote` still sends it. `dev help <command>` says the command runs here
under the default.

### Commands that fetch a built file

A command whose spec has `fetch`, or whose header has a `# fetch JOB FILE`
line, runs here, and under
the remote mode it first builds `FILE` on ci. `JOB` is a job of a pipeline in
`.ci/`, and `FILE` is the artifact that job keeps with `ci.artifact`. The
header is `# fetch client ci` for the job `client` that keeps `ci`.

The remote mode is the remote default (`[remote] default` is not `"local"`) or
`--remote`. In it dev reads `uname -sm`, takes the first target of the job
whose OS word matches this host (`macos-` for Darwin, `freebsd-`, `windows-`,
and any other target for Linux), and starts the job on that target at this
host's architecture, `aarch64` for `arm64` and `x86_64` for `amd64`. It waits
for the run with `ci ps RUN -w`, pulls the artifact `JOB.INDEX.TARGET/FILE`
with `ci cp`, and runs the command here with `DEV_FETCHED` set to the pulled
file's path in a new temporary directory.

`--local`, `DEV_REMOTE=0` and `[remote] default = "local"` run the command
here with no fetch and no `DEV_FETCHED`, so the command builds the file
itself. Inside a ci job or a dev box the command always runs here with no
fetch.

A host whose platform no target of the job matches, or whose job ci cannot
start for it, fails with exit 1. The message names the platform, such as
`Windows x86_64`, and says to pass `--local`. A run that does not pass fails
with its run id and the `ci logs` command that reads it. An agent's `DEV_AGENT`
label rides on every ci run the fetch starts, as for `--remote`.

### Commands that apply a patch from ci

A command whose spec has `patch`, or whose header has a `# patch JOB FILE`
line, never runs here
under the remote mode. It suits a command that rewrites files, such as a
formatter that must not run on the laptop. `JOB` is a job of a pipeline in
`.ci/`, and `FILE` is the patch that job keeps with `ci.artifact`.

In the remote mode dev starts `JOB` on the first target ci lists for it,
whatever its OS and with no `--arch`, waits with `ci ps RUN -w`, and pulls
`FILE` with `ci cp`. It lists the files the patch touches with
`git apply --numstat` and applies it with `git apply` at the project root,
never to the index. An empty patch prints `No file changed.` and exits 0.

A patch that does not apply changes no file, because `git apply` is all or
nothing. dev exits 1 and names the run id and the path where it kept the patch.
A patch that applied, or was empty, leaves no temporary file.
`--local`, `DEV_REMOTE=0` and `[remote] default = "local"` run the script here
with no ci call, and so does a ci job or a dev box.

### When ci cannot be asked

The default fails instead of running here, to keep a ci deploy from moving
every run onto the laptop. A missing `ci` on PATH, or a `ci run --list` that
exits non-zero, fails with ci's error and exit code and the hint
``Rerun it, or pass `--local` to run it here.``

Local is automatic only for `CI=true`, the box marker, `--local`,
`default = "local"` and `DEV_REMOTE=0`.

### Inside a job or a box

Inside a ci job (`CI=true`) or a dev box, dev always runs here, `--remote`
included. It is already the remote.

A dev box is marked by the file `/etc/ci-box`, which ci writes at box creation
(see "Dev boxes" in ci's README). `DEV_BOX_MARKER` names another marker path.
A box made before ci writes the file has no marker, so pass `--local` there.

An agent command policy denies a raw test or lint run on a machine without
the marker or `CI=true`. The denial names only `dev --remote test` or
`dev --remote lint`.

## The default runner

With no override, the runner is `ci`. A command runs the job of the same name
from the project's default pipeline (`.ci/jobs.lua`).

`dev <command> <sub>` runs the job `<command>-<sub>`, and one level deeper it
is `<command>-<sub>-<sub2>`, with a hyphen between every word. ci refuses a
dot in a job name. A word holding a dot or an underscore is no job, and ci is
not asked.

dev checks `ci run --list --json` first. A command with no such job exits 1 with
``No job named <job> exists in the project's default pipeline (.ci/jobs.lua).
Add one to run it with `--remote`.``, and nothing runs. It never falls back to a
local run.

A missing `ci` on PATH prints a warning with the install hint and exits 1.

The command it runs is:

```
ci -C <root> run --local --follow --job <job> -- <args>
```

## Agents

An agent sets `DEV_AGENT` to its name, `repo/role[/card]` as `dev board` takes
it (`dev help boards`), such as `dotfiles/implementer/f5f0e007`.

### The local refusal

Under `DEV_AGENT`, a run that would happen here for a command with a default
ci job is refused. It makes no difference what chose the laptop (`--local`,
`DEV_REMOTE=0` or `[remote] default = "local"`).

The refusal exits 2, prints a line that names the command and `--remote`, and
runs nothing. The default remote run and `--remote` still go to ci.

The refusal does not apply to a `runs_local` command, to a command that sets
`remote = false`, or inside a ci job or dev box (`CI=true` or the box
marker). An unset or empty `DEV_AGENT` changes nothing.

When ci cannot be asked, the refusal fails with ci's error and the hint
`An agent runs it on ci, so fix ci and rerun.`

### The primary checkout refusal

A `DEV_AGENT` whose role, the second part of its name, is `runner`,
`implementer`, `planner`, `reviewer` or `verifier` is a workspace role. Such an
agent is refused when a mutating command runs with its root in the
primary checkout, the folder a workspace or worktree belongs to.

The refused commands are the ones that declare `requires: workspace`, in the
spec or header, and the line of a command with subcommands
covers its subcommands. Every other command passes.

The lead role is refused only for `land`, `board land`, `abandon`, `clean`,
`purge` and `fmt`, the commands a lead never runs in the primary checkout. It
still runs `install`, `push`, `pull` and the rest there.

A repo adds commands to that refusal with `agent.primary_guarded` in its
`.dev/config.toml`, a list of command names or command phrases such as
`["bump", "board land"]`. A listed command is refused for any set `DEV_AGENT`,
the lead role included, with the same exit 2 and the same primary checkout
test. Its line says the repo's `agent.primary_guarded` lists it. A command the
list leaves out runs as before, and a value that is not a list of names ends
dev with exit 1.

The refusal exits 2, prints a line that names the command and `dev -C WS`, and
runs nothing. A workspace or worktree root passes, whether dev started there or
`-C` points at it. An unset or empty `DEV_AGENT` and a run inside a ci job or
dev box are not refused.

### The run label

A run dev starts on ci carries a `DEV_AGENT` label, which `ci ps -o run,by`
shows in the BY column. The one exception is a terminal run with no
`DEV_CI_COMMAND`.

A check run carries the check label even when DEV_AGENT is set. For any
other command a caller's non-empty `DEV_AGENT` is kept. Otherwise the label is
`<repo>/<command>`, or `<repo>/<command>/<card>` when `DEV_CI_CARD` is set.

The command is `DEV_CI_COMMAND` and defaults to `remote`.
The repo is `[board] name` or the project directory name.

`dev board check` sets both variables, so its runs read `<repo>/check/<card>`
whatever `DEV_AGENT` holds. `dev board land` requires `DEV_AGENT` and sets no
land command, so it never reads `<repo>/land/<card>`. Its recheck rows run as
check runs and carry the check label.

A repo's own release command exports `DEV_CI_COMMAND=release` and `DEV_CI_CARD`
before it calls `dev --remote`.

A `dev --remote` run from a terminal with no `DEV_CI_COMMAND`, and with `stdin`
attached to that terminal, carries no label at all. ci shows the person who
started it. The same run with `stdin` off a terminal stays `<repo>/remote`.

## Priority

The ci runner adds `--priority` to `ci run`, before the `--`, when
`dev --remote --priority test` is given or `DEV_CI_PRIORITY` is `1`. It
starts the run's jobs ahead of every normal job waiting for room on the
hub. `--priority` without `--remote` is a usage error.
`dev board land` sets it on the `[board.land] recheck` rows, and `dev board
ship` sets it on the `[board.release] checks` rows. `dev board check` and a
plain `dev --remote` run leave it unset, so they pass no `--priority`.

## Job timeout

To bound a remote run the way a `dev board check` row is, the ci runner adds
`--timeout DURATION` to `ci run`, before the `--`, when
`dev --remote --job-timeout 3600 test` is given. `--job-timeout` without
`--remote`, with no duration, or with a duration that starts with `-`, such as
`--`, is a usage error and runs nothing. A plain `dev --remote` run passes no
`--timeout`.

## --detach

`--detach` needs `--remote`, and alone it is a usage error. The ci runner then
passes `--detach` in place of `--follow`, and ci prints the run id and returns.

Read the run later with `ci ps <run> -w`, `ci logs <run>` or `ci ps <run>`.
`dev ci logs RUN [--job JOB]` runs `ci logs` for the run in the project root,
for an agent that may call `dev` only.

## Replacing the runner

A project replaces the runner with `.dev/helpers/remote.luau`, a helper that dev
never lists. It is
a chunk that returns a function:

```luau
return function(run)
    return 0
end
```

### The run table

`run` has these fields:

- `run.words`: the command words (`{"test"}`, or `{"box", "ls"}`)
- `run.args`: the arguments for the job
- `run.detach`: whether `--detach` was given
- `run.priority`: whether `--priority` was given
- `run.job_timeout`: the `--job-timeout` duration, or nil when it was not given
- `run.root`: the project root as an absolute path
- `run.verbose`: the level of `-v` (0, 1 or 2)

The returned integer is dev's exit code modulo 256, and nothing means 0. Any
other return value ends the run with `The file <path> returned <value>, not an
exit code.` and exit 1. A Lua error is printed as `<message>` with exit 1.

### Reusing the default runner

A runner can reuse the default one with
`require("dev.remote").ci_runner(run, opts)`. `opts.verbosity` is the `-v`
level. `opts.pipeline` names a pipeline under `.ci/`, so the job runs from
`.ci/<pipeline>.lua` instead of the default pipeline.

This repo's `.dev/helpers/remote.luau` sends `soak` to `.ci/soak.lua`
(`dev --remote soak`, the signal tests in a loop under CPU load) and
everything else to the default one.

## What it refuses

A command that sets `remote = false` in its spec, or with a
`# remote: false` header line, exits 2 with `dev <command>: runs on this
machine only, so --remote does not apply`, whatever the runner. The line of a
command with subcommands covers its subcommands.

A `remote = false` command whose spec has `patch` or whose header has a
`# patch JOB FILE` line runs its
job on ci and applies the patch here instead of exiting 2.
