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
dev board add "Name" --checks "dev lint" --checks "dev test"
dev board label 8af0e001 needs:human --remove needs:lead
dev board stale --days 7
dev board note 8af0e001 "Tests pass, landing now."
dev board note 8af0e001 --kind decision --as reviewer "Keep the two flags separate."
dev board notes 8af0e001
dev board show 8af0e001
dev board edit 8af0e001 < plan.md
dev board checks 8af0e001 "dev lint" "dev test"
dev board outcome 8af0e001 "Two-line cards print in full."
dev board outcome 8af0e001 --rename 2 "A tick shows in show."
dev board outcome 8af0e001 --tick 2
dev board outcome 8af0e001 --untick 2
dev board outcome 8af0e001 --convert
dev board note 8af0e001 --edit 3ff0e006 "Tests pass, landed as abc123."
dev board note 8af0e001 --delete 3ff0e006
dev board move 8af0e001 progress
dev board take 8af0e001
dev board release 8af0e001
dev board sync
dev board wait --for ready
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
- Which colours are on. White, yellow, green, blue and red are enabled and every
  other colour (orange, purple, magenta, cyan, brown) is disabled, one line per
  change such as `disabled orange`. Nothing is deleted. A card that already
  wears a disabled colour keeps it and is reported on every run, one line each.
  Pomb lets only an admin token change this, so with the lead token a 403 prints
  `left the colours enabled as they are...`, and the rest of the run still
  happens. Run `dev board init --admin` to switch the colours.
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

Pomb is moving to fine-grained tokens, and dev reads both servers. Today a
refusal is `insufficient_scope` and `whoami` returns a `scope`. After the
change a refusal is `permission_denied` with the `permission` and a `board_id`,
and `whoami` returns `permissions` and `boards` (`all`, or a list of ids and
names). dev prints two messages for the new refusal:

- `board_id` null: the token lacks the permission on every board, so use a
  token that has it. `init` adds the `--admin` hint to this one.
- `board_id` set: the token has the permission but is not assigned to that
  board, so add the board to the token. No `--admin` hint, since a new
  sign-in does not change the assignment.

A board missing from `GET /api/boards` on a token assigned only some boards
is reported as `pomb lists no board named X for this token, which is assigned
only to ...`. On a token that sees every board it stays `pomb has no board
named X`. `init --admin` accepts the sign-in when `whoami` says `scope` is
`admin`, or when `permissions` holds every permission the catalog
(`GET /api/v1/auth/permissions`) lists for the `admin` preset and `boards` is
`all`.

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

Every card in every column is fair game for an agent unless it is labelled
`needs:human`. What each column means, in the order a card travels:

- Icebox: an idea, maybe later. A scoping agent sharpens, sizes and promotes
  cards to Backlog. A `needs:human` card here is an idea you want to flesh out
  yourself.
- Backlog: wanted, not ready to run. A card enters with a Problem. A planner
  writes the card format v2 description, the outcomes and the checks, sizes it
  (splitting a red card, which may become an umbrella over its children) and
  moves it to Ready.
- Ready: an agent can run it with no questions: size 1 to 3, v2, 3 to 7
  outcomes and a checks row, which `dev board` enforces. The top card is next,
  and the order within Ready is the priority. A runner takes it by size: yellow
  by a haiku agent, green and blue by a sonnet agent.
- In Progress: an agent holds the card, under its name. Only the claimant works
  it.
- In Review: the change is under review or ci, then it lands. Still the
  claimant's.
- Blocked: waiting on an answer. `needs:human` is yours alone. `needs:lead` is
  for a higher-tier agent, which answers and moves the card out.
- Done: landed, answered, or dropped with a note.

An agent with nothing Ready takes the top of Backlog and then Icebox, planning
the card first. It reads each card's comments before taking one, and a card
whose latest comment of yours defers it ("not now", "after X") or asks for
something goes to Icebox or Blocked with `needs:human` and is left alone.

`needs:human` means only a human can answer. No agent answers for you on such a
card, and another agent relaying your view never counts. Agents never move,
edit or relabel one, and the label sits only in Blocked or Icebox, never
Backlog. Only you move it out. The one exception is an agent that you answered
directly in its own session: it quotes you in a decision note, removes the label
and carries on. Your own comment on the card, or that session answer, counts as
the answer only when it settles every open choice. A partial answer keeps the
label. A `needs:human` card whose newest comment is yours counts as
answered and waits for your move.

An umbrella waits in Backlog until its first child starts, sits in In Progress,
and is Done when every child is Done. It is never Ready and holds no claim.

To push a card later, drag it lower in Ready.

A card is named by its id or by a prefix of at least 8 characters that is
unique on the board. `ls` prints the id prefix, column, size, labels and name,
with Done left out unless `--column Done` asks for it. When a listed card has
Done when outcomes, a column such as `1/3` (ticked over all) follows the
labels. The size is the card
colour's palette label, or `unsized`. `next` prints the top Ready card that is
unclaimed and not blocked, or `no ready cards`.

`add` puts a card in Backlog unless `--column` names another column, and
writes the three card format v2 headings into the description (Problem,
Change and Out of scope), filling Problem from `--description`. A
description that already holds a heading or the v1 Done when is kept as it is,
and an Icebox card gets the text as given, with no headings. Each
`--done-when TEXT` (repeatable, at most 7) is a Done when outcome: `add` creates
the card, then appends one Pomb subtask per item. If an append fails, `add`
exits 1 and names the card and the outcome it stopped at, for example `11111111
was added to Backlog but outcome 2 of 3 was not: ...`. Nothing is rolled back (an agent token cannot delete a card or a
subtask) and the failure is never queued, so a replay cannot add the card
twice. A queued add that never reached
Pomb replays with all its items. With `--column ready`, Pomb gets the card in
Backlog first and the move to Ready comes after the subtasks. `note` adds a comment, of kind
agent unless `--kind` says otherwise. `move` puts the card at the top of the
column.

`add`, `note` and `edit` warn on standard error, and still write, when the
prose holds a hex id, a hash or a path, which the v2 format keeps in the
Change section only. One line names each word. A hex id is 7 or more hex
characters with a digit and a letter. A path holds a `/` and starts with `~/`,
`./` or `/` or ends in an extension. A URL is exempt. Text under `## Change` is
not scanned, a note is all prose, an outcome is prose, and `--checks` is never
scanned.

Sizing is part of planning, so a card cannot enter Ready without a size. `move
CARD ready` refuses a card that is unsized (white or no colour) or red, more
than 3 Pomodori, and says to run `dev board size CARD 1`, `2` or `3` (exit 1);
a red card is split instead. `add --column ready` without `--size 1`, `2` or `3`
is a usage error (exit 2). Every other column takes a card of any colour.

A card also needs card format v2 to enter Ready: all three headings, and 3 to
7 Done when outcomes (subtasks). A card with none is still accepted when its
description has a v1 `## Done when` checklist item, until the boards are
converted. `move CARD ready` refuses a card without them and names what is
missing (exit 1), and `add --column ready` does the same for its description
and `--done-when` items (exit 2). Icebox cards are free-form, so adding to or moving into Icebox is
never checked.

A card needs a checks row to enter Ready too. The checks live in the board's
`dev.checks` field, a table with a `run` column, and `add --checks CMD`
(repeatable) writes one row per command. `move CARD ready` refuses a card with
no row (exit 1), `add --column ready` without `--checks` is a usage error
(exit 2), and on a Pomb board that has no checks field both say so and point to
`dev board init`, which defines the field once and never touches one that
exists. `checks CARD CMD...` replaces the rows of a card that is already on
the board (one row per command, so it also adds a second command) and prints
`set checks <id prefix>, N rows`. With no command it is a usage error (exit
2), to keep anyone from clearing the rows by accident. It sends the claim's
fence when this machine holds one, gives the same refusal as a move into
Ready on a Pomb board with no checks field, and is queued while Pomb is
unreachable, since sending the same rows twice changes nothing more. `show`
prints the rows under the description. Icebox is exempt.

`show CARD` prints everything a runner needs to take a card: the `ls` line
(id prefix, column, size, labels and name), then the description, then the
comments in the `notes` format. The outcomes print as `done when:` with one
`- [x]` or `- [ ]` line each, after the description. A card with no description prints `no
description`, and one with no comments `no comments`. Use it instead of the
Pomb API to read a card, so the token stays inside dev. `links` lists its links.
A child also prints `parent: <id prefix> <name>` under the `ls` line, and an
umbrella `children: N of M done`.

`edit CARD` replaces a card's description with the text of `--file PATH`, or of
standard input when there is no `--file`, and prints `edited <id prefix>`. The
format v2 description always holds the current plan, so rewrite it after a
decision. Trailing whitespace is dropped, and empty text is a usage error
(exit 2), to keep an empty pipe from wiping a plan. It sends the claim's fence when
this machine holds one. It does not touch the title or the comments.

`note CARD --kind K --as ROLE TEXT` tags the comment: `K` is decision, question,
blocked, status or done (agent when omitted), and `ROLE` is a free label of at
most 80 characters, such as planner, implementer or reviewer, that lets agents
sharing one token tell themselves apart. A note that begins with a dash still
posts as text. `--edit` changes only the text, so the kind and the label stay,
and a queued note replays with both.

`notes CARD` lists the card's comments, oldest first: the comment's id prefix,
who wrote it (the token's name, else the kind of actor), its kind, its role
label (`-` when it has none), the time in UTC and the first line. `note CARD --edit COMMENT TEXT` replaces the text of one of your own
comments and `note CARD --delete COMMENT` removes it. `COMMENT` is an id prefix
of at least 8 characters from `notes`. Pomb lets a token change only the
comments it wrote, so a comment from a person, from another token or from
before Pomb 0.5.7 answers 403, and dev says `that comment is not yours to
change` (exit 1). A deleted comment is gone for good (Pomb keeps no recycle bin
for comments).

`ls` on a colour terminal prints a summary line (`12 cards · 3 backlog · 2
ready`), a size legend and a table where the size is dots (one yellow, two
green, three blue, four red, three dim hollow ones for unsized) and the
outcomes are a `▰▱` meter with `2/4`. `ls --group` draws one block per column instead, with
the column's name and card count as its heading. `--column`, `--label` and
`--size` filter both layouts, a tall list goes through your pager, and piped
output, `NO_COLOR` and `TERM=dumb` keep the plain aligned lines with or without
`--group`.

`size CARD S` sets a card's colour from the size word `S`: `1` is yellow, `2`
green, `3` blue, `3+` red and `unsized` white. `add --size S` does the same
when it makes the card, and `ls --size S` keeps only the cards of that colour,
where a card with no colour counts as unsized. Any other word is a usage error
(exit 2) that lists the five. The colour is found by its value in the board's
palette, never by its label, so it works before and after `dev board init`
names the labels. A board missing the colour fails with
`board unavailable: the board has no yellow colour`.

`outcome CARD TEXT` appends a Done when outcome to a card that already exists
(`POST /api/tasks/{id}/subtasks`) and prints `outcome <id prefix> N added`.
`outcome CARD --rename N TEXT` rewords the Nth, `--tick N` marks it done and
`--untick N` clears it (`PATCH /api/tasks/{id}/subtasks/{sub_id}` with `name`
or `done`), each printing `outcome <id prefix> N reworded`, `ticked` or
`unticked`. N counts from 1 in the order `show` lists the outcomes, and an N
past the last outcome is exit 1. Ticking belongs to the reviewer. dev never
deletes or reorders an outcome (Pomb keeps both admin-only). The claim's
fence goes along when this machine holds one, and a local board keeps the same
outcomes on the card.

`outcome CARD --convert` moves a v1 `## Done when` checklist into outcomes. It
appends one outcome per `- [ ]` or `- [x]` item, ticks the ticked ones, and
only once all of that succeeded rewrites the description without the heading
and the items, then prints `outcome <id prefix> converted N outcomes`. A card
that already has outcomes, or has no checklist, is left as it is with one line
saying why (exit 0), so a second run changes nothing.

`add --label L` gives a new card a label, and may be repeated. `label CARD L`
(or `+L`) adds a label to a card and `--remove L` removes one, each as many
times as you like in one call, the additions first. Pomb replaces a card's
whole label list on a change, so `label` reads the current labels, applies
the edits and sends the full list, with the claim's fence when this machine
holds one. Adding a label the card has, or removing one it lacks, changes
nothing and sends nothing. A label is one word with no spaces and no leading
`-`, and anything else is a usage error (exit 2). The escalation labels
`needs:lead` and `needs:human` are plain labels to dev. Two agents
editing the same card's labels at the same moment can lose one edit, because
pomb has no add or remove call and takes the whole list.

`link CARD KIND OTHER` links two cards. `KIND` is `blocked_by`, `blocks`,
`related` or `parent`. `OTHER` is a card of this board, by id or prefix, or
`BOARD:PREFIX`
for a card on another board of the same Pomb server, which dev finds by reading
that board, so write the work that spans repos as
`dev board link 5ff0e014 blocked_by ci:1a2b3c4d`. It prints
`linked <id prefix> <kind> <other>`. Pomb keeps one link whichever card holds it,
and asking again for a link it has changes nothing, so a `link` that could not
reach Pomb is queued with the others. Pomb refuses a card linked to itself and a
link that would make cards wait on each other. `dev board link CHILD parent UMBRELLA` makes the other card
the umbrella of the first. A card has one umbrella and umbrellas nest one level, so Pomb refuses a
second umbrella, an umbrella that is itself a child and a child that is itself
an umbrella, and a local board refuses them too. A local board stores the links
on its own cards, links only its own cards, and its `next` skips a card that a
card outside Done blocks.

`links CARD` lists a card's links, one line each: the kind as the card sees it
(`blocked_by`, `blocks`, `related` or `parent`), the other card's id prefix and
the name
of its board, with `-` for this board. A card with no links prints `no links`.
It lists both sides of a link: the ones the card holds and the ones another
card holds on it, which show as `blocks`, `related` or `child`. A link to a card on
another board shows that board's name, so `blocks  1a2b3c4d  ci` reads as a
card on `ci` that this one blocks. dev has no command to remove a link
(Pomb lets only the admin scope delete one).

`stale [--days N] [--icebox-days N]` lists the cards that have sat in
Backlog, Ready, In Progress or In Review for N days or more, 7 by default,
oldest first. Each line is the id prefix, the column, the days in it (`9d`), the size and the name.
It counts whole days from the card's `column_entered_at`, which Pomb gives
every task view, so a card at 6 days is fresh and one at 7 is stale. Icebox,
Blocked and Done are never stale. Every card with the `needs:human` label, in
any column but Done and at any age, is listed apart under
`for the owner (needs:human):` with its column and days in column, and never
among the stale ones (it waits on the owner, not on an agent). A card in one of
those columns, or with that label, that the tasks view did not date gets a line
`could not date <id> <name>` after a blank line, instead of being skipped. When
nothing is stale it prints `no stale cards`. A `--days` that is not a whole
number of 1 or more is a usage error (exit 2). Every card in Backlog that is
unsized (white or no colour) is also listed at any age, apart, under
`unsized in Backlog:` with its id prefix, column and name, so a planner sees what
still needs a size. Last, under `icebox, untouched for N days:`, it lists the
Icebox cards nobody has looked at: the card's time in Icebox and its latest
comment are both `--icebox-days` days old or older (30 by default), counted
from the later of the two. Cards labelled `needs:human` are left out, and the
section is absent when no card qualifies. A card it cannot date, or whose
comments it cannot read, gets a `could not` line after the section. An
orchestrator can run it at startup and re-plan, escalate or ice each card it
lists, and scope the Icebox ones.

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

On a Pomb board, `add`, `move`, `note`, `size`, `label`, `link`, `edit` and
`outcome`
that cannot reach Pomb, or cannot read the token because `pass` is locked, are
kept in a queue and print the line below. A timeout or a gateway error may come
after Pomb applied the change, so only `move`, `size`, `label`, `link`, `edit`
and `outcome` with `--rename`, `--tick` or `--untick`, which are safe to
repeat, are queued for those; `add`, `note`, an `outcome` append and
`outcome --convert` fail instead of risking a duplicate.

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

A missing queue file is an empty queue. A queue file that is damaged, for
example hand-edited into invalid JSON, is never treated as empty and never
overwritten. `dev board sync` prints
`dev: <file>:<line>: <reason>; the queue is left in place` and exits 1. Any other `dev board` command prints that line on
standard error, skips the replay and runs as usual. A write that cannot reach
Pomb then fails instead of being queued. Fix or delete the file to go on.

## Waiting for the board

`dev board wait` blocks until the board changes, so an agent with nothing to do
parks on it instead of polling or ending idle. Run it in the background under
`timeout`, and its exit wakes the session:

```
timeout 3600 dev board wait --for ready
timeout 3600 dev board wait --for human
```

`--for ready` wakes on a card added to Ready or moved into it and prints
`added <id prefix> to Ready` or `moved <id prefix> to Ready`. `--for human`
wakes only on a card moved out of Blocked and prints
`moved <id prefix> out of Blocked` (a comment on a Blocked card never wakes
it). With no `--for`, every added card, move, update and comment wakes it. Any
other `--for` value is a usage error, and a local board is
`dev: a local board has nothing to wait on` (exit 1). `wait` is never queued.

The command asks Pomb for events after a cursor and holds each request for up
to 50 seconds, repeating on a quiet board until a matching event arrives. It
keeps the cursor in `~/.local/state/dev/boards/<name>.<mode>.cursor` (`ready`, `human` or `all`), readable by you
alone and saved after every reply, so a change made while no wait was running
wakes the next one. With no cursor file the first call starts from now. When
Pomb has dropped the events after the stored cursor, `wait` stores the oldest
one it still has, prints `events were trimmed, check the board` and exits 0, so
look at the board and run it again.

Pomb being unreachable (no route, a locked `pass`, a gateway error) is retried
every 30 seconds, up to ten failures in a row, and then `wait` exits 1 with the
message. Pomb allows 4 open waits per token and every session shares one, so a
fifth session gets a 429 with the code `too_many_waits`. That is never a
failure: `wait` prints one line on standard error the first time, then retries
with a pause that doubles from 30 seconds to 5 minutes, each pause cut by a
random fraction of up to a quarter to keep sessions from retrying together,
and keeps waiting until a slot frees. Any other refusal, such as a bad token,
exits 1 at once. Exit 124 from `timeout` means nothing changed, so park
again.

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
within 15 minutes of the loop's end. A network failure does not stop it. A
`move` out of In Progress also releases the claim once the move has succeeded,
and a refused release prints a warning and leaves the move done.

The loop's state is a file named for the card in `$XDG_STATE_HOME/dev/board/`,
or `~/.local/state/dev/board/`, with the card, the fence and the loop's pid at
mode 600. It never holds the token. The loop reads the token from `pass` for
each renewal and hands it to curl on standard input, so it is in no argument
list, environment variable, file or output. While you hold a claim, `move` and
`note` send its fence, and `ls` shows each live claim's holder in a column
before the name.
