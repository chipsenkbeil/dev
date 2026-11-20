local text = require("dev.text")

---The board seam: the column names, the card helpers and the one interface the
---`dev board` commands call, which a backend implements.
---@class dev.board
local M = {}

-- dev.board.claims requires this module, so the require waits for the first call
local function claims_module()
    return require("dev.board.claims")
end

-- dev.cmd.board requires this module, so the require waits for the first call
local function cmd_board()
    return require("dev.cmd.board")
end

-- dev.board.wiring requires this module, so the require waits for the first call
local function wiring()
    return require("dev.board.wiring")
end

-- dev.board.land requires this module, so the require waits for the first call
local function land_module()
    return require("dev.board.land")
end

-- dev.board.check requires this module, so the require waits for the first call
local function check_module()
    return require("dev.board.check")
end

-- dev.board.review requires this module, so the require waits for the first call
local function review_module()
    return require("dev.board.review")
end

---@class dev.board.claim.Opts
---@field ttl integer the seconds a Pomb grab or a lease claim lasts
---@field fence integer? the caller's live fence, which renews the claim it names
---@field lease boolean? true when the claim lasts the ttl, false for the card-size minutes
---@field epic {done: integer, total: integer}? the card's children, which a Pomb grab refuses while open

---@class dev.board.Card
---@field id string the card's full id
---@field name string the card's title
---@field column string the name of the column it sits in
---@field lane string? the name of the swimlane it sits in, nil on a board with one lane
---@field done boolean? whether that column is one of finished cards
---@field size string the colour's palette label, or `unsized`
---@field color string? the colour's standard value (`yellow`, `green`, `blue`, `red`, `white`), nil
---   when the card has none
---@field labels string[] the card's labels
---@field description string? the card's description, nil when it has none
---@field claimant string? who holds the card while its owner lease is live
---@field claim_fence integer? the fence of that claim, nil when no claim is live
---@field responsible string? the session that is responsible, or `member ID` for a member account,
---   nil when none is set
---@field due string? the card's due date as `YYYY-MM-DD`, nil when none is set
---@field kind string? `epic` for an epic, `task` otherwise
---@field epic {done: integer, total: integer}? the children of an epic, nil when the card is not
---   one
---@field checks string[] the run commands in its checks rows, empty when it has none
---@field allow string[] the guard rails its allow field lifts, empty when it has none
---@field tests string[] the tests its tests field names, empty when it has none
---@field files string[] the files its files field names, empty when it has none
---@field outcomes dev.board.Outcome[] its Done when outcomes, empty when it has none
---@field outcomes_unreadable boolean? true when the board sent outcomes dev cannot read, so
---   `outcomes` may be short

---@class dev.board.Outcome
---@field id string the outcome's id
---@field name string what has to be true
---@field done boolean whether it is ticked

---@class dev.board.Event
---@field kind string `task_added`, `task_moved`, `task_updated` or `comment_added`
---@field task_id string the card it happened to
---@field column string? the name of the column the card sits in after the event, nil when it left
---   for another board
---@field from_column string? the name of the column a moved card left
---@field actor string? `human` for the owner and `agent` for a token, nil when Pomb did not say
---@field at integer? when it happened, in seconds since the epoch, nil when Pomb did not say

---@class dev.board.Events
---@field cursor string the cursor to send as `after` next
---@field events dev.board.Event[] the events, oldest first, empty when the wait timed out

---@class dev.board.ColumnRow
---@field name string the column's name
---@field is_done boolean whether a card in it counts as finished
---@field wip_limit integer? how many cards it holds at most, nil when it has no limit, and always
---   nil on a local board
---@field outcomes_locked boolean? whether the board refuses outcome changes on a card in it, nil
---   when the backend sends no such key and always nil on a local board

---@class dev.board.OutcomeFields
---@field name string? the new wording of the outcome
---@field done boolean? the new tick of the outcome

---@alias dev.board.FieldValue string|string[]|table<string, any>[]|dev.json.Null

---@class dev.board.card.Opts
---@field listed boolean? whether the card was resolved from a card word, so a closed epic carries no
---   child counts

---@class dev.board.cards.Opts
---@field summary boolean? read the paged task list, which leaves out the description, the outcomes
---   and the colour

---@class dev.board.Backend
---@field describe fun(self: dev.board.Backend): string the backend and board, as `status` prints
---   them
---@field card_url (fun(self: dev.board.Backend, id: string): string)? the link that opens the
---   card, nil on a board with no host
---@field done_columns fun(self: dev.board.Backend): string[]?, string? the names of the columns
---   marked finished, in board order, or nil and a message
---@field column_map table<string, string>? the `[board.columns]` map the runner resolves into
---   `stages`
---@field stages dev.board.Stages? the column set of this run, which the runner sets before a
---   command
---@field timed boolean? whether the board keeps time entries, false on a local board
---@field card fun(self: dev.board.Backend, id: string, opts: dev.board.card.Opts?): dev.board.Card?,
---   string? the card with that id, or nil and a message
---@field cards fun(self: dev.board.Backend, opts: dev.board.cards.Opts?): dev.board.Card[]?,
---   string? every card in column order, or nil and a message, from the paged task list when
---   `summary` is set
---@field lanes fun(self: dev.board.Backend): string[]?, string? the names of the lanes in board
---   order, empty on a board with fewer than two lanes, or nil and a message
---@field has_field fun(self: dev.board.Backend, key: string): boolean?, string? whether the board
---   defines the custom field with that key, or nil and a message
---@field next fun(self: dev.board.Backend, column: string, opts: dev.board.next.Opts?):
---   dev.board.Card?, string? the top unclaimed, unblocked card of that column without needs:human,
---   or nil and a message when it failed
---@field add fun(self: dev.board.Backend, name: string, column: string, opts: dev.board.add.Opts?):
---   dev.board.Card?, string?, boolean? the new card, or with `once` the open card of that name and
---   true when one existed
---@field entered fun(self: dev.board.Backend): table<string, string>?, string? the time each card
---   entered its column, as an RFC 3339 stamp by card id, or nil and a message
---@field set_size fun(self: dev.board.Backend, id: string, color: string, fence: integer?):
---   boolean?, string? the card given the palette colour of that value, checked against the claim's
---   fence when one is given
---@field set_due fun(self: dev.board.Backend, id: string, date: string?, fence: integer?):
---   boolean?, string? the card's due date set to that `YYYY-MM-DD` date, or cleared when the date
---   is nil, checked against the claim's fence when one is given
---@field set_labels fun(self: dev.board.Backend, id: string, labels: string[], fence: integer?):
---   boolean?, string? the card's whole label list replaced, checked against the claim's fence when
---   one is given
---@field add_outcome fun(self: dev.board.Backend, id: string, text: string, fence: integer?):
---   boolean?, string? an outcome appended to the card, checked against the claim's fence when one
---   is given
---@field set_outcome fun(self: dev.board.Backend, id: string, outcome: string,
---   fields: dev.board.OutcomeFields, fence: integer?): boolean?, string? the wording or the tick
---   of the outcome with that id changed, checked against the claim's fence when one is given
---@field delete_outcome fun(self: dev.board.Backend, id: string, outcome: string, fence: integer?):
---   boolean?, string? the outcome with that id removed from the card, checked against the claim's
---   fence when one is given
---@field set_description fun(self: dev.board.Backend, id: string, text: string, fence: integer?):
---   boolean?, string? the card's description replaced, checked against the claim's fence when one
---   is given
---@field set_name fun(self: dev.board.Backend, id: string, name: string, fence: integer?):
---   boolean?, string? the card's title replaced, checked against the claim's fence when one is
---   given
---@field set_checks fun(self: dev.board.Backend, id: string, runs: string[], fence: integer?):
---   boolean?, string? the card's checks rows replaced by one row per command, checked against the
---   claim's fence when one is given
---@field set_field fun(self: dev.board.Backend, id: string, key: string,
---   value: dev.board.FieldValue, fence: integer?): boolean?, string? the custom field with that
---   key replaced whole by the value, where json.null clears it, checked against the claim's
---   fence when one is given
---@field note fun(self: dev.board.Backend, id: string, body: string, fence: integer?,
---   opts: dev.board.note.Opts?): boolean?, string? a comment added to the card, of kind agent
---   unless opts names one, checked against the claim's fence when one is given
---@field log_time fun(self: dev.board.Backend, id: string, minutes: integer, role: string,
---   note: string?): boolean?, string? time logged on the card in the role, or nil and why not
---@field seat_verdict (fun(self: dev.board.Backend, id: string, seat: string, name: string,
---   verdict: string, revision: string): boolean?, string?, dev.board.SeatReason?)? the seat named
---   SEAT taken by NAME and answered with `approved` or `changes_needed` at the revision, or nil,
---   Pomb's refusal and `no_seat` when the card has no such seat and the token cannot add it, nil
---   on a board with no seats
---@field ask fun(self: dev.board.Backend, id: string, question: dev.board.Ask, fence: integer?):
---   boolean?, string? a structured question posted on the card, which Pomb moves to Blocked with
---   needs:human, or nil and Pomb's refusal
---@field answer fun(self: dev.board.Backend, id: string, choice: integer, quote: string,
---   fence: integer?): boolean?, string? the card's open question answered with the choice and the
---   owner's quote, so Pomb moves the card to that choice's column, or nil and a message
---@field comments fun(self: dev.board.Backend, id: string): dev.board.Comment[]?, string? the
---   card's comments, oldest first
---@field history fun(self: dev.board.Backend, id: string): dev.board.HistoryEvent[]?, string? the
---   card's history events, newest first
---@field dwell fun(self: dev.board.Backend): dev.board.Dwell[]?, string? the last move into Verify
---   and into Done of each Done card, read from one export, or nil and a message
---@field edit_note fun(self: dev.board.Backend, id: string, comment: string, body: string):
---   boolean?, string? the body of one of the caller's own comments replaced, or nil and a message
---@field delete_note fun(self: dev.board.Backend, id: string, comment: string): boolean?, string?
---   one of the caller's own comments deleted, or nil and a message
---@field bin? fun(self: dev.board.Backend, id: string): boolean?, string? the card moved to the
---   recycle bin, or nil and a message when the backend refuses
---@field binned? fun(self: dev.board.Backend): {id: string, name: string, restores_to: string}[]?,
---   string? the cards waiting in the recycle bin, or nil and a message
---@field restore? fun(self: dev.board.Backend, id: string): string?, string? the name of the column
---   the binned card came back to, or nil and a message
---@field link fun(self: dev.board.Backend, id: string, kind: string, other: string): boolean?,
---   string? a link of that kind
---   (`blocked_by`, `blocks`, `related` or `parent`, which names the other card as the epic) from
---   the card to the card with that full id, which may sit on another board; linking twice changes
---   nothing
---@field links fun(self: dev.board.Backend, id: string): dev.board.Link[]?, string? the links the
---   card holds plus a `blocks`, `related` or `child` entry for each link another card holds on it,
---   in the order the backend gives them
---@field unlink fun(self: dev.board.Backend, id: string, kind: string, other: string): boolean?,
---   string? the link of that kind from the card to the card with that full id removed, or nil and
---   a message when the card holds no such link or the backend refuses the change
---@field attachments fun(self: dev.board.Backend, id: string): dev.board.Attachment[]?, string? the
---   files the card holds, oldest first, or nil and a message
---@field attach fun(self: dev.board.Backend, id: string, path: string): dev.board.Attachment?,
---   string? the file at that path uploaded to the card, or nil and the backend's refusal as it
---   words it
---@field detach fun(self: dev.board.Backend, id: string, attachment: string): boolean?, string? the
---   attachment with that full id removed, or nil and a message
---@field set_responsible fun(self: dev.board.Backend, id: string, name: string?, fence: integer?): boolean?, string?
---   the card's responsible session set to that name, or cleared when the name is nil, checked
---   against the claim's fence when one is given, or nil and the backend's refusal
---@field make_epic fun(self: dev.board.Backend, id: string, fence: integer?): boolean?, string? the
---   card turned into an epic, checked against the claim's fence when one is given, or nil and the
---   backend's refusal, as for a card that is already an epic
---@field family fun(self: dev.board.Backend, id: string): dev.board.Family?, string? the card's
---   epic and the count of its children
---@field needs_human fun(self: dev.board.Backend): dev.board.HumanCard[]?, string[]|string? every
---   card labelled needs:human on the boards the token sees, newest column entry first, with the
---   names of the boards whose cards the token could not read, or nil and a message
---@field other_board fun(self: dev.board.Backend, name: string): dev.board.Backend?, string? the
---   backend of another board on the same server, or nil and a message
---@field boards fun(self: dev.board.Backend): string[]?, string? the names of the boards the token
---   sees, in the server's order, or nil and a message
---@field columns fun(self: dev.board.Backend, name: string?): dev.board.ColumnRow[]?, string? the
---   columns of the named board, or of this one when nil, in board order, or nil and a message
---@field wait fun(self: dev.board.Backend, after: string?, kinds: string[]?, timeout: integer?):
---   dev.board.Events?, string?, string?, boolean? the events after the cursor, oldest first, held
---   up to `timeout` seconds (50 when nil) until there is one; with no cursor it answers at once
---   with none and the board's current cursor. On an expired cursor it returns nil, a message and
---   the oldest cursor that still resumes, when Pomb holds too many open waits for the token it
---   returns nil, a message, nil and true, and on any other failure nil and a message
---@field move fun(self: dev.board.Backend, id: string, column: string, opts: dev.board.move.Opts?):
---   boolean?, string?, dev.board.MoveReason? the card moved to a column, or nil, a message and
---   `full` when Pomb refuses it at a limit, or nil, no message and `no_column` or `no_lane` when
---   the board lacks it, which `move_refusal` writes
---@field limits fun(self: dev.board.Backend, name: string?): dev.board.limits.Limits?, string? the
---   column and group limits the board holds, or those of the Pomb board named `name`, empty on a
---   board with none, or nil and a message
---@field claim fun(self: dev.board.Backend, id: string, claimant: string,
---   opts: dev.board.claim.Opts): integer?, string? the fence of the owner grab, renewed when the
---   caller's live fence is given
---@field release fun(self: dev.board.Backend, id: string, fence: integer): boolean?, string?,
---   dev.board.ReleaseReason?, string? the owner lease ended, or nil, a message, or for a fixed
---   refusal nil, no message, its reason and the detail the sentence names (the holder, or the
---   card id), which `release_refusal` writes
---@field keepalive fun(self: dev.board.Backend, id: string, fence: integer, ticks: integer,
---   state: string, name: string): integer?, string? the pid of a detached loop that renews the
---   owner lease every tick until the state file loses the fence or the ticks run out

---@class dev.board.Link
---@field kind string `blocked_by`, `blocks`, `related`, `parent` or `child`, as seen from the card
---@field id string the other card's full id
---@field board string? the other card's board name, nil for the card's own board

---@class dev.board.Attachment
---@field id string the attachment's full id
---@field name string the file name
---@field size integer the size in bytes

---@class dev.board.Family
---@field parent {id: string, name: string}? the epic the card is part of
---@field epic boolean whether the card is an epic, Pomb's kind epic or a card with children
---@field children dev.board.Children? how many of the card's children are done, nil when it has
---   none

---@class dev.board.Children
---@field done integer how many children are done
---@field total integer how many children there are
---@field items dev.board.Child[]? each child, when the backend lists them

---@class dev.board.Child
---@field id string the child's full id
---@field name string the child's title
---@field board string? the name of the child's board, nil on the epic's own board
---@field column string? the name of the child's column
---@field done boolean whether the child is done

---@class dev.board.HumanCard
---@field board string the name of the card's board
---@field id string the card's full id
---@field epic string the epic's name, `-` for none or unreadable
---@field name string the card's title
---@field entered string when the card entered its column, as an RFC 3339 stamp, empty when unknown

---@class dev.board.note.Opts
---@field kind string? the comment's kind, lowercase
---@field author string? the label the comment is written under

---@class dev.board.move.Opts
---@field fence integer? the claim fence the move is checked against
---@field position integer? the zero-based place in the column and lane, the top when nil
---@field lane string? the name of the lane to move the card to, its own lane when nil
---@field force boolean? whether Pomb skips the column and group limits, true for a trunk-blocker

---@class dev.board.Dwell
---@field id string the card's full id
---@field verify integer seconds since the epoch of the card's last move into Verify
---@field done integer seconds since the epoch of the card's last move into Done

---@class dev.board.HistoryEvent
---@field at string when it happened, as an RFC 3339 stamp
---@field kind string what it records, such as `moved`
---@field from string? the value it replaced, when it changed one
---@field to string? the value it set, when it changed one
---@field actor string who caused it, the account name or `api-token`
---@field token string? the name of the token that made it, nil for a browser session

---@class dev.board.Comment
---@field id string the comment's full id
---@field who string the token's name, else the kind of actor that wrote it
---@field at string when it was written, as an RFC 3339 stamp
---@field body string its text
---@field kind string? its kind tag, when it has one
---@field author string? the role label it was written under, when it has one
---@field actor string? the kind of actor that wrote it, `human` or `agent`, when known
---@field question dev.board.Question? the structured question the comment holds, with its answer
---   once given

---@class dev.board.Question
---@field text string the question
---@field answer table<string, any>? how the question was answered, nil while it is open

---@class dev.board.Ask
---@field text string? the question
---@field choices {label: string, column: string}[] the choices in order, each with the column the
---   card moves to
---@field recommended integer? the number of the recommended choice
---@field why string? why the agent cannot decide alone

---@class dev.board.next.Opts
---@field label string? the label the card must carry
---@field max_size integer? the most Pomodori the card may be, nil for any size
---@field lane string? the name of the lane the card must sit in

---@class dev.board.add.Opts
---@field description string? the card's description
---@field color string? the standard value of the palette colour to give it
---@field labels string[]? the labels to give it
---@field checks string[] the run commands to give it, one checks row each
---@field outcomes string[]? the Done when outcomes to give it, one subtask each
---@field epic boolean? whether to create it as an epic
---@field lane string? the name of the lane to put it in
---@field once boolean? whether to return the open card of that name instead of adding a second

---@class dev.board.Highlight
---@field label string the label to highlight
---@field color string the colour as `#rrggbb`

---@class dev.board.Layout
---@field add fun(self: dev.board.Layout, name: string, column: string, opts: dev.board.add.Opts?):
---   dev.board.Card?, string?, boolean? a card added, or with `once` the open card of that name and
---   true when one existed
---@field find fun(self: dev.board.Layout): boolean?, string? whether the board exists, or nil and a
---   message
---@field create fun(self: dev.board.Layout): boolean?, string? the board made, with the name of the
---   template it came from
---@field read fun(self: dev.board.Layout): dev.board.LayoutState?, string? the board's columns,
---   colours and cards
---@field add_column fun(self: dev.board.Layout, name: string, is_done: boolean): boolean?, string?
---   a column at the end
---@field rename_column fun(self: dev.board.Layout, id: string, name: string): boolean?, string? a
---   column given a new name, its cards kept
---@field move_column fun(self: dev.board.Layout, id: string, position: integer): boolean?, string?
---   a column moved, 0 first
---@field mark_done fun(self: dev.board.Layout, id: string): boolean?, string? a column made the one
---   of finished cards
---@field mark_blocked fun(self: dev.board.Layout, id: string): boolean?, string?, boolean? a column
---   made the one of cards waiting on an answer, third value true when it changed one
---@field set_stage fun(self: dev.board.Layout, id: string, stage: string): boolean?, string?,
---   boolean? a column given a stage, third value true when it wrote one
---@field lock_outcomes fun(self: dev.board.Layout, id: string): boolean?, string?, boolean? a column
---   that refuses outcome changes, third value true when it wrote the lock
---@field set_color fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?,
---   string? a colour's label, description, default flag or enabled flag
---@field add_highlights fun(self: dev.board.Layout, wanted: dev.board.Highlight[]): string[]|false|
---   nil, string? the labels highlighted by this call, empty when all were, false when the board
---   has no label settings, or nil and a message
---@field set_card fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?,
---   string? a card's name or colour
---@field add_checks_field fun(self: dev.board.Layout): boolean?, string? the checks field defined
---   on the board
---@field add_roles fun(self: dev.board.Layout): (string[]|false)?, string?, string? the standard
---   agent roles granted to the board, the names this call created, or false when the board has no
---   roles. A refusal for a missing permission names it in the third value, as `roles.grant`, or
---   `roles.unreadable` when the roles list could not be read
---@field limit_groups fun(self: dev.board.Layout): table<string, any>[]|false|nil, string? the
---   limit groups the board holds, false when the board has no limits to set, or nil and a message
---@field add_limit_group fun(self: dev.board.Layout, names: string[], limit: integer): boolean?,
---   string? the columns named made one limit group of cards
---@field add_lane fun(self: dev.board.Layout, name: string): boolean?, string? a lane made last in
---   the board's lane order

---@class dev.board.LayoutColumn
---@field id string the column's id
---@field name string the column's name
---@field is_done boolean whether a card in it counts as finished
---@field is_blocked boolean? whether it holds the cards waiting on an answer, nil when the backend
---   sends no such key
---@field stage string? the stage the column holds, nil when it holds none
---@field outcomes_locked boolean? whether the board refuses outcome changes on a card in it, nil
---   when the backend sends no such key

---@class dev.board.LayoutColor
---@field id string the colour's id
---@field value string the colour's palette value
---@field label string the colour's label
---@field description string the colour's description
---@field is_default boolean whether new cards take this colour
---@field enabled boolean whether the colour is in use

---@class dev.board.LayoutState
---@field columns dev.board.LayoutColumn[] the columns in board order
---@field colors dev.board.LayoutColor[] the palette
---@field cards {id: string, name: string, color_id: string?}[] every card
---@field has_checks boolean whether the board has the checks field
---@field lanes string[]? the names of the board's lanes in board order

---The key of the custom field that holds a card's checks.
M.CHECKS_FIELD = "dev.checks"

---The key of the custom field that holds the guard rails a card lifts.
M.ALLOW_FIELD = "dev.allow"

---The key of the custom field that holds the tests a tests card names.
M.TESTS_FIELD = "dev.tests"

---The key of the custom field that holds the files a card names.
M.FILES_FIELD = "dev.files"

---The words the allow field holds, in the order dev sends them.
M.ALLOW_WORDS = { "test-edits", "ci-edits" }

---The word that clears the allow field.
M.ALLOW_NONE = "none"

---The key of the checks table column that holds the command to run.
M.CHECKS_RUN = "run"

---The actors a comment or an owner can be, by role.
---@type {AGENT: string, HUMAN: string}
M.ACTOR = { AGENT = "agent", HUMAN = "human" }

---The reasons a move names beside its message when the refusal is a fixed one.
---@enum dev.board.MoveReason
M.MoveReason = { FULL = "full", NO_COLUMN = "no_column", NO_LANE = "no_lane" }

---The reason a seat verdict names beside its message when the card lacks the seat.
---@enum dev.board.SeatReason
M.SeatReason = { NO_SEAT = "no_seat" }

---The reasons a claim release names beside its message when the refusal is a fixed one.
---@enum dev.board.ReleaseReason
M.ReleaseReason = { HELD_BY_MEMBER = "held_by_member", NO_CARD = "no_card", NOT_HELD = "not_held" }

---Write why a move was refused, from the reason the backend named.
---@param reason dev.board.MoveReason? the reason the backend named
---@param why string? the backend's message, which a reason code leaves out
---@param column string the column of the move
---@param lane string? the lane of the move
---@return string message the text
function M.move_refusal(reason, why, column, lane)
    if reason == M.MoveReason.NO_COLUMN then
        return "The board has no " .. column .. " column. Run `dev board init`."
    elseif reason == M.MoveReason.NO_LANE then
        return "The board has no " .. lane .. " lane."
    end
    return text.sentence(why)
end

---Write why Pomb refused the seat verdict.
---@param reason dev.board.SeatReason? the reason the backend named
---@param why string the backend's message
---@param seat string the seat of the verdict
---@return string message the text
function M.seat_refusal(reason, why, seat)
    if reason == M.SeatReason.NO_SEAT then
        return string.format(
            "The card has no %s seat and this token cannot add one (%s). The claim adds the seats, so take the card with dev board take first.",
            seat,
            why
        )
    end
    return text.sentence(why)
end

---The fixed reasons a token file or claim state could not be used, named beside no message.
---@enum dev.board.FileReason
M.FileReason = {
    NO_HASHER = "no_hasher",
    HASH_FAILED = "hash_failed",
    MAKE_DIR = "make_dir",
    WRITE = "write",
    NOT_TOKEN_FILE = "not_token_file",
    DELETE = "delete",
    PROTECT = "protect",
}

---Write why a token file or claim state could not be used, from the reason.
---@param reason dev.board.FileReason? the fixed reason
---@param why string? the lower layer's message, which a reason code leaves out
---@param detail string? the path or directory the reason names
---@return string message the text
function M.file_refusal(reason, why, detail)
    local Reason = M.FileReason
    if reason == Reason.NO_HASHER then
        return "Neither shasum nor sha256sum is on PATH."
    elseif reason == Reason.HASH_FAILED then
        return "Could not hash the agent name."
    elseif reason == Reason.MAKE_DIR then
        return "Cannot make " .. detail .. "."
    elseif reason == Reason.WRITE then
        return "Cannot write " .. detail .. "."
    elseif reason == Reason.NOT_TOKEN_FILE then
        return "The token file " .. detail .. " is not a token file."
    elseif reason == Reason.DELETE then
        return "Cannot delete " .. detail .. "."
    elseif reason == Reason.PROTECT then
        return "Cannot protect " .. detail .. "."
    end
    return text.sentence(why)
end

---Write why a claim was not released, from the reason the backend named.
---@param reason dev.board.ReleaseReason? the reason the backend named
---@param why string? the backend's message, which a reason code leaves out
---@param detail string? the holder or the card id the backend named
---@param fence integer? the fence of the release
---@return string message the text
function M.release_refusal(reason, why, detail, fence)
    local Reason = M.ReleaseReason
    if reason == Reason.HELD_BY_MEMBER then
        return "The card is held by " .. detail .. ". Only that member can release it in Pomb."
    elseif reason == Reason.NO_CARD then
        return "The board has no card " .. detail .. "."
    elseif reason == Reason.NOT_HELD then
        return "The claim on " .. detail .. " is not held with fence " .. tostring(fence) .. "."
    end
    return text.sentence(why)
end

---The label of a card that waits on the owner, which `stale` lists apart at any age.
M.NEEDS_HUMAN = "needs:human"

---The label of a card that waits on a higher tier.
M.NEEDS_LEAD = "needs:lead"

---The label of a card whose plan a planner must check, which escalates to `needs:lead`.
M.NEEDS_PLANNER = "needs:planner"

---The Blocked escalation label that each `--for` word of `next` and `wait` matches.
M.BLOCKED_LABELS = { planner = M.NEEDS_PLANNER, lead = M.NEEDS_LEAD }

---The label `discard` puts on a card it drops, which a Done card may carry unticked.
M.DISCARDED = "discarded"

---The label of a run card, which holds a session's orders and never comes up as the next card.
M.RUN = "run"

---The label of a card whose change unblocks every landing, which skips the in-flight limits.
M.TRUNK_BLOCKER = "trunk-blocker"

---The label of a card that ships no change, which moves to Done with no proof.
M.NO_CHANGE = "no-change"

---The names in a multiline text field, one per line.
---@param value string|string[]|nil the field's value
---@return string[] names the non-blank lines, empty for any other value
function M.names(value)
    local names = {}
    if type(value) == "string" then
        for line in value:gmatch("[^\r\n]+") do
            if line:find("%S") then
                names[#names + 1] = line
            end
        end
    elseif type(value) == "table" then
        for _, name in ipairs(value) do
            if type(name) == "string" then
                names[#names + 1] = name
            end
        end
    end
    return names
end

---Find the newest question comment that nothing answers yet.
---@param comments dev.board.Comment[] the card's comments, oldest first
---@return dev.board.Comment? open the newest question, nil when none is open
function M.open_question(comments)
    for index = #comments, 1, -1 do
        local comment = comments[index]
        if comment.kind == M.NoteKind.QUESTION or comment.question then
            if comment.question and comment.question.answer then
                return nil
            end
            return comment
        end
        if comment.kind == M.NoteKind.DECISION or comment.actor == M.ACTOR.HUMAN then
            return nil
        end
    end
end

---Whether a card carries a label.
---@param card dev.board.Card the card
---@param label string the label to look for
---@return boolean
function M.labelled(card, label)
    for _, word in ipairs(card.labels or {}) do
        if word == label then
            return true
        end
    end
    return false
end

---The name of the card that holds the landing turn.
M.TURN_NAME = "landing turn"

---Check whether a card is the landing turn card, which no agent takes.
---@param card dev.board.Card the card
---@return boolean
function M.is_turn_card(card)
    return card.name == M.TURN_NAME
end

---Check that a name has the shape <repo>/<role>[/<card>].
---@param name string the agent name
---@return boolean
function M.agent_shape(name)
    local parts = 0
    for part in (name .. "/"):gmatch("([^/]*)/") do
        if not part:find("^[%w._-]+$") then
            return false
        end
        parts = parts + 1
    end
    return parts == 2 or parts == 3
end

---The role part of a name shaped <repo>/<role>[/<card>].
---@param name string? the agent name
---@return string? role the role, nil when the name has no role part
function M.agent_role(name)
    if type(name) ~= "string" or not M.agent_shape(name) then
        return nil
    end
    return name:match("^[^/]*/([^/]*)")
end

---The backends a project may name.
M.Backend = { POMB = "pomb", LOCAL = "local" }

---The kinds of card.
M.Kind = { EPIC = "epic", TASK = "task" }

---The kinds of link between two cards.
M.LinkKind = {
    BLOCKED_BY = "blocked_by",
    BLOCKS = "blocks",
    RELATED = "related",
    PARENT = "parent",
    CHILD = "child",
}

---The link kinds in the order help lists them.
M.LINK_KINDS = { M.LinkKind.BLOCKED_BY, M.LinkKind.BLOCKS, M.LinkKind.RELATED, M.LinkKind.PARENT }

---The fewest characters of a card id that name a card.
M.MIN_PREFIX = 8

---The comment kinds, with question sent only by `ask`.
M.NoteKind = {
    DECISION = "decision",
    QUESTION = "question",
    BLOCKED = "blocked",
    STATUS = "status",
    DONE = "done",
}

---The comment kinds `note --kind` accepts, in the order help lists them.
M.NOTE_KINDS = {
    M.NoteKind.DECISION,
    M.NoteKind.BLOCKED,
    M.NoteKind.STATUS,
    M.NoteKind.DONE,
}

---The most characters of the label `note --as` sends, which Pomb enforces.
M.AUTHOR_CHARS = 80

---The ending that marks an outcome as decided by the reviewer.
M.JUDGEMENT = "(reviewer judgement)"

---What opens the ending that names a checks row as an outcome's deciding check.
M.CHECK_OPEN = "(check: "

---The prefix of the comment `check` writes, which no note may begin with.
M.CHECK_PREFIX = "dev-check:"

---The prefix of the comment `review` writes, which no note may begin with.
M.REVIEW_PREFIX = "dev-review:"

M.TURN_PREFIX = "dev-turn:"

---The prefix of the comment a claim writes, which no note may begin with.
M.CLAIM_PREFIX = "dev-claim:"

---The prefix of the comment a tick writes, which no note may begin with.
M.TICK_PREFIX = "dev-tick:"

local RESERVED_PREFIXES =
    { M.CHECK_PREFIX, M.REVIEW_PREFIX, M.TURN_PREFIX, M.CLAIM_PREFIX, M.TICK_PREFIX }

---The body of the comment that keeps who ticked an outcome.
---@param name string the ticker's name
---@param number integer the outcome's number as `dev board show` lists it
---@return string body the comment body
function M.tick_record(name, number)
    return M.TICK_PREFIX .. " by=" .. name .. " outcome=" .. number
end

---The names that ticked an outcome, read from the card's tick comments.
---@param comments {body: string}[] the card's comments
---@return table<string, boolean> names every name with a tick comment
function M.tickers(comments)
    local names = {}
    for _, comment in ipairs(comments) do
        if comment.body:sub(1, #M.TICK_PREFIX) == M.TICK_PREFIX then
            local name = comment.body:sub(#M.TICK_PREFIX + 1):match("^ by=(%S+) outcome=%d+$")
            if name then
                names[name] = true
            end
        end
    end
    return names
end

---The body of the comment that keeps who took a card after the claim lapses.
---@param name string the claimant's name
---@return string body the comment body
function M.claim_record(name)
    return M.CLAIM_PREFIX .. " by=" .. name
end

---The names that took a card, read from its claim comments.
---@param comments {body: string}[] the card's comments
---@return table<string, boolean> names every name with a claim comment
function M.claimants(comments)
    local names = {}
    for _, comment in ipairs(comments) do
        if comment.body:sub(1, #M.CLAIM_PREFIX) == M.CLAIM_PREFIX then
            local name = comment.body:sub(#M.CLAIM_PREFIX + 1):match("^ by=(%S+)$")
            if name then
                names[name] = true
            end
        end
    end
    return names
end

---Return the name in the newest claim comment.
---@param comments {body: string}[] the card's comments, oldest first
---@return string? name the latest claimant, nil when no claim comment exists
function M.last_claimant(comments)
    local last
    for _, comment in ipairs(comments) do
        if comment.body:sub(1, #M.CLAIM_PREFIX) == M.CLAIM_PREFIX then
            last = comment.body:sub(#M.CLAIM_PREFIX + 1):match("^ by=(%S+)$") or last
        end
    end
    return last
end

---Say whether a comment body begins with a prefix only a dev verb writes.
---@param body string the comment body
---@return boolean reserved true when a note may not hold it
function M.reserved(body)
    local head = body:match("^%s*(.-)$"):lower()
    for _, prefix in ipairs(RESERVED_PREFIXES) do
        if head:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

---Say whether a note followed the claimant's claim record, posted by the token that wrote it.
---@param comments {who: string, body: string, kind: string?}[] the card's comments, oldest first
---@param claimant string the name the claim record holds
---@return boolean? noted nil when no claim record names the claimant
function M.noted_since_claim(comments, claimant)
    local record = M.claim_record(claimant)
    local at
    for i, comment in ipairs(comments) do
        if comment.body == record then
            at = i
        end
    end
    if not at then
        return nil
    end
    local who = comments[at].who
    for i = at + 1, #comments do
        local comment = comments[i]
        local decision = comment.kind == M.NoteKind.DECISION
        if comment.who == who and not decision and not M.reserved(comment.body) then
            return true
        end
    end
    return false
end

---Say whether a name posted a note after one of its claim records, so it did work on the card.
---@param comments {who: string, body: string, kind: string?}[] the card's comments, oldest first
---@param name string the name to look for
---@return boolean worked true when a note by the claim's poster follows a claim record of the name
function M.worked(comments, name)
    local record = M.claim_record(name)
    for at, comment in ipairs(comments) do
        if comment.body == record then
            for i = at + 1, #comments do
                local later = comments[i]
                if later.body:sub(1, #M.CLAIM_PREFIX) == M.CLAIM_PREFIX then
                    break
                end
                local decision = later.kind == M.NoteKind.DECISION
                if later.who == comment.who and not decision and not M.reserved(later.body) then
                    return true
                end
            end
        end
    end
    return false
end

local UNSIZED = "unsized"

---The size words a user may type, with the palette colour each names.
M.SIZES = { ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red", [UNSIZED] = "white" }

local SIZE_WORDS = { "1", "2", "3", "3+", UNSIZED }

local SIZE_RANKS =
    { [M.SIZES["1"]] = 1, [M.SIZES["2"]] = 2, [M.SIZES["3"]] = 3, [M.SIZES["3+"]] = 4 }

---The size limits a runner may set, as the word it types and the most Pomodori it covers.
---@type table<string, integer>
M.SIZE_LIMITS = { ["1"] = 1, ["2"] = 2, ["3"] = 3 }

---Report whether a card is no bigger than a runner's size limit.
---@param card dev.board.Card the card
---@param limit integer? the most Pomodori the runner takes, nil for no limit
---@return boolean fits true when there is no limit or the card is within it
function M.fits(card, limit)
    return limit == nil or (SIZE_RANKS[card.color] or 0) <= limit
end

---The stages a column map names, in board order.
M.STAGES = { "icebox", "backlog", "ready", "progress", "review", "verify", "release", "blocked" }

---The name each stage has when the config map does not rename it.
M.DEFAULT_NAMES = {
    icebox = "Icebox",
    backlog = "Backlog",
    ready = "Ready",
    progress = "In Progress",
    review = "Review",
    verify = "Verify",
    release = "Release",
    blocked = "Blocked",
    done = "Done",
}

---@class dev.board.Stages
---@field icebox string the column of free-form cards, which are never scaffolded or checked
---@field backlog string the column of new cards, which planners size and split
---@field ready string the column a worker takes cards from
---@field progress string the column of cards being worked, where a move keeps a claim's loop alive
---@field review string the column of cards waiting for review
---@field verify string the column of cards waiting for a verifier
---@field release string the column of cards on main, not yet deployed or installed
---@field blocked string the column of cards that wait on the owner
---@field done string? the mapped column of finished cards, nil when the config names none
---@field finished string[] the names of the columns the backend marks finished, in board order
---@field list string[] the column names in board order, the mapped or default Done last
---@field stale table<string, boolean> the columns where a card that sits untouched is stale
local Stages = {}
Stages.__index = Stages

---Resolve the column set of one command run.
---@param map table<string, any>? the `[board.columns]` table, keyed by stage
---@param finished string[]? the names of the columns the backend marks finished
---@return dev.board.Stages
function M.stages(map, finished)
    map = map or {}
    local stages = setmetatable({ finished = finished or {} }, Stages)
    local list = {}
    for _, stage in ipairs(M.STAGES) do
        local name = map[stage]
        stages[stage] = type(name) == "string" and name ~= "" and name or M.DEFAULT_NAMES[stage]
        list[#list + 1] = stages[stage]
    end
    local done = map.done
    if type(done) == "string" and done ~= "" then
        stages.done = done
    end
    list[#list + 1] = stages.done or stages.finished[1] or M.DEFAULT_NAMES.done
    stages.list = list
    stages.stale = {
        [stages.backlog] = true,
        [stages.ready] = true,
        [stages.progress] = true,
        [stages.review] = true,
        [stages.verify] = true,
    }
    return stages
end

---Point `backend` at a `columns` map, a `root` and its stages.
---@param backend dev.board.Backend the backend to retarget
---@param columns table<string, string>? the `[board.columns]` map the runner resolves into
---@param root string? the project root the board's config lives under
---@param finished string[]? the names of the columns the backend marks finished
function M.retarget(backend, columns, root, finished)
    backend.column_map = columns
    backend.stages = M.stages(columns, finished)
    backend.root = root
end

---The column `discard` moves a card to: the mapped done column, else the first finished one.
---@return string
function Stages:done_column()
    return self.done or self.finished[1] or M.DEFAULT_NAMES.done
end

---Name a column from its full name or a stage name, in any case.
---@param word string `ready`, `progress`, `Review`, a finished column's name and so on
---@return string? column the column's name, or nil when it is not one of the board's
function Stages:column(word)
    local lowered = word:lower():gsub("%s+", " ")
    for _, stage in ipairs(M.STAGES) do
        if stage == lowered then
            return self[stage]
        end
    end
    if lowered == "done" then
        return self:done_column()
    end
    for _, name in ipairs(self.list) do
        if name:lower() == lowered then
            return name
        end
    end
    for _, name in ipairs(self.finished) do
        if name:lower() == lowered then
            return name
        end
    end
end

---List the column names a user may type.
---@return string names the column names and the stage words
function Stages:help()
    local names, seen = {}, {}
    for _, name in ipairs(self.list) do
        names[#names + 1] = name
        seen[name] = true
    end
    for _, name in ipairs(self.finished) do
        if not seen[name] then
            names[#names + 1] = name
        end
    end
    return table.concat(names, ", ") .. " (or a stage such as progress or review, in any case)"
end

---Name a palette colour from a size word.
---@param word string `1`, `2`, `3`, `3+` or `unsized`
---@return string? color the colour's standard value, nil when the word is not a size
function M.size_color(word)
    return M.SIZES[word:lower()]
end

---List the size words a user may type.
---@return string words the five size words
function M.size_help()
    return table.concat(SIZE_WORDS, ", ")
end

---Tell whether a card has the colour a size word names, where no colour counts as white.
---@param card dev.board.Card the card
---@param color string the colour's standard value
---@return boolean
function M.has_color(card, color)
    return (card.color or M.SIZES[UNSIZED]) == color
end

---Find the card, or other item with an id, that an id or a unique prefix of it names.
---@generic T: {id: string}
---@param items T[] the board's cards, or a card's comments
---@param word string the id or a prefix of at least 8 characters
---@param noun string? what the items are called in a message, `card` by default
---@return T? item the item
---@return string? message why no item matched
function M.resolve(items, word, noun)
    noun = noun or "card"
    local prefix = word:lower()
    if #prefix < M.MIN_PREFIX or not prefix:find("^[%x-]+$") then
        return nil,
            ("A %s id needs at least %d hex characters: %s."):format(noun, M.MIN_PREFIX, word)
    end
    local found
    for _, item in ipairs(items) do
        if item.id:lower():sub(1, #prefix) == prefix then
            if item.id:lower() == prefix then
                return item
            end
            if found then
                return nil,
                    "More than one " .. noun .. " starts with " .. word .. ". Give more characters."
            end
            found = item
        end
    end
    if not found then
        return nil, "No " .. noun .. " starts with " .. word .. "."
    end
    return found
end

---The required headings of card format v4, in order.
M.HEADINGS = { "Problem", "Change", "Out of scope" }

---The optional heading of card format v4, after Out of scope.
M.SOURCE = "Source"

---The fewest and the most Done when outcomes a planned card has.
M.MIN_OUTCOMES = 3
M.MAX_OUTCOMES = 7
M.MIN_EPIC_OUTCOMES = 1
M.MAX_EPIC_OUTCOMES = 3

local PROBLEM = M.HEADINGS[1]
local CHANGE = M.HEADINGS[2]
local OUT_OF_SCOPE = M.HEADINGS[3]
local DONE_WHEN = "Done when"

---The start of a refusal for a section with no text.
M.TEXT_UNDER = "text under ## "

---The refusal for a Problem that holds a Change or Out of scope line.
M.MISPLACED = "a " .. PROBLEM .. " free of " .. CHANGE .. ": and " .. OUT_OF_SCOPE .. ": lines"

---The line patterns that mark a Change or Out of scope line misplaced in a Problem.
local MISPLACED_LINES = { "^%s*" .. CHANGE .. ":", "^%s*" .. OUT_OF_SCOPE .. ":" }

local function lines_of(description)
    return ((description or "") .. "\n"):gmatch("(.-)\n")
end

local function heading_of(line)
    return line:match("^##%s+(.-)%s*$")
end

---Give a description the three v3 headings, filling Problem from the text given. A text that
---already holds a v3 heading or the v1 Done when heading is kept as it is.
---@param description string? the text the caller gave, if any
---@return string description the text with the headings
function M.scaffold(description)
    local given = (description or ""):match("^%s*(.-)%s*$")
    for line in lines_of(given) do
        local name = heading_of(line)
        if name == DONE_WHEN then
            return given
        end
        for _, heading in ipairs(M.HEADINGS) do
            if name == heading then
                return given
            end
        end
    end
    local parts = {}
    for i, heading in ipairs(M.HEADINGS) do
        parts[i] = "## " .. heading .. "\n" .. (i == 1 and given ~= "" and given .. "\n" or "")
    end
    return table.concat(parts, "\n")
end

local HEX_MIN = 7

local function is_url(word)
    return word:find("^%a[%w+.-]*://") ~= nil
end

local function is_path(word)
    if not word:find("/", 1, true) then
        return false
    end
    if word:find("^/[^/]*$") and not word:find("%.%a[%w]*$") then
        return false
    end
    if word:find("^~/%S") or word:find("^%./%S") or word:find("^/[^/%s]") then
        return true
    end
    return word:find("%.%a[%w]*$") ~= nil
end

local function is_hex_id(run)
    return #run >= HEX_MIN
        and run:find("^%x+$") ~= nil
        and run:find("%d") ~= nil
        and run:find("%a") ~= nil
        and run:find("^%d+[eE]%d+$") == nil
end

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local MOSTLY_IDS_MIN_WORDS = 4

---Say whether a comment is mostly ids: at least 4 words, more than half of them a hex id of 7 or
---more digits, a uuid, or a word holding a slash or a file extension.
---@param comment string the comment
---@return boolean mostly true when the comment should be refused
function M.mostly_ids(comment)
    local words, ids = 0, 0
    for raw in comment:gmatch("%S+") do
        words = words + 1
        local word = raw:gsub("^[%(%[<\"'`]+", ""):gsub("[%)%]>\"'`,;:!?.]+$", "")
        if
            word:find(UUID_PATTERN)
            or is_hex_id(word)
            or word:find("/", 1, true)
            or word:find("%.%a[%w]*$")
        then
            ids = ids + 1
        end
    end
    return words >= MOSTLY_IDS_MIN_WORDS and ids * 2 > words
end

local function is_land_line(line)
    return line:find("^Landed commit %x+ ") ~= nil
        or line:find("^landed %x+ on [^%s/]+/main") ~= nil
end

---Warn about the hex ids, hashes and paths in prose. Text under a `## Change` or `## Source`
---heading is left out, and so is a URL and a line that starts the way a land note does.
---@param prose string? the description or note
---@return string[] warnings one line per offending word, in order, without repeats
function M.prose_warnings(prose)
    local warnings, seen, in_change = {}, {}, false
    local function warn(kind, word)
        local line = "Card prose holds " .. kind .. ": " .. word .. "."
        if not seen[line] then
            seen[line] = true
            warnings[#warnings + 1] = line
        end
    end
    for line in lines_of(prose) do
        local name = heading_of(line)
        if name then
            in_change = name == CHANGE or name == M.SOURCE
        elseif not in_change and not is_land_line(line) then
            for raw in line:gmatch("%S+") do
                local word = raw:gsub("^[%(%[<\"'`]+", ""):gsub("[%)%]>\"'`,;:!?.]+$", "")
                if is_url(word) then
                    word = ""
                elseif is_path(word) then
                    warn("a path", word)
                    word = ""
                end
                for run in word:gmatch("%w+") do
                    if is_hex_id(run) then
                        warn("a hex id or hash", run)
                    end
                end
            end
        end
    end
    return warnings
end

---Split a v1 `## Done when` checklist off a description: the `- [ ]` and `- [x]` items under that
---heading, and the description without the heading and those items.
---@param description string? the card's description
---@return {name: string, done: boolean}[]? items the checklist items in order, nil when there are
---   none
---@return string? rest the description without the heading and the items
function M.split_checklist(description)
    local items, kept, current, cut = {}, {}, nil, false
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
        end
        local mark, label
        if current == DONE_WHEN and not name then
            mark, label = line:match("^%s*[-*]%s%[([ xX])%]%s+(%S.-)%s*$")
        end
        if mark then
            items[#items + 1] = { name = label, done = mark ~= " " }
            cut = true
        elseif name == DONE_WHEN then
            cut = true
        else
            local blank = not line:find("%S")
            if not (cut and blank and (#kept == 0 or not kept[#kept]:find("%S"))) then
                kept[#kept + 1] = line
            end
            cut = cut and blank
        end
    end
    if #items == 0 then
        return nil
    end
    local rest = table.concat(kept, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return items, rest
end

local function sections(description)
    local seen, filled, current = {}, {}, nil
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
            seen[name] = true
        elseif current and line:find("%S") then
            filled[current] = true
        end
    end
    return seen, filled
end

---Build a card format v4 description from the text of each section.
---@param problem string? the Problem text
---@param change string? the Change text
---@param out_of_scope string? the Out of scope text
---@param source string? the Source text, left out of the description when blank
---@return string description the three headings with their text, then Source when it has text
function M.compose(problem, change, out_of_scope, source)
    local texts = { problem, change, out_of_scope }
    local parts = {}
    for i, heading in ipairs(M.HEADINGS) do
        local body = (texts[i] or ""):match("^%s*(.-)%s*$")
        parts[i] = "## " .. heading .. "\n" .. (body ~= "" and body .. "\n" or "")
    end
    local quote = (source or ""):match("^%s*(.-)%s*$")
    if quote ~= "" then
        parts[#parts + 1] = "## " .. M.SOURCE .. "\n" .. quote .. "\n"
    end
    return table.concat(parts, "\n")
end

---The card fields that render as a block of list lines, in the order of the rendering.
M.BLOCK_FIELDS = { "checks", "allow", "tests", "files" }

---The outcomes block name and the block names of the list fields, which a description never holds.
local RENDERED_BLOCKS = { ["done when:"] = true }
for _, field in ipairs(M.BLOCK_FIELDS) do
    RENDERED_BLOCKS[field .. ":"] = true
end

---Find the first line of a description that is exactly a rendered block name.
---@param description string? the card's description
---@return string? line the block line, nil when the text holds none
function M.rendered_blocks(description)
    for line in (description or ""):gmatch("[^\n]+") do
        if RENDERED_BLOCKS[line] then
            return line
        end
    end
    return nil
end

---List what a card lacks of card format v3 outside Icebox: each missing heading, and Problem text.
---@param description string? the card's description
---@return string[] missing the problems, empty when the card follows the format outside Icebox
function M.backlog_missing(description)
    local seen, filled = sections(description)
    local missing = {}
    for _, heading in ipairs(M.HEADINGS) do
        if not seen[heading] then
            missing[#missing + 1] = "## " .. heading
        end
    end
    local problem = M.HEADINGS[1]
    if seen[problem] and not filled[problem] then
        missing[#missing + 1] = M.TEXT_UNDER .. problem
    end
    return missing
end

---List the shapes card format v3 refuses outside Icebox: a Change or Out of scope section with no
---text under it, and a Problem text with a line that starts `Change:` or `Out of scope:`.
---@param description string? the card's description
---@return string[] shapes the problems, empty when the sections have the right shape
function M.shapes(description)
    local seen, filled = sections(description)
    local shapes = {}
    for _, heading in ipairs({ CHANGE, OUT_OF_SCOPE, M.SOURCE }) do
        if seen[heading] and not filled[heading] then
            shapes[#shapes + 1] = M.TEXT_UNDER .. heading
        end
    end
    local current, misplaced = nil, false
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
        elseif current == PROBLEM then
            for _, pattern in ipairs(MISPLACED_LINES) do
                misplaced = misplaced or line:find(pattern) ~= nil
            end
        end
    end
    if misplaced then
        shapes[#shapes + 1] = M.MISPLACED
    end
    return shapes
end

---@class dev.board.Unplanned
---@field color string? the card's colour
---@field description string? the card's description
---@field outcomes integer how many outcomes it has
---@field need_outcomes boolean whether it needs one
---@field closing boolean? whether an epic with every child Done is closing
---@field children integer how many children it has, 0 for a card that is no epic
---@field epic boolean? whether it is an epic even with no children
---@field sections boolean? whether the v3 sections are checked, true when nil
---@field shapes boolean? whether an empty section and a misplaced line are checked with the
---   sections, true when nil

---The refusal for an epic whose outcome count is out of range.
---@param outcomes integer? how many outcomes the epic has, left off the text when nil
---@return string problem the epic rule, with the count when given
local function epic_outcomes_text(outcomes)
    local rule = M.MIN_EPIC_OUTCOMES
        .. " to "
        .. M.MAX_EPIC_OUTCOMES
        .. " Done when outcomes for an epic"
    if outcomes == nil then
        return rule
    end
    return rule .. ", not " .. outcomes
end

---List what a card outside Icebox lacks: a size of 1, 2, 3 or 3+, each v3 section with text under
---Problem, no empty Change or Out of scope section and no misplaced line under Problem, and, when
---asked, at least one Done when outcome. An epic, a card with children, needs 1 to 3 outcomes as
---its final check, unless it is closing with every child Done.
---@param card dev.board.Unplanned the card's size, description and outcome facts
---@return string[] missing the problems, empty when the card may sit outside Icebox
function M.unplanned(card)
    local color, description = card.color, card.description
    local missing = {}
    if color == nil or color == M.SIZES[UNSIZED] then
        missing[1] = "a size"
    end
    if card.sections ~= false then
        for _, item in ipairs(M.backlog_missing(description)) do
            missing[#missing + 1] = item
        end
        if card.shapes ~= false then
            for _, shape in ipairs(M.shapes(description)) do
                missing[#missing + 1] = shape
            end
        end
    end
    if card.need_outcomes then
        if card.outcomes == 0 and not card.closing then
            if card.children == 0 then
                missing[#missing + 1] = "Done when outcomes"
            end
        elseif
            (card.children > 0 or card.epic)
            and card.outcomes > M.MAX_EPIC_OUTCOMES
            and not card.closing
        then
            missing[#missing + 1] = epic_outcomes_text(card.outcomes)
        end
    end
    return missing
end

---Count the children of a card that are not Done.
---@param children {done: integer, total: integer}? the card's children, nil when it has none
---@return integer open how many children are open
function M.open_children(children)
    if not children then
        return 0
    end
    return children.total - children.done
end

---Check whether an epic has children and every one of them is Done.
---@param children {done: integer, total: integer}? the epic's children, nil when it has none
---@return boolean closed true when it has children and none is open
function M.children_closed(children)
    return children ~= nil and children.total > 0 and M.open_children(children) == 0
end

---The mark an epic carries before its name in a listing.
---@param card dev.board.Card the card
---@return string mark `[epic]` with the open-children count when there are children, else empty
function M.epic_mark(card)
    local epic = card.epic
    if not epic then
        return ""
    end
    if epic.total == 0 then
        return "[epic] "
    end
    return "[epic " .. M.open_children(epic) .. " of " .. epic.total .. " open] "
end

---List the required rows a card's checks lack.
---
---A checks row satisfies a required row when it equals it or starts with it and a space.
---@param checks string[] the card's checks rows
---@param required string[] the rows the project requires
---@return string[] missing the required rows no checks row satisfies
function M.missing_rows(checks, required)
    local missing = {}
    for _, row in ipairs(required) do
        local held = false
        for _, check in ipairs(checks) do
            if check == row or check:sub(1, #row + 1) == row .. " " then
                held = true
            end
        end
        if not held then
            missing[#missing + 1] = row
        end
    end
    return missing
end

---List the outcomes that name no deciding check.
---
---An outcome names one by ending with `CHECK_OPEN`, a ROW and a closing parenthesis, where ROW is
---a non-blank substring of one of the checks rows, or with `JUDGEMENT`.
---@param outcomes dev.board.Outcome[] the card's outcomes
---@param checks string[] the card's checks rows
---@return string[] unnamed the names of the outcomes with neither ending, or a ROW no row holds
function M.unnamed_checks(outcomes, checks)
    local unnamed = {}
    local pattern = M.CHECK_OPEN:gsub("%p", "%%%0") .. "(.+)%)$"
    for _, outcome in ipairs(outcomes) do
        local name = outcome.name:gsub("%s+$", "")
        local row = name:match(pattern)
        row = row and row:match("^%s*(.-)%s*$")
        local named = name:sub(-#M.JUDGEMENT) == M.JUDGEMENT
        for _, check in ipairs(checks) do
            if row and row ~= "" and check:find(row, 1, true) then
                named = true
            end
        end
        if not named then
            unnamed[#unnamed + 1] = outcome.name
        end
    end
    return unnamed
end

---List what a card lacks of card format v3 to enter Ready: each missing or empty section, and
---Done when outcomes. The outcomes are 3 to 7 subtasks, or 1 to 3 for an epic.
---@param description string? the card's description
---@param outcomes integer how many outcomes the card has
---@param children integer how many children the card has
---@param epic boolean? whether the card is an epic even with no children
---@return string[] missing the problems, empty when the card follows the format
function M.missing(description, outcomes, children, epic)
    local seen, filled = sections(description)
    local missing = {}
    for _, heading in ipairs(M.HEADINGS) do
        if not seen[heading] then
            missing[#missing + 1] = "## " .. heading
        elseif heading == PROBLEM and not filled[heading] then
            missing[#missing + 1] = M.TEXT_UNDER .. heading
        end
    end
    for _, shape in ipairs(M.shapes(description)) do
        missing[#missing + 1] = shape
    end
    if children > 0 or epic then
        if outcomes == 0 then
            if children == 0 then
                missing[#missing + 1] = epic_outcomes_text()
            end
        elseif outcomes > M.MAX_EPIC_OUTCOMES then
            missing[#missing + 1] = epic_outcomes_text(outcomes)
        end
    elseif outcomes == 0 then
        missing[#missing + 1] = M.MIN_OUTCOMES .. " to " .. M.MAX_OUTCOMES .. " Done when outcomes"
    elseif outcomes > 0 and (outcomes < M.MIN_OUTCOMES or outcomes > M.MAX_OUTCOMES) then
        missing[#missing + 1] = M.MIN_OUTCOMES
            .. " to "
            .. M.MAX_OUTCOMES
            .. " Done when outcomes, not "
            .. outcomes
    end
    return missing
end

---Show the label for a card's colour.
---@param label string? the palette label, nil when the card has no colour
---@return string size the label or `unsized`
function M.size(label)
    if label == nil or label == "" then
        return UNSIZED
    end
    return label
end

---Count the ticked outcomes of a card as `done/total`.
---@param card dev.board.Card the card
---@return string ticks `1/3`, or `-` when the card has no outcomes
function M.ticks(card)
    local total, ticked = #card.outcomes, 0
    for _, outcome in ipairs(card.outcomes) do
        if outcome.done then
            ticked = ticked + 1
        end
    end
    return total > 0 and ticked .. "/" .. total or "-"
end

---Say a card in one line.
---@param card dev.board.Card the card
---@param opts {holders: boolean?, progress: boolean?, lanes: boolean?}? `holders` adds the claim
---   holder before the name, `progress` the ticked outcomes before the holder, `lanes` the lane
---   after the column
---@return string[] cells id prefix, column, the lane when asked for, size, labels, the ticks and
---   the holder when asked for, and name
function M.cells(card, opts)
    opts = opts or {}
    local labels = #card.labels > 0 and table.concat(card.labels, ",") or "-"
    local cells = { card.id:sub(1, M.MIN_PREFIX), card.column }
    if opts.lanes then
        cells[#cells + 1] = card.lane or "-"
    end
    cells[#cells + 1] = card.size
    cells[#cells + 1] = labels
    if opts.progress then
        cells[#cells + 1] = M.ticks(card)
    end
    if opts.holders then
        cells[#cells + 1] = card.claimant or "-"
    end
    cells[#cells + 1] = M.epic_mark(card) .. card.name
    return cells
end

---Pad rows into aligned columns, with no trailing spaces.
---@param rows string[][] the cells of each row
---@return string[] lines one line per row
function M.table_lines(rows)
    local widths = {}
    for _, row in ipairs(rows) do
        for c, value in ipairs(row) do
            widths[c] = math.max(widths[c] or 0, text.width(value))
        end
    end
    local lines = {}
    for r, row in ipairs(rows) do
        local parts = {}
        for c, value in ipairs(row) do
            parts[c] = c < #row and value .. string.rep(" ", widths[c] - text.width(value)) or value
        end
        lines[r] = table.concat(parts, text.GAP):gsub(" +$", "")
    end
    return lines
end

---A project's board, which a verb finds from a workspace.
---@class dev.board.Board
---@field backend dev.board.Backend the backend behind it
local Board = {}
Board.__index = Board

---One card on a board.
---@class dev.board.CardHandle
---@field board dev.board.Board the board it is on
---@field card dev.board.Card the card
local CardHandle = {}
CardHandle.__index = CardHandle

---Find the board a workspace's project configures.
---@param workspace dev.scm.Workspace the checkout a verb works in
---@return dev.board.Board? found the board
---@return string? message why the project has none
function M.find(workspace)
    local backend, message = cmd_board().backend_at(workspace.root)
    if not backend then
        return nil, message
    end
    M.retarget(backend, backend.column_map, backend.root, backend:done_columns() or {})
    return setmetatable({ backend = backend }, Board)
end

---Find the card an id or a unique prefix of one names.
---@param word string the id or a prefix of at least 8 characters
---@return dev.board.CardHandle? card the card
---@return string? message why no card matched
function Board:find_card(word)
    local cards, message = self.backend:cards()
    if not cards then
        return nil, message
    end
    local card, why = M.resolve(cards, word)
    if not card then
        return nil, why
    end
    return setmetatable({ board = self, card = card }, CardHandle)
end

---Name the column a landed card waits in for a deploy.
---@return string column the release column
function Board:release_column()
    return self.backend.stages.release
end

---Name the column a finished card moves to.
---@return string column the done column
function Board:done_column()
    return self.backend.stages:done_column()
end

---Name why the card cannot land, without landing it.
---
---The reasons are its column, its claimant, its open outcomes, its check, its reviews and the files
---its commit touches. The agent is the one `DEV_AGENT` names, and a moved trunk is no reason, since
---landing rebases.
---@param ignore_change_run string? the reason to land past a failed gerrit change run
---@return string? problem every reason in one text, nil when the card may land
function CardHandle:land_problem(ignore_change_run)
    local backend = self.board.backend
    local comments, message = backend:comments(self.card.id)
    if not comments then
        return text.sentence(message)
    end
    local problems = wiring().land_problems(backend, self.card, {
        name = os.getenv("DEV_AGENT") or "",
        comments = comments,
        untaken = true,
        ignore_change_run = ignore_change_run,
    })
    if #problems == 0 then
        return nil
    end
    return table.concat(problems, " ")
end

---Copy the rows of the newest passing run recorded at a commit, under the card's own commands.
---@param comments {body: string}[] the card's comments, oldest first
---@param at {commit: string, rows: string[]} the checked commit and the card's checks rows
---@return dev.board.check.Row[]? rows the copied rows, nil when no record at the commit fits
local function copied_check(comments, at)
    local check = check_module()
    for i = #comments, 1, -1 do
        local record = check.parse(comments[i].body)
        if
            record
            and record.mode == check.Mode.RUN
            and record.commit == at.commit
            and #record.rows == #at.rows
        then
            local copied = {}
            for n, row in ipairs(record.rows) do
                copied[n] = {
                    run = at.rows[n],
                    result = row.result,
                    run_id = row.run_id,
                    reason = row.reason,
                }
            end
            return copied
        end
    end
end

---Write the review records of a checked commit anew for another commit of the same change.
---@param comments {body: string}[] the card's comments, oldest first
---@param carried string the checked commit
---@param state dev.board.check.State the commit the records are written for
---@return string[] bodies the record bodies, one per review that carries a verdict
local function copied_reviews(comments, carried, state)
    local review = review_module()
    local bodies = {}
    for _, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if record and record.commit == carried and record.verdict then
            bodies[#bodies + 1] = review.record(
                record.kind,
                record.by,
                { commit = state.commit, change = state.change },
                record.verdict,
                record.of
            )
        end
    end
    return bodies
end

---Write the card's check and reviews onto the commit the working copy holds.
---
---A rebase after `dev board check` gives the commit a new id, and the guard on a move into Release
---or Done wants a record at the commit it reads. This finds the checked commit `dev land` would
---carry the records over from, with the same rules, and notes a copy of its check and reviews for
---the working-copy commit. Call it after the rebase and before the push, since a jj merge leaves
---the working copy empty. It writes nothing when the commit has its own records, and the guard
---stays as strict as before.
---@return boolean? ok true when the commit is proven now, by its own records or by a carry
---@return string? message why no record was written
function CardHandle:carry_proof()
    local backend = self.board.backend
    local root = backend.root
    local land = land_module()
    local state, why = land.state(root)
    if not state then
        return nil, text.sentence(why)
    end
    local comments, message = backend:comments(self.card.id)
    if not comments then
        return nil, text.sentence(message)
    end
    local rows = self.card.checks or {}
    local carried, carry_why, check_only = land.carry({
        root = root,
        comments = comments,
        state = state,
        rows = rows,
    })
    if not carried then
        if carry_why then
            return nil, carry_why
        end
        local lacking = land.missing_reviews(comments, state, root)
        local unproven = land.checks_problem(comments, state, rows)
        if #lacking == 0 and not unproven then
            return true
        end
        return nil, unproven or lacking[1]
    end
    local held = claims_module().read(self.card.id)
    local fence = held and held.fence
    local function write(body)
        local noted, why_not = backend:note(self.card.id, body, fence)
        if not noted then
            return text.sentence(why_not)
        end
    end
    local copied = copied_check(comments, { commit = carried, rows = rows })
    if not copied then
        return nil, "The checked commit's record could not be read."
    end
    local failed = write(check_module().record(state, copied, false))
    if failed then
        return nil, failed
    end
    if check_only then
        local lacking = land.missing_reviews(comments, state, root)
        return #lacking == 0 or nil, lacking[1]
    end
    for _, body in ipairs(copied_reviews(comments, carried, state)) do
        failed = write(body)
        if failed then
            return nil, failed
        end
    end
    return true
end

---Move the card to a column.
---
---A move into Release or Done is refused unless the card's check, reviews and outcomes prove it,
---read at the commit `state` names, or at the working-copy commit when it is nil. Pass `state`
---when the working copy no longer holds the change to prove, such as after a merge.
---@param column string the column's name
---@param state dev.board.check.State? the commit to prove, read before the merge
---@return boolean? ok true when the card moved
---@return string? message why it did not
function CardHandle:move_to(column, state)
    local opts
    if state then
        opts = {
            state = function()
                return state
            end,
        }
    end
    local result = cmd_board().move(self.board.backend, { self.card.id, column }, opts)
    if result.code then
        return nil, result.message
    end
    return true
end

---Move the card to the release column.
---@param state dev.board.check.State? the commit to prove, as `move_to` takes it
---@return boolean? ok true when the card moved
---@return string? message why it did not
function CardHandle:move_to_release(state)
    return self:move_to(self.board:release_column(), state)
end

---Move the card to the done column.
---@param state dev.board.check.State? the commit to prove, as `move_to` takes it
---@return boolean? ok true when the card moved
---@return string? message why it did not
function CardHandle:move_to_done(state)
    return self:move_to(self.board:done_column(), state)
end

return M
