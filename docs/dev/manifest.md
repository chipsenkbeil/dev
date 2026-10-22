# manifest: The tools manifest and the install scopes of dev tools

`dev tools check` and `dev tools install` read `.dev/tools.tsv` at the
project root. Its columns and cell syntax are documented in the header of
that file. A project without it gets "no .dev/tools.tsv" and exit 0.

```
dev tools check
dev tools install --dry-run
dev tools install --system
dev tools install --user ripgrep
```

`check` reports which tools are on PATH and exits 1 when one is missing.
`install` takes tool names (an unknown one exits 2), `--dry-run`, `--force`
(which needs a name) and one scope.

## Scopes

- no scope: every row, as on a laptop or in an image build. Root is a usage
  error.
- `--system`: the official package manager, which is bare packages, `cask:`
  and `tap:` rows. On Linux it needs root.
- `--user`: `script:`, `cargo:` and `flatpak:` rows, which write into the
  running user's home. It refuses to run as root.

`--system` and `--user` together are a usage error. `--system` skips `aur:`,
`copr:` and `luarocks:` rows and names them in one line, since they run code
from a repo outside the distribution.

## Where the code lives

dev runs `scripts/pkg.sh` from the dotfiles clone that holds dev, from the
project root. `DOTFILES` overrides where that clone is found. A project
script cannot replace the `tools` subcommands, so the root step of an image
build never runs project code. `dev --ci` refuses every `tools` subcommand.
