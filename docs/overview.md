# overview: What dev is and where to start

`dev` is one command for the work a repository needs: lint, test, format,
build, push, pull, land and the project's task board. A project adds its own
commands, help pages and settings under `.dev/`, and `dev` runs them beside
its built-ins.

## Look around

```
dev
dev help -a
dev help --topics
```

`dev` with no arguments prints the curated view, the commands grouped by
purpose. `dev help -a` adds the hidden ones, and `dev help --topics` lists the
help pages.

## Run a command

```
dev lint
dev test
dev --remote test
```

A command runs in the project that holds the working directory, or in the one
named by `-C DIR`. `--remote` sends a command with a ci job to the ci
machine (`dev help remote`).

## Add a command

Put `NAME.luau` or `NAME.sh` in `.dev/commands/` and `dev <name>` runs it.
`dev help commands` says how those files become commands, and
`dev help porting` covers moving a bash command to Luau.

## Send it

```
dev push
dev pull
dev follow
```

`dev help forge` says which remote `dev push` picks and why. `dev follow` moves
the main checkout onto trunk.

`dev help modules` and `dev help flags` hold the rules for each module and
global flag.
