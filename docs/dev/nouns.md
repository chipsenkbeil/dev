# nouns: How nouns and the scripts in .dev/ become verbs

`dev <verb>` runs `.dev/<verb>.sh` at the repo root when it is executable.
That script replaces a built-in of the same name, and `dev help -a` marks it
`(override)`. A script that matches no built-in is a local verb.

```
dev help -a
dev help lint
```

## Nouns

`dev <noun> <sub>` runs `.dev/<noun>/<sub>.sh`. A directory of executable
scripts is a noun, unless a flat `.dev/<noun>.sh` takes the whole name. A
built-in noun (`dev tools`) keeps its subcommands: a project script never
replaces them, but it can add new ones. A noun with no subcommand, or an
unknown one, exits 2 and lists the subcommands.

The first line of `.dev/<noun>/DESCRIPTION` describes the noun. Without it,
`dev help` lists the subcommand names.

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

Scripts named `__*.sh` never appear in any listing.

## Project topics

A `.md` file in `.dev/topics/` is a topic, shown by `dev help <topic>`. Its
first line is `# <name>: <summary>`, where the name is the file name. Run
`dev __check-topics` to check the format, the names and every quoted `dev`
line.

dev refuses to run any project script as root.
