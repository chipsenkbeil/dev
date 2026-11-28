# flags: The global flags, help flags and how the launcher starts dev

## Global flags

These flags work before the command word, whatever the command. `-v` and `-q`
also count after it.

- `-v` or `--verbose`: print each command before it runs, show debug log
  lines, and export `VERBOSE=1` to it.
- `-vv`: also log every spawn with its folder, exit code and time, and export
  `VERBOSE=2`.
- `-vvv`: also trace every native `dev.*` call, and run each `.sh` command
  under `bash -x`. Only that script is traced, not the scripts or tools it
  starts. It exports `VERBOSE=3`.
- `-vvvv`: also trace calls between dev's Luau modules, and export
  `VERBOSE=4`.
- `-q` or `--quiet`: show errors only. It never touches standard output.
- `--remote`: run the command on a remote runner. By default that is the job
  named like the command in the project's default pipeline (`.ci/jobs.lua`),
  run on example-box through ci. `DEV_REMOTE=1` in the environment is the
  same. A job that names no target starts on `ci.rust_target` (a Rust project)
  or `ci.target` from the user config, else on the ci default.
- `--local`: run the command here, whatever the `[remote] default` setting
  says. With `--remote` it is a usage error. Under `DEV_AGENT` a run of a
  command with a ci job that stays here is refused (see the `remote` topic).
- `--detach`: with `--remote`, start the job and return. Alone it is a usage
  error.
- `--priority`: with `--remote`, add `--priority` to the `ci run`, which starts
  the job ahead of every normal job waiting for room on the hub. Alone it is a
  usage error.
- `--job-timeout DURATION`: with `--remote`, add `--timeout DURATION` to the
  `ci run`, which bounds the run. Alone, with no duration, or with a duration
  that starts with `-`, it is a usage error.
- `-C DIR`: run as if dev started in `DIR`. dev enters `DIR` before
  any Luau runs, so the project root, the config and a `--remote` run all
  come from `DIR`.
- `--agent NAME`: export `DEV_AGENT=NAME` to the command. dev sets it
  before any Luau runs, so a plain `dev -C DIR --agent NAME board land CARD`
  names its claimant with no `export` or env prefix in the call.
- `--version` or `-V`: print the word dev and the version, such as
  dev 0.1.0, and exit 0, whatever words follow. The version is the release
  tag a release build was made from, else the crate version in `Cargo.toml`.
  A build reads the tag from `DEV_RELEASE_TAG` at compile time, and an empty
  or unset variable leaves the crate version.

A missing `DIR` or an empty word after `-C` is a usage error (exit 2), and so is
a missing or empty `NAME` after `--agent`. dev takes the word after
`--job-timeout` only when it does not start with `-`, and a missing duration is
a usage error.
Repeated `-C` flags apply in turn, a relative one from the directory before.
Global flags other than `-v` and `-q` count only before the first command
word. After it, every word belongs to the command. A command opts out of the
words it takes back with `globals = false`.

`-v` stacks up to `-vvvv`, and the count is capped at 4. Setting `VERBOSE` in
the environment counts the same: empty, `no` and `false` mean off, a number
counts up to 4, and any other word means 1.

`dev help remote` explains the runner, the refusals and how a project replaces
it.

These lines show each global flag at work:

```
dev -v lint
dev -vv test
dev --remote test
```

### Adding a global flag

A new flag is one row in the `GLOBALS` table of `src/flags.rs` and one match
arm there. The Rust host parses it and hands the result to Luau as
`dev.globals`. Then add it to each copy:

- `GLOBAL_FLAGS` or `VALUE_FLAGS` in `luau/dev/registry.luau`, the list
  completion and the topic check read
- the checks that combine flags in `luau/dev/cli.luau`
- the flag table in `luau/dev/help.luau`
- the list above

`tests/lua/global_flags_test.luau` fails and names the flag when a copy
misses it.

## Help flags

`-h` and `--help` are reserved for help on every command and subcommand,
in any position, but only before a `--`. A command never sees them there, so it
cannot declare them as flags (`dev help --check-topics` reports one that
does). Everything after a `--` reaches the command verbatim, so
`dev run -- -h` runs `cargo run -- -h`.

- `-h` anywhere after a command prints its description, usage and flag names.
- `--help` anywhere after a command prints the long form, the same as
  `dev help <command>`: every flag with its kind, short, default, choices,
  repeatable mark and help text, and every argument. When both appear, the
  first one found wins.
- `dev help -a` lists every command, hidden ones included.
- `dev help --topics` lists the help pages, and `dev help -k <page>` prints one.
- A topic taller than the terminal opens in `$PAGER`, else in dev's built-in
  pager. `dev help --no-pager <topic>` or `DEV_PAGER=0` prints it directly.
- The curated `dev help` always pages on a terminal, even when it fits, unless
  `--no-pager` or `DEV_PAGER=0` is set. With less as `$PAGER`, dev adds `-+F`
  and the last line reads `& filters · / searches · q quits`. The built-in
  pager has its own `/` search.

The `&` key narrows the lines as you type in less.

Color is on only when the output is a terminal and `NO_COLOR` is unset.

## Flags a command declares

A command gets a flag only when its spec declares it, or its `.sh` header does
with a `# flag:` line. dev parses the words after the command through the spec
before the command runs. A word that starts with `-` (and is not the lone word
`-`) must be a global flag, `-h`, `--help` or a declared flag, or dev stops
before the command runs. A command with subcommands checks its own words the
same way.

`--name=value` and `--name value` both work for a flag that takes a value, and
`-w VALUE` for a flag with a short. A flag that takes a value takes the next
word verbatim, even one that starts with `-`, and a word that holds whitespace
before any `=` is never a flag.

Words after the first `--` are plain arguments, unless the spec sets
`passthrough`. Then those words reach the command untouched, so flags meant
for another tool go there. `dev test -- <args>` runs the test suites with
`<args>`.

With `--remote`, arguments typed with no `--` reach the job, and arguments on
both sides of a `--` are refused, as the `remote` topic describes.

The refusal exits 2 with a sentence naming the flag or argument:

```
dev <command>: Unknown flag <flag>.
```

An unknown letter in a cluster of short flags names the word as typed, as in
`Unknown flag -b in -bad.`

## Command specs and headers

Each command is a `.luau` file returning a `dev.command` spec, or a `.sh` or
`.ps1` file with a header. `dev help <command>` draws the help from the spec.
`dev help commands` has the fields, the header grammar and the three layers.
A few fields change how dev calls a command:

- `hidden` keeps a command to `dev help -a`.
- `runs_local` keeps the remote default from sending that command to ci, for a
  command that drives ci itself beside a same-named job. An explicit
  `--remote` still sends it, and `dev help <command>` says it runs here under
  the default.
- `remote = false` marks a command that never runs on a remote runner. The
  remote default skips it, `--remote` refuses it, and the setting of a command
  with subcommands covers its subcommands.
- `requires = { "workspace" }` refuses the command to a `DEV_AGENT` with a
  workspace role in the primary checkout, and `requires = { "lead" }` does
  the same for the lead role. `workspace` and `lead` are the only
  preconditions dev knows.
- `fetch = { job, file }` runs the command here, and under the remote mode
  first builds `file` with the ci job `job` on this host's platform and hands
  the pulled path to the command in `DEV_FETCHED`. `dev help remote` has the
  rule.
- `patch = { job, file }` runs the ci job under the remote mode and applies
  the patch `file` it keeps at the project root, in place of running the
  command. `dev help remote` has the rule.
- `positional` keeps a word shaped `KEY=value` in the command's arguments.

Any other global or project command has such words split into `ctx.vars`, and
a `.sh` command always gets every word as given. A command documents its
`KEY=value` arguments in its help.

## The help views

`dev` with no arguments is `dev help`. It prints the project line, the
commands under task-named group headings, the topic list and a pointer line.

The groups are Check your work, Share it, Set up a machine or project and
Boxes, shown in that order and only when they have members. Any project group
follows, then Hidden. A command's description is the summary of its
spec or header.

Each view reads the terminal like this.

- On a terminal with color, the curated view and `dev help -a` draw commands
  in bold and group headings in dim. Each command and help page sits on one
  line cut to the terminal width with `…`.
- Piped output, `NO_COLOR` and `TERM=dumb` stay plain and uncut.
- The closing pointer line draws its backticked spans in cyan without the
  backticks and is cut to the width with `…`. Piped, it keeps the backticks
  and is not cut.
- `dev help -a` adds the hidden commands and dev's own `__` helpers. Its mark
  column names the source of each command, `builtin`, `global` or `project`,
  and `project over builtin`, `global over builtin` or `project over global`
  for a command that replaces another. The curated view marks such a command
  `(override)` and has no source column.
- `dev help <command>` and `dev <command> --help` print the long form, and
  `dev <command> -h` prints the description, usage and flags. The heading of a
  command that replaces another names its source and what it replaces, as in
  `dev lint (project over builtin)`.
- `dev help <page>`, `dev help -k <page>` and `dev help --topics` read
  help pages.

A command with subcommands takes the group of its first subcommand that has
one. Every command, built-in or not, is a spec, so `-h` and `--help` read the
same fields for all of them.

## Paging

A topic prints as the file when standard output is not a terminal, when
`NO_COLOR` is set and not empty, and when `TERM` is `dumb`. Otherwise it
prints as styled Markdown through `dev.ui.markdown`, at most 100 columns wide.

`dev help <topic>` and `dev help -k <topic>` then go through `dev.ui.page`
(`$PAGER`, else the built-in pager) when standard output is a terminal and
the text has
more lines than the screen has rows (`dev.term.size`). Otherwise they print
directly. `dev help --no-pager ...` (the flag may stand anywhere among the
arguments) or `DEV_PAGER=0` in the environment turns paging off.

The curated view always goes through the pager on a terminal, even when it
fits. `--no-pager`, `DEV_PAGER=0`, a pipe, `NO_COLOR` and `TERM=dumb` print it
directly. In `help.page_plan`, `rows = 0` forces `dev.ui.page` to page it.

With less as the pager (`PAGER` is set and its first word has the basename
`less`), dev adds `-+F` to its arguments. That cancels a `-F` from `PAGER` or
`LESS` that would make less quit on short text. The paged text also ends in a
dim `& filters · / searches · q quits` line.

`dev.ui.should_page(content, opts)` makes the decision and
`dev.ui.page(content, opts)` runs the pager. The `opts` are:

- `pager`: the command to run.
- `allowed`: whether paging is permitted.
- `interactive`: whether standard output is a terminal.
- `rows`: the rows the screen has.
- `fallback`: the text printed when the pager fails, instead of the content.

The text goes to the pager on a temporary file as its standard input. A pager
that quits early exits 0. One that is missing or exits non-zero gets
`The pager failed, so the text follows without it.` on standard error, and
the text prints directly without the filter line.

## Topics

Topics are Markdown files whose first line is `# <name>: <summary>`.
Built-in ones are the `docs/` folder baked into the binary, and project ones
live in `.dev/help/`. A help page may not share a name with a top-level command
or a built-in topic, except that a project's `overview` page is printed after
dev's own. Nested command words such as `gerrit listen-build` never collide
with a page.

`dev help --check-topics` checks the built-in help pages from `docs/` on disk
when the project is dev itself (`luau/dev/cli.luau` exists), and the project's
help pages in every project. For each help page it checks the first line, the
names, and that each backticked or fenced `dev` line followed by words names a
real command or subcommand and only flags it declares. It exits 1 with
`file:line` for each problem.

`tests/dev/help_test.sh` runs the check on the real help pages and snapshots the
help views of `tests/dev/fixtures/help-project/`.
`UPDATE_SNAPSHOTS=1 bash tests/dev/help_test.sh` rewrites them.

## The remote default

A command with a ci job runs remote by default. The config files hold
`[remote] default = "remote"` (the shipped value, also the value when nothing
sets it) or `"local"`. `dev.config`'s `prefer_user` reads it, so the user file
beats the project file and a host picks its own default.

Any other value is ``The `remote.default` setting must be "remote" or
"local", not X.`` (exit 1).

The default applies only to a command whose job `ci run --list --json` lists in
the default pipeline. It never applies to a command that declares
`remote: false` (see `# remote: false` above) or as root, which reads no
config. A project with no `.ci/*.lua` pipeline file has no job and ci is not
asked, and a command the listing does not name runs here with no message.

A missing `ci` on PATH, or a `ci run --list` that exits non-zero or answers
badly, fails the command with ci's error (exit code kept) and the hint
``Rerun it, or pass `--local` to run it here.`` A ci deploy never moves every
run onto the laptop.

Both the default and an explicit `--remote` pass every argument to the job.

Local is automatic only for these cases.

- `CI=true` or the box marker.
- `--local`, or `DEV_REMOTE` set to `0`, `no` or `false`.
- `remote.default = "local"`.

Inside a ci job (`CI=true`) or a dev box, dev always runs here, `--remote`
included, except as root. The box marker is the file `/etc/ci-box` that ci
writes at box creation (see "Dev boxes" in ci's README), or the path in
`DEV_BOX_MARKER`, which `dev.remote.BOX_MARKER` defaults to. A box made before
ci writes `/etc/ci-box` has no marker, so pass `--local` there.

A run under `DEV_AGENT` of a command with a ci job that stays here is refused,
whatever chose it. The exceptions are a command with a `# local` header and a
run inside a ci job or a dev box. See the `remote` topic.

A `DEV_AGENT` with a workspace role, `runner`, `implementer`, `planner`,
`reviewer` or `verifier`, is also refused with exit 2 when a command that
declares `requires: workspace` runs in the primary checkout, so `-C WS` must
name a workspace or worktree. The lead role is refused the same way for
`land`, `board land`, `abandon`, `clean`, `purge` and `fmt` only. The repo's
`agent.primary_guarded` list in `.dev/config.toml` adds commands to that
refusal for any set `DEV_AGENT`. The `remote` topic has the rule.

A command line with both `--local` and `--remote` exits 2 with this message:

```
The flags `--local` and `--remote` cannot be used together.
```

## The minimum dev version

dev's own version is `dev.runtime.version`, the `MAJOR.MINOR.PATCH` core of
the release tag, else the crate version.
A project names the
oldest dev it works with as `[dev] min_version = "MAJOR.MINOR.PATCH"` in
`.dev/config.toml`. When this dev is older, dev exits 1 before it runs
anything, with ``This project needs dev 0.2.0 or newer, and this dev is
0.1.0.`` (the real versions). A value that is not `MAJOR.MINOR.PATCH` exits 1
with ``The `dev.min_version` setting must be MAJOR.MINOR.PATCH, not X.``

## Upgrade

`dev upgrade` replaces the running binary with the latest release that is not
a pre-release, and says so when this version is current. A pre-release of the
latest version counts as older. `dev help upgrade` lists the checks it makes
before the swap.

```
dev upgrade
```

## The remote runner

`--remote` (or `DEV_REMOTE=1`) runs the command somewhere else. Dev strips
`--remote`, `--detach`, `--priority` and `--job-timeout DURATION`, hands the
runner the command words and the arguments untouched, and returns the
runner's exit code.
Arguments given with no `--` reach the job as well, and arguments on both
sides of a `--` are a usage error.

The runner is `.dev/helpers/remote.luau` when the project has one, else `ci`. A
`.dev/helpers/remote.luau` is a chunk returning `function(run) -> integer`, with
`run = {words, args, detach, priority, job_timeout, root, verbose}`.

The ci runner needs `ci` on PATH and checks `ci -C <root> run --list --json`
for the job. The job is `<command>`, or the words joined by a hyphen for a
subcommand (`<command>-<sub>`, and `<command>-<sub>-<sub2>` one level
deeper). It then runs
`ci -C <root> run --local --follow --job <job> -- <args>` on example-box, with
`--detach` in place of `--follow`, and never falls back to a local run.

Arguments on both sides of the `--` are a usage error, and so are `--detach`,
`--priority` and `--job-timeout` without `--remote`.

This repo's `.dev/helpers/remote.luau` sends `soak` to the job of the same
name in `.ci/soak.lua`. The default pipeline runs on every patchset, so `soak`
stays out of `.ci/jobs.lua`.

Every other command goes to `dev.remote.ci_runner`. The topic is
`docs/dev/remote.md`.

`--remote` refuses every command that declares `remote: false` in its header or
its built-in row. The refusal exits 2 whatever the runner, with this message:

```
dev <command>: runs on this machine only, so --remote does not apply
```

## Push and pull

`dev push` and `dev pull` use jj when the repo has `.jj` and git otherwise.
`dev push` pushes only to the remote of record: the `gerrit` remote in a
gerrit project, else `origin`, from the same forge setting `jj land` reads.

`dev push origin` and `dev push gerrit` push to the one remote named.
`dev push` prints which forge and remote it chose and why. A flag or argument
a command does not take is a usage error that names it and exits 2.

## Follow

`dev follow` moves the repo's main checkout onto trunk. It takes no argument and
works from the main checkout, a jj workspace or a git worktree. A set
`DEV_FOLLOW_REV`, a commit id, moves it onto that commit in place of trunk: jj
opens a new empty change on it and git detaches HEAD there. `dev board ship`
sets it to the commit it tested, and a value that is not hex exits 2.

- A folder with `.jj` answers to jj, and its main checkout is the workspace
  named `default`. Any other folder with `.git` answers to git, and its main
  checkout holds the common git folder. A folder with neither exits 1.
- A main checkout with `.jj` uses jj and one with only `.git` uses git.
- A clean checkout is fetched, then moved onto trunk. jj opens a new empty
  change on `trunk()`. git switches to `master` or `main` and fast-forwards it
  to the `origin` remote, or to the first remote when there is no `origin`.
- A checkout with uncommitted edits stays as it is. For jj that means an
  `@` that is not empty, and for git a changed tracked file. A git checkout on
  a detached HEAD that no branch holds stays as it is too. One line names the
  folder and says why.
- For jj, an empty `@` whose parent is not on trunk stays as it is too, to keep
  the command from moving a checkout off unlanded changes. A set
  `DEV_FOLLOW_REV` is subject to the same rule.
- A set `DEV_FOLLOW_REV` never moves a checkout back to an older commit. A
  checkout on a commit newer than the rev stays as it is, and the line reads
  `FOLDER stays on the newer commit COMMIT.` A rev ahead of the checkout still
  moves it.
- The command prints one sentence with a final period. It reads
  `FOLDER is on trunk COMMIT.`,
  `FOLDER was left alone: it has uncommitted changes.`,
  `FOLDER was left alone: it sits on changes that are not on trunk.` or
  `FOLDER stays on the newer commit COMMIT.`, and the exit code is 0 for all
  four. A failed jj or git command exits 1 with a sentence that names it, such
  as `The git fetch command failed in FOLDER: OUTPUT.`
- A project `.dev/commands/follow.luau` or `follow.sh` replaces the built-in.
  `dev board land` on a board with no `deploys = true` under `[board.land]`
  and `dev board ship` run it through dev, and the script runs in
  the main checkout.

## The config command

`dev config` is the first-run wizard for the user config,
`~/.config/dev/config.toml`. It takes no argument and works in any folder. It
asks for the keys that file does not set. It looks at that file alone, so a
value in a project's `.dev/config.toml` leaves a key unset to the wizard.

| Key | Needed | Answer |
|---|---|---|
| `board.pomb.url` | required | the Pomb URL |
| `board.pomb.token` | required | a `pass:<entry>` reference, never the token |
| `gerrit.host` | optional | the Gerrit host name |
| `board.pomb.field_prefix` | optional | the prefix of the board's custom field keys |
| `gerrit.port` | optional | the Gerrit SSH port, a whole number from 1 to 65535 |
| `board.ship.source_roots` | optional | a comma separated list of source folders |

- On a terminal it prints the keys that are set, then asks for each unset one as
  a line on standard input. A blank answer skips an optional key and asks a
  required one again. It appends the answers to the file, in the section of each
  key, and keeps every other line as it is. It makes the file and its folder
  when they are missing, and prints `Wrote KEY to PATH.` for each key it wrote.
  It exits 1 when a required key is still unset at the end, and 0 otherwise.
- With no terminal it asks nothing and writes nothing. It prints each key with
  `set`, `unset` or `unset, required`, and exits 1 when a required key is unset.
- The token key holds only a `pass:<entry>` reference. The terminal does not
  echo what is typed for it, and any other answer is refused with a sentence
  that does not repeat the answer, and nothing is written for that key. The
  wizard never runs `pass`, never reads a token and never prints one.
- The wizard does not ask for `github.owner`. Set it in the user file to name
  the owner in the remote that `dev init` prints, and `OWNER` is printed when
  it is unset.
- `ci.target` and `ci.rust_target` name the ci target that `dev init` writes
  into `.ci/jobs.lua`, and `TARGET` is written when the key is unset. The
  wizard does not ask for them.

## The launcher

dev is one Rust binary that embeds Luau. `bootstrap.sh` and the zsh
completion find dev as `dev` on `PATH`, and a built binary runs as
`target/debug/dev` or `target/release/dev`.

Before any Luau runs, the Rust host parses the global flags. It reads them
only before the first command word. That word and every word after it belong
to the command, so `dev test --remote` hands `--remote` to `test`. Any other
word that starts with `-` before the command word exits 2 with
``The flag `X` is not a global flag of dev.`` A lone `-` is a command word.

- Each `-C DIR` is applied in order. A missing or empty word exits 2 with
  ``The flag `-C` needs a directory.`` and a folder dev cannot enter exits 2
  with ``The flag `-C` cannot enter <DIR>.`` dev sets `PWD` for each.
- `--agent NAME` exports `DEV_AGENT=NAME`. A missing name exits 2 with
  `The --agent flag needs a name.`
- `--job-timeout` takes the next word unless it starts with `-`.
- `-l FILE ARGS...` runs a Luau file with every word after it as its arguments,
  for example `dev -l tests/native/runtime_test.luau`. A missing file exits 2
  with `The file FILE does not exist.` An error prints its traceback and exits
  1.
- An argument that is not valid UTF-8 exits 2 with
  `An argument to dev is not valid UTF-8.`

At uid 0 the host resets `PATH` to
`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` and unsets
`DEV_UID`, `DEV_OS`, `BASH_ENV` and `ENV`. The root check itself stays in Luau.
The host exports `DEV_SELF` as the canonical path of the running binary. An
enabled `DEV_REMOTE` is anything but empty, `0`, `no` or `false`.

Nothing is read from disk to start: the Luau modules, the topics and the
init templates are baked into the binary. A modules folder on disk is not
needed and a checkout update never shows a running dev half-written code.

Verbosity is the flag count, else the `VERBOSE` variable, capped at 4. At `-vv`
dev logs every spawn to standard error. At `-vvv` it also traces every native
`dev.*` call, and a `.sh` command runs as `bash -x SCRIPT ARGS`. Only that
script is traced, because dev sets no `BASH_ENV` hook for the scripts and tools
it starts.

## The dispatcher

`dev.cli.main(dev.globals)` is the entry point the host calls with the parsed
flags. It returns the exit code. These steps run in order.

- Checks the flags that combine, such as `--local` with `--remote` and
  `--detach` without `--remote`, and applies the root check.
- Resolves the command words through `dev.registry`, which merges the
  built-in, global and project layers.
- Walks a command with subcommands, and answers `needs a subcommand` or
  `unknown subcommand` with the subcommand list (exit 2).
- Parses the words after the command through the command's spec with
  `dev.spec`, refusing an unknown flag or argument with a usage message
  (exit 2). `-h` and `--help` are answered before the parse.
- Runs `--remote` through `dev.remote`.
- Runs a `.luau` command in process through `dev.command`, or execs a `.sh`
  command with each parsed flag in `DEV_FLAG_NAME`, or a `.ps1` command under
  `pwsh -File` on Windows.

An error in a `.luau` command prints as `dev <command>: <message>` with exit 1.
A word the registry does not know is `dev: unknown command <word>` with the
curated help on standard error (exit 2). An error that escapes the host prints
`dev: <message>` and a traceback and exits 1. A closed standard output exits 141
with no text.

Other modules serve these commands.

- `dev.complete` and `dev.topics`: `dev __complete WORD...` prints one
  candidate per line, `value`, a tab and a description. It completes command
  words, flag names, flag values (the `choices`, or the flag's provider) and
  arguments through their provider. The providers are
  `dev.complete.board_card`, `board_column`, `box` and `file`. A card id
  completes from a cache file under `$XDG_CACHE_HOME/dev` that a detached
  `dev __complete --refresh-cards FILE` rewrites when it is a minute old, so
  Tab never waits on Pomb. A box or connectable name comes from
  `ci __complete KIND` under a 3 second limit, and a run id after `--run`. A
  missing, slow or failing provider prints nothing and exits 0.
  `dev completion SHELL` prints the shell's script.
- `dev.cmd.types`: the project-type built-ins `lint`, `fmt`, `test`, `build`,
  `run` and `fetch`, in process.
- `dev.cmd.push` and `dev.cmd.pull`: `push` and `pull`, with the backend and
  the forge setting in `dev.vcs` and `dev.forge`.
- `dev.cmd.follow`: `follow`, and the `main` and `launch` calls `board land` and
  `board ship` make.
- `dev.cmd.tools` and, as root, `dev.root`: `tools install` and `tools check`.
- `dev.cmd.init`: `init`.
- `dev.cmd.config`: `config`, which writes through `dev.toml`'s `set`.

A test seam (`tests/lua/fake_env.luau`) can fake the uid and system name and
hide named tools from `which` (`FAKE_HIDE`) for a user. It never loads at
uid 0.
