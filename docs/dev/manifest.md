# manifest: The tools manifest, the install scopes of dev tools and the package driver

`dev tools check` and `dev tools install` read `.dev/tools.tsv` at the
project root. Its columns and cell syntax are documented in the header of
that file. A project without it gets "no .dev/tools.tsv" and exit 0.

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
only the rows whose list holds NAME, and combines with every scope, `--dry-run`,
`--force` and tool names. The groups today are `base` (the lint and VCS tools)
and `rust` (the Rust toolchain and its lint set). An unknown group, or a tool
named outside the group, exits 2 and names it. A manifest with no `groups`
column has no groups, so `--group` on it is an unknown group.

## Intel macOS

On Darwin with `uname -m` x86_64 the driver reads the `darwin-x86_64` column
and never calls brew; Apple Silicon keeps `brew`. In that column `-` drops the
tool, `release:`, `script:` and `cargo:` route to their drivers, `system:NAME`
names a tool installed outside dev tools, such as the OS or the prelude
(`install` prints `installed outside dev tools`, `check` probes PATH), and a
bare package or any other channel is an error naming the row.

bats and stow have no x86_64 macOS release, so their cells are
`script:scripts/install-bats.lua,bin:-` and `script:scripts/install-stow.lua,bin:-`.
Each script downloads the pinned source archive named in `.dev/releases.tsv`,
checks its sha256 before it extracts anything, and builds into `~/.local`
(`DEV_TOOLS_PREFIX` overrides) with the Xcode tools and the perl macOS ships.
`--check` exits 0 when the tool is in that prefix or on PATH.

The rust group on Intel macOS routes each row: cargo-binstall, cargo-deny,
cargo-nextest and sccache are `release:` pins (cargo-nextest ships one
universal build), rustup is `script:scripts/install-rustup-darwin.lua,bin:-` (the row is then checked by running the script),
rustfmt-nightly keeps its script, build-tools is `system:cc`, and zig,
cargo-zigbuild and rust-darwin-targets are `-` (only cross builds from
Linux use them). cargo-sort is `cargo:cargo-sort`: upstream ships no x86_64
macOS asset, so the cargo driver runs cargo-binstall, which falls back to
quickinstall's prebuilt build or else compiles the crate. That one install
has no sha256 pin (cargo-binstall picks the source at run time).
The rustup script downloads the pinned `rustup-init`, checks its sha256 before
running it and installs toolchain 1.99.1, the one the lint set pins, as the
default. `--check` exits 0 when `rustup` is in `~/.cargo/bin` (`CARGO_HOME`
overrides) or on PATH.

The base group needs no cargo on Intel macOS: selene is `-` there (its
release zip is arm64 only, and `dev lint` runs on ci by default).

Intel macOS uses neither Homebrew nor MacPorts. Every tool comes from a
`release:` pin, a `script:` row, `cargo:` or something outside dev tools (`system:`, the OS or the prelude).

## Ubuntu

On Linux with `apt-get` on PATH and neither pacman nor dnf, the driver reads the
`apt` column. A bare package runs `apt-get install -y -- NAME` through `env
DEBIAN_FRONTEND=noninteractive`, behind `sudo` for a user, and the first install
of a run is preceded by one `apt-get update`. `release:` and `script:` cells
route as in the other columns, and a `-` drops the tool. `dpkg-query` decides
what counts as installed, so a package that is removed with its configuration
left behind is installed again.

The column fills the base group, and every other row is `-` except pass and
gnupg, so `dev tools install` on Ubuntu installs the base group. The packages
are `ripgrep`, `fd-find` (Ubuntu names the command `fdfind`, so the cell
carries `bin:fdfind` and no `fd` is put on PATH), `sd`, `jq`, `hyperfine`,
`shellcheck`, `shfmt`, `bats`, `luajit`, `git`, `gh`, `zsh`, `dash` and `stow`.
The `*-linux` pins in `.dev/releases.tsv` cover what Ubuntu 24.04 lacks or
ships wrongly: `jujutsu`, `yq` (apt's `yq` is the Python wrapper, not
mikefarah's), `stylua`, `difftastic`, `watchexec`, `ast-grep` and `selene`. tokei is `-`
(Ubuntu has no package and upstream publishes no current Linux build).
The pins are x86_64 builds, so the column is for x86_64 Ubuntu 24.04.

A fresh Ubuntu machine runs `bash scripts/prelude/ubuntu.sh`, which installs
`ca-certificates`, `curl`, `git`, `jq`, `stow`, `unzip`, `xz-utils` and
`luajit`, and then `dev tools install --group base`. The pins need `curl`, `tar`, `unzip`,
`xz-utils` (for watchexec) and `sha256sum`.

A user without `sudo` splits the work by scope: root installs the apt packages,
and the user runs `dev tools install --user` for the pins. `docs/aide-agent.md`
does this for the Aide server, with the package list in its own script so that
root runs no code from the user's clone.

## Pins

A `release:NAME` cell installs the row `NAME` of `.dev/releases.tsv` into
`~/.local/bin` (`DEV_TOOLS_BIN` overrides). The driver appends that directory,
and `~/.cargo/bin` (`CARGO_HOME` overrides), to its own PATH for `install` and
`check` (not as root), so a row that follows rustup finds `cargo` in the same
run. To add a pin:

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
A checksum mismatch deletes the download and fails without touching
`~/.local/bin`.

## A fresh Intel guest

The guest has the Xcode command line tools, no `brew` and a dotfiles archive
unpacked into its current directory. `dev` finds the project from the
directory holding `.dev` when there is no `.jj` or `.git`, so run these from
the archive root. None of them needs `sudo`.

```
bash scripts/prelude/mac.sh
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
bash dotfiles/bin/.local/bin/dev tools install --group base
bash dotfiles/bin/.local/bin/dev tools install --group rust
bash dotfiles/bin/.local/bin/dev tools check
```

The prelude builds the pinned `luajit` into `~/.local` and needs `curl`,
`tar`, `make` and a compiler (all from the Xcode tools). The `base` group
needs `curl`, `tar`, `unzip` and `shasum` for the pins, and Xcode's `perl`
and `make` for stow. The `rust` group installs rustup with toolchain 1.99.1,
the nightly rustfmt, cargo-sort and the pinned cargo tools.

The archive must hold these paths and keep the execute bit on `dev`:

- `dotfiles/bin/.local/bin/dev`
- `dotfiles/bin/.local/share/dev/` (the whole directory)
- `.dev/tools.tsv`
- `.dev/releases.tsv`
- `scripts/prelude/mac.sh`
- `scripts/install-bats.lua`
- `scripts/install-jjui.lua`
- `scripts/install-muchsync.lua`
- `scripts/install-pi.lua`
- `scripts/install-rust-darwin-targets.sh`
- `scripts/install-rustfmt-nightly.lua`
- `scripts/install-rustup-darwin.lua`
- `scripts/install-stow.lua`

The script paths are every local `script:` source in the manifest, cut at the
first comma. Regenerate them after a manifest change.

```
rg -o --no-filename 'script:scripts/[^ ",]+' .dev/tools.tsv | sort -u
```

The driver appends `CARGO_HOME/bin` (else `~/.cargo/bin`) and `DEV_TOOLS_BIN` (else
`~/.local/bin`) to its own PATH for `install` and `check`, except as root, so a
row that runs after rustup or cargo-binstall finds what an earlier row put
there. A tool already on PATH still wins.

## Scopes

- no scope: every row, as on a laptop or in an image build. Root is a usage
  error.
- `--system`: the official package manager, which is bare packages, `cask:`
  and `tap:` rows. On Linux it needs root.
- `--user`: `script:`, `cargo:`, `release:` and `flatpak:` rows, which write into the
  running user's home. It refuses to run as root.

`--system` and `--user` together are a usage error. `--system` skips `aur:`,
`copr:` and `luarocks:` rows and names them in one line, since they run code
from a repo outside the distribution.

## Where the code lives

dev runs `luajit dotfiles/bin/.local/share/dev/pkg.lua` from the dotfiles
clone that holds dev, from the project root. It reads the manifest and runs the
package manager commands in Lua, one driver module per manager under
`dotfiles/bin/.local/share/dev/lua/dev/pkg/`. Every package, repo and channel
word reaches a command as one argument, never through a shell. A `script:` row's
arguments are split on blanks and never glob-expanded.
`DOTFILES` overrides where that clone is found. A project script cannot replace the `tools` subcommands, so the root step of an image
build never runs project code. `dev --remote` refuses every `tools` subcommand.

## Reference: the driver and the root gate

A built-in noun for any project. `dev tools install` and `dev tools check` read `<project root>/.dev/tools.tsv` (columns and cell syntax are in dotfiles' own manifest) and run the package driver, `luajit dotfiles/bin/.local/share/dev/pkg.lua`, from the dotfiles clone that holds `dev`, from the project root. The driver reads the manifest, picks the tools, prints the status lines and runs the install and status commands in Lua, one module per manager under `dotfiles/bin/.local/share/dev/lua/dev/pkg/` (`brew`, `pacman`, `dnf`, `apt`, `cargo`, `luarocks`, `script`, `release`), and every package, repo and channel word reaches a command as one argument. A `script:` source ending in `.lua` runs as `luajit <path> <args>` with dev's modules on `package.path`, any other source as `bash <path> <args>`, and the dry-run line prints whichever was chosen (this repo's own rows for jjui, pi, muchsync, rustfmt-nightly, bats and stow name `scripts/install-*.lua`; `script.lua` gives each the pins file as `PKG_RELEASES`); the arguments split on blanks and no shell sees them. A `release:NAME` cell installs a pinned upstream release: `dev.pkg.release` reads the row `NAME` of `<project root>/.dev/releases.tsv` (beside the manifest, columns name, version, sha256, url with `${version}`, and the binary's path in the archive or `-` for a bare binary, checked when the file is read: https url, 64 hex digits, a path exactly when the url is an archive, no `..`), downloads the url with `curl -fsSL --connect-timeout 15 --max-time 600` into a `dev.fs.mktemp` directory, checks the sha256 with `shasum -a 256` or else `sha256sum`, and unpacks `.tar.gz`, `.tgz` and `.tar.xz` with `tar` and `.zip` with `unzip` by the url's suffix. A mismatch deletes the download and fails with `sha256 mismatch for <url>: expected <sum>, got <sum>`, and a binary that is not a regular file inside the unpacked directory (a symlink out of it included) is refused, so a failure leaves nothing in the bin directory. The binary is installed with `install -m 755` to a staging name and `mv`d into `~/.local/bin` (`DEV_TOOLS_BIN` overrides), named by the row's binary column, else the pin's name. A tool on PATH or already in that directory is skipped unless `--force`, `--dry-run` prints the curl, checksum, unpack and install lines with `<download>` and `<extract>` for the temporary paths, and `check` reports through `lib.report`, counting the bin directory when it is not on PATH. `release` is user scope, like `script` and `cargo`, and the Intel macOS column pins ripgrep, fd, jq, yq, sd, gh, jujutsu, shellcheck, shfmt and stylua through it. `detect_manager` reads `uname`, then `uname -m` on Darwin, and answers the manager `darwin-x86_64` for an Intel Mac and `brew` for Apple Silicon, so an Intel Mac reads the manifest's `darwin-x86_64` column and never calls brew. In that column a `-` cell drops the tool (`install` and `check` skip it), `release:`, `script:` and `cargo:` route to their drivers, a `system:NAME` cell (`dev.pkg.system`, user scope) names a tool the OS ships, so `install` prints a skip line and `check` probes PATH, and a bare package or any other channel is a manifest error: `check` prints `[ ] <name>` with the reason, `install` prints `! <name>: a darwin-x86_64 cell takes release:, script:, cargo: or system:` and fails. In the base group that column pins the tools above, marks git, zsh, dash and luajit `system:`, and drops difftastic, tokei, watchexec, hyperfine, ast-grep and selene with `-` (selene's release zip is arm64 and lint runs on ci), and builds bats and stow from pinned source archives (`dev.pkg.source`, below). An Intel Mac uses neither Homebrew nor MacPorts. For `install` and `check` (not as root) the driver appends `CARGO_HOME/bin` (else `~/.cargo/bin`) and the bin directory to its own PATH, so a row after rustup finds `cargo` in the same run. With `--log-file`, a failed row prints the last 20 lines of the failing command's output, indented, under its failure line (`dev.pkg.lib` `run` and `flush_failure`). A pin is added by writing a `.dev/releases.tsv` row (the url with `${version}`, the sha256 from `curl -fsSL URL | shasum -a 256`, the binary path in the archive) and `release:NAME` in the tool's `darwin-x86_64` cell, checked with `dev tools install --dry-run NAME` and `--force NAME`, and bumped by changing that row's version and sha256. A fresh Intel guest (Xcode command line tools, no `brew`, an unpacked dotfiles archive as the working directory) runs `bash scripts/prelude/mac.sh`, `export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"`, then `bash dotfiles/bin/.local/bin/dev tools install --group base` and `--group rust`. The archive holds `dotfiles/bin/.local/bin/dev`, `dotfiles/bin/.local/share/dev/`, `.dev/tools.tsv`, `.dev/releases.tsv`, `scripts/prelude/mac.sh` and every local `script:` path of the manifest cut at the first comma (`rg -o --no-filename 'script:scripts/[^ ",]+' .dev/tools.tsv`), and this topic lists them. A project without the file gets "no .dev/tools.tsv" and exit 0. `install` takes tool names (an unknown one exits 2), `--dry-run`, `--force` (needs a name), `--group NAME` and a scope:

| Flag | Rows it installs | User |
|---|---|---|
| none | every row, as on a laptop or in an image build | a user, root is a usage error |
| `--system` | the official package manager: bare packages, `cask:` and `tap:` | root on Linux, refused otherwise |
| `--user` | `script:`, `cargo:`, `release:` and `flatpak:`, which write into the running user's home | not root, refused at uid 0 |

`--system` skips `aur:`, `copr:` and `luarocks:` rows and names them in one line: they run code from a repo outside the distribution, so a box image bakes them in and an agent never gets root through an AUR build. `--system` and `--user` together are a usage error. Except as root, the driver appends `CARGO_HOME/bin` (else `~/.cargo/bin`) and `DEV_TOOLS_BIN` (else `~/.local/bin`) to its own PATH for `install` and `check`, so a row after rustup or cargo-binstall finds what an earlier row installed; a tool already on PATH still wins. `--group NAME` (on `install` and `check`) keeps only the rows whose `groups` column, the manifest's last, lists NAME (`base` and `rust` today); it combines with the scopes, `--dry-run`, `--force` and tool names. An unknown group, or a tool name outside it, is a usage error naming it with exit 2, and a manifest with no `groups` column has no groups. `dev` finds the driver from its own location (`DOTFILES` overrides), so a root-owned copy such as `/usr/local/lib/dotfiles` works, and nothing writes into the dotfiles tree. Every package name and repo in a cell must be a plain word (no leading `-`, no spaces), else the row fails, and the pacman and dnf commands put `--` before it. The `tools` subcommands cannot be overridden by `.dev/tools.sh` or `.dev/tools/install.sh`. As root, `dev` works only on Linux and runs only `tools install` and `tools check`. It finds the project by checking which directories exist and never runs jj or git. It reads `.dev/tools.tsv` only when the manifest, `.dev`, the project directory and every directory above it are owned by root, none is a symlink and none is writable by group or others (a sticky directory such as `/tmp` may be above them), so a caller copies the manifest into such a directory first. It then opens the file once with `O_NOFOLLOW` (and `O_NONBLOCK`, so a FIFO never blocks), checks that same descriptor with `fstat` (a regular file owned by root, no group or other write bit, at most 256 KiB), reads it from that descriptor, requires no line over 4096 bytes, copies it to a root-owned temp file and gives that copy to the driver, which runs under a scrubbed environment (`DOTFILES` is ignored and the driver comes from `dev`'s own location) with the absolute `luajit` the launcher started `dev` with (argv zero, never found through `PATH`). A bad flag or argument exits 2: as a user it prints the error line and the curated help on stderr like any built-in, and as root, which reads no help machinery, the error line and one `usage: dev tools check [--group NAME]`-style line with the subcommand's accepted form. As root `-h` and `--help` are not help: they are an unknown flag, a usage error with that hint (exit 2). The driver runs through a constant `sh -c` wrapper that removes the temp copy on exit, `INT` and `TERM`, taking the copy and the driver command as arguments. With `-vv` the driver gets `BASH_ENV=<dev's share>/xtrace.bash` and dev's fixed `PS4` only when that trace file exists, else it falls back to `VERBOSE=1`, and never anything from the caller's environment. It never runs a project script, so the root step of a box build never executes project-controlled code. `dev --remote` refuses every `tools` subcommand.

The `bats` and `stow` rows of the `darwin-x86_64` column are `script:scripts/install-bats.lua,bin:-` and `script:scripts/install-stow.lua,bin:-`, because neither has an x86_64 macOS binary release and Homebrew is not there to build them. Both scripts are a few lines over `dev.pkg.source`, which takes `--check`, `[--dry-run]` and `PKG_FORCE`, reads the pin named after the tool from `PKG_RELEASES` (the pins file `dev tools` gives every script, else `.dev/releases.tsv`), fetches and verifies it through `dev.pkg.release.fetch` (download, sha256 check and only then extraction, the same code the `release:` channel runs) and runs the tool's build in the source directory against the prefix `DEV_TOOLS_PREFIX`, else `~/.local`: `bash ./install.sh <prefix>` for bats-core, `./configure --prefix=<prefix>`, `make` and `make install` for GNU Stow, on the Xcode tools and the perl macOS ships. `--check` exits 0 when the binary is in `<prefix>/bin` or on PATH, which is why the cells carry `bin:-` (the row is then checked by running the script, so `~/.local/bin` need not be on PATH), and an install does nothing when the binary is there unless forced. A dry run prints the curl, checksum and unpack lines and then each build command with its `cd`. `dev install` runs the same stow script through `ensure_stow` when none is on PATH, and keeps stow as it is when one is. `tests/lua/pkg_source_test.lua` runs both scripts against stub tarballs, a stub `curl` and stub `make` in a temporary prefix.

The rust rows of the `darwin-x86_64` column are routed one by one: cargo-binstall, cargo-deny, cargo-nextest (a universal build) and sccache are `release:` pins, rustup is `script:scripts/install-rustup-darwin.lua,bin:-` (the row is then checked by running the script, so `~/.cargo/bin` need not be on PATH), rustfmt-nightly keeps `scripts/install-rustfmt-nightly.lua`, build-tools is `system:cc`, and zig, cargo-zigbuild and rust-darwin-targets are `-` (only cross builds from Linux use them). cargo-sort is `cargo:cargo-sort` (upstream ships no x86_64 macOS asset): the cargo driver runs cargo-binstall, which takes quickinstall's prebuilt build or compiles the crate, and that one install has no sha256 pin. `scripts/install-rustup-darwin.lua` reads the `rustup-init` pin through `dev.pkg.release.fetch` (sha256 checked before the file is made executable or run), runs it with `-y --no-modify-path --default-toolchain 1.99.1`, the toolchain the lint set pins, and skips when `rustup` is in `CARGO_HOME/bin` (else `~/.cargo/bin`) or on PATH. `--check` is that test. `tests/lua/pkg_pins_rust_test.lua` covers every rust row, the dry run order and the script against a stub `curl` and a stub `rustup-init`.

