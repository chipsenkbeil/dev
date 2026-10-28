# boards: Read and update a project's board with dev board

`dev board` reads and updates the project's kanban board, so an agent never
handles the board's API. It is machine-local: `--remote` and root refuse it.

```
dev board status
dev board init
dev board ls --column ready
dev board next
dev board add "Name the new thing" --column backlog --description "why" --size 2
dev board ls --size 3+
dev board size 8af0e001 1
dev board add "Name" --label needs:lead --label docs
dev board label 8af0e001 +needs:human
dev board stale --days 7
dev board note 8af0e001 "Tests pass, landing now."
dev board notes 8af0e001
dev board note 8af0e001 --edit 3ff0e006 "Tests pass, landed as abc123."
dev board note 8af0e001 --delete 3ff0e006
dev board move 8af0e001 progress
dev board take 8af0e001
dev board release 8af0e001
dev board sync
```

## Opting in

A project uses a board when `.dev/config.toml` has a `[board]` section:

```toml
[board]
backend = "pomb"
name = "dotfiles"
```

`backend` is `pomb` or `local`, and `name` defaults to the project directory's
name. `dev board status` prints the backend and the board, or `no board for
this project` with exit 1, and every other subcommand says the same and exits 1
without a `[board]` section. The `local` backend keeps the board in a file (see Local boards below).

The server and the token live once in the user file
`~/.config/dev/config.toml`, never in a project file:

```toml
[board.pomb]
url = "https://pomb.example.com"
token = "pass:secrets/worker/token/pomb.example.com"
lead_token = "pass:secrets/lead/token/pomb.example.com"
```

dev reads `[board.pomb]` from the user file alone, so a repository cannot send
the token to another server.

## The token

`token` names a `pass` entry. dev runs `pass show` under a 10 second timeout
with `PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch"`, so a locked
store fails at once with `board unavailable: pass is locked or has no entry
...` instead of waiting on a prompt. The token goes to curl on standard input
as a config line. It is in no argument list, no environment variable, no file
and no output, `-v` and `-vv` included.

## Laying out the board

`dev board init` brings the project's board to the standard, whether the board
is new or old. It adds what is missing, fixes what is wrong and never deletes
anything, so running it twice is the same as running it once. It prints one line
per change, and `board X already follows the standard, nothing to change` when
there is none.

```
dev board init
dev board init --name ci
dev board init --admin
```

What it lays out:

- The columns Icebox, Backlog, Ready, In Progress, In Review, Blocked and Done,
  in that order, with Done counting as done. A missing board is made from Pomb's
  `agent project` template, and the missing columns are added and moved into
  place. A column it does not know stays, comes after Done and is reported as
  `kept column "X", which is not part of the standard board`. It never renames
  a column.
- The palette: yellow is `1 Pomodoro`, green `2 Pomodori`, blue `3 Pomodori`, red
  `>3 Pomodori` and white `Unsized`, with white as the default. A card keeps its
  colour in every column, so the colour is the only record of its size.
- Size words off card names. A trailing `(yellow)`, `(green)`, `(blue)`, `(red)`
  or `(red, split)` comes off the name. If the card is still white, has no
  colour, or has the colour that was the default when the run began (Pomb gave
  that to every card nobody coloured), the card takes the colour the word names.
  A card with any other colour keeps it.
- Labels need nothing: `needs:lead` and `needs:human` are plain strings on a
  card, and Pomb makes them when a card first carries one.

The board's name comes from `[board]`. In a project with no `[board]` section,
`--name N` names the board and `init` appends the section to `.dev/config.toml`
once the board is in order. `--name` with a different name than the section's
is a usage error.

### Tokens

By default `init` uses the lead token, `lead_token` in `[board.pomb]`, read the
same way as `token`. Pomb lets the lead token name colours, set the default
colour and reorder columns only on boards that token created. On any other
board Pomb answers 403 and `init` says to run it with `--admin`.

`--admin` signs in through Pomb's device flow. dev prints a code and a link,
you open the link in your browser, check that it asks for `admin`, approve it
and pick an expiry, and dev carries on. The token it receives is held in memory
for that run. It is never written to a file, put in an argument or an
environment variable, or printed. If you approve a lower scope than `admin`,
`init` stops before changing anything.

```
approve the admin sign-in at https://pomb.example.com/device
code: ABCD-EFGH
```

Run it once on each existing board, from that board's repository. The four
without a `[board]` section get one from `--name`, an uncommitted change to
`.dev/config.toml` that you commit with the rest of that repository's work:

```
cd ~/projects/dotfiles && dev board init --admin
cd ~/src/ci && dev board init --admin --name ci
cd ~/projects/infra && dev board init --admin --name infra
cd ~/projects/pomb && dev board init --admin --name pomb
cd ~/projects/demo && dev board init --admin --name demo
```

## Columns, cards and sizes

The columns are Icebox, Backlog, Ready, In Progress, In Review, Blocked and
Done, matched by name. A column argument is a name in any case or `ready`,
`progress`, `review`, `blocked`, `done`, `backlog` or `icebox`.

A card is named by its id or by a prefix of at least 8 characters that is
unique on the board. `ls` prints the id prefix, column, size, labels and name,
with Done left out unless `--column Done` asks for it. The size is the card
colour's palette label, or `unsized`. `next` prints the top Ready card that is
unclaimed and not blocked, or `no ready cards`.

`add` puts a card in Backlog unless `--column` names another column. `note`
adds a comment of kind agent. `move` puts the card at the top of the column.

`notes CARD` lists the card's comments, oldest first: the comment's id prefix,
who wrote it (the token's name, else the kind of actor), the time in UTC and the
first line. `note CARD --edit COMMENT TEXT` replaces the text of one of your own
comments and `note CARD --delete COMMENT` removes it. `COMMENT` is an id prefix
of at least 8 characters from `notes`. Pomb lets a token change only the
comments it wrote, so a comment from a person, from another token or from
before Pomb 0.5.7 answers 403, and dev says `that comment is not yours to
change` (exit 1). A deleted comment is gone for good (Pomb keeps no recycle bin
for comments).

`size CARD S` sets a card's colour from the size word `S`: `1` is yellow, `2`
green, `3` blue, `3+` red and `unsized` white. `add --size S` does the same
when it makes the card, and `ls --size S` keeps only the cards of that colour,
where a card with no colour counts as unsized. Any other word is a usage error
(exit 2) that lists the five. The colour is found by its value in the board's
palette, never by its label, so it works before and after `dev board init`
names the labels. A board missing the colour fails with
`board unavailable: the board has no yellow colour`.

`add --label L` gives a new card a label, and may be repeated. `label CARD +L`
adds a label to a card and `-L` removes one, with as many as you like in one
call. Pomb replaces a card's whole label list on a change, so `label` reads
the current labels, applies the edits in order and sends the full list, with
the claim's fence when this machine holds one. Adding a label the card has, or
removing one it lacks, changes nothing and sends nothing. A label is one word
with no spaces and no leading `-`; anything else, or a word with no sign, is a
usage error (exit 2). dev reads a bare `-L` as a flag it does not know, so put
`--` between the card and the label. The escalation
labels `needs:lead` and `needs:human` are plain labels to dev. Two agents
editing the same card's labels at the same moment can lose one edit, because
pomb has no add or remove call and takes the whole list.

`stale [--days N]` lists the cards that have sat in Backlog, Ready, In
Progress or In Review for N days or more, 7 by default, oldest first. Each line
is the id prefix, the column, the days in it (`9d`), the size and the name.
It counts whole days from the card's `column_entered_at`, which Pomb gives
every task view, so a card at 6 days is fresh and one at 7 is stale. Icebox,
Blocked and Done are never stale. Every card with the `needs:human` label, in
any column but Done and at any age, is listed apart under
`for the owner (needs:human):` with its column and days in column, and never
among the stale ones (it waits on the owner, not on an agent). A card in one of
those columns, or with that label, that the tasks view did not date gets a line
`could not date <id> <name>` after a blank line, instead of being skipped. When
nothing is stale it prints `no stale cards`. A `--days` that is not a whole
number of 1 or more is a usage error (exit 2). An orchestrator can run it at
startup and re-plan, escalate or ice each card it lists.

## Local boards

`backend = "local"` keeps the board in one JSON file, so a project needs no
Pomb server. Every command works on it, with the same seven columns, size
colours and labels as a Pomb board, so a board reads the same either way.

```toml
[board]
backend = "local"
name = "scratch"
```

The file is `~/.local/state/dev/boards/scratch.json` (under `$XDG_STATE_HOME`
when that is an absolute path), readable by you alone. To keep the board in
the repository and commit it, name a path inside the project:

```toml
[board]
backend = "local"
path = ".dev/board.json"
```

`dev board init` lays out the columns and the palette in the file. Two
processes can write at once: each change takes a lock beside the file, reads it
again and renames a finished copy into place. `take` sets a claim that lapses
after twice the card's size and needs no loop, and `release` gives it up. Only
a note written by dev can be edited or deleted. A local board has nothing to
sync, so `dev board sync` says so.

## When Pomb is unreachable

On a Pomb board, `add`, `move`, `note`, `size` and `label` that cannot reach
Pomb, or cannot read the token because `pass` is locked, are kept in a queue
and print the line below. A timeout or a gateway error may come after Pomb
applied the change, so only `move`, `size` and `label`, which are safe to
repeat, are queued for those; `add` and `note` fail instead of risking a
duplicate.

```
queued: Pomb unreachable, will sync
```

The queue is `~/.local/state/dev/boards/<name>.queue`, readable by you alone,
and holds the commands as you typed them and never the token. `dev board sync`
replays it in order once Pomb answers, and every other `dev board` command on
the board tries that first when the queue is not empty. Card ids are matched
when the change is replayed. A change Pomb refuses, for example because the
card is gone, is reported as `dropped <command> <card>: <reason>` and removed,
so it is never retried. A change that dev was killed in the middle of replaying stays queued and may be sent twice. A replay that finds Pomb still down leaves the rest
queued, and `sync` then prints how many are left and exits 1.

## Claims

`take` claims a card so no other agent picks it up, and starts a loop that
keeps the claim alive. The claim lasts 900 seconds. The loop renews it every 5
minutes with curl, so it costs no model turns and outlives the shell that
started it. Its claimant is `dev@<host>:<session or pid>`.

```
dev board next
dev board take 8af0e001
dev board move 8af0e001 progress
```

The loop stops when you `release` the card, when you `move` it to any column
but In Progress, when Pomb refuses a renewal because the claim is gone, and by
itself after twice the card's size: 50 minutes for 1 Pomodoro, 100 for 2
Pomodori and 150 for the rest. A crashed agent therefore loses its claim
within 15 minutes of the loop's end. A network failure does not stop it.

The loop's state is a file named for the card in `$XDG_STATE_HOME/dev/board/`,
or `~/.local/state/dev/board/`, with the card, the fence and the loop's pid at
mode 600. It never holds the token. The loop reads the token from `pass` for
each renewal and hands it to curl on standard input, so it is in no argument
list, environment variable, file or output. While you hold a claim, `move` and
`note` send its fence, and `ls` shows each live claim's holder in a column
before the name.
