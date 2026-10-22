# boxes: Create, list, stop and delete dev boxes through ci box

`dev box` is a client for `ci box ... --json`. It needs `ci` and `jq` on PATH
and never talks to Incus, ssh-keys or Tailscale itself.

```
dev box ls
dev box create --profile large --ttl 8
dev box show myproject-k3x
dev box stop myproject-k3x
dev box resume myproject-k3x --keep
dev box extend myproject-k3x --ttl 2
dev box delete myproject-k3x -y
```

## Listing

`dev box ls` prints one row per box (name, state, profile, projects, time
left), then a cap line such as `2 of 3 running, 24 of 32 GiB`. Time left is
`3h12m left` or `kept` for a running box, `deleted in 6d` for a stopped one,
and empty for any other state. `--all` adds deleted boxes.

## Creating

`dev box create` blocks until the box runs. The profile is `medium` and the
lifetime is 4 hours unless you pass `--profile`, `--ttl HOURS` or `--keep`.
`--ttl` with `--keep` exits 2 before ci runs.

Inside a project with no `--project`, dev passes the project root's directory
name. `--project` repeats for several projects.

## Names and hosts

A box name is 1 to 40 of `a-z`, `0-9` and `-`, and any other name exits 2.
The host comes from the box's `tailnet_name`. A null `tailnet_name` prints as
`-`.

## Errors

When ci exits non-zero with an `{"ok":false}` document, dev prints
`dev box <sub>: <message>` to stderr and exits with ci's code (2 to 11).
Output that is not JSON passes through with ci's exit code, and progress lines
from ci reach the terminal as they come.

`dev box delete` asks on `/dev/tty` unless you pass `-y`, and exits 2 when
there is no terminal and no `-y`.

`dev --ci box` is refused, since boxes belong to this machine's ci.
