# overview: What dev is and where to start

dev is one entry point for every project. `dev <command>` runs the script
`.dev/<command>.lua` or `.dev/<command>.sh` at the project root, or a built-in
of the same name, so lint, test, build and push read the same everywhere.

## Look around

```
dev
dev help -a
dev help --topics
```

`dev` prints the curated help and `dev help -a` lists every command, hidden
ones included. `dev help <topic>` prints one topic, and the project's own
topics are the `.md` files in `.dev/topics/`.

## Check your work

```
dev lint
dev test
dev --remote test
```

`--remote` runs the command's job from `.ci/jobs.lua` on ci instead of here
(`dev help remote`).

## Send it

```
dev push
dev pull
dev follow
```

`dev help forge` says which remote `dev push` picks and why. `dev follow` moves
the main checkout onto trunk.

## Work on dev itself

The launcher in this checkout runs the snapshot that `dev install` publishes,
so a change here reaches the running dev only after that install.
`DEV_FROM=checkout dev ...` runs the checkout copy on purpose
(`dev help flags`). `dev help modules` holds the rules for each module.
