# boards: Read and update a project's board with dev board, and every subcommand in detail

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
dev board checks 8af0e001 "dev --remote lint" "dev --remote test"
dev board check 8af0e001
dev board check 8af0e001 --expect-fail --timeout 2400
dev board review 8af0e001 --kind code --by reviewer --rev @
dev board allow 8af0e001 test-edits ci-edits
dev board allow 8af0e001 none
dev board tests 8af0e001 one_should_be_one tests::two
dev board files 8af0e001 src/a.rs src/b.rs
dev board outcome 8af0e001 "Two-line cards print in full."
dev board outcome 8af0e001 --rename 2 "A tick shows in show."
dev board outcome 8af0e001 --tick 2
dev board outcome 8af0e001 --untick 2
dev board outcome 8af0e001 --convert
dev board note 8af0e001 --edit 3ff0e006 "Tests pass, landed as abc123."
dev board note 8af0e001 --delete 3ff0e006
dev board move 8af0e001 progress
dev board order 8af0e001 3ff0e006
dev board take 8af0e001 --as project-alt/boardls
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
name. `dev board status` prints the backend and the board, or
`no board for this project` with exit 1, and every other subcommand says the
same and exits 1 without a `[board]` section. The `local` backend keeps the
board in a file (see Local boards below).

The server and the token live once in the user file `~/.config/dev/config.toml`,
never in a project file:

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
store fails at once with `board unavailable: pass is locked or has no entry ...`
instead of waiting on a prompt. The token goes to curl on standard input as a
config line. It is in no argument list, no environment variable, no file and no
output, `-v` and `-vv` included.

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
  `kept column "X", which is not part of the standard board`. It never renames a
  column.
- The palette: yellow is `1 Pomodoro`, green `2 Pomodori`, blue `3 Pomodori`,
  red `>3 Pomodori` and white `Unsized`, with white as the default. A card keeps
  its colour in every column, so the colour is the only record of its size.
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
once the board is in order. `--name` with a different name than the section's is
a usage error.

### Tokens

By default `init` uses the lead token, `lead_token` in `[board.pomb]`, read the
same way as `token`. Pomb lets the lead token name colours, set the default
colour and reorder columns only on boards that token created. On any other board
Pomb answers 403 and `init` says to run it with `--admin`.

Pomb is moving to fine-grained tokens, and dev reads both servers. Today a
refusal is `insufficient_scope` and `whoami` returns a `scope`. After the change
a refusal is `permission_denied` with the `permission` and a `board_id`, and
`whoami` returns `permissions` and `boards` (`all`, or a list of ids and names).
dev prints two messages for the new refusal:

- `board_id` null: the token lacks the permission on every board, so use a token
  that has it. `init` adds the `--admin` hint to this one.
- `board_id` set: the token has the permission but is not assigned to that
  board, so add the board to the token. No `--admin` hint, since a new sign-in
  does not change the assignment.

A board missing from `GET /api/boards` on a token assigned only some boards is
reported as
`pomb lists no board named X for this token, which is assigned only to ...`. On
a token that sees every board it stays `pomb has no board named X`.
`init --admin` accepts the sign-in when `whoami` says `scope` is `admin`, or
when `permissions` holds every permission the catalog
(`GET /api/v1/auth/permissions`) lists for the `admin` preset and `boards` is
`all`.

`--admin` signs in through Pomb's device flow. dev prints a code and a link, you
open the link in your browser, check that it asks for `admin`, approve it and
pick an expiry, and dev carries on. The token it receives is held in memory for
that run. It is never written to a file, put in an argument or an environment
variable, or printed. If you approve a lower scope than `admin`, `init` stops
before changing anything.

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

The standard columns are Icebox, Backlog, Ready, In Progress, In Review, Blocked
and Done. A finished column is any column the backend marks done (`is_done` on
Pomb, the same flag in a local board's file), and a board may have several: `ls`
hides all of them, `stale` never lists their cards, and a blocker in one no
longer blocks. The other roles come from a `[board.columns]` table, read with
the project file over the user file, and each role defaults to its standard
name, which `dotfiles/bin/.config/dev/config.toml` ships:

```toml
[board.columns]
icebox = "Icebox"
backlog = "Backlog"
ready = "Ready"
progress = "In Progress"
review = "In Review"
blocked = "Blocked"
```

A project whose board renames a column sets the role to the new name, and may
add `done = "Shipped"` to name the finished column `discard` moves a card to,
else `discard` uses the first finished column in board order. A column argument
is a column's name in any case, a finished column's name or a role word:
`icebox`, `backlog`, `ready`, `progress`, `review`, `blocked` or `done`.
`dev board init` lays out the mapped names, with the mapped `done` (else Done)
marked finished. The rules in this guide say Ready, Blocked and the rest for the
roles, whatever the board calls them.

Every card in every column is fair game for an agent unless it is labelled
`needs:human`. What each column means, in the order a card travels:

- Icebox: an idea, maybe later. A scoping agent sharpens, sizes and promotes
  cards to Backlog. A `needs:human` card here is an idea you want to flesh out
  yourself.
- Backlog: wanted, not ready to run. A card enters with a Problem. A planner
  writes the card format v2 description, the outcomes and the checks, sizes it
  (splitting a red card, which may become an umbrella over its children) and
  moves it to Ready.
- Ready: an agent can run it with no questions: size 1 to 3, v2, 3 to 7 outcomes
  and a checks row, which `dev board` enforces. The top card is next, and the
  order within Ready is the priority. A runner takes it by size: yellow by a
  haiku agent, green and blue by a sonnet agent.
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
card, and another agent relaying your view never counts. Agents never move, edit
or relabel one, and the label sits only in Blocked or Icebox, never Backlog. dev
enforces it: `edit` and `rename` refuse a card labelled `needs:human`, and
`move` refuses one headed for another column (exit 1). A move within its own
column, and so `order`, is allowed. `label CARD needs:human` and
`add --label needs:human` refuse a card outside Blocked and Icebox, so move it
there first and add the label after. `label --remove needs:human` and notes stay
allowed in any column. Only you move it out. Two exceptions, both ending with an
agent removing the label: an agent that you answered directly in its own session
quotes you in a decision note and carries on, and once you move a card out of
Blocked or Icebox, the first agent to see it elsewhere removes the label and
follows that column. `stale` lists such a card under `moved by the owner`. Your
own comment on the card, or that session answer, counts as the answer only when
it settles every open choice. A partial answer keeps the label. A `needs:human`
card whose newest comment is yours counts as answered and waits for your move.

An umbrella waits in Backlog until its first child starts, sits in In Progress,
and is Done when every child is Done. It is never Ready and holds no claim:
`dev board move CARD ready` refuses a card that has children.

To push a card later, drag it lower in Ready.

A card is named by its id or by a prefix of at least 8 characters that is unique
on the board. `ls` prints the id prefix, column, size, labels and name, with
Done left out unless `--column Done` asks for it. When a listed card has Done
when outcomes, a column such as `1/3` (ticked over all) follows the labels. The
size is the card colour's palette label, or `unsized`. `next` prints the top
Ready card that is unclaimed, not blocked and not labelled `needs:human`, or
`no ready cards`. `next --column backlog` and `next --column icebox` take the
top such card of those columns instead, or print `no cards in <column>`. Any
other column is exit 2.

`add` puts a card in Backlog unless `--column` names another column, and writes
the three card format v2 headings into the description (Problem, Change and Out
of scope), filling Problem from `--description`. A description that already
holds a heading or the v1 Done when is kept as it is, and an Icebox card gets
the text as given, with no headings. Each `--done-when TEXT` (repeatable, at
most 7) is a Done when outcome: `add` creates the card, then appends one Pomb
subtask per item. If an append fails, `add` exits 1 and names the card and the
outcome it stopped at, for example
`11111111 was added to Backlog but outcome 2 of 3 was not: ...`. Nothing is
rolled back (an agent token cannot delete a card or a subtask) and the failure
is never queued, so a replay cannot add the card twice. A queued add that never
reached Pomb replays with all its items. With `--column ready`, Pomb gets the
card in Backlog first and the move to Ready comes after the subtasks. `note`
adds a comment, of kind agent unless `--kind` says otherwise. `move` puts the
card at the top of the column.

`order CARD...` sets the top of one column in a single call. Every named card
must sit in the same column. Each goes to position 0, 1, 2 and so on in the
order named, and the cards not named keep their relative order below. It prints
the column's cards after the change, one row each as `ls` does. A card that is
unknown, named twice or in another column than the first fails with exit 1
before any move, and no card is touched. A move that fails partway leaves the
cards before it in place. A queued `order` replays like a `move`. Planners keep
Icebox and Backlog in priority order with it.

`add`, `note` and `edit` warn on standard error, and still write, when the prose
holds a hex id, a hash or a path, which the v2 format keeps in the Change
section only. One line names each word. A hex id is 7 or more hex characters
with a digit and a letter. A path holds a `/` and starts with `~/`, `./` or `/`
or ends in an extension. A URL is exempt. Text under `## Change` is not scanned,
a note is all prose, an outcome is prose, and `--checks` is never scanned.

Sizing is part of planning, so a card cannot enter Ready without a size.
`move CARD ready` refuses a card that is unsized (white or no colour) or red,
more than 3 Pomodori, and says to run `dev board size CARD 1`, `2` or `3` (exit
1); a red card is split instead. `add --column ready` without `--size 1`, `2` or
`3` is a usage error (exit 2). Every other column takes a card of any colour.

A card needs a Problem to enter Backlog: all three headings, with text under
Problem. `add` (the default column) and `move CARD backlog` refuse a card
without them and name what is missing (add exit 2, move exit 1). A card also
needs card format v2 to enter Ready: all three headings with text under each,
and 3 to 7 Done when outcomes (subtasks). A card with none is still accepted
when its description has a v1 `## Done when` checklist item, until the boards
are converted. `move CARD ready` refuses a card without them and names what is
missing (exit 1), and `add --column ready` does the same for its description and
`--done-when` items (exit 2). Icebox cards are free-form, so adding to or moving
into Icebox is never checked. `add` fills the sections from `--problem`,
`--change` and `--out-of-scope`, and `--description` cannot go with them.

A card needs a checks row to enter Ready too. The checks live in the board's
`dev.checks` field, a table with a `run` column, and `add --checks CMD`
(repeatable) writes one row per command. `move CARD ready` refuses a card with
no row (exit 1), `add --column ready` without `--checks` is a usage error (exit
2), and on a Pomb board that has no checks field both say so and point to
`dev board init`, which defines the field once and never touches one that
exists. `checks CARD CMD...` replaces the rows of a card that is already on the
board (one row per command, so it also adds a second command) and prints
`set checks <id prefix>, N rows` (`1 row` for one). With no command it is a
usage error (exit 2), to keep anyone from clearing the rows by accident. It
sends the claim's fence when this machine holds one, gives the same refusal as a
move into Ready on a Pomb board with no checks field, and is queued while Pomb
is unreachable, since sending the same rows twice changes nothing more. `show`
prints the rows under the description. Icebox is exempt.

Three more card fields are set the same way, each replacing the field's
whole value under the claim's fence, and queued while Pomb is unreachable. A
board that lacks the field is refused before any write (exit 1) with
`the board has no dev.allow field, so define it on the board first`, naming
the field. `dev board init` defines none of them. `allow CARD WORD...` sets
`dev.allow`, a multiselect, to the JSON array of `test-edits` and
`ci-edits` given (duplicates dropped), and `allow CARD none` sends null to clear
it. Any other word, or `none` with another word, is a usage error (exit 2).
`tests CARD NAME...` and `files CARD PATH...` set `dev.tests` and
`dev.files`, multiline text fields, to the names joined one per line (a
blank name or one holding a line break is exit 2). `show` prints `allow:`,
`tests:` and `files:` blocks after `checks:` when set. A local board stores the
same values on the card.

`show CARD` prints everything a runner needs to take a card: the `ls` line (id
prefix, column, size, labels and name), then the description, then the comments
in the `notes` format, except that each comment prints its whole body: the lines
after the first sit under the body column, so a numbered menu reads whole. The
outcomes print as `done when:` with one `- [x]` or `- [ ]` line each, after the
description. A card with no description prints `no description`, and one with no
comments `no comments`. Use it instead of the Pomb API to read a card, so the
token stays inside dev. `links` lists its links. A child also prints
`parent: <id prefix> <name>` under the `ls` line, and an umbrella
`children: N of M done`.

`edit CARD` replaces a card's description with the text of `--file PATH`, or of
standard input when there is no `--file`, and prints `edited <id prefix>`. The
format v2 description always holds the current plan, so rewrite it after a
decision. Trailing whitespace is dropped, and empty text is a usage error (exit
2), to keep an empty pipe from wiping a plan. It sends the claim's fence when
this machine holds one. It does not touch the title or the comments.

`note CARD --kind K --as ROLE TEXT` tags the comment: `K` is decision, question,
blocked, status or done (agent when omitted), and `ROLE` is a free label of at
most 80 characters, such as planner, implementer or reviewer, that lets agents
sharing one token tell themselves apart. A note that begins with a dash still
posts as text. `--edit` changes only the text, so the kind and the label stay,
and a queued note replays with both.

`notes CARD` lists the card's comments, oldest first: the comment's id prefix,
who wrote it (the token's name, else the kind of actor), its kind, its role
label (`-` when it has none), the time in UTC and the first line of the body
(`show` prints the rest of a multi-line body, `notes` does not).
`note CARD --edit COMMENT TEXT` replaces the text of one of your own comments
and `note CARD --delete COMMENT` removes it. `COMMENT` is an id prefix of at
least 8 characters from `notes`. Pomb lets a token change only the comments it
wrote, so a comment from a person, from another token or from before Pomb 0.5.7
answers 403, and dev says `that comment is not yours to change` (exit 1). A
deleted comment is gone for good (Pomb keeps no recycle bin for comments).

`ls` on a colour terminal prints a summary line
(`12 cards · 3 backlog · 2 ready`), a size legend and a table where the size is
dots (one yellow, two green, three blue, four red, three dim hollow ones for
unsized) and the outcomes are a `▰▱` meter with `2/4`. `ls --group` draws one
block per column instead, with the column's name and card count as its heading.
`--column`, `--label` and `--size` filter both layouts, a tall list goes through
your pager, and piped output, `NO_COLOR` and `TERM=dumb` keep the plain aligned
lines with or without `--group`.

`size CARD S` sets a card's colour from the size word `S`: `1` is yellow, `2`
green, `3` blue, `3+` red and `unsized` white. `add --size S` does the same when
it makes the card, and `ls --size S` keeps only the cards of that colour, where
a card with no colour counts as unsized. Any other word is a usage error (exit
2) that lists the five. The colour is found by its value in the board's palette,
never by its label, so it works before and after `dev board init` names the
labels. A board missing the colour fails with
`board unavailable: the board has no yellow colour`.

`outcome CARD TEXT` appends a Done when outcome to a card that already exists
(`POST /api/tasks/{id}/subtasks`) and prints `outcome <id prefix> N added`.
`outcome CARD TEXT` is exit 2 when a word of TEXT is `--tick`, `--untick`,
`--rename` or `--convert`, or when TEXT is only a number. The message names the
form meant, such as `outcome CARD --tick N`. A flag inside one quoted sentence
is plain text. `outcome CARD --rename N TEXT` rewords the Nth, `--tick N` marks
it done and `--untick N` clears it (`PATCH /api/tasks/{id}/subtasks/{sub_id}`
with `name` or `done`), each printing `outcome <id prefix> N reworded`, `ticked`
or `unticked`. N counts from 1 in the order `show` lists the outcomes, and an N
past the last outcome is exit 1. A tick names its ticker with `--as NAME` after
the number (`outcome CARD --tick N --as NAME`), else with DEV_AGENT, and prints
`ticked by NAME`. On a claimed card the ticker must be a name other than the
claimant's: no name is exit 2 and the claimant's own name is exit 1, with
nothing written. The name is self-declared, so dev checks only that it differs
from the claimant. An unclaimed card needs no name, and a DEV_AGENT that is not
one word is ignored there. `--untick` takes no name and stays open to anyone.
`--as` is read only after `--tick` and `--convert`; on the other forms it is
ordinary text, so `--untick N --as X` is exit 2 for its extra words. A queued
tick keeps the name it resolved, so a later sync records the same ticker. dev
never deletes or reorders an outcome (Pomb
keeps both admin-only). The claim's fence goes along when this machine holds
one, and a local board keeps the same outcomes on the card.

`outcome CARD --convert` moves a v1 `## Done when` checklist into outcomes. It
appends one outcome per `- [ ]` or `- [x]` item, ticks the ticked ones, and only
once all of that succeeded rewrites the description without the heading and the
items, then prints `outcome <id prefix> converted N outcomes`. The ticked items
are ticks, so on a claimed card with any `- [x]` item it takes the ticker the
same way as `--tick` (`--as NAME` or DEV_AGENT, never the claimant's name) and
refuses before it writes anything. A card that already has outcomes, or has no
checklist, is left as it is with one line saying why (exit 0), so a second run
changes nothing.

`add --label L` gives a new card a label, and may be repeated. `label CARD L`
(or `+L`) adds a label to a card and `--remove L` removes one, each as many
times as you like in one call, the additions first. Pomb replaces a card's whole
label list on a change, so `label` reads the current labels, applies the edits
and sends the full list, with the claim's fence when this machine holds one.
Adding a label the card has, or removing one it lacks, changes nothing and sends
nothing. A label is one word with no spaces and no leading `-`, and anything
else is a usage error (exit 2). The escalation labels `needs:lead` and
`needs:human` are plain labels to dev. Two agents editing the same card's labels
at the same moment can lose one edit, because pomb has no add or remove call and
takes the whole list.

`link CARD KIND OTHER` links two cards. `KIND` is `blocked_by`, `blocks`,
`related` or `parent`. `OTHER` is a card of this board, by id or prefix, or
`BOARD:PREFIX` for a card on another board of the same Pomb server, which dev
finds by reading that board, so write the work that spans repos as
`dev board link 5ff0e014 blocked_by ci:1a2b3c4d`. It prints
`linked <id prefix> <kind> <other>`. Pomb keeps one link whichever card holds
it, and asking again for a link it has changes nothing, so a `link` that could
not reach Pomb is queued with the others. Pomb refuses a card linked to itself
and a link that would make cards wait on each other.
`dev board link CHILD parent UMBRELLA` makes the other card the umbrella of the
first. A card has one umbrella and umbrellas nest one level, so Pomb refuses a
second umbrella, an umbrella that is itself a child and a child that is itself
an umbrella, and a local board refuses them too. A local board stores the links
on its own cards, links only its own cards, and its `next` skips a card that a
card outside Done blocks.

`links CARD` lists a card's links, one line each: the kind as the card sees it
(`blocked_by`, `blocks`, `related` or `parent`), the other card's id prefix and
the name of its board, with `-` for this board. A card with no links prints
`no links`. It lists both sides of a link: the ones the card holds and the ones
another card holds on it, which show as `blocks`, `related` or `child`. A link
to a card on another board shows that board's name, so `blocks  1a2b3c4d  ci`
reads as a card on `ci` that this one blocks. `unlink CARD KIND OTHER` removes one.

`unlink CARD KIND OTHER` removes a link the card holds, named as `links CARD`
shows it, and prints `unlinked <id prefix> <kind> <other>`. A card with no such
link exits 1 and lists its links. A `child` line cannot be removed, because
`child` is not a link kind; remove the other card's `parent` link instead.

Pomb lets a token delete only the links it created. A link another token made,
or one made before Pomb 0.5.40 (which records no creator), gets a 403
`permission_denied`, which dev reports as `pomb kept the link: ...` and exits 1
for, leaving the link in place. Unlike `link`, `unlink` is not queued while Pomb
is unreachable.

`stale [--days N] [--icebox-days N]` lists the cards that have sat in Backlog,
Ready, In Progress or In Review for N days or more, 7 by default, oldest first.
Each line is the id prefix, the column, the days in it (`9d`), the size and the
name. It counts whole days from the card's `column_entered_at`, which Pomb gives
every task view, so a card at 6 days is fresh and one at 7 is stale. Icebox,
Blocked and Done are never stale. Every card with the `needs:human` label in
Blocked or Icebox, at any age, is listed apart under
`for the owner (needs:human):` with its column and days in column, and never
among the stale ones (it waits on the owner, not on an agent). A card with that
label in any other column but Done is listed apart under
`moved by the owner, remove needs:human:`, to show that the owner moved it out
and an agent should take the label off (per the board guide). A card in one of
those columns, or with that label, that the tasks view did not date gets a line
`could not date <id> <name>` after a blank line, instead of being skipped. When
nothing is stale it prints `no stale cards`. A `--days` that is not a whole
number of 1 or more is a usage error (exit 2). Every card in Backlog that is
unsized (white or no colour) is also listed at any age, apart, under
`unsized in Backlog:` with its id prefix, column and name, so a planner sees
what still needs a size. Last, under `icebox, untouched for N days:`, it lists
the Icebox cards nobody has looked at: the card's time in Icebox and its latest
comment are both `--icebox-days` days old or older (30 by default), counted from
the later of the two. Cards labelled `needs:human` are left out, and the section
is absent when no card qualifies. A card it cannot date, or whose comments it
cannot read, gets a `could not` line after the section. An orchestrator can run
it at startup and re-plan, escalate or ice each card it lists, and scope the
Icebox ones.

## Local boards

`backend = "local"` keeps the board in one JSON file, so a project needs no Pomb
server. Every command works on it, with the same seven columns, size colours and
labels as a Pomb board, so a board reads the same either way.

```toml
[board]
backend = "local"
name = "scratch"
```

The file is `~/.local/state/dev/boards/scratch.json` (under `$XDG_STATE_HOME`
when that is an absolute path), readable by you alone. To keep the board in the
repository and commit it, name a path inside the project:

```toml
[board]
backend = "local"
path = ".dev/board.json"
```

`dev board init` lays out the columns and the palette in the file. Two processes
can write at once: each change takes a lock beside the file, reads it again and
renames a finished copy into place. `take` sets a claim that lapses after twice
the card's size and needs no loop, and `release` gives it up. Only a note
written by dev can be edited or deleted. A local board has nothing to sync, so
`dev board sync` says so.

## When Pomb is unreachable

On a Pomb board, `add`, `move`, `note`, `size`, `label`, `link`, `edit` and
`outcome` that cannot reach Pomb, or cannot read the token because `pass` is
locked, are kept in a queue and print the line below. `check` is never
queued. A timeout or a gateway error
may come after Pomb applied the change, so only `move`, `size`, `label`,
`link`, `edit` and `outcome` with `--rename`, `--tick` or `--untick`, which are
safe to repeat, are queued for those; `add`, `note`, an `outcome` append and
`outcome --convert` fail instead of risking a duplicate. A move to Done is never
queued: its outcome check reads the card from Pomb now, so it is refused and
can be run again once Pomb answers.

```
queued: Pomb unreachable, will sync
```

The queue is `~/.local/state/dev/boards/<name>.queue`, readable by you alone,
and holds the commands as you typed them and never the token. `dev board sync`
replays it in order once Pomb answers, and every other `dev board` command on
the board tries that first when the queue is not empty. Card ids are matched
when the change is replayed. A change Pomb refuses, for example because the card
is gone, is reported as `dropped <command> <card>: <reason>` and removed, so it
is never retried. A change that dev was killed in the middle of replaying stays
queued and may be sent twice. A replay that finds Pomb still down leaves the
rest queued, and `sync` then prints how many are left and exits 1.

A missing queue file is an empty queue. A queue file that is damaged, for
example hand-edited into invalid JSON, is never treated as empty and never
overwritten. `dev board sync` prints
`dev: <file>:<line>: <reason>; the queue is left in place` and exits 1. Any
other `dev board` command prints that line on standard error, skips the replay
and runs as usual. A write that cannot reach Pomb then fails instead of being
queued. Fix or delete the file to go on.

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
`moved <id prefix> out of Blocked` (a comment on a Blocked card never wakes it).
With no `--for`, every added card, move, update and comment wakes it. Any other
`--for` value is a usage error, and a local board is
`dev: a local board has nothing to wait on` (exit 1). `wait` is never queued.

The command asks Pomb for events after a cursor and holds each request for up to
50 seconds, repeating on a quiet board until a matching event arrives. It keeps
the cursor in `~/.local/state/dev/boards/<name>.<mode>.cursor` (`ready`, `human`
or `all`), readable by you alone and saved after every reply, so a change made
while no wait was running wakes the next one. With no cursor file the first call
starts from now. When Pomb has dropped the events after the stored cursor,
`wait` stores the oldest one it still has, prints
`events were trimmed, check the board` and exits 0, so look at the board and run
it again.

Pomb being unreachable (no route, a locked `pass`, a gateway error) is retried
every 30 seconds, up to ten failures in a row, and then `wait` exits 1 with the
message. Pomb allows 4 open waits per token and every session shares one, so a
fifth session gets a 429 with the code `too_many_waits`. That is never a
failure: `wait` prints one line on standard error the first time, then retries
with a pause that doubles from 30 seconds to 5 minutes, each pause cut by a
random fraction of up to a quarter to keep sessions from retrying together, and
keeps waiting until a slot frees. Any other refusal, such as a bad token, exits
1 at once. Exit 124 from `timeout` means nothing changed, so park again.

## Claims

`take` claims a card so no other agent picks it up, and starts a loop that keeps
the claim alive. The claim lasts 900 seconds. The loop renews it every 5 minutes
with curl, so it costs no model turns and outlives the shell that started it.
Its claimant is the name from `take --as NAME`, else the `DEV_AGENT` environment
variable, else `dev@<host>:<session or pid>`. A name is one word of letters,
digits and `.`, `-`, `_` and `/`, else exit 2. `ls` shows it as the holder.
`move CARD progress` takes the claim itself, under the same name and with the
same keep-alive loop, when nobody holds the card, except a card with children,
which stays unclaimed. A claim this machine already holds is kept, and one held
by someone else leaves the move to fail as the backend answers.

```
dev board next
dev board take 8af0e001
dev board move 8af0e001 progress
```

The loop stops when you `release` the card, when you `move` it to any column but
In Progress, when Pomb refuses a renewal because the claim is gone, and by
itself after twice the card's size: 50 minutes for 1 Pomodoro, 100 for 2
Pomodori and 150 for the rest. A crashed agent therefore loses its claim within
15 minutes of the loop's end. A network failure does not stop it. A `move` out
of In Progress also releases the claim once the move has succeeded, and a
refused release prints a warning and leaves the move done.

The loop's state is a file named for the card in `$XDG_STATE_HOME/dev/board/`,
or `~/.local/state/dev/board/`, with the card, the fence and the loop's pid at
mode 600. It never holds the token. The loop reads the token from `pass` for
each renewal and hands it to curl on standard input, so it is in no argument
list, environment variable, file or output. While you hold a claim, `move` and
`note` send its fence, and `ls` shows each live claim's holder in a column
before the name.

## Reference: the subcommands in detail

A built-in noun for any project, and machine-local (`--remote` refuses it, as
does the root gate). It reads and updates the project's kanban board so an agent
never handles the API.

- `status`: `backend: pomb` and `board: <name>` from the config, with no
  network.
- `init [--name N] [--admin]`: Brings the board to the standard and prints one
  line per change (below).
- `ls [--column C] [--label L] [--size S] [--group]`: One line per card: id
  prefix (8 characters), column, size, labels (`-` for none) and name, in column
  then board order, aligned. Done is left out unless `--column` names it. A done
  column such as `1/3` (ticked outcomes over all, `-` for a card with none) sits
  after the labels, only when a listed card has outcomes. `--size` keeps one
  size (`1`, `2`, `3`, `3+` or `unsized`, where a card with no colour is
  unsized). `no cards` when nothing matches. When standard output takes colour
  (`dev.ui.context`: a terminal, no `NO_COLOR`, `TERM` not `dumb`) it draws a
  summary line `N cards · n backlog · ...` (the listed cards, by column), the
  legend `size  ● 1  ●● 2  ●●● 3  ●●●● >3  ○○○ unsized`, and a table with a dim
  bold header (ID, COLUMN, SIZE, LABELS, DONE, HELD BY only when a listed card
  is claimed, NAME): the size as yellow, green, blue or red dots (`○○○` dim for
  unsized), DONE as a `▰▱` meter with `2/4` (`-` dim with no outcomes), In
  Progress green, Blocked yellow, other columns dim and labels yellow, through
  `dev.ui.page` when taller than the screen. `--group` instead lists the cards
  under a bold column heading with a dim `N cards`, and a dim line saying Done
  is left out unless `--column done`. Piped, with `NO_COLOR` or with `TERM=dumb`
  the output is the plain lines above and `--group` changes nothing.
- `next [--column C]`: The top Ready card that is unclaimed, not blocked and not
  labelled `needs:human`, in the `ls` format, else `no ready cards` (exit 0).
  `--column backlog` or `--column icebox` takes the top such card of that column
  instead, else `no cards in <column>` (exit 0). Any other column is exit 2.
- `add NAME [--column C] [--description TEXT] [--problem TEXT] [--change TEXT] [--out-of-scope TEXT] [--size S] [--label L]... [--checks CMD]... [--done-when TEXT]...`:
  Creates the card, in Backlog by default, and prints
  `added <id prefix> <column>`. `--size` gives it the colour of the size, as
  `size` does, and each `--label L` (repeatable, duplicates dropped) gives it a
  label. Unless the column is Icebox, the description is given the three card
  format v2 headings (`## Problem`, `## Change`, `## Out of scope`) with
  `--description` text filled into Problem, or each section filled from
  `--problem`, `--change` and `--out-of-scope` (these cannot go with
  `--description`, exit 2, and `dev.board.compose` builds the text), and a text
  that already holds one of those headings or the v1 `## Done when` is kept as
  it is; an Icebox card gets the text as given and none otherwise.
  `--column ready` without a `--size` of `1`, `2` or `3` is a usage error (exit
  2), by the same rule as `move`, and so is a `--column backlog` (the default)
  whose description lacks a heading or text under Problem
  (`a card needs card format v2 before it enters Backlog, and this one lacks ...`,
  checked before the backend adds anything), and a `--column ready` whose
  description lacks a heading or text under one, or that has neither 3 to 7
  `--done-when` outcomes nor a `- [ ]` or `- [x]` item under a v1
  `## Done when`, checked after the scaffold (so it needs a full
  `--description`). Each `--done-when TEXT` (repeatable, at most 7, a blank one
  is exit 2) is one Done when outcome: `add` creates the card first and then
  appends each item as a subtask (`POST /api/tasks/{id}/subtasks` with `name`,
  in order, a work-scope call; a local card keeps them in `outcomes` with `id`,
  `name` and `done`). A queued add replays with its items (the queue holds the
  command as typed). If an append fails after the card exists (Pomb has no card
  delete or subtask delete or reorder for an agent token, so nothing is rolled
  back and nothing is retried), `add` exits 1 with
  `<id prefix> was added to <column> but outcome N of M was not: <reason>`,
  which names the card and never reads as unreachable, so it is not queued and a
  replay cannot add the card twice; the outcomes before N stay on the card. A
  Pomb `add --column ready` with outcomes creates the card in Backlog, appends
  the subtasks and then moves it to Ready, so the card is never in Ready without
  them; a failed move says
  `<id prefix> was added to Backlog with its outcomes but the move to Ready failed: <reason>`.
  Each `--checks CMD` (repeatable, a blank one is exit 2) gives the card one row
  of the board's checks field `dev.checks`, a table whose `run` column
  holds the command (`POST /api/tasks` with `fields`; a local card keeps them in
  `checks`). A `--checks`, or a `--column ready`, on a Pomb board that has no
  checks field is a usage error saying
  `the board has no checks field, so run dev board init to add it`, and a
  `--column ready` with no `--checks` is a usage error too
  (`a card needs a checks row before it enters Ready; pass --checks CMD`),
  checked after the heading check and before the backend adds anything. An
  Icebox card is exempt.
- `label CARD [+]L... [--remove L]...`: Adds labels (`L` or `+L`) and removes
  them (`--remove L`, repeatable and declared in the row's flags, so no `--` is
  needed), adds first in order and then the removals, and prints
  `labelled <id prefix> <labels, comma-joined, or ->`. It reads the card's
  labels, applies the changes and sends the whole list (`PATCH /api/tasks/{id}`
  with `labels`, which replaces the list), with the claim's fence when this
  machine holds one. Adding a label the card has and removing one it lacks are
  no-ops that send nothing. A label is one word with no whitespace and no
  leading `-` (after a `+`, or as the `--remove` value), else exit 2, and no
  label at all is exit 2. A word starting with `-` reaches the command only
  through `--` or a queue file written by an older dev, and still removes that
  label, so a queued old-form command replays. `needs:lead` and `needs:human`
  are ordinary labels, except that adding `needs:human` to a card outside
  Blocked and Icebox is refused
  (`<id prefix> is in <column>, and needs:human lives only in Blocked or Icebox; move it there first`,
  exit 1, on both backends and on a queued replay); removing it is allowed in
  any column.
- `link CARD KIND OTHER`: Links a card to another and prints
  `linked <id prefix> <kind> <other>`. `KIND` is `blocked_by`, `blocks`,
  `related` or `parent`, else exit 2. `parent` is held by the child and names
  the umbrella as `OTHER`; an umbrella nests one level and a card has one
  umbrella, so Pomb answers a second umbrella, a child made an umbrella or an
  umbrella made a child with a `400` (exit 1), and a local board refuses the
  same itself (`the card already has an umbrella`,
  `umbrellas nest one level, ...`) while linking the same umbrella twice changes
  nothing. `OTHER` is a card of this board (an id or a prefix of 8 hex
  characters or more) or `BOARD:PREFIX` for a card of another board of the same
  Pomb server, which dev finds by reading that board (`other_board`) and
  resolving the prefix there, then sends the other card's full id
  (`POST /api/tasks/{id}/links` with `kind` and `target_id`). An unknown board
  or card is exit 1. Pomb answers an existing link unchanged, so linking twice
  is safe, `link` is queued while Pomb is unreachable like `label` (the prefix
  is resolved at replay time), and Pomb refuses a card linked to itself or a
  cycle (`400`, exit 1). A `blocks` link is the same link as `blocked_by` on the
  other card. A local board stores the link in the `links` of the card that
  holds it (`blocked_by` for both blocking forms), refuses a self link and a
  cycle itself, links only its own cards (`BOARD:` is exit 1), and its `next`
  skips a card with a `blocked_by` target outside a Done column.
- `links CARD`: Lists the card's links, one aligned line each: the kind
  (`blocked_by`, `blocks`, `related`, `parent` or `child`, as the card sees it),
  the other card's 8-character id prefix and its board name (`-` for this
  board), in the order the backend gives, else `no links`. A Pomb board reads
  `GET /api/tasks/{id}/links`, which lists the links the card holds and a
  `blocks`, `related` or `child` entry for each link another card holds on it,
  and names a link's board from `GET /api/boards` (an id Pomb no longer lists is
  shown as the id). A local board lists the card's own `links`, then a `blocks`
  entry for each `blocked_by` link another card holds on it a `related` entry
  for each `related` link held the other way and a `child` entry for each
  `parent` link held on it. A missing or unknown card is exit 1. Removing a link
  is `unlink`, below.
- `unlink CARD KIND OTHER`: Removes the link of that KIND from the card to OTHER
  (a card of this board, or `BOARD:PREFIX`), and prints `unlinked` with the
  same three words `link` prints. KIND and OTHER must match a line `links CARD`
  lists, else exit 1 with that listing after the message. A `blocks` line is
  removed as the `blocked_by` the other card holds, and a `related` line from
  whichever card holds it. A Pomb board reads `GET /api/tasks/{id}/links` on the
  holder for the link's id and sends `DELETE /api/tasks/{id}/links/{link_id}`.
  A 403 `permission_denied` for `links.delete` that names no board exits 1 as
  `pomb kept the link`, and leaves the link in place. The change is not queued
  while Pomb is unreachable (exit 1, `board unavailable`). A local board removes
  the link from the card that holds it.
- `stale [--days N] [--icebox-days N]`: Lists the cards that have sat in
  Backlog, Ready, In Progress or In Review for N days or more (7 by default),
  oldest first, one line each: id prefix, column, `<days>d`, size and name,
  aligned. Days are whole days from the card's `column_entered_at` (Pomb's task
  view, RFC 3339, read with `dev.cmd.box.parse_time`) to now, so 6 days is fresh
  and 7 is stale. Icebox, Blocked and Done are never stale. Every card carrying
  the `needs:human` label in Blocked or Icebox, at any age, is listed apart,
  after a blank line and the heading `for the owner (needs:human):` (same
  columns; the name ends `(answered, waiting for your move)` when the newest
  comment is the owner's), never among the stale ones. Every such card in any
  other column but Done is listed apart after them under the heading
  `moved by the owner, remove needs:human:` (same columns, no answer note).
  Every Backlog card that is white or has no colour is listed apart too, at any
  age, after a blank line and the heading `unsized in Backlog:`, one line each
  with id prefix, column and name, in board order; sizing happens in planning,
  so a card that waits unsized is a planner's to size. A card in those columns
  or with that label that the tasks view did not date (missing from the pages,
  or no `column_entered_at`) gets one line `could not date <id> <name>` after a
  blank line. `no stale cards` when the first list is empty. Last comes the
  Icebox section: every Icebox card without `needs:human` whose column time and
  latest comment (`backend:comments`) are both `--icebox-days` days old or more
  (30 by default) is listed after a blank line and the heading
  `icebox, untouched for N days:`, oldest first, with the same columns as the
  first list, the days counted from the later of the two times. A card with no
  comment counts by its column time. A card the tasks view did not date, or
  whose comments could not be read, gets a `could not date` or
  `could not read the comments of` line after the section, and the section is
  absent when no card qualifies. Always exit 0 unless the board cannot be read
  (1); a `--days` or `--icebox-days` that is not a whole number of 1 or more is
  exit 2.
- `notes CARD`: Lists the card's comments (`GET /api/tasks/{id}/comments`),
  oldest first, one line each: comment id prefix (8 characters), the token's
  name (else the actor kind), the comment's kind (`-` for none), its role label
  (`-` for none, and Pomb's default `api-token` counts as none), the time to the
  minute in UTC and the first line of the body, aligned. `no comments` when
  there are none.
- `show CARD`: Prints the card as `ls` does (id prefix, column, size, labels,
  name), a blank line, its description (`no description` when empty), a blank
  line and its comments as `notes` lists them, so an agent reads a whole card
  without the API or the token. The description comes from the same
  `/export-data` read `ls` makes, and `GET /api/tasks/{id}/comments` gives the
  comments. After the description it prints `done when:` and one
  `- [x] <outcome>` or `- [ ] <outcome>` line per outcome (Pomb's `subtasks` in
  the `/export-data` task row), then a blank line, when the card has any, and
  then `checks:` and one `- <command>` line per checks row, then a blank line,
  when the card has any, and the same for `allow:`, `tests:` and `files:` with
  one `- <word or name>` line each (the `dev.allow`, `dev.tests` and
  `dev.files` fields). Links are listed by `links`. On a child it also
  prints `parent: <id prefix> <name>` under the `ls` line, and on an umbrella
  `children: N of M done`, from `GET /api/tasks/{id}` (`parent`,
  `children_done`, `children_total`) on Pomb and from the `parent` links of the
  cards on a local board (done meaning in a done column).
- `edit CARD [--file PATH]`: Replaces the card's description with the text of
  `--file PATH`, else of standard input (a terminal with no `--file` is exit 2),
  with trailing whitespace removed, and prints `edited <id prefix>`
  (`PATCH /api/tasks/{id}` with `description`, the same field `add` sends, with
  the claim's fence when this machine holds one). Empty text, an unreadable
  file, a missing card argument or an extra word is exit 2, and an unknown card
  is exit 1. The input is read before the board is asked, so a queued `edit`
  holds the card and the new text as typed (`dev.cmd.board` `description_args`)
  and replays without the file or the pipe; sending a whole new description
  twice changes nothing more, so `edit` is queued like `size` and `label`,
  timeouts and 502, 503 and 504 included. A local board sets the card's
  `description` under the same fence rule. Titles and comments are not editable
  here. A card labelled `needs:human` is refused (exit 1).
- `rename CARD TEXT`: Sets the card's title to TEXT (`PATCH /api/tasks/{id}`
  with `name`, with the claim's fence when this machine holds one) and prints
  `renamed <id prefix>`. The words after the card are the title, which must not
  be blank, must be at most 100 characters with no quote, backslash or control
  character, and may not hold a word starting with `-` (each exit 2). A card
  labelled `needs:human` is refused like `edit`, and a title change is queued
  while Pomb is unreachable, like `edit`. A local board sets the card's `name`.
- `checks CARD CMD...`: Replaces the card's checks rows with one row per command
  and prints `set checks <id prefix>, N rows`, or `1 row` for one
  (`PATCH /api/tasks/{id}` with
  `{"fields":{"dev.checks":[{"run":CMD},...]}}`, which Pomb merges by key
  so the sent rows replace the field's whole value, with the claim's fence when
  this machine holds one). A local board sets the card's `checks` under the same
  fence rule. No command, a blank command, a missing card or an unknown option
  word is exit 2 (so nobody clears the rows by accident, and no subcommand
  clears them), and an unknown card is exit 1. A Pomb board with no checks field
  is refused before any write with the message
  `the board has no checks field, so run dev board init to add it`, as a move
  into Ready gives (exit 1). Sending the same rows twice changes nothing more,
  so `checks` is queued while Pomb is unreachable like `edit`, timeouts and 502,
  503 and 504 included. The `on` runner names are not set.
- `check CARD [--expect-fail] [--timeout SECONDS]`: Runs every checks row of the
  card and records the result as one comment on the card. A row runs as a
  plain command, split on whitespace and started without a shell, so a row
  that holds any of `| & ; < > ( ) $`, a backtick, a backslash, a quote, `*`,
  `?` or a line break is refused before anything runs (exit 1). Under a set
  `DEV_AGENT`, dev refuses a local run of a verb that has a ci job, so a row
  reads `dev --remote lint` (not `dev lint`). Each row may run for `--timeout`
  seconds (1800 by default, at most 86400, anything else is exit 2), to cover a
  remote test of about five minutes that waits in the ci queue. A row that
  outlasts it is killed and recorded as `timeout`, as is a row that exits 124
  or is killed from outside. A card with no rows is
  exit 1.

  The result belongs to one commit. In a jj project the working copy is itself
  a commit, so a changed file is normal and the commit is `@` after jj
  snapshots the files, recorded with its change id. In a git project the tree
  must match `HEAD`, and a dirty one is refused (exit 1) with the count of
  changed paths. A conflicted jj working copy is refused too. dev names the
  commit before the first row and again after the last, and a result whose
  two commits differ was run on a tree that moved, so it is not recorded
  (exit 1).

  The comment has the kind `status` and begins with a reserved first line,
  then one line per row:

  ```
  dev-check: commit=<full commit id> change=<change id, - in git> mode=run
  1 pass dev --remote lint
  2 fail dev --remote test
  ```

  A row ends as `pass`, `fail` (any non-zero exit) or `timeout`. The command
  prints the same lines (the last 12 lines of a row that did not pass follow
  it, indented) and `recorded on <id prefix> at commit <12 characters>: N of M
  rows passed`. It exits 0 when every row passed and 1 otherwise.
  `--expect-fail` is for filing a card: it records `mode=expect-fail`, exits 0
  when every row failed, and reports a row that passed as one that proves
  nothing (exit 1, still recorded).

  If the comment cannot be written (Pomb unreachable, a timeout, a refused
  fence), the command exits 1 with `the result was NOT recorded` and the row
  lines. It never prints `recorded` then, and it is never queued (a replay
  would rerun the rows). A timeout or gateway error may come
  after Pomb stored the comment, so read `notes` before repeating a long run.
  `note` refuses any text that begins with `dev-check:` (any case, after
  leading space), and `note --edit` and `--delete` refuse a comment that holds
  or would hold it (exit 1).
- `review CARD --kind code|style|recheck --by NAME --rev REV`: Records that
  NAME reviewed the commit REV, as one `status` comment on the card that begins
  with a reserved first line and has no other:

  ```
  dev-review: kind=code by=<NAME> commit=<full commit id> change=<change id, - in git>
  ```

  All three flags are required (a missing one or an unknown kind is exit 2, and
  the message lists the kinds). REV is a jj revset in a jj project and a git
  revision in a git one, and it must name exactly one commit, so a revset of
  many commits, a word that starts with `-` and a name that resolves to nothing
  are refused (exit 1). NAME is an agent name as `take --as` takes, and the
  card's claimant is refused as the reviewer (exit 1), to keep a claimant from
  reviewing its own change. An unclaimed card takes any NAME. It prints
  `recorded KIND review by NAME on <id prefix> at commit <12 characters>`. Like
  `check`, it is never queued: if the comment cannot be written the command
  exits 1 with `the review was NOT recorded`, and a timeout or gateway error may
  come after Pomb stored it, so read `notes` before repeating. `note` refuses
  `dev-review:` as it does `dev-check:`, and `note --edit` and `--delete` refuse
  a comment that holds it. It does not judge the review.
- `allow CARD WORD...`: Replaces the card's `dev.allow` field with the JSON
  array of the words, each `test-edits` or `ci-edits` with duplicates dropped,
  and prints `set allow <id prefix>, <words>` (`PATCH /api/tasks/{id}` with
  `{"fields":{"dev.allow":["test-edits","ci-edits"]}}`, with the claim's
  fence when this machine holds one). `allow CARD none` sends `null` to clear
  the field and prints `cleared allow <id prefix>`. No word, any other word, or
  `none` beside another word is exit 2, an unknown card is exit 1, and a Pomb
  board without the field is refused before any write with
  `the board has no dev.allow field, so define it on the board first` (exit
  1). Sending the same value twice changes nothing more, so it is queued while
  Pomb is unreachable like `checks`. A local board keeps the words in the card's
  `allow`.
- `tests CARD NAME...`: Replaces the card's `dev.tests` field with the
  names joined by line breaks and prints `set tests <id prefix>, N names`
  (`1 name` for one) (`PATCH /api/tasks/{id}` with
  `{"fields":{"dev.tests":"a\nb"}}`, the multiline text a runner reads one
  name per line, with the claim's fence when this machine holds one). No name, a
  blank name or a name with a line break is exit 2, an unknown card is exit 1,
  and a board without the field is refused before any write, naming it (exit 1).
  It is queued while Pomb is unreachable like `checks`. A local board keeps the
  text in the card's `tests`.
- `files CARD PATH...`: The same as `tests`, for the `dev.files` field:
  prints `set files <id prefix>, N names` (`1 name` for one).
- `outcome CARD TEXT`, `outcome CARD --rename N TEXT`, `outcome CARD --tick N`,
  `outcome CARD --untick N`, `outcome CARD --convert`: Appends a Done when
  outcome to an existing card (`POST /api/tasks/{id}/subtasks` with `name`) and
  prints `outcome <id prefix> N added`, with N the new outcome's place.
  `--rename N TEXT` rewords the Nth and `--tick N` and `--untick N` set it done
  or clear it (`PATCH /api/tasks/{id}/subtasks/{sub_id}` with `name` or `done`),
  printing `outcome <id prefix> N reworded`, `ticked by NAME` or `unticked`. A
  tick on a claimed card needs `--as NAME` (or DEV_AGENT) for someone other than
  the claimant. The reviewer or verifier ticks, and a card moves to Done only
  once every outcome is ticked (see `move`). N counts from 1 in the order
  `show` prints the outcomes, which come from the subtasks `/export-data`
  carries (`id`, `name`, `done`), and an N
  that is not a whole number of 1 or more is exit 2, one past the last outcome
  exit 1 naming how many the card has. `--convert` moves a v1 `## Done when`
  checklist into outcomes: it appends one outcome per `- [ ]` or `- [x]` item in
  order, ticks the ticked ones, and only after every append and tick succeeded
  rewrites the description (`edit`) without that heading and those items,
  printing `outcome <id prefix> converted N outcomes`. A card that already has
  outcomes prints `outcome <id prefix> left alone: it already has outcomes` and
  one with no checklist
  `outcome <id prefix> left alone: it has no Done when checklist` (exit 0,
  nothing changed), so a second run changes nothing; a failure part way leaves
  the appended outcomes and the old description, and the card then counts as
  converted until its outcomes are fixed by hand. It takes no other word (exit
  2). The words after the card, or after N, are the text, which must not be
  blank (exit 2), and the text gets the prose warnings. All five send the
  claim's fence as `If-Claim-Fence` when this machine holds one. dev never calls
  Pomb's delete or reorder subtasks, which are admin-only. A local board keeps
  the same rows in the card's `outcomes`, refusing a stale fence as the other
  writes do. The three flag forms are queued while Pomb is unreachable and safe
  to apply twice, and the append and `--convert` are not (N is read from the
  live card at replay time).
- `size CARD S`: Sets the card's colour: `1` yellow, `2` green, `3` blue, `3+`
  red, `unsized` white (`PATCH /api/tasks/{id}` with `color_id`, sending the
  claim's fence when this machine holds one) and prints `sized <id prefix> <S>`.
  The colour id comes from the palette (`/colors`) by its `value`, never its
  label. Any other size word is exit 2 naming the five. A board without the
  colour is `board unavailable: the board has no <colour> colour` (exit 1).
- `note CARD [--kind K] [--as ROLE] TEXT`: Adds a comment and prints
  `noted <id prefix>`. The words after the card, minus the two options, are
  joined with spaces, and any other word, one starting with `-` included, is
  text. `--kind` is `decision`, `question`, `blocked`, `status` or `done` in any
  case, sent lowercase as the comment's `kind` (anything else is exit 2, and no
  `--kind` posts kind `agent`). `--as ROLE` is free text, trimmed, sent as the
  comment's `author` label (Pomb allows 80 characters, and an empty, over-long
  or control-character value is exit 2, and none leaves Pomb's default). A local
  board stores both on the comment. `show` and `notes` print them, a queued note
  keeps both options in its arguments, and `--edit` replaces only the body, so
  the kind and the label stay.
- `note CARD --edit COMMENT TEXT`, `note CARD --delete COMMENT`: Replaces the
  body of one of the agent's own comments
  (`PATCH /api/tasks/{id}/comments/{comment_id}`) or deletes it (`DELETE`), and
  prints `edited` or `deleted` with the card's and the comment's id prefixes.
  `COMMENT` is an id prefix from `notes`, 8 hex characters or more, unique on
  the card, else exit 1. Pomb lets a work or provision token change only a
  comment that same token wrote, and answers 403 for any other and for one
  written before Pomb 0.5.7, which dev prints as
  `that comment is not yours to change` (exit 1). A missing text, a missing
  comment or an extra word is exit 2.
- `move CARD COLUMN`: Moves the card to the top of the column and prints
  `moved <id prefix> to <column>`. When the card has a claim taken by `take`,
  the move sends its fence as `If-Claim-Fence` and, for any column but In
  Progress, stops the keep-alive loop, forgets the claim and, once the move has
  succeeded, releases it on the backend with its fence (a refused release prints
  `dev: moved, but the claim was not released: <reason>` on stderr and the move
  still succeeds). A move into Ready of a card that is white, has no colour or
  is red (more than 3 Pomodori) is refused before the backend is called:
  `<id prefix> has no size and cannot enter Ready; size it with dev board size CARD 1, 2 or 3`,
  or for red
  `<id prefix> is red, more than 3 Pomodori, so split it and cannot enter Ready; ...`
  (exit 1), on both backends, so a card is sized in planning and red never
  reaches Ready. A move into Backlog of a card whose description lacks a v2
  heading or text under Problem is refused before the backend is called:
  `<id prefix> is not in card format v2 and cannot enter Backlog; it lacks <what>; fix the description with dev board edit`
  (exit 1, on both backends, `dev.board.backlog_missing`). A move into Ready of
  a card whose description lacks one of the three v2 headings or text under one,
  or that has neither 3 to 7 outcomes (subtasks) nor, as the v1 fallback while
  boards are converted, a `- [ ]` or `- [x]` item under `## Done when`, is
  refused the same way, before the backend is called:
  `<id prefix> is not in card format v2 and cannot enter Ready; it lacks <what>; add outcomes with dev board outcome and fix the description with dev board edit, where a v1 Done when checklist also counts`
  (exit 1, on both backends, size checked first).
  `dev.board.missing(description, outcomes)` lists what is missing. A move into
  Ready of a card with no checks row is refused after those, before the backend
  is called:
  `<id prefix> has no checks row and cannot enter Ready; give it one with dev board checks CARD CMD`,
  or on a Pomb board with no checks field
  `the board has no checks field, so run dev board init to add it` (exit 1, on
  both backends, which `checks_field` tells apart; a local board always has it).
  A move into Ready of a card that has children (`children_total` on Pomb,
  `parent` links on a local board, as `show` reads them) is refused after the
  checks above, still before the move:
  `<id prefix> is an umbrella with N children and never enters Ready; its children are the work`
  (exit 1, on both backends, and on a queued replay). `move` refuses any card
  labelled `needs:human` first, whatever the column. A move into any other
  column, Icebox included, is never checked for the Ready rules. A move into In
  Progress of a card nobody holds and that this machine holds no claim on takes
  the claim first, as `take` does with `DEV_AGENT` as the name (a bad name is
  exit 2), unless the card has children, and releases it again when the move
  fails.
  A move into Done (`move CARD done`) is refused once the card is read, before
  the move is sent, while the card has an unticked outcome:
  `<id prefix> cannot move to Done: N of M outcomes are unticked (1. text, 2. text); the reviewer ticks them with dev board outcome CARD --tick N --as NAME, or dev board discard CARD drops it`
  (exit 1, on both backends, each open outcome numbered as `show` numbers it).
  Outcomes that Pomb sent in a form dev cannot read (`subtasks` that is not a
  list, or an entry without a string name) refuse the move the same way:
  `<id prefix> cannot move to Done: its outcomes cannot be read from Pomb, so they cannot be checked`.
  A card with no outcomes, or with all of them ticked, moves as before. Neither
  refusal is queued, nor is a move to Done that Pomb could not answer for.
- `discard CARD [--reason TEXT]`: Drops a card in three steps, in order: with
  `--reason`, a decision note with TEXT (`note --kind decision`), then the label
  `discarded` (`label`), then the move to Done (`discard_move`, the move without
  the outcome check), printing
  `discarded <id prefix>`. A card labelled `needs:human` is refused before any
  step, as `move` refuses it, so nothing is posted. A card lookup that Pomb
  cannot answer is not queued, since the steps need the card's id. Each step is
  the command of the same name, so its checks and its claim handling apply,
  except the move, which skips the outcome check (a dropped card is not done).
  When Pomb cannot take a step the steps left are queued, in order, under those
  names, so a reason is never posted twice. A blank `--reason` is exit 2. The
  card is kept, never deleted.
- `take CARD [--as NAME]`: Claims the card (`POST /api/tasks/{id}/claim` with
  `claimant` NAME, else `DEV_AGENT`, else
  `dev@<host>:<CLAUDE_SESSION_ID or the pid of dev's caller>`; NAME is one word
  of letters, digits and `.`, `-`, `_` and `/` of at most 200 characters, else
  exit 2, `ttl_seconds` 900, and the stored fence when this machine already
  holds one, which renews) and starts the keep-alive loop. Prints
  `took <id prefix>, fence N, renewing every 5m for up to Mm`. A refused claim
  (`claim_held`) is `board unavailable: pomb answered 409: ...`, exit 1.
- `release CARD`: Stops the loop, forgets the claim and posts `/claim/release`
  with the fence. Prints `released <id prefix>`. A card with no claim taken by
  `take` is exit 1.
- `sync`: Replays the changes queued while Pomb was unreachable, as below.

`add` (its `--description`), `note` (a new or `--edit`ed text) and `edit` write
a warning to standard error, prefixed `warning: `, and still write (exit 0,
output unchanged), when prose holds a hex id, a hash or a path:
`card prose holds a hex id or hash: <word>` or
`card prose holds a path: <word>`, one line per distinct word. Text under a
`## Change` heading is left out, so a note, which has no headings, is all prose,
and the name, `--checks` and `dev board checks` arguments are never scanned. A
`--done-when` outcome is scanned as prose. A hex id is a run of 7 or more hex
characters with at least one digit and one letter (so `decade` and `1234567`
pass), found in any alphanumeric run of a word. A path is a word, trimmed of
surrounding quotes, backticks, brackets and trailing punctuation, that holds a
`/` and either starts with `~/`, `./` or `/` or ends in a dot and a letter-led
extension (`and/or` and `2026/10/28` pass). A URL (`scheme://...`) is exempt.
Fenced code counts as prose. It is `dev.board.prose_warnings`, and a queued
replay prints none.

The board comes from the `[board]` section of `<root>/.dev/config.toml`:
`backend` is `pomb` or `local`, and `name` defaults to the project directory's
name. With no `[board]` section every subcommand prints
`dev: no board for this project` and exits 1, which is how an agent branches. A
`local` backend keeps the board in a file (below). Any other backend is exit 1.
The Pomb server and the token reference come from `[board.pomb]` (`url`,
`token = "pass:<entry>"` and `lead_token = "pass:<entry>"`) in the user file
`~/.config/dev/config.toml` alone, read with `config.user`, so a project file
cannot name another server for the token to go to.
`dotfiles/bin/.config/dev/config.toml` ships that file, and this repo's own
`.dev/config.toml` holds `[board] backend = "pomb"` and `name = "dotfiles"`.

`take` writes `<state home>/dev/board/<card id>` (`$XDG_STATE_HOME` when
absolute, else `~/.local/state`) with `card=`, `fence=` and `pid=` lines at mode
600 in a mode 700 directory (written to a `.new` file and renamed, so the loop
never sees a half file), and never the token. The loop is `board/keepalive.sh`
in dev's share directory, started by `dev.board.pomb` through
`sh -c 'set -m; nohup bash <script> ... & echo $!'`, so it has its own process
group, outlives the caller's shell and wakes no model. Every 5 minutes (`sleep`
with the tick in seconds as its seventh argument) it checks that the state file
still holds its fence, reads the token with the same `timeout 10 pass show` and
`PASSWORD_STORE_GPG_OPTS` as `dev.board.pomb`, refuses a token outside
`A-Za-z0-9._~+/=-`, and sends `POST /api/tasks/{id}/claim/heartbeat` with
`{"fence":N}` through `curl -K -`, the token going over a `printf` builtin pipe
into curl's stdin so it is in no argv, no environment variable, no file and no
output. The loop ends when the state file is gone or holds another fence
(`release`, `move` out of In Progress or a newer `take`; `release` and `move`
also kill its pid after `ps` shows the script in the command, and `release` does
so only once Pomb has accepted the release, so a failed release can be retried),
when a heartbeat answers 4xx (the claim is gone), and after twice the card's
size in 5-minute ticks: 10 for 1 Pomodoro, 20 for 2 Pomodori and 30 for any
other size, unsized included. A network failure, a 5xx or a failed `pass` read
(a locked store) keeps it going until the cap, and a move made outside
`dev board move` does not stop it, and a loop that ends removes its state file,
so a crashed agent's claim lapses after its 900-second lease. `ls` adds a
claimant column before the name, only when a listed card has a live claim (`-`
for the others), from `claim.claimant` of `/export-data` while
`claim.expires_at` is in the future. Moving a card keeps the loop only into In
Progress, so `next`, `take`, `move progress` works.

`dev board wait [--for ready|human]` (Pomb only) loops on `Backend:wait` until
an event matches and prints one line per matching event in the reply, then exits
0, so a background run under `timeout` wakes the session. `--for ready` sends
kinds `task_added,task_moved` and matches a card whose column is Ready after the
event (`added <id prefix> to Ready`, `moved <id prefix> to Ready`),
`--for human` sends `task_moved` and matches a move whose `from_column` is
Blocked (`moved <id prefix> out of Blocked`), so a comment never matches it, and
with no `--for` all four kinds match (`added <id> to <column>`,
`moved <id> to <column>`, `updated <id>`, `commented on <id>`). An unknown
`--for`, a card argument or another flag is exit 2, and a local board is
`dev: a local board has nothing to wait on` (exit 1). The cursor is
`<state home>/dev/boards/<name>.<ready|human|all>.cursor`, one per `--for` mode
so a filtered wait never consumes another mode's events (the name with every
character outside `A-Za-z0-9._-` turned into `_`) at mode 600, written after
every reply, and with no file the first call asks without a cursor and starts
from the cursor Pomb answers. An expired cursor (410) stores the backend's
oldest cursor and prints `events were trimmed, check the board` (exit 0). A
failure `pomb.unreachable` counts (idempotent rules) is retried after a 30
second nap, and the tenth in a row exits 1 with its message (an endless silent
retry would hide a dead Pomb from the session). A 429 whose body has the code
`too_many_waits` (4 open waits per token, and every session shares the token)
makes `Backend:wait` return a fourth value, `true`, and is never a failure:
`wait` prints
`dev: pomb holds too many open waits for this token, waiting for one to end` on
standard error once per call, resets the failure count, and retries with a pause
of 30, 60, 120, 240 and then 300 seconds, each cut by up to a quarter with a
random fraction, until a reply comes (a reply starts the pause over). A 429 with
another code is a plain refusal. Any other refusal exits 1 at once. `wait` is
not in the queue rules, and a reply with no matching event loops again.
`tests/lua/board_test.lua` covers it with a fake backend and stub `nap`,
`random` and `notice` options.

`dev board sync` is the one subcommand outside the board's own commands. On a
Pomb board it replays the queue below and prints `synced <sub> <first argument>`
per change, `dropped <sub> <first argument>: <reason>` for one Pomb refused, and
`synced` at the end (`nothing queued` for an empty or missing queue); it exits 1
and prints `queued: N` when Pomb is still unreachable, and on a local board it
is `dev: a local board has nothing to sync` (exit 1).

The `local` backend is `dev.board.localboard`, one JSON file with `name`,
`columns`, `colors` and `cards` (each card with its `column_id`, `color_id`,
`labels`, `links`, `comments`, `entered_at`, and a `claim` of `claimant`,
`fence` and `expires_at` while one is held), written one card per line so a
tracked file diffs well. The file is `<state home>/dev/boards/<name>.json`
(`$XDG_STATE_HOME` when absolute, else `~/.local/state`) at mode 600 in a mode
700 directory, with the name restricted to letters, digits, dots, dashes and
underscores (else `dev: a local board's name must be letters, digits...`, exit
1), or `<root>/<path>` at the default mode when
`[board] path = ".dev/board.json"` is set. The path must be relative, start with
a letter, digit, dot or underscore and hold no `..` or `//` (else exit 1), and
`path` with the `pomb` backend is exit 1. Every change runs in
`dev.board.store`: take an exclusive `flock` on `<file>.lock` (for a tracked
path, a lock file named for the path under `<state home>/dev/boards/locks/`, so
the project tree gets none), read the file again, change it, write a temporary
file beside it and `rename` it over, so two processes never lose each other's
write and a reader never sees half a file. `take` on a local board sets the
claim's expiry to twice the card's size from now (50, 100 or 150 minutes),
starts no loop, writes the state file with `pid=0` and prints
`took <id prefix>, fence N, held for Nm`; a live claim by another claimant or
with another fence refuses the claim, a write that sends a fence while another
fence holds the claim is refused, and a lapsed claim blocks nothing. Comments
are of actor `agent`, and `note --edit` and `--delete` refuse any other
(`that comment is not yours to change`). New cards go to the bottom of their
column, `move` to the top, `next` is the top unclaimed Ready card, and `stale`
counts days from the card's `entered_at`.

The Pomb offline queue is `dev.board.queue`,
`<state home>/dev/boards/<name>.queue` (the name with every character outside
`A-Za-z0-9._-` turned into `_`) at mode 600, a JSON list of `{sub, args, at}`
with the command as typed and no token. When `add`, `move`, `note` (not `--edit`
or `--delete`), `size`, `label`, `link`, `edit`, `rename` or `outcome` on a Pomb
board fails because Pomb could not be asked (`dev.board.pomb.unreachable`:
`pass` timed out or is locked, or curl could not resolve or connect, exit 5, 6
or 7; for `move`, `size`, `label`, `link`, `edit`, `rename` and `outcome` with
`--rename`, `--tick` or `--untick`, which are safe to apply twice, also a curl
timeout, a 502, 503 or 504, or an answer that is not JSON, since those may
follow an applied change and `add` or `note` would then be doubled, so an
`outcome` append or `--convert` is never queued for those), the command appends
itself to the queue, prints `queued: Pomb unreachable, will sync` and exits 0.
Usage errors, refusals and every read are not queued. Every other `dev board`
command on a Pomb board, `status` included, first replays a non-empty queue (its
`synced` and `dropped` lines go to standard error), so a card prefix is resolved
against the live board at replay time. Replays run in order under the queue's
lock, each leaving the file as soon as it is dealt with, so a process killed
mid-replay leaves that change queued and delivery is at least once. One that
Pomb refuses is reported and dropped, never retried, and one that finds Pomb
unreachable again stops the replay and stays queued with those behind it.
`status` prints `queued: N` last while changes are waiting. A missing queue file
is an empty queue. A file that is not valid JSON, is not a list or holds an
entry without a string `sub` and a list `args` is malformed: `queue.count` and
`queue.list` answer `<path>:<line>: <reason>` (the line from the parse error's
offset, or `<path>: entry N is not a queued command`), `dev board sync` prints
`dev: <that>; the queue is left in place` and exits 1, and every other Pomb
command (`status` included) prints the same line on standard error, replays
nothing, runs normally and leaves the file untouched, so a read is never blocked
by a bad queue. A write that would have been queued then fails with
`could not be queued` (`push` refuses a malformed file), and nothing overwrites
it. `tests/lua/board_local_test.lua` covers the local backend on a temporary
state directory, a tracked path, six processes writing at once and the queue.

A column argument is matched against Icebox, Backlog, Ready, In Progress, In
Review, Blocked and Done in any case, plus the short forms `progress` and
`review`, else exit 2 naming the columns. A card is its full id or a prefix of
at least 8 hex characters that is unique on the board; a shorter, unknown or
ambiguous one exits 1. The size is the palette label of the card's colour, or
`unsized`. A flag a subcommand does not take, a missing argument and a bad
column are usage errors (exit 2).

`dev.board.pomb` finds the board by name (`GET /api/boards`), then its columns
(`GET /api/boards/{id}`) and palette (`/colors`), matching columns by name.
`stale` pages through `/tasks?limit=500` (following `next_cursor` with
`&cursor=`) for `column_entered_at` and takes the rest from `/export-data`; `ls`
reads `/export-data` because only it carries each card's colour; `next` asks
`/tasks?limit=1&ready=true&claimed=false&column_id=<Ready>` and reads the card
for its colour; `add`, `note` and `move` are `POST /api/tasks`,
`/api/tasks/{id}/comments` (kind `agent`) and `/api/tasks/{id}/move` (position
0). `wait(after, kinds, timeout)` is `GET /api/boards/{id}/events/wait` (timeout
50 seconds by default, curl `--max-time` the timeout plus 10, every other
request 30), answering `{cursor, events}` with each event's column ids turned
into names (nil for a null or unknown id, as a null `column_id` on the source
board of a cross-board move); a 410 `cursor_expired` returns nil, the message
and the body's `oldest_cursor`, and a local board's `wait` is
`nil, "a local board has nothing to wait on"`. A curl failure is
`board unavailable: cannot reach <url> (curl exit N)`, and an HTTP error is
`board unavailable: pomb answered <status>: <message>`.

`init` is deterministic and idempotent, and it never deletes a column, a colour
or a card, and never renames a column. It takes the board's name from `[board]`,
or from `--name N` when the project has no `[board]` section (without either it
exits 1, and with a section a `--name` that differs is a usage error), and after
the run it appends `[board]` with `backend = "pomb"` and that name to
`.dev/config.toml`, creating `.dev` itself when the project has none (never a
directory above the root), a line `wrote [board] to .dev/config.toml`. A
`[board]` section with no `backend` is exit 1. On a `local` board `init` lays
out the same columns and palette in the board's file (making the file when it is
missing, from the five colours with their plain names), takes no `--admin`
(usage error), and refuses a `--name` that differs from the section's. It runs
through `dev.board.init` over the `dev.board.Layout` seam that `dev.board.pomb`
implements, and does, in this order: create a missing board with
`POST /api/boards`, using the template named `agent project` when
`GET /api/templates` lists it and no template otherwise; add each missing column
with `POST /api/columns` (Done with `is_done`), then re-read the board, mark an
existing Done column done with `PATCH /api/columns/{id}` when it is not, and
reorder with `POST /api/columns/{id}/move` (`{"position": N}`, 0 first) so the
seven standard columns come first in the order Icebox, Backlog, Ready, In
Progress, In Review, Blocked, Done and any other column follows, kept and
reported as `kept column "X", which is not part of the standard board` on every
run; then define the checks field when the board lacks it
(`GET /api/boards/{id}/fields` lists the keys, and
`POST /api/boards/{id}/fields` sends `dev.checks`: label `Checks`, kind
`table`, `required` true, columns `run` (text, required) and `on` (multiselect,
optional, with the one option `local`, since Pomb refuses a multiselect without
options and runner names are set elsewhere), copied from the dev board's
definition, one line `added the checks field dev.checks`, never a change to
an existing field, and nothing on a local board); then name the palette through
`PATCH /api/boards/{id}/colors/{color_id}` (the colours are found by `value`):
yellow `1 Pomodoro`, green `2 Pomodori`, blue `3 Pomodori`, red `>3 Pomodori`
and white `Unsized`, each with a legend description; then, with the palette
named, strip a trailing `(yellow)`, `(green)`, `(blue)`, `(red)` or
`(red, split)` from every card name with `PATCH /api/tasks/{id}`, setting the
colour from the word in the same call when the card's colour is white, unset or
the colour that was the default when the run began (so a card Pomb painted with
the old yellow default gets its real colour), and leaving the colour of any
other card alone, and repeating that for a name with several size words; then
enable exactly white, yellow, green, blue and red and disable every other colour
(orange, purple, magenta, cyan, brown and any other value) with
`PATCH /api/boards/{id}/colors/{color_id}` and `{"enabled": bool}`, enabling
first, one line per colour (`enabled white`, `disabled orange`), never deleting
a colour, and reporting each card that wears a disabled colour in one line
(`card <id prefix> wears the disabled colour orange, left as it is`, on every
run, the card's colour untouched); Pomb keeps `enabled` admin-only, so a 403 on
it prints one line
(`left the colours enabled as they are, since this token may not change them; run dev board init --admin`)
and the run carries on instead of exiting 1; last, make white the default, so a
run that stops early can be repeated and still know the old default. A name that
is only a size word is kept and reported. Labels are plain strings on cards in
Pomb, so `needs:lead` and `needs:human` need no creation. Each change prints one
line (`created board X from the agent project template`, `added column X`,
`moved column X to position N`, `marked Done as the column of finished cards`,
`named yellow "1 Pomodoro"`, `made white the default colour`,
`renamed card <id prefix> to "..." and coloured it blue`), and the last line is
`board X already follows the standard, nothing to change` or
`board X: N changes`. A failure prints `dev: <message>` with exit 1 after the
lines of the changes already made, and a `403` adds
`; this token may not change this board, run dev board init --admin`. Pomb 0.5.5
lets the lead token name colours, set the default and reorder columns only on
boards it created after 0.5.5, so the default token is the lead token
(`[board.pomb] lead_token = "pass:<entry>"` in the user file, read like `token`,
else exit 1 saying to set it or pass `--admin`), and `--admin` uses Pomb's
device sign-in instead (`dev.board.device`): `POST /api/v1/auth/device` with
`client_name` `dev-board-init@<host>` and `scopes` `["admin"]`, a printed
`approve the admin sign-in at <verification_url>` and `code: <user_code>`, then
`POST /api/v1/auth/device/token` every `interval_seconds` (5 more after
`slow_down`), ending on `access_denied`, `device_code_expired`, `invalid_grant`,
`quota_exceeded` or an unapproved sign-in after `expires_in_seconds`, each with
`dev: <reason>` and exit 1. The token comes back once, is held in the process's
memory for that run and goes to curl only as the `-K -` header line; the
`device_code` goes to curl as `--data-binary @<file>` in a mode-600 `mktemp`
file under `$TMPDIR` that is removed when the poll ends, so neither is in argv,
the environment, a file that outlives the run or the output, `-v` and `-vv`
included. The approver may grant a lower scope, so `GET /api/v1/auth/whoami`
must say `admin` or the run stops before any change: on a server that returns
`scope` it must be `admin`, and on one that returns `permissions` and `boards`
the token must hold every permission `GET /api/v1/auth/permissions` lists with
`admin` in its `presets` and `boards` must be `all` (`Backend:admin`). A 403
with `code` `permission_denied` is
`pomb answered 403: this token lacks the <permission> permission on every board; use a token that has it`
when `board_id` is null (the `--admin` hint applies) and
`this token has the <permission> permission but is not assigned to board <id>; add the board to the token`
when it is set (no hint). A board absent from `/api/boards` is
`pomb lists no board named X for this token, which is assigned only to ...` when
`whoami` returns a `boards` list, else `pomb has no board named X`.
`tests/lua/board_init_test.lua` runs the algorithm against a stateful fake
layout and the command against a fake `curl`.

The token is read by `timeout 10 pass show <entry>` with
`PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch"` and no stdin, so a
locked store fails at once with
`board unavailable: pass is locked or has no entry <entry>` (a timeout says
`pass timed out`). A token with any character outside `A-Za-z0-9._~+/=-` is
refused without being shown. The token reaches curl only as the config line
`header = "Authorization: Bearer ..."` on standard input (`curl -K -`, through
`dev.os.capture_input`): it is in no argument list, no environment variable, no
file and no message, and `BASH_ENV`, `ENV`, `PS4` and `VERBOSE` are unset for
`pass` and curl so `-vv` never traces them. The response is read from a
temporary file `capture_input` removes.

