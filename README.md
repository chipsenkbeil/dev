# dev

`dev` is one command for the work a repository needs: lint, test, format,
build, push, pull, land and the project's task board. A project adds its own
commands, help pages and settings under `.dev/`, and `dev` runs them beside
its built-ins.

`dev` is a Rust binary with an embedded Luau runtime. Project commands are
Luau or shell scripts in `.dev/commands/`.

## Install a release binary

Each release on https://github.com/chipsenkbeil/dev/releases carries one
binary per target, named `dev-TAG-TRIPLE`, and a `SHA256SUMS` file:

- `dev-TAG-x86_64-unknown-linux-musl`
- `dev-TAG-aarch64-apple-darwin`
- `SHA256SUMS`

Download the binary for your machine and `SHA256SUMS` with the `gh` client.
Replace `TAG` and `TRIPLE` with the release tag and your target.

```sh
gh release download TAG --repo chipsenkbeil/dev \
    --pattern 'dev-TAG-TRIPLE' --pattern SHA256SUMS
```

Check the binary against `SHA256SUMS` (on Linux with GNU coreutils, use
`sha256sum` in place of `shasum -a 256`). The command prints `OK` for the
file and ignores the other line in `SHA256SUMS`.

```sh
shasum -a 256 -c --ignore-missing SHA256SUMS
```

Make the binary executable, move it to a directory on your `PATH` as `dev`
(replace `DIR` with that directory), then run `dev` to see the curated help.

```sh
chmod +x dev-TAG-TRIPLE
mv dev-TAG-TRIPLE DIR/dev
```

## Build from source

`rust-toolchain.toml` pins the Rust toolchain, and `rustup` installs it on
the first build. The binary is `target/release/dev`, to copy onto your
`PATH` as above.

```sh
cargo build --locked --release
```

## Documentation

`docs/` holds the guides. Each is also a help topic, and `dev help --topics`
lists them.

- `docs/overview.md`: what dev is and where to start
- `docs/commands.md`: how the files in `.dev/commands/` become commands
- `docs/modules.md`: the dev modules a command can require
- `docs/porting.md`: port a `.dev` bash command to Luau
- `docs/flags.md`: the global flags, help flags and how the launcher
  starts dev
- `docs/remote.md`: run a command somewhere else, by default or with
  `--remote`
- `docs/boards.md`: every `dev board` subcommand
- `docs/forge.md`, `docs/manifest.md` and `docs/boxes.md`: `dev push` and
  `dev pull`, the tools manifest, and dev boxes

`.dev/README.md` lists the commands this repo defines, and `CONTRIBUTING.md`
describes the checks that run over the repo.

## License

See `LICENSE-APACHE` and `LICENSE-MIT`.
