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
goes through the push guard like any other git push, which can check the
tagged commit first. dev only sends tags and never creates or signs one.

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

## dev branch

`dev branch ls`, `dev branch archive REV` and `dev branch prune NAME` clean a
repo to one trunk without losing unlanded work. They run git on the project's
store (the git store under `.jj` on jj, the repo itself on git) and use the
remotes the project has.

The trunk is the remote of record's `master` or `main`, else the local one.
A branch is landed by content when every commit of `trunk..BRANCH` has its
`git patch-id --stable` among the patch-ids of the commits between the merge
base and the trunk. A squash or a rebase gives a landed commit a new hash but
the same patch-id, so only this comparison says what is on the trunk.

`dev branch ls` lists the local branches, the remote branches per remote from
the last fetch and, on jj, the non-empty heads no bookmark holds, each marked
`landed` or `unlanded`.

`dev branch archive REV` takes a branch, a bookmark, a jj change id or any
revision. It pushes the commit to `refs/archive/YYYY-MM-DD/NAME` on every
remote. `NAME` is the bookmark or branch name, else the change id (jj) or the
short commit id (git). It never uses `refs/tags`, which jj treats as immutable
heads that would freeze the archived commits. Then it reads each remote with
`git ls-remote` and exits 1 naming a remote that lacks the ref.

The flag --to NAME pushes to the one remote NAME and reads only that remote
back. A NAME the project has no remote for refuses before anything is pushed.

`dev branch prune NAME` deletes the local branch and the remote branches named
`NAME`. It refuses, deleting nothing, while any of them is neither landed by
content nor held by an archive ref of `NAME` on every remote, at that commit or
a descendant of it. It refuses the trunk. It reads a remote branch from the
last fetch, so fetch first.

Pushes go through the push guard and never carry a plus or `--force`, so a
remote that denies creating or deleting a ref, as Gerrit does without those
permissions, makes the command fail and say which remote refused.

```
dev branch ls
dev branch archive my-topic
dev branch archive my-topic --to gerrit
dev branch archive kkmpptxzrspx
dev branch prune my-topic
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
through the push guard. `dev push` refuses a detached HEAD on git.

## The push guard

Every push that dev makes with git runs through one program, `git push` by
default. `dev push` on a git repo, `dev push --tag`, `dev branch archive`,
`dev branch prune` and the push of `dev land` all use it.

To put a check in front of them, set `guard` in the `[push]` table of the user
file `~/.config/dev/config.toml` to a program name on PATH or a path. dev runs
it in place of git with the same arguments, `GUARD push -- REMOTE REFSPEC`
(with `--git-dir DIR` ahead of `push` on jj), so the guard is a wrapper that
ends up calling git. Only the user file sets it, so a checked-in project file
cannot choose a program for dev to run.

```
[push]
guard = "my-push-check"
```

When `guard` names a program that is not found or not executable, the push
refuses before it sends anything and the message names the setting. A guard
that exits non-zero stops the push, and dev reports that push as failed.

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
