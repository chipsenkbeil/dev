# boxes: Create, connect to, stop and delete dev boxes through ci box

`dev box` is a client for `ci box ... --json`. It needs `ci` and `jq` on PATH
and never talks to Incus, ssh-keys or Tailscale itself.

```
dev box ls
dev box create --profile large --ttl 8
dev box stop myproject-k3x
dev box resume myproject-k3x --keep
dev box extend myproject-k3x --ttl 2
dev box install-tools myproject-k3x --project myproject
dev box delete myproject-k3x -y
dev box delete myproject-k3x -y --no-archive
```

## Listing and creating

`dev box ls` prints one row per box (name, state, profile, projects, time
left), then a cap line such as `2 of 3 running, 24 of 32 GiB`. Time left is
`3h12m left` or `kept` for a running box and `deleted in 6d` for a stopped one.

`dev box create` blocks until the box runs. The profile is `medium` and the
lifetime is 4 hours unless you pass `--profile`, `--ttl HOURS` or `--keep`.
`--ttl` with `--keep` exits 2. Inside a project with no `--project`, dev passes
the project root's directory name.

A box name is 1 to 40 of `a-z`, `0-9` and `-`, else exit 2. A null
`tailnet_name` prints as `-`.

`dev box install-tools` reinstalls a running box's tools, for every project or
the ones `--project` names, and prints one line per project. A box that is
not running exits 6.

## Connecting

```
dev connect
dev connect myproject-k3x --ssh
```

`dev connect` and `dev box connect` are the same command. With no name it
lists the boxes, the current project's first, and you pick one. Inside a
project the last item, `new box for <project>`, creates a box and attaches. A
stopped box is resumed first. Any other state than running exits 6, as does a
box with no `tailnet_name` or no project path yet.

dev then runs `ci box show <box>`, which writes the box's host keys to ci's
known_hosts, and replaces itself with
`et -c "tmux new -A -s <session> -c <dir>" <ssh_user>@<tailnet_name>`, told
to trust only that file, so a box's host key is never accepted on first use.
The session is the first project's name or the box name, with `.` and `:`
turned into `_`. The directory is the first project's `path`, or
`/srv/projects` with no project, so a session never starts in `$HOME`. A path
outside `/srv/projects[/<name>]` exits 1. `--ssh`, or an `et` missing from
PATH (with one warning), runs `ci box ssh <box> -- tmux ...` with the same
tmux command, which checks the same host keys.

## Errors

When ci exits non-zero with an `{"ok":false}` document, dev prints
`dev box <sub>: <message>` to stderr and exits with ci's code (2 to 11).
Other output passes through. `dev box delete` asks on `/dev/tty` unless you
pass `-y`, and exits 2 with no terminal. `dev --ci` refuses `box` and `connect`.

`dev box delete --no-archive` deletes the box without archiving its projects,
so anything not pushed is lost, and its question says so.
