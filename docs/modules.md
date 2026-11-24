# modules: The dev modules a command can require

## dev modules

The native and Luau modules of `dev`, one per item.

## Native modules

The Rust host registers these modules under `@dev/*` before any Luau runs, and
`require("@dev/NAME")` returns them first. A nested module is `@dev/a/b`. The
old dotted form `require("dev.NAME")` is refused with a message that names the
`@dev/` spelling. An expected failure returns `nil,
reason`, and misuse (a wrong argument type) raises `bad argument #N to 'fn'`. An
error a native function raises reaches Luau as userdata, so call `tostring` on
it before string methods. At `-vvv` every native call writes `+ dev.MODULE.FN`
to standard error.

### @dev/runtime

- `load(source, chunkname?, env?)`: compile a chunk, `nil, err` on a syntax
  error. With `env` the chunk runs in that table.
- `dofile(path)`: run a file and return its values, raising on any error.
- `asset(path)`: an embedded file (`luau/dev/...`, `docs/...` or `init/...`) or
  nil.
- `assets(path)`: the sorted names of the direct children of an embedded
  folder, `{}` for anything else.
- `signatures()`: every registered native function as `{ module, name,
  signature, docs }`.
- `parse_globals(words)`: read dev's global flags from `words`, the command
  line after the program name, with the code the binary starts with. It
  applies them (`-C`, `--agent`, verbosity) and returns a table shaped like
  `dev.globals`, or nil and the usage message. A `dev -l` script that runs
  `dev.cli.main` on its own words calls it, so it reads the flags exactly as
  the binary does.
- `exe`: the canonical path of the running binary.
- `version`: the crate version, which `dev.version` reads.
- `loaded`: the `require` cache, keyed by `@dev/NAME` for a dev module and by
  the file's real path for any other.

### @dev/globals

A table of the parsed global flags: `args`, `after`, `dashed`, `remote`,
`detach`, `priority`, `job_timeout`, `local_flag`, `env_local`, `conflict`,
`level`, `quiet`, `stripped` and `agent`. `dev.cli.main` receives it.

### @dev/os

- `getenv(name)`, `setenv(name, value?)` (nil unsets) and `vars()`.
- `name()` is `Darwin`, `Linux` or `Windows`. `arch()`, `getpid()`, `getuid()`
  and `isatty(fd)`.
- `nap(secs)`, `monotonic()` and `random_bytes(n)`.
- `append_path(dirs)`, `which(name)`, `quote(arg)`, `command(argv)` and
  `kind_of(mode)`.
- `defaults = { env, unset, show }`, read at every spawn.
- `run(argv, opts)` returns the exit code, and `capture(argv, opts)` returns
  `out, code`. `capture_input(argv, input, opts)` and `capture_timed(argv,
  secs, opts)` add standard input and a time limit.
- The `opts` table of `run`, `capture`, `capture_input`, `capture_timed`, `exec`
  and `spawn` takes these fields: `env` (variables to set over dev's own),
  `unset` (variable names to remove), `cwd` (the folder to run in), `stdin`
  (`"null"` for /dev/null, the only value), `stdout` and `stderr` (`"null"`,
  `"inherit"` or a file path). `capture_input` and `capture_timed` take neither
  `stdin` nor `stdout`, and `capture_timed` adds `input` (text for its standard
  input) and `merge`. `stderr = "stdout"` merges standard error into standard
  output. A path in `stdout` or `stderr` is opened for append and created when
  missing, so an existing file keeps its content, and a caller that wants a
  fresh file makes it first with `dev.fs.mktemp`.
- `exec(argv, opts)` replaces dev and returns only on failure.
- `spawn(argv, opts)` starts a child without waiting and returns a process
  with `pid`, `wait(secs?)` and `kill(sig)`. `opts.detach` starts a new
  session that outlives dev.
- A SIGINT, SIGTERM or SIGHUP to dev reaches these children:
  - A `run`, `capture` or `capture_input` child shares dev's process group. It
    gets SIGTERM always. It gets SIGINT or SIGHUP when another process sends
    it to dev's pid alone, such as `kill -INT PID`. A terminal's Ctrl-C or
    hangup already reaches it through the group, so dev adds no second copy.
    A signal that another process sends to dev's whole group reaches it twice.
  - A `capture_timed` child leads its own group, and dev signals that whole
    group with the same signal.
  - A `spawn` child is not a foreground child. It is stopped with SIGTERM when
    dev exits, except with `opts.detach`, which outlives dev.
  - SIGKILL to dev runs no cleanup and reaches no child. A caller kills dev's
    process group instead.
- `stdout` and `stderr` with `write` and `flush`, and `stdin` with `read`.
- `exit(code?)`, `on_exit(fn)`, `run_cleanups()`, `interrupt_code()`,
  `SIGNAL_EXIT_BASE` (128) and `EXEC_FAILED` (126).

### @dev/fs

- `exists`, `is_dir`, `is_file`, `is_link` and `is_exec` test a path.
- `read(path)`, `write(path, text, { mode?, atomic? })` (`mode` is a decimal
  integer such as `493` for 0755, written `tonumber("755", 8)` in Luau, and
  applies to the new file) and
  `append(path, text)`.
- `mkdir`, `remove`, `move`, `list`, `stat`, `realpath`, `readlink`, `mktemp`,
  `symlink` and `chmod(path, mode)`.
- `join`, `dirname` and `basename` build and split paths.
- `open_nofollow`, `fstat`, `read_fd` and `close` read a file without
  following a link.
- `Kind` names the kinds of a path.

### @dev/lock

- `lock(path, { shared?, timeout?, mode? })` waits for a file lock and returns
  a handle.
- `try_lock(path, opts)` returns at once.
- `handle:release()` frees the lock.

### @dev/hash

- `sha256(text)` returns the hex digest.
- `sha256_file(path)` returns it for a file, or `nil, reason`.

### @dev/http

- `request{ method, url, headers?, body?, file?, timeout?, connect_timeout? }`
  returns `{ status, headers, body }`, or `nil, reason, kind`. A non-2xx status
  is a normal result. `kind` is `resolve`, `connect`, `timeout`, `tls` or
  `other`.
- `download{ url, path, headers?, timeout?, progress? }` returns `{ status,
  headers }` or `nil, reason, kind`. A `file://` url with an absolute path is
  copied with status 200 and no headers, and `progress` is called as for a
  fetch.

### @dev/json

- `decode(text)` and `encode(value)`.
- `null` is the null sentinel, `object()` makes an object, and `is_object` and
  `present` test values.

### @dev/toml

- `parse(text)` returns a tree, or `nil, "LINE: reason"`.
- `set(text, key, value)` sets a dotted key, and `SetRefusal` names why it
  refuses.
- `encode(tree)` writes a tree as TOML.

### @dev/manifest

- `parse(text)` reads a tools manifest, and `column` and `select` read one
  column of a row and pick the rows.

### @dev/term

- `TTY_PATH`, `DEFAULT_COLS` and `Key`.
- `raw`, `silent`, `open_tty` and `close` manage raw mode, which is always
  restored.
- `size()` and `decode` and `read_key` read the screen and the keys.
- `page(text, opts)` shows text in the built-in pager and returns whether it
  did. `move_to(row, col)`, `clear()` and `alt_screen(on)` move the cursor and
  switch the screen.

### @dev/spec

- `validate(spec)` checks a `dev.command` spec and returns it, or `nil,
  reason`. When the spec declares a flag that takes `--help` or `-h`, a third
  value, `Reason.RESERVED_FLAG`, says so. `Reason` is the closed set of those
  codes.
- `parse(spec, argv)` returns `opts, args, passthrough`, or `nil,
  usage_message`.

## Luau modules

### Commands and dispatch

- `@dev/cli`: dispatch.
- `@dev/command`: the command spec contract (`dev_command({...})`, the helpers
  `usage_error`, `no_args`, `say`, `relay`, `note`, `die`, `show`, `need`).
- `@dev/cmd/types`: the project type's built-ins and the command lines
  `dev help <command>` prints for them.
- `@dev/cmd/tools`: `tools install` and `tools check`.
- `@dev/cmd/land`: `land`, which reads the card from the workspace name through
  `dev.scm` and `dev.board`, refuses it through the card's `land_problem`,
  hands it to the `board land` command, or lands a plain change when the
  project has no board.
- `@dev/cmd/box`: the `box` subcommands, the time-left text and the `ci box`
  call.
- `@dev/cmd/config`: `config`, the first-run wizard for the user config. See
  `dev help flags`, the config command section.
- `@dev/cmd/connect`: `connect` and `box connect`.
- `@dev/cmd/init`: `init` with `--name` and `--dry-run`. It sets up version
  control, the `[board]` section of `.dev/config.toml` named for the project
  and the `origin` remote hint, prints the `would create:`, `created:` and
  `skipped:` lines and the summary, then the Pomb board hint and its note that
  Pomb refused the token, and skips what exists. It writes
  no lint file, style guide, README, CI jobs file or `.editorconfig`, takes
  no `--type` and sets up no Gerrit project. The board hint reads
  `[board.pomb] url` (after `POMB_URL`) and `token` from the user config and
  is skipped when either is unset. None of the keys has a default.

### Board

- `@dev/cmd/board`: the `board` subcommands and the one place that turns a
  result into output and an exit code.
- `@dev/board`: the column names and short forms, the card-id prefix match, the
  size label, the table lines and the `dev.board.Backend` interface the
  commands call. It is also the board half of dev's public API for commands.
  `board.find(workspace)` returns a board with `find_card`, `release_column`
  and `done_column`, and a card found on it has `land_problem`, `carry_proof`,
  `move_to`, `move_to_release` and `move_to_done`. `land_problem` returns why
  the card cannot land, from its column, claimant, outcomes, check and reviews,
  or nil, and lands nothing. `carry_proof` writes the card's check and reviews
  onto a rebased commit. `move_to` into Release or Done refuses a card its
  check, reviews and outcomes do not prove, read at the working-copy commit or
  at the state a caller passes. A command calls them in its own order.
- `@dev/scm`: the source control half of that API, a new module over `dev.vcs`
  and `dev.board.land`. `scm.workspace(root)` returns a workspace with `name`,
  `is_dirty`, `touched`, `holds`, `state`, `rebase` and `merge_into_trunk`.
  `board land` runs on it.
- `@dev/board/render`: the color terminal table and summary `board ls` prints.
- `@dev/board/guards`: the refusals and guards the `board` subcommands run
  before they act, and the usage and failure results they return.
- `@dev/board/runner`: a runner's size limit and refusals, the full-column
  result and the claim a `take` makes.
- `@dev/board/wait`, `@dev/board/ship`, `@dev/board/stale`,
  `@dev/board/runcard`, `@dev/board/setup`: the `board wait`, `ship`, `stale`
  and `run` subcommands and the board setup helpers, split out of
  `@dev/cmd/board` to keep it below the local-variable limit of one chunk.
- `@dev/board/wiring`: the flag parsing and rows behind `board check`, and the
  landing problems, turn wait and held landing behind `board land`.
- `@dev/board/pomb`: that interface over curl. The token comes from
  `DEV_BOARD_TOKEN`, then the file for `DEV_AGENT`, then `pass`, and goes to
  curl on standard input.
- `@dev/board/tokenfile`: the role token files `dev board token mint` writes.
  It holds the directory, the name by a hash of the agent, the 0600 write,
  the read, the delete and the sweep of expired files.

### Workspaces

`dev.cmd.ws` holds `ws new NAME`, `ws ls`, `ws adopt PATH`, `ws rm NAME` and
`ws prune`. `ws` is machine-local, so `--remote` refuses it.

The path of a workspace is `DEV_WS_ROOT`, else `~/.local/share/workspaces`,
then the project folder's name, then NAME. A path that exists is refused with
exit 1. A project inside the central root is named by its folder just below
the root, so a workspace makes siblings. Any other folder is named by its main
repo's folder, so a secondary jj workspace or a git worktree outside the root
shares the main checkout's name.

`ws new NAME` refuses with exit 1 and makes nothing when the project root
holds no `.jj`, `.git` or `.dev`, which is a folder outside any project.
Otherwise it works by project kind:

- A jj project first fetches its remote of record (`forge.resolve`, then
  `jj git fetch --remote NAME`). A failed fetch exits 1 with its output and
  adds nothing. The fetch, the remote listing and the `jj git root` read run
  with `--ignore-working-copy`, so a stale calling workspace does not stop
  them. The calling workspace then runs
  `jj workspace update-stale`, which changes nothing in a fresh one. In a
  colocated project, a prunable git worktree record for the path of NAME is
  pruned first, but when another prunable record would drop with it the command
  exits 1 and names it. The project then gets
  `jj workspace add --name NAME -r trunk()`.
- A git project fetches its remote of record the same way (`git fetch
  NAME`), and a failed fetch exits 1 and adds nothing. It then gets
  `git worktree add --no-track -b NAME PATH REMOTE/TRUNK`, where TRUNK is the
  `master` or `main` branch the remote holds, and a remote with neither exits
  1. A git project with no remote of record exits 1 and adds nothing.
- A folder with only `.dev` gets a plain directory.

The path is printed. `ws ls` prints each folder under ROOT/<repo> as its name,
a tab and its path.

`ws adopt PATH` calls `ws.adopt(root, path, opts)` and moves a workspace folder
of the project into ROOT/<repo>/<name>, where name is the jj workspace name or
the worktree folder's name. It returns the same result table as `ws.remove`.
jj cannot relocate a workspace, as `jj workspace list` keeps naming the old
folder after a hand move. So a jj workspace is read first, refreshed with
`jj workspace update-stale` and refused with `DIRTY` when its `@` holds changes.
Then `adopt` runs `jj workspace forget NAME` and `jj workspace add --name NAME`
at the new path on the parent of `@`, or on `@` itself when it is already on
trunk. The old folder goes to the trash as `ws rm` does, and the line is
`Adopted NAME at TARGET. Moved PATH to TRASH.` When the add fails, the
workspace stays forgotten and its folder stays where it was, and the refusal
names that folder. A git worktree moves with `git worktree move PATH TARGET`
and may hold changes. `adopt` refuses a PATH that is not a workspace of this
project (`NOT_WORKSPACE`), one already under the central root (`ADOPTED`), the
folder dev runs in, and a target that exists (`EXISTS`), and moves nothing.

`ws rm NAME` calls `ws.remove(root, name, opts)`. It returns a result table with
`ok`, `message`, `code` and `purged` instead of dying, and `opts.inside` skips
only the refusal of the workspace dev runs in, which `dev board land` uses when
it removes the card's workspace. With `opts.inside` a jj workspace whose `@`
holds a change already on trunk is first moved to a new change on trunk.

The lookup runs in order: the folder `ROOT/<repo>/NAME` for the checkout's own
folder name, then, from any workspace of the repo including a sibling, the
folder `jj workspace root --name NAME` lists. The listed folder is taken only
when it sits directly under a folder of `ROOT`, so a checkout named
`host-setup` removes the workspace at `ROOT/hosts/NAME`. The trash entry goes
under the folder the workspace sat in. The forget runs with
`--ignore-working-copy` to keep a stale main checkout from stopping it. A
failed forget or prune keeps the folder, and the message names the command's
`Error:` line or else its first line of output.

It refuses a NAME that is missing, a link, outside the central root or the
workspace dev runs in, and a folder whose jj `@` is not empty and has no
description or whose `git status --porcelain` is not empty. A described
working-copy commit counts as committed here and in `ws prune`, but `ws adopt`
still refuses it.

It deletes nothing it can rename instead. It first moves the folder (ignored
files included) to `ROOT/.trash/<repo>/NAME-<UTC stamp>`, where the stamp reads
`YYYYMMDDTHHMMSSZ`, and then runs `jj workspace forget NAME` or `git worktree
prune` from the project's main folder. After a forget in a colocated repo it
also runs `git worktree prune`, which drops the git record jj leaves, and
ignores a failure there. A plain folder is only moved.

Before the move, `ws rm` runs `jj workspace update-stale` in a jj folder to
refresh a stale working copy, and then treats a working-copy commit that is
already on trunk as holding no changes. `ws prune --dry-run` does not refresh.
It reads a stale workspace with `--ignore-working-copy` and plans the same
removal.

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

Before the move, `opts.warn` gets one line for each process whose working
directory is the folder or under it, `Process PID (COMMAND) is still inside
PATH.`, and `ws rm` writes it to standard error. The removal goes on and no
process is killed. `ws.__processes_proc` finds them on Linux from the
`/proc/PID/cwd` links, and `ws.__processes_lsof` on macOS from `lsof -a -d cwd
-F pcn`.

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
and its line ends with the first line of their error. A workspace whose folder
exists and whose name is not the short id of a Done card gets a `Left workspace
NAME alone.` line (`worktree` for git) and counts in the closing `Left N items
alone`, in a dry run and a real one. The workspace of a Done card whose
folder is elsewhere gets the same line, with the reason
`Its folder is not where ws new puts it.` Ignored files do not count as
changes, as with `ws rm`. A project with no board, or a board that cannot be
read, skips the card test and says so. A board setting that is invalid stops
prune with exit 1 before any change. `dev.cmd.board.finished(root)` lists the
Done short ids.

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

- `@dev/toml`: native, see above. `toml.set` adds a string, integer or list of
  strings under its section by a dotted key and makes the section when
  absent. It returns a `toml.SetRefusal` reason when the key is set, is not a
  plain dotted key, or would leave a file that does not parse.
- `@dev/config`: `config.get(root, "a.b")` reads `~/.config/dev/config.toml`
  and then `<root>/.dev/config.toml` over it. `config.user("a.b")` reads the
  user file alone. `config.prefer_user(root, key)` reads the user file first
  and the project file second. A malformed file is
  `<path>:<line>: <reason>` with exit 1, and as root no file is read.
- `@dev/root`: the command words dev may run as root (`tools install` and
  `tools check`) and the checked manifest copy.
- `@dev/remote`: `--remote`.
- `@dev/fetch`: the `# fetch JOB FILE` and `# patch JOB FILE` command
  headers. `fetch.pull(root, spec)` runs the job on ci for this host's
  platform and returns the pulled file, and `dev.cli` hands it to the command in
  `DEV_FETCHED`. `fetch.apply(root, spec)` runs a patch job on its first listed
  target and applies the pulled patch at the project root (`dev help remote`).
- `@dev/registry`: the registry of commands.
- `@dev/version`: `current` reads `dev.runtime.version`, and
  `compare` orders two `MAJOR.MINOR.PATCH` strings. `dev.cli` refuses a
  project whose `[dev] min_version` is newer (`dev help flags`).
- `@dev/xdg`: `state_home`, the one place that resolves `XDG_STATE_HOME`. It
  falls back to `$HOME/.local/state` when the variable is unset or not
  absolute. The board claims, the board store, `dev.board.tokenfile` and
  `connect` append their own subpath.

### Help and completion

- `@dev/help`: `dev help` and the help every command's `-h` and `--help`
  print, drawn from the command's spec. `dev.cli` and `dev.command` turn an
  `interrupted!` error into exit 130 with nothing on standard error.
- `@dev/complete`: what `dev __complete` prints. It walks the typed words
  through the registry and the command spec, and completes command words, flag
  names, flag values and arguments. `dev.complete.board_card`, `board_column`,
  `box` and `file` are the providers a spec names in `complete`, and
  `dev.complete.scripts` holds the four shell scripts `dev completion` prints.
  A provider that errors prints nothing. See `dev help commands`.
- `@dev/topics`: the help page files, read from the embedded `docs/` and the
  project's `.dev/help/`, and the check behind `dev help --check-topics`.

### Test support

- `@dev/testing`: `test(name, fn)` registers a case, and `eq`, `ok` and
  `raises` assert. These moved from `tests/lua/testing.lua`.
- `@dev/testrun`: `run(root)` runs every `root/.dev/tests/*_test.luau` sorted,
  and each file finds the project's `.dev/lib` through its `.luaurc`. It
  prints `ok - NAME` and `not ok - NAME` with the error, and returns 1 when a
  case failed or a file failed to load. When the directory is missing it prints
  `SKIP .dev/tests (none)` and returns 0. `execute(from, only)` is the loop
  `tests/lua/run.luau` calls.
- `@dev/testenv`: the helpers a project test uses.
  - `tempdir`: a temporary directory for one test.
  - `fake(root, name, {code, out, err})`: writes an executable
    `root/bin/NAME` that prints `out` and `err`, appends its arguments to
    `root/bin/NAME.log` and exits `code`.
  - `calls(root, name)`: the logged lines.
  - the launcher helper, called with `(root, words, opts)`: runs the dev
    launcher in `root` with `root/bin` first on PATH and `opts.env`. It
    returns `out, code, err` with standard error apart.

  `tests/lua/projtest_test.lua` pins all three helpers.

### System, release and terminal

- `@dev/os`: native, see above.
- `@dev/release`: the session the release installers under `scripts/` share.
  It holds the parsing of `--dry-run [version]`, the latest-tag lookup, the
  platform names, `step` that runs or prints a command, and a scratch
  directory removed at the end.
  A `die` prints `  ! install-<tool>: <message>` and exits 1.
- `@dev/term`: native, see above. It adds the built-in pager and cursor moves.
- `@dev/text`: display width, `fit`, `trim`, `words`, `index_of`, `contains`
  and `wrap`. `wrap` is the one greedy word wrap that confirm and
  `dev.ui.markdown` share, and it leaves a word wider than the width on a line
  of its own.

### Terminal UI

- `@dev/ui`: colors, tables, bars, confirm and spin. Confirm wraps the
  consequence to the terminal width above the `[y/N]` question.
- `@dev/ui/markdown`: one function, `markdown(text, {width, color})`, that
  returns the text styled for a terminal.
- `@dev/ui/picker`: a list picker, with the keys and windowing below.

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

### Modules a command may require

A project or global command (`.dev/commands/*.luau` or
`~/.config/dev/commands/*.luau`) may `require` these modules and call the
functions listed under each. The list is what `.dev` calls
today, and the test `tests/lua/modules_contract_test.luau` reads it, so it
fails when a listed module or function goes away.

- `@dev/command`: `die`, `need`, `no_args`, `note`, `say`, `show`,
  `usage_error`.
- `@dev/config`: `get`, `user`.
- `@dev/fs`: `basename`, `dirname`, `exists`, `is_dir`, `is_exec`, `is_file`,
  `is_link`, `join`, `list`, `mkdir`, `mktemp`, `read`, `readlink`, `realpath`,
  `remove`, `symlink`, `write`.
- `@dev/help`: `bad_argument`, `overview_text`, `page`, `topic_text`,
  `usage_error`.
- `@dev/json`: `decode`, `encode`.
- `@dev/os`: `capture`, `capture_input`, `capture_timed`, `command`, `exec`,
  `getenv`, `getpid`, `getuid`, `isatty`, `name`, `nap`, `on_exit`, `quote`,
  `run`, `which`.
- `@dev/pipelines`: `jobs`.
- `@dev/project`: `detect_type`, `root`.
- `@dev/registry`: `load`.
- `@dev/release`: `env`.
- `@dev/remote`: `ci_runner`, `is_remote_host`.
- `@dev/runtime`: `asset`, `assets`, `dofile`, `load`,
  `parse_globals`, `signatures`.
- `@dev/standalone`: `problems`.
- `@dev/testenv`: `calls`, `command`, `fake`, `tempdir`.
- `@dev/testing`: `eq`, `ok`, `raises`, `test`.
- `@dev/testrun`: `execute`, `run`.
- `@dev/text`: `fit`, `trim`, `words`, `wrap`.
- `@dev/ui`: `confirm`, `context`, `table`.
- `@dev/ui/picker`: `run`.
- `@dev/vcs`: `backend`, `base`, `branches`, `files`, `remotes`, `require`,
  `with`.
- `@dev/xdg`: `state_home`.

`@dev/runtime` field `exe` is a string, not a function: the path of the
running dev binary, which a command passes to `@dev/os` `run` to start dev
again.

Every other module under `dev` is internal and may change without notice.

