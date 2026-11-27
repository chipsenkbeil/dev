# manifest: The tools manifest, install scopes and the package driver

## Overview

`dev tools check` and `dev tools install` read `.dev/tools.tsv` at the project
root. The header of that file documents its columns and cell syntax. A project
without it gets "no .dev/tools.tsv" and exit 0.

```
dev tools check
dev tools install --dry-run
dev tools install --system
dev tools install --user ripgrep
dev tools install --group base --dry-run
dev tools check --group rust
```

`check` reports which tools are on PATH and exits 1 when one is missing.
`install` takes tool names (an unknown one exits 2), `--dry-run`, `--force`
(which needs a name), `--group NAME` and one scope.

## Groups

The last column of the manifest, `groups`, holds a comma-separated list of
group names, or `-` for none. `--group NAME` on `install` and on `check` keeps
only the rows whose list holds NAME. It combines with every scope, `--dry-run`,
`--force` and tool names.

The groups today are `base` (the lint and VCS tools) and `rust` (the Rust
toolchain and its lint set). An unknown group, or a tool named outside the
group, exits 2 and names it. A manifest with no `groups` column has no groups,
so `--group` on it is an unknown group.

## Scopes

- none: installs every row, as on a laptop or in an image build. It runs as a
  user, and root is a usage error.
- `--system`: installs the official package manager rows (bare packages,
  `cask:` and `tap:`). It runs as root on Linux and is refused otherwise.
- `--user`: installs `script:`, `cargo:`, `release:` and `flatpak:` rows, which
  write into the running user's home. It runs as a non-root user and is
  refused at uid 0.

`--system` and `--user` together are a usage error.

`--system` skips `aur:`, `copr:` and `luarocks:` rows and names them in one
line. They run code from a repo outside the distribution, so a box image bakes
them in and an agent never gets root through an AUR build.

## PATH

For `install` and `check`, the driver appends `CARGO_HOME/bin` (else
`~/.cargo/bin`) and `DEV_TOOLS_BIN` (else `~/.local/bin`) to its own PATH. A
row that runs after rustup or cargo-binstall then finds what an earlier row
installed. A tool already on PATH still wins, and root appends nothing.

## Intel macOS

On Darwin with `uname -m` x86_64, `detect_manager` answers the manager
`darwin-x86_64`, so the driver reads the column of that name and never calls
brew. Apple Silicon keeps `brew`. Intel macOS uses neither Homebrew nor
MacPorts.

In that column:

- `-` drops the tool, and `install` and `check` skip it.
- `release:`, `script:` and `cargo:` route to their drivers.
- `system:NAME` names a tool installed outside dev tools, such as the OS or the
  prelude (`dev.pkg.system`, user scope). `install` prints
  `installed outside dev tools` and `check` probes PATH.
- A bare package or any other channel is a manifest error naming the row.
  `check` prints `[ ] <name>` with the reason, and `install` prints
  `! <name>: a darwin-x86_64 cell takes release:, script:, cargo: or system:`
  and fails.

Every tool therefore comes from a `release:` pin, a `script:` row, `cargo:` or
something outside dev tools.

### The base group

The column pins ripgrep, fd, jq, yq, sd, gh, jujutsu, shellcheck, shfmt and
stylua through `release:`. It marks git, zsh and dash `system:`.

It drops difftastic, tokei, watchexec, hyperfine, ast-grep and selene with
`-`. The selene release zip is arm64 only, and `dev lint` runs on ci by
default. The base group needs no cargo on Intel macOS.

### bats and stow

Neither has an x86_64 macOS binary release, and Homebrew is not there to build
them. In the dotfiles repo's `.dev/tools.tsv`, their cells are
`script:scripts/install-bats.lua,bin:-` and
`script:scripts/install-stow.lua,bin:-`. The scripts sit in that repo's
`scripts/` folder, which this repo does not have.

Both scripts are a few lines over `dev.pkg.source`. It takes `--check`,
`[--dry-run]` and `PKG_FORCE`, and reads the pin named after the tool from
`PKG_RELEASES` (the pins file `dev tools` gives every script, else
`.dev/releases.tsv`).

It fetches and verifies the pin through `dev.pkg.release.fetch`, the code the
`release:` channel runs: download, sha256 check and only then extraction. It
then builds in the source directory against the prefix `DEV_TOOLS_PREFIX`, else
`~/.local`. The build uses the Xcode tools and the perl macOS ships:

- bats-core: `bash ./install.sh <prefix>`.
- GNU Stow: `./configure --prefix=<prefix>`, `make` and `make install`.

`--check` exits 0 when the binary is in `<prefix>/bin` or on PATH. The cells
carry `bin:-`, and the row is checked by running the script, so
`~/.local/bin` need not be on PATH. An install does nothing when the binary is
there unless forced.

A dry run prints the download, checksum and unpack lines and then each build
command with its `cd`. The stow script runs through `ensure_stow` when none
is on PATH, and keeps stow as it is when one is.
`tests/lua/pkg_source_test.luau` runs both scripts, kept as the fixtures under
`tests/pkg/fixtures/`, against a stub tarball on a local server and a stub
`make` in a temporary prefix.

### The rust group

The rust rows and their scripts below are the dotfiles repo's. Each rust row
routes on its own:

- cargo-binstall, cargo-deny, cargo-nextest and sccache are `release:` pins
  (cargo-nextest ships one universal build).
- rustup is `script:scripts/install-rustup-darwin.lua,bin:-`. The row is
  checked by running the script, so `~/.cargo/bin` need not be on PATH.
- rustfmt-nightly keeps `scripts/install-rustfmt-nightly.lua`.
- build-tools is `system:cc`.
- zig, cargo-zigbuild and rust-darwin-targets are `-` (only cross builds
  from Linux use them).
- cargo-sort is `cargo:cargo-sort`.

Upstream ships no x86_64 macOS asset for cargo-sort. The cargo driver runs
cargo-binstall, which takes quickinstall's prebuilt build or compiles the
crate. That one install has no sha256 pin.

`scripts/install-rustup-darwin.lua` reads the `rustup-init` pin through
`dev.pkg.release.fetch`, which checks the sha256 before the file is made
executable or run. It runs `rustup-init` with
`-y --no-modify-path --default-toolchain 1.99.1`, the toolchain the lint set
pins, and skips when `rustup` is in `CARGO_HOME/bin` (else `~/.cargo/bin`) or
on PATH. `--check` is that test.

The dotfiles repo's `tests/lua/pkg_pins_rust_test.lua` covers every rust row,
the dry run order and the script against a stub `curl` and a stub
`rustup-init`.

## Ubuntu

On Linux with `apt-get` on PATH and neither pacman nor dnf, the driver reads
the `apt` column. A bare package runs `apt-get install -y -- NAME` through
`env DEBIAN_FRONTEND=noninteractive`, behind `sudo` for a user. The first
install of a run is preceded by one `apt-get update`.

`release:` and `script:` cells route as in the other columns, and a `-` drops
the tool. `dpkg-query` decides what counts as installed, so a package that is
removed with its configuration left behind is installed again.

The column fills the base group, and every other row is `-` except pass and
gnupg. `dev tools install` on Ubuntu therefore installs the base group. The
column is for x86_64 Ubuntu 24.04 (the pins are x86_64 builds).

The packages are `ripgrep`, `fd-find`, `sd`, `jq`, `hyperfine`, `shellcheck`,
`shfmt`, `bats`, `git`, `gh`, `zsh`, `dash` and `stow`. Ubuntu names
the `fd-find` command `fdfind`, so its cell carries `bin:fdfind` and no `fd` is
put on PATH.

The `*-linux` pins in `.dev/releases.tsv` cover what Ubuntu 24.04 lacks or
ships wrongly: `jujutsu`, `yq`, `stylua`, `difftastic`, `watchexec`, `ast-grep`
and `selene`. The `yq` in apt is the Python wrapper, not mikefarah's. tokei is
`-` (Ubuntu has no package and upstream publishes no current Linux build).

### A fresh machine

A fresh Ubuntu machine runs the dotfiles repo's
`bash scripts/prelude/ubuntu.sh`. It installs
`ca-certificates`, `curl`, `git`, `jq`, `stow`, `unzip` and `xz-utils`. Then run
`dev tools install --group base`.

The pins need `curl`, `tar`, `unzip`, `xz-utils` (for watchexec) and
`sha256sum`.

### Without sudo

A user without `sudo` splits the work by scope. Root installs the apt packages,
and the user runs `dev tools install --user` for the pins.

`docs/aide-agent.md` does this for the Aide server, with the package list in
its own script, so root runs no code from the user's clone.

## Pins

A `release:NAME` cell installs a pinned upstream release. `dev.pkg.release`
reads the row `NAME` of `<project root>/.dev/releases.tsv`, beside the
manifest. The columns are name, version, sha256, url with `${version}`, and the
binary's path in the archive (`-` for a bare binary).

As root, `dev tools` copies the manifest and this file into one new folder that
only root can enter, and the driver reads the pins from that folder.

The file is checked when it is read:

- The url is https, or `file://` followed by an absolute path.
- The sha256 is 64 hex digits.
- The path is present exactly when the url is an archive, and holds no `..`.

### Install steps

`release` downloads the url into a `dev.fs.mktemp` directory with
`curl -fsSL --connect-timeout 15 --max-time 600`. It checks the sha256 with
`shasum -a 256` or else `sha256sum`. The url's suffix picks the unpacking:
`.tar.gz`, `.tgz` and `.tar.xz` use `tar`, and `.zip` uses `unzip`.

A `file://` url, such as `file:///srv/mirror/tool-1.2.3.tar.gz`, is copied from
the local path instead of fetched, then checked, unpacked and installed like an
https download. A project can serve a pin from an offline mirror this way, and a
test can serve one from a temp directory. A `script:` source takes the same
`file://` url as an `https://` one: it is copied to a temp file and run.

A mismatch deletes the download and fails with
`The sha256 of <url> does not match the pin. Expected <sum>, got <sum>.`
A binary that is not a regular file inside the unpacked directory (a symlink
out of it included) is refused. A failure therefore leaves nothing in the bin
directory.

The binary is installed with `install -m 755` to a staging name and `mv`d into
`~/.local/bin` (`DEV_TOOLS_BIN` overrides). It is named by the row's binary
column, else the pin's name.

After each install the driver writes a receipt to
`$XDG_STATE_HOME/dev/tools/NAME` (default `~/.local/state/dev/tools/NAME`)
holding the pin's name, version and sha256. A tool in the bin directory is
skipped when its receipt names the pin's version and sha256, and replaced
without `--force` when the receipt is missing or names another. A tool installed
before receipts existed has none, so the first install after the upgrade
reinstalls it once.

A tool on PATH outside the bin directory is skipped unless `--force` (dev
did not put it there), and the skip line names its path. A PATH hit that
resolves to the bin directory's own file counts as the bin directory's tool.

`check` prints `[!] NAME (installed X, pinned Y)` for a tool in the bin
directory whose receipt differs from the pin, or `(no receipt, pinned Y)`, and
exits 1. Otherwise it reports through `lib.report` and counts the bin directory
when it is not on PATH.

`--dry-run` prints the curl, checksum, unpack and install lines, with
`<download>` and `<extract>` for the temporary paths.

`release` is user scope, like `script` and `cargo`. The driver appends the bin
directory and `~/.cargo/bin` to its own PATH as described under PATH.

### Adding a pin

1. Find the x86_64 macOS asset on the project's releases page and put its url
   in a new row with `${version}` in place of the version. A tag with a `v`
   keeps the `v` in the version column.
2. Compute the checksum of the file at that url (a bare binary or an archive).
3. Put the checksum in the `sha256` column. For an archive, give the binary's
   path inside it in the `path` column (`-` for a bare binary).
4. Set the tool's `darwin-x86_64` cell in `.dev/tools.tsv` to `release:NAME`.
5. Check the result.

```
curl -fsSL URL | shasum -a 256
dev tools install --dry-run NAME
dev tools install --force NAME
dev tools check --group base
```

To bump a pin, change the `version` and `sha256` columns of its row and run
the last three commands (with `--group rust` on `check` for a rust-group pin).

## A fresh Intel guest

The guest has the Xcode command line tools, no `brew` and a dotfiles archive
unpacked into its current directory. `dev` finds the project from the
directory holding `.dev` when there is no `.jj` or `.git`, so run these from
the archive root. None of them needs `sudo`.

```
bash scripts/prelude/mac.sh
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
dev tools install --group base
dev tools install --group rust
dev tools check
```

The prelude builds the pinned tools the `base` group needs into `~/.local` and
needs `curl`, `tar`, `make` and a compiler (all from the Xcode tools).

The `base` group needs `curl`, `tar`, `unzip` and `shasum` for the pins, and
Xcode's `perl` and `make` for stow. The `rust` group installs rustup with
toolchain 1.99.1, the nightly rustfmt, cargo-sort and the pinned cargo tools.

### The archive

The dotfiles archive must hold these paths and keep the execute bit on `dev`.
The manifest, prelude and scripts are the dotfiles repo's:

- `dev`, the binary
- `` (the whole directory)
- `.dev/tools.tsv`
- `.dev/releases.tsv`
- `scripts/prelude/mac.sh`
- every local `script:` source in the manifest, cut at the first comma

List the script paths with this command, run in the dotfiles repo, after a
manifest change.

```
rg -o --no-filename 'script:scripts/[^ ",]+' .dev/tools.tsv | sort -u
```

## The driver

`dev tools install` and `dev tools check` are built-in commands for any
project. They run the hidden built-in `dev __pkg` from the project root and
pass the project's `.dev/tools.tsv` as `--manifest`.
The driver refuses `check` and `install` without `--manifest` and exits 2.
Nothing writes into `dev`'s own directory.

The manifest parser is the native `dev.manifest` module (`parse`, `column`
and `select`). The driver reads the manifest, picks the tools, prints the status
lines and runs the install and status commands in Luau. There is one module per
manager under `luau/dev/pkg/`: `brew`, `pacman`, `dnf`, `apt`, `cargo`,
`luarocks`, `script` and `release`.

Every package, repo and channel word reaches a command as one argument, never
through a shell. A package name or repo in a cell must be a plain word (no
leading `-`, no spaces), else the row fails. The pacman and dnf commands put
`--` before it.

### script rows

A `script:` source ending in `.lua` or `.luau` runs as `dev -l <path> <args>`,
with dev's modules available as `@dev/NAME`. Any other source runs as
`bash <path> <args>`. The dry-run line prints whichever was chosen.

The arguments split on blanks and are never glob-expanded, and no shell sees
them. A row for a pinned tool, such as stow or bats, names
`scripts/install-*.lua`. `luau/dev/pkg/script.luau` gives each the pins file as
`PKG_RELEASES`.

### Logs

With `--log-file`, a failed row prints the last 20 lines of the failing
command's output, indented, under its failure line (`dev.pkg.lib` `run` and
`flush_failure`).

### Overrides

`.dev/commands/tools.sh` cannot override the `tools` command. A script such
as `.dev/commands/tools/install.sh` replaces that subcommand for a user, as it
does any built-in subcommand. As root, dev skips the registry and the driver
never runs a project script, so the root step of a box build never executes
project-controlled code. `dev --remote` refuses every `tools` subcommand.

## As root

As root, `dev` works only on Linux and runs only `tools install` and
`tools check`. It finds the project by checking which directories exist and
never runs jj or git.

### Reading the manifest

`dev` reads `.dev/tools.tsv` only when these hold:

- The manifest, `.dev`, the project directory and every directory above it are
  owned by root.
- None of them is a symlink.
- None of them is writable by group or others. A sticky directory such as
  `/tmp` may be above them.

A caller therefore copies the manifest into such a directory first.

`dev` then opens the file once with `O_NOFOLLOW` (and `O_NONBLOCK`, so a FIFO
never blocks) and checks that same descriptor with `fstat`. The file must be a
regular file owned by root, with no group or other write bit, at most 256 KiB.
No line may be over 4096 bytes.

It reads the file from that descriptor, copies it to a root-owned temp file and
gives that copy to the driver.

### Running the driver

The driver runs under a scrubbed environment. `DOTFILES` is ignored and the
driver is the built-in `dev __pkg` of the running binary (`dev.runtime.exe`,
never found through `PATH`).

The driver runs through a constant `sh -c` wrapper. The wrapper takes the copy
and the driver command as arguments and removes the temp copy on exit, `INT`
and `TERM`.

With `-v` or more the driver gets `VERBOSE=<level>`. It never takes anything
from the caller's environment, and no `BASH_ENV` or `PS4` reaches it.

### Usage errors

A bad flag or argument exits 2. As a user it prints the error line and the
curated help on stderr, like any built-in.

As root, which reads no help machinery, it prints the error line and one
`usage: dev tools check [--group NAME]`-style line with the subcommand's
accepted form. `-h` and `--help` are not help as root. They are an unknown
flag, a usage error with that hint (exit 2).
