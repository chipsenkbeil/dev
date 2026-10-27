# flags: The global flags -v, -vv, --remote and --detach, and how help flags work

Four flags work anywhere before a `--` on the line, whatever the verb.

- `-v` or `--verbose`: print each command before it runs, and export
  `VERBOSE=1` to it.
- `-vv`: also trace every line of dev and of each bash script it runs, which
  exports `VERBOSE=2`.
- `--remote`: run the command on a remote runner, by default the verb's job of
  the same name from the project's default pipeline (`.ci/jobs.lua`) on
  example-box through ci. `DEV_REMOTE=1` in the environment is the same.
- `--detach`: with `--remote`, start the job and return. Alone it is a usage
  error.

`-v` and `-vv` also stack as `-vvv` (the count is capped at 2). Setting
`VERBOSE` in the environment counts the same, where empty, `no` and `false`
mean off and any other word means 1.

```
dev -v lint
dev -vv test
dev --remote test
```

`dev help remote` explains the runner, the refusals and how a project replaces
it.

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

## Flags a script declares

A project script gets a flag only when its `# flags:` line declares it. Before
a `--`, a word that starts with `-` (and is not the lone word `-`) must be a
global flag, `-h` or `--help`, or listed on the line. Anything else stops dev
before the script runs, with exit 2 and:

```
dev <verb>: unknown flag <flag>; pass it after -- to reach the script, or add it to the script's # flags: line
```

`<verb>` is the command words, a noun and its subcommand included.
`--name=value` is checked as `--name`, a declared flag's separate value
(`--days 7`) is a plain word, and words that do not start with `-` are never
refused. A value that starts with `-` is checked as a flag, so write it as
`--days=-1`.

Everything after the first `--` reaches the script untouched, so flags meant
for another tool go there: `dev test -- <args>` runs the test suites with
`<args>`.

Built-in verbs check their own flags. With `--remote`, any argument before the
`--` is refused, as the `remote` topic describes.
