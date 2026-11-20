# flags: The global flags, help flags and how the launcher starts dev

## Global flags

Nine flags work anywhere before a `--` on the line, whatever the verb.

- `-v` or `--verbose`: print each command before it runs, and export
  `VERBOSE=1` to it.
- `-vv`: also trace every line of dev and of each bash script it runs, which
  exports `VERBOSE=2`.
- `--remote`: run the command on a remote runner. By default that is the job
  named like the verb in the project's default pipeline (`.ci/jobs.lua`), run
  on example-box through ci. `DEV_REMOTE=1` in the environment is the same.
- `--local`: run the command here, whatever the `[remote] default` setting
  says. With `--remote` it is a usage error. Under `DEV_AGENT` a run of a
  verb with a ci job that stays here is refused (see the `remote` topic).
- `--detach`: with `--remote`, start the job and return. Alone it is a usage
  error.
- `--priority`: with `--remote`, add `--priority` to the `ci run`, which starts
  the job ahead of every normal job waiting for room on the hub. Alone it is a
  usage error.
- `--job-timeout DURATION`: with `--remote`, add `--timeout DURATION` to the
  `ci run`, which bounds the run. Alone, with no duration, or with a duration
  that starts with `-`, it is a usage error.
- `-C DIR`: run as if dev started in `DIR`. The launcher enters `DIR` before
  `luajit` starts, so the project root, the config and a `--remote` run all
  come from `DIR`.
- `--agent NAME`: export `DEV_AGENT=NAME` to the command. The launcher sets it
  before `luajit` starts, so a plain `dev -C DIR --agent NAME board land CARD`
  names its claimant with no `export` or env prefix in the call.

A missing `DIR` or an empty word after `-C` is a usage error (exit 2), and so is
a missing or empty `NAME` after `--agent`. The launcher passes the word after
`--job-timeout` on with it, and the Lua parser refuses a missing duration.
Repeated `-C` flags apply in turn, a relative one from the directory before.
After the verb `guide` a `-C` or `--agent` is part of the question.

`-v` and `-vv` also stack as `-vvv`, and the count is capped at 2. Setting
`VERBOSE` in the environment counts the same: empty, `no` and `false` mean
off, a number counts up to 2, and any other word means 1.

`dev help remote` explains the runner, the refusals and how a project replaces
it.

When the trace file `xtrace.bash` is missing, `-vv` prints
`The trace file <path> is missing. Showing commands only.` and falls back to
`-v`.

These lines show each global flag at work:

```
dev -v lint
dev -vv test
dev --remote test
```

### Adding a global flag

A new flag goes first into `BARE_FLAGS` or `VALUE_FLAGS` in
`lua/dev/registry.lua`, the one list every other copy is checked against.
Then add it to each copy:

- the launcher, `bin/.local/bin/dev`, when it consumes the flag or implies
  `--remote`
- the parser in `lua/dev/cli.lua`
- the flag table in `lua/dev/help.lua`
- the completion in `zsh/.config/zsh/completions/_dev`
- the list above

`tests/lua/global_flags_test.lua` fails and names the flag when a copy
misses it.

## Help flags

`-h` and `--help` are reserved for help on every verb and noun subcommand, in
any position, but only before a `--`. A script never sees them there, so it
cannot declare them in its `# flags:` line (`dev __topics check` reports one
that does). Everything after a `--` reaches the verb verbatim, so
`dev run -- -h` runs `cargo run -- -h`.

- `-h` anywhere after a verb prints its description, usage and flags.
- `--help` anywhere after a verb prints the long form, the same as
  `dev help <verb>`. When both appear, the first one found wins.
- `dev help -a` lists every command, hidden ones included.
- `dev help --topics` lists the topics, and `dev help -k <topic>` prints one.
- A topic taller than the terminal opens in `$PAGER` (else `less -R`).
  `dev help --no-pager <topic>` or `DEV_PAGER=0` prints it directly.
- The curated `dev help` always pages on a terminal, even when it fits, unless
  `--no-pager` or `DEV_PAGER=0` is set. With less as the pager, dev adds `-+F`
  and the last line reads `& filters · / searches · q quits`.

The `&` key narrows the lines as you type. The one exception to the help
flags is `tools install` and `tools check` as root, where they are an unknown
flag.

Color is on only when the output is a terminal and `NO_COLOR` is unset.

## Flags a script declares

A project script gets a flag only when its `# flags:` line declares it.
Before a `--`, a word that starts with `-` (and is not the lone word `-`) must
be a global flag, `-h` or `--help`, or listed on the line. Anything else stops
dev before the script runs.

`<verb>` is the command words, a noun and its subcommand included.
`--name=value` is checked as `--name`, and a declared flag's separate value
(`--days 7`) is a plain word. Words that do not start with `-` are never
refused, and a value that starts with `-` is checked as a flag, so write it as
`--days=-1`.

Everything after the first `--` reaches the script untouched, so flags meant
for another tool go there. `dev test -- <args>` runs the test suites with
`<args>`.

Built-in verbs check their own flags. With `--remote`, arguments typed with no
`--` reach the job, and arguments on both sides of a `--` are refused, as the
`remote` topic describes.

The refusal exits 2 with this message:

```
dev <verb>: Unknown flag <flag>. Pass it after -- to reach the script, or add it to the script's # flags: line.
```

## Script headers

Each verb is `.dev/<verb>.lua` or `.dev/<verb>.sh`, and `dev help <verb>`
prints the script's header. A header can carry these lines.

- `# flags: --a --b`: the flags that `dev help <verb>` and shell completion
  offer. Commas also separate the words.
- `# group: <name>`: the heading the verb is listed under. A verb with none
  lands in a group named after the project directory, and a built-in override
  keeps its built-in group.
- `# hidden`: keeps a flat verb to `dev help -a`.
- `# local`: keeps the remote default from sending that verb to ci, for a
  script that drives ci itself beside a same-named job. An explicit `--remote`
  still sends it, and `dev help <verb>` says it runs here under the default.
- `# fetch JOB FILE`: runs the verb here, and under the remote mode first
  builds `FILE` with the ci job `JOB` on this host's platform and hands the
  pulled path to the verb in `DEV_FETCHED`. `dev help remote` has the rule.
- `# patch JOB FILE`: under the remote mode runs the ci job `JOB` and applies
  the patch `FILE` it keeps at the project root, in place of running the verb.
  `dev help remote` has the rule.
- `# positional`: marks a `.lua` verb that takes positional words. A word
  shaped `KEY=value` stays in `ctx.args` for it and `ctx.vars` is empty.

Any other `.lua` verb has such words split into `ctx.vars`, and a `.sh` verb
always gets every word as given. A verb documents its `KEY=value` arguments in
its header, as in `dev setup STEPS="--install-brew"`.

## The help views

`dev` with no arguments is `dev help`. It prints the project line, the verbs
under task-named group headings, the topic list and a pointer line.

The groups are Check your work, Share it, Set up a machine or project and
Boxes, shown in that order and only when they have members. Any project group
follows, then Hidden. A verb's description is the first comment line of its
script.

Each view reads the terminal like this.

- On a terminal with color, the curated view and `dev help -a` draw verbs in
  bold and group headings in dim. Each verb and topic sits on one line cut to
  the terminal width with `…`.
- Piped output, `NO_COLOR` and `TERM=dumb` stay plain and uncut.
- The closing pointer line draws its backticked spans in cyan without the
  backticks and is cut to the width with `…`. Piped, it keeps the backticks
  and is not cut.
- `dev help -a` adds the hidden verbs and dev's own `__` helpers.
- `dev help <verb>` and `dev <verb> --help` print the long form, and
  `dev <verb> -h` prints the description, usage and flags.
- `dev help <topic>`, `dev help -k <topic>` and `dev help --topics` read
  topics.

A noun takes the group of its first subcommand script with a `# group:` line.
`builtin_table` rows end in a group column, where `hidden` keeps a built-in to
`dev help -a` and a subcommand row leaves the column empty to take its noun's.

## Paging

A topic prints as the file when standard output is not a terminal, when
`NO_COLOR` is set and not empty, and when `TERM` is `dumb`. Otherwise it
prints as styled Markdown through `dev.ui.markdown`, at most 100 columns wide.

`dev help <topic>` and `dev help -k <topic>` then go through `dev.ui.page`
(`$PAGER`, else `less -R`) when standard output is a terminal and the text has
more lines than the screen has rows (`dev.term.size`). Otherwise they print
directly. `dev help --no-pager ...` (the flag may stand anywhere among the
arguments) or `DEV_PAGER=0` in the environment turns paging off.

The curated view, and `dev guide` with no question (once, as one text), always
go through the pager on a terminal, even when they fit. `--no-pager`,
`DEV_PAGER=0`, a pipe, `NO_COLOR` and `TERM=dumb` print them directly. In
`help.page_plan`, `rows = 0` forces `dev.ui.page` to page them.

With less as the pager (`PAGER` unset or its first word has the basename
`less`), dev adds `-+F` to its arguments. That cancels a `-F` from `PAGER` or
`LESS` that would make less quit on short text. The paged text also ends in a
dim `& filters · / searches · q quits` line, and dev builds no viewer of its
own.

`dev.ui.should_page(content, opts)` makes the decision and
`dev.ui.page(content, opts)` runs the pager. The `opts` are:

- `pager`: the command, run by `sh`.
- `allowed`: whether paging is permitted.
- `interactive`: whether standard output is a terminal.
- `rows`: the rows the screen has.
- `fallback`: the text printed when the pager fails, instead of the content.

The text goes to the pager on a temporary file as its standard input. A pager
that quits early exits 0. One that is missing or exits non-zero gets
`The pager failed, so the text follows without it.` on standard error, and
the text prints directly without the filter line.

## Topics

Topics are Markdown files whose first line is `# <name>: <summary>`. Built-in
ones live in `docs/dev/` of the dotfiles clone that holds `dev` (found through
`dotfiles_root`), and project ones in `.dev/topics/`. A topic may not share a
name with a verb or a built-in topic.

`dev __topics check` checks the built-in topics when the project is the
dotfiles clone `dev` reads them from (`DOTFILES` overrides it), and the
project's topics in every project. For each topic it checks the first line,
the names, and that each backticked or fenced `dev` line followed by words
names a real verb or subcommand and only flags `dev __flags` lists for it. It
exits 1 with `file:line` for each problem.

`tests/dev/help_test.sh` runs the check on the real topics and snapshots the
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
the default pipeline. It never applies to a machine-local verb (listed below)
or as root, which reads no config. A project with no `.ci/*.lua` pipeline file
has no job and ci is not asked, and a command the listing does not name runs
here with no message.

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

A run under `DEV_AGENT` of a verb with a ci job that stays here is refused,
whatever chose it. The exceptions are a verb with a `# local` header and a run
inside a ci job or a dev box. See the `remote` topic.

A command line with both `--local` and `--remote` exits 2 with this message:

```
The flags `--local` and `--remote` cannot be used together.
```

## The remote runner

`--remote` (or `DEV_REMOTE=1`) runs the command somewhere else. Dev strips
`--remote`, `--detach`, `--priority` and `--job-timeout DURATION`, hands the
runner the command words and the arguments untouched, and returns the
runner's exit code.
Arguments given with no `--` reach the job as well, and arguments on both
sides of a `--` are a usage error.

The runner is `.dev/__remote.lua` when the project has one, else `ci`. A
`.dev/__remote.lua` is a chunk returning `function(run) -> integer`, with
`run = {words, args, detach, priority, job_timeout, root, verbose}`.

The ci runner needs `ci` on PATH and checks `ci -C <root> run --list --json`
for the job. The job is `<verb>`, or the words joined by a dot for a
subcommand (`<noun>.<sub>`, and `<noun>.<sub>.<sub2>` one level deeper). It
then runs `ci -C <root> run --local --follow --job <job> -- <args>` on
example-box, with `--detach` in place of `--follow`, and never falls back to a
local run.

Arguments on both sides of the `--` are a usage error, and so are `--detach`,
`--priority` and `--job-timeout` without `--remote`.

`bootstrap` is not on the refusal list below. This repo's
`.dev/__remote.lua` sends `bootstrap` and `soak` to the job of the same name
in `.ci/bootstrap.lua` and `.ci/soak.lua`.

The default pipeline runs on every patchset, so `bootstrap` stays out of
`.ci/jobs.lua`.

Every other command goes to `dev.remote.ci_runner`. The topic is
`docs/dev/remote.md`.

`--remote` refuses the machine-local verbs `install`, `uninstall`, `restow`,
`sync`, `setup`, `fmt`, `fetch`, `help`, `init`, `push`, `pull`, `follow`,
`land`, `guide` and `connect`, and every `tools`, `box`, `board`, `ws`, `pi` and
`antinote` subcommand. The refusal exits 2 whatever the runner, with this
message:

```
dev <verb>: runs on this machine only, so --remote does not apply
```

## Push and pull

`dev push` and `dev pull` use jj when the repo has `.jj` and git otherwise.
`dev push` pushes only to the remote of record: the `gerrit` remote in a
gerrit project, else `origin`, from the same forge setting `jj land` reads.

`dev push origin` and `dev push gerrit` push to the one remote named.
`dev push` prints which forge and remote it chose and why. A flag or argument
a verb does not take is a usage error that names it and exits 2.

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
  the verb from moving a checkout off unlanded changes. A set `DEV_FOLLOW_REV`
  is subject to the same rule.
- The verb prints one sentence with a final period. It reads
  `FOLDER is on trunk COMMIT.`,
  `FOLDER was left alone: it has uncommitted changes.` or
  `FOLDER was left alone: it sits on changes that are not on trunk.`, and the
  exit code is 0 for all three. A failed jj or git command exits 1 with a
  sentence that names it,
  such as `The git fetch command failed in FOLDER: OUTPUT.`
- A project `.dev/follow.sh` or `.dev/follow.lua` replaces the built-in.
  `dev board land` on a board with no `deploys = true` under `[board.land]`
  and `dev board ship` run it through the launcher, and the script runs in
  the main checkout.

## The launcher

`dotfiles/bin/.local/bin/dev` is a small launcher. `bootstrap.sh` and the zsh
completion recognize this repo by that path.

Before anything else, the launcher takes each `-C DIR` pair out of the
arguments before a `--`. A missing or empty word exits 2 with
``The flag `-C` needs a directory.`` Once the launcher has found itself, it
enters the directories in turn, and one it cannot enter exits 2 with
``The flag `-C` cannot enter <DIR>.``

At uid 0 (`$EUID` or `id -u`), the launcher then does the following.

- Sets `PATH` to `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- Unsets `DEV_UID`, `DEV_OS`, `BASH_ENV`, `ENV`, and `LUA_PATH`, `LUA_CPATH`
  and `LUA_INIT` with their `_5_1` and `_5_2` variants. Bash has already read
  `BASH_ENV` by then, so this scrubs the children only.
- Refuses `bootstrap` with the root refusal (exit 2).
- Takes luajit only from `/usr/bin` or `/usr/local/bin`. When it is in
  neither, the launcher refuses `--remote`, `--detach`, `--priority`,
  `--job-timeout` and an enabled `DEV_REMOTE` with the root refusal (exit 2).

A root caller without luajit and without those flags gets the root refusal
(exit 2) for every command but `tools install` and `tools check`. Those print
`As root, dev runs only on Linux.` (exit 2) off Linux and
``The command `dev tools` needs luajit in /usr/bin or /usr/local/bin.`` (exit 1)
on it.
The launcher decides this in bash from the words after the `-v` and
`--verbose` flags, before anything is read.

The launcher resolves its own real path into `DEV_SELF`. An enabled
`DEV_REMOTE` is anything but empty, `0`, `no` or `false`.

### Which copy of dev runs

A user's launcher runs dev from the installed snapshot when
`${XDG_STATE_HOME:-~/.local/state}/dev/snapshot/current` holds a `main.lua`
and an `ORIGIN` file naming the clone that launcher belongs to. It resolves
that link once, hands luajit the real version directory and exports
`DEV_CHECKOUT`, the clone it started from, for the verbs that read the
repository. A checkout update therefore never shows a running dev half-written
code. `dev install bin` publishes the snapshot: it copies `share/dev` into a new
`versions/` directory, then renames a link over `current`, so the swap is one
step. The newest three versions stay.

The launcher runs the checkout copy instead when `DEV_FROM=checkout` is set
(`dev test` sets it for every suite), when no snapshot exists yet or it came
from another clone, and always for root. A landing is live only after
`dev install bin`. When a landing changed a `dev.*` module that the install
verb itself needs, run `DEV_FROM=checkout dev install bin`.

### bootstrap

`bootstrap` as the first word runs `bootstrap.sh` from the dotfiles clone,
with no luajit needed. Dev's own handling takes over when either of these
holds.

- `--remote`, `--detach`, `--priority`, `--job-timeout` or an enabled
  `DEV_REMOTE` is present.
- Luajit is available and `--verbose`, `-v` (any number of v), `-h` or
  `--help` follows `bootstrap` before a `--`.

On the `bootstrap.sh` path the launcher drops the first `--` and passes the
words after it verbatim. `dev bootstrap --no-login`,
`dev bootstrap -- --no-login` and `dev bootstrap -v -- --no-login` all give
`bootstrap.sh` exactly `--no-login`, with or without luajit.

With no luajit, the launcher also turns `--verbose` and `-v` words before the
`--` into `VERBOSE=1` or `VERBOSE=2` (the count, at most 2) in
`bootstrap.sh`'s environment and strips them from its arguments. `-h` and
`--help` reach `bootstrap.sh`, which prints its own usage.

### Without luajit

With luajit, the launcher execs
`luajit dotfiles/bin/.local/share/dev/main.lua`. Without it, a non-root caller
exits 1 with one of the two messages below. The second applies with `--remote`,
`--detach`, `--priority`, `--job-timeout` or an enabled `DEV_REMOTE`, and
nothing runs.

```
Luajit is not found. Run `dev bootstrap`, or install it with `brew install luajit`, `pacman -S luajit`, `dnf install luajit` or `apt install luajit`.
```

```
The flag `--remote` needs luajit. Install it with `brew install luajit`, `pacman -S luajit`, `dnf install luajit` or `apt install luajit`.
```

## The dispatcher

`main.lua` builds its `package.path` from its own location only and calls
`dev.cli`. That module does these steps in order.

- Parses the global flags and applies the root check.
- Resolves the verb through `dev.registry`.
- Refuses a flag the verb's `# flags:` line does not declare. With `--remote`
  it does not, and the remote check refuses arguments on both sides of a `--`.
- Runs a `.lua` verb in process (`chunk(ctx)`, with `.dev/lua` added to
  `package.path` unless root), or execs a `.sh` verb.
- Runs `--remote` through `dev.remote`.

An error or a syntax error in a `.lua` verb prints as `dev <verb>: <message>`
with exit 1. A word the registry does not know is `dev: unknown verb <word>`
with the curated help on standard error (exit 2).

Other modules serve these commands.

- `dev.complete` and `dev.topics`: `__verbs`, `__subs`, `__flags`, `__args` and
  `__topics check`.
  `dev __args WORD...` takes the words from the verb up to the one being typed
  and prints `value<TAB>label` per line. A card id completes after a `dev board`
  subcommand that takes a card, from a cache file under `$XDG_CACHE_HOME/dev`
  that a background `dev board ls` refreshes when it is a minute old, so Tab
  never waits on Pomb. A box name completes after `dev box show`, `stop`,
  `resume`, `extend`, `retag` and `delete`, a box or connectable name after
  `dev connect` and `dev box connect`, and a run id after `--run`. Those come
  from `ci __complete KIND` under a 3 second limit for each kind. A missing,
  slow or failing `ci` prints nothing and exits 0.
- `dev.cmd.types`: the project-type built-ins `lint`, `fmt`, `test`, `build`,
  `run` and `fetch`, in process.
- `dev.cmd.misc`: `deploy`, `guide` and `bootstrap`.
- `dev.cmd.sync`, over `dev.templates`: `sync`.
- `dev.cmd.push` and `dev.cmd.pull`: `push` and `pull`, with the backend and
  the forge setting in `dev.vcs` and `dev.forge`. `dev help push` and
  `dev help pull` print their commands from the same code.
- `dev.cmd.follow`: `follow`, and the `main` and `launch` calls `board land` and
  `board ship` make.
- `dev.cmd.tools` and, as root, `dev.root`: `tools install` and `tools check`.
- `dev.cmd.init`: `init`.

A test seam (`tests/lua/fake_env.lua` through `LUA_INIT`) can fake the uid and
system name and hide named tools from `which` (`FAKE_HIDE`) for a user. It
never loads at uid 0.
