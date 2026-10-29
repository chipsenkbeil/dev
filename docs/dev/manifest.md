# manifest: The tools manifest and the install scopes of dev tools

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
names a tool the OS ships (`install` does nothing, `check` probes PATH), and a
bare package or any other channel is an error naming the row.

bats and stow have no x86_64 macOS release, so their cells are
`script:scripts/install-bats.lua,bin:-` and `script:scripts/install-stow.lua,bin:-`.
Each script downloads the pinned source archive named in `.dev/releases.tsv`,
checks its sha256 before it extracts anything, and builds into `~/.local`
(`DEV_TOOLS_PREFIX` overrides) with the Xcode tools and the perl macOS ships.
`--check` exits 0 when the tool is in that prefix or on PATH.

The rust group on Intel macOS routes each row: cargo-binstall, cargo-deny,
cargo-nextest and sccache are `release:` pins (cargo-nextest ships one
universal build), rustup is `script:scripts/install-rustup-darwin.lua,bin:-` (the row is then checked by running the script, so `~/.cargo/bin` need not be on PATH),
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
