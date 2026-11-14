# modules: The dev Lua modules, .dev scripts, test runner, guide and scribe

## dev modules

The luajit modules of `dev`, one per item.

### Commands and dispatch

- `dev.cli`: dispatch.
- `dev.verb`: the `.lua` verb contract (`chunk(ctx)`, `usage_error`, `no_args`,
  `say`, `note`, `die`, `show`, `need`).
- `dev.cmd.types`: the project type's built-ins and the command lines
  `dev help <verb>` prints for them.
- `dev.cmd.misc`: `deploy`, `guide` and `bootstrap`.
- `dev.cmd.tools`: `tools install` and `tools check`.
- `dev.cmd.box`: the `box` subcommands, the time-left text and the `ci box`
  call.
- `dev.cmd.connect`: `connect` and `box connect`.
- `dev.cmd.init`: `init` with `--type`, `--name`, `--dry-run` and
  `--no-gerrit`. It prints the `would create:`, `created:` and `skipped:`
  lines and the summary, then the Gerrit project and remote, the Pomb board
  hint and its note that Pomb refused the token. It seeds `.dev/README.md`
  from the template for every project type and skips a file that exists.
- `dev.cmd.sync`: the lint-template `sync` with `--check`, `--yes` and `-y`.
  It prints the `missing:` and `differs:` lines, `up to date` and the diffs,
  asks for confirmation through `dev.ui`, and ends with `synced` or `aborted`.
  `--check` and `--yes` together are a usage error. It also rewrites the
  head of `.dev/README.md` above `## Commands in this repo` for every project
  type, in the same diff and confirm flow, and leaves a file with no marker
  line alone.

### Board

- `dev.cmd.board`: the `board` subcommands and the one place that turns a
  result into output and an exit code.
- `dev.board`: the column names and short forms, the card-id prefix match, the
  size label, the table lines and the `dev.board.Backend` interface the
  commands call.
- `dev.board.render`: the color terminal table and summary `board ls` prints.
- `dev.board.guards`: the refusals and guards the `board` verbs run before they
  act, and the usage and failure results they return.
- `dev.board.runner`: a runner's size limit and refusals, the full-column result
  and the claim a `take` makes.
- `dev.board.wiring`: the flag parsing and rows behind `board check`, and the
  landing problems, turn wait and held landing behind `board land`.
- `dev.board.pomb`: that interface over curl. The token comes from
  `DEV_BOARD_TOKEN`, then the file for `DEV_AGENT`, then `pass`, and goes to
  curl on standard input.
- `dev.board.tokenfile`: the role token files `dev board token mint` writes.
  It holds the directory, the name by a hash of the agent, the 0600 write,
  the read, the delete and the sweep of expired files.

### Workspaces

`dev.cmd.ws` holds `ws new NAME`, `ws ls`, `ws rm NAME` and `ws prune`. `ws` is
machine-local, so `--remote` refuses it.

The path of a workspace is `DEV_WS_ROOT`, else `~/.local/share/workspaces`,
then the project folder's name, then NAME. A path that exists is refused with
exit 1. A project inside the central root is named by its folder just below
the root, so a workspace makes siblings.

`ws new NAME` refuses with exit 1 and makes nothing when the project root
holds no `.jj`, `.git` or `.dev`, which is a folder outside any project.
Otherwise it works by project kind:

- A jj project first fetches its remote of record (`forge.resolve`, then
  `jj git fetch --remote NAME`). A failed fetch exits 1 with its output and
  adds nothing. It then gets `jj workspace add --name NAME -r trunk()`.
- A git project fetches its remote of record the same way (`git fetch
  NAME`), and a failed fetch exits 1 and adds nothing. It then gets
  `git worktree add --no-track -b NAME PATH REMOTE/TRUNK`, where TRUNK is the
  `master` or `main` branch the remote holds, and a remote with neither exits
  1. A git project with no remote of record exits 1 and adds nothing.
- A folder with only `.dev` gets a plain directory.

The path is printed. `ws ls` prints each folder under ROOT/<repo> as its name,
a tab and its path.

`ws rm NAME` calls `ws.remove(root, name, opts)`. It returns a result table with
`ok`, `message`, `code` and `purged` instead of dying, and `opts.inside` skips
only the refusal of the workspace dev runs in, which `dev board land` uses when
it removes the card's workspace.

It refuses a NAME that is missing, a link, outside the central root or the
workspace dev runs in, and a folder whose jj `@` is not empty or whose `git
status --porcelain` is not empty.

It deletes nothing it can rename instead. It first moves the folder, ignored
files included, to `ROOT/.trash/<repo>/NAME-<UTC stamp>`, where the stamp reads
`YYYYMMDDTHHMMSSZ`, and then runs `jj workspace forget NAME` or `git worktree
prune` from the project's main folder. A plain folder is only moved.

The move comes first, so a move that fails leaves the folder and the workspace
as they were, and a forget or prune that fails moves the folder back. A target
that already exists fails the move. Before the move, a git worktree is refused
when `git worktree list --porcelain` marks it locked (the prune would skip it)
or marks another worktree prunable (the prune would drop its record). A locked
worktree needs `git worktree unlock` first, and a prunable one `git worktree
prune`. `ws prune` removes the records of gone folders before it removes
finished worktrees, and its `--dry-run` applies the same refusal to each
finished worktree, ignoring only the records of gone folders it would remove
first. `ws ls` and `ws prune` read only ROOT/<repo>, so they never treat the
trash as a workspace.

The trash sits on the same filesystem as the workspaces, so the move is a
rename. A folder that is a mount of its own is copied and then deleted, and
fails with the error of `mv`.

Each call then purges the trash of the repo. An entry whose name ends in a
stamp more than 14 days old is deleted and gets one line, `Purged PATH from
the trash.` The stamp is compared as text with the stamp of the cutoff, never
the entry's mtime, and an entry with no stamp is left alone.

The purge runs only when a later removal runs, so an old entry can stay on
disk until then. Nothing restores an entry. The folder is moved back by hand.

A jj folder whose name `jj workspace list` no longer shows is refused by
default. jj has no working-copy commit to read there, and the message says jj
no longer tracks it and that `dev ws rm NAME --forgotten` moves it to the
trash. `--forgotten` skips the clean check and the forget and moves the folder
under the same guards. It is refused for a folder jj still lists.

A plain file directly under ROOT/<repo> is moved under the same guards, and
`ws rm` prints `Moved PATH to TRASH.` followed by the purge lines. The call
returns the purge lines as a fourth value, so `dev board land` adds them to
its cleanup lines.

`ws.remove` also takes `opts.missing`, the folder jj or git recorded. A folder
that is gone skips every folder check, and the call only forgets the jj
workspace or removes the git worktree record, never the default workspace.

`ws prune [--dry-run]` clears what finished work leaves behind, for a jj or a
git project. Each action is one sentence on standard output and the last line
counts them, for example `Pruned 2 workspaces and 1 head. Left 3 items alone.`
A dry run says `Would forget` and `Would prune` and removes nothing. As with
any jj command, reading a workspace snapshots its working copy.

A jj workspace or git worktree is pruned when its recorded folder is gone,
through `ws.remove` with `opts.missing`. It is also pruned when its name is the
short id of a Done card on the project's board and its folder sits where
`ws new` puts it, through the same `ws.remove` as `ws rm`, so the folder goes
to the trash and its line ends with `Moved PATH to TRASH.` The default
workspace and the main worktree are never listed.

A folder with changes not in a commit, and the workspace dev runs in, are kept
and each gets a `Kept` line, as does a git worktree that is locked or sits
beside a prunable one. A folder that jj or git cannot read is kept too,
and its line ends with the first line of their error. Ignored files do not
count as changes, as with `ws rm`. A project with no board, or a board that cannot be read, skips the
card test and says so. A board setting that is invalid stops prune with exit 1
before any change. `dev.cmd.board.finished(root)` lists the Done short ids.

A forget, removal or abandon that fails gets a line saying so, and prune goes
on with the rest. It exits with the code of the first failure after the count
line. A jj or git command that only reads state and fails exits 1 at once.

A jj project then abandons every head of `heads(mutable()) & empty()` that no
working copy, bookmark, remote bookmark or tag holds. It runs after the
forgets, so the working copy of a forgotten workspace goes too. A dry run
leaves the workspaces it would forget out of the held working copies, so it
lists the same heads a real run does. Only heads go, so a chain of empty
commits needs one run per commit.

It lists and leaves alone every non-empty head that nothing holds, and every
bookmark whose commit is not an ancestor of `trunk()`. There is no age
threshold. A git project has no heads to abandon and says so, so only
worktrees are pruned.

`vcs.delete_branch(root, backend, name)` runs `jj bookmark delete` or
`git branch -D` when `vcs.branches` lists the name. `land` calls it for the
card's bookmark.

### Project setup and configuration

- `dev.templates`: the lint set directory and its manifest. The manifest
  names the Lua lint, fmt and test verbs and the shared
  `.dev/lua/lintset.lua`. It also holds `skip_pending`, which leaves a
  project's Lua verbs unwritten while any of its bash verbs exists, the
  rendering that keeps the project's text below the `lint.lua` and `deny.toml`
  markers, the `[workspace.lints]` block, the library-register attribute and
  the guide part of `docs/STYLE.md`. It holds `EDITORCONFIG`, the text of the
  `.editorconfig` that `init` writes. It also holds `render_readme`, which
  keeps the project's text from the `## Commands in this repo` line of
  `.dev/README.md` and takes everything above it from the template that
  `readme_template` names. `sync` and `init` both call it, and
  `dev.pipelines` reads the `.ci/jobs.lua` texts `init` writes from
  `dotfiles/bin/.local/share/dev/init/`.
- `dev.toml`: a small TOML reader. It takes tables and dotted tables, basic
  strings, integers, booleans, one-line arrays of scalars and comments, and
  names the line of an error for anything else.
- `dev.config`: `config.get(root, "a.b")` reads `~/.config/dev/config.toml`
  and then `<root>/.dev/config.toml` over it. `config.user("a.b")` reads the
  user file alone. `config.prefer_user(root, key)` reads the user file first
  and the project file second. A malformed file is
  `dev: <path>:<line>: <reason>` with exit 1, and as root no file is read.
- `dev.root`: the command words dev may run as root (`tools install` and
  `tools check`) and the checked manifest copy.
- `dev.remote`: `--remote`.
- `dev.registry`: the registry of verbs.
- `dev.xdg`: `state_home`, the one place that resolves `XDG_STATE_HOME`. It
  falls back to `$HOME/.local/state` when the variable is unset or not
  absolute. The board claims, the board store, `dev.board.tokenfile` and
  `connect` append their own subpath.

### Help and completion

- `dev.help`: `dev help` and the help every verb's `-h` and `--help` print.
  It detects the project type only for `lint`, `fmt`, `test`, `build`, `run`
  and `fetch`. The Lua check of `dev.project` is one `find` capped at 4 levels
  that skips dot directories, `node_modules` and `target` and does not follow
  symlinks below the root. `dev.cli.guard` and `dev.verb` turn an
  `interrupted!` error into exit 130 with nothing on standard error.
- `dev.complete`: the hidden `__verbs`, `__subs` and `__flags` that feed shell
  completion, and `__topics check`.
- `dev.topics`: the topic files and the check behind `__topics check`.

### Test support

- `dev.testing`: `test(name, fn)` registers a case, and `eq`, `ok` and
  `raises` assert. These moved from `tests/lua/testing.lua`.
- `dev.testrun`: `run(root)` runs every `root/.dev/tests/*_test.lua` sorted,
  with `root/.dev/lua` on `package.path`. It prints `ok - NAME` and
  `not ok - NAME` with the error, and returns 1 when a case failed or a file
  failed to load. When the directory is missing it prints
  `SKIP .dev/tests (none)` and returns 0. `execute(from, only)` is the loop
  `tests/lua/run.lua` calls.
- `dev.testenv`: the helpers a project test uses.
  - `tempdir`: a temporary directory for one test.
  - `fake(root, name, {code, out, err})`: writes an executable
    `root/bin/NAME` that prints `out` and `err`, appends its arguments to
    `root/bin/NAME.log` and exits `code`.
  - `calls(root, name)`: the logged lines.
  - `verb(root, words, opts)`: runs the dev launcher in `root` with
    `root/bin` first on PATH and `opts.env`. It returns `out, code, err` with
    standard error apart.

  `tests/lua/projtest_test.lua` pins all three helpers.

### System, release and terminal

- `dev.os`: quoted commands, `nap`, `capture_input` to run a command with a
  secret on its standard input, exec, isatty, the uid, and `kind_of`,
  `open_nofollow`, `fstat`, `read_fd` and `close` through ffi.
- `dev.release`: the session the release installers under `scripts/` share.
  It holds the parsing of `--dry-run [version]`, the latest-tag lookup, the
  platform names, `step` that runs or prints a command, and a scratch
  directory removed at the end.
  A `die` prints `  ! install-<tool>: <message>` and exits 1.
- `dev.term`: raw mode that is always restored, and key decoding including
  pgup, pgdn, home and end.
- `dev.text`: display width, `fit`, `trim`, `words` and `wrap`. `wrap` is the
  one greedy word wrap that confirm and `dev.ui.markdown` share, and it leaves
  a word wider than the width on a line of its own.

### Terminal UI

- `dev.ui`: colors, tables, bars, confirm and spin. Confirm wraps the
  consequence to the terminal width above the `[y/N]` question.
- `dev.ui.markdown`: one function, `markdown(text, {width, color})`, that
  returns the text styled for a terminal.
- `dev.ui.picker`: a list picker, with the keys and windowing below.

`dev.ui.markdown` styles these parts:

- headings and bold in bold
- inline code in cyan without its backticks
- fenced code indented and never wrapped
- bulleted and numbered lists with their indent and a hanging wrap
- pipe tables with every column as wide as its widest cell
- prose wrapped at the width

A table wider than the width shrinks its widest columns, down to the longest
word or 8 columns, and wraps the text inside the cells. It never falls back to
the raw row. `color` off drops the markers and paints nothing.

`dev help` calls it with the terminal's width capped at 100 when standard
output takes color. `tests/lua/markdown_test.lua` pins both modes.

The picker behaves this way:

- Up and down, ctrl-p and ctrl-n, and j and k move.
- Pgup and pgdn move by a window, and home and end by the list.
- A list taller than the screen scrolls in a window that follows the cursor,
  with dim `↑ n more` and `↓ n more` lines.
- When the context has no height, the picker reads the screen's rows from its
  `size` before each draw. That is 24 when `term.size` cannot read them, and
  `Model:lines` windows only when `ctx.height` is set.
- In multi mode a row with `checked` starts checked, and `required` keeps
  enter from finishing until a row is checked.

### Tests and checks

Lua tests are `tests/lua/*_test.lua`. The hand-rolled runner runs one file at
a time: `luajit tests/lua/run.lua <file> [name]`, where a name keeps the cases
whose name contains it. The pty suites are
`tests/dev/{term,picker,confirm}.bats`, which drive a pty through
`tests/dev/pty.bash`.

`dev test` runs them when luajit is on PATH and prints `SKIP` for a suite that
ran no case.

This repo's own `dev lint`, `dev fmt` and `dev test` are `.dev/lint.lua`,
`.dev/fmt.lua` and `.dev/test.lua`. The shared code is in
`.dev/lua/dotfiles/checks.lua`, and project verbs get `.dev/lua` on
`package.path`.

#### dev lint and dev fmt

`dev lint` runs these checks:

- shellcheck, shfmt and the comment-spacing check over the bash roots
- the bare-assertion check over the bats files
- stylua, selene, ast-grep and the comment checks from the style skill's
  `lint/lua` set over the Lua roots
- the rule tests of the Lua and Rust lint sets, once

The Lua roots are the dev modules, `main.lua`, the guide and scribe modules,
`tests/lua` and `.dev`. `dev fmt` runs stylua over the same files with the
same config.

selene runs with `--no-exclude`. The set's `exclude = [".*/**"]` would hide
`.dev` otherwise.

#### dev soak

`dev --remote soak [-- --runs N]` is `.dev/soak.lua`, the job of
`.ci/soak.lua`. It does 50 runs by default. Each run loops these cases beside
two busy loops per core:

- the pkg_script TERM case
- the `ctrl-c` cases of `tests/dev/confirm.bats`
- the three interrupt cases of `tests/guide/guide.bats`

It prints each run as `PASS` or `FAIL` with the burner count, core count, load
average and runnable count it ran under, and keeps the output of a failed run.
It fails a run in which no case ran and exits 1 when any run failed. It
refuses to run off a ci host to avoid loading the machine.

#### dev test

`dev test PATH...` runs only the suites at each path under `tests/` and
refuses a path that names no suite with exit 2. A path under a group skipped on
this machine (`tests/lua` without luajit, `tests/neomutt` without neomutt and
tmux) is also exit 2. The message reads `PATH is skipped here. It needs
luajit.` or names neomutt and tmux. A leading `./` and a trailing slash are
dropped from a path first. `dev test` alone runs every bats file, `*_test.sh`
and `test-*.sh` script and `*_test.lua` suite.

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
- `tests/dev/sync_test.sh` and `tests/dev/help_test.sh`
- `tests/lua/help_test.lua`
- `tests/tmux/conf_test.sh`
- `tests/jj/land.bats`
- the neomutt scripts

`dev test` prints each suite's output whole with its `PASS`, `FAIL` or `SKIP`
line in discovery order, then a summary line. When the uid is not 0 or the OS
is not Linux it ends with `dev: the real-root cases of tests/dev/root_test.sh
and tests/dev/tools_test.sh were skipped, run dev --remote test for them`.

The real root group of the ci `test` job in `.ci/jobs.lua` runs both files as
root, or for a named run (`dev --remote test PATH`) each file that a path
selects. A path selects a file when it names the file or a directory above it,
with a leading `./` and a trailing slash dropped. It fails the job when a file
it runs prints a line starting `SKIP real-root` (a case that needs real root or
the real pacman). A line starting `SKIP user-only` (a case that runs as a user
through `FAKE_UID` or `FAKE_OS`) still passes.

### The lint-set template rule

The rule covers `dev.templates` and `dev.cmd.sync`. A change making a synced
template call a dev module or function the deployed dev lacks lands only after
infra has rebaked the ci images at a dotfiles rev that holds it.

`dev board land` refuses a commit that changes a template file and a dev
module the template requires, so the dev change lands first. The runner blocks
the template card on the infra card for that rebake
(`agents/runner.md`, Template changes that need new
dev).

## .dev scripts

There is one script per verb (`install.lua`, `uninstall.lua`, `restow.lua`,
`purge.lua`, `clean.lua`, `list.lua`, `stow.lua`, `sync.lua`, `setup.lua`,
`skills.lua`, ...), run through `dev <verb>`.

The subdirectories hold the Lua subcommands of two nouns:

- `pi/`: `dev pi` with `install`, `save`, `diff` and `check`, over
  `.dev/lua/dotfiles/pi.lua`.
- `antinote/`: `dev antinote` with `export`, `import` and `diff`, over
  `.dev/lua/dotfiles/antinote.lua`.

`lint.lua`, `fmt.lua`, `test.lua`, `soak.lua` and `skills.lua` are Lua verbs
that run in the dev process (see the `dev.*` items above).

### The install family

The install family is `.dev/lua/dotfiles/packages.lua`:

- `default_deps`: the single source of truth for the default targets.
- `select`: the package arguments, or the defaults.
- `ensure_stow`: runs `scripts/install-stow.lua`, the pinned build, into
  `DEV_TOOLS_PREFIX` else `~/.local` when stow is not on `PATH`. The stow
  calls after it use that prefix's binary.
- the stow flag table: `--no-folding` for `gpg`, `ssh`, `bin` and `pi`, plus
  `--ignore='settings\.json'` for `pi`.
- the per-package hooks: `gpg`, `ssh`, `antinote`, `pi`, `claude` and `jj`.

Any `dotfiles/<app>/` directory is automatically installable. The `pi` and
`antinote` hooks call `dotfiles.pi` and `dotfiles.antinote` in process.
`tests/lua/packages_test.lua` pins the module.

`SRC_DIR` (default `<repo>/dotfiles`) and `TARGET_DIR` (default `$HOME`) come
from the `KEY=value` arguments, then the environment, so a test points both at
a temp tree. `dev install nvim TARGET_DIR=/tmp/home` installs into a temp
tree.

`dev install`, `uninstall`, `restow` and `purge` take package names, and the
other verbs take only `KEY=value`. `dev skills` calls `packages.fetch_skills`
and takes no argument.

### dev sync

`.dev/sync.lua` is the project's `dev sync`. It wins over the built-in
lint-template `dev sync`, so `dev __flags sync` offers none of `--check` and
`--yes`.

It takes `SYNC_DST` (`user@host`) and `SYNC_PATH` (the remote folder,
`dotfiles` by default) from the `KEY=value` arguments, then the environment.
Without `SYNC_DST` it asks on a terminal and exits 1 without one.

It pipes the NUL-separated output of `jj file list` (a `.jj` repo) or
`git ls-files -z` into `rsync -azqP --from0 --files-from=-` through
`dev.os.capture_input`. It then runs
`ssh <dst> "cd '<path>' && bash dotfiles/bin/.local/bin/dev install"`, so the
remote `dev` finds its project from its working directory.

The ssh output goes to a `dev.fs.mktemp` log. A successful sync removes the
log and a failed one keeps it (`sync failed; log kept at <path>`, exit 1).
`dev sync SYNC_DST=host` and `SYNC_DST=host dev sync` are the same call.

## The guide and scribe commands

### dev guide

`dev guide` is a built-in verb in the "Set up a machine or project" group. It
is machine-local: `--remote` refuses it, and it refuses to run as root. Only
the form with a question needs the `guide` package installed.

With no question it prints the project's `overview` topic when
`.dev/topics/overview.md` exists (rendered like any topic), then the curated
`dev help`. That is one text that always goes through the pager on a terminal,
like the curated view (`DEV_PAGER=0` turns it off).

With a question it runs `guide dev -- <question>` from the repo root. When
`.dev/topics` exists it adds `--context-dir <root>/.dev/topics`, so the
project's topics are gathered before the rest of the help.

The curated `dev help` has no verb-count cap. It is curated by purpose and
fits a 50-line screen. `board` is shown under "Share it".

The hidden verbs are `bootstrap` (machine-local setup run once), `help`,
`gpgkeys` (the legacy GPG key listing) and dev's own `__` helpers.
`tests/dev/guide_test.sh` pins that exact list, and `dev help -a` still lists
them.

### guide

The `guide <tool> [question]` command lives in the `guide` package. Its
launcher is `dotfiles/guide/.local/bin/guide` and its modules are
`dotfiles/guide/.local/share/guide/*.lua`, which are luajit.

#### The launcher

`guide` is a launcher that does these things in order:

1. Finds `luajit`, else prints the install hint and exits 1.
2. Resolves its own symlink.
3. Sets `GUIDE_DEV_LUA` to the `dev` Lua modules (the dotfiles tree beside it,
   else `~/.local/share/dev/lua`).
4. Keeps the caller's `PAGER` in `GUIDE_PAGER`, its `NO_COLOR` in
   `GUIDE_NO_COLOR` and its `TERM` in `GUIDE_TERM`.
5. Exports `PAGER=cat`, `MANPAGER=cat`, `GIT_PAGER=cat`, `NO_COLOR=1`,
   `TERM=dumb` and `CLICOLOR=0`.
6. Makes the work directory (`GUIDE_WORK`, which `main.lua` uses). The
   launcher's `EXIT`, `INT` and `TERM` traps remove it, so `Ctrl-C` leaves
   none.
7. Runs `luajit .local/share/guide/main.lua`.

luajit has no signal handler of its own, so the launcher runs it as a
background child and waits for it. A foreground child would defer the `TERM`
trap until it ended. The traps end the child and everything it started (a walk
down `pgrep -P`) and exit 143 or 130.

#### The modules

- `main.lua`: the options, the checks, the cache and the scribe calls.
- `help.lua`: parses a help text.
- `probe.lua`: runs tools and the man page through `dev.os.capture_timed`.
- `tree.lua`: reads the top of a help tree.
- `gather.lua`: collects guides, help and the man page.
- `check.lua`: the post-check.
- `progress.lua`: the status line.

`main.lua` runs the gather and check modules as
`luajit gather.lua MODE TOOL ...` and `luajit check.lua TOOL FILE`. Gather
exits 3 when the documentation is over the budget.

#### How a question is answered

A tool follows the help convention when `<tool> help --topics` exits 0 with at
least one `name<TAB>summary` line. Guide then reads its commands from
`help -a`.

A question goes to `scribe guide-answer --profile guide`, with prompts in
`dotfiles/scribe/.config/scribe/prompts/guide-*.md`. The answer is checked
against the live help, with one `warning:` line per made-up subcommand or
flag.

Documentation over `GUIDE_BUDGET` characters (default 60000) takes a second
model call, `guide-pick`, to choose the subcommands to read.

With no question, a tool with no guides gets a model-written overview cached
in `${XDG_CACHE_HOME:-~/.cache}/guide/<tool>/<hash of its version>.md`.
`--refresh` rebuilds it and `--offline` skips the model.

#### Rendering

Everything guide prints as Markdown (an answer, and the cached or fresh
overview) goes through `dev.ui.markdown`. The width is capped at 100 when
standard output is a terminal and colour is on. `dev.ui.context` decides that
over the caller's `NO_COLOR` and `TERM`, read from `GUIDE_NO_COLOR` and
`GUIDE_TERM` to survive the launcher's overrides.

A pipe, `NO_COLOR` or `TERM=dumb` print the text unchanged. The post-check
warnings are written after the rendered answer, one per line.

The offline help text is not Markdown and stays plain. On a terminal with
colour, `style_help` in `main.lua` adds colour codes only:

- it bolds each help heading (a line ending in a colon with nothing after it,
  or all capitals at column zero)
- it cyans each flag that starts an indented line

`--offline` has `gather.lua offline` print its parts (the guide list, each
guide body, the help text), each after a mark line of the control character
0x1e and its kind, which `main.lua` splits. On a terminal with colour it draws
the guide list as a `dev.ui.table` with bold names and each guide body through
`dev.ui.markdown`. A pipe, `NO_COLOR` or `TERM=dumb` print the parts joined,
with the guide list tab separated and each guide body as written.

The whole offline text, man page included, goes through `show` once, so the
pager takes it as one text.

A rendered answer or no-question overview, warnings included, goes through
`dev.ui.page` with the caller's pager from `GUIDE_PAGER` (`less -R` when the
launcher finds no `PAGER`). That happens when standard output is a terminal
and the text is taller than the screen, after the status line is erased.
`--no-pager`, a pipe or a short text print it directly.

#### The man page

The man page keeps its own marks:

- `probe.man_raw` caches `man -P cat` output with the overstrike text as it
  is, in the entry `man-raw`. An older build's stripped `man` entry is never
  read, so its page is fetched once.
- `probe.strip_man` removes the marks as `col -b` does. It serves the model's
  documentation, the post-check and a pipe, `NO_COLOR` or `TERM=dumb`.
- `probe.style_man` turns `X` backspace `X` into bold and underscore backspace
  `X` into underline on a terminal with colour. It writes one pair of codes
  for each run of characters with the same marks.

#### The status line

`progress.lua` draws a status line on standard error, `<label> (<N>s so far)`
in dim. It draws under the same rule as colour (standard error a terminal,
`GUIDE_NO_COLOR` empty and `GUIDE_TERM` not `dumb`), for each step of a run:
reading the help and man page, choosing subcommands, asking the model and
checking the answer.

It is redrawn at each step and not ticked during one (the steps block in
capture calls). It is erased when the step ends or fails, so only the answer
stays. The launcher erases it on `INT` and `TERM`.

A run with standard error piped, `NO_COLOR` set or `TERM=dumb` draws nothing.

#### The cache and probes

`probe.help` and `probe.man` keep each help text and the man page in
`${XDG_CACHE_HOME:-~/.cache}/guide/<tool>/<hash of its version>.docs/`.
`GUIDE_DOC_CACHE` names the directory for the `gather.lua` and `check.lua`
children, and `probe.use_cache` does for the main process. A second question
about one version runs no `--help` probe, only the one `--version` call that
makes the key.

- A probe that hit the time limit is not kept.
- `--refresh` removes every `.md` and `.docs` entry of the tool.
- The `--context-dir` guides and the `help --topics`, `help -a` and `help -k`
  calls are never cached. They can change without a version change.

Every call to the tool has a time limit (`GUIDE_PROBE_TIMEOUT`, default 3
seconds, and 0 sets no limit, as in GNU `timeout`). It runs in its own process
group so the limit also stops what it started, and it reads no stdin.

The `man` call waits at least 10 seconds when the limit is above 0. The guide
calls set `opts.reap`, which kills the group of a call that exits on its own,
so a background child of a finished probe does not stay behind.

#### Signals and timed calls

`dev.os.without_sigpipe(fn)` makes a write to a closed pipe (a pager quit
early, scribe exiting unread) fail instead of killing the process.

`dev.os.on_exit(fn)` registers a cleanup, the Lua match for a bash `trap` on
`EXIT`. Each cleanup runs once, newest first, when the verb returns, when it
raises and when `SIGTERM` or `SIGINT` ends it. A cleanup that raises is
reported on standard error and the rest still run, and the first registration
wraps `os.exit` to run the cleanups before the process leaves.

`main.lua` calls `dev.os.catch_term()`, which hands `SIGTERM` the handler
that LuaJIT's own launcher installs for `SIGINT`. That handler runs no Lua.
It only asks the VM to raise the interrupt error at its next instruction, so
`SIGTERM` takes the same path as `Ctrl-C`.

`dev.os.interrupt_code()` reports 143 for `SIGTERM` and 130 for `SIGINT`. A
signal that arrives while `os.execute` waits on a child takes effect when the
child returns. `SIGKILL` runs nothing.

`dev.os.capture_timed(argv, secs, opts)` is the timed call. It uses no
`timeout` command and no `sleep` in the loop, to keep `os.execute` from
ignoring `SIGINT` while it waits. It does these things:

- Starts a watcher beside the command that blocks reading a pipe the calling
  process holds open, and starts no process while the command runs.
- Enforces the limit in its own poll loop, which sends TERM to the process
  group, waits 1 second and sends KILL.
- Waits for the watcher to start with 5 millisecond `usleep` polls, then polls
  the status with 0.1 second ones.
- Has the watcher kill the command's process group when the pipe reaches end
  of file before the command has finished. That happens when the calling
  process dies (`Ctrl-C`, `TERM` or `KILL`). In every case the watcher then
  removes the temporary directory.
- Sets no limit when `secs` is 0 or less.
- Collects the output, merged with standard error when `opts.merge` is set.
- Kills the process group of a command that exited on its own when `opts.reap`
  is set (scribe and `dev board check` do not set it).
- Takes `opts.input` as standard input, else /dev/null.
- Returns the exit code, 124 when the limit hit or the command was killed.

Tests are `tests/guide/guide.bats`, which put fake tools, a fake `man` and a
fake model command first on PATH.

### scribe

The `scribe <kind>` command has the same launcher shape (`SCRIBE_DEV_LUA`) and
lives in the `scribe` package. Its modules are:

- `.local/share/scribe/main.lua`: the options, the settings and the flow.
- `profile.lua`: walks a profile's `command` and `http` lines in order and
  returns the first answer.
- `backend.lua`: makes the curl chat call, runs a command backend and cleans
  the answer.

The curl call builds its payload with `dev.json` and reads only
`.choices[0].message.content`. A command backend runs through
`dev.os.capture_timed` with the system prompt and context on its standard
input.

Cleaning removes think-blocks and quotes. For `*name`, `*slug`,
`bookmark-*` and `branch-*` kinds it also makes a kebab slug of at most 50
characters.

Profiles and prompts are looked up under `SCRIBE_PROFILES` and
`SCRIBE_PROMPTS` (default `~/.config/scribe/profiles` and `prompts`).
`~/.config/scribe/config` is read as `SCRIBE_NAME=value` lines for any
`SCRIBE_` setting (an optional `export`, one pair of quotes around the value)
and wins over the environment.

Tests are `tests/scribe/scribe.bats`, with a fake `curl` and fake commands
first on PATH.
