# boards: Read and update a project's board with dev board, and every subcommand in detail

`dev board` reads and updates the project's kanban board, so an agent never
handles the board's API. It is machine-local: `--remote` and root refuse it.

```
dev board status
dev board init
dev board ls --column ready
dev board next
dev board add "Name the new thing" --column backlog --description "why" --size 2 --done-when "it works"
dev board ls --size 3+
dev board size 8af0e001 1
dev board add "Name" --size 1 --problem "why" --done-when "it works" --label needs:lead --label docs
dev board add "Name" --size 1 --problem "why" --done-when "it works" --checks "dev lint" --checks "dev test"
dev board label 8af0e001 needs:human --remove needs:lead
dev board ask 8af0e001 --question "Which way?" --choice "Ready=Take the first" --choice "Icebox=Park it" --recommend 1 --why "Only you can choose"
dev board answer 8af0e001 --choice 2 --quote "Take the second one."
dev board stale --days 7
dev board lint
dev board note 8af0e001 "Tests pass, landing now."
dev board note 8af0e001 --kind decision --as reviewer "Keep the two flags separate."
dev board notes 8af0e001
dev board show 8af0e001
dev board edit 8af0e001 < plan.md
dev board checks 8af0e001 "dev --remote lint" "dev --remote test"
dev board check 8af0e001
dev board check 8af0e001 --expect-fail --timeout 2400
dev board review 8af0e001 --kind code --by reviewer --rev @
dev board land 8af0e001
dev board allow 8af0e001 test-edits ci-edits
dev board allow 8af0e001 none
dev board tests 8af0e001 one_should_be_one tests::two
dev board files 8af0e001 src/a.rs src/b.rs
dev board outcome 8af0e001 "Two-line cards print in full."
dev board outcome 8af0e001 --rename 2 "A tick shows in show." --reason "it was vague"
dev board outcome 8af0e001 --tick 2
dev board outcome 8af0e001 --untick 2
dev board outcome 8af0e001 --delete 2 --reason "never achievable"
dev board outcome 8af0e001 --convert
dev board note 8af0e001 --edit 3ff0e006 "Tests pass, landed as abc123."
dev board note 8af0e001 --delete 3ff0e006
dev board move 8af0e001 progress
dev board order 8af0e001 3ff0e006
dev board take 8af0e001 --as project-alt/boardls
dev board release 8af0e001
dev board run --orders "Clear the board, then stop"
dev board run
dev board run --end
dev board sync
dev board wait --for ready
```

A project's `.dev/standalone/` is reserved for shell that must run where dev
cannot, such as a production server. Line 2 of each script there reads
`# standalone: runs on <where>, where dev is absent`, and `dev lint` warns on
any other `.sh` under `.dev` except a hidden `.dev/__*.sh` helper.

`dev board land` refuses a commit that adds a file under `.dev/standalone/`
unless the card carries the `standalone-ok` label, and the refusal names the
file. Only the owner adds that label, so `dev board label` refuses to add it
when `DEV_AGENT` is set, while removing it stays allowed. An agent that needs a
standalone script files a `needs:human` card instead.

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
instead of waiting on a prompt. `board/passlock.sh` runs it under one lock, the
directory `/tmp/dev-pass-<uid>.lock`, so
concurrent dev calls and keep-alive ticks queue instead of crowding the
hardware key. It waits up to 2 minutes for the lock and then fails like a timeout.
A lock whose owner pid is gone, or that is older than 30 seconds, is taken
over. A dev process reads each entry once, while the keep-alive loop reads it
on every tick.

On a machine with `/usr/bin/security` (macOS), the Keychain answers before
`pass`. `board/keychain.sh` keeps the token as a generic password named
`dev-pomb-token:<entry>`, one item per `pass` entry. `passlock.sh` reads it
first, with no lock and no hardware key. On a miss it reads `pass` under the lock
and stores the token.

The item is created through `security -i`, which takes the command on
standard input to keep the token out of every argument list. It is created
with `-T /usr/bin/security` to make reading it raise no prompt.

Every Keychain call runs under a 3 second timeout, and any failure, a locked
keychain included, falls through to `pass`. A machine without `security`
reads `pass` alone.

When Pomb answers 401 to a token from the Keychain, dev deletes the item,
reads `pass` once and repeats the request once, to replace a rotated token.
A delete that fails ends the retry, and the 401 is reported.
The keep-alive loop does the same on a tick.

`DEV_BOARD_TOKEN` carries a role token a lead issued. When it is set and not
empty, dev board sends it in place of the `pass` entry and reads neither `pass`
nor the Keychain, and the keep-alive loop does the same on a tick. When it is
unset or empty, dev reads the token file for the current `DEV_AGENT`, then
`pass` as above. A 401 under either is refused, with no retry and no fallback
to the `pass` token. The refusal says `the issued token in DEV_BOARD_TOKEN was
refused by pomb` for the variable and `the role token file for DEV_AGENT was
refused by pomb` for the file. An expired file is refused the same way, with
`mint it again`.

### Role tokens: token-mint

`dev board token mint --role ROLE --as NAME` gives a runner a role token when
a lead starts it by hand. It reads the role's id by name from
`GET /api/v1/agent-roles`, posts `{name, role_id}` to
`/api/v1/auth/tokens/children` with the lead token (`lead_token`), and prints
the role, the `agent-N` label and the expiry, never the token. Pomb sets the
expiry: one hour by default, at most eight, and never past the lead's own.

The token goes to a file named by a SHA-256 hash of NAME, mode 0600, in a
directory of mode 0700. The directory is `$XDG_RUNTIME_DIR/dev/tokens` when
that variable is an absolute path, else `dev/tokens` under the state
directory. The file holds the token on its first line and the expiry in Unix
seconds on its second. Every mint deletes the expired files it finds there.

The lead then starts the runner with `DEV_AGENT=NAME` and no token in its
environment or prompt. Because NAME is the claimant name, it follows
`repo/role[/card]`. The verb runs only for a lead, and so does
`delete`: both read one helper, which counts a `DEV_AGENT` as the lead when its
role segment (the second) is `lead`, as in `dotfiles/lead`, or when it
holds no slash. Any other role is refused.

Pomb refuses a name that a live token holds with a 409, and a name frees once
its token expires. dev shows that, an `unknown_role` and an `exceeds_grant`
in plain words. Minting again for a running runner is described under
token-remint, and `token revoke` ends a token early. A retry of a card reuses its
name, so it revokes the earlier live token first or waits for it to expire.

The token goes to curl on standard input as a config line. It is in no argument
list, no file and no output, `-v` and `-vv` included, and in no environment
variable but `DEV_BOARD_TOKEN` itself.

### Minting again when a token expires: token-remint

A role token lives at most eight hours, and Pomb answers 401 `token_expired`
once it ends. The runner holds no `tokens.issue`, so the lead mints again with
the same command, `dev board token mint --role ROLE --as NAME`. Pomb deletes
the account's expired issued tokens when it issues a child, so an expired
token's name is free at once and the new token reuses NAME with no suffix. The
file of NAME is replaced with the new token. Only a live or suspended token of
that name, matched without regard to case, gets a 409 `name_taken`, which the
verb refuses by naming NAME and leaves the file as it was.

A request that was refused with `token_expired` for the token it read from that
file reads the file once more. When the file holds another token, it retries
the request once with it. When the file still holds the same token, it fails
with the expired message and makes no second try. A token from
`DEV_BOARD_TOKEN` or from `pass` is never retried this way, and an expired one
fails with the expired message as before. A runner cannot mint for itself, and
dispatch's own re-mint is a separate matter.

### Ending a role token: token-revoke

`dev board token revoke --as NAME` ends the token that `token mint` issued as
NAME, once its run is over. It reads the lead token's own child tokens from
`GET /api/v1/auth/tokens/children`, finds the one named NAME, and revokes it
with `DELETE /api/v1/auth/tokens/children/{id}`. Pomb lists and revokes only
the children the calling token issued, so a token the lead did not issue is
out of reach. The lead is refused as `mint` and `delete` are, by the one lead
helper.

Pomb answers 200 once the token is revoked, and dev then deletes the file named
by the hash of NAME and prints `revoked the role token of NAME`. A NAME that no
live child holds, or a token Pomb answers 404 for because it is already gone,
leaves nothing to revoke: dev exits 0, prints `nothing was left to revoke for
NAME` and deletes a stale file for NAME. When Pomb refuses the revoke, dev
prints the reason, exits 1 and keeps the file.

## Which token each tool holds

Pomb groups permissions into four presets, each holding the one before it:
`read`, `work`, `lead` and `admin`. A token holds a preset or a custom
permission set, on all boards or on an assigned few. Each tool holds the
smallest preset that covers its calls, on the boards it works.

| Tool | Token | Calls it needs | Deletes it holds |
|------|-------|----------------|------------------|
| lead session | `lead_token`, `lead` | Everything `work` does, plus `boards.create`, `columns.create`, `columns.edit`, `columns.reorder`, `fields.create`, `colors.edit` and `tasks.bin`, for `init`, for the `dev board delete` verb, and `subtasks.delete` for `outcome --delete` | `tasks.bin`: a card goes to the bin for 30 days. `subtasks.delete`: any outcome |
| subagent and runner | `token`, `work` | Every read, `tasks.create` (add), `tasks.edit` (edit, labels, fields, restore), `tasks.move`, `tasks.claim` (claim, heartbeat, release), `subtasks.edit`, `subtasks.check`, `comments.write`, `links.write` | Its own comments and links. No card delete and no outcome delete: Pomb answers 403 `permission_denied` for `subtasks.delete`, and only the lead does either, with the lead token, and never an outcome from Ready on, where outcomes are fixed |
| runner | `work` on its board | Read the board, create and move cards, set fields and labels, comment, link, claim, heartbeat and release | None. Its `init` needs `lead`, which the lead runs |
| Aide agent | `work`, assigned boards only | The subagent's calls, notes written with `--as aide` | None. It never holds `lead` |

Every delete an agent holds is of its own work, except that only the lead
deletes an outcome, so a mistaken comment or
link never waits for the owner. Deleting from the bin, emptying it, and every
board, column or account delete stay with the owner, who holds `admin`.

A card delete is token policy, not something dev enforces on its own. Only the
lead decides and does one, and Pomb refuses a `work` token with a 403 naming
`tasks.bin`. A restore from the bin needs only `tasks.edit`.

The calls come from `board/pomb.lua`, a runner's Pomb contract notes and
Pomb's permission catalog. For the deletes, the table follows the Pomb 0.5.60
report: a `work` token deletes its own comments, links and outcomes, which the
older passages and the contract still call admin-only, though dev lets only the
lead delete an outcome. Those are tracked in
two cards, one for this file and one for the contract.

The review found no preset to change. The outcome delete is a Pomb right with
no dev call yet, and dev needs no token change for it.

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

- The columns Icebox, Backlog, Ready, In Progress, Review, Verify, Release,
  Blocked and Done, in that order, with Done counting as done. A missing board
  is made from Pomb's `agent project` template, and the missing columns are
  added and moved into place. A column named In Review is renamed to Review
  with its cards kept, through `PATCH /api/columns/{id}`, so no card is left in
  a column that no longer exists. A rerun changes nothing. A column it does
  not know stays, comes after Done and is reported as
  `kept column "X", which is not part of the standard board`. It renames
  no column but In Review.
- The agent roles: the planner, implementer, reviewer, verifier, release and lead
  roles, granted to the board. `init` posts `{"boards":[board id]}` to Pomb's
  `/api/v1/agent-roles/standard` right after the columns and prints
  `created agent roles` with the names the reply lists, or `agent roles unchanged`
  on a rerun, which is not counted as a change. A role that exists keeps its
  template. The endpoint needs `settings.write` and a board the token holds. A
  `permission_denied` is shown with the missing permission, and an
  `exceeds_grant` as `the token does not hold board X`, with nothing created. A
  local board has no roles, so it says nothing.
- Role refusals: a refusal reads the token's `role_name` from
  `GET /api/v1/auth/whoami`, once, and only then. A `permission_denied` 403 and
  an `exceeds_grant` 403 name the refused permission or action and the role, as
  `this token (role implementer) lacks the tasks.edit permission`. A token
  with no role gets the plain text with no role named. A 401 with the code
  `token_expired`, matched on the code and never the message, prints `the role
  token expired; mint it again from its issuer`.
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
- The limit group: when `GET /api/boards/{id}` lists no `limit_groups`, `init`
  posts `{"column_ids":[In Progress, Review, Verify ids],"limit":4}` to
  `/api/boards/{id}/limit-groups` and prints `created limit group In Progress,
  Review and Verify at 4`. A board that has any group is left alone and says
  nothing, and a local board gets none and stays uncapped. A 403 is shown with
  the `--admin` hint like the other changes. `dev board limits` shows the
  result.
- Labels need nothing: `needs:planner`, `needs:lead` and `needs:human` are
  plain strings on a card, and Pomb makes them when a card first carries one.

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

The standard columns are Icebox, Backlog, Ready, In Progress, Review, Verify,
Release, Blocked and Done. A finished column is any column the backend marks
done (`is_done` on Pomb, the same flag in a local board's file), and a board may
have several: `ls` hides all of them, `stale` never lists their cards, and a
blocker in one no longer blocks. The other roles come from a `[board.columns]`
table, read with the project file over the user file, and each role defaults to
its standard name, which `dotfiles/bin/.config/dev/config.toml` ships:

```toml
[board.columns]
icebox = "Icebox"
backlog = "Backlog"
ready = "Ready"
progress = "In Progress"
review = "Review"
verify = "Verify"
release = "Release"
blocked = "Blocked"
```

A project whose board renames a column sets the role to the new name, and may
add `done = "Shipped"` to name the finished column `discard` moves a card to,
else `discard` uses the first finished column in board order. A column argument
is a column's name in any case, a finished column's name or a role word:
`icebox`, `backlog`, `ready`, `progress`, `review`, `verify`, `release`,
`blocked` or `done`. `dev board init` lays out the mapped names, with the mapped
`done` (else Done) marked finished. The rules in this guide say Ready, Blocked
and the rest for the roles, whatever the board calls them.

Every card in every column is fair game for an agent unless it is labelled
`needs:human`. What each column means, in the order a card travels:

- Icebox: an idea, maybe later. A scoping agent sharpens, sizes and promotes
  cards to Backlog. A `needs:human` card here is an idea you want to flesh out
  yourself.
- Backlog: wanted, not ready to run. A card enters with a size, the card
  format v2 sections and an outcome. A planner refines the description, the
  outcomes and the checks, re-sizes it if needed (splitting a red card, which
  may become an epic over its children) and moves it to Ready.
- Ready: an agent can run it with no questions: size 1 to 3, v2, 3 to 7 outcomes (1 to 3 for an
  epic) and a checks row, which `dev board` enforces. The top card is next, and the
  order within Ready is the priority. A runner takes it by size: yellow by a
  haiku agent, green and blue by a sonnet agent.
- In Progress: an agent holds the card, under its name. Only the claimant works
  it.
- Review: the change is under review or ci. The claimant dispatches the
  reviewers, and when every review is clean and the check passes it moves the
  card to Verify. Still the claimant's.
- Verify: a verifier ticks the outcomes from the ci logs while the card sits
  here. Then `dev board land` lands it and moves the card to Release, or to
  Done when `[board.land] deploys` is not true.
- Release: where `[board.land] deploys` is true, land sends a card to Release,
  and it waits there to go live. `dev board ship` runs the release command
  or the `[board.release]` checks rows once and moves every card with all
  outcomes ticked to Done. `dev board move CARD done` moves one card and
  refuses while an outcome is unticked.
  A card in Review, Verify or Release with no claim waits for that stage's
  role. A claim means the role is working it.
- Blocked: waiting on an answer.
  - `needs:human` is yours alone, and only a question for you uses `dev board
    ask`. A question between agents is a blocked note holding the numbered
    menu.
  - `needs:planner` is for a planner. An implementer or reviewer who doubts a
    card's plan, an outcome above all, writes why in a blocked note holding
    the numbered menu of choices, moves the card to Blocked and labels it, and
    never rewords or deletes the outcome. A planner who did not
    build the card finds it with `dev board next --column blocked --for
    planner`, parks on `timeout 86400 dev board wait --for planner`, moves it to
    Backlog, keeps or rewords the outcome there or asks the lead to delete it,
    then moves it back to Ready. The agent that writes the outcomes never ticks
    them, a verifier does. A planner who cannot settle it runs
    `dev board escalate CARD TEXT`,
    which becomes `needs:lead`.
  - `needs:lead` is for a higher-tier agent, which answers and moves the card
    out.
  - A lead finds one with `dev board next --column blocked`, takes it before
    any Ready card, and parks on `timeout 86400 dev board wait --for lead`.
  - A lead that cannot answer asks you with `dev board ask`, which leaves the
    card in Blocked with `needs:human`. The chain is `needs:planner`,
    `needs:lead`, `needs:human`.
- Done: on main (and live where the project deploys), answered, or
  dropped with a note.

An agent with nothing Ready takes the top of Backlog and then Icebox, planning
the card first. It reads each card's comments before taking one. A steering
comment of yours (one that gives direction) is followed. The agent folds it into
the description and notes the decision. When it lists options, the agent picks
the one you favour and says why in the decision note. A list with no favoured
option is a choice only you can make.

A card is parked only when one of your comments defers it ("not now", "after X")
and no later comment lifts that deferral, or when a comment holds a choice only
you can make. A steer does not lift a deferral unless it says so. Parking sends
the card to Icebox or Blocked with `needs:human`, and the agent leaves it alone.

A plain question of yours is answered in a note, and the agent carries on with
the card. It parks only if the answer needs a choice only you can make, and
whether to defer a card is such a choice.

`needs:human` means only a human can answer. No agent answers for you on such a
card, and another agent relaying your view never counts. Agents never move, edit
or relabel one, except to set its size, and the label sits only in Blocked or
Icebox, never Backlog. dev enforces it: `edit` and `rename` refuse a card
labelled `needs:human`, and `move` refuses one headed for another column (exit
1). `label CARD needs:human` and `add --label needs:human` refuse a card
outside Blocked and Icebox, so move it there first and add the label after.
Only you move it out.
Setting the size is the third exception: an agent may run `dev board size CARD
1`, `2`, `3` or `3+` on such a card and change nothing else (until Pomb's
`fff0e011` ships, Pomb refuses it on a locked card and dev prints the reason).
A size answers no question, and an agent may change it to another size. An
agent never sets `unsized` on such a card. You set `unsized` yourself, with
`dev board size` in Icebox. The other two both end with an agent removing the
label: an agent that you answered directly in its own session removes the
label through `dev board answer CARD --choice N --quote TEXT` and carries on, and once you move a card
out of Blocked or Icebox, the first agent to see it elsewhere removes the
label and follows that column. `stale` lists such a card under `moved by the
owner`. Your own comment on the card, or that session answer, counts as the
answer only when it settles every open choice. A partial answer keeps the label. A `needs:human`
card whose newest comment is yours counts as answered and waits for your
move.

Pomb 0.5.59 locks a card labelled `needs:human`: it answers 403 `card_locked`
to a token for a comment (create, and edit or delete of its own), a move, a
reorder and a size change, and only a label change passes. dev prints that
reason instead of a generic failure.

An agent asks you with `dev board ask CARD --question TEXT --choice
COLUMN=LABEL... --recommend N --why TEXT`. It sends Pomb's structured question:
the question, two to ten numbered choices that each name the column the card
moves to, the recommended choice and why the agent cannot decide. Pomb moves
the card to the column marked blocked, which `dev board init` sets, adds
`needs:human` and refuses a part that is missing in its own words, which dev
prints as they come (exit 1). Pomb refuses `note
--kind question` without that shape, so `ask` is the only way to put a
question to you. `add --label needs:human` still creates the card and its
outcomes, then sets the label.

`dev board answer CARD --choice N --quote TEXT` records your answer through
Pomb's answer API. The quote must hold your own words and may not be empty:
dev refuses an empty one before it calls Pomb. Pomb removes `needs:human`,
moves the card to the destination of choice N and stores the answer as relayed,
with the token's name and the quote. It refuses a card with no open question.
You can also answer in the browser.

Until Pomb's `fff0e011` ships, `order` and `size` fail on such a card,
whatever the rule says. `label --remove needs:human` stays allowed in any
column.

An epic is a card of kind epic, which `add --epic` creates and `epic CARD` turns
an existing card into, and a `parent` link needs one. `ls` and
`next` print `[epic N of M open] ` before its name, and `[epic] ` while it has
no children, and `show` prints `kind: epic, N open` above the `parent` and
`children` lines. Once every child is Done it enters Ready and takes a claim
like any card. While a child is open, `next` never offers it, in any column, on
Pomb or a local board. It needs 1 to 3 outcomes as its final check, where any
other card needs 3 to 7, and it is claimed like any card once its children are
done. `move CARD done` closes it once every child is Done and refuses it while a
child is open.

To push a card later, drag it lower in Ready.

A card is named by its id or by a prefix of at least 8 characters that is unique
on the board. `ls` prints the id prefix, column, size, labels and name, with
Done left out unless `--column Done` asks for it. When a listed card has Done
when outcomes, a column such as `1/3` (ticked over all) follows the labels. The
size is the card colour's palette label, or `unsized`. `next` prints the top
Ready card that is unclaimed, not blocked and not labelled `needs:human`, with
its comment count and how many of those comments are the owner's after the card
line (`2 comments, 1 the owner's`, or `1 comment` for one), or `no ready cards`.
A local board has no owner comments, so it always counts 0 as the owner's.
`next --column backlog`, `icebox`, `review`, `verify` and `release` take the top
such card of those columns instead, or print `no cards in <column>`.
`next --column blocked` prints the top unclaimed card labelled `needs:lead`,
never one that also carries `needs:human`, or `no cards in Blocked`, and with
`--for planner` the top such card labelled `needs:planner`. Any other
column is exit 2.

`add` puts a card in Backlog unless `--column` names another column, and writes
the three card format v2 headings into the description (Problem, Change and Out
of scope), filling Problem from `--description`. A description that already
holds a heading or the v1 Done when is kept as it is, and an Icebox card gets
the text as given, with no headings. Each `--done-when TEXT` (repeatable, at
most 7) is a Done when outcome: `add` creates the card, then appends one Pomb
subtask per item. If an append fails, `add` exits 1 and names the card and the
outcome it stopped at, for example
`11111111 was added to Backlog but outcome 2 of 3 was not: ...`. Nothing is
rolled back (an agent token cannot delete a card, and deletes
a subtask only if that token made it) and the failure
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

Only Icebox holds a card that is unsized or free-form. Every other column takes
a card with a size of `1`, `2`, `3` or `3+`, all three v2 headings with text
under Problem, and, for `add` and `move`, at least one Done when outcome (a v1
`## Done when` item counts). A `move` of a card whose Pomb outcomes dev
cannot read is not refused for missing outcomes, except into Done and Ready.
`dev.board.unplanned` is the one check.
`add` refuses a card without them and names
what is missing (exit 2), `move` does the same (exit 1), and `discard` refuses
an unsized card or one without the headings but does not ask for outcomes (exit
1), so a card reaches Done unsized only by the Icebox `--reason` case below.
`size CARD unsized` is refused outside Icebox (exit 1), `edit` refuses a text
that drops a heading outside Icebox (exit 1), and a move into Icebox always
works. An epic follows the same rule with 1 to 3 outcomes in place of 3 to 7.

Sizing is part of planning, so a card also cannot enter Ready as red.
`move CARD ready` refuses a card that is unsized (white or no colour) or red,
more than 3 Pomodori, and says to run `dev board size CARD 1`, `2` or `3` (exit
1); a red card is split instead. `add --column ready` without `--size 1`, `2` or
`3` is a usage error (exit 2).

A card also needs card format v2 to enter Ready: all three headings with text
under each, no `Change:` or `Out of scope:` line under Problem, and 3 to 7 Done
when outcomes (subtasks). A card with none is still accepted when its
description has a v1 `## Done when` checklist item, until the boards are
converted. `move CARD ready` refuses a card without them and names what is
missing (exit 1), and `add --column ready` does the same for its description and
`--done-when` items (exit 2). Icebox cards are free-form, so adding to or moving
into Icebox is never checked. `add` fills the sections from `--problem`,
`--change` and `--out-of-scope`, and `--description` cannot go with them. A
repeated `--change` adds a line each, and a repeated `--problem` or
`--out-of-scope` is refused.

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
is unreachable, since sending the same rows twice changes nothing more. Both
`checks` and `add --checks` apply the write-time refusal of `dev board check`
to every row, so a row holding a shell character (a quote, a backslash, `*`,
`|` and the rest), starting with a dotted run such as `dev.--remote.lint` or
passing a word to `dev --remote test` or `dev --remote lint` before the double
dash is a usage error (exit 2) naming the row and nothing is written. A test
name goes after the double dash, as in `dev --remote test -- NAME`. A
leading `! ` is allowed. Rows already on a card are not rewritten. `show`
prints the rows under the description. Icebox is exempt.

A planner also runs each new rg row against a small sample of the intended
result and confirms it passes, matches behaviour rather than a name the builder
may choose, and checks every rule number or section the card names against the
file. A must-not-match row (`rg --files-without-match`) names one file, as with
several it passes when any one lacks the text, and the planner reads the code
each Change bullet relies on before filing.

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
`parent: <id prefix> <name>` under the `ls` line, and an epic
`children: N of M done`.

`edit CARD` replaces a card's description with the text of `--file PATH`, or of
standard input when there is no `--file`, and prints `edited <id prefix>`. The
format v2 description always holds the current plan, so rewrite it after a
decision. Trailing whitespace is dropped, and empty text is a usage error (exit
2), to keep an empty pipe from wiping a plan. It sends the claim's fence when
this machine holds one. It does not touch the title or the comments.

`note CARD --kind K --as ROLE TEXT` tags the comment: `K` is decision, blocked,
status or done (agent when omitted), and `ROLE` is a free label of at most 80
characters, such as planner, implementer or reviewer, that lets agents sharing
one token tell themselves apart. `question` is exit 2 and names `dev board ask`,
which sends the owner a question in Pomb's structured shape. A note that begins
with a dash still posts as text. `--edit` changes only the text, so the kind and
the label stay, and a queued note replays with both.

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
is plain text. `outcome CARD --rename N TEXT --reason TEXT` rewords the Nth
(the first `--reason` ends the new text), `--tick N` marks it done and
`--untick N` clears it (`PATCH /api/tasks/{id}/subtasks/{sub_id}`
with `name` or `done`), each printing `outcome <id prefix> N reworded`, `ticked`
or `unticked`. N counts from 1 in the order `show` lists the outcomes, and an N
past the last outcome is exit 1. A tick names its ticker with `--as NAME` after
the number (`outcome CARD --tick N --as NAME`), else with DEV_AGENT, and prints
`ticked by NAME`. On a claimed card the ticker must be a name other than the
claimant's: no name is exit 2 and the claimant's own name is exit 1, with
nothing written. The name is self-declared, so dev checks only that it differs
from the claimant. An unclaimed card needs no name, and a DEV_AGENT that is not
one word is ignored there. `--untick` takes no name and stays open to anyone.
`--as` is read only after `--tick`, `--delete` and `--convert`; on the other forms it is
ordinary text, so `--untick N --as X` is exit 2 for its extra words. A queued
tick keeps the name it resolved, so a later sync records the same ticker.
`outcome CARD --delete N --reason TEXT [--as NAME]` removes the Nth outcome
(`DELETE /api/tasks/{id}/subtasks/{sub_id}` on Pomb) from a card in Blocked,
Backlog or Icebox. Outcomes are fixed from Ready on. A card in a column mapped
to the ready, progress, review, verify or release role, in a finished column, or
in a column outside the role map is refused with exit 1 naming the column, with
nothing written or queued. The roles come from `[board.columns]` and `is_done`,
never from a column name. Only the lead deletes an outcome: a `DEV_AGENT` whose
role segment is not lead is refused with exit 1 and nothing written, before any
backend call, and a runner, implementer, planner or reviewer asks the lead with
the card, the number and the reason. The outcomes after it move up a number, and
the command writes a decision note holding the deleted text and the reason, then
prints `outcome <id prefix> N deleted`. A missing number or reason is exit 2.
`--reason` is the one way to say why an outcome that was never achievable is
deleted and not reworded. On a Pomb board the DELETE goes out with the lead
token, `lead_token` in `[board.pomb]`, never the work token, and never
`DEV_BOARD_TOKEN` or the token file for `DEV_AGENT`, which every other verb
reads first. Pomb 0.5.78 gives `subtasks.delete` to the lead tier only. A
missing `lead_token` exits 1 before any request, naming `subtasks.delete` and
the lead token. A 403 `permission_denied` for `subtasks.delete` exits 1 with a
message that names `subtasks.delete` and the lead token, and writes no note. A
local board needs no lead token. A locked card gets 403 `card_locked` for every
token, and a column entry rule can refuse a delete that leaves the card worse.
`--delete` prints Pomb's reason for each refusal, writes no note and changes
nothing. A delete is never queued for a later sync, to keep its number from
pointing at a different outcome by then. dev never reorders an outcome. The
claim's fence goes along when this machine holds one, and a local board keeps
the same outcomes on the card.

The card's claimant and every name in its claim history (the `dev-claim:`
notes that `review` reads) are refused an outcome add, `--convert`,
`--delete`, `--rename` and `dev board checks`, with exit 1 and nothing
written. The builder passes a change back with a note instead, to stop a
released runner from rewording the card and taking it back. The
refusal compares the names with `DEV_AGENT` and, after `--delete` and
`--convert`, with the `--as` name.
`checks` reads `DEV_AGENT` only. The lead
(a name with no `/`) and any name that never claimed the card may change
outcomes and checks, except that only the lead deletes an outcome. A session
with no `DEV_AGENT` is not checked.

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
else is a usage error (exit 2). The escalation labels `needs:planner`,
`needs:lead` and `needs:human` are plain labels to dev. Two agents editing the same card's labels
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
`dev board link CHILD parent EPIC` makes the other card the epic of the
first, and dev refuses an `EPIC` that is not an epic before any request,
naming `dev board epic EPIC`. A card has one epic and epics nest to any
depth, so Pomb refuses a second epic and a link that would make a cycle,
and a local board refuses them too, naming the two cards the link joins.
Epics count their direct children. A local board stores the links on its own
cards, links only its own cards, and its `next` skips a card that a card
outside Done blocks.

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

`attach CARD FILE...` uploads each file to a Pomb card and prints `attached <id
prefix> <name>`, or `skipped <name>` when the card already holds a file of that
name, so a rerun uploads nothing twice. `attachments CARD` lists the card's
files, one line each with the id prefix, the size in bytes and the name, or
`no attachments`. `detach CARD ID` removes the attachment whose id starts with
ID and prints `detached <id prefix> <name>`. dev checks no size and no type:
Pomb enforces its own limits and dev prints its refusal as Pomb words it. A 503
`busy` answer is retried after a short nap. A token without `attachments.delete`
gets the permission message, and agents do not detach. A local board refuses all
three with `a local board holds no attachments`. None of them is queued while
Pomb is unreachable.

`stale [--days N] [--icebox-days N] [--lead-hours N]` lists the cards that have
sat in Backlog, Ready, In Progress, Review or Verify for N days or more, 7 by
default, oldest first. Each line is the id prefix, the column, the
days in it (`9d`), the size and the name. It counts whole days from the card's
`column_entered_at`, which Pomb gives every task view, so a card at 6 days is
fresh and one at 7 is stale. Icebox, Blocked and Done are never stale. Every
card with the `needs:human` label in Blocked or Icebox, at any age, is listed
apart under `for the owner (needs:human):` with its column and days in column,
and never among the stale ones (it waits on the owner, not on an agent). A card
with that label in any other column but Done is listed apart under `moved by the
owner, remove needs:human:`, to show that the owner moved it out and an agent
should take the label off (per the board guide). A card in one of those
columns, or with that label, that the tasks view did not date gets a line `could
not date <id> <name>` after a blank line, instead of being skipped. When nothing
is stale it prints `no stale cards`. A `--days` that is not a whole number of 1
or more is a usage error (exit 2). Every card labelled `needs:lead` (and not
`needs:human`) that has sat in Blocked for `--lead-hours` hours or more (1 by
default) is listed apart under `for a lead (needs:lead):`, with its time as
`<hours>h`. A card labelled `needs:planner` in Blocked for as long is listed the
same way under `for a planner (needs:planner):`. Every card that is unsized (white or no colour), in any column but
Icebox, is also listed at any age, apart, under `unsized outside Icebox:` with
its id prefix, column and name, so a planner sees what still needs a size. Last,
under `icebox, untouched for N days:`, it lists the Icebox cards nobody has
looked at: the card's time in Icebox and its latest comment are both
`--icebox-days` days old or older (30 by default), counted from the later of the
two. Cards labelled `needs:human` are left out, and the section is absent when
no card qualifies. A card it cannot date, or whose comments it cannot read, gets
a `could not` line after the section. An orchestrator can run it at startup and
re-plan, escalate or ice each card it lists, and scope the Icebox ones.

`lint [--strict]` reports every card that breaks the board's rules. The guards
in `move`, `add` and `discard` stop a bad write only when it goes through
`dev board`, and lint also sees the cards written in the Pomb UI, by another
client or before a guard existed. It makes no write of its own and calls no
model. Like every board command on a Pomb board, it first replays any queued
changes. Each finding is one line of id prefix, column and rule, in board
order. A finding only the owner can fix ends in `(owner)`: any finding on a
`needs:human` card, except a missing size and a `needs:human` label outside
Blocked and Icebox, which an agent fixes. The exit is 1 when any finding is
left that an agent may fix, and 0 with `no findings` or when every finding is
the owner's, so a card whose checks run lint can land while the owner has an
open question. `--strict` exits the same way. The rules:

- Outside Icebox: a size, the three v2 headings with text under Problem, and a
  Done when outcome. This is `dev.board.unplanned`, the check `move` makes,
  which keeps a move and lint in agreement. Where a card's sections are checked
  (outside Icebox and not Done, or every Done card under `--strict`), lint also
  reports the shapes of `dev.board.shapes`, which `move CARD ready` shares: no
  text under Change or Out of scope, and no `Change:` or `Out of scope:` line
  under Problem. A Done card gets the size and outcome checks only, and a Done
  card labelled `discarded` needs no outcome. An epic, a card with children,
  needs 1 to 3 outcomes, so lint reads the children of every card it checks for
  outcomes.
- With `--strict`, a Done card also needs the three v2 headings with text under
  Problem. A discarded card is held to the rule `discard` applies. Older Done
  cards are v1 and fail it until their descriptions are rewritten.
- Outside Icebox and Done: a description of at most 400 words. In Ready, In
  Progress and Review, a checks row. In Ready, no red size.
- `needs:human` sits only in Blocked or Icebox.
- A Blocked card holds a `question` or `blocked` note or a `blocked_by` link.
- An In Progress card holds a claimant, an epic too.
- A Done epic that was not discarded has every child Done: `N of M children
  open`.
- A Done card that was not discarded has every outcome ticked.

A card whose outcomes Pomb sent in a shape dev cannot read is reported as
`outcomes unreadable`, never as having no outcomes. Fixing a finding is the
agent's job, except on a `needs:human` card, which belongs to the owner apart
from its size: an agent may set that with `dev board size CARD 1`, `2`, `3` or
`3+`.

A project makes `--strict` its default with a `[board.lint]` table in
`.dev/config.toml`. The file may be the project file or the user file, as with
`[board]`. `strict` must be `true` or `false`, otherwise `dev board lint` exits
1 and names the setting:

```toml
[board.lint]
strict = true
```

## Local boards

`backend = "local"` keeps the board in one JSON file, so a project needs no Pomb
server. Every command works on it, with the same nine columns, size colours and
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
`link`, `edit` and `outcome` with `--tick` or `--untick`, which are safe to
repeat, are queued for those, whereas `add`, `note`, an `outcome` append,
`outcome --rename` (a replay would note the new text as the old) and
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
parks on it instead of polling or ending idle right away. Run it in the
background under `timeout`, and its exit wakes the session:

```
timeout 86400 dev board wait --for ready
timeout 86400 dev board wait --for human
timeout 86400 dev board wait --for lead
timeout 86400 dev board wait --for planner
```

`--for ready` wakes on a card added to Ready or moved into it and prints `added
<id prefix> to Ready` or `moved <id prefix> to Ready`. `--for review`, `--for
verify` and `--for release` do the same for that column, but only for a card
nobody has claimed. `--for human` wakes on a card the owner moved out of Blocked
(`moved <id prefix> out of Blocked`, and a move by an agent never wakes it, nor
does a move made before the wait started) and on a card, in any column but
Done, whose newest comment is the owner's and newer than the wait's start
(`the owner commented on <id prefix>`). A comment of an agent never wakes it.
The first such event opens a settle window of 60 seconds: the wait keeps
listening until no new event from the owner has come for that long, to catch a
second reply, then prints one line per card the owner touched, not one per
comment. The woken agent reads every comment with `dev board show`. `--for
lead` wakes on a card added, moved or updated that is now in Blocked with the
`needs:lead` label, no claim and without `needs:human`, and prints `<id
prefix> is labelled needs:lead in Blocked`. `--for planner` does the same for
`needs:planner` and prints `<id prefix> is labelled needs:planner in Blocked`.
Pomb's events carry no labels, so it reads the board for each batch of events.
With no `--for`, every added card, move, update and comment wakes it. Any
other `--for` value is a usage error, and a local board is `dev: a local board
has nothing to wait on` (exit 1). `wait` is never queued.

The command asks Pomb for events after a cursor and holds each request for up to
50 seconds, repeating on a quiet board until a matching event arrives. It keeps
the cursor in `~/.local/state/dev/boards/<name>.<mode>.cursor` (`ready`, `human`,
`lead` or `all`), readable by you alone and saved after every reply, so a change made
while no wait was running wakes the next one, except that `--for human`
ignores a move made before it started. With no cursor file the first call
starts from now. When Pomb has dropped the events after the stored cursor,
`wait` stores the oldest one it still has, prints
`events were trimmed, check the board` and exits 0, so look at the board and run
it again. `--for human` instead keeps waiting on a trim, and exits only when a
card that sat in Blocked or Icebox when it started has left it.

Pomb being unreachable (no route, a locked `pass`, a gateway error) is retried
every 30 seconds, up to ten failures in a row, and then `wait` exits 1 with the
message. Pomb allows 4 open waits per token and every session shares one, so a
fifth session gets a 429 with the code `too_many_waits`. That is never a
failure: `wait` prints one line on standard error the first time, then retries
with a pause that doubles from 30 seconds to 5 minutes, each pause cut by a
random fraction of up to a quarter to keep sessions from retrying together, and
keeps waiting until a slot frees. Any other refusal, such as a bad token, exits
1 at once. Exit 124 from `timeout`, or 143 from the `run_with_timeout` wrapper
in the background-work rules, means nothing changed. With nothing to do and no
card in flight, end the session (a session started later under the same
`DEV_AGENT` picks its open run card up with `dev board run`). Otherwise park
again.

## Claims

`take` claims a card so no other agent picks it up, and starts a loop that keeps
the claim alive. The claim lasts 900 seconds. The loop renews it every 5 minutes
with curl, so it costs no model turns and outlives the shell that started it.
Its claimant is the name from `take --as NAME`, else the `DEV_AGENT` environment
variable, else `dev@<host>:<session or pid>`. A name is one word of letters,
digits and `.`, `-`, `_` and `/`, else exit 2. `ls` shows it as the holder.
Agents name themselves `repo/role[/card]`, written `<repo>/<role>[/<card>]`:
the board name, any role word (usually `lead`, `runner`, `planner`,
`implementer`, `code-examiner`, `style-examiner`, `recheck-examiner`,
`verifier`, `land`, `release` or `check`) and an optional card id, as in
`dotfiles/lead` and `dotfiles/implementer/f5f0e007`. Each part is letters,
digits, `.`, `_` and `-`. A name of another shape is refused with `an agent
name is <repo>/<role>[/<card>], got NAME` (exit 2) when `take` or a `move` into
In Progress would take a new claim, whether it came from `DEV_AGENT` or `--as`.
Every other verb on a card already claimed under that exact name passes, so a
card claimed under an older name finishes and lands under it. An unset or empty
`DEV_AGENT` is accepted.
`move CARD progress` takes the claim itself, under the same name and with the
same keep-alive loop, when nobody holds the card, except a card with children,
which stays unclaimed. A claim this machine already holds is kept, and one held
by someone else leaves the move to fail as the backend answers. After a claim
it takes, `take` prints the card as `show` does, with every comment in full,
and so does a `move` into In Progress that takes the claim, so the owner's
comments are read before any work. A `move` that finds the claim already held
prints only the `moved` line.

`move` refuses to take a claimed card out of In Progress to Review, Ready or
Blocked (exit 1) until its claimant has left a note since claiming it, and the
refusal says the note holds what was built, tried and learned. dev finds the
note by who posted it, never by its text or `--as` label. The claim writes a
`dev-claim: by=NAME` comment.

The claimant's note is any later comment posted by the same Pomb token as the
latest such record for the claimant, unless its body
begins with a prefix a dev verb writes (`dev-check:`, `dev-review:`,
`dev-turn:`, `dev-claim:`) or its kind is decision. A client that posts through
the claim's token satisfies it with any text. A card with
no claim record for its claimant is not checked. A move after the note releases
the claim as before.

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
mode 600. It never holds the token. The loop reads the token for each
renewal, from the Keychain or else `pass`, and hands it to curl on standard
input to keep it out of every argument list, environment variable, file or
output. While you hold a claim, `move` and `note` send its fence, and `ls` shows each live claim's holder in a column
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
- `next [--column C] [--for planner|lead] [--max-size N]`: The top Ready card that is unclaimed, not
  blocked and not labelled `needs:human` or `run`, in the `ls` format followed
  by `N comments, M the owner's` (`1 comment` for one), else `no ready cards`
  (exit 0). Comments that cannot be read are exit 1. `--column backlog`,
  `icebox`, `review`, `verify` or `release` takes the top such card of that
  column instead, else `no cards in <column>` (exit 0). `--column blocked` takes
  the top unclaimed card labelled `needs:lead`, or with `--for planner`
  `needs:planner`, never one labelled `needs:human`
  and, like every `next`, never one that a card outside Done blocks, nor an epic
  with a child that is not Done. A blocker on another board counts only while
  it is outside Done, and a card on that board that cannot be read counts as
  open. The Ready column also sends Pomb's `ready=true` filter. Any other
  column is exit 2. `--max-size N` (1, 2 or 3, else exit 2), or
  `DEV_MAX_SIZE` when the flag is absent, skips a card bigger than N Pomodori
  to keep a small model from taking a bigger card. A card with no size
  passes. With neither set, nothing is skipped.
- `boards`: The name of every board the token sees, one per line
  (`GET /api/boards`, which leaves out the boards outside a fine-grained
  token's set). On a local board it prints that board's own name. An extra
  word is exit 2.
- `whoami`: `dev board whoami` shows the credential dev board uses, one
  `key: value` line each, from `GET /api/v1/auth/whoami`: `name`, `kind`,
  `scope`, `role`, `label`, `issuer`, `expires` (UTC, `never` when the
  credential does not expire),
  `boards` (`all`, or the board names) and `permissions`. A token issued as no
  role shows `none` for `role`, `label` and `issuer`. `issuer` is the name of
  the lead token that issued it, as it was then. The token is never printed. A
  401 reads as every other refusal does, with `mint it again` for an expired
  role token, and a local board holds no credential, so it is exit 1. An extra
  word is exit 2. The drift of a role token from its template is not listed
  (Pomb's whoami does not return it).
- `columns [BOARD]`: The columns of the board named BOARD, else of this
  project's board, one per line in board order, with ` (done)` after a column
  that finishes a card (`GET /api/boards/{id}`, `columns`). A board the token
  does not see is exit 1 and says no board has that name. A local board
  answers only for its own name and refuses any other with exit 1. A second
  word is exit 2.
- `limits [BOARD]`: The limits of the board named BOARD, else of this
  project's board, from a fresh `GET /api/boards/{id}`. It prints one line per
  column limit as `COLUMN: N UNIT`, where UNIT is `count` or `hours` from the
  column's `limit_unit`, then one line per limit group as `COLUMN, COLUMN:
  N (C in flight)`, where C is the group's `count` and a group always counts
  cards. A board with no limit group is exit 1 and the last line says `no
  limit group`, and so is a local board. A second word is exit 2.
- `add NAME [--board B] [--blocked-by CARD]... [--from CARD] [--id-only] [--column C] [--description TEXT] [--problem TEXT] [--change TEXT]... [--out-of-scope TEXT] [--size S] [--label L]... [--checks CMD]... [--done-when TEXT]...`:
  Creates the card, in Backlog by default, and prints
  `added <id prefix> <column>`. `--size` gives it the colour of the size, as
  `size` does, and each `--label L` (repeatable, duplicates dropped) gives it a
  label. Unless the column is Icebox, the description is given the three card
  format v2 headings (`## Problem`, `## Change`, `## Out of scope`) with
  `--description` text filled into Problem, or each section filled from
  `--problem`, `--change` and `--out-of-scope` (these cannot go with
  `--description`, exit 2, and `dev.board.compose` builds the text). Each
  `--change TEXT` (repeatable) is one line of the Change section, in the order
  given, and a repeated `--problem` or `--out-of-scope` is a usage error naming
  the flag (exit 2) to keep any text from being dropped silently. A text that
  already holds one of those headings or the v1 `## Done when` is kept as it
  is; an Icebox card gets the text as given and none otherwise.
  `--board B` files the card on the Pomb board named `B` from any repo, using
  this repo's column names; a board Pomb does not list is refused (exit 1)
  before anything is added, and a local board refuses it. Each
  `--blocked-by CARD` (repeatable) links the new card as `blocked_by` that card,
  looked up on the board the card is filed on (`BOARD:CARD` reaches another),
  and an unknown blocker is refused before the card is added. `--from CARD`
  links the new card as `related` to the card it came from, looked up the same
  way, and an unknown card is refused before anything is added. If a link then
  fails, `add` exits 1 naming the card and the other card, and the refusal is
  not queued for a later sync.
  `--id-only` prints the full card id alone on standard output in place of that
  line, for a script to capture. Warnings still go to standard error, and a
  failed add prints nothing on standard output. An `add --id-only` that cannot
  reach Pomb is refused and never queued (a queued add has no id to print).
  `--column ready` without a `--size` of `1`, `2` or `3` is a usage error (exit
  2), by the same rule as `move`, and so is any other column but Icebox (Backlog
  by default) for a card with no size, a description that lacks a heading or text
  under Problem, or no `--done-when` outcome
  (`a card outside Icebox needs a size, card format v2 and Done when outcomes, and this one lacks ...`,
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
  Each `--checks CMD` (repeatable, a blank one or one that `dev board check`
  would refuse is exit 2, as for `checks`) gives the card one row
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
- `escalate CARD TEXT`: Hands a `needs:planner` card up to `needs:lead`. On
  Pomb it is one `POST /api/tasks/<id>/escalate` with `{tier, reason}`, where
  TEXT, which holds the numbered menu of choices, is the reason. Pomb writes
  the blocked note and swaps the tier label in that one write, so the call
  needs only `comments.write` and the implementer, reviewer, verifier and
  release roles may use it. The claim's fence goes along when this machine
  holds one. A local board appends the blocked note and swaps the label in one
  update. It prints `escalated <id prefix> to needs:lead`. The column stays.
  A card without `needs:planner` and an empty TEXT are refused before anything
  is written (exit 1 for the card, exit 2 for the text). A refusal from Pomb
  (a locked card, a stale fence, a missing permission) is exit 1 with Pomb's
  message, and nothing is written. It refuses `--question`, `--choice`,
  `--recommend` and `--why` (exit 2) and points to `dev board ask`, which only
  the owner's questions use.
- `answer CARD --choice N --quote TEXT`: Records the owner's answer, typed
  in this session, on a `needs:human` card. It removes `needs:human`
  from the card's labels (the other labels and the column stay), then posts
  one decision note, `Owner's answer, typed in this session: choice N, quote:
  TEXT`, both with the claim's fence when this machine holds one, and
  prints `answered <id prefix> with choice N`. The words after `--quote` are
  the quote. A card without `needs:human`, a missing flag, a `--choice` that
  is not a whole number from 1 and an empty quote are refused (exit 1 for
  the card, exit 2 for the rest) before anything is written. Pomb refuses a
  comment on a labelled card, so the label goes first. A note that
  fails after the label is gone is exit 1 and prints the `dev board note
  CARD --kind decision` command with the full text, so the quote is not
  lost. `answer` is never queued, to keep a replay from posting the note
  twice. dev cannot tell a typed answer from a
  relayed one, so the verb is for the agent whose own session the owner
  answered in.
- `epic CARD`: Turns a card into an epic with `PATCH /api/tasks/{id}` and
  `{"kind": "epic"}` (`tasks.edit`) and prints `made <id prefix> an epic`. Pomb
  answers a live claim with a `409` `claim_held` and a card that is already an
  epic with a `400`, and dev prints Pomb's words and exits 1. A local board
  stores `kind` on the card and refuses a card that is already an epic. Turning
  an epic back into a plain card is not supported. `add --epic` creates the card
  with `"kind": "epic"`, on a local board too.
- `link CARD KIND OTHER`: Links a card to another and prints
  `linked <id prefix> <kind> <other>`. `KIND` is `blocked_by`, `blocks`,
  `related` or `parent`, else exit 2. `parent` is held by the child and names
  the epic as `OTHER`, which must be an epic (dev refuses any other card with
  `<id prefix> is not an epic, make it one with dev board epic <id prefix>`
  before any request). Epics nest to any depth and a card has one
  epic, so Pomb answers a second epic or a cycle with a `400` (exit 1),
  and a local board refuses the same itself (`the card already has an
  epic`, `the link would make a cycle of epics between A and B`) while
  linking the same epic twice changes nothing. `OTHER` is a card of this board (an id or a prefix of 8 hex
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
- `attach CARD FILE...`: Sends each file to `POST /api/tasks/{id}/attachments` as
  a multipart `file` part, after one `GET /api/tasks/{id}/attachments` that
  lists the names the card holds. A name already held prints `skipped <name>`,
  any other prints `attached <id prefix> <name>`. Pomb's refusal for a file
  (size, type, `quota_exceeded`, `duplicate_attachment`) prints as Pomb words it
  after the file's name, the other files still upload, and the exit is 1. A 503 `busy` is retried twice after a 2 second nap. A local board
  refuses it.
- `attachments CARD`: Prints `<id prefix>  <size>  <name>` for each attachment in
  the order Pomb lists them, else `no attachments`. A local board refuses it.
- `detach CARD ID`: Finds the attachment whose id starts with ID in the card's
  list, sends `DELETE /api/tasks/{id}/attachments/{attachment_id}` and prints
  `detached <id prefix> <name>`. An id that matches none or several exits 1. A
  403 `permission_denied` for `attachments.delete` is reported by the permission
  message. A local board refuses it.
- `delete CARD --reason TEXT`: Moves a card to Pomb's recycle bin for the lead.
  It reads `lead_token` from `[board.pomb]`, not `token`, adds a `decision`
  comment `the lead deletes this card, reason: TEXT` to keep the reason on
  the card when it is restored, then sends `DELETE /api/tasks/{id}` and prints
  `moved <id prefix> to the bin`. A `DEV_AGENT` that is not a lead
  name is refused with exit 1 before any token is read or any call is made. A
  lead name has a role segment (the second) of `lead`, as in
  `dotfiles/lead/CARD/1`, or holds no slash, and `token mint` reads the same
  helper. A local board has no bin and exits 1.
  Pomb's refusals print as they come: a `permission_denied` 403 names the
  permission and board, and `card_locked` says the card is locked. A locked
  card refuses the comment first and keeps nothing. A delete Pomb refuses after
  the comment leaves the comment on the card. The change is not queued
  while Pomb is unreachable. Emptying the bin and deleting from it stay with
  the owner.
- `stale [--days N] [--icebox-days N] [--lead-hours N]`: Lists the cards that
  have sat in Backlog, Ready, In Progress, Review or Verify for N days or more
  (7 by default), oldest first, one line each: id prefix, column,
  `<days>d`, size and name, aligned. Days are whole days from the card's
  `column_entered_at` (Pomb's task view, RFC 3339, read with
  `dev.cmd.box.parse_time`) to now, so 6 days is fresh and 7 is stale. Icebox,
  Blocked and Done are never stale. Every card carrying the `needs:human` label
  in Blocked or Icebox, at any age, is listed apart, after a blank line and the
  heading `for the owner (needs:human):` (same columns; the name ends
  `(answered, waiting for your move)` when the newest comment is the owner's),
  never among the stale ones. Every other card but Done and not listed above
  whose newest comment is the owner's is listed apart under the heading `newest
  comment is the owner's:` (same columns), whatever its label and age. Every
  `needs:human` card in any other column but Done is listed apart after them
  under the heading `moved by the owner, remove needs:human:` (same columns, no
  answer note). Every card outside Icebox that is white or has no colour is
  listed apart too, at any age, after a blank line and the heading `unsized
  outside Icebox:`, one line each with id prefix, column and name, in board
  order; sizing happens in planning, so a card that waits unsized is a planner's
  to size. A card in those columns or with that label that the tasks view did
  not date (missing from the pages, or no `column_entered_at`) gets one line
  `could not date <id> <name>` after a blank line. `no stale cards` when the
  first list is empty. Last comes the Icebox section: every Icebox card without
  `needs:human` whose column time and latest comment (`backend:comments`) are
  both `--icebox-days` days old or more (30 by default) is listed after a blank
  line and the heading `icebox, untouched for N days:`, oldest first, with the
  same columns as the first list, the days counted from the later of the two
  times. A card with no comment counts by its column time. A card the tasks view
  did not date, or whose comments could not be read, gets a `could not date` or
  `could not read the comments of` line after the section, and the section is
  absent when no card qualifies. Always exit 0 unless the board cannot be read
  (1); a `--days` or `--icebox-days` that is not a whole number of 1 or more is
  exit 2.
- `lint [--strict]`: Reads every card (`backend:cards`) and prints one line per
  broken rule: id prefix, column and rule, aligned, in board order. A finding
  on a `needs:human` card ends in `(owner)`, unless it is `lacks a size` or
  `needs:human outside ...`, which `dev.board.lint.card` reports as agent
  findings (its third return value holds the indexes of the owner's). It exits
  1 only when a finding without the mark is left. A clean board prints
  `no findings` and exits 0. A flag other than
  `--strict` is exit 2. `--strict` is also on when `board.lint.strict` is
  `true` in the config (`config.get`, project over user file), and a
  non-boolean value is exit 1. The rules live in `dev.board.lint`, which calls
  `dev.board.unplanned` for the size, the v2 sections and the outcomes. A Done
  card passes `sections = false` unless strict, and a `discarded` one passes no
  outcome check, which is what `discard`'s guard does. It adds, outside Icebox
  and Done, `over 400 words (N)`, `no checks row` in Ready, In Progress and In
  Review for a card with no children, and `red card in Ready`. Anywhere it
  adds `needs:human outside Blocked and Icebox`. In Blocked it adds `blocked with no question or blocked
  note and no blocker`, reading `backend:comments` for a `question` or
  `blocked` kind and then `backend:links` for `blocked_by`. In In Progress it
  adds `in progress with no claimant`, and in Done `N of M outcomes unticked` unless discarded, and `N of M children
  open` when the card has an open child. Every card asked for outcomes reads
  `backend:family` for its child count, which sets the 1 to 3 an epic needs. A
  card with `outcomes_unreadable` gets `outcomes unreadable` and no outcome
  rule. A read that fails is exit 1 with the message. It writes nothing
  itself, but the dispatcher replays the queue first, as for every Pomb
  command.
- `notes CARD`: Lists the card's comments (`GET /api/tasks/{id}/comments`),
  oldest first, one line each: comment id prefix (8 characters), the token's
  name (else the actor kind), the comment's kind (`-` for none), its role label
  (`-` for none, and Pomb's default `api-token` counts as none), the time to the
  minute in UTC and the first line of the body, aligned. `no comments` when
  there are none.
- `show CARD`: Prints the card as `ls` does (id prefix, column, size, labels,
  name), a blank line, its description (`no description` when empty), a blank
  line and its comments as `notes` lists them with every line of each body
  in full, the later lines indented under the first, so an agent reads a whole
  card without the API or the token. The description comes from the same
  `/export-data` read `ls` makes, and `GET /api/tasks/{id}/comments` gives the
  comments. After the description it prints `done when:` and one
  `- [x] <outcome>` or `- [ ] <outcome>` line per outcome (Pomb's `subtasks` in
  the `/export-data` task row), then a blank line, when the card has any. A
  card with outcomes prints a v1 `## Done when` checklist in its description
  only through those lines, never twice, and a card with none prints no
  `done when:` block and keeps its description as it is. After that it prints
  `checks:` and one `- <command>` line per checks row, then a blank line, when
  the card has any, and the same for `allow:`, `tests:` and `files:` with one
  `- <word or name>` line each (the `dev.allow`, `dev.tests` and
  `dev.files` fields). Links are listed by `links`. On a child it also
  prints `parent: <id prefix> <name>` under the `ls` line, and on an epic
  `kind: epic, N open` above it and `children: N of M done`, from `GET /api/tasks/{id}` (`parent`,
  `children_done`, `children_total`) on Pomb and from the `parent` links of the
  cards on a local board (done meaning in a done column). `show CARD --board B`
  prints the card on the Pomb board named `B` from any repo, looked up as
  `add --board` looks it up, and a local board refuses it (exit 1).
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
  fence rule. A name in the card's claim history is refused with exit 1 and
  nothing written. A row that `dev board check` would refuse is exit 2 with the
  row named, as in `add --checks`. No command, a blank command, a missing card
  or an unknown
  option word is exit 2 (so nobody clears the rows by accident, and no
  subcommand clears them), and an unknown card is exit 1. A Pomb board with no
  checks field is refused before any write with the message
  `the board has no checks field, so run dev board init to add it`, as a move
  into Ready gives (exit 1). Sending the same rows twice changes nothing more,
  so `checks` is queued while Pomb is unreachable like `edit`, timeouts and 502,
  503 and 504 included. The `on` runner names are not set.
- `check CARD [--expect-fail] [--timeout SECONDS]`: Runs every checks row of the
  card and records the result as one comment on the card.
  In a jj project `check`, `turn` (not `--release`) and `land` first refuse,
  and do nothing else, unless the working copy's workspace is named for the
  card's id prefix, the name `dev ws new CARD` gives. The refusal names the
  workspace it found. A git project is not checked, and no flag or
  environment variable turns the rule off. A row runs as a
  plain command, split on whitespace and started without a shell, so a row
  that holds any of `| & ; < > ( ) $`, a backtick, a backslash, a quote, `*`,
  `?`, `!` or a line break, or starts with a dotted run such as
  `dev.--remote.lint`, or passes a word to `dev --remote test` or
  `dev --remote lint` before the double dash, is refused before anything runs
  (exit 1). One `!` is allowed, as the first word: a row
  `! rg -n PATTERN FILE` runs the rest as the command and passes only when it
  exits 1 (a search that found nothing).
  Exit 0 fails the row as a match found, and any other exit fails it as an
  error, so rg's exit 2 never passes. Under a set
  `DEV_AGENT`, dev refuses a local run of a verb that has a ci job, so a row
  reads `dev --remote lint` (not `dev lint`). Each row may run for `--timeout`
  seconds (7200 by default, at most 86400, anything else is exit 2), counted
  from the row's start to its end, so the wait in the ci queue and a job that
  ci restarts count too. The default covers a remote test of about five minutes
  that waits behind a long queue. A row that outlasts it is killed and recorded
  as `timeout`, as is a row that exits 124 or is killed from outside. A card
  with no rows is exit 1.

  The result belongs to one commit. In a jj project the working copy is itself
  a commit, so a changed file is normal and the commit is `@` after jj
  snapshots the files, recorded with its change id. In a git project the tree
  must match `HEAD`, and a dirty one is refused (exit 1) with the count of
  changed paths. A conflicted jj working copy is refused too. dev names the
  commit before the first row and again after the last, and a result whose
  two commits differ was run on a tree that moved, so it is not recorded
  (exit 1).

  The comment has the kind `status` and begins with a reserved first line,
  then one line per row: its place, its result, the ci run id it printed and
  its command. The run id is the one from the `run <id>` line of `ci run
  --follow`, so `ci logs <id>` reads the row's log, and `-` when
  the row printed none:

  ```
  dev-check: commit=<full commit id> change=<change id, - in git> mode=run
  1 pass 8cb600 dev --remote lint
  2 fail - dev --remote test
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
- `review CARD --kind code|style|recheck --by NAME --rev REV --verdict clean|minor|needs-work`:
  Records that NAME reviewed the commit REV with that verdict, as one `status`
  comment on the card that begins with a reserved first line and has no other:

  ```
  dev-review: kind=code by=<NAME> commit=<full commit id> change=<change id, - in git> verdict=<clean|minor|needs-work>
  ```

  All four flags are required (a missing one, an unknown kind or an unknown
  verdict is exit 2, and the message lists the kinds or the verdicts). A record
  written before verdicts has no `verdict=` and is read as it was.
  REV is a jj revset in a jj project and a git revision in a git one, and it must name exactly one commit, so a revset of
  many commits, a word that starts with `-` and a name that resolves to nothing
  are refused (exit 1). NAME is an agent name as `take --as` takes, and the
  card's claimant is refused for every kind (exit 1) whether NAME is the
  claimant or the caller is, which is the caller's `DEV_AGENT` or, with that
  unset, the default name a claim without a name is held under (a
  `dev@host:session` name that `take` gives), to keep a claimant from
  reviewing its own change under either name. So is every name that took the
  card before, read from its `dev-claim:` notes, so a claim that lapsed does
  not free its holder to review. The message names the claimant and says a
  reviewer other than it must record the review. An unclaimed card takes any
  NAME. The reviewer records its own review with its final verdict, `clean` for
  CLEAN, `minor` for MINOR ISSUES and `needs-work` for NEEDS WORK, so it is the
  recorder the board allowance for `review` covers. After a needs-work record
  the reviewer notes the findings and leaves the card where it is. It prints
  `recorded KIND review by NAME on <id prefix> at commit <12 characters>`. Like
  `check`, it is never queued: if the comment cannot be written the command
  exits 1 with `the review was NOT recorded`, and a timeout or gateway error may
  come after Pomb stored it, so read `notes` before repeating. `note` refuses
  `dev-review:` and `dev-turn:` as it does `dev-check:`, and `note --edit`
  and `--delete` refuse a comment that holds it. `review` does not judge the
  verdict: `land` does.
- `land CARD [--wait SECONDS]`: Takes the landing turn and lands the change.
  It refuses outside the card's workspace, as `check` does. It rebases the
  working-copy change onto trunk, lands it with
  `jj land --yes -r @` run in the project root, writes a `done` note, moves
  the card to Release when `[board.land] deploys` is true and to Done
  otherwise, and gives the turn back. It needs `DEV_AGENT` (usage error, exit
  2, without it) and a jj project: in plain git it refuses and says so. It
  refuses, exit 1, and lands nothing until every condition holds, and the
  message lists each one that fails. A refusal can leave the change rebased
  onto trunk:
  - the card is in the verify column and no other agent claims it. `move`
    releases the claim, so `land` refuses a card claimed by another agent and
    lets any agent with `DEV_AGENT` set land an unclaimed one.
  - every outcome is ticked (the same count `move CARD done` refuses on). The
    verifier ticks after the checks pass and before `land`.
  - the working-copy commit is non-empty, has a description and has no
    conflicts.
  - a `code` and a `style` review of the working-copy change are recorded. A
    review of an earlier commit of the change counts when `jj interdiff`
    between that commit and the landing one is empty, so
    a clean rebase keeps its reviews and only the check reruns. Any other
    earlier commit counts only with a `recheck` recorded at the landing commit.
  - no `code`, `style` or `recheck` review at the landing commit, or at an
    earlier commit of the change with the same empty interdiff, has `needs-work`
    as its latest verdict. The refusal names the kind and the reviewer, and a
    later `clean` or `minor` review of that kind at the commit lifts it. A record
    with no verdict never refuses.
  - the newest `dev-check:` record with `mode=run` at the landing commit has a
    `pass` for every checks row, in the card's row order. A `mode=expect-fail`
    record never counts, even when it does not parse. When the newest
    `dev-check:` record at the commit does not parse and its mode is not
    `expect-fail`, as with one written before rows carried run ids, `land`
    refuses it as unreadable and says to run `dev board check` again, not
    that no record exists.
  - the commit's parent is the current trunk, compared after
    `jj git fetch --remote <remote of record>`, with the remote taken from the
    forge settings (see `forge`). A failed fetch refuses. `land` rebases the
    change onto trunk itself while it holds the turn, so this holds unless the
    rebase failed. The conditions on the reviews and the check are then judged
    at the rebased commit. A change that sits on an unlanded parent is
    refused and not rebased.

  The landing turn keeps one landing at a time across runners, to keep
  trunk from moving under a landing. It is the claim on a card named
  `landing turn`, which `land` creates in the Icebox when the board has none,
  to keep the holder on the board and not in one session.

  A card in the wrong column, with an open outcome or claimed by another
  agent is refused before the turn is asked for. `land` then asks for the
  turn for up to `--wait` seconds (60 by default, up to 86400, a whole number)
  and, when it stays taken, refuses with
  `the landing turn is held by NAME since STAMP`.

  After its first look, a waiting poll reads only the turn card and its
  comments. It reads the card list again only when the turn card cannot be read
  or has ended, or when it wins the claim.

  It sleeps 5 seconds, then 1.5 times longer after each poll that sees the same
  place in line and holder, up to 30 seconds. A change in either starts over at
  5 seconds. Each sleep is shortened by up to 20% at random.

  Each poll also reads the waiting card. A waiter whose card has moved to
  Done writes its `left` note and stops with `<id prefix> is done, so there is
  nothing to wait for`.

  Cards wait in the order they asked. A card with a wait writes a
  `dev-turn: ask` note with the time its wait ends before it asks for the
  turn, and only the first live ask in line may take it. A later asker is
  told whom the turn is next for. An ask ends when its card takes the turn,
  writes a `dev-turn: left` note when its wait runs out, or passes its end
  time, to keep a waiter that died from holding the line. Only the claim's
  fence releases the turn, and a waiter that gives up releases nothing.

  The holder writes a `dev-turn:` note on the turn card with its name, the
  card it lands and the time it took the turn. The lease is 900 seconds and
  `land` renews it before the `jj land`. When a holder dies, the lease ends
  and the next asker takes the turn. A holder that comes back after that
  gets `the landing turn was lost` or `the landing turn ran out`, writes
  nothing and lands nothing, and has to ask again.

  `land` gives the turn back on every exit, a refusal included (a hold from
  `turn` stays through a refusal). A local
  board keeps the lease for its length and ignores the card-size lease that
  `take` uses.

  After the move, `land` cleans up. It deletes the bookmark named for the
  card, then runs the removal behind `dev ws rm` on the card's workspace,
  which is the one it runs in, so a shell left inside it sees dev exit 1 with
  the deleted working directory message and the output says to run the next
  command from another folder. A git project removes the worktree first and
  then deletes the branch, because git refuses to delete a checked-out
  branch. A workspace outside the central root, or one with changes not in a
  commit, stays, and the output names it and why. Cleanup never changes the
  exit code or the card's column.

  One case keeps a check and reviews across a rebase. When the landing commit
  lacks the reviews and has no `dev-check:` record of its own (one that does
  not parse is its own, and `land` refuses one not marked `expect-fail` as
  unreadable), `land` looks for the commits of the same change id with a
  passing run and their code and style reviews (a recheck counts as above).
  It tries them newest first and carries the records of the first one for
  which all of these hold:

  - the commit's parent is the current trunk
  - the checked commit sat on one ancestor of that trunk
  - `jj interdiff` between the checked commit and the landing one is empty
  - the rebase left no conflict

  A trunk commit that touched the same files does not stop the carry. The
  release run tests the whole batch and catches a clash the rebase cannot see.

  The carry is tried whenever reviews are lacking, even when another refusal
  stands (an unticked outcome, the wrong column), to list in the refusal only
  what still blocks the landing.

  `deploys = true` under the same `[board.land]` table makes `land` move the
  card to Release, where it waits until it is live. Without it `land` moves the
  card to Done. This repo does not set it.

  `checks` under `[board.release]` lists the commands `dev board ship` runs
  once when it gets none after `--`, one plain command per row.

  The landing turn keeps landings made through `dev board land` to one at a
  time, and a raw `jj land` takes no turn (see the `land` entry above).

  In a repo whose `.dev/config.toml` has a `[board]` section, a bare `jj land`
  exits 1 and names `dev board land`. `dev board land` sets `DEV_BOARD_LAND=1`
  for the `jj land` it runs, and `jj land --no-card` lands a change that has no
  card. `jj land --undo` and `jj land --dry-run` pass the guard. Neither one
  lands a change, and neither needs a card.

  A different change id, a non-empty interdiff or a review never recorded at
  the checked commit keeps the plain refusals, and any jj read that fails
  refuses too. The done note then adds that the check and reviews were carried
  over from the checked commit. When no commit carries, the refusal gives the
  reason for the newest one, unless a jj read fails first, which refuses at
  once and names that read.

  A failed `jj land` leaves the card where it is, exits 1 and prints jj's
  output. A landing whose done note or move then fails exits 1 and says what to
  finish by hand. `jj land` can rewrite the commit through the forge, so after
  it succeeds `land` fetches the remote of record and reads the commit that
  holds the change on trunk by its change id; the `dev-check:` and `dev-review:` records keep the commit from
  before the land. The done note reads
  `Landed commit <12 characters> (change <id>) on trunk, run by NAME.` and
  success prints `landed <id prefix> at commit <12 characters> and moved it to
  Done`, both naming the commit on trunk. If the fetch or the read fails after
  the land (which does not undo it), the note reads `Landed change <id>, run by
  NAME.` and says that the commit named is from before the land and may differ
  from the one on trunk, the success line says the same, and the card still
  moves to Done. It is never queued.
- `ship [-- CMD...]`: Ships the Release batch. It runs the release command
  after `--` once, for example `dev board ship -- dev release --batch 12
  --summary TEXT`, or each row of the `checks` list under `[board.release]`
  once when no command is given, as plain commands from the project root.
  With neither it exits 2 and names `[board.release]`. When every command
  passes, `ship` moves each card in Release whose outcomes are all ticked to
  Done after writing one `done` note that names the commit trunk points at
  (`Shipped in trunk commit <12 characters>.`), and lists the cards left in
  Release with an unticked outcome. When trunk cannot be read, the note says
  so. When a command fails or times out, `ship` stops at it, moves no card,
  prints the command and its output tail, and exits 1. A card whose note or
  move fails stays in Release, is listed, and makes `ship` exit 1. It is
  never queued.
- `turn CARD [--hold SECONDS] [--wait SECONDS] [--release]`:
  It refuses outside the card's workspace, as `check` does, but `--release`
  works from anywhere. The turn is short and holding it is optional: a landing
  takes it only around the rebase and the push, so a runner holds none across
  the reviews or a check, and two cards whose checks ran in parallel land one
  after the other. `turn` takes the landing turn for CARD early and keeps it,
  so `land` lands under it and no other landing moves trunk meanwhile. It needs
  `DEV_AGENT` (exit 2 without it) and takes the turn as `land` does, but fails
  fast: it asks once unless `--wait` gives seconds to keep asking, and, when the
  turn stays taken, refuses with `the landing turn is held by NAME since STAMP`.
  A hold is longer than a landing's 900 second lease: `--hold` sets its lease,
  1800 seconds by default and 3600 at most (a whole number, exit 2 otherwise),
  so a long wait fits. `check` does not renew the lease while
  it runs. Running `turn CARD` again as the holder renews the lease for
  `--hold` more seconds, until the hold has been kept without a break for 3600
  seconds in all, after which `turn` and `land` refuse, give the turn back and
  leave the holder to ask again. The hold is recorded in the `dev-turn:` note
  with the fence and the lease, so a later command finds it from the board
  alone, on any machine under the same `DEV_AGENT`. Success prints
  `holding the landing turn for <id prefix> for N seconds`.
  A hold that lapsed frees the turn to the next asker, so taking it again
  starts a new window. `--release` gives the hold back and writes a `left`
  note. When the caller holds none for the card it still writes the `left`
  note, which drops a queued ask and creates the `landing turn` card when the
  board has none, and refuses. A hold that ran out is cleared
  and reported as already gone. A card in Done is refused, except to give a
  hold back.

  `land CARD` finds a hold taken by the caller for that card and lands under
  it without asking again. It renews the lease before `jj land` and gives the
  turn back once the card has landed. A refusal leaves the hold in place, with
  a line that says so, so the runner fixes the cause and lands again. When the
  hold ran out or another card took the turn, `land` writes nothing, lands
  nothing and refuses with `the landing turn held for <id prefix> ran out or
  was taken by another`, and `turn CARD` takes it again.
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
- `outcome CARD TEXT`, `outcome CARD --rename N TEXT --reason TEXT`,
  `outcome CARD --tick N`, `outcome CARD --untick N`,
  `outcome CARD --convert`: Appends a Done when outcome to an existing card
  (`POST /api/tasks/{id}/subtasks` with `name`) and
  prints `outcome <id prefix> N added`, with N the new outcome's place.
  `--rename N TEXT --reason TEXT` rewords the Nth and posts one decision note
  with the old text, the new text and the reason. A missing or empty `--reason`
  is exit 2 and writes nothing. `--tick N` and `--untick N` set it done
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
  Pomb's reorder subtasks, which is admin-only. A local board keeps
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
- `note CARD [--board B] [--kind K] [--as ROLE] TEXT`: Adds a comment and prints
  `noted <id prefix>`. The words after the card, minus the options, are
  joined with spaces, and any other word, one starting with `-` included, is
  text. `--kind` is `decision`, `blocked`, `status` or `done` in any case, sent
  lowercase as the comment's `kind` (anything else is exit 2, `question`
  included, which names `dev board ask`, and no `--kind` posts kind `agent`).
  `--as ROLE` is free text, trimmed, sent as the comment's `author` label (Pomb
  allows 80 characters, and an empty, over-long or control-character value is
  exit 2, and none leaves Pomb's default). A local board stores both on the
  comment. `show` and `notes` print them, a queued note keeps both options in
  its arguments, and `--edit` replaces only the body, so the kind and the label
  stay. `--board B`, right after `CARD`, comments on the card on the Pomb board
  named `B` from any repo, looked up as `add --board` looks it up, and a local
  board refuses it (exit 1). It takes no `--edit` or `--delete` (exit 2).
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
- `move CARD COLUMN [--max-size N]`: Moves the card to the top of the column
  and prints `moved <id prefix> to <column>`. A move into In Progress that takes the claim
  adds a blank line and the card as `show CARD` prints it, with the same
  stderr warning when that read fails. When the card has a claim taken by
  `take`, the move sends its fence as `If-Claim-Fence` and, for any column but
  In Progress, stops the keep-alive loop, forgets the claim and, once the move
  has succeeded, releases it on the backend with its fence (a refused release
  prints
  `dev: moved, but the claim was not released: <reason>` on stderr and the move
  still succeeds). A move into Ready of a card that is white, has no colour or
  is red (more than 3 Pomodori) is refused before the backend is called:
  `<id prefix> has no size and cannot enter Ready; size it with dev board size CARD 1, 2 or 3`,
  or for red
  `<id prefix> is red, more than 3 Pomodori, so split it and cannot enter Ready; ...`
  (exit 1), on both backends, so a card is sized in planning and red never
  reaches Ready. A move into any other column but Icebox or Ready of a card
  with no size, a description that lacks a v2 heading or text under Problem, or
  no outcome is refused before the backend is called:
  `<id prefix> is not planned and cannot enter <column>; it lacks <what>; fix it with dev board size, edit and outcome`
  (exit 1, on both backends, `dev.board.unplanned`). A `discard` is refused the
  same way for a missing size or heading, with no outcome needed, except an
  unplanned Icebox card given a `--reason`. A move into
  Ready of a card whose description lacks one of the three v2 headings or text under one,
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
  A card with children is an epic (`kind` epic or `children_total` on Pomb,
  `parent` links on a local board) and enters Ready under the same checks as any
  card. `move` refuses any card
  labelled `needs:human` first, whatever the column. A move into any other
  column, Icebox included, is never checked for the Ready rules. A move into In
  Progress of a card nobody holds and that this machine holds no claim on takes
  the claim first, as `take` does with `DEV_AGENT` as the name (a name that
  is not `repo/role[/card]` is exit 2), an epic included, and releases it again when the move fails.
  A move into Done (`move CARD done`) is refused once the card is read, before
  the move is sent, while the card has an unticked outcome:
  `<id prefix> cannot move to Done: N of M outcomes are unticked (1. text, 2. text); the reviewer ticks them with dev board outcome CARD --tick N --as NAME, or dev board discard CARD drops it`
  (exit 1, on both backends, each open outcome numbered as `show` numbers it).
  Outcomes that Pomb sent in a form dev cannot read (`subtasks` that is not a
  list, or an entry without a string name) refuse the move the same way:
  `<id prefix> cannot move to Done: its outcomes cannot be read from Pomb, so they cannot be checked`.
  A card with no outcomes, or with all of them ticked, moves as before.
  An epic with an open child is refused a move into a column whose settings
  make it WIP-limited or done, never one picked by its name:
  `<id prefix> is an epic and cannot enter COLUMN, a done column: N of M children are open`
  (or `a WIP-limited column`; exit 1, on both backends). `Backend:columns`
  reports each column's `is_done` and `wip_limit`, and a local column has no
  limit, so only `is_done` applies there. The refusal reads the epic's counts
  from the card, so a plain card costs no extra request. When the counts are
  stale and Pomb refuses the move itself (`epic_has_open_children`, a `409`),
  dev prints Pomb's own text. Pomb reopens an epic that moves out of a done
  column, and a local epic is open again as soon as its column is not done,
  because a local board stores no closed flag. `discard` skips the rule, and
  none of these refusals is queued, nor is a move to Done that Pomb could not
  answer for.
  `add` cannot create a card with children and `discard` asks for no outcomes,
  so neither reads them.
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
  card is kept, never deleted. An unplanned Icebox card closes when it has a
  `--reason`, since the planning check is skipped there. An unplanned card in
  any other column is refused (exit 1), and so is an Icebox card with no
  reason.
- `run [--orders TEXT | --end]`: Keeps a session's run on the board as one card
  labelled `run`, named `run <session>`, where the session is `DEV_AGENT` else
  `dev@<host>:<session>`. `--orders TEXT` adds the card in In Progress,
  size 3, claimed under the session name, with the orders quoted line by line in
  its Change, three outcomes and a `dev board lint` checks row, and prints
  `started <id prefix>` then the card as `show` does; orders over 250 words,
  counting each line's quote mark, are exit 2, and a session that already has an open run card is exit 1. With no
  flag it prints the session's open run card (claiming it again when the claim
  lapsed), the cards the session holds and the top of `next`, and with no open
  run card it is exit 1 with `start one with dev board run --orders TEXT`.
  `--end` closes the card the way `discard` does, with the note `the run
  ended`, and prints `ended <id prefix>`. Two sessions have two cards, and
  `next` never returns a run card, and `lint` does not ask a run card for a
  claimant, since the claim lapses after 150 minutes. Without `DEV_AGENT` or
  `CLAUDE_SESSION_ID` the session has no stable name, so `run` is exit 2. In a
  project with no `[board]` section, `run --orders` makes the board as
  `init --name <directory>` does when the project is private (no origin, or an
  origin on github.com that `gh repo view` says is private) and stops with
  exit 1 otherwise, to leave a public project's board to the owner.
- `take CARD [--as NAME] [--max-size N]`: Claims the card
  (`POST /api/tasks/{id}/claim` with `claimant` NAME, else `DEV_AGENT`, else
  `dev@<host>:<CLAUDE_SESSION_ID or the pid of dev's caller>`; NAME is one word
  of letters, digits and `.`, `-`, `_` and `/` of at most 200 characters, else
  exit 2, `ttl_seconds` 900, and the stored fence when this machine already
  holds one, which renews) and starts the keep-alive loop. Prints
  `took <id prefix>, fence N, renewing every 5m for up to Mm` (a local board
  needs no loop and prints `took <id prefix>, fence N, held for Mm`), a blank
  line and the card as `show CARD` prints it. When that read fails,
  `dev: took <id prefix>, but <reason>` goes to stderr and the claim stays. A
  refused claim (`claim_held`) is `board unavailable: pomb answered 409: ...`,
  exit 1. The first claim by a name also writes a status note
  `dev-claim: by=NAME`, so the name outlives the claim, and `review` reads
  those notes. If that note cannot be written the claim is released and `take`
  exits 1. `note` refuses the `dev-claim:` prefix as it does `dev-check:`.
  With `--max-size N` or, when the flag is absent, `DEV_MAX_SIZE` set to 1, 2
  or 3 (else exit 2), `take` and `move CARD progress` refuse a card bigger
  than that many Pomodori with `<id prefix> is <size>, above this runner's limit of N Pomodori
  (DEV_MAX_SIZE)` (exit 1). `run` takes its own run card and is not held
  to the limit, and the `next:` line of `run` skips a card above it.
  `take`, `move CARD COLUMN` and `move CARD progress` also refuse a card
  when a limit Pomb holds forbids it, to land what passed before it starts a
  new card. dev reads both kinds of limit from Pomb with a fresh
  `GET /api/boards/ID`: a column's own `wip_limit` and the `limit_groups`
  that span adjacent columns, such as In Progress, Review and Verify. A
  column limit refuses when the target holds that many other cards and the
  card is not in it, and the refusal reads `COLUMN holds N cards (ID, ID), at
  its limit of L. Land one first.` A column whose `limit_unit` is `hours` is
  skipped, and Pomb enforces that limit itself. A missing `limit_unit` counts
  as `count`. A group limit refuses when the target is in the group, the card's
  column is outside it and the group's columns hold that many other cards,
  whoever claimed them. The refusal reads `N cards are
  in flight in In Progress, Review and Verify (ID, ID, ID), at the limit of
  L. Land one first.` (exit 1). Cards in other columns do not count, and
  neither do epics or the card being moved. A board with no limits set in
  Pomb is uncapped, and so is a local board. A move to Done is not checked here.
  A card already in In Progress, or whose claim this machine holds, is not
  checked for In Progress, and a take of a card another name holds gets the
  claim refusal. Cards already in flight are never moved. The count and the
  claim are two steps, and under parallel commands the limit is advisory and
  can be overrun. Pomb enforces its limits too: a move it refuses with 409
  `wip_limit_reached` prints `Pomb refused the move: MESSAGE` (exit 1), a
  `move CARD progress` that had just taken the claim gives it back, and dev
  never sends `force`, so its own land move into Release fails the same way
  and the card stays put. `next` stays read-only and shows the card anyway.
  The turn hold is 1800 seconds by default and 3600 at most (see `turn`).
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
`dev: no board for this project` and exits 1, which is how an agent branches.
Every subcommand, `edit` and `show` alike, prints
`dev: no board for this project` from a directory outside the project (the
root is found from the current directory). A refusal from a checkout's root or
any directory below it means that checkout's `.dev/config.toml` has no
`[board]` section. A refusal from elsewhere means the shell was not in the
project, or that project has no `[board]` section.
A `local` backend keeps the board in a file (below). Any other backend is
exit 1.
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
still holds its fence, reads the token through the same `board/passlock.sh` as
`dev.board.pomb`, Keychain first, refuses a token outside `A-Za-z0-9._~+/=-`,
and sends `POST /api/tasks/{id}/claim/heartbeat` with
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

`dev board wait [--for ready|review|verify|release|human|lead]` (Pomb only)
loops on `Backend:wait` until an event matches and prints one line per matching
event in the reply, then exits 0, so a background run under `timeout` wakes the
session. `--for ready` sends kinds `task_added,task_moved` and matches a card
whose column is Ready after the event (`added <id prefix> to Ready`, `moved <id
prefix> to Ready`), `--for human` sends `task_moved,comment_added` and matches a
move whose `from_column` is Blocked, whose `actor` is `human` (Pomb's
`actor_kind` of `user`) and whose `at` (Pomb's `at` as epoch seconds, both
kept on each event by `Backend:wait`) is later than the wait's start, printed
as `moved <id prefix> out of Blocked`, or a comment event whose card is not
Done and whose newest comment is the owner's and newer than the time the wait
started, which it reads with `Backend:cards` and `Backend:comments` (`the
owner commented on <id prefix>`). The first match opens a settle window of 60
seconds (`Owner.SETTLE_SECONDS`): each further call to `Backend:wait` passes
the time left of the window as its timeout, a match restarts the window, and
an empty reply or an elapsed window ends it with one line per card. `--for
lead` sends `task_added,task_moved,task_updated` and, for each reply with
events, reads `Backend:cards` and matches an event whose card is in Blocked
with `needs:lead` (`--for planner`, which sends the same kinds,
`needs:planner`) and no `needs:human` (`<id prefix> is labelled needs:lead in
Blocked`, once per card per reply), and with no `--for` all four kinds match
(`added <id> to <column>`, `moved <id> to <column>`, `updated <id>`,
`commented on <id>`). An unknown `--for`, a card argument or another flag is
exit 2, and a local board is `dev: a local board has nothing to wait on` (exit
1). The cursor is `<state
home>/dev/boards/<name>.<ready|review|verify|release|human|lead|planner|all>.cursor`,
one per `--for` mode so a filtered wait never consumes another mode's events
(the name with every character outside `A-Za-z0-9._-` turned into `_`) at mode
600, written after every reply, and with no file the first call asks without a
cursor and starts from the cursor Pomb answers. An expired cursor (410) stores
the backend's oldest cursor and prints `events were trimmed, check the board`
(exit 0). `--for human` stores it and rereads the cards instead
(`Owner.sitting` at the start, `Owner.departed` on a trim) and prints `moved
<id prefix> out of <column>` for each card that sat in Blocked or Icebox and
has left it, or keeps waiting when none has. A failure `pomb.unreachable`
counts (idempotent rules) is retried after a 30 second nap, and the tenth in a
row exits 1 with its message (an endless silent retry would hide a dead Pomb
from the session). A 429 whose body has the code `too_many_waits` (4 open
waits per token, and every session shares the token) makes `Backend:wait`
return a fourth value, `true`, and is never a failure: `wait` prints `dev:
pomb holds too many open waits for this token, waiting for one to end` on
standard error once per call, resets the failure count, and retries with a
pause of 30, 60, 120, 240 and then 300 seconds, each cut by up to a quarter
with a random fraction, until a reply comes (a reply starts the pause over). A
429 with another code is a plain refusal. Any other refusal exits 1 at once.
`wait` is not in the queue rules, and a reply with no matching event loops
again. `tests/lua/board_test.lua` covers it with a fake backend and stub
`nap`, `random` and `notice` options.

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
`--tick` or `--untick`, which are safe to apply twice, also a curl
timeout, a 502, 503 or 504, or an answer that is not JSON, since those may
follow an applied change and `add` or `note` would then be doubled, so an
`outcome` append, `--rename` or `--convert` is never queued for those), the
command appends itself to the queue, prints
`queued: Pomb unreachable, will sync` and exits 0.
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
implements, and does, in this order: create a missing board with `POST
/api/boards`, using the template named `agent project` when `GET /api/templates`
lists it and no template otherwise; rename an In Review column to Review with
`PATCH /api/columns/{id}` (`{"name": "Review"}`) when no Review column exists,
add each missing column with `POST /api/columns` (Done with `is_done`), then
re-read the board, mark an existing Done column done with `PATCH
/api/columns/{id}` when it is not, mark the Blocked column with `PATCH
/api/columns/{id}` and `{"is_blocked": true}` when it is not (a Pomb whose
column views carry no `is_blocked` key stops init at that step with a message
that it cannot mark a Blocked column yet and that `dev board ask` needs it,
sending no write for the mark. A local board has no such setting, so it marks
nothing and says nothing), and reorder with `POST
/api/columns/{id}/move` (`{"position": N}`, 0 first) so the nine standard
columns come first in the order Icebox, Backlog, Ready, In Progress, Review,
Verify, Release, Blocked, Done and any other column follows, kept and reported
as `kept column "X", which is not part of the standard board` on every run; then
define the checks field when the board lacks it (`GET /api/boards/{id}/fields`
lists the keys, and `POST /api/boards/{id}/fields` sends `dev.checks`:
label `Checks`, kind `table`, `required` true, columns `run` (text, required)
and `on` (multiselect, optional, with the one option `local`, since Pomb refuses
a multiselect without options and runner names are set elsewhere), copied from
the dev board's definition, one line `added the checks field
dev.checks`, never a change to an existing field, and nothing on a local
board); then name the palette through `PATCH /api/boards/{id}/colors/{color_id}`
(the colours are found by `value`): yellow `1 Pomodoro`, green `2 Pomodori`,
blue `3 Pomodori`, red `>3 Pomodori` and white `Unsized`, each with a legend
description; then, with the palette named, strip a trailing `(yellow)`,
`(green)`, `(blue)`, `(red)` or `(red, split)` from every card name with `PATCH
/api/tasks/{id}`, setting the colour from the word in the same call when the
card's colour is white, unset or the colour that was the default when the run
began (so a card Pomb painted with the old yellow default gets its real colour),
and leaving the colour of any other card alone, and repeating that for a name
with several size words; then enable exactly white, yellow, green, blue and red
and disable every other colour (orange, purple, magenta, cyan, brown and any
other value) with `PATCH /api/boards/{id}/colors/{color_id}` and `{"enabled":
bool}`, enabling first, one line per colour (`enabled white`, `disabled
orange`), never deleting a colour, and reporting each card that wears a disabled
colour in one line (`card <id prefix> wears the disabled colour orange, left as
it is`, on every run, the card's colour untouched); Pomb keeps `enabled`
admin-only, so a 403 on it prints one line (`left the colours enabled as they
are, since this token may not change them; run dev board init --admin`) and the
run carries on instead of exiting 1; last, make white the default, so a run that
stops early can be repeated and still know the old default. A name that is only
a size word is kept and reported. Labels are plain strings on cards in Pomb, so
`needs:lead` and `needs:human` need no creation. Each change prints one line
(`created board X from the agent project template`, `added column X`, `moved
column X to position N`, `marked Done as the column of finished cards`, `marked
Blocked as the column of cards waiting on an answer`, `named yellow
"1 Pomodoro"`, `made white the default colour`, `renamed card <id prefix>
to "..." and coloured it blue`), and the last line is `board X already follows
the standard, nothing to change` or `board X: N changes`. A failure prints `dev:
<message>` with exit 1 after the lines of the changes already made, and a `403`
adds `; this token may not change this board, run dev board init --admin`. Pomb
0.5.5 lets the lead token name colours, set the default and reorder columns only
on boards it created after 0.5.5, so the default token is the lead token
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
with `code` `permission_denied` is `pomb answered 403: this token lacks the
<permission> permission on every board; use a token that has it` when `board_id`
is null (the `--admin` hint applies) and `this token has the <permission>
permission but is not assigned to board <id>; add the board to the token` when
it is set (no hint). A board absent from `/api/boards` is `pomb lists no board
named X for this token, which is assigned only to ...` when `whoami` returns a
`boards` list, else `pomb has no board named X`. `tests/lua/board_init_test.lua`
runs the algorithm against a stateful fake layout and the command against
a fake `curl`.

On a miss in the Keychain, the token is read by `timeout 10 pass show <entry>`
through `board/passlock.sh`, with `PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch"` and no stdin, so a
locked store fails at once with
`board unavailable: pass is locked or has no entry <entry>` (a timeout says
`pass timed out`). A token with any character outside `A-Za-z0-9._~+/=-` is
refused without being shown. The token reaches curl only as the config line
`header = "Authorization: Bearer ..."` on standard input (`curl -K -`, through
`dev.os.capture_input`): it is in no argument list, no environment variable, no
file and no message, and `BASH_ENV`, `ENV`, `PS4` and `VERBOSE` are unset for
`pass` and curl so `-vv` never traces them. The response is read from a
temporary file `capture_input` removes.

