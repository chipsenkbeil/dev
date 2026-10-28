# forge: How dev push and dev pull pick a remote and a command

`dev push` pushes the trunk bookmark (jj) or the current branch (git) to the
remote of record. `dev push origin` or `dev push gerrit` pushes to the one
remote named. A name is accepted when it is `origin` or `gerrit` and the
project has that remote, or when it is the remote of record. Any other name
exits 2. `dev help push` shows the exact commands for this repo.

```
dev push
dev push origin
dev help push
```

## The forge setting

The forge is `gerrit`, `github` or `plain`. dev takes the first of:

1. the `JJ_FORGE` environment variable.
2. `git config forge.kind` in the repo's own store.
3. detection: `gerrit` when a remote named gerrit exists, `github` when
   origin's URL names github.com, else `plain`.

The remote of record is `git config forge.remote`, else `gerrit` for a gerrit
forge, else `origin`. It must be a remote of the project, or push stops.
`dev push` prints the forge, the remote and why before it pushes.

## Backends

A repo with `.jj` uses jj, and a repo with only `.git` uses git. The jj push
is `jj git push --remote <remote> -b <trunk>`, where trunk is the `master` or
`main` bookmark. The git push goes through `commit-guard`, beside dev, which
checks commit messages for attribution, and refuses a detached HEAD.

## dev pull

On jj, `dev pull` runs `jj sync` when that alias exists. Otherwise it runs
`jj git fetch --all-remotes` and rebases onto `trunk()`. On git it runs
`git pull --rebase origin <branch>` and refuses a tree with uncommitted
changes.

## trunk()

The shared jj config redefines `trunk()` as jj's builtin with the `gerrit`
remote added: the newest of `main`, `master` or `trunk` on `gerrit`, `origin`
or `upstream`, else `root()`. A commit pushed to gerrit stays immutable before
the mirror reaches origin. A repo's own `trunk()` alias still wins.
`jj sync` only fast-forwards the local trunk bookmark to an origin bookmark on
the `trunk()` commit, so while gerrit is ahead of origin it rebases onto the
gerrit trunk and leaves the local bookmark where it is.
