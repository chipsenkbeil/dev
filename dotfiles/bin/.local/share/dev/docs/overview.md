# overview: What this repo is for and where to start

This repo holds a set of app configs. Each directory under `dotfiles/` is a
GNU Stow package whose files mirror `$HOME`, so `dotfiles/git/.gitconfig`
links to `~/.gitconfig`. `dev` is the only entry point for working on it.

## Look around

```
dev list
dev tools check
dev help --topics
```

`dev list` names the packages that install on this OS. `dev tools check`
reports which tools from `.dev/tools.tsv` are missing.

## Change a package

Edit the files under `dotfiles/<app>/`, then check the result:

```
dev lint
dev test
```

The live checkout is stowed into `$HOME`, so a change there is a change to the
running machine, except for dev itself, which runs from the snapshot that
`dev install bin` publishes. A landing changes dev only after that install, and
`DEV_FROM=checkout dev ...` runs the checkout copy on purpose
(`dev help flags`). Try an install in a temp tree instead:

```
dev install nvim TARGET_DIR=/tmp/home
```

## Send it

```
dev push
dev pull
dev follow
```

`dev help forge` says which remote `dev push` picks and why. `dev follow` moves
the main checkout onto trunk.

`dev help layout` and `dev help modules` hold the rules for each package and
module. `AGENTS.md` at the repo root maps every topic.
