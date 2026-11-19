# nouns: How nouns and the scripts in .dev/ become verbs

`dev <verb>` runs `.dev/<verb>.lua` or `.dev/<verb>.sh` at the repo root. A
`.sh` script must be executable, a `.lua` script needs no exec bit, and the
`.lua` file wins when both exist.

A script replaces a built-in of the same name, and `dev help -a` marks it
`(override)`. A script that matches no built-in is a local verb.

`dev land` is the one land verb, so a project's `.dev/land.lua` replaces the
built-in whole and owns its own turn, landed note and move to the release
column. `dev help land` marks it `(override)`.

Every verb that works in a repository supports jj when the repo uses it and git
otherwise, a worktree included. That holds for a project script and for a
built-in alike, and a new verb ships with both.

```
dev help -a
dev help lint
```

## Nouns

`dev <noun> <sub>` runs `.dev/<noun>/<sub>.sh` (or `.lua`). A directory of
executable scripts is a noun, unless a flat `.dev/<noun>.sh` takes the whole
name, and dev then warns once that the script shadows the directory.

A built-in noun (`dev tools`) keeps its subcommands. A project script never
replaces them, but it can add new ones. A noun with no subcommand, or an
unknown one, exits 2 and lists the subcommands.

Nouns nest to any depth. `.dev/<noun>/<sub>/<sub2>.sh` runs as
`dev <noun> <sub> <sub2>`, and a directory of scripts inside a noun is a noun
too, with its own `DESCRIPTION`, listing and exit 2. `dev help`,
`dev __subs` and `dev __flags` take one word per level.

A command word has no hyphen. A hyphen reads as two words, so a name such as
`install-tools` is a noun and a subcommand (`dev box tools install`). Flags
keep their hyphens.

The first line of `.dev/<noun>/DESCRIPTION` describes the noun. Without it,
`dev help` lists the subcommand names.

## Reserved folders

`.dev/lua`, `.dev/topics` and `.dev/standalone` are never nouns, and dev lists
and runs nothing inside them. `standalone` holds shell that must run where dev
cannot.

Line 2 of each script there reads
`# standalone: runs on <where>, where dev is absent`. `dev help porting` has
the list of places.

## Header lines

dev reads the comment block under the shebang of each script.

- the first comment line is the description in `dev help`.
- `# flags: --a --b` declares the flags that `dev help <verb>` and shell
  completion offer, and the only flags dev lets through to the script.
  `dev help flags` has the rule.
- `# group: <name>` sets the heading `dev help` lists a verb under. A verb
  with no group lands in a group named after the project directory. A noun
  takes the group of its first subcommand script that has the line.
- `# hidden` keeps a flat verb out of `dev help`, and `dev help -a` still
  lists it.
- `# local`, `# fetch JOB FILE`, `# patch JOB FILE` and `# positional` change
  how a verb is called. `dev help flags` describes them.

A Lua verb (`.lua`) takes the same lines in one leading `--[[ ... ]]` block,
with no `# ` prefix. The `group:` line comes first and the description on the
line after it, as `.dev/antinote/diff.lua` has it. The bare `hidden`, `local`
and `positional` lines and the `flags:` line sit in the same block.

Project scripts named `__*.sh` or `__*.lua` never appear in any listing.

## Project topics

A `.md` file in `.dev/topics/` is a topic, shown by `dev help <topic>`. Its
first line is `# <name>: <summary>`, where the name is the file name.

Run `dev __topics check` to check the format, the names and every quoted `dev`
line.

dev refuses to run any project script as root.
