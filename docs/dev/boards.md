# boards: Read and update a project's board with dev board

`dev board` reads and updates the project's kanban board, so an agent never
handles the board's API. It is machine-local: `--remote` and root refuse it.

```
dev board status
dev board ls --column ready
dev board next
dev board add "Name the new thing" --column backlog --description "why"
dev board note 8af0e001 "Tests pass, landing now."
dev board move 8af0e001 progress
dev board take 8af0e001
dev board release 8af0e001
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
without a `[board]` section. The `local` backend is not built yet and stops with
an error.

The server and the token live once in the user file
`~/.config/dev/config.toml`, never in a project file:

```toml
[board.pomb]
url = "https://pomb.example.com"
token = "pass:secrets/worker/token/pomb.example.com"
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
