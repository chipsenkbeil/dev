# remote: Run a command somewhere else, by default or with --remote, and how to change where

A command that has a ci job runs remote by default, so a forgotten flag never
spikes the laptop. `dev test` and `dev --remote test` are the same, and
`dev test --local` runs here. Both flags work anywhere before a `--`, and
together they are a usage error (exit 2).

The default is `[remote] default = "remote"` or `"local"` in
`~/.config/dev/config.toml` or the project's `.dev/config.toml`. The user file
wins over the project file, so a host chooses its own default, and with neither
set the default is remote. Any other value exits 1. With `"local"`, only
`--remote` and `DEV_REMOTE` go to ci.

The default applies only to a command whose job `ci jobs --json` lists, and
never to a machine-local verb (below) or as root, which reads no config. A
failed `ci jobs` counts as no job, and with no `ci` on PATH the default runs the
command here and prints `dev: ci is not on PATH, so this runs here` on stderr
(an explicit `--remote` without `ci` still fails). Such a command runs here with no message, so `dev board ls` is the same under either
default. Unlike an explicit `--remote`, the default passes every argument to
the job, before the `--` or after it, and a verb with no job is not an error.

Inside a ci job (`CI=true`) or a dev box (the file `/etc/ci-box`, which ci
writes at box creation, see "Dev boxes" in ci's README), dev always runs here, `--remote` included, as it is
already the remote. A box made before ci writes the file has no marker, but it has
no `ci` either, so the default falls back to a local run there.

`--remote` runs the command on a remote runner instead of this machine. It works
anywhere before a `--`, for every verb: `dev test --remote` and
`dev --remote test` are the same. `DEV_REMOTE=1` in the environment is the same
as the flag, where empty means unset and `0`, `no` and `false` mean `--local`.

```
dev --remote test
dev --remote test -- parse
dev --remote --detach lint
```

dev strips `--remote` and `--detach`, then hands the runner the command words
and the arguments after `--`, untouched, spaces and quotes included. The runner
inherits the terminal, and its exit code is dev's. Any argument before the `--`
is a usage error.

## The default runner

With no override, the runner is `ci`. A verb runs the job of the same name from
the project's default pipeline (`.ci/jobs.lua`), and `dev <noun> <sub>` runs the
job `<noun>.<sub>` (`<noun>.<sub>.<sub2>` one level deeper, a dot between
every word):

```
ci -C <root> run --local --follow --job <job> -- <args>
```

dev checks `ci jobs --json` first. A verb with no such job exits 1 with `no job
named <job> in the project's default pipeline (.ci/jobs.lua), add one to run it
with --remote`, and nothing runs. It never falls back to a local run.

## --detach

`--detach` needs `--remote` (alone it is a usage error). The ci runner then
passes `--detach` in place of `--follow`: ci prints the run id and returns. Read
the run later with `ci attach <id>`, `ci logs <id>` or `ci status <id>`.

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
bootstrap`, the Arch bootstrap proof) and everything else to the default
pipeline.

## What it refuses

Verbs that act on this machine exit 2 with `dev <verb>: runs on this machine
only, so --remote does not apply`, whatever the runner: install, uninstall,
restow, sync, setup, fmt, fetch, help, init, push, pull, guide, connect, and
every subcommand of tools, box, pi and antinote.
