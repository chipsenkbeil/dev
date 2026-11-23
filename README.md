# dev

`dev` is one entry point for the daily work in a repository: lint, format,
test, push, land, and the board of cards the work comes from. A project adds
its own commands as scripts under `.dev/`, and `dev` runs them beside its
built-in commands. It is written in LuaJIT and works the same in a jj or a git
repository.

## Install

`dev` needs `bash` and `luajit` (the Lua 5.1 baseline), from
`brew install luajit`, `pacman -S luajit`, `dnf install luajit` or
`apt install luajit`. Until the first release, install from a clone:

```sh
git clone https://github.com/chipsenkbeil/dev ~/src/dev
cd ~/src/dev && bin/dev install
```

`dev install` links `~/.local/bin/dev` to the clone's launcher and
`~/.local/share/dev` to the clone, then publishes a snapshot of the clone
that the launcher runs. A pull reaches the running `dev` at the next
`dev install`.

## Getting help

Run `dev` with no arguments in a project to see the curated help, the
commands grouped by what they are for. `dev help -a` lists every command with
where it comes from and what it overrides, and a topic such as `remote` or
`boards` is a longer guide:

```sh
dev
dev help -a
dev help lint
dev help --topics
dev help remote
```

## Starting a project

`dev init` seeds a project with version control and a `.dev/config.toml`:

```sh
cd myproject
dev init --dry-run
dev init
```

## Commands

A command is a script. `dev lint` runs `.dev/lint.lua` or `.dev/lint.sh` at
the project root. A folder of scripts is a command with subcommands, so
`.dev/box/create.sh` runs as `dev box create`.

Commands come from three places, and the first match wins:

1. The project: `.dev/` at the project root.
2. Global: `~/.config/dev/commands/` (under `$XDG_CONFIG_HOME` when set), with
   the layout of `.dev/`, for commands every project shares.
3. Built-in: the commands that ship with `dev`.

`dev builtin:lint` and `dev global:lint` reach a command that a script
overrides. `dev help commands` has the details.

## Boards

`dev board` works the project's board of cards: take the next card, check
its outcomes, land it and move it on. `dev help boards` covers both backends.

[pomb](https://github.com/chipsenkbeil/pomb) is the server backend. `dev`
expects the server URL and a token reference in `[board.pomb]` of your user
config, `~/.config/dev/config.toml`, and `dev config` asks for both.

Without a Pomb server, `backend = "local"` keeps the board in one JSON file
under `~/.local/state/dev/boards/`, or in the repository with
`path = ".dev/board.json"`.

`.dev/config.toml` names the backend and the board:

```toml
[board]
backend = "pomb"
name = "myproject"
```

## Running on ci

`dev --remote test` runs the command on
[ci](https://github.com/chipsenkbeil/ci) instead of this machine. `dev`
expects the `ci` client on your `PATH` with a hub configured, and a pipeline
under `.ci/` with a job named after the command. `dev help remote` covers the
flags and the default.

A command with a ci job runs remote by default. Without ci, set the default to
local in `~/.config/dev/config.toml` and every command runs here:

```toml
[remote]
default = "local"
```

## License

`dev` is licensed under either of [Apache License, Version 2.0](LICENSE-APACHE)
or [MIT license](LICENSE-MIT), at your option.
