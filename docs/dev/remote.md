# remote: Run a command somewhere else with --remote, and how to change where

`--remote` runs the command on a remote runner instead of this machine. It works
anywhere before a `--`, for every verb: `dev test --remote` and
`dev --remote test` are the same. `DEV_REMOTE=1` in the environment is the same
as the flag, where empty, `0`, `no` and `false` mean off.

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
