# remote: Run a command somewhere else, by default or with --remote, and how to change where

A command that has a ci job runs remote by default, so a forgotten flag never
spikes the laptop. `dev test` and `dev --remote test` are the same, and
`dev test --local` runs here, unless `DEV_AGENT` is set (see Agents below).
Both flags work anywhere before a `--`, and together they are a usage error
(exit 2).

The default is `[remote] default = "remote"` or `"local"` in
`~/.config/dev/config.toml` or the project's `.dev/config.toml`. The user file
wins over the project file, so a host chooses its own default, and with neither
set the default is remote. Any other value exits 1. With `"local"`, only
`--remote` and `DEV_REMOTE` go to ci.

The default applies only to a command whose job `ci run --list --json`
lists, and never to a machine-local verb (below) or as root, which reads no
config.
A project with no `.ci/*.lua` pipeline file has no job and ci is not asked, and
a command the listing does not name runs here with no message, so
`dev board ls` is the same under either default.

Unlike an explicit `--remote`, the default passes every argument to the job,
before the `--` or after it, and a verb with no job is not an error.

A verb script whose header has a `# local` line is never sent to ci by the
default, for a script that prepares something and then drives ci itself beside
a job of the same name. `--remote` still sends it, and `dev help <verb>` says
the verb runs here under the default.

When ci cannot be asked, the default fails instead of running here, to keep a
ci deploy from moving every run onto the laptop. A missing `ci` on PATH, or a
`ci run --list` that exits non-zero, fails with ci's error and exit code and
the hint `rerun, or pass --local to run it here`. Local is automatic only for
`CI=true`, the box marker, `--local`, `default = "local"` and `DEV_REMOTE=0`.

Inside a ci job (`CI=true`) or a dev box (the file `/etc/ci-box`, which ci
writes at box creation, see "Dev boxes" in ci's README), dev always runs here,
`--remote` included, as it is already the remote. A box made before ci writes
the file has no marker, so pass `--local` there.

An agent command policy denies a raw test or lint run on a machine without
the marker or `CI=true`, and the denial names only `dev --remote test` or
`dev --remote lint`.

`--remote` runs the command on a remote runner instead of this machine. It works
anywhere before a `--`, for every verb: `dev test --remote` and
`dev --remote test` are the same. `DEV_REMOTE=1` in the environment is the same
as the flag, where empty means unset and `0`, `no` and `false` mean `--local`.

```
dev --remote test
dev --remote test -- parse
dev --remote --detach lint
```

dev strips `--remote` and `--detach` (the launcher has already entered the
directory of any `-C DIR`), then hands the runner the command words
and the arguments after `--`, untouched, spaces and quotes included. The runner
inherits the terminal, and its exit code is dev's. Any argument before the `--`
is a usage error. A checks row for `test` or `lint` therefore reads
`dev --remote test -- NAME`, and `dev board checks` refuses the bare form.

## The default runner

With no override, the runner is `ci`. A verb runs the job of the same name from
the project's default pipeline (`.ci/jobs.lua`), and `dev <noun> <sub>` runs the
job `<noun>.<sub>` (`<noun>.<sub>.<sub2>` one level deeper, a dot between
every word):

```
ci -C <root> run --local --follow --job <job> -- <args>
```

dev checks `ci run --list --json` first. A verb with no such job exits 1 with
`no job named <job> in the project's default pipeline (.ci/jobs.lua), add one to
run it with --remote`, and nothing runs. It never falls back to a local run.

## Agents

An agent sets `DEV_AGENT` to its name, `repo/role[/card]` as `dev board` takes
it (`dev help boards`), such as `dotfiles/implementer/f5f0e007`. Under it, a run that would
happen here for a verb with a default ci job is refused, whatever chose the
laptop (`--local`, `DEV_REMOTE=0`, or `[remote] default = "local"`). The
refusal exits 2, prints a line that names the verb and `--remote`, and runs
nothing. The default remote run and `--remote` still go to ci. The refusal does
not apply to a `# local` verb, to a machine-local verb, or inside a ci job or dev
box (`CI=true` or the box marker), and an unset or empty `DEV_AGENT` changes
nothing. When ci
cannot be asked, the refusal fails with ci's error and the hint
`an agent runs it on ci, so fix ci and rerun`.

A run dev starts on ci carries a `DEV_AGENT` label, which `ci ps -o run,by`
shows in the BY column, except a terminal run with no `DEV_CI_VERB` (below).
A caller's non-empty `DEV_AGENT` is kept. Otherwise the label is
`<repo>/<verb>`, or `<repo>/<verb>/<card>` when `DEV_CI_CARD` is set, where the
verb is `DEV_CI_VERB` and defaults to `remote`, and the repo is `[board] name` or
the project directory name. `dev board check` sets both variables, so with
`DEV_AGENT` unset its runs read `<repo>/check/<card>`. `dev board land` requires `DEV_AGENT`, so a run under
land keeps the caller's label and never reads `<repo>/land/<card>`. A
repo's own release verb exports `DEV_CI_VERB=release` and `DEV_CI_CARD` before it
calls `dev --remote`.

A `dev --remote` run from a terminal with no `DEV_CI_VERB`, and with `stdin`
attached to that terminal, carries no label at all, and ci shows the person
who started it. The same run with `stdin` off a terminal stays `<repo>/remote`.

## --detach

`--detach` needs `--remote` (alone it is a usage error). The ci runner then
passes `--detach` in place of `--follow`: ci prints the run id and returns. Read
the run later with `ci ps <run> -w`, `ci logs <run>` or `ci ps <run>`.

## Replacing the runner

A project replaces the runner with `.dev/__remote.lua`, a hidden helper. It is a chunk that returns a function:

```lua
return function(run)
    return 0
end
```

`run.words` holds the command words (`{"test"}`, or `{"box", "ls"}`),
`run.args` the arguments after `--`, `run.detach` whether `--detach` was given,
`run.root` the project root as an absolute path, and `run.verbose` the level of
`-v` (0, 1 or 2). The returned integer is
dev's exit code, and nothing means 0. A Lua error is printed as `dev: <message>`
with exit 1.

A runner can reuse the default one with
`require("dev.remote").ci_runner(run, opts)`. `opts.verbosity` is the `-v`
level and `opts.pipeline` names a pipeline under `.ci/`, so the job runs from
`.ci/<pipeline>.lua` instead of the default pipeline. This repo's
`.dev/__remote.lua` sends `bootstrap` to `.ci/bootstrap.lua` (`dev --remote
bootstrap`, the Arch bootstrap proof), `soak` to `.ci/soak.lua` (`dev --remote
soak`, the signal tests in a loop under CPU load) and everything else to the
default pipeline.

## What it refuses

Verbs that act on this machine exit 2 with `dev <verb>: runs on this machine
only, so --remote does not apply`, whatever the runner: install, uninstall,
restow, sync, setup, fmt, fetch, help, init, push, pull, guide, connect, and
every subcommand of tools, box, pi and antinote.
