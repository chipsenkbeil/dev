# Contributing to dev

This file covers the commands that check dev's own repo. They are project
commands in `.dev/commands/`, and they replace the built-in `lint`, `fmt` and
`test` here. Another project gets the built-ins, which `docs/commands.md`
describes under "The built-in project commands".

## Tests and checks

Luau tests are `tests/lua/*_test.luau`. The runner runs one file at a time:
`dev -l tests/lua/run.luau <file> [name]`, where a name keeps the cases whose
name contains it, and `dev -l FILE` runs any Luau file with the embedded
modules and `arg` set (the Rust integration tests in `tests/native/` use it).
The pty suites are `tests/dev/{term,picker,confirm}.bats`, which drive a pty
through `tests/dev/pty.bash`.

`dev test` runs them and prints `SKIP` for a suite that ran no case.

This repo's own `dev lint`, `dev fmt` and `dev test` are
`.dev/commands/lint.luau`, `fmt.luau` and `test.luau`. The shared code is in
`.dev/lib/devrepo/checks.luau`, and project commands get `.dev/lib` on the
`require` path.

### dev lint and dev fmt

`dev lint` runs these checks:

- `cargo +nightly fmt --check` and `cargo clippy --all-targets -- -D
  warnings`, when `Cargo.toml` exists
- shellcheck, shfmt and the comment-spacing check over the bash roots
- the bare-assertion check over the bats files
- the line-width check over `docs` and `.dev/help`
- stylua over the Luau files and the `.ci` Lua files, with the repo's
  `stylua.toml`, which sets the syntax to Luau
- the comment checks over the Luau files: no full-line comment directly after
  code, and no run of three or more consecutive prose comment lines
- luau-analyze over the Luau files, in its default non-strict mode, with
  root `.luaurc` naming the globals dev's runtime adds
- selene and ast-grep over the `.ci` Lua files, with the repo's `selene.toml`
  and `sgconfig.yml`
- the standalone shell check
- the ast-grep rule tests, once

The Luau roots are `luau/dev`, `tests/lua` and `.dev`. `dev fmt` runs
`cargo +nightly fmt`, then stylua over the Luau files with the same config.

A `.luau` file gets stylua, the comment checks and luau-analyze. selene and
ast-grep read Lua only, so they run on `.ci/*.lua` alone and never see a
`.luau` file. The `.luaurc` at the root turns luau-analyze's style lints off,
so it reports type errors and syntax errors only. The `--!strict` header and
typed `@param` rules are not part of the set.

selene runs with `--no-exclude`. The set's `exclude = [".*/**"]` would hide
`.dev` otherwise.

### dev soak

`dev --remote soak [-- --runs N]` is `.dev/commands/soak.luau`, the job of
`.ci/soak.lua`. It does 50 runs by default. Each run loops these cases beside
two busy loops per core:

- the pkg_script TERM case
- the `ctrl-c` cases of `tests/dev/confirm.bats`

It prints each run as `PASS` or `FAIL` with the burner count, core count, load
average and runnable count it ran under, and keeps the output of a failed run.
It fails a run in which no case ran and exits 1 when any run failed. It
refuses to run off a ci host to avoid loading the machine. Each case runs in its
own process group with a 300 second limit, so a TERM or a kill of dev alone
stops the case and its busy loops at once.

### dev test

`dev test PATH...` runs only the suites at each path under `tests/` and
refuses a path that names no suite with exit 2. A path under a group skipped on
this machine is also exit 2. The message reads `PATH is skipped here.` A
leading `./` and a trailing slash are dropped from a path first. `dev test`
alone runs every bats file, `*_test.sh` and `test-*.sh` script and
`*_test.luau` suite.

`dev board check` and the `dev board land` recheck narrow a plain
`dev --remote test` row, one with no words after it, to the suites that cover
the working-copy change (`dev.board.select`). This is the selection rule:

- A touched suite is picked itself.
- A touched Lua module picks every Lua suite that requires it, directly,
  through the modules that require it, or through a concatenated require such
  as `require("dev.pkg." .. name)`, and no other suite. A bats or shell suite,
  a suite that requires `support` or `dev.testenv`, and a suite that names a
  fixture or reads the source are not picked, and `dev board ship` runs the
  whole suite as the backstop.
- A touched file that is not a Lua module or a suite, a touched test helper,
  or a touched module that no Lua suite reaches leaves the whole suite running.
- A touched module that a command file loads, directly or through other
  modules, leaves the whole suite running. A command file is a Lua file under
  `.dev` that is not a module, not a suite and not under `tests/`. Its parity
  suites run it as a subprocess and never require the module, so the map
  cannot name them.
- A moved or copied file counts at both its old and its new path.

The recorded row stays the card's own plain row, so the checks fingerprint does
not change. A row that names suites and every other row run as written, and
`dev board ship` runs its release rows whole.

The suites run in parallel:

- The worker pool is the core count from `nproc` or `sysctl -n hw.ncpu`.
  `DEV_TEST_JOBS` overrides it, and 1 runs one after another.
- Each suite runs in its own `TMPDIR` with its output in a file.
- The scratch directory `dt.XXXXXX` sits under `TMPDIR` when that is an
  absolute path of at most 40 characters, else under `/tmp`. A suite's
  `TMPDIR` stays short that way.
- Ctrl-C included, a guard process in its own process group waits for dev to
  die, sends TERM and then KILL to every unfinished suite's group and removes
  the scratch directory. `tests/dev/interrupt_test.sh` pins it.

These suites run one at a time beside the pool:

- `tests/dev/{term,picker,confirm,pager}.bats`
- `tests/dev/help_test.sh`
- `tests/lua/help_test.luau`

`dev test` prints each suite's output whole with its `PASS`, `FAIL` or `SKIP`
line in discovery order, then a summary line. When the uid is not 0 or the OS
is not Linux it ends with ``The real-root cases of tests/dev/root_test.sh
and tests/dev/tools_test.sh were skipped. Run `dev --remote test` for them.``

The real root group of the ci `test` job in `.ci/jobs.lua` runs both files as
root, or for a named run (`dev --remote test PATH`) each file that a path
selects. A path selects a file when it names the file or a directory above it,
with a leading `./` and a trailing slash dropped. It fails the job when a file
it runs prints a line starting `SKIP real-root` (a case that needs real root or
the real pacman). A line starting `SKIP user-only` (a case that runs as a user
through `FAKE_UID` or `FAKE_OS`) still passes.

## Releasing

A release is a pushed tag. `.github/workflows/release.yml` runs on a `v*` tag
and on nothing else, never on a push or a pull request.

1. Push the tag from a workspace: `jj tag set vX.Y.Z -r REV`, then
   `dev push --tag vX.Y.Z`. Gerrit mirrors it to GitHub.
2. A Linux x86_64 musl job and one macOS job build with `DEV_RELEASE_TAG` set
   to the tag, so `dev --version` prints it, run `dev release test` on each
   binary and upload it. The macOS job runs on an Apple-chip runner, builds
   aarch64 natively and cross-compiles x86_64, which it tests under Rosetta.
3. A last job runs the built Linux binary's `dev release publish`, which writes
   `SHA256SUMS` and creates the GitHub release, as a pre-release when the tag
   holds `-pre.`.

`dev release build`, `test` and `publish` hold the logic, so the workflow only
sets up the toolchain, the one bootstrap `cargo build` and the calls. A
published release is never deleted or overwritten. A failed run is fixed
forward with the next tag.

## The lint-set template rule

The rule covers the synced lint templates. A change making a synced
template call a dev module or function the deployed dev lacks lands only after
the ci images are rebuilt from a rev that holds it.

`.dev/baked.txt` lists the dev modules (`dev.fs`) and functions
(`dev.fs.exists`) the dev baked into ci's images provides, and
`dev.board.land.dev_calls` reads the same entries from a template file's
`require("dev.x")` locals, skipping full-line comments. The `sync.templates`
and `sync.baked` keys of `.dev/config.toml` name the template path prefixes
and the list file. `dev board land` refuses a commit that changes a Lua
template file calling an entry the list lacks, with the dev change in the same
commit or an earlier one, so the dev change lands first and the template
commit adds the entries after the rebuild. The runner blocks the template card
on the card for that rebuild.
