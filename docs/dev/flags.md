# flags: The global flags -v, -vv and --ci, and how help flags work

Three flags work anywhere before a `--` on the line, whatever the verb.

- `-v` or `--verbose`: print each command before it runs, and export
  `VERBOSE=1` to it.
- `-vv`: also trace every line of dev and of each bash script it runs, which
  exports `VERBOSE=2`.
- `--ci`: run the verb's job of the same name from the project's default
  pipeline (`.ci/jobs.lua`) on example-box, through
  `ci run --local --job <verb> -f`.

`-v` and `-vv` also stack as `-vvv` (the count is capped at 2). Setting
`VERBOSE` in the environment counts the same, where empty, `no` and `false`
mean off and any other word means 1.

```
dev -v lint
dev -vv test
dev --ci test
```

## --ci

`--ci` exits with the job's status and never falls back to a local run. It
refuses a verb with no job of that name and any extra argument. It also
refuses the machine-local verbs install, uninstall, restow, sync, setup, fmt,
fetch, help, init, push and pull, and the nouns tools, cargo, pi and antinote. A
subcommand `dev --ci <noun> <sub>` runs the job named `<noun>-<sub>`.
`DEV_CI=1` in the environment is the same as the flag.

## Help flags

`-h` and `--help` are reserved for help on every verb, but only before a
`--`. A script never sees them there, and so cannot declare them in its
`# flags:` line (`dev __check-topics` reports one that does). Everything
after a `--` reaches the verb verbatim, so `dev run -- -h` runs
`cargo run -- -h`.

- `-h` after a verb prints its description, usage and flags.
- `--help` after a verb prints the long form, the same as `dev help <verb>`.
- `dev help -a` lists every command, hidden ones included.
- `dev help --topics` lists the topics, and `dev help -k <topic>` prints one.

Color is on only when the output is a terminal and `NO_COLOR` is unset.
