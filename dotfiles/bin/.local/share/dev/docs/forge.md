# forge: How dev push and dev pull pick a remote and a command

`dev push` pushes the trunk bookmark (jj) or the current branch (git) to the
remote of record. `dev push origin` or `dev push gerrit` pushes to the one
remote named.

A name is accepted when it is `origin` or `gerrit` and the project has that
remote, or when it is the remote of record. Any other name exits 2.
`dev help push` shows the exact commands for this repo.

`dev push --tag NAME` pushes an existing tag instead of the trunk, and the flag
repeats for several tags. A tag named twice is pushed once. It goes to the
remote of record, or to the remote named.

Before anything is pushed, dev refuses a tag that does not exist locally
(`There is no local tag NAME. No tag was pushed.`) and a tag the remote
holds at another commit. It never forces, and it reports and skips a tag the
remote holds at the same commit.

A tag push needs no trunk bookmark or branch, so a detached HEAD is fine. It
goes through `commit-guard`, which checks the tagged commit for an attribution
line like any other push. dev only sends tags and never creates or signs one.

```
dev push
dev push origin
dev push --tag v1.2.0 --tag batch-7
dev help push
```

## dev abandon

`dev abandon CHANGE` abandons an open change on the project's Gerrit, for a
draft that was pushed and is no longer wanted. CHANGE is a change number or a
Change-Id. `--reason TEXT` sends TEXT as the abandon message.

It refuses a forge that is not gerrit with exit 1. It reads
`remote.<remote of record>.url`, which must be `ssh://[user@]host[:port]/project`,
and runs over `ssh -o BatchMode=yes -p PORT HOST`. Gerrit's `review` command
takes a revision and not a Change-Id, so dev first runs
`gerrit query --format=JSON --current-patch-set` for the change. A change that
is missing or not NEW exits 1 and sends no review call. Otherwise dev sends
`gerrit review --abandon [--message TEXT] REVISION` with the current patch
set's revision. It never restores a change.

```
dev abandon 101
dev abandon I8473b95934b5732ac55d26311a706c9c2bde9940
dev abandon I8473b95934b5732ac55d26311a706c9c2bde9940 --reason "superseded"
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

A repo with `.jj` uses jj, and a repo with only `.git` uses git.

On jj, `dev push` sends the trunk bookmark to the remote through jj's own
push, where trunk is the `master` or `main` bookmark. The git push goes
through `commit-guard`, beside dev, which checks commit messages for
attribution. `dev push` refuses a detached HEAD on git.

## dev pull

On jj, `dev pull` runs `jj sync` when that alias exists. Otherwise it runs
`jj git fetch --all-remotes` and rebases onto `trunk()`.

On git it runs `git pull --rebase origin <branch>`. It refuses a detached HEAD
and a tree with uncommitted changes.

## trunk()

The shared jj config redefines `trunk()` as jj's builtin with the `gerrit`
remote added: the newest of `main`, `master` or `trunk` on `gerrit`, `origin`
or `upstream`, else `root()`. A commit pushed to gerrit stays immutable before
the mirror reaches origin. A repo's own `trunk()` alias still wins.

`jj sync` only fast-forwards the local trunk bookmark to an origin bookmark on
the `trunk()` commit. While gerrit is ahead of origin, it rebases onto the
gerrit trunk and leaves the local bookmark where it is.

`jj sync` rebases the whole branch of the working copy onto `trunk()`. It
refuses first, naming the workspace, when another workspace's working copy
sits in the set that rebase would move, so move that workspace off the branch
or rebase the branch by hand first. A root already on `trunk()` moves nothing,
and a working copy off a trunk ancestor keeps its commit id.
