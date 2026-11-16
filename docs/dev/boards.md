# boards: Read and update a project's board, with every dev board subcommand

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
`# standalone: runs on <where>, where dev is absent`. `dev lint` warns on any
other `.sh` under `.dev`, except a hidden `.dev/__*.sh` helper.

`dev board land` refuses a commit that adds a file under `.dev/standalone/`
unless the card carries the `standalone-ok` label. The refusal names the file.

Only the owner adds that label. `dev board label` refuses to add it when
`DEV_AGENT` is set, while removing it stays allowed. An agent that needs a
standalone script files a `needs:human` card instead.

## Opting in

A project uses a board when `.dev/config.toml` has a `[board]` section:

```toml
[board]
backend = "pomb"
name = "dotfiles"
```

`backend` is `pomb` or `local`, and `name` defaults to the project
directory's name. The `local` backend keeps the board in a file (see Local
boards below).

`dev board status` prints the backend and the board. Without a `[board]`
section it prints `dev: This project has no board.` and exits 1, and every other
subcommand says the same and exits 1.

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
with `PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch"`. A locked
store fails at once with `board unavailable: pass is locked or has no entry
...` instead of waiting on a prompt.

`board/passlock.sh` runs `pass` under one lock, the directory
`/tmp/dev-pass-<uid>.lock`. Concurrent dev calls and keep-alive ticks queue
instead of crowding the hardware key.

- wait: up to 2 minutes for the lock, then it fails like a timeout.
- takeover: a lock whose owner pid is gone, or that is older than 30
  seconds, is taken over.
- reads: a dev process reads each entry once, while the keep-alive loop reads
  it on every tick.

On a machine with `/usr/bin/security` (macOS), the Keychain answers before
`pass`. `board/keychain.sh` keeps the token as a generic password named
`dev-pomb-token:<entry>`, one item per `pass` entry.

`passlock.sh` reads the Keychain first, with no lock and no hardware key. On a
miss it reads `pass` under the lock and stores the token.

The item is created through `security -i`, which takes the command on
standard input to keep the token out of every argument list. It is created
with `-T /usr/bin/security` to make reading it raise no prompt.

Every Keychain call runs under a 3 second timeout. Any failure, a locked
keychain included, falls through to `pass`. A machine without `security`
reads `pass` alone.

When Pomb answers 401 to a token from the Keychain, dev deletes the item,
reads `pass` once and repeats the request once, to replace a rotated token.
A delete that fails ends the retry, and the 401 is reported. The keep-alive
loop does the same on a tick.

`DEV_BOARD_TOKEN` carries a role token a lead issued. When it is set and not
empty, dev board sends it in place of the `pass` entry and reads neither
`pass` nor the Keychain. The keep-alive loop does the same on a tick.

When `DEV_BOARD_TOKEN` is unset or empty, dev reads the token file for the
current `DEV_AGENT`, then `pass` as above.

A 401 under either role token is refused, with no retry and no fallback to
the `pass` token. The refusal says:

- `the issued token in DEV_BOARD_TOKEN was refused by pomb` for the variable.
- `the role token file for DEV_AGENT was refused by pomb` for the file.

An expired file is refused the same way, with ``The role token file for
DEV_AGENT expired. Mint it again with `dev board token mint`.``

### Role tokens: token-mint

`dev board token mint --role ROLE --as NAME` gives a runner a role token when
a lead starts it by hand. It prints the role, the `agent-N` label and the
expiry, never the token. Pomb sets the expiry: one hour by default, at most
eight, and never past the lead's own.

The verb makes two calls:

- `GET /api/v1/agent-roles` reads the role's id by name.
- `POST /api/v1/auth/tokens/children` with `{name, role_id}` and the lead
  token (`lead_token`) issues the token.

The token goes to a file named by a SHA-256 hash of NAME, mode 0600, in a
directory of mode 0700. The directory is `$XDG_RUNTIME_DIR/dev/tokens` when
that variable is an absolute path, else `dev/tokens` under the state
directory.

The file holds the token on its first line and the expiry in Unix seconds on
its second. Every mint deletes the expired files it finds there.

The lead then starts the runner with `DEV_AGENT=NAME` and no token in its
environment or prompt. NAME is the claimant name, so it follows
`repo/role[/card]`.

The verb runs only for a lead, and so does `delete`. Both read one helper,
which counts a `DEV_AGENT` as the lead when its role segment (the second) is
`lead`, as in `dotfiles/lead`, or when it holds no slash. Any other role is
refused.

Pomb refuses a name that a live token holds with a 409, and a name frees once
its token expires. dev shows that, an `unknown_role` and an `exceeds_grant`
in plain words.

Minting again for a running runner is described under token-remint, and
`token revoke` ends a token early. A retry of a card reuses its name, so it
revokes the earlier live token first or waits for it to expire.

The token goes to curl on standard input as a config line. It is in no
argument list, no file and no output, `-v` and `-vv` included, and in no
environment variable but `DEV_BOARD_TOKEN` itself.

### Minting again when a token expires: token-remint

A role token lives at most eight hours, and Pomb answers 401 `token_expired`
once it ends. The runner holds no `tokens.issue`, so the lead mints again
with the same command, `dev board token mint --role ROLE --as NAME`.

Pomb deletes the account's expired issued tokens when it issues a child. An
expired token's name is free at once, and the new token reuses NAME with no
suffix. The file of NAME is replaced with the new token.

Only a live or suspended token of that name, matched without regard to case,
gets a 409 `name_taken`. The verb refuses by naming NAME and leaves the file
as it was.

A request refused with `token_expired` for the token it read from that file
reads the file once more:

- another token: it retries the request once with it.
- the same token: it fails with the expired message and makes no second try.

A token from `DEV_BOARD_TOKEN` or from `pass` is never retried this way, and
an expired one fails with the expired message as before. A runner cannot mint
for itself, and dispatch's own re-mint is a separate matter.

### Closing an epic

`dev board move EPIC done` on a Pomb board reads the card with the worker
token first. When the card is an epic and the column is the Done column, dev
opens the board again with `[board.pomb] lead_token`, as `delete` does, and
sends the move with it, and never queues it when Pomb is unreachable. Pomb grants `epics.manage` to the `lead` preset alone.
A `DEV_AGENT` that is not a lead is refused with `dev: Only the lead closes an
epic. DEV_AGENT NAME is not a lead name, whose role segment is lead. Ask the
lead.` before the move goes out, and an unset `lead_token` exits 1 naming
`epics.manage`. The move still refuses a child that is open and an outcome
that is unticked, and names the count and the outcomes.

### Ending a role token: token-revoke

`dev board token revoke --as NAME` ends the token that `token mint` issued as
NAME, once its run is over. The lead is refused as `mint` and `delete` are, by
the one lead helper.

The verb makes two calls:

- `GET /api/v1/auth/tokens/children` reads the lead token's own child tokens
  and finds the one named NAME.
- `DELETE /api/v1/auth/tokens/children/{id}` revokes it.

Pomb lists and revokes only the children the calling token issued, so a token
the lead did not issue is out of reach.

Pomb answers 200 once the token is revoked. dev then deletes the file named
by the hash of NAME and prints `revoked the role token of NAME`.

A NAME that no live child holds, or a token that Pomb answers 404 for
(already gone), leaves nothing to revoke. dev exits 0, prints `Nothing was
left to revoke for NAME.` and deletes a stale file for NAME.

When Pomb refuses the revoke, dev prints the reason, exits 1 and keeps the
file.

## Which token each tool holds

Pomb groups permissions into four presets, each holding the one before it:
`read`, `work`, `lead` and `admin`. A token holds a preset or a custom
permission set, on all boards or on an assigned few.

Each tool holds the smallest preset that covers its calls, on the boards it
works.

- lead session: `lead_token`, preset `lead`.
  - calls: everything `work` does, plus `boards.create`, `columns.create`,
    `columns.edit`, `columns.reorder`, `fields.create` and `colors.edit` (for
    `init`), `tasks.bin` (for the `dev board delete` verb), and
    `subtasks.delete` for `outcome --delete`.
  - deletes: `tasks.bin` sends a card to the bin for 30 days, and
    `subtasks.delete` removes any outcome.
- subagent and runner: `token`, preset `work`.
  - calls: every read, `tasks.create` (add), `tasks.edit` (edit, labels,
    fields, restore), `tasks.move`, `tasks.claim` (claim, heartbeat,
    release), `subtasks.edit`, `subtasks.check`, `comments.write` and
    `links.write`.
  - deletes: its own comments and links. It deletes no card and no outcome.
    Pomb answers 403 `permission_denied` for `subtasks.delete`, and only the
    lead deletes either, with the lead token. Nobody deletes an outcome from
    Ready on, where outcomes are fixed.
- runner: preset `work` on its board.
  - calls: read the board, create and move cards, set fields and labels,
    comment, link, claim, heartbeat and release.
  - deletes: none. Its `init` needs `lead`, which the lead runs.
- Aide agent: preset `work`, assigned boards only.
  - calls: the subagent's calls, with notes written with `--as aide`.
  - deletes: none. It never holds `lead`.

Every delete an agent holds is of its own work, except that only the lead
deletes an outcome. A mistaken comment or link never waits for the owner.

Deleting from the bin, emptying it, and every board, column or account delete
stay with the owner, who holds `admin`.

A card delete is token policy, not something dev enforces on its own. Only
the lead decides and does one, and Pomb refuses a `work` token with a 403
naming `tasks.bin`. A restore from the bin needs only `tasks.edit`.

The calls come from `board/pomb.lua`, a runner's Pomb contract notes and
Pomb's permission catalog.

For the deletes, the list above follows the Pomb 0.5.60 report. A `work` token
deletes its own comments, links and outcomes, which the older passages and
the contract still call admin-only, though dev lets only the lead delete an
outcome. Two cards track that, one for this file and one for the contract.

The review found no preset to change. The outcome delete is a Pomb right with
no dev call yet, and dev needs no token change for it.

## Laying out the board

`dev board init` brings the project's board to the standard, whether the
board is new or old. It adds what is missing, fixes what is wrong and never
deletes anything, so running it twice is the same as running it once.

It prints one line per change, and `Board X already follows the standard.
Nothing changed.` when there is none.

Every warning goes to standard error, like an error, and standard output keeps
the change lines that another tool may read. The warnings are the `kept
column`, `kept card` and `wears the disabled colour` lines, the two lines that
leave the agent roles (`not checked` and `left for --admin`), the line that
leaves the colours enabled and the line that names an unlisted first lane.

```
dev board init
dev board init --name ci
dev board init --admin
```

What it lays out:

- the `landing turn` card in the Icebox, made once, to spare each runner the
  create at its first landing.
- columns: Icebox, Backlog, Ready, In Progress, Review, Verify, Release,
  Blocked and Done, in that order, with Done counting as done.
  - A missing board is made from Pomb's `agent project` template, and the
    missing columns are added and moved into place.
  - A column named In Review is renamed to Review with its cards kept,
    through `PATCH /api/columns/{id}`, so no card is left in a column that no
    longer exists. It renames no column but In Review.
  - On a Pomb board, it gives the Ready, In Progress, Review, Verify and
    Release columns the stages `ready`, `in_progress`, `review`, `verify` and
    `release` through `PATCH /api/columns/{id}`, so the role token's standard
    moves resolve. One line per column, such as `set the in_progress stage on
    In Progress`. A column that already holds a stage, even another one, keeps
    it. A local board has no stages and says nothing.
  - A rerun changes nothing.
  - A column it does not know stays, comes after Done and is reported as
    `kept column "X", which is not part of the standard board`.
- lanes: the names in the `lanes` list of `[board]` in `.dev/config.toml`, in
  list order.
  - `init` makes each lane the board lacks at the end of the lane order, one
    line per change such as `created lane "Parity"`, and leaves the lanes that
    exist alone. A name matches without regard to case.
  - On a Pomb board, `init` says when the first lane is not in the `lanes` list
    and names it, to show where cards filed without `--lane` land. It changes
    nothing. Delete or reorder the lane in the Pomb UI.
  - It never renames, reorders or deletes a lane. A board with no `lanes` list
    gets none.
  - On a Pomb board the call is `POST /api/swimlanes`, which needs
    `swimlanes.create`, and only the lead token holds it. `init` uses the
    configured `lead_token` for every request unless `--admin` is given. The
    lead token may lack `roles.grant`, and the roles step then leaves its work
    for `--admin` without stopping the run, so the lead token makes the lanes.
    Under `--admin` the run stops at the lane step, after the other steps,
    when a lane is missing. It sends no lane request and names `lead_token`.
  - A local board gets the lane in the `swimlanes` list of its file.
- agent roles: the planner, implementer, reviewer, verifier, release and lead
  roles, granted to the board.
  - `init` first reads `GET /api/v1/agent-roles`, which needs `settings.read`
    only. When each of the six standard keys (a role's `standard` field) sits
    on a role whose `boards` list holds this board, it posts nothing and
    prints `agent roles unchanged`. A failed read counts as not granted, and
    when the post is then refused for `roles.grant`, `init` prints `agent roles
    not checked, the roles list could not be read` with the read's failure in
    place of the line that leaves the roles for `--admin`.
  - Otherwise it posts `{"boards":[board id]}` to Pomb's
    `/api/v1/agent-roles/standard` right after the columns.
  - It prints `created agent roles` with the names the reply lists, or
    `agent roles unchanged` on a rerun, which is not counted as a change.
  - A role that exists keeps its template.
  - The post needs `roles.grant` and a board the token holds.
    The lead token can run init once the roles exist, as the post is then
    skipped. A `permission_denied` is shown with the missing permission, and an
    `exceeds_grant` as `board unavailable: the token (role R) does not hold
    board X (ID), so it cannot be granted the standard roles; add the board to
    the token`, with nothing created.
  - When the refused permission is `roles.grant`, `init` prints ``The agent
    roles are left for `dev board init --admin`.``, counts no change and goes
    on to the later steps, the lane step included. Any other refusal still
    stops the run.
  - A local board has no roles, so it says nothing.
- role refusals: a refusal reads the token's `role_name` from
  `GET /api/v1/auth/whoami`, once, and only then.
  - A `permission_denied` 403 and an `exceeds_grant` 403 name the refused
    permission or action and the role, as `this token (role implementer)
    lacks the tasks.edit permission`.
  - A token with no role gets the plain text with no role named.
  - A 401 with the code `token_expired`, matched on the code and never the
    message, prints `the role token expired; mint it again from its issuer`.
- palette: yellow is `1 Pomodoro`, green `2 Pomodori`, blue `3 Pomodori`, red
  `>3 Pomodori` and white `Unsized`, with white as the default. A card keeps
  its colour in every column, so the colour is the only record of its size.
- colours that are on: white, yellow, green, blue and red are enabled.
  - Every other colour (orange, purple, magenta, cyan, brown) is disabled,
    one line per change such as `disabled orange`. Nothing is deleted.
  - A card that already wears a disabled colour keeps it and is reported on
    every run, one line each.
  - Pomb lets only an admin token change this. With the lead token a 403
    prints ``Left the colours enabled as they are, since this token may not
    change them. Run `dev board init --admin`.``, and the rest of the run
    still happens.
- size words off card names: a trailing `(yellow)`, `(green)`, `(blue)`,
  `(red)` or `(red, split)` comes off the name.
  - If the card is still white, has no colour, or has the colour that was the
    default when the run began (Pomb gave that to every card nobody
    coloured), the card takes the colour the word names.
  - A card with any other colour keeps it.
- limit group: when `GET /api/boards/{id}` lists no `limit_groups`, `init`
  posts `{"column_ids":[In Progress, Review, Verify ids],"limit":4}` to
  `/api/boards/{id}/limit-groups`.
  - It prints `created limit group In Progress, Review and Verify at 4`.
  - A board that has any group is left alone and says nothing.
  - A local board gets none and stays uncapped.
  - A 403 is shown with the `--admin` hint like the other changes.
  - `dev board limits` shows the result.
- labels: they need nothing. `needs:planner`, `needs:lead` and `needs:human`
  are plain strings on a card, and Pomb makes them when a card first carries
  one.

The board's name comes from `[board]`. In a project with no `[board]`
section, `--name N` names the board and `init` appends the section to
`.dev/config.toml` once the board is in order. `--name` with a different name
than the section's is a usage error.

### Tokens

By default `init` uses the lead token, `lead_token` in `[board.pomb]`, read
the same way as `token`. Pomb lets the lead token name colours, set the
default colour and reorder columns only on boards that token created.

On any other board Pomb answers 403 and `init` says to run it with `--admin`.

Pomb is moving to fine-grained tokens, and dev reads both servers:

- today: a refusal is `insufficient_scope` and `whoami` returns a `scope`.
- after the change: a refusal is `permission_denied` with the `permission`
  and a `board_id`, and `whoami` returns `permissions` and `boards` (`all`,
  or a list of ids and names).

dev prints two messages for the new refusal:

- `board_id` null: the token lacks the permission on every board, so use a
  token that has it. `init` adds the `--admin` hint to this one.
- `board_id` set: the token has the permission but is not assigned to that
  board, so add the board to the token. There is no `--admin` hint, as a new
  sign-in does not change the assignment.

A board missing from `GET /api/boards` on a token assigned only some boards
is reported as `board unavailable: pomb lists no board named X for this token,
which is assigned only to NAMES; if the board exists, add it to the token`. On a
token that sees every board it stays `board unavailable: pomb has no board named
X`.

`init --admin` accepts the sign-in in either case:

- `whoami` says `scope` is `admin`.
- `permissions` holds every permission the catalog
  (`GET /api/v1/auth/permissions`) lists for the `admin` preset, and `boards`
  is `all`.

`--admin` signs in through Pomb's device flow. dev prints a code and a link,
you open the link in your browser, check that it asks for `admin`, approve it
and pick an expiry, and dev carries on.

The token it receives is held in memory for that run. It is never written to
a file, put in an argument or an environment variable, or printed. If you
approve a lower scope than `admin`, `init` stops before changing anything.

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
Release, Blocked and Done.

A finished column is any column the backend marks done (`is_done` on Pomb, the
same flag in a local board's file). A board may have several, and for all of
them:

- `ls` hides their cards.
- `stale` never lists their cards.
- A blocker in one no longer blocks.

The other roles come from a `[board.columns]` table, read with the project file
over the user file. Each role defaults to its standard name, which
`dotfiles/bin/.config/dev/config.toml` ships:

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

A project whose board renames a column sets the role to the new name. It may
add `done = "Shipped"` to name the finished column `discard` moves a card to.
Without it, `discard` uses the first finished column in board order.

A column argument is a column's name in any case, a finished column's name or a
role word: `icebox`, `backlog`, `ready`, `progress`, `review`, `verify`,
`release`, `blocked` or `done`.

`dev board init` lays out the mapped names, with the mapped `done` (else Done)
marked finished. The rules in this guide say Ready, Blocked and the rest for the
roles, whatever the board calls them.

Every card in every column is fair game for an agent unless it is labelled
`needs:human`. What each column means, in the order a card travels:

- Icebox: an idea, maybe later.
  - A scoping agent sharpens, sizes and promotes cards to Backlog.
  - A `needs:human` card here is an idea you want to flesh out yourself.
- Backlog: wanted, not ready to run.
  - A card enters with a size, the card format v3 sections and an outcome.
  - A planner refines the description, the outcomes and the checks, and
    re-sizes the card if needed (splitting a red card, which may become an
    epic over its children).
  - The planner then moves it to Ready.
- Ready: an agent can run it with no questions.
  - It has size 1 to 3, v3, 3 to 7 outcomes (1 to 3 for an epic) and a checks
    row, which `dev board` enforces, except for an epic with children.
  - The top card is next, and the order within Ready is the priority.
  - A runner takes it by size: yellow by a haiku agent, green and blue by a
    sonnet agent.
- In Progress: an agent holds the card, under its name. Only the claimant works
  it.
- Review: the change is under review or ci.
  - The claimant dispatches the reviewers.
  - When every review is clean and the check passes, it moves the card to
    Verify. The card stays the claimant's.
- Verify: a verifier ticks the outcomes from the ci logs while the card sits
  here. Then `dev board land` lands it and moves the card to Release, or to
  Done when `[board.land] deploys` is not true.
  - dev board land merges a card once Verify passes.
    A card's change stays unmerged until land merges it.
    `jj land --no-card` is a second merge path, and a forge merge bypasses both.
    The WIP limit group counts only In Progress, Review and Verify.
- Release: where `[board.land] deploys` is true, land sends a card to Release
  and it waits there to go live.
  - A deploying repo merges many cards, then cuts and tests one release
    after about 10 cards land, or when a peer needs a change.
    Release drains at least once a day.
    Leave Release without a limit. A Pomb limit on a column refuses moves
    into it.
  - `dev board ship` runs the release command or the `[board.release]` checks
    rows once and moves every card with all outcomes ticked to Done.
  - `dev board move CARD done` moves one card and refuses while an outcome is
    unticked.
  - A card in Review, Verify or Release with no claim waits for that stage's
    role. A claim means the role is working it.
- Blocked: waiting on an answer.
  - A card moved to Blocked keeps its owner and keep-alive loop. `dev board
    ask` ends them, and so does a move out of Blocked from the machine
    holding the claim.
  - A take from elsewhere is refused with the owner and the lease end, as in
    `task owned by NAME until TIME`, until the lease lapses.
  - `needs:human` is yours alone, and only a question for you uses `dev board
    ask`. A question between agents is a blocked note holding the numbered
    menu.
  - An agent may set the size of a `needs:human` card with `dev board size`,
    and changes nothing else on it. Until `fff0e011` ships, Pomb refuses it on
    a locked card, and an agent never sets `unsized`.
  - `needs:planner` is for a planner. An implementer or reviewer who doubts
    a card's plan, an outcome above all, writes why in a blocked note holding
    the numbered menu of choices, moves the card to Blocked and labels it.
    They never reword or delete the outcome.
  - A planner who did not build the card finds it with `dev board next
    --column blocked --for planner` and parks on `timeout 86400 dev board
    wait --for planner`. The planner moves it to Backlog, keeps or rewords
    the outcome there or asks the lead to delete it, then moves it back to
    Ready.
  - The agent that writes the outcomes never ticks them, a verifier does.
  - A planner who cannot settle it runs `dev board escalate CARD TEXT`, which
    becomes `needs:lead`.
  - `needs:lead` is for a higher-tier agent, which answers and moves the card
    out.
  - A lead finds one with `dev board next --column blocked`, takes it before
    any Ready card, and parks on `timeout 86400 dev board wait --for lead`.
  - A lead that cannot answer asks you with `dev board ask`, which leaves the
    card in Blocked with `needs:human`. The chain is `needs:planner`,
    `needs:lead`, `needs:human`.
- Done: on main (and live where the project deploys), answered, or dropped
  with a note.

An agent with nothing Ready takes the top of Backlog and then Icebox, planning
the card first. It reads each card's comments before taking one.

A steering comment of yours (one that gives direction) is followed. The agent
folds it into the description and notes the decision.

When a steering comment lists options, the agent picks the one you favour and
says why in the decision note. A list with no favoured option is a choice only
you can make.

A card is parked only in two cases:

- One of your comments defers it ("not now", "after X") and no later comment
  lifts that deferral. A steer does not lift a deferral unless it says so.
- A comment holds a choice only you can make.

Parking sends the card to Icebox or Blocked with `needs:human`, and the agent
leaves it alone.

A plain question of yours is answered in a note, and the agent carries on with
the card. It parks only if the answer needs a choice only you can make, and
whether to defer a card is such a choice.

`needs:human` means only a human can answer. No agent answers for you on such a
card, and another agent relaying your view never counts.

Agents never move, edit or relabel such a card, except to set its size. The
label sits only in Blocked or Icebox, never Backlog.

dev enforces this:

- `edit` and `rename` refuse a card labelled `needs:human`.
- `move` refuses one headed for another column (exit 1).
- `label CARD needs:human` and `add --label needs:human` refuse a card outside
  Blocked and Icebox, so move it there first and add the label after.

Only you move the card out.

Setting the size is the third exception. An agent may run `dev board size CARD
1`, `2`, `3` or `3+` on such a card and change nothing else (until Pomb's
`fff0e011` ships, Pomb refuses it on a locked card and dev prints the reason).
A size answers no question, so an agent may change it to another size.

An agent never sets `unsized` on such a card. You set `unsized` yourself, with
`dev board size` in Icebox.

The other two exceptions both end with an agent removing the label:

- An agent that you answered directly in its own session removes the label
  through `dev board answer CARD --choice N --quote TEXT` and carries on.
- Once you move a card out of Blocked or Icebox, the first agent to see it
  elsewhere removes the label and follows that column. `stale` lists such a
  card under `moved by the owner`.

Your own comment on the card, or that session answer, counts as the answer only
when it settles every open choice. A partial answer keeps the label. A
`needs:human` card whose newest comment is yours counts as answered and waits
for your move.

Pomb 0.5.59 locks a card labelled `needs:human`. It answers 403 `card_locked`
to a token for these, and only a label change passes:

- a comment (create, and edit or delete of its own)
- a move
- a reorder
- a size change

dev prints that reason instead of a generic failure.

An agent asks you with `dev board ask CARD --question TEXT --choice
COLUMN=LABEL... --recommend N --why TEXT`. It sends Pomb's structured question:

- the question
- two to ten numbered choices that each name the column the card moves to
- the recommended choice
- why the agent cannot decide

Pomb moves the card to the column marked blocked, which `dev board init` sets,
and adds `needs:human`. It refuses a part that is missing in its own words,
which dev prints as they come (exit 1).

`ask` adds `needs:human` itself, so an agent never labels the card first. A
card that already carries the label is locked, and dev refuses the question
before it posts anything. The refusal tells the agent to run `dev board label
CARD --remove needs:human` and then ask again.

`ask` also refuses a card that `board.unplanned` finds lacking a size, a v3
section, a filled Change, Out of scope or Problem, or a Done when outcome (exit
1). The refusal names what is missing. Pomb locks a card once it carries
`needs:human`, and the lock refuses the edits that would plan it, so a question
on an unplanned card leaves you a question nobody can act on. Plan the card
with `dev board size`, `dev board edit` and `dev board outcome`, then ask.

Pomb refuses `note --kind question` without that shape, so `ask` is the only
way to put a question to you. `add --label needs:human` still creates the card
and its outcomes, then sets the label.

Once Pomb accepts the question, `ask` ends the owner lease on the card and
stops its keep-alive loop, when this machine holds the claim. The card waits in
Blocked with no lease held by the asking agent, so your answer does not depend
on that agent's loop.

`dev board answer CARD --choice N --quote TEXT` records your answer through
Pomb's answer API. The quote must hold your own words and may not be empty. dev
refuses an empty one before it calls Pomb.

On Pomb, dev answers every open question on the card with choice N and the
quote, in the order Pomb lists them. Before it writes anything, dev checks that
the open questions offer the same menu, with the same choices in the same order,
labels and columns. When they differ, or no question is open, dev refuses with
exit 1, writes nothing, and names each open question in quotes.

Pomb keeps `needs:human` and the column while another question stays open, and
on the last open answer it removes the label and moves the card to the
destination of choice N. Each answer is stored as relayed, with the token's name
and the quote, and a later failure leaves the earlier answers recorded with
Pomb's message. You can also answer in the browser.

Until Pomb's `fff0e011` ships, `order` and `size` fail on such a card, whatever
the rule says. `label --remove needs:human` stays allowed in any column.

An epic is a card of kind epic. `add --epic` creates one, `epic CARD` turns an
existing card into one, and a `parent` link needs one.

- `ls` and `next` print `[epic N of M open] ` before its name, and `[epic] `
  while it has no children.
- `show` prints `kind: epic, N open` above the `parent` and `children` lines.
- While a child is open, `next` never offers the epic, in any column, on Pomb
  or a local board.
- It needs 1 to 3 outcomes as its final check to enter Ready, where any other
  card needs 3 to 7.
- Once every child is Done it enters Ready and takes a claim like any card.
- `move CARD done` closes it once every child is Done and refuses it while a
  child is open.

To push a card later, drag it lower in Ready.

A card is named by its id or by a prefix of at least 8 characters that is unique
on the board.

`ls` prints the id prefix, column, size, labels and name, with Done left out
unless `--column Done` asks for it. When a listed card has Done when outcomes,
a column such as `1/3` (ticked over all) follows the labels. The size is the
card colour's palette label, or `unsized`.

`next` prints the top Ready card that is unclaimed, not blocked and not labelled
`needs:human`. After the card line it prints its comment count and how many of
those comments are the owner's (`2 comments, 1 the owner's`, or `1 comment` for
one). With no card it prints `No ready cards.`

A local board has no owner comments, so it always counts 0 as the owner's.

`next --column` changes what it picks:

- `backlog`, `icebox`, `review`, `verify` and `release` take the top such card
  of that column, or print `No cards in <column>.`
- `blocked` prints the top unclaimed card labelled `needs:lead`, never one that
  also carries `needs:human`, or `No cards in Blocked.` With `--for planner` it
  prints the top such card labelled `needs:planner`.
- Any other column is exit 2.

`add` puts a card in Backlog unless `--column` names another column. It writes
the three card format v3 headings into the description (Problem, Change and Out
of scope), filling Problem from `--description`.

A description that already holds a heading or the v1 Done when is kept as it
is. An Icebox card gets the text as given, with no headings.

Each `--done-when TEXT` (repeatable, at most 7) is a Done when outcome. `add`
creates the card, then appends one Pomb subtask per item. If an append fails,
`add` exits 1 and names the card and the outcome it stopped at, for example
`11111111 was added to Backlog but outcome 2 of 3 was not: ...`.

Nothing is rolled back (an agent token cannot delete a card, and deletes a
subtask only if that token made it). The failure is never queued, so a replay
cannot add the card twice. A queued add that never reached Pomb replays with all
its items.

With `--column ready`, Pomb gets the card in Backlog first and the move to Ready
comes after the subtasks. `note` adds a comment, of kind agent unless `--kind`
says otherwise. `move` puts the card at the top of the column.

`order CARD...` sets the top of one column in a single call. Every named card
must sit in the same column. Each goes to position 0, 1, 2 and so on in the
order named, and the cards not named keep their relative order below.

It prints the column's cards after the change, one row each as `ls` does. A
queued `order` replays like a `move`. Planners keep Icebox and Backlog in
priority order with it.

These fail with exit 1 before any move, and no card is touched:

- a card that is unknown
- a card named twice
- a card in another column than the first

A move that fails partway leaves the cards before it in place.

`add`, `note` and `edit` warn on standard error, and still write, when the prose
holds a hex id, a hash or a path, which the v3 format keeps in the Change
section only. One line names each word.

- A hex id is 7 or more hex characters with a digit and a letter.
- A path holds a `/` and starts with `~/`, `./` or `/` or ends in an extension.
- A URL is exempt.
- Text under `## Change` is not scanned, a note is all prose, an outcome is
  prose, and `--checks` is never scanned.

Only Icebox holds a card that is unsized or free-form. Every other column takes
a card with a size of `1`, `2`, `3` or `3+`, all three v3 headings with text
under Problem, and, for `add` and `move`, at least one Done when outcome (a v1
`## Done when` item counts).

A `move` of a card whose Pomb outcomes dev cannot read is not refused for
missing outcomes, except into Done and Ready. `dev.board.unplanned` is the one
check.

The refusals for a card that lacks these:

- `add` refuses a card without them and names what is missing (exit 2).
- `move` does the same (exit 1).
- `discard` refuses an unsized card or one without the headings but does not ask
  for outcomes (exit 1), so a card reaches Done unsized only by the Icebox
  `--reason` case below.
- `size CARD unsized` is refused outside Icebox (exit 1).
- `edit` refuses a text that drops a heading outside Icebox (exit 1).
- A move into Icebox always works.

An epic follows the same rule with 1 to 3 outcomes in place of 3 to 7, except
that an epic with every child Done closes with none.

Sizing is part of planning, so a card also cannot enter Ready as red. `move CARD
ready` refuses a card that is unsized (white or no colour) or red, more than 3
Pomodori, and says to run `dev board size CARD 1`, `2` or `3` (exit 1). A red
card is split instead.

`add --column ready` without `--size 1`, `2` or `3` is a usage error (exit 2).

A card also needs card format v3 to enter Ready:

- all three headings with text under each
- no `Change:` or `Out of scope:` line under Problem
- 3 to 7 Done when outcomes (subtasks)
- each outcome ends with `(check: ROW)`, where ROW is part of one checks row,
  or with `(reviewer judgement)`

A card with no outcomes is still accepted when its description has a v1
`## Done when` checklist item, until the boards are converted.

`move CARD ready` refuses a card without them and names what is missing (exit
1). `add --column ready` does the same for its description and `--done-when`
items (exit 2).

Icebox cards are free-form, so adding to or moving into Icebox is never
checked. `add` fills the sections from `--problem`, `--change` and
`--out-of-scope`, and `--description` cannot go with them. A repeated `--change`
adds a line each, and a repeated `--problem` or `--out-of-scope` is refused.

A card needs a checks row to enter Ready too. The checks live in the board's
`dev.checks` field, a table with a `run` column, and `add --checks CMD`
(repeatable) writes one row per command.

- `move CARD ready` refuses a card with no row (exit 1), unless the card has
  children.
- `add --column ready` without `--checks` is a usage error (exit 2).
- On a Pomb board that has no checks field, both say so and point to
  `dev board init`, which defines the field once and never touches one that
  exists.

`checks CARD CMD...` replaces the rows of a card that is already on the board
(one row per command, so it also adds a second command). It prints
`set checks <id prefix>, N rows` (`1 row` for one).

- With no command it is a usage error (exit 2), to keep anyone from clearing
  the rows by accident.
- It sends the claim's fence when this machine holds one.
- It gives the same refusal as a move into Ready on a Pomb board with no checks
  field.
- It is queued while Pomb is unreachable (sending the same rows twice changes
  nothing more).

Both `checks` and `add --checks` apply the write-time refusal of
`dev board check` to every row. A row is a usage error (exit 2) naming the row,
and nothing is written, when it:

- holds a shell character (a quote, a backslash, `*`, `|` and the rest)
- starts with a dotted run such as `dev.--remote.lint`
- passes a word to `dev --remote test` or `dev --remote lint` before the double
  dash

A test name goes after the double dash, as in `dev --remote test -- NAME`. A
leading `! ` is allowed. Rows already on a card are not rewritten.

`show` prints the rows under the description. Icebox is exempt.

A planner also runs each new rg row against a small sample of the intended
result and confirms it passes. The planner also confirms that the row matches
behaviour rather than a name the builder may choose, and checks every rule
number or section the card names against the file.

A must-not-match row (`rg --files-without-match`) names one file. With several
files it passes when any one lacks the text.

The planner reads the code each Change bullet relies on before filing.

Three more card fields are set the same way. Each replaces the field's
whole value under the claim's fence and is queued while Pomb is unreachable.

A board that lacks the field is refused before any write (exit 1), naming the
field. The message reads
`The board has no dev.allow field. Define it on the board first.`
`dev board init` defines none of them.

- `allow CARD WORD...`: sets `dev.allow`, a multiselect, to the JSON array
  of `test-edits` and `ci-edits` given (duplicates dropped). `allow CARD none`
  sends null to clear it. Any other word, or `none` with another word, is a
  usage error (exit 2).
- `tests CARD NAME...`: sets `dev.tests`, a multiline text field, to the
  names joined one per line. A blank name or one holding a line break is exit 2.
- `files CARD PATH...`: sets `dev.files`, a multiline text field, the same
  way.

`show` prints `allow:`, `tests:` and `files:` blocks after `checks:` when set.
A local board stores the same values on the card.

`show CARD` prints everything a runner needs to take a card:

- the `ls` line (id prefix, column, size, labels and name)
- the description
- the outcomes as `done when:`, one `- [x]` or `- [ ]` line each
- the comments in the `notes` format

Each comment prints its whole body, with the lines after the first under the
body column, so a numbered menu reads whole. A card with no description prints
`no description`, and one with no comments `no comments`.

Use it instead of the Pomb API to read a card, so the token stays inside dev.
`links` lists its links. A child also prints `parent: <id prefix> <name>` under
the `ls` line, and an epic `children: N of M done`.

`edit CARD [--board B]` replaces a card's description with the text of
`--file PATH`, or of standard input when there is no `--file`. It prints
`edited <id prefix>`.

The format v3 description always holds the current plan, so rewrite it after a
decision. Trailing whitespace is dropped, and empty text is a usage error (exit
2), to keep an empty pipe from wiping a plan.

It sends the claim's fence when this machine holds one. It does not touch the
title or the comments.

`note CARD --kind K --as ROLE TEXT` tags the comment:

- `K`: decision, blocked, status or done (agent when omitted)
- `ROLE`: a free label of at most 80 characters, such as planner, implementer
  or reviewer, that lets agents sharing one token tell themselves apart

`question` is exit 2 and names `dev board ask`, which sends the owner a question
in Pomb's structured shape. A note that begins with a dash still posts as text.
`--edit` changes only the text, so the kind and the label stay, and a queued
note replays with both.

`notes CARD` lists the card's comments, oldest first. Each line holds:

- the comment's id prefix
- who wrote it (the token's name, else the kind of actor)
- its kind
- its role label (`-` when it has none)
- the time in UTC
- the first line of the body (`show` prints the rest of a multi-line body,
  `notes` does not)

`note CARD --edit COMMENT TEXT` replaces the text of one of your own comments
and `note CARD --delete COMMENT` removes it. `COMMENT` is an id prefix of at
least 8 characters from `notes`.

Pomb lets a token change only the comments it wrote. A comment from a person,
from another token or from before Pomb 0.5.7 answers 403, and dev says
`that comment is not yours to change` (exit 1).

A deleted comment is gone for good (Pomb keeps no recycle bin for comments).

`ls` on a colour terminal prints a summary line
(`12 cards · 3 backlog · 2 ready`), a size legend and a table. In the table the
size is dots (one yellow, two green, three blue, four red, three dim hollow ones
for unsized) and the outcomes are a `▰▱` meter with `2/4`.

`ls --group` draws one block per column instead, with the column's name and card
count as its heading. `--column`, `--label` and `--size` filter both layouts,
and a tall list goes through your pager.

Piped output, `NO_COLOR` and `TERM=dumb` keep the plain aligned lines with or
without `--group`.

`size CARD S` sets a card's colour from the size word `S`:

- `1`: yellow
- `2`: green
- `3`: blue
- `3+`: red
- `unsized`: white

`add --size S` does the same when it makes the card. `ls --size S` keeps only
the cards of that colour, where a card with no colour counts as unsized.

Any other word is a usage error (exit 2) that lists the five. The colour is
found by its value in the board's palette, never by its label, so it works
before and after `dev board init` names the labels.

A Pomb board missing the colour fails with
`board unavailable: the board has no yellow colour`, and a local board with
``The board has no yellow colour. Run `dev board init`.``

`outcome CARD TEXT` appends a Done when outcome to a card that already exists
(`POST /api/tasks/{id}/subtasks`) and prints `outcome <id prefix> N added`.

It is exit 2 when a word of `TEXT` is `--tick`, `--untick`, `--rename` or
`--convert`, or when `TEXT` is only a number. The message names the form meant,
such as `outcome CARD --tick N`. A flag inside one quoted sentence is plain
text.

The other forms change the Nth outcome:

- `outcome CARD --rename N TEXT --reason TEXT`: rewords it (the first `--reason`
  ends the new text)
- `outcome CARD --tick N`: marks it done
- `outcome CARD --untick N`: clears it

The rename, tick and untick calls are
`PATCH /api/tasks/{id}/subtasks/{sub_id}` with `name` or `done`. Each prints
`outcome <id prefix> N reworded`, `ticked` or `unticked`.

`N` counts from 1 in the order `show` lists the outcomes, and an `N` past the
last outcome is exit 1.

A tick names its ticker with `--as NAME` after the number
(`outcome CARD --tick N --as NAME`), else with `DEV_AGENT`. It prints
`ticked by NAME`.

On a claimed card the ticker must be a name other than the claimant's. No name
is exit 2 and the claimant's own name is exit 1, with nothing written. The name
is self-declared, so dev checks only that it differs from the claimant.

An unclaimed card needs no name, and a `DEV_AGENT` that is not one word is
ignored there. `--untick` takes no name and stays open to anyone.

`--as` is read only after `--tick`, `--delete` and `--convert`. On the other
forms it is ordinary text, so `--untick N --as X` is exit 2 for its extra words.
A queued tick keeps the name it resolved, so a later sync records the same
ticker.

`outcome CARD --delete N --reason TEXT [--as NAME]` removes the Nth outcome
(`DELETE /api/tasks/{id}/subtasks/{sub_id}` on Pomb) from a card in Blocked,
Backlog or Icebox. Outcomes are fixed from Ready on.

A card is refused with exit 1 naming the column, with nothing written or queued,
when it sits in:

- a column mapped to the ready, progress, review, verify or release role
- a finished column
- a column outside the role map

The roles come from `[board.columns]` and `is_done`, never from a column name.

Only the lead deletes an outcome. A `DEV_AGENT` whose role segment is not lead
is refused with exit 1 and nothing written, before any backend call. A runner,
implementer, planner or reviewer asks the lead with the card, the number and the
reason.

The outcomes after it move up a number. The command writes a decision note
holding the deleted text and the reason, then prints
`outcome <id prefix> N deleted`.

A missing number or reason is exit 2. `--reason` is the one way to say why an
outcome that was never achievable is deleted and not reworded.

On a Pomb board the DELETE goes out with the lead token, `lead_token` in
`[board.pomb]`, never with the work token, `DEV_BOARD_TOKEN` or the token file
for `DEV_AGENT`, which every other verb reads first. Pomb 0.5.78 gives
`subtasks.delete` to the lead tier only. A local board needs no lead token.

A delete is refused when:

- a missing `lead_token` exits 1 before any request, naming `subtasks.delete`
  and the lead token
- a 403 `permission_denied` for `subtasks.delete` exits 1 with a message that
  names `subtasks.delete` and the lead token
- a locked card gets 403 `card_locked` for every token
- a column entry rule can refuse a delete that leaves the card worse

`--delete` prints Pomb's reason for each refusal, writes no note and changes
nothing.

A delete is never queued for a later sync, to keep its number from pointing at a
different outcome by then. dev never reorders an outcome.

The claim's fence goes along when this machine holds one, and a local board
keeps the same outcomes on the card.

The card's claimant and every name in its claim history (the `dev-claim:` notes
that `review` reads) are refused an outcome add, `--convert`, `--delete`,
`--rename` and `dev board checks`. The refusal is exit 1 with nothing written.
The builder passes a change back with a note instead, to stop a released runner
from rewording the card and taking it back.

The refusal compares the names with `DEV_AGENT` and, after `--delete` and
`--convert`, with the `--as` name. `checks` reads `DEV_AGENT` only.

The lead (a name with no `/`) and any name that never claimed the card may
change outcomes and checks, except that only the lead deletes an outcome. A
session with no `DEV_AGENT` is not checked.

`outcome CARD --convert` moves a v1 `## Done when` checklist into outcomes. It
appends one outcome per `- [ ]` or `- [x]` item and ticks the ticked ones. Only
once all of that succeeded does it rewrite the description without the heading
and the items, then print `outcome <id prefix> converted N outcomes`.

The ticked items are ticks. On a claimed card with any `- [x]` item it takes the
ticker the same way as `--tick` (`--as NAME` or `DEV_AGENT`, never the
claimant's name) and refuses before it writes anything.

A card that already has outcomes, or has no checklist, is left as it is with one
line saying why (exit 0), so a second run changes nothing.

`add --label L` gives a new card a label, and may be repeated. `label CARD L`
(or `+L`) adds a label to a card and `--remove L` removes one, each as many
times as you like in one call, the additions first.

Pomb replaces a card's whole label list on a change. So `label` reads the
current labels, applies the edits and sends the full list, with the claim's
fence when this machine holds one.

Adding a label the card has, or removing one it lacks, changes nothing and sends
nothing. A label is one word with no spaces and no leading `-`, and anything
else is a usage error (exit 2).

The escalation labels `needs:planner`, `needs:lead` and `needs:human` are plain
labels to dev. Pomb has no add or remove call and takes the whole list, so two
agents editing the same card's labels at the same moment can lose one edit.

`link CARD KIND OTHER` links two cards:

- `KIND`: `blocked_by`, `blocks`, `related` or `parent`
- `OTHER`: a card of this board, by id or prefix, or `BOARD:PREFIX` for a card
  on another board of the same Pomb server

dev finds the card on another board by reading that board, so write the work
that spans repos as `dev board link 5ff0e014 blocked_by ci:1a2b3c4d`. It prints
`linked <id prefix> <kind> <other>`.

Pomb keeps one link whichever card holds it, and asking again for a link it has
changes nothing. So a `link` that could not reach Pomb is queued with the
others. Pomb refuses a card linked to itself and a link that would make cards
wait on each other.

`dev board link CHILD parent EPIC` makes the other card the epic of the first.
dev refuses an `EPIC` that is not an epic before any request, naming
`dev board epic EPIC`.

A card has one epic and epics nest to any depth. Pomb refuses a second epic and
a link that would make a cycle, and a local board refuses them too, naming the
two cards the link joins. Epics count their direct children.

A local board stores the links on its own cards, links only its own cards, and
its `next` skips a card that a card outside Done blocks.

`links CARD` lists a card's links, one line each:

- the kind as the card sees it (`blocked_by`, `blocks`, `related` or `parent`)
- the other card's id prefix
- the name of its board, with `-` for this board

A card with no links prints `No links.` It lists both sides of a link, the ones
the card holds and the ones another card holds on it, which show as `blocks`,
`related` or `child`.

A link to a card on another board shows that board's name, so
`blocks  1a2b3c4d  ci` reads as a card on `ci` that this one blocks.

`unlink CARD KIND OTHER` removes a link the card holds, named as `links CARD`
shows it, and prints `unlinked <id prefix> <kind> <other>`. A card with no such
link exits 1 and lists its links.

A `child` line cannot be removed (`child` is not a link kind). Remove the other
card's `parent` link instead.

Pomb lets a token delete only the links it created. A link another token made,
or one made before Pomb 0.5.40 (which records no creator), gets a 403
`permission_denied`. dev reports it as `pomb kept the link: ...` and exits 1,
leaving the link in place.

Unlike `link`, `unlink` is not queued while Pomb is unreachable.

`attach CARD FILE...` uploads each file to a Pomb card. It prints
`attached <id prefix> <name>`, or `skipped <name>` when the card already holds a
file of that name, so a rerun uploads nothing twice.

`attachments CARD` lists the card's files, one line each with the id prefix, the
size in bytes and the name, or `No attachments.` `detach CARD ID` removes the
attachment whose id starts with ID and prints `detached <id prefix> <name>`.

dev checks no size and no type. Pomb enforces its own limits and dev prints its
refusal as Pomb words it. A 503 `busy` answer is retried after a short nap.

A token without `attachments.delete` gets the permission message, and agents do
not detach. A local board refuses all three with
`a local board holds no attachments`. None of them is queued while Pomb is
unreachable.

`stale [--days N] [--icebox-days N] [--lead-hours N]` lists the cards that have
sat in Backlog, Ready, In Progress, Review or Verify for `N` days or more, 7 by
default, oldest first. Each line is the id prefix, the column, the days in it
(`9d`), the size and the name.

It counts whole days from the card's `column_entered_at`, which Pomb gives every
task view, so a card at 6 days is fresh and one at 7 is stale. Icebox, Blocked
and Done are never stale.

A `--days` that is not a whole number of 1 or more is a usage error (exit 2).
When nothing is stale it prints `No stale cards.`

These sections follow, each listed apart from the stale cards:

- `for the owner (needs:human):`: every card with the `needs:human` label in
  Blocked or Icebox, at any age, with its column and days in column. It never
  appears among the stale ones (it waits on the owner, not on an agent).
- `moved by the owner, remove needs:human:`: a card with that label in any other
  column, Done included, to show that the owner moved it out and an agent
  should take the label off (per the board guide).
- `for a lead (needs:lead):`: every card labelled `needs:lead` (and not
  `needs:human`) that has sat in Blocked for `--lead-hours` hours or more (1 by
  default), with its time as `<hours>h`. An unclaimed card that `next --column
  blocked` would skip (a run card, an epic with an open child or a card an open
  card blocks) is not listed. A claimed card is.
- `for a planner (needs:planner):`: a card labelled `needs:planner` in Blocked
  for as long, listed the same way.
- `asks nobody, add a needs label:`: every card in Blocked with none of
  `needs:human`, `needs:lead` and `needs:planner`, at any age, with its days in
  column. Nobody is asked to answer it, so a lead or the owner never sees it
  until someone labels it.
- `unsized outside Icebox:`: every card that is unsized (white or no colour), in
  any column but Icebox, at any age, with its id prefix, column and name, so a
  planner sees what still needs a size.
- `todo files, move their items onto cards:`: `TODO.md` and `docs/TODO.md`, one
  line each, for each that exists under the project's root. The section is
  absent when neither exists, and dev reads no item in the file.
- `icebox, untouched for N days:`: the Icebox cards nobody has looked at. The
  card's time in Icebox and its latest comment are both `--icebox-days` days old
  or older (30 by default), counted from the later of the two. Cards labelled
  `needs:human` are left out, and the section is absent when no card qualifies.

A card in one of the scanned columns, or with the `needs:human` label, that the
tasks view did not date gets a line `could not date <id> <name>` after a blank
line, instead of being skipped. A card the Icebox section cannot date, or whose
comments it cannot read, gets a `could not` line after the section.

An orchestrator can run it at startup and re-plan, escalate or ice each card it
lists, and scope the Icebox ones.

`lint [CARD] [--strict]` reports every card that breaks the board's rules. The
guards in `move`, `add` and `discard` stop a bad write only when it goes through
`dev board`, and lint also sees the cards written in the Pomb UI, by another
client or before a guard existed.

With a `CARD` id prefix, lint reports only that card, so a checks row of
`dev board lint CARD` fails only for its own card. A prefix that matches no card
or more than one is exit 1.

It makes no write of its own and calls no model. Like every board command on a
Pomb board, it first replays any queued changes. Each finding is one line of id
prefix, column and rule, in board order.

A finding only the owner can fix ends in `(owner)`. That is any finding on a
`needs:human` card, except a missing size and a `needs:human` label outside
Blocked and Icebox, which an agent fixes.

The exit is 1 when any finding is left that an agent may fix, and 0 with
`No findings.` or when every finding is the owner's, so a card whose checks run
lint can land while the owner has an open question. `--strict` exits the same
way.

The rules:

- Outside Icebox: a size, the three v3 headings with text under Problem, and a
  Done when outcome. This is `dev.board.unplanned`, the check `move` and `add`
  make, which keeps a move, an add and lint in agreement.
- Where a card's sections are checked (outside Icebox and not Done, or every
  Done card under `--strict`), `dev.board.unplanned` also reports the shapes of
  `dev.board.shapes`, which `move CARD ready` shares: no text under Change or
  Out of scope, and no `Change:` or `Out of scope:` line under Problem. So a
  move into In Progress, Review, Blocked or Done and an add to Backlog refuse
  them too, and lint reports each once. `dev board discard` skips the shapes.
- A Done card gets the size and outcome checks only, and a Done card labelled
  `discarded` needs no outcome.
- An epic, a card with children, needs 1 to 3 outcomes. A Done epic with every
  child Done may have none, and 1 to 3 if it has any. Lint reads the children of
  every card it checks for outcomes.
- With `--strict`, a Done card also needs the three v3 headings with text under
  Problem. A discarded card is held to the rule `discard` applies. Older Done
  cards are v1 and fail it until their descriptions are rewritten.
- Outside Icebox and Done: a description of at most 400 words. In Ready, In
  Progress and Review, a checks row, unless the card has children. In Ready, no
  red size.
- `needs:human` sits only in Blocked or Icebox.
- A Blocked card holds a `question` or `blocked` note or a `blocked_by` link.
- An In Progress card holds a claimant, an epic too.
- A Done epic that was not discarded has every child Done: `N of M children
  open`.
- A Done card that was not discarded has every outcome ticked.
- A Done card that was not discarded names no one as both its builder and a
  reviewer: `built and reviewed by the same name: NAME`. The builders are the
  names in the card's claim records, and the reviewers are the `by` names in its
  review records. Every name in a claim record counts as a builder, whatever
  role it worked in.

A card whose outcomes Pomb sent in a shape dev cannot read is reported as
`outcomes unreadable`, never as having no outcomes.

Fixing a finding is the agent's job, except on a `needs:human` card, which
belongs to the owner apart from its size. An agent may set that with
`dev board size CARD 1`, `2`, `3` or `3+`.

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

`dev board init` lays out the columns and the palette in the file. A local board
has nothing to sync, so `dev board sync` says so.

A local board works as follows:

- writes: two processes can write at once. Each change takes a lock beside the
  file, reads it again and renames a finished copy into place.
- claims: `take` sets a claim that lapses after twice the card's size and needs
  no loop. `release` gives it up.
- notes: only a note written by dev can be edited or deleted.
- lanes: an optional `swimlanes` list of `{id, name}` in the file orders the
  lanes, and a card's `swimlane_id` names its lane. A card with none or an
  unknown lane sorts after every lane and prints `-` for its lane.

## When Pomb is unreachable

On a Pomb board, a write that cannot reach Pomb, or cannot read the token
(`pass` is locked), goes into a queue. The queued commands are `add`, `move`,
`note`, `size`, `label`, `link`, `edit` and `outcome`. `check` is never queued.

A timeout or a gateway error may come after Pomb applied the change. For those,
only a command that is safe to repeat is queued:

- queued: `move`, `size`, `label`, `link`, `edit` and `outcome` with `--tick` or
  `--untick`.
- failed instead of risking a duplicate: `add`, `note`, an `outcome` append,
  `outcome --rename` (a replay would note the new text as the old) and
  `outcome --convert`.

A move to Done is never queued. Its outcome check reads the card from Pomb now,
so it is refused and can be run again once Pomb answers. A queued write prints:

```
queued: Pomb unreachable, will sync
```

The queue is `~/.local/state/dev/boards/<name>.queue`, readable by you alone. It
holds the commands as you typed them and never the token.

`dev board sync` replays the queue in order once Pomb answers. Every other
`dev board` command on the board tries that first when the queue is not empty.
Card ids are matched when the change is replayed.

A replay can end in three ways:

- Pomb refuses a change (for example the card is gone): dev reports
  `dropped <command> <card>: <reason>` and removes it, so it is never retried.
- dev is killed in the middle of a change: the change stays queued and may be
  sent twice.
- Pomb is still down: the rest stay queued, and `sync` prints how many are left
  and exits 1.

A missing queue file is an empty queue. A damaged queue file, for example
hand-edited into invalid JSON, is never treated as empty and never overwritten.

`dev board sync` exits 1 and prints:

```
dev: <file>:<line>: <reason>. The queue is left in place.
```

Any other `dev board` command prints that line on standard error, skips the
replay and runs as usual. A write that cannot reach Pomb then fails instead of
being queued. Fix or delete the file to go on.

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

Each mode wakes on its own events:

- `--for ready`: a card added to Ready or moved into it. It prints
  `added <id prefix> to Ready` or `moved <id prefix> to Ready`.
- `--for review`, `--for verify` and `--for release`: the same for that column,
  but only for a card nobody has claimed.
- `--for human`: a card the owner moved out of Blocked, and a card in any column
  but Done whose newest comment is the owner's and newer than the wait's start.
  It prints `moved <id prefix> out of Blocked` or
  `the owner commented on <id prefix>`.
- `--for lead`: a card added, moved or updated that is now in Blocked with the
  `needs:lead` label, no claim and without `needs:human`. It skips what
  `next --column blocked` skips: a run card, an epic with an open child or a
  card an open card blocks. It prints
  `<id prefix> is labelled needs:lead in Blocked`.
- `--for planner`: the same for `needs:planner`. It prints
  `<id prefix> is labelled needs:planner in Blocked`.
- no `--for`: every added card, move, update and comment.

A move by an agent never wakes `--for human`, nor does a move made in an
earlier second than the wait started or a comment of an agent. The first
owner event opens a settle window of 60 seconds. The wait keeps listening until
no new event from the owner has come for that long, to catch a second reply,
then prints one line per card the owner touched, not one per comment.

The woken agent reads every comment with `dev board show`. Pomb's events carry
no labels, so `wait` reads the board for each batch of events.

Any other `--for` value is a usage error. On a local board `wait` prints
`dev: A local board has nothing to wait on.` and exits 1, and it is never queued.

The command asks Pomb for events after a cursor and holds each request for up to
50 seconds. On a quiet board it repeats until a matching event arrives.

The cursor lives in `~/.local/state/dev/boards/<name>.<mode>.cursor` (`<mode>`
is `ready`, `human`, `lead` or `all`), readable by you alone and saved after
every reply. `--for human` saves it only when it prints its held lines, so a
kill inside the settle window leaves them to print again. A change made while
no wait was running wakes the next one, except that `--for human` ignores a
move made before it started. With no cursor file the first call starts from
now.

When Pomb has dropped the events after the stored cursor, `wait` stores the
oldest one it still has, prints `events were trimmed, check the board` and exits
0. Look at the board and run it again. `--for human` instead keeps waiting on a
trim, and exits only when a card that sat in Blocked or Icebox when it started
has left it. It then prints `events were trimmed, check the board` after the
lines it holds.

An unreachable Pomb (no route, a locked `pass`, a gateway error) is retried
every 30 seconds. After ten failures in a row `wait` exits 1 with the message.

Pomb allows 4 open waits per token and every session shares one, so a fifth
session gets a 429 with the code `too_many_waits`. That is never a failure.
`wait` prints one line on standard error the first time and keeps waiting until
a slot frees.

It retries with a pause that doubles from 30 seconds to 5 minutes. Each pause is
cut by a random fraction of up to a quarter, to keep sessions from retrying
together. Any other refusal, such as a bad token, exits 1 at once.

Exit 124 from `timeout`, or 143 from the `run_with_timeout` wrapper in the
background-work rules, means nothing changed. With nothing to do and no card in
flight, end the session (a session started later under the same `DEV_AGENT`
picks its open run card up with `dev board run`). Otherwise park again.

## Claims

`take` claims a card so no other agent picks it up, and starts a loop that keeps
the claim alive. The claim lasts 900 seconds. The loop renews it every 5 minutes
with curl, so it costs no model turns and outlives the shell that started it.

The claimant is the name from `take --as NAME`, else the `DEV_AGENT`
environment variable, else `dev@<host>:<session>`. The session is
`CLAUDE_SESSION_ID`, else the login user and the controlling terminal of dev's
process, else that process's pid when it has no terminal. A name is one word of
letters, digits and `.`, `-`, `_` and `/`, else exit 2. `ls` shows it as the
holder.

Agents name themselves `<repo>/<role>[/<card>]`: the board name, any role word
and an optional card id, as in `dotfiles/lead` and
`dotfiles/implementer/f5f0e007`. Each part is letters, digits, `.`, `_` and `-`.
The usual roles are `lead`, `runner`, `planner`, `implementer`, `code-examiner`,
`style-examiner`, `recheck-examiner`, `verifier`, `land`, `release` and `check`.

A grab on a Pomb card sends the role part of that name as the owner's `role`,
so `dotfiles/implementer/f5f0e007` sends `implementer`. A name with no role part,
such as the default `dev@<host>:<session>`, sends no role.

A name of another shape is refused with
`an agent name is <repo>/<role>[/<card>], got NAME` (exit 2). That happens when
`take` or a `move` into In Progress would take a new claim, whether the name
came from `DEV_AGENT` or `--as`. Every other verb on a card already claimed
under that exact name passes, so a card claimed under an older name finishes and
lands under it.

An unset or empty `DEV_AGENT` is accepted.

`move CARD progress` takes the claim itself, under the same name and with the
same keep-alive loop, when nobody holds the card. A card with children stays
unclaimed. A claim this machine already holds is kept, and one held by someone
else leaves the move to fail as the backend answers.

After a claim it takes, `take` prints the card as `show` does, with every
comment in full, so the owner's comments are read before any work. A `move` into
In Progress that takes the claim does the same. A `move` that finds the claim
already held prints only the `moved` line.

```
dev board next
dev board take 8af0e001
dev board move 8af0e001 progress
```

`move` refuses to take a claimed card out of In Progress to Review, Ready or
Blocked (exit 1) until its claimant has left a note after claiming it. The
refusal reads ``Card ID has no note from its claimant NAME since the claim. It
cannot leave In Progress. Note what you built, tried and learned first with
`dev board note ID TEXT`.`` The claim writes a `dev-claim: by=NAME` comment.

dev finds the note by who posted it, never by its text or `--as` label. The note
is any later comment posted by the same Pomb token as the latest such record for
the claimant. A comment does not count when its body begins with a prefix a dev
verb writes (`dev-check:`, `dev-review:`, `dev-turn:`, `dev-claim:`) or its kind
is decision.

A client that posts through the claim's token satisfies the
check with any text. A card with no claim record for its claimant is not
checked. A move after the note releases the claim as before.

The loop stops in four cases:

- you `release` the card.
- you `move` the card to any column but In Progress or Blocked.
- Pomb refuses a renewal (the claim is gone).
- twice the card's size has passed: 50 minutes for 1 Pomodoro, 100 for 2
  Pomodori and 150 for the rest.

A crashed agent therefore loses its claim within 15 minutes of the loop's end. A
network failure does not stop the loop.

`check` renews the claimant's claim and restarts the loop before each row to
keep a long ci run inside the loop's cap, and `land` does the same before its
checks and again after its recheck. Only a caller that holds the card's claim
state and is its claimant renews anything. A renewal that fails prints a note
and the command goes on. It leaves the old claim and loop as they were and
never releases the claim.

A `move` out of In Progress to any column but Blocked also releases the claim
once the move has succeeded. A refused release prints a warning and leaves the
move done.

A `move` to Blocked keeps the owner and the keep-alive loop. `ask` ends them
once Pomb has parked the card, and so does a move out of Blocked from the
machine holding the claim. Otherwise the owner lease runs until it lapses, and a
take from elsewhere is refused with `task owned by NAME until TIME`.

The loop's state is a file named for the card in `$XDG_STATE_HOME/dev/board/`,
or `~/.local/state/dev/board/`, with the card, the fence and the loop's pid at
mode 600. It never holds the token.

The loop reads the token for each renewal, from the Keychain or else `pass`, and
hands it to curl on standard input to keep it out of every argument list,
environment variable, file or output. While you hold a card, `move` and `note`
send its owner fence, and `ls` shows each live owner's holder in a column before
the name.

## Reference: the subcommands in detail

`dev board` is a built-in noun for any project. It reads and updates the
project's kanban board so an agent never handles the API.

It is machine-local. `--remote` refuses it, as does the root refusal.

`dev help board` lists every subcommand. `tests/lua/help_test.lua` fails when a
verb in the commands table or a board handler has no builtins row, or when a
non-hidden row is missing from that listing.

### status

`dev board status` prints the board the config names, with no network.

- It prints `backend: pomb` and `board: <name>` from the config.

### init

`dev board init [--name N] [--admin]` brings the board to the standard.

- It prints one line per change (below).

### ls

`dev board ls [--column C] [--label L] [--size S] [--lane L] [--group]` lists
the cards.

- `--lane L` keeps the cards of one swimlane. A lane the board lacks is a usage
  error (exit 2) that names the lanes it has, and a board with fewer than two
  lanes has none to name.

- It prints one line per card: id prefix (8 characters), column, size, labels
  (`-` for none) and name, in column then board order, aligned.
- On a board with more than one swimlane, a lane column sits after the column,
  and the order is column, then lane order, then position. A card in no known
  lane sorts after every lane and prints `-`. A board with one lane prints no
  lane.
- Done is left out unless `--column` names it.
- A done column such as `1/3` (ticked outcomes over all, `-` for a card with
  none) sits after the labels, only when a listed card has outcomes.
- `--size` keeps one size (`1`, `2`, `3`, `3+` or `unsized`, where a card with
  no colour is unsized).
- It prints `No cards.` when nothing matches.
- When standard output takes colour (`dev.ui.context`: a terminal, no
  `NO_COLOR`, `TERM` not `dumb`) it draws more than the plain lines:
  - A summary line `N cards · n backlog · ...` (the listed cards, by column).
  - The legend `size  ● 1  ●● 2  ●●● 3  ●●●● >3  ○○○ unsized`.
  - A table with a dim bold header (ID, COLUMN, SIZE, LABELS, DONE, HELD BY
    only when a listed card is claimed, NAME).
  - The size as yellow, green, blue or red dots (`○○○` dim for unsized).
  - DONE as a `▰▱` meter with `2/4` (`-` dim with no outcomes).
  - In Progress green, Blocked yellow, other columns dim and labels yellow.
  - The table goes through `dev.ui.page` when taller than the screen.
- `--group` instead lists the cards under a bold column heading with a dim
  `N cards`, and a dim line saying Done is left out unless `--column done`.
- Piped, with `NO_COLOR` or with `TERM=dumb`, the output is the plain lines
  above and `--group` changes nothing.

### next

`dev board next [--column C] [--for planner|lead] [--lane L] [--max-size N]`
prints the top Ready card that is unclaimed, not blocked and not labelled
`needs:human` or `run`.

- `--lane L` takes the top such card of one swimlane, with the same usage error
  as `ls` for a lane the board lacks.
- With no `--lane` on a Pomb board of two or more lanes, `next` asks each lane
  in lane order and then the cards of no known lane, and prints the first card
  it may take. Pomb numbers positions within one lane, so its own column order
  would not put the earlier lane first. A board of one lane sends no lane
  filter. A local board sorts by lane already.

- The card is in the `ls` format, followed by `N comments, M the owner's`
  (`1 comment` for one). On a Pomb board a `link: <url>/t/<card id>` line
  follows it.
- With no such card it prints `No ready cards.` (exit 0).
- Comments that cannot be read are exit 1.
- `--column backlog`, `icebox`, `review`, `verify` or `release` takes the top
  such card of that column instead, else `No cards in <column>.` (exit 0).
- `--column blocked` takes the top unclaimed card labelled `needs:lead`, or
  with `--for planner` `needs:planner`. It never takes one labelled
  `needs:human`.
- Like every `next`, it never takes a card that a card outside Done blocks, nor
  an epic with a child that is not Done.
- A blocker on another board counts only while it is outside Done, and a card
  on that board that cannot be read counts as open.
- The Ready column also sends Pomb's `ready=true` filter.
- Any other column is exit 2.
- `--max-size N` (1, 2 or 3, else exit 2), or `DEV_MAX_SIZE` when the flag is
  absent, skips a card bigger than N Pomodori. That keeps a small model from
  taking a bigger card.
- A card with no size passes. With neither set, nothing is skipped.

### boards

`dev board boards` prints the name of every board the token sees, one per
line.

- It reads `GET /api/boards`, which leaves out the boards outside a
  fine-grained token's set.
- On a local board it prints that board's own name.
- An extra word is exit 2.

### whoami

`dev board whoami` shows the credential dev board uses, from
`GET /api/v1/auth/whoami`.

- It prints one `key: value` line each for `name`, `kind`, `scope`, `role`,
  `label`, `issuer`, `expires` (UTC, `never` when the credential does not
  expire), `boards` (`all`, or the board names) and `permissions`.
- A token issued as no role shows `none` for `role`, `label` and `issuer`.
- `issuer` is the name of the lead token that issued it, as it was then.
- The token is never printed.
- A 401 reads as every other refusal does, with ``The role token file for
  DEV_AGENT expired. Mint it again with `dev board token mint`.`` for an
  expired role token.
- A local board holds no credential, so it is exit 1.
- An extra word is exit 2.
- The drift of a role token from its template is not listed, as Pomb's whoami
  does not return it.

### columns

`dev board columns [BOARD]` lists the columns of the board named BOARD, else of
this project's board.

- It prints one per line in board order, with ` (done)` after a column that
  finishes a card (`GET /api/boards/{id}`, `columns`).
- A board the token does not see is exit 1 and says no board has that name.
- A local board answers only for its own name and refuses any other with
  exit 1.
- A second word is exit 2.

### limits

`dev board limits [BOARD]` lists the limits of the board named BOARD, else of
this project's board, from a fresh `GET /api/boards/{id}`.

- It prints one line per column limit as `COLUMN: N UNIT`, where UNIT is
  `count` or `hours` from the column's `limit_unit`.
- It then prints one line per limit group as `COLUMN, COLUMN: N (C in flight)`,
  where C is the group's `count`. A group always counts cards.
- A board with no limit group is exit 1 and the last line says
  `no limit group`.
- A local board is exit 1.
- A second word is exit 2.

A card with the `trunk-blocker` label skips these limits. `take` and `move` do
not refuse it at a column or group limit, and `move` adds `force: true` to the
Pomb move request, which makes Pomb skip the limits too. A move of any other
card sends no `force`. Only a card whose change unblocks every landing carries
the label, and the owner's standing exemption decides which one that is.

`dev board limits --set N` sets the limit of the group that holds the In
Progress, Review and Verify columns on this project's board.

- N is a whole number of at least 1, else exit 2. A board name beside `--set`
  is exit 2.
- It reads the board, then sends `PATCH /api/boards/{id}/limit-groups/{group}`
  with the group's own `column_ids` and the new `limit`, as Pomb replaces both.
- Pomb needs `columns.edit` on the board. A lead token holds it and a worker
  token does not, so `--set` needs a lead name for `DEV_AGENT` and the
  `lead_token` setting of `[board.pomb]`. Any other name is refused as exit 1
  before a request goes out. A 403 still prints a sentence that names the lead
  token and is exit 1.
- A board with no group that holds the three columns is exit 1.
- A local board has no limit group and is exit 1 with a sentence.
- On success it prints `Set the limit of In Progress, Review and Verify to N.`
  with the board's own column names.

### add

`dev board add NAME [--board B] [--blocked-by CARD]... [--from CARD]
[--id-only] [--top | --before CARD | --after CARD] [--column C] [--lane L]
[--description TEXT] [--problem TEXT] [--change TEXT]... [--out-of-scope TEXT]
[--size S] [--label L]... [--checks CMD]... [--done-when TEXT]...` creates the
card.

- The card goes in Backlog by default.
- On a Pomb board `add` prints `link: <url>/t/<card id>` under the `added` line.
- `--lane L` puts the card in that swimlane, and without it Pomb picks the
  lane. A lane the board lacks is a usage error (exit 2) that names the lanes
  it has. `--before` and `--after` put the card in the lane of `CARD`, and a
  `--lane` that names another lane is a usage error.
- It prints `added <id prefix> <column>`.
- `--size` gives the card the colour of the size, as `size` does.
- Each `--label L` (repeatable, duplicates dropped) gives it a label.
- Unless the column is Icebox, the description is given the three card format
  v3 headings (`## Problem`, `## Change`, `## Out of scope`). The text comes
  from one of two sources:
  - `--description` text fills Problem.
  - Each section is filled from `--problem`, `--change` and `--out-of-scope`.
    These cannot go with `--description` (exit 2), and `dev.board.compose`
    builds the text.
- Each `--change TEXT` (repeatable) is one line of the Change section, in the
  order given.
- A repeated `--problem` or `--out-of-scope` is a usage error naming the flag
  (exit 2) to avoid dropping text silently.
- A text that already holds one of those headings or the v1 `## Done when` is
  kept as it is.
- An Icebox card gets the text as given and none otherwise.

Where the card goes:

- `--board B` files the card on the Pomb board named `B` from any repo, using
  this repo's column names.
- A board Pomb does not list is refused (exit 1) before anything is added.
- A local board refuses `--board`.

Placement:

- `--top` puts the new card first in its column. `--before CARD` and
  `--after CARD` put it directly above or below `CARD`. Without one, the card
  lands at the bottom.
- `add` moves the card to that position after it is created, with the call
  `order` makes.
- More than one of the three is a usage error (exit 2), and so is a `CARD` in
  another column than the new card's. The message names both columns. An
  unknown `CARD` is refused (exit 1). Both are checked before the card is
  created.
- If the move then fails, `add` exits 1 naming the card, which was added but
  not placed. The refusal is not queued for a later sync.

Links:

- Each `--blocked-by CARD` (repeatable) links the new card as `blocked_by` that
  card, looked up on the board the card is filed on (`BOARD:CARD` reaches
  another).
- An unknown blocker is refused before the card is added.
- `--from CARD` links the new card as `related` to the card it came from,
  looked up the same way.
- An unknown card is refused before anything is added.
- If a link then fails, `add` exits 1 naming the card and the other card. The
  refusal is not queued for a later sync.

`--id-only`:

- It prints the full card id alone on standard output in place of the `added`
  line, for a script to capture.
- Warnings still go to standard error, and a failed add prints nothing on
  standard output.
- An `add --id-only` that cannot reach Pomb is refused and never queued, as a
  queued add has no id to print.

Ready and the card format:

- `--column ready` without a `--size` of `1`, `2` or `3` is a usage error
  (exit 2), by the same rule as `move`.
- So is any other column but Icebox (Backlog by default) for a card with no
  size, a description that lacks a heading or text under Problem, or no
  `--done-when` outcome. The message reads
  `a card outside Icebox needs a size, card format v3 and Done when outcomes,
  and this one lacks ...` and is checked before the backend adds anything.
- A `--column ready` whose description lacks a heading or text under one is a
  usage error too.
- So is a `--column ready` that has neither 3 to 7 `--done-when` outcomes nor
  a `- [ ]` or `- [x]` item under a v1 `## Done when`. Both are checked after
  the scaffold, so a Ready card needs a full `--description`.

Outcomes:

- Each `--done-when TEXT` (repeatable, at most 7, a blank one is exit 2) is one
  Done when outcome.
- `add` creates the card first and then appends each item as a subtask
  (`POST /api/tasks/{id}/subtasks` with `name`, in order, a work-scope call).
  A local card keeps them in `outcomes` with `id`, `name` and `done`.
- A queued add replays with its items, as the queue holds the command as typed.
- Pomb has no card delete or subtask delete or reorder for an agent token, so
  nothing is rolled back and nothing is retried when an append fails after the
  card exists.
- In that case `add` exits 1 with
  `<id prefix> was added to <column> but outcome N of M was not: <reason>`.
  It names the card and never reads as unreachable, so it is not queued and a
  replay cannot add the card twice. The outcomes before N stay on the card.
- A Pomb `add --column ready` with outcomes creates the card in Backlog,
  appends the subtasks and then moves it to Ready, so the card is never in
  Ready without them.
- A failed move says
  `<id prefix> was added to Backlog with its outcomes but the move to Ready
  failed: <reason>`.

Checks:

- Each `--checks CMD` (repeatable) gives the card one row of the board's checks
  field `dev.checks`, a table whose `run` column holds the command.
- A blank command, or one that `dev board check` would refuse, is exit 2, as
  for `checks`.
- It sends `POST /api/tasks` with `fields`, and a local card keeps the rows in
  `checks`.
- A `--checks`, or a `--column ready`, on a Pomb board that has no checks field
  is a usage error saying
  ``The board has no checks field. Run `dev board init` to add it.``
- A `--column ready` with no `--checks` is a usage error too:
  `a card needs a checks row before it enters Ready; pass --checks CMD`. It is
  checked after the heading check and before the backend adds anything.
- An Icebox card is exempt.

### label

`dev board label CARD [+]L... [--remove L]...` adds and removes labels.

- It adds labels (`L` or `+L`) and removes them (`--remove L`, repeatable and
  declared in the row's flags, so no `--` is needed).
- It applies the adds first in order and then the removals.
- It prints `labelled <id prefix> <labels, comma-joined, or ->`.
- It reads the card's labels, applies the changes and sends the whole list
  (`PATCH /api/tasks/{id}` with `labels`, which replaces the list), with the
  claim's fence when this machine holds one.
- Adding a label the card has and removing one it lacks are no-ops that send
  nothing.
- A label is one word with no whitespace and no leading `-` (after a `+`, or as
  the `--remove` value), else exit 2. No label at all is exit 2.
- A word starting with `-` reaches the command only through `--` or a queue
  file written by an older dev, and still removes that label. A queued old-form
  command therefore replays.
- `needs:lead` and `needs:human` are ordinary labels, with one exception.
  Adding `needs:human` to a card outside Blocked and Icebox is refused with
  `Card <id prefix> is in <column>, and needs:human lives only in Blocked or
  Icebox. Move it there first.` (exit 1, on both backends and on a queued
  replay).
- Removing `needs:human` is allowed in any column, and dev does not check which
  of the two cases below applies.
- An agent removes it after the owner answers in that agent's own session. It
  records the answer with `dev board answer CARD --choice N --quote TEXT`. On
  Pomb, a partial answer keeps `needs:human` while another question stays open.
  On Pomb, the answer that settles the last open choice removes the label and
  moves the card to the chosen column.
- An agent also removes it after the owner moves the card out of Blocked or
  Icebox. The first agent that finds the card in another column runs `dev board
  label CARD --remove needs:human`. That agent then follows the new column's
  meaning.

### escalate

`dev board escalate CARD TEXT` hands a `needs:planner` card up to `needs:lead`.

- It prints `escalated <id prefix> to needs:lead`. The column stays.
- On Pomb it is one `POST /api/tasks/<id>/escalate` with `{tier, reason}`. TEXT
  holds the numbered menu of choices and is the reason.
- Pomb writes the blocked note and swaps the tier label in that one write. The
  call needs only `comments.write`, so the implementer, reviewer, verifier and
  release roles may use it.
- The claim's fence goes along when this machine holds one.
- A local board appends the blocked note and swaps the label in one update.
- A card without `needs:planner` is refused before anything is written
  (exit 1), and so is an empty TEXT (exit 2).
- A refusal from Pomb (a locked card, a stale fence, a missing permission) is
  exit 1 with Pomb's message, and nothing is written.
- It refuses `--question`, `--choice`, `--recommend` and `--why` (exit 2) and
  points to `dev board ask`, which only the owner's questions use.

### answer

`dev board answer CARD --choice N --quote TEXT` records the owner's answer,
typed in this session, on a `needs:human` card.

- On Pomb it answers through Pomb's answer API instead, as the `needs:human`
  section above says. The steps below are the local board's.
- It removes `needs:human` from the card's labels. The other labels and the
  column stay.
- It then posts one decision note, `Owner's answer, typed in this session:
  choice N, quote: TEXT`. Both writes carry the claim's fence when this machine
  holds one.
- It prints `answered <id prefix> with choice N`.
- The words after `--quote` are the quote.
- A card without `needs:human` is refused (exit 1). A missing flag, a
  `--choice` that is not a whole number from 1 and an empty quote are refused
  too (exit 2). All are refused before anything is written.
- Pomb refuses a comment on a labelled card, so the label goes first.
- A note that fails after the label is gone is exit 1. It prints the
  `dev board note CARD --kind decision` command with the full text, so the
  quote is not lost.
- `answer` is never queued, to keep a replay from posting the note twice.
- dev cannot tell a typed answer from a relayed one. The verb is for the agent
  whose own session the owner answered in.

### epic

`dev board epic CARD` turns a card into an epic.

- It sends `PATCH /api/tasks/{id}` with `{"kind": "epic"}` (`tasks.edit`) and
  prints `made <id prefix> an epic`.
- Pomb answers a live claim with a `409` `claim_held` and a card that is
  already an epic with a `400`. dev prints Pomb's words and exits 1.
- A local board stores `kind` on the card and refuses a card that is already an
  epic.
- Turning an epic back into a plain card is not supported.
- `add --epic` creates the card with `"kind": "epic"`, on a local board too.

### link

`dev board link CARD KIND OTHER` links a card to another.

- It prints `linked <id prefix> <kind> <other>`.
- `KIND` is `blocked_by`, `blocks`, `related` or `parent`, else exit 2.
- `parent` is held by the child and names the epic as `OTHER`, which must be an
  epic. dev refuses any other card before any request, with
  ``Card <id prefix> is not an epic. Make it one with `dev board epic <id
  prefix>`.``
- Epics nest to any depth and a card has one epic. Pomb answers a second epic
  or a cycle with a `400` (exit 1).
- A local board refuses the same itself (`the card already has an epic`,
  `the link would make a cycle of epics between A and B`). Linking the same
  epic twice changes nothing.
- `OTHER` is a card of this board (an id or a prefix of 8 hex characters or
  more) or `BOARD:PREFIX` for a card of another board of the same Pomb server.
- For `BOARD:PREFIX`, dev reads that board (`other_board`), resolves the prefix
  there and sends the other card's full id (`POST /api/tasks/{id}/links` with
  `kind` and `target_id`).
- An unknown board or card is exit 1.
- Pomb answers an existing link unchanged, so linking twice is safe.
- `link` is queued while Pomb is unreachable, like `label`. The prefix is
  resolved at replay time.
- Pomb refuses a card linked to itself or a cycle (`400`, exit 1).
- A `blocks` link is the same link as `blocked_by` on the other card.
- A local board stores the link in the `links` of the card that holds it
  (`blocked_by` for both blocking forms).
- A local board refuses a self link and a cycle itself, and links only its own
  cards (`BOARD:` is exit 1).
- A local board's `next` skips a card with a `blocked_by` target outside a Done
  column.

### links

`dev board links CARD` lists the card's links.

- It prints one aligned line each: the kind (`blocked_by`, `blocks`,
  `related`, `parent` or `child`, as the card sees it), the other card's
  8-character id prefix and its board name (`-` for this board).
- The order is the one the backend gives, else it prints `No links.`
- A Pomb board reads `GET /api/tasks/{id}/links`. That lists the links the card
  holds and a `blocks`, `related` or `child` entry for each link another card
  holds on it.
- A Pomb board names a link's board from `GET /api/boards`. An id Pomb no
  longer lists is shown as the id.
- A local board lists the card's own `links`, then three kinds of entry for the
  links other cards hold on it:
  - A `blocks` entry for each `blocked_by` link.
  - A `related` entry for each `related` link held the other way.
  - A `child` entry for each `parent` link.
- A missing or unknown card is exit 1.
- Removing a link is `unlink`, below.

### unlink

`dev board unlink CARD KIND OTHER` removes the link of that KIND from the card
to OTHER (a card of this board, or `BOARD:PREFIX`).

- It prints `unlinked` with the same three words `link` prints.
- KIND and OTHER must match a line `links CARD` lists, else exit 1 with that
  listing after the message.
- A `blocks` line is removed as the `blocked_by` the other card holds, and a
  `related` line from whichever card holds it.
- A Pomb board reads `GET /api/tasks/{id}/links` on the holder for the link's
  id and sends `DELETE /api/tasks/{id}/links/{link_id}`.
- A 403 `permission_denied` for `links.delete` that names no board exits 1 as
  `pomb kept the link`, and leaves the link in place.
- The change is not queued while Pomb is unreachable (exit 1,
  `board unavailable`).
- A local board removes the link from the card that holds it.

### attach

`dev board attach CARD FILE...` uploads each file to the card.

- It sends each file to `POST /api/tasks/{id}/attachments` as a multipart
  `file` part, after one `GET /api/tasks/{id}/attachments` that lists the names
  the card holds.
- A name already held prints `skipped <name>`. Any other prints
  `attached <id prefix> <name>`.
- Pomb's refusal for a file (size, type, `quota_exceeded`,
  `duplicate_attachment`) prints as Pomb words it after the file's name. The
  other files still upload, and the exit is 1.
- A 503 `busy` is retried twice after a 2 second nap.
- A local board refuses it.

### attachments

`dev board attachments CARD` lists the card's attachments.

- It prints `<id prefix>  <size>  <name>` for each, in the order Pomb lists
  them, else `No attachments.`
- Listing is its own verb, to keep `show` at one request.
- A local board refuses it.

### detach

`dev board detach CARD ID` removes one attachment.

- It finds the attachment whose id starts with ID in the card's list, sends
  `DELETE /api/tasks/{id}/attachments/{attachment_id}` and prints
  `detached <id prefix> <name>`.
- An id that matches none or several exits 1.
- A 403 `permission_denied` for `attachments.delete` is reported by the
  permission message.
- A local board refuses it.

### delete

`dev board delete CARD --reason TEXT` moves a card to Pomb's recycle bin for
the lead.

- It reads `lead_token` from `[board.pomb]`, not `token`.
- It adds a `decision` comment `the lead deletes this card, reason: TEXT`, so
  the reason stays on the card when it is restored.
- It then sends `DELETE /api/tasks/{id}` and prints
  `moved <id prefix> to the bin`.
- A `DEV_AGENT` that is not a lead name is refused with exit 1 before any token
  is read or any call is made.
- A lead name has a role segment (the second) of `lead`, as in
  `dotfiles/lead/CARD/1`, or holds no slash. `token mint` reads the same
  helper.
- A local board has no bin and exits 1.
- Pomb's refusals print as they come. A `permission_denied` 403 names the
  permission and board, and `card_locked` says the card is locked.
- A locked card refuses the comment first and keeps nothing. A delete Pomb
  refuses after the comment leaves the comment on the card.
- The change is not queued while Pomb is unreachable.
- Emptying the bin and deleting from it stay with the owner.

### stale

`dev board stale [--days N] [--icebox-days N] [--lead-hours N]` lists the cards
that have sat too long.

The first list:

- It covers Backlog, Ready, In Progress, Review and Verify, for N days or more
  (7 by default), oldest first.
- Each line holds the id prefix, column, `<days>d`, size and name, aligned.
- Days are whole days from the card's `column_entered_at` (Pomb's task view,
  RFC 3339, read with `dev.cmd.box.parse_time`) to now, so 6 days is fresh and
  7 is stale.
- Icebox, Blocked and Done are never stale.
- It prints `No stale cards.` when the first list is empty.

The sections after it, each after a blank line and its heading, with the same
columns as the first list unless noted:

- `for the owner (needs:human):` lists every card carrying `needs:human` in
  Blocked or Icebox, at any age, and never among the stale ones. The name ends
  `(answered, waiting for your move)` when the newest comment is the owner's.
- `for a lead (needs:lead):` lists every card labelled `needs:lead` (and not
  `needs:human`) that has sat in Blocked for `--lead-hours` hours or more (1 by
  default), with its time as `<hours>h`. It leaves out an unclaimed run card,
  an epic with an open child or a card an open card blocks, as
  `next --column blocked` does.
- `for a planner (needs:planner):` lists a card labelled `needs:planner` in
  Blocked for as long, the same way.
- `asks nobody, add a needs label:` lists every Blocked card with none of
  `needs:human`, `needs:lead` and `needs:planner`, at any age, with the same
  columns as the first list.
- `moved by the owner, remove needs:human:` lists every `needs:human` card in
  any other column, Done included, with no answer note.
- `newest comment is the owner's:` lists every other card but Done and not
  listed above whose newest comment is the owner's, whatever its label and age.
- `unsized outside Icebox:` lists every card outside Icebox that is white or
  has no colour, at any age, one line each with id prefix, column and name, in
  board order. Sizing happens in planning, so a card that waits unsized is a
  planner's to size.
- `todo files, move their items onto cards:` lists `TODO.md` and `docs/TODO.md`
  one per line, each when it is a file under `backend.root` (read with
  `dev.fs.is_file`). It is absent when neither exists or the backend has no
  root, and dev reads no item in the file.
- `icebox, untouched for N days:` comes last. It lists, oldest first, every
  Icebox card without `needs:human` whose column time and latest comment
  (`backend:comments`) are both `--icebox-days` days old or more (30 by
  default).
  - The days count from the later of the two times.
  - A card with no comment counts by its column time.
  - The section is absent when no card qualifies.

Cards it cannot date:

- A card in those columns or with that label that the tasks view did not date
  (missing from the pages, or no `column_entered_at`) gets one line
  `could not date <id> <name>` after a blank line.
- An Icebox card the tasks view did not date, or whose comments could not be
  read, gets a `could not date` or `could not read the comments of` line after
  the Icebox section.

Exit codes:

- It exits 0 unless the board cannot be read (1).
- A `--days` or `--icebox-days` that is not a whole number of 1 or more is
  exit 2.

### lint

`dev board lint [CARD] [--strict]` reads every card (`backend:cards`) and prints
one line per broken rule. With `CARD`, it resolves the prefix with
`board.resolve` and lints only that card.

- Each line holds the id prefix, column and rule, aligned, in board order.
- A finding on a `needs:human` card ends in `(owner)`, unless it is
  `lacks a size`, `needs:human outside ...` or `agent question ...`, which
  `dev.board.lint.card`
  reports as agent findings (its third return value holds the indexes of the
  owner's).
- It exits 1 only when a finding without the mark is left.
- A clean board prints `No findings.` and exits 0.
- A flag other than `--strict`, or a second card, is exit 2. A `CARD` that
  matches no card or several is exit 1.
- `--strict` is also on when `board.lint.strict` is `true` in the config
  (`config.get`, project over user file). A non-boolean value is exit 1.
- A read that fails is exit 1 with the message.
- It writes nothing itself, but the dispatcher replays the queue first, as for
  every Pomb command.

The rules live in `dev.board.lint`, which calls `dev.board.unplanned` for the
size, the v3 sections and the outcomes. It adds these:

- Outside Icebox and Done: `over 400 words (N)`.
- In Ready, In Progress and In Review, for a card with no children:
  `no checks row`.
- In Ready and In Progress, for a card with a checks row that is not an epic:
  `outcome names no deciding check: NAME`, once per outcome that ends with
  neither `(check: ROW)` naming part of a checks row nor `(reviewer
  judgement)`, as `dev.board.unnamed_checks` lists them.
- In Ready: `red card in Ready`.
- Anywhere: `needs:human outside Blocked and Icebox`.
- On a `needs:human` card that is unsized or outside Blocked, with an open
  question from an agent (a comment whose `actor` is `agent` and whose question
  has no answer): `agent question on an unsized card` and `agent question
  outside Blocked`. It reads `backend:comments` for such a card. Both are agent
  findings, and an owner's idea with no question stays free-form.
- In Blocked: `blocked with no question or blocked note and no blocker`. It
  reads `backend:comments` for a `question` or `blocked` kind and then
  `backend:links` for `blocked_by`.
- In In Progress: `in progress with no claimant`, unless the card carries the
  run label.
- In Done: `N of M outcomes unticked` unless discarded, and `N of M children
  open` when the card has an open child.
- In Done, unless discarded: `built and reviewed by the same name: NAMES`. It
  reads `backend:comments` once, takes the names `board.claimants` finds in the
  claim records, and lists each one that `dev.board.review.parse` also finds as
  `by` in a review record, sorted.

How it reads outcomes:

- A Done card passes `sections = false` unless strict.
- A `discarded` card passes no outcome check, which is what `discard`'s guard
  does.
- Every card asked for outcomes reads `backend:family` for its child count,
  which sets the 1 to 3 an epic needs, or none once every child is Done.
- A card with `outcomes_unreadable` gets `outcomes unreadable` and no outcome
  rule.

### notes

`dev board notes CARD` lists the card's comments (`GET
/api/tasks/{id}/comments`), oldest first.

- Each line holds, aligned, the comment id prefix (8 characters), the token's
  name (else the actor kind), the comment's kind (`-` for none), its role label
  (`-` for none, and Pomb's default `api-token` counts as none), the time to
  the minute in UTC and the first line of the body.
- It prints `no comments` when there are none.

### show

`dev board show CARD [--board B]` prints a whole card, so an agent reads it
without the API or the token.

The layout, top to bottom:

- The card as `ls` does (id prefix, column, lane on a board with several lanes,
  size, labels, name).
- On a Pomb board, `link: <url>/t/<card id>` under that line, the link that
  opens the card. A local board has no host and prints none.
- On a child, `parent: <id prefix> <name>` under the `ls` line. On an epic,
  `kind: epic, N open` above it and `children: N of M done`.
- A blank line and the description (`no description` when empty), from the same
  `/export-data` read `ls` makes.
- `done when:` and one `- [x] <outcome>` or `- [ ] <outcome>` line per outcome
  (Pomb's `subtasks` in the `/export-data` task row), then a blank line, when
  the card has any.
- `checks:` and one `- <command>` line per checks row, then a blank line, when
  the card has any.
- The same for `allow:`, `tests:` and `files:` with one `- <word or name>` line
  each (the `dev.allow`, `dev.tests` and `dev.files` fields).
- A blank line and the comments as `notes` lists them, from
  `GET /api/tasks/{id}/comments`, with every line of each body in full and the
  later lines indented under the first.
  Under an open question it lists each choice as `N. LABEL (COLUMN)` and ends
  the recommended one with `[recommended]`. An answered question lists none, and
  a local board holds no questions to list.

Its facts:

- A card with outcomes prints a v1 `## Done when` checklist in its description
  only through the `done when:` lines, never twice. A card with none prints no
  `done when:` block and keeps its description as it is.
- Links are listed by `links`.
- The parent and children lines come from `GET /api/tasks/{id}` (`parent`,
  `children_done`, `children_total`) on Pomb and from the `parent` links of the
  cards on a local board (done meaning in a done column).
- `--board B` prints the card on the Pomb board named `B` from any repo, looked
  up as `add --board` looks it up. A local board refuses it (exit 1).

### edit

`dev board edit CARD [--board B] [--file PATH]` replaces the card's
description and prints `edited <id prefix>`.

- The text comes from `--file PATH`, else from standard input (a terminal with
  no `--file` is exit 2), with trailing whitespace removed.
- It sends `PATCH /api/tasks/{id}` with `description`, the same field `add`
  sends, with the claim's fence when this machine holds one.
- A local board sets the card's `description` under the same fence rule.
- Empty text, an unreadable file, a missing card argument or an extra word is
  exit 2. An unknown card is exit 1.
- A card labelled `needs:human` is refused (exit 1).
- `--board B` replaces the description of the card on the Pomb board named `B`
  from any repo, looked up as `add --board` looks it up. A local board
  refuses it (exit 1), and a missing name is exit 2.
- Titles and comments are not editable here.

While Pomb is unreachable:

- `edit` is queued like `size` and `label`, timeouts and 502, 503 and 504
  included, as sending a whole new description twice changes nothing more.
- The input is read before the board is asked, so a queued `edit` holds the
  card and the new text as typed (`dev.cmd.board` `description_args`) and
  replays without the file or the pipe.

### rename

`dev board rename CARD TEXT` sets the card's title to TEXT and prints
`renamed <id prefix>`.

- It sends `PATCH /api/tasks/{id}` with `name`, with the claim's fence when
  this machine holds one. A local board sets the card's `name`.
- The words after the card are the title. It must not be blank, must be at most
  100 characters with no quote, backslash or control character, and may not
  hold a word starting with `-` (each exit 2).
- A card word that matches no card, or more than one, is exit 2 with the
  reason. A board that cannot be read is exit 1.
- A card labelled `needs:human` is refused like `edit`.
- A title change is queued while Pomb is unreachable, like `edit`.

### checks

`dev board checks CARD CMD...` replaces the card's checks rows with one row per
command and prints `set checks <id prefix>, N rows`, or `1 row` for one.

- It sends `PATCH /api/tasks/{id}` with
  `{"fields":{"dev.checks":[{"run":CMD},...]}}`, with the claim's fence
  when this machine holds one. Pomb merges by key, so the sent rows replace the
  field's whole value.
- A local board sets the card's `checks` under the same fence rule.
- A name in the card's claim history is refused with exit 1 and nothing
  written.
- A row that `dev board check` would refuse is exit 2 with the row named, as in
  `add --checks`.
- No command, a blank command, a missing card or an unknown option word is exit
  2, so nobody clears the rows by accident and no subcommand clears them.
- An unknown card is exit 1.
- A Pomb board with no checks field is refused before any write (exit 1) with
  ``The board has no checks field. Run `dev board init` to add it.``, as a move
  into Ready gives.
- Sending the same rows twice changes nothing more, so `checks` is queued while
  Pomb is unreachable like `edit`, timeouts and 502, 503 and 504 included.
- The `on` runner names are not set.

### check

`dev board check CARD [--expect-fail] [--timeout SECONDS]` runs every checks
row of the card and records the result as one comment on the card.

The workspace rule:

- In a jj project `check`, `turn` (not `--release`) and `land` first refuse,
  and do nothing else, unless the working copy's workspace is named for the
  card's id prefix, the name `dev ws new CARD` gives.
- The refusal names the workspace it found.
- A git project is not checked, and no flag or environment variable turns the
  rule off.

How a row runs:

- A row runs as a plain command, split on whitespace and started without a
  shell.
- A row is refused before anything runs (exit 1) when it holds any of
  `| & ; < > ( ) $`, a backtick, a backslash, a quote, `*`, `?`, `!` or a line
  break, or starts with a dotted run such as `dev.--remote.lint`, or passes a
  word to `dev --remote test` or `dev --remote lint` before the double dash.
- One `!` is allowed, as the first word. A row `! rg -n PATTERN FILE` runs the
  rest as the command and passes only when it exits 1 (a search that found
  nothing). Exit 0 fails the row as a match found, and any other exit fails it
  as an error, so rg's exit 2 never passes.
- Under a set `DEV_AGENT`, dev refuses a local run of a verb that has a ci job,
  so a row reads `dev --remote lint` (not `dev lint`).
- Each row may run for `--timeout` seconds (7200 by default, at most 86400,
  anything else is exit 2), counted from the row's start to its end. The wait
  in the ci queue and a job that ci restarts count too.
- The default covers a remote test of about five minutes that waits behind a
  long queue.
- A row that outlasts it is killed and recorded as `timeout`, as is a row that
  exits 124 or is killed from outside.
- When a timed-out row printed a ci run id, dev reads the run's state with
  `ci ps RUN --json`. The record puts one reason line under the row, for
  example `the ci run was running at the limit and may still finish`, or says
  the state could not be read. The run keeps going, so read it before a rerun.
- A card with no rows is exit 1.

The result belongs to one commit:

- In a jj project the working copy is itself a commit, so a changed file is
  normal. The commit is `@` after jj snapshots the files, recorded with its
  change id.
- In a git project the tree must match `HEAD`, and a dirty one is refused
  (exit 1) with the count of changed paths.
- A conflicted jj working copy is refused too.
- dev names the commit before the first row and again after the last. A result
  whose two commits differ was run on a tree that moved, so it is not recorded
  (exit 1).

The comment has the kind `status` and begins with a reserved first line, then
one line per row: its place, its result, the ci run id it printed and its
command.

- The run id is the one from the `run <id>` line of `ci run --follow`, so
  `ci logs <id>` reads the row's log. It is `-` when the row printed none.
- dev prints `row N run <id>` to standard error the moment the row's `run <id>`
  line is complete, before the row finishes, so a runner told to stop its own
  runs finds the ids in its log. It prints one line per row, for the first
  `run` line the row prints. `land`'s recheck and `ship` print none.
- A row that failed with no run id adds a second line under it, indented by
  two spaces, with the last line the row printed. A row that printed a run id,
  a negated row and a row that timed out add none.
- A run the ci hub refused while it drains is not a failed row. The hub's
  refusal is a line that says it `is draining`, that `nothing new starts` and
  that names the `ci fleet drain off` command, for the whole hub or for one
  target. When a row that printed no run id exits nonzero with that line, a
  negated row included, dev stops at that row, records no comment, prints
  `The ci hub refused row N (ROW). Nothing was recorded on card CARD. The hub said: `
  and the refusal line, and exits 1. A negated row the hub refused is a fail
  wherever a row runs. Rows that already ran are not recorded either, and
  dev does not wait or retry.
- A row that printed no run id and exits 12 is refused the same way. Exit 12
  is the `draining` code, which a drain wait ends with after 1 hour. The
  refusal line is the one holding `The drain did not lift within`, else the
  last line the row printed. A row that printed a run id and exits 12 is a
  failed row.

```
dev-check: commit=<full commit id> change=<change id, - in git> mode=run rows=2 sum=<hash>
1 pass 8cb600
2 fail -
  error: Failed to run the pipeline
```

A row's line holds its index, result and ci run id and no command text, so
the record stays under Pomb's 5000-byte comment cap up to about 300 rows.
`sum` is a hash of the card's checks rows in order, and land refuses a record
whose `sum` differs from the card's rows with ``The checks rows changed since
the newest check run at commit <12 characters>. Run `dev board check` again.``
A reason line is cut to 120 bytes and dropped once the comment nears 4800 bytes.
A record from before this form has no `rows` or `sum`, reads as unreadable and
is refused the same way.

The result and the exit code:

- A row ends as `pass`, `fail` (any non-zero exit) or `timeout`. Under
  `--expect-fail` a row that never started ends as `error` instead: one that
  exits 126 or 127 with no run id, or a `ci` or `dev --remote` row that exits
  non-zero without printing a `run <id>` line.
- The command prints the same lines (the last 12 lines of a row that did not
  pass follow it, indented) and `recorded on <id prefix> at commit <12
  characters>: N of M rows passed`.
- It exits 0 when every row passed and 1 otherwise.
- `--expect-fail` is for filing a card. It records `mode=expect-fail`, exits 0
  when every row failed, and reports a row that passed as one that proves
  nothing (exit 1, still recorded). A row that ends as `error` fails the run
  the same way (its failure shows nothing about the code). A row that
  exits 1 or any other code after it started is still the expected failure.

When the comment cannot be written:

- If Pomb is unreachable, a timeout occurs or a fence is refused, the command
  exits 1 with ``The result was NOT recorded on card ID. REASON. The board may
  or may not hold it. Read `dev board notes` before trusting or repeating it.``
  and the row lines. It never prints
  `recorded` then, and it is never queued, as a replay would rerun the rows.
- A timeout or gateway error may come after Pomb stored the comment, so read
  `notes` before repeating a long run.
- `note` refuses any text that begins with `dev-check:` (any case, after
  leading space). `note --edit` and `--delete` refuse a comment that holds or
  would hold it (exit 1).

### review

`dev board review CARD --kind code|style|recheck --by NAME --rev REV --verdict
clean|minor|needs-work` records that NAME reviewed the commit REV with that
verdict.

The record is one `status` comment on the card that begins with a reserved
first line and has no other:

```
dev-review: kind=code by=<NAME> commit=<full commit id> change=<change id, - in git> verdict=<clean|minor|needs-work>
```

The flags:

- All four are required. A missing one, an unknown kind or an unknown verdict
  is exit 2, and the message lists the kinds or the verdicts.
- A record written before verdicts has no `verdict=` and is read as it was.
- REV is a jj revset in a jj project and a git revision in a git one. It must
  name exactly one commit, so a revset of many commits, a word that starts with
  `-` and a name that resolves to nothing are refused (exit 1).
- NAME is an agent name as `take --as` takes.

Who may record:

- The card's claimant is refused for every kind (exit 1), whether NAME is the
  claimant or the caller is. The caller is its `DEV_AGENT` or, with that unset,
  the default name a claim without a name is held under (a `dev@host:session`
  name that `take` gives). This keeps a claimant from reviewing its own change
  under either name.
- So is every name that took the card before, read from its `dev-claim:` notes,
  so a claim that lapsed does not free its holder to review.
- The message names the claimant and says a reviewer other than it must record
  the review.
- An unclaimed card takes any NAME.
- The reviewer records its own review with its final verdict: `clean` for
  CLEAN, `minor` for MINOR ISSUES and `needs-work` for NEEDS WORK. It is the
  recorder the board allowance for `review` covers.
- After a needs-work record the reviewer notes the findings and leaves the card
  where it is.

The result:

- It prints `recorded KIND review by NAME on <id prefix> at commit <12
  characters>`.
- Like `check`, it is never queued. If the comment cannot be written the
  command exits 1 with ``The review was NOT recorded on card <id prefix>.
  REASON. The board may or may not hold it. Read `dev board notes` before
  repeating it.``
- A timeout or gateway error may come after Pomb stored it, so read `notes`
  before repeating.
- `note` refuses `dev-review:` and `dev-turn:` as it does `dev-check:`, and
  `note --edit` and `--delete` refuse a comment that holds it.
- `review` does not judge the verdict. `land` does.

### land

`dev board land CARD [--wait SECONDS]` takes the landing turn and lands the
card's change on trunk.

In order, it:

- takes the landing turn and rebases the working-copy change onto trunk
- lands the change with `jj land --yes -r @`, run in the project root, or in a
  git project pushes the HEAD commit to the trunk branch of the remote of
  record through the guarded push `dev push` uses
- writes a `done` note
- moves the card to Release when `[board.land] deploys` is true and to Done
  otherwise
- ends any claim still on the card, and a landed card carries no owner
- gives the turn back and cleans up

dev board land merges a card once Verify passes.
A card's change stays unmerged until land merges it.
`jj land --no-card` is a second merge path, and a forge merge bypasses both.

After the move, dev board land removes the card's workspace and bookmark.
A workspace or bookmark it cannot remove is kept, and the output says why.

The command:

- It refuses outside the card's workspace, as `check` does.
- It needs `DEV_AGENT` (usage error, exit 2, without it).
- It works in a jj project and in a git project, a checkout or a linked
  worktree. In git it fetches the remote of record, rebases the branch onto the
  remote trunk when the trunk moved, refuses a change that sits on an unlanded
  parent, and pushes the commit to the trunk branch as a fast-forward. A failed
  fetch, rebase or push leaves the card where it is and names the step. A
  conflicted rebase is aborted and leaves the branch as it was.
- `--wait` is a whole number of seconds up to 86400 and is off by default, so a
  land that finds the turn held refuses at once and names the holder. With it,
  the land waits up to that many seconds for the turn. Anything else exits 2.
- It is never queued.

The conditions:

`land` lands nothing and exits 1 until every condition holds, and the message
lists each one that fails. A refusal can leave the change rebased onto trunk.

- The card is in the verify column and no other agent claims it. `move`
  releases the claim, so `land` refuses a card claimed by another agent and
  lets any agent with `DEV_AGENT` set land an unclaimed one.
- Every outcome is ticked (the same count `move CARD done` refuses on). The
  verifier ticks after the checks pass and before `land`.
- The working-copy commit is non-empty, has a description and has no conflicts.
- The commit adds no file under `.dev/standalone/` unless the card carries the
  `standalone-ok` label.
- The commit does not change both a lint-set template file and a dev module
  that the template requires. The refusal says to land the dev change first,
  have infra rebake the ci images, then land the template change.
- A `code` and a `style` review of the working-copy change are recorded. A
  review of an earlier commit of the change counts when `jj interdiff` between
  that commit and the landing one is empty, so a clean rebase keeps its reviews
  and only the check reruns. Any other earlier commit counts only with a
  `recheck` recorded at the landing commit.
- No `code`, `style` or `recheck` review at the landing commit (or at an
  earlier commit of the change with the same empty interdiff) has `needs-work`
  as its latest verdict. The refusal names the kind and the reviewer, and a
  later `clean` or `minor` review of that kind at the commit lifts it. A record
  with no verdict never refuses.
- The newest `dev-check:` record with `mode=run` at the landing commit has a
  `pass` for every checks row, in the card's row order. A `mode=expect-fail`
  record never counts, even when it does not parse.
- The commit's parent is the current trunk, compared after
  `jj git fetch --remote <remote of record>`, with the remote taken from the
  forge settings (see `forge`). A failed fetch refuses. The git reads
  behind this are `git fetch <remote of record>` and the remote's `master` or
  `main` branch as trunk. Plain git does not reach them until the git land
  lands.
  Each fetch stops after 120 seconds, or after `DEV_LAND_FETCH_SECONDS`
  when that is set, and one fetch that fails with `agent refused operation`
  is retried once. A second refusal or a timeout refuses with a message that
  tells the person to touch the hardware key and run `dev board land` again.

`land` rebases the change onto trunk itself while it holds the turn, so the
last condition holds unless the rebase failed. The conditions on the reviews and
the check are then judged at the rebased commit. A change that sits on an
unlanded parent is refused and not rebased. In a jj project an unlanded parent
that is empty, has no description and is not a merge (the commit `dev ws new`
leaves under a change built with `jj new`) does not count. `land` abandons
it, then rebases the change onto trunk. A parent with a description or
a patch is still refused, and a git project still refuses every unlanded
parent.

When the newest `dev-check:` record at the commit does not parse and its mode is
not `expect-fail` (as with one written before rows carried run ids), `land`
refuses it as unreadable and says to run `dev board check` again, not that no
record exists.

The landing turn:

- It keeps one landing at a time across runners, so trunk does not move under a
  landing.
- It is the owner of a card named `landing turn`, which `init` creates in the
  Icebox, and `land` creates it there when an old board has none. That keeps the
  holder on the board and not in one session.
- Both create it only when no open card of that name exists. A local board
  checks that under its file lock, so two runners cannot both add one. Pomb has
  no atomic create, so `init` narrows the window there to first-time setup,
  and two first inits started together can still make two. A process that
  starts after a race left two takes the lowest id.
- `next`, in any column, and the Icebox list of `stale` never list that card,
  so no agent is offered it. Its notes stay bounded by the rotation below.
- On a Pomb board the turn grabs that owner with `POST /api/tasks/{id}/owner`
  and the turn's lease as `ttl_seconds`, renews it through `/owner/renew` with
  `If-Owner-Fence`, and gives it back through `/owner/release`.
- The holder is the card's live owner, so a lapsed owner lease leaves the turn
  free. A local board keeps the same owner as a claim in its file.
- A local board keeps the lease for its length and ignores the card-size lease
  that `take` uses.
- The holder writes a `dev-turn:` note on the turn card with its name, the card
  it lands and the time it took the turn.
- The lease is 900 seconds, and `land` renews it before the `jj land`. When
  the landing commit carries a check across trunk commits, `land` first
  stretches it to 3000 seconds for the recheck, which can queue in ci for
  longer than 900 seconds, and the renewal before the `jj land` puts it back to
  900 seconds.
- When a holder dies, the lease ends and the next asker takes the turn. A holder
  that comes back after that gets `The landing turn was lost.` or
  `The landing turn ran out and was lost. Ask for it again.`, writes nothing,
  lands nothing and has to ask again.
- A holder whose newest hold note names an older fence than its live claim
  still owns the claim. `land` finds it with the claim's own fence and lands
  under it, and refuses only when the claim is gone or belongs to another name.
- `land` gives the turn back on every exit, a refusal included. A hold from
  `turn` stays through a refusal.
- A raw `jj land` takes no turn, so the turn keeps only the landings made
  through `dev board land` to one at a time.

Asking for the turn:

- A card in the wrong column, with an open outcome or claimed by another agent
  is refused before the turn is asked for.
- `land` then asks for the turn for up to `--wait` seconds, none by default, and
  when it stays taken, refuses with `The landing turn is held by NAME since STAMP.`
- Cards wait in the order they asked. A card with a wait writes a
  `dev-turn: ask` note with the time its wait ends, plus 10 seconds, before it
  asks for the turn. Only the first live ask in line may take it, except a
  caller that already owns the claim for that card, whose newest holder note is
  for it. That caller renews the claim under its live fence, whatever the line.
- A caller that owns the claim and has kept it for `MAX_HOLD_SECONDS` is
  refused, and `take` gives that claim back under its fence and writes the
  `left` note, as `turn` does, so the next card in line does not wait on it.
- A later asker is told whom the turn is next for.
- An ask ends when its card takes the turn, writes a `dev-turn: left` note when
  its wait runs out, or passes its end time. The end time keeps a waiter that
  died from holding the line.
- Only the claim's fence releases the turn, and a waiter that gives up releases
  nothing.

Rotating the turn card:

- The landing turn card rotates once it holds 500 notes (`MAX_NOTES`), before
  Pomb refuses a note at 1048576 bytes in a task and every turn answers
  `limit reached`.
- `ask` and `take` check the count, and only on a card with no owner. A held
  card keeps its notes until the hold ends, at most `MAX_HOLD_SECONDS`.
- Rotation moves the card to Done, adds a fresh landing turn card and posts the
  live asks onto it again in their order, with their end times. An ask that ran
  out or was answered is not carried.
- A move to Done adds a history event, so Pomb refuses it with `limit reached`
  on a card already past the byte limit. Rotation never bins the card, to leave
  the loss of a card that Pomb purges after 30 days to the owner.
  `take` and `ask` answer `The landing turn card ID is full and Pomb refuses to
  move it. Rename it to have dev make a fresh one.` and the card stays. Once the
  owner renames it, the next call makes a fresh card.
- Rotation re-reads the card first and leaves it when another agent has taken
  it meanwhile.
- Any other move failure answers `The full landing turn card could not be
  retired.` and the card stays.
- `land` asks once before it polls, and every poll runs `take`, so a card that
  fills while a waiter waits rotates on the next poll.

Polling while it waits:

- A poll sleeps 5 seconds at first, then 1.5 times longer after each poll that
  sees the same place in line and holder, up to 30 seconds.
- A change in either starts over at 5 seconds.
- Each sleep is shortened by up to 20% at random.
- Each poll reads the waiting card, lists the cards to find the lowest-id turn
  card, then reads that card's comments. A poll that reaches the claim and
  loses it lists the cards again, and a `land` poll lists them once more, to
  find a hold of its own.
- A waiter whose card has moved to Done writes its `left` note and stops with
  `Card <id prefix> is done. There is nothing to wait for.`

Carrying a check and reviews across a rebase:

`land` carries them when the landing commit lacks the reviews and has no
`dev-check:` record of its own. A record that does not parse is its own, and
`land` refuses one not marked `expect-fail` as unreadable.

- It looks for the commits of the same change id with a passing run and their
  code and style reviews (a recheck counts as above).
- It tries them newest first and carries the records of the first one for which
  all of these hold:
  - the commit's parent is the current trunk
  - the checked commit sat on one ancestor of that trunk, where an empty
    undescribed parent that is not a merge is skipped to the commit below it
    (jj only)
  - `jj interdiff` between the checked commit and the landing one is empty (in
    a git project, a `git merge-tree` of the two patches that gives the landing
    commit's tree)
  - the rebase left no conflict
- A trunk commit that touched the same files does not stop the carry. The
  release run tests the whole batch and catches a clash the rebase cannot see.
- The carry is tried whenever reviews are lacking, even when another refusal
  stands (an unticked outcome, the wrong column), to list in the refusal only
  what still blocks the landing.
- A different change id, a non-empty interdiff or a review never recorded at the
  checked commit keeps the plain refusals, and any jj read that fails refuses
  too.
- When no commit carries, the refusal gives the reason for the newest one,
  unless a jj read fails first, which refuses at once and names that read.
- The done note then adds that the check and reviews were carried over from the
  checked commit.

The settings:

- `deploys = true` under `[board.land]` makes `land` move the card to Release,
  where it waits until it is live. Without it `land` moves the card to Done.
  This repo sets it.
- The done note then ends with `It waits in Release for the deploy.`
- The lead runs `dev board ship` from a workspace at trunk, and rolls the
  checkout only onto the revision that ship passed.
- `checks` under `[board.release]` lists the commands `dev board ship` runs once
  when it gets none after `--`, one plain command per row.
- `recheck` under `[board.land]` lists the commands `land` reruns itself, one
  plain command per row. When the carried check's commit does not sit directly
  on the trunk `land` rebased onto, `land` runs each row on the landing commit
  under the landing turn, in order. A row that fails refuses the land with the
  row, its run id and the end of its output, and nothing is pushed. A check on
  the current trunk or an empty list lands as before. `land` reads the rows
  from the project config as trunk holds it, then from the user config, so the
  landing change cannot edit the rows that guard it. A trunk or a file `land`
  cannot read refuses the land. This repo sets it to `dev --remote lint` and
  `dev --remote test`.
- In a repo whose `.dev/config.toml` has a `[board]` section, a bare `jj land`
  exits 1 and names `dev board land`.
- `dev board land` sets `DEV_BOARD_LAND=1` for the `jj land` it runs, and
  `jj land --no-card` lands a change that has no card.
- `jj land --undo` and `jj land --dry-run` pass the guard. Neither one lands a
  change, and neither needs a card.

The result:

- A failed `jj land` leaves the card where it is, exits 1 and prints jj's
  output. A failed git push does the same and prints git's output.
- A landing whose done note or move then fails exits 1 and says what to finish
  by hand.
- `jj land` can rewrite the commit through the forge, so after it succeeds
  `land` fetches the remote of record and reads the commit that holds the change
  on trunk by its change id. The `dev-check:` and `dev-review:` records keep the
  commit from before the land.
- The done note reads
  `Landed commit <12 characters> (change <id>) on trunk, run by NAME.` (in git
  `Landed commit <12 characters> on trunk, run by NAME.`) and
  success prints
  `landed <id prefix> at commit <12 characters> and moved it to Done`
  (or Release). Both name the commit on trunk.
- If the fetch or the read fails after the land (which does not undo it), the
  note reads `Landed change <id>, run by NAME. Trunk could not be read after
  the land, so <12 characters> is the commit from before it and may differ from
  the one on trunk.`
- The success line says the same, and the card still moves.

Cleanup:

After the move, `land` deletes the bookmark named for the card, then runs the
removal behind `dev ws rm` on the card's workspace, which is the one it runs in.
That removal moves the folder to the trash under the workspaces root, so a
landed card's workspace stays recoverable for at least 14 days.
Cleanup never changes the exit code or the card's column.

- A shell left inside the workspace stays in the moved folder under the trash,
  and the output says to run the next command from another folder.
- A workspace outside the central root, or one with changes not in a commit,
  stays. The output names it and why.

Following trunk:

- On a board where `[board.land]` has no `deploys = true`, a successful `land`
  then runs `dev follow`, which moves the repo's main checkout onto the new
  trunk, and adds its one line to the output.
- On a board that deploys, `land` does not run it. `ship` does.
- A project `.dev/follow.sh` or `.dev/follow.lua` replaces the built-in for
  `land` and `ship` alike. `dev help follow` and `docs/dev/flags.md`
  describe the verb.
- It never changes the exit code or the card's column.

### turn

`dev board turn CARD [--hold SECONDS] [--wait SECONDS] [--release]` takes the
landing turn for CARD early and keeps it, so `land` lands under it and no other
landing moves trunk meanwhile.

The turn is short and holding it is optional. A landing takes it only around
the rebase and the push, so a runner holds none across the reviews or a check,
and two cards whose checks ran in parallel land one after the other.

The command:

- It refuses outside the card's workspace, as `check` does, but `--release`
  works from anywhere.
- It needs `DEV_AGENT` (exit 2 without it).
- It takes the turn as `land` does, but fails fast. It asks once unless
  `--wait` gives seconds to keep asking (a whole number up to 86400), and when
  the turn stays taken it refuses with
  `The landing turn is held by NAME since STAMP.`
- A card in Done is refused, except to give a hold back.

The hold:

- A hold is longer than a landing's 900 second lease. `--hold` sets its lease,
  1800 seconds by default and 3600 at most (a whole number, exit 2 otherwise),
  so a long wait fits.
- `check` does not renew the lease while it runs.
- The hold is recorded in the `dev-turn:` note with the fence and the lease, so
  a later command finds it from the board alone, on any machine under the same
  `DEV_AGENT`.
- A hold is the live one only when its note names the fence of the card's
  current claim. A record left by a lapsed hold counts as lost, even when the
  same name later took the turn for another card.
- Success prints ``Holding the landing turn for <id prefix> for N seconds.
  Rebase, then run `dev board land <id prefix>`, which lands under it. Run `dev
  board turn <id prefix>` again to renew it, or add `--release` to give it
  back.``
- A hold that lapsed frees the turn to the next asker, so taking it again starts
  a new window.

Renewing:

- Running `turn CARD` again as the holder renews the lease for `--hold` more
  seconds and prints
  `Renewed the landing turn held for <id prefix> for N more seconds.`
- When the renewal succeeds and the note of the new lease fails, `turn` refuses
  with `The hold was renewed but its lease could not be noted.` and takes
  nothing new. The hold stays with its old lease note.
- The hold may be kept without a break for 3600 seconds in all. After that,
  `turn` and `land` refuse, give the turn back and leave the holder to ask
  again.

Giving it back:

- `--release` gives the hold back, writes a `left` note and prints
  `Gave back the landing turn held for <id prefix>.`
- When the caller holds none for the card, it still writes the `left` note,
  which drops a queued ask and creates the `landing turn` card when the board
  has none, and refuses.
- A hold that ran out is cleared and reported as already gone.
- A hold whose note names an older fence than the live claim is not found as a
  hold, but while the caller owns that claim `--release` still frees it under
  its live fence and prints the same line.

Landing under a hold:

- `land CARD` finds a hold taken by the caller for that card and lands under it
  without asking again.
- It renews the lease before `jj land` and gives the turn back once the card
  has landed.
- A refusal leaves the hold in place, with a line that says so, so the runner
  fixes the cause and lands again.
- When the hold ran out or another card took the turn, `land` writes nothing,
  lands nothing and refuses with
  `The landing turn held for <id prefix> ran out or was taken by another. Take
  it again with dev board turn <id prefix>.`, and `turn CARD` takes it again.

### allow

`dev board allow CARD WORD...` replaces the card's `dev.allow` field with
the JSON array of the words and prints `set allow <id prefix>, <words>`.

- Each word is `test-edits` or `ci-edits`, with duplicates dropped. They are the
  guard rails the card lifts.
- It sends `PATCH /api/tasks/{id}` with
  `{"fields":{"dev.allow":["test-edits","ci-edits"]}}`, with the claim's
  fence when this machine holds one.
- `allow CARD none` sends `null` to clear the field and prints
  `cleared allow <id prefix>`.
- No word, any other word, or `none` beside another word is exit 2. An unknown
  card is exit 1.
- A Pomb board without the field is refused before any write with
  `The board has no dev.allow field. Define it on the board first.`
  (exit 1).
- Sending the same value twice changes nothing more, so it is queued while Pomb
  is unreachable like `checks`.
- A local board keeps the words in the card's `allow`.

### tests

`dev board tests CARD NAME...` replaces the card's `dev.tests` field with
the names joined by line breaks and prints `set tests <id prefix>, N names`
(`1 name` for one).

- It sends `PATCH /api/tasks/{id}` with `{"fields":{"dev.tests":"a\nb"}}`,
  with the claim's fence when this machine holds one. The field is multiline
  text, and a runner reads one name per line.
- No name, a blank name or a name with a line break is exit 2. An unknown card
  is exit 1.
- A board without the field is refused before any write, naming it (exit 1).
- It is queued while Pomb is unreachable like `checks`.
- A local board keeps the text in the card's `tests`.

### files

`dev board files CARD PATH...` is the same as `tests`, for the `dev.files`
field. It prints `set files <id prefix>, N names` (`1 name` for one).

### outcome

`dev board outcome CARD TEXT` appends a Done when outcome to an existing card.
The other forms change one by its number N.

N counts from 1 in the order `show` prints the outcomes, which come from the
subtasks `/export-data` carries (`id`, `name`, `done`). An N that is not a whole
number of 1 or more is exit 2, and one past the last outcome is exit 1 naming
how many the card has.

The other forms:

```
dev board outcome CARD --rename N TEXT --reason TEXT
dev board outcome CARD --tick N
dev board outcome CARD --untick N
dev board outcome CARD --delete N --reason TEXT
dev board outcome CARD --convert
```

The forms:

- The append sends `POST /api/tasks/{id}/subtasks` with `name` and prints
  `outcome <id prefix> N added`, with N the new outcome's place.
- `--rename` rewords the Nth and posts one decision note with the old text, the
  new text and the reason. A missing or empty `--reason` is exit 2 and writes
  nothing.
- `--tick` and `--untick` set it done or clear it (`PATCH` on
  `/api/tasks/{id}/subtasks/{sub_id}` with `name` or `done`).
- The output is `outcome <id prefix> N reworded`, `ticked by NAME` or
  `unticked`.
- `--delete` removes the Nth outcome, and only the lead runs it. Its rules are
  under `outcome CARD --delete` in Columns, cards and sizes.
- `--convert` moves a v1 `## Done when` checklist into outcomes. It takes no
  other word (exit 2).

The text:

- The words after the card, or after N, are the text. It must not be blank
  (exit 2).
- The text gets the prose warnings.

Ticking:

- A tick on a claimed card needs `--as NAME` (or `DEV_AGENT`) for someone other
  than the claimant.
- The reviewer or verifier ticks, and a card moves to Done only once every
  outcome is ticked (see `move`).

Converting:

- `--convert` appends one outcome per `- [ ]` or `- [x]` item in order, ticks
  the ticked ones, and only after every append and tick succeeded rewrites the
  description (`edit`) without that heading and those items. It prints
  `outcome <id prefix> converted N outcomes`.
- A card that already has outcomes prints
  `Outcomes of card <id prefix> are left alone. It already has outcomes.`
- A card with no checklist prints
  `Outcomes of card <id prefix> are left alone. It has no Done when checklist.`
- Both are exit 0 with nothing changed, so a second run changes nothing.
- A failure part way leaves the appended outcomes and the old description. The
  card then counts as converted until its outcomes are fixed by hand.

Writes and queueing:

- Every form sends the owner fence as `If-Owner-Fence` when this machine holds
  one.
- dev never calls Pomb's reorder subtasks, which is admin-only.
- A local board keeps the same rows in the card's `outcomes`, refusing a stale
  fence as the other writes do.
- The append, `--rename`, `--tick` and `--untick` are queued while Pomb is
  unreachable. A timeout or gateway error queues only `--tick` and `--untick`,
  which are safe to apply twice.
- `--convert` and `--delete` are never queued. The append and `--convert` are
  not safe to apply twice (N is read from the live card at replay time).

### ship

`ship [--rev REV] [-- CMD...]` ships the Release batch. It runs the
release commands, then moves each shipped card from Release to Done.

The commands:

- The command after `--` runs once, for example
  `ship -- dev release --batch 12 --summary TEXT`.
- With no command, each row of the `checks` list under `[board.release]` runs
  once.
- Every command is a plain command run from the project root.
- With no command and no `checks` key under `[board.release]`, `ship` exits 2
  and names `[board.release]`.
- With no command and a `checks` key that is malformed, `ship` exits 1 and
  runs nothing. A malformed key is one of:
  - an empty list
  - a value that is not a list
  - a row that is not a string, or that is not a plain command

The revision:

- REV is a jj revset that names one commit, and it defaults to trunk. In a git
  project REV is a git revision, and the default is the fetched remote trunk.
- When REV cannot be read, `ship` runs nothing and moves no card.
- A `dev --remote` row tests the working tree of the project root. When that
  tree differs from the tree of the commit REV names (a jj `@` that differs, a
  git `HEAD` that differs or a dirty git tree), `ship` exits 1, runs no command
  and moves no card. Run it from a workspace at that revision.

The move:

- It happens only when every command passes.
- A card moves to Done when all its outcomes are ticked and its landed commit
  is an ancestor of REV.
- Each moved card gets a `done` note that names REV and its commit
  (`Shipped in trunk, commit <12 characters>.`).
- The landed commit comes from the card's newest land note, in either form:
  `Landed commit <commit> (change <id>) on trunk` from `dev board land`, or
  `landed <commit> on <remote>/main` from the land verb Pomb ships.

The cards left in Release:

- `ship` lists each one with its reason: an outcome is not ticked, the card has
  no readable landed commit, or its landed commit is not in REV.
- A card whose move fails stays in Release, is listed, and makes `ship` exit
  1.
- A card whose move succeeds but whose note fails stays in Done with no `done`
  note. `ship` lists it under `moved to Done with no done note, write it by
  hand:` and exits 1.
- Neither write is queued.

A failing command:

- When a command fails or times out, `ship` stops at it and moves no card.
- It prints the command and its output tail, and exits 1.

Following trunk:

- After every command passes, `ship` runs `dev follow` and adds its one line
  to the output, whether or not each card moved.
- A project `.dev/follow.sh` or `.dev/follow.lua` replaces the built-in. When
  a command fails, `ship` runs neither.
- The line never changes the exit code.

### size

`dev board size CARD S` sets the card's colour and prints
`sized <id prefix> <S>`.

The sizes:

- `1` is yellow, `2` is green, `3` is blue, `3+` is red and `unsized` is white.
- Any other size word is exit 2 naming the five.
- `unsized` on a card outside Icebox is exit 1 with
  `Card <id prefix> is outside Icebox and keeps a size. Move it to Icebox
  first.`

The write:

- It is `PATCH /api/tasks/{id}` with `color_id`, sending the claim's fence when
  this machine holds one.
- The colour id comes from the palette (`/colors`) by its `value`, never its
  label.
- A board without the colour is `board unavailable: the board has no <colour>
  colour` (exit 1).

### note

`dev board note CARD [--board B] [--kind K] [--as ROLE] TEXT` adds a comment
and prints `noted <id prefix>`.

The text:

- The words after the card, minus the options, are joined with spaces.
- Any other word is text, one starting with `-` included.

The options:

- `--kind` is `decision`, `blocked`, `status` or `done` in any case, sent
  lowercase as the comment's `kind`. With no `--kind` the comment has kind
  `agent`.
- Any other kind is exit 2. `question` is refused too, and the message names
  `dev board ask`.
- `--as ROLE` is free text, trimmed, sent as the comment's `author` label. With
  no `--as`, Pomb's default stays.
- An empty, over-long or control-character `--as` is exit 2. Pomb allows 80
  characters.
- `--board B`, right after `CARD`, comments on the card on the Pomb board named
  `B` from any repo, looked up as `add --board` looks it up.
- A local board refuses `--board` (exit 1), and it takes no `--edit` or
  `--delete` (exit 2).

Where it shows:

- A local board stores the kind and the label on the comment.
- `show` and `notes` print them.
- A queued note keeps both options in its arguments.
- `--edit` replaces only the body, so the kind and the label stay.

### note --edit and note --delete

`dev board note CARD --edit COMMENT TEXT` replaces the body of one of the
agent's own comments. `dev board note CARD --delete COMMENT` deletes it. Each
prints `edited` or `deleted` with the card's and the comment's id prefixes.

The calls:

- The edit is `PATCH /api/tasks/{id}/comments/{comment_id}` and the delete is
  `DELETE` on the same path.
- `COMMENT` is an id prefix from `notes`, 8 hex characters or more and unique
  on the card, else exit 1.
- A missing text, a missing comment or an extra word is exit 2.

Whose comment:

- Pomb lets a work or provision token change only a comment that same token
  wrote.
- It answers 403 for any other comment and for one written before Pomb 0.5.7.
- dev prints that as `that comment is not yours to change` (exit 1).

### move

`dev board move CARD COLUMN [--lane L] [--max-size N] [--wait SECONDS]` moves
the card to the top of the column and prints `moved <id prefix> to <column>`.

- The card keeps its swimlane. `--lane L` moves it to that lane too, and puts it
  at the top of the column in that lane. Pomb counts a position within one
  column and lane, so `order` takes cards of one lane only.

A full column:

- A move refused for a limit, by dev's own check or by Pomb's 409
  `wip_limit_reached`, exits 3 and prints the refusal that names the column,
  its cards and its limit (see the limits below).
- `--wait` is a whole number of seconds up to 86400 and is off by default. With
  it, the move tries again every 15 seconds until room frees, and gives up at
  the bound with exit 3 and the last refusal. A usage error is exit 2.
- `dev board wait` has no event for a column freeing, so the wait polls the
  move. Each try repeats every check, and a try that takes the claim gives it
  back when Pomb refuses.

The output:

- A move into In Progress that takes the claim adds a blank line and the card
  as `show CARD` prints it.
- When that read fails, the same stderr warning as `take` appears.

The claim:

- When the card has a claim taken by `take`, the move sends its fence as
  `If-Owner-Fence`.
- For any column but In Progress or Blocked, the move also stops the keep-alive
  loop and forgets the claim. Once the move has succeeded, it releases the
  claim on the backend with its fence.
- A refused release prints `dev: Moved, but the claim was not released.
  <reason>` on stderr, and the move still succeeds.
- A move into In Progress of a card nobody holds, on a machine with no claim on
  it, takes the claim first as `take` does, with `DEV_AGENT` as the name. An
  epic is included.
- A name that is not `repo/role[/card]` is exit 2.
- The move releases that claim again when it fails.

The refusals run in this order:

- When the column is Review, Verify, Release or not a column at all, the stage
  check runs before the card is read. A board that still has an In Review
  column and lacks a stage column fails with
  ``The board has an In Review column and no <name> column. Run `dev board
  init` to move the board to the stage columns.``
  (exit 1).
- After the card is read, `move` refuses a card labelled `needs:human` that
  moves to a different column.
- The Ready, planning, Done and epic rules follow, each described below.
- A move into Review is refused unless the card is in In Progress under a claim
  or comes back from Verify, and a move into Verify is refused unless the card
  is in Review. The refusal reads ``Card <id prefix> cannot move to <column>
  from <column>. It must pass <column> first.`` and names In Progress under a
  claim or Review (exit 1). A move to the column the card is already in passes.
- A card leaving In Progress for Review, Ready or Blocked with a claimant and
  no note from that claimant after the claim is refused with
  ``Card <id prefix> has no note from its claimant NAME since the claim. It
  cannot leave In Progress. Note what you built, tried and learned first with
  `dev board note <id prefix> TEXT`.``
  (exit 1).
- None of these refusals is queued.

A move into Ready:

- A card that is white, has no colour or is red (more than 3 Pomodori) is
  refused before the backend is called, on both backends, so a card is sized in
  planning and red never reaches Ready.
- The refusal reads
  ``Card <id prefix> has no size. It cannot enter Ready. Size it with `dev board
  size CARD 1`, `2` or `3`.``,
  or for red
  ``Card <id prefix> is red, more than 3 Pomodori. Split it, since a red card
  cannot enter Ready. Size it with `dev board size CARD 1`, `2` or `3`.``
  (exit 1).
- A card whose description lacks one of the three v3 headings or text under
  one, or that has neither 3 to 7 outcomes (subtasks) nor a v1 checklist item,
  is refused the same way, before the backend is called.
- The v1 fallback is a `- [ ]` or `- [x]` item under `## Done when`, and it
  holds while boards are converted.
- The refusal reads
  ``Card <id prefix> is not in card format v3 and cannot enter Ready. It lacks
  <what>. Add outcomes with `dev board outcome` and fix the description with
  `dev board edit`, where a v1 Done when checklist also counts.``
  (exit 1, on both backends, size checked first).
- `dev.board.missing(description, outcomes)` lists what is missing.
- A card with no checks row and no children is refused after those, before the
  backend is called.
- That refusal reads
  ``Card <id prefix> has no checks row and cannot enter Ready. Give it one with
  `dev board checks CARD CMD`.``,
  or on a Pomb board with no checks field
  ``The board has no checks field. Run `dev board init` to add it.`` (exit 1,
  on both backends, which `checks_field` tells apart).
- A local board always has the checks field.
- An outcome that ends with neither `(check: ROW)` naming part of a checks row
  nor `(reviewer judgement)` is refused after the checks row, and the refusal
  names each such outcome (exit 1). An epic is not asked.
- A prose outcome is the usual one to mark `(reviewer judgement)`. The
  verifier ticks the reviewer judgement outcome after it reads the diff against
  the outcome.
- A card with children is an epic (`kind` epic or `children_total` on Pomb,
  `parent` links on a local board). It enters Ready under the same rules as any
  card, except that it needs no checks row, as its children carry the checks.
- A move into any other column, Icebox included, is never checked for the Ready
  rules.

A move into any column but Icebox or Ready:

- A card with no size, a description that lacks a v3 heading or text under
  Problem, with an empty Change or Out of scope section or a `Change:` or
  `Out of scope:` line under Problem, or no outcome is refused before the
  backend is called. A discard skips the empty section and the line.
- The refusal reads
  ``Card <id prefix> is not planned and cannot enter <column>. It lacks <what>.
  Fix it with `dev board size`, `dev board edit` and `dev board outcome`.``
  (exit 1, on both backends, `dev.board.unplanned`).
- An unsized card with children is told only `a size` and never the missing
  outcomes, which the refusal names once the card is sized.
- A `discard` is refused the same way for a missing size or heading, with no
  outcome needed, except an unplanned Icebox card given a `--reason`.

A move into Done (`move CARD done`):

- It is refused once the card is read, before the move is sent, while the card
  has an unticked outcome.
- The refusal reads
  ``Card <id prefix> cannot move to Done. N of M outcomes are unticked (1.
  text, 2. text). The reviewer ticks them with `dev board outcome CARD --tick N
  --as NAME`, or `dev board discard CARD` drops it.``
  (exit 1, on both backends, each open outcome numbered as `show` numbers it).
  Both refusals name the board's own Done column, so a board that renames
  Done reads `cannot move to Shipped`.
- Outcomes that Pomb sent in a form dev cannot read refuse the move the same
  way. That is a `subtasks` that is not a list, or an entry without a string
  name.
- That refusal reads
  `Card <id prefix> cannot move to Done. Its outcomes cannot be read from Pomb.
  They cannot be checked.`
- A move to Ready refuses a card with outcomes dev cannot read the same way,
  naming Ready, and never reports its outcomes as missing.
- A card with no outcomes, or with all of them ticked, moves as before.
- A move to Done that Pomb could not answer for is not queued.

An epic with an open child:

- It is refused a move into a column whose settings make it WIP-limited or
  done, never one picked by its name.
- The refusal reads
  `Card <id prefix> is an epic and cannot enter COLUMN, a done column. N of M
  children are open.`
  (or `a WIP-limited column`, exit 1, on both backends).
- `Backend:columns` reports each column's `is_done` and `wip_limit`. A local
  column has no limit, so only `is_done` applies there.
- The refusal reads the epic's counts from the card, so a plain card costs no
  extra request.
- When the counts are stale and Pomb refuses the move itself
  (`epic_has_open_children`, a `409`), dev prints Pomb's own text.
- Pomb reopens an epic that moves out of a done column. A local epic is open
  again as soon as its column is not done, and a local board stores no closed
  flag.
- `discard` skips the rule.
- `add` cannot create a card with children and `discard` asks for no outcomes,
  so neither reads them.

### discard

`dev board discard CARD [--board B] [--reason TEXT]` drops a card and prints
`discarded <id prefix>`. The card is kept, never deleted.

The steps, in order:

1. With `--reason`, a decision note with TEXT (`note --kind decision`).
2. The label `discarded` (`label`).
3. The move to Done (`discard_move`, the move without the outcome check).

The rules:

- Each step is the command of the same name, so its checks and its claim
  handling apply. The move skips the outcome check, and a dropped card is not
  done.
- A card labelled `needs:human` is refused before any step, as `move` refuses
  it, so nothing is posted.
- A blank `--reason` is exit 2.
- `--board B`, right after `CARD`, drops the card on the Pomb board named `B`
  from any repo, looked up as `add --board` looks it up. A local board refuses
  it (exit 1), and a missing name is exit 2. A step that Pomb cannot take is
  not queued there, so no step replays on this repo's own board.
- A card lookup that Pomb cannot answer is not queued, and the steps need the
  card's id.
- Without `--board`, when Pomb cannot take a step, the steps left are queued
  in order under those names, so a reason is never posted twice.

The planning check:

- An unplanned Icebox card closes when it has a `--reason`, and the planning
  check is skipped there.
- An unplanned card in any other column is refused (exit 1).
- An Icebox card with no reason is refused too.

### run

`dev board run [--orders TEXT | --end]` keeps a session's run on the board as
one card labelled `run`, named `run <session>`. The session is `DEV_AGENT`, else
`dev@<host>:<session>`.

The session name:

- Without `DEV_AGENT` or `CLAUDE_SESSION_ID` the session has no stable name, so
  `run` is exit 2.
- Two sessions have two cards.

With `--orders TEXT`:

- It adds the card in In Progress, size 3, claimed under the session name.
- The card holds the orders quoted line by line in its Change, three outcomes
  and a `dev board lint` checks row.
- It prints `started <id prefix>`, then the card as `show` does.
- Orders over 250 words, counting each line's quote mark, are exit 2.
- A session that already has an open run card is exit 1.
- In a project with no `[board]` section, it makes the board as
  `init --name <directory>` does when the project is private. That means no
  origin, or an origin on github.com that `gh repo view` says is private.
- Otherwise it stops with exit 1, to leave a public project's board to the
  owner.

With no flag:

- It prints the session's open run card (claiming it again when the claim
  lapsed), the cards the session holds and the top of `next`.
- With no open run card it is exit 1 with
  ``There is no open run card for NAME. Start one with `dev board run --orders
  TEXT`.``

With `--end`:

- It closes the card the way `discard` does, with the note `the run ended`.
- It prints `ended <id prefix>`.

Elsewhere:

- `next` never returns a run card.
- `lint` does not ask a run card for a claimant, and the claim lapses after
  150 minutes.

### take

`dev board take CARD [--as NAME] [--from NAME] [--max-size N]` claims the card
and starts the keep-alive loop.

The claim:

- It is `POST /api/tasks/{id}/owner` with `name` NAME, else `DEV_AGENT`, else
  `dev@<host>:<CLAUDE_SESSION_ID, else the user and terminal, else the pid>`,
  and `ttl_seconds` 900.
- NAME is one word of letters, digits and `.`, `-`, `_` and `/`, at most 200
  characters, else exit 2.
- When this machine already holds a fence, dev renews it through
  `/owner/renew` first and grabs again when Pomb answers 409.
- On a Pomb board dev refuses an epic with an open child, which the grab route
  does not.

The output:

- A Pomb board prints `took <id prefix>, fence N, renewing every 5m for up to
  Mm`.
- A local board needs no loop and prints `took <id prefix>, fence N, held for
  Mm`.
- A blank line and the card as `show CARD` prints it follow.
- When that read fails, `dev: Took card <id prefix>, but its view failed.
  <reason>` goes to stderr and the claim stays.

A card another agent owns:

- It is `owner_held`, printed as `board unavailable: pomb answered 409: task
  owned by NAME until TIME` (exit 1).
- No loop starts.

The claim note:

- The first claim by a name also writes a status note `dev-claim: by=NAME`, so
  the name outlives the claim. `review` reads those notes.
- If that note cannot be written, the claim is released and `take` exits 1.
- `note` refuses the `dev-claim:` prefix as it does `dev-check:`.

The handoff:

- `--from NAME` takes over the claim of an agent that exited. It lets the lead
  that verifies a card land it under its own name.
- When NAME is the card's current claimant, `take` releases that claim and
  takes the card under the caller's name, then posts the status note
  `handoff: NAME released the claim and CALLER took it`.
- It uses the backend's own release and claim calls, so a Pomb board and a
  local board both work.
- It refuses with exit 1 and changes nothing when the card has no claim, when
  NAME is not the claimant, or when NAME is the caller.
- A failure after the release, such as a claim that Pomb refuses, leaves the
  card unclaimed. The runner's keep-alive loop is stopped and `take` exits 1.
- A Pomb release sends the runner's fence when this machine holds its state
  file, and none otherwise.
- Without `--from`, a card another name holds still gets the claim refusal.

The size limit:

- `--max-size N`, or when the flag is absent `DEV_MAX_SIZE`, is 1, 2 or 3,
  else exit 2.
- With it set, `take` and `move CARD progress` refuse a card bigger than that
  many Pomodori with
  `<id prefix> is <size>, above this runner's limit of N Pomodori
  (DEV_MAX_SIZE)`
  (exit 1).
- `run` takes its own run card and is not held to the limit.
- The `next:` line of `run` skips a card above it.

The limits Pomb holds:

- `take`, `move CARD COLUMN` and `move CARD progress` also refuse a card when a
  limit Pomb holds forbids it, to land what passed before a new card starts.
- dev reads both kinds of limit from Pomb with a fresh `GET /api/boards/ID`.
  They are a column's own `wip_limit` and the `limit_groups` that span adjacent
  columns, such as In Progress, Review and Verify.
- A board with no limits set in Pomb is uncapped, and so is a local board.
- A move to Done is not checked here.
- A card already in In Progress, or whose claim this machine holds, is not
  checked for In Progress.
- A take of a card another name holds gets the claim refusal.
- Cards already in flight are never moved.

A column limit:

- It refuses when the target holds that many other cards and the card is not in
  it.
- The refusal reads `COLUMN holds N cards (ID, ID), at its limit of L. Land one
  first.`
- A column whose `limit_unit` is `hours` is skipped, and Pomb enforces that
  limit itself.
- A missing `limit_unit` counts as `count`.

A group limit:

- It refuses when the target is in the group, the card's column is outside it
  and the group's columns hold that many other cards, whoever claimed them.
- The refusal reads `N cards are in flight in In Progress, Review and Verify
  (ID, ID, ID), at the limit of L. Land one first.` (exit 1 for `take`, 3 for
  `move`).
- Cards in other columns do not count, and neither do epics or the card being
  moved.

Pomb's own limits:

- The count and the claim are two steps, so under parallel commands the limit
  is advisory and can be overrun.
- Pomb enforces its limits too. A move it refuses with 409 `wip_limit_reached`
  prints `Pomb refused the move: MESSAGE` (exit 3).
- A `move CARD progress` that had just taken the claim gives it back.
- dev never sends `force`, so its own land move into Release fails the same way
  and the card stays put.
- `next` stays read-only and shows the card anyway.
- The turn hold is 1800 seconds by default and 3600 at most (see `turn`).

### release

`dev board release CARD` gives up the card's claim and prints
`released <id prefix>, fence N`.

The steps:

- A card with no claim taken by `take` is exit 1.
- It reads the card first and skips the post when no owner lease is live.
- When a person holds the card, it is exit 1 and prints
  `The card is held by NAME. Only that member can release it in Pomb.`
  Nothing is posted, and the claim stays.
- It posts `/owner/release` with the owner's name as `name` and the fence as
  `If-Owner-Fence`.
- Only once the release succeeds does it stop the loop and forget the claim.
  When the backend refuses, the loop keeps running and the claim stays.

### sync

`dev board sync` replays the changes queued while Pomb was unreachable, as
described under the queue below. It is the one subcommand outside the board's
own commands.

On a Pomb board:

- It prints `synced <sub> <first argument>` per change.
- It prints `dropped <sub> <first argument>: <reason>` for one Pomb refused.
- It ends with `synced`, or `Nothing is queued.` for an empty or missing queue.
- When Pomb is still unreachable, it prints `queued: N` and exits 1.

On a local board:

- It prints `dev: A local board has nothing to sync.` (exit 1).

### Prose warnings

`add`, `note` and `edit` warn when card prose holds a hex id, a hash or a path.
The warning goes to standard error with no prefix, and the write still
happens (exit 0, output unchanged).

- messages: `Card prose holds a hex id or hash: <word>.` and
  `Card prose holds a path: <word>.`, one line per distinct word.
- scanned: the `--description` of `add`, a new or `--edit`ed `note` text and
  the text `edit` writes. A `--done-when` outcome counts as prose. Fenced code
  counts as prose.
- not scanned: text under a `## Change` heading, and the name, `--checks`
  and `dev board checks` arguments. A note has no headings, so all of it is
  prose.
- hex id: a run of 7 or more hex characters with at least one digit and one
  letter (`decade` and `1234567` pass), found in any alphanumeric run of a
  word.
- path: a word, trimmed of surrounding quotes, backticks, brackets and
  trailing punctuation, that holds a `/` and either starts with `~/`, `./` or
  `/` or ends in a dot and a letter-led extension (`and/or` and `2026/10/28`
  pass). A URL (`scheme://...`) is exempt.

`dev.board.prose_warnings` implements the scan. A queued replay prints none.

### The board section

The board comes from the `[board]` section of `<root>/.dev/config.toml`.

- `backend`: `pomb` or `local`. A `local` backend keeps the board in a file
  (see the local backend below). Any other backend is exit 1.
- `name`: defaults to the project directory's name.
- no `[board]` section: every subcommand prints
  `dev: This project has no board.` and exits 1, which is how an agent
  branches.

Every subcommand, `edit` and `show` alike, prints
`dev: This project has no board.` from a directory outside the project (the
root is found from the current directory). A refusal from a checkout's root
or any directory below it means that checkout's `.dev/config.toml` has no
`[board]` section. A refusal from elsewhere means the shell was not in the
project, or that project has no `[board]` section.

The Pomb server and the token reference come from `[board.pomb]` (`url`,
`token = "pass:<entry>"` and `lead_token = "pass:<entry>"`) in the user file
`~/.config/dev/config.toml` alone, read with `config.user`. A project file
cannot name another server for the token to go to.

`dotfiles/bin/.config/dev/config.toml` ships that file. This repo's own
`.dev/config.toml` holds `[board] backend = "pomb"` and `name = "dotfiles"`.

### The keep-alive loop

`take` starts a loop that renews the card's owner lease.

State file:

- path: `<state home>/dev/board/<card id>` (`$XDG_STATE_HOME` when absolute,
  else `~/.local/state`), with `card=`, `fence=` and `pid=` lines.
- mode: 600 in a mode 700 directory. It never holds the token.
- write: to a `.new` file, then renamed, so the loop never sees a half file.

Start:

- the loop is `board/keepalive.sh` in dev's share directory.
- `dev.board.pomb` starts it through
  `sh -c 'set -m; nohup bash <script> ... & echo $!'`. It has its own process
  group, outlives the caller's shell and wakes no model.

Every 5 minutes (`sleep` with the tick in seconds as its seventh argument)
the loop does these in order:

1. It checks that the state file still holds its fence.
2. It reads the token through the same `board/passlock.sh` as
   `dev.board.pomb`, Keychain first. A token that cannot be read, or has a
   character outside `A-Za-z0-9._~+/=-`, skips that renewal and counts as a
   tick.
3. It sends `POST /api/tasks/{id}/owner/renew` with
   `{"name":NAME,"ttl_seconds":900}` and `If-Owner-Fence: N` through
   `curl -K -`. The token goes over a `printf` builtin pipe into curl's stdin,
   so it is in no argv, no environment variable, no file and no output.

The loop ends when:

- the state file is gone or holds another fence (`release`, `move` out of In
  Progress or a newer `take`). `release` and `move` also kill its pid after
  `ps` shows the script in the command. `release` does so only once Pomb has
  accepted the release, so a failed release can be retried.
- a renewal answers 4xx (the owner lease is gone). The exception is a 401 for
  a token read from the Keychain: the loop drops that Keychain entry through
  `board/keychain.sh` once, and ends on a second 401 before any renewal
  succeeds.
- twice the card's size in 5-minute ticks have passed: 10 for 1 Pomodoro, 20
  for 2 Pomodori and 30 for any other size, unsized included.

A network failure, a 5xx or a failed `pass` read (a locked store) keeps the
loop going until the cap. A move made outside `dev board move` does not stop
it.

A loop that ends removes its state file when the file still holds its fence.
A crashed agent's claim lapses after its 900-second lease.

Readers of the lease:

- `ls` adds a holder column before the name, only when a listed card has a
  live owner (`-` for the others). It reads `owner.holder` of `/export-data`
  while `owner.lease_expires_at` is in the future or null.
- a lapsed lease counts as unowned in `ls`, `next` and `lint`.
- `next` reads each card's `owner` and skips a live one.
- moving a card keeps the loop only into In Progress, so `next`, `take`,
  `move progress` works.

### wait

`dev board wait [--for ready|review|verify|release|human|lead|planner]` (Pomb
only) loops on `Backend:wait` until an event matches. It prints one line per
matching event in the reply, then exits 0, so a background run under `timeout`
wakes the session.

The `--for` modes:

- `ready`: sends the kinds `task_added,task_moved` and matches a card whose
  column is Ready after the event, printed as `added <id prefix> to Ready` or
  `moved <id prefix> to Ready`.
- `review`, `verify` and `release`: send the same kinds and print the same
  lines for their own column, and match only a card with no claimant.
- `human`: sends `task_moved,comment_added` and matches two things. The first
  is a move whose `from_column` is Blocked, whose `actor` is `human` (Pomb's
  `actor_kind` of `user`) and whose `at` is not earlier than the wait's start,
  so a move in the start's own second counts. Pomb's `at` is epoch seconds,
  and `Backend:wait` keeps both on each event. It prints
  `moved <id prefix> out of Blocked`. The second is a comment event
  whose card is not Done and whose newest comment is the owner's and newer than
  the wait's start, which `wait` reads with `Backend:cards` and
  `Backend:comments`. It prints `the owner commented on <id prefix>`.
- `lead` and `planner`: send `task_added,task_moved,task_updated`. For each
  reply with events they read `Backend:cards` and match an event whose card is
  in Blocked with no claimant, no `needs:human` and the label `needs:lead`
  (`needs:planner` for `--for planner`), skipping a run card, an epic with an
  open child or a card an open card blocks, which `Backend:blocked` answers. A
  card that such a blocker held back is not announced again when the blocker
  clears. The line is `<id prefix> is labelled needs:lead in Blocked`, once per
  card per reply.
- no `--for`: all four kinds match, printed as `added <id> to <column>`,
  `moved <id> to <column>` (`another board` when the column is unknown),
  `updated <id>` and `commented on <id>`.

The `human` mode settles before it answers. The first match opens a window of
60 seconds (`Owner.SETTLE_SECONDS`). Each further call to `Backend:wait` passes
the time left of the window as its timeout, and a match restarts the window.
An empty reply or an elapsed window ends it with one line per card.

An unknown `--for`, a card argument or another flag is exit 2. A local board
prints `dev: A local board has nothing to wait on.` (exit 1).

The cursor:

- path: `<state home>/dev/boards/<name>.<mode>.cursor` at mode 600, where
  `<mode>` is `ready`, `review`, `verify`, `release`, `human`, `lead`,
  `planner` or `all`. The name has every character outside `A-Za-z0-9._-`
  turned into `_`.
- one file per `--for` mode, so a filtered wait never consumes another mode's
  events.
- written after every reply, except for `--for human`, which writes it when it
  prints its held lines. With no file, the first call asks without a
  cursor and starts from the cursor Pomb answers.
- an expired cursor (410) stores the backend's oldest cursor and prints
  `events were trimmed, check the board` (exit 0).
- `--for human` stores the oldest cursor when it holds no line and rereads
  the cards instead (`Owner.sitting` at the start, `Owner.departed` on a
  trim). It prints
  `moved <id prefix> out of <column>` for each card that sat in Blocked or
  Icebox and has left it or the board, or keeps waiting when none has.

Failures:

- a failure that `pomb.unreachable` counts (idempotent rules) is retried
  after a 30 second nap. The tenth in a row exits 1 with its message (an
  endless silent retry would hide a dead Pomb from the session). The card
  read of `lead` and `planner` and the comment read of `human` are retried like
  the events call: a read that fails the same way keeps the cursor and asks the
  same call again.
- a 429 whose body has the code `too_many_waits` (4 open waits per token, and
  every session shares the token) is never a failure. `Backend:wait` returns a
  fourth value, `true`. `wait` prints
  `dev: pomb holds too many open waits for this token, waiting for one to end`
  on standard error once per call, resets the failure count and retries with a
  pause of 30, 60, 120, 240 and then 300 seconds, each cut by up to a quarter
  with a random fraction. A reply starts the pause over.
- a 429 with another code is a rate limit. Every Pomb request waits the
  `Retry-After` seconds, or the `retry_after` of the body, or one second, each
  wait cut at 5 seconds, and sends again up to 3 times within 10 seconds of
  waiting. A 429 that outlasts them is a plain refusal. Any other refusal
  exits 1 at once.

`wait` is not in the queue rules, and a reply with no matching event loops
again. `tests/lua/board_test.lua` covers it with a fake backend and stub
`nap`, `random` and `notice` options.

### The local backend

The `local` backend is `dev.board.localboard`, one JSON file written one card
per line, so a tracked file diffs well.

The file holds:

- `name`, `columns`, `colors` and `cards`.
- per card: `column_id`, `color_id`, `labels`, `links`, `comments` and
  `entered_at`, and a `claim` of `claimant`, `fence` and `expires_at` while one
  is held.

Where it lives:

- default: `<state home>/dev/boards/<name>.json` (`$XDG_STATE_HOME` when
  absolute, else `~/.local/state`) at mode 600 in a mode 700 directory. The
  name is restricted to letters, digits, dots, dashes and underscores (else
  ``dev: A local board's name must be letters, digits, dots, dashes and
  underscores to name its file. Otherwise set the `path` setting of
  `[board]`.``, exit 1).
- tracked: `<root>/<path>` at the default mode when
  `[board] path = ".dev/board.json"` is set. The path must be relative, start
  with a letter, digit, dot or underscore and hold no `..` or `//` (else exit
  1). `path` with the `pomb` backend is exit 1.

Every change runs in `dev.board.store`:

1. Take an exclusive `flock` on `<file>.lock`. A tracked path gets a lock file
   named for the path under `<state home>/dev/boards/locks/`, so the project
   tree gets none.
2. Read the file again and change it.
3. Write a temporary file beside it and `rename` it over.

Two processes never lose each other's write, and a reader never sees half a
file.

Behavior:

- `take` sets the claim's expiry to twice the card's size from now (50, 100
  or 150 minutes), starts no loop, writes the state file with `pid=0` and
  prints `took <id prefix>, fence N, held for Nm`.
- a live claim by another claimant or with another fence refuses the claim. A
  write that sends a fence while another fence holds the claim is refused. A
  lapsed claim blocks nothing.
- comments are of actor `agent`. `note --edit` and `--delete` refuse any other
  (`that comment is not yours to change`).
- new cards go to the bottom of their column and `move` puts a card at the
  top.
- `next` is the top unclaimed Ready card.
- `stale` counts days from the card's `entered_at`.

### The offline queue

`dev.board.queue` keeps the Pomb offline queue in
`<state home>/dev/boards/<name>.queue`, at mode 600. The name has every
character outside `A-Za-z0-9._-` turned into `_`. The file is a JSON list of
`{sub, args, at}` with the command as typed and no token.

Queued commands:

- `add`, `move`, `note` (not `--edit` or `--delete`), `size`, `label`,
  `link`, `edit`, `rename` and `outcome` on a Pomb board queue themselves when
  Pomb could not be asked. That is `dev.board.pomb.unreachable`: `pass` timed
  out or is locked, or curl could not resolve or connect (exit 5, 6 or 7).
- `move`, `size`, `label`, `link`, `edit`, `rename` and `outcome` with
  `--tick` or `--untick` are safe to apply twice. For them a curl timeout, a
  502, 503 or 504, or an answer that is not JSON also queues.
- a curl timeout, a 502, 503 or 504, or an answer that is not JSON may follow
  a change that was applied. `add` and `note` would then be doubled, so they
  are not queued on it, and neither is an `outcome` append, `--rename` or
  `--convert`.

A queued command appends itself to the queue, prints
`queued: Pomb unreachable, will sync` and exits 0. Usage errors, refusals and
every read are not queued.

Replay:

- every other `dev board` command on a Pomb board, `status` included, first
  replays a non-empty queue. Its `synced` and `dropped` lines go to standard
  error.
- a card prefix is resolved against the live board at replay time.
- replays run in order under the queue's lock, each leaving the file as soon
  as it is dealt with. A process killed mid-replay leaves that change queued,
  so delivery is at least once.
- a change Pomb refuses is reported and dropped, never retried.
- a change that finds Pomb unreachable again stops the replay and stays queued
  with those behind it.
- `status` prints `queued: N` last while changes are waiting.

A missing queue file is an empty queue. A file that is not valid JSON, is not
a list or holds an entry without a string `sub` and a list `args` is
malformed:

- `queue.count` and `queue.list` answer `<path>:<line>: <reason>` (the line
  from the parse error's offset, or `<path>: entry N is not a queued command`).
- `dev board sync` prints `dev: <that sentence> The queue is left in place.` and exits
  1.
- every other Pomb command (`status` included) prints the same line on
  standard error, replays nothing, runs normally and leaves the file
  untouched, so a bad queue never blocks a read.
- a write that would have been queued fails with `dev: REASON. The change could
  not be queued. WHY.` (`push` refuses a malformed file), and nothing
  overwrites the file.

`tests/lua/board_local_test.lua` covers the local backend on a temporary state
directory, a tracked path, six processes writing at once and the queue.

### Arguments

- column: matched against Icebox, Backlog, Ready, In Progress, In Review,
  Blocked and Done in any case, plus the short forms `progress` and `review`.
  Anything else is exit 2 naming the columns.
- card: its full id or a prefix of at least 8 hex characters that is unique on
  the board. A shorter, unknown or ambiguous one exits 1.
- size: the palette label of the card's colour, or `unsized`.
- a flag a subcommand does not take, a missing argument and a bad column are
  usage errors (exit 2).

### The Pomb requests

`dev.board.pomb` finds the board by name (`GET /api/boards`), then its columns
(`GET /api/boards/{id}`) and palette (`/colors`), matching columns by name.

Reads:

- `stale` pages through `/tasks?limit=500`, following `next_cursor` with
  `&cursor=`, for `column_entered_at`. It takes the rest from `/export-data`.
- `ls` reads `/export-data`, which alone carries each card's colour.
- `next` asks `/tasks?limit=1&ready=true&claimed=false&column_id=<Ready>` and
  reads the card for its colour.

Writes:

- `add`: `POST /api/tasks`.
- `note`: `POST /api/tasks/{id}/comments` (kind `agent`).
- `move`: `POST /api/tasks/{id}/move` (position 0).

`wait(after, kinds, timeout)` is `GET /api/boards/{id}/events/wait`:

- timeout: 50 seconds by default. Curl's `--max-time` is the timeout plus 10,
  and every other request gets 30.
- reply: `{cursor, events}`, with each event's column ids turned into names
  (nil for a null or unknown id, such as a null `column_id` on the source board
  of a cross-board move).
- a 410 `cursor_expired` returns nil, the message and the body's
  `oldest_cursor`.
- a local board's `wait` is `nil, "a local board has nothing to wait on"`.

A curl failure is `board unavailable: cannot reach <url> (curl exit N)`. An
HTTP error is `board unavailable: pomb answered <status>: <message>`.

### How init runs

`init` is deterministic and idempotent. It never deletes a column, a colour or
a card, and never renames a column.

The name and the config:

- the board's name comes from `[board]`, or from `--name N` when the project
  has no `[board]` section. Without either it exits 1. With a section, a
  `--name` that differs is a usage error.
- after the run it appends `[board]` with `backend = "pomb"` and that name to
  `.dev/config.toml`, creating `.dev` itself when the project has none (never a
  directory above the root). The line is `wrote [board] to .dev/config.toml`.
- a `[board]` section with no `backend` is exit 1.
- on a `local` board, `init` lays out the same columns and palette in the
  board's file. It makes the file when it is missing, from the five colours
  with their plain names. It takes no `--admin` (usage error) and refuses a
  `--name` that differs from the section's.

`init` runs through `dev.board.init` over the `dev.board.Layout` seam that
`dev.board.pomb` implements. It does these in order:

1. Create a missing board with `POST /api/boards`, using the template named
   `agent project` when `GET /api/templates` lists it and no template
   otherwise.
2. Fix the columns. Rename an In Review column to Review with
   `PATCH /api/columns/{id}` (`{"name": "Review"}`) when no Review column
   exists, and add each missing column with `POST /api/columns` (Done with
   `is_done`). Then re-read the board and mark an existing Done column done
   with `PATCH /api/columns/{id}` when it is not. Mark the Blocked column with
   `PATCH /api/columns/{id}` and `{"is_blocked": true}` when it is not. Set the
   stage of Ready, In Progress, Review, Verify and Release that hold none with
   `PATCH /api/columns/{id}` and `{"stage": "in_progress"}`, and likewise
   `ready`, `review`, `verify` and `release`. Last, reorder with
   `POST /api/columns/{id}/move` (`{"position": N}`, 0 first), so the nine
   standard columns come first in the order Icebox, Backlog, Ready,
   In Progress, Review, Verify, Release, Blocked, Done and any other column
   follows, kept and reported on every run as
   `kept column "X", which is not part of the standard board`.
3. Grant the agent roles.
4. Define the checks field when the board lacks it.
5. Name the palette through `PATCH /api/boards/{id}/colors/{color_id}`. The
   colours are found by `value`: yellow `1 Pomodoro`, green `2 Pomodori`, blue
   `3 Pomodori`, red `>3 Pomodori` and white `Unsized`, each with a legend
   description.
6. Strip size words from card names, with the palette named.
7. Enable and disable colours.
8. Make white the default, so a run that stops early can be repeated and
   still know the old default.
9. Create the limit group.
10. Report each card that wears a disabled colour.

Details by step:

- Blocked mark: a Pomb whose column views carry no `is_blocked` key stops
  `init` at that step with a message that it cannot mark a Blocked column yet
  and that `dev board ask` needs it. It sends no write for the mark. A local
  board has no such setting, so it marks nothing and says nothing.
- agent roles: `GET /api/v1/agent-roles` first, and the post is skipped when
  every standard role is granted to the board. Otherwise
  `POST /api/v1/agent-roles/standard` with `{"boards":[board id]}`. A local
  board has no roles and says nothing.
- limit group: posts the In Progress, Review and Verify column ids with a limit
  of 4 to `/api/boards/{id}/limit-groups`, only when the board has no group. A
  local board gets none.
- checks field: `GET /api/boards/{id}/fields` lists the keys, and
  `POST /api/boards/{id}/fields` sends `dev.checks` with the label
  `Checks`, the kind `table` and `required` true. Its columns are `run` (text,
  required) and `on` (multiselect, optional, with the one option `local`).
  Pomb refuses a multiselect without options, and runner names are set
  elsewhere. The definition is copied from the dev board. The line is
  `added the checks field dev.checks`. An existing field never changes,
  and a local board gets nothing.
- size words: strip a trailing `(yellow)`, `(green)`, `(blue)`, `(red)` or
  `(red, split)` from every card name with `PATCH /api/tasks/{id}`. The same
  call sets the colour from the word when the card's colour is white, unset or
  the colour that was the default when the run began, so a card Pomb painted
  with the old yellow default gets its real colour. Any other card keeps its
  colour. A name with several size words is stripped again until none is left.
  A name that is only a size word is kept and reported.
- colours: enable exactly white, yellow, green, blue and red, and disable every
  other colour (orange, purple, magenta, cyan, brown and any other value) with
  `PATCH /api/boards/{id}/colors/{color_id}` and `{"enabled": bool}`, enabling
  first. It prints one line per colour (`enabled white`, `disabled orange`)
  and never deletes a colour.
- worn colours: each card that wears a disabled colour is one line,
  `card <id prefix> wears the disabled colour orange, left as it is`, on every
  run, with the card's colour untouched.
- admin-only colours: Pomb keeps `enabled` admin-only. A 403 on it prints one
  line, ``Left the colours enabled as they are, since this token may not change
  them. Run `dev board init --admin`.`` The run carries on instead of exiting
  1.

Labels are plain strings on cards in Pomb, so `needs:lead` and `needs:human`
need no creation.

Each change prints one line:

- `created board X from the agent project template`
- `added column X` and `moved column X to position N`
- `marked Done as the column of finished cards`
- `marked Blocked as the column of cards waiting on an answer`
- `named yellow "1 Pomodoro"` and `made white the default colour`
- `renamed card <id prefix> to "..." and coloured it blue`
- `created agent roles` with the names the reply lists, or
  `agent roles unchanged` (not counted as a change)
- `created limit group In Progress, Review and Verify at 4`

The last line is `Board X already follows the standard. Nothing changed.`
or `board X: N changes`. A failure prints `dev: <message>` with exit 1 after the
lines of the changes already made. A `403` adds
``. This token may not change this board, so run `dev board init --admin`.``

`tests/lua/board_init_test.lua` runs the algorithm against a stateful fake
layout and the command against a fake `curl`.

### Tokens for init

Pomb 0.5.5 lets the lead token name colours, set the default and reorder
columns only on boards it created after 0.5.5. The default token is therefore
the lead token: `[board.pomb] lead_token = "pass:<entry>"` in the user file,
read like `token`, else exit 1 saying to set it or pass `--admin`.

`--admin` uses Pomb's device sign-in instead (`dev.board.device`):

1. `POST /api/v1/auth/device` with `client_name` `dev-board-init@<host>` and
   `scopes` `["admin"]`.
2. It prints `approve the admin sign-in at <verification_url>` and
   `code: <user_code>`.
3. `POST /api/v1/auth/device/token` every `interval_seconds` (5 more after
   `slow_down`).
4. The poll ends on `access_denied`, `device_code_expired`, `invalid_grant`,
   `quota_exceeded` or an unapproved sign-in after `expires_in_seconds`. Each
   prints `dev: <reason>` and exits 1.

The token comes back once, is held in the process's memory for that run and
goes to curl only as the `-K -` header line. The `device_code` goes to curl as
`--data-binary @<file>` in a mode-600 `mktemp` file under `$TMPDIR`, removed
when the poll ends. Neither is in argv, the environment, a file that outlives
the run or the output, `-v` and `-vv` included.

The approver may grant a lower scope, so `GET /api/v1/auth/whoami` must say
`admin` or the run stops before any change (`Backend:admin`):

- a server that returns `scope`: it must be `admin`.
- a server that returns `permissions` and `boards`: the token must hold every
  permission `GET /api/v1/auth/permissions` lists with `admin` in its
  `presets`, and `boards` must be `all`.

A 403 with `code` `permission_denied` reads as follows. Each message is two
clauses joined by a semicolon or a plain `but`:

- `board_id` null: `pomb answered 403: this token lacks the <permission>
  permission on every board`, a semicolon and `use a token that has it`. The
  `--admin` hint applies.
- `board_id` set: `this token has the <permission> permission but is not
  assigned to board <id>`, a semicolon and `add the board to the token`. No
  hint applies.

A board absent from `/api/boards` reads `board unavailable: pomb lists no board
named X for this token, which is assigned only to NAMES; if the board exists,
add it to the token` when `whoami` returns a `boards` list, else `board
unavailable: pomb has no board named X`.

### Reading the token

On a miss in the Keychain, `board/passlock.sh` reads the token with
`timeout 10 pass show <entry>`.

- environment: `PASSWORD_STORE_GPG_OPTS="--pinentry-mode error --batch"`.
- stdin: none, so a locked store fails at once with
  `board unavailable: pass is locked or has no entry <entry>`. A timeout says
  `board unavailable: pass timed out`.
- a token with any character outside `A-Za-z0-9._~+/=-` is refused without
  being shown.

The token reaches curl only as the config line `header = "Authorization:
Bearer ..."` on standard input (`curl -K -`, through `dev.os.capture_input`).
It is in no argument list, no environment variable, no file and no message.
`BASH_ENV`, `ENV`, `PS4` and `VERBOSE` are unset for `pass` and curl, so `-vv`
never traces them.

The response is read from a temporary file that `capture_input` removes.
