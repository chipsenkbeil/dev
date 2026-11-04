local text = require("dev.text")

---The board seam: the column names, the card helpers and the one interface the
---`dev board` commands call, which a backend implements.
---@class dev.board
local M = {}

---@class dev.board.ClaimOpts
---@field lease boolean? true when the claim lasts the ttl, false for the card-size minutes

---@class dev.board.Card
---@field id string the card's full id
---@field name string the card's title
---@field column string the name of the column it sits in
---@field done boolean? whether that column is one of finished cards
---@field size string the colour's palette label, or `unsized`
---@field color string? the colour's standard value (`yellow`, `green`, `blue`, `red`, `white`), nil when the card has none
---@field labels string[] the card's labels
---@field description string? the card's description, nil when it has none
---@field claimant string? who holds a live claim on it
---@field epic {done: integer, total: integer}? the children of an epic, nil when the card is not one
---@field checks string[] the run commands in its checks rows, empty when it has none
---@field allow string[] the guard rails its allow field lifts, empty when it has none
---@field tests string[] the tests its tests field names, empty when it has none
---@field files string[] the files its files field names, empty when it has none
---@field outcomes dev.board.Outcome[] its Done when outcomes, empty when it has none
---@field outcomes_unreadable boolean? true when the board sent outcomes dev cannot read, so `outcomes` may be short

---@class dev.board.Outcome
---@field id string the outcome's id
---@field name string what has to be true
---@field done boolean whether it is ticked

---@class dev.board.Event
---@field kind string `task_added`, `task_moved`, `task_updated` or `comment_added`
---@field task_id string the card it happened to
---@field column string? the name of the column the card sits in after the event, nil when it left for another board
---@field from_column string? the name of the column a moved card left
---@field actor string? `human` for the owner and `agent` for a token, nil when Pomb did not say

---@class dev.board.Events
---@field cursor string the cursor to send as `after` next
---@field events dev.board.Event[] the events, oldest first, empty when the wait timed out

---@class dev.board.ColumnRow
---@field name string the column's name
---@field is_done boolean whether a card in it counts as finished
---@field wip_limit integer? how many cards it holds at most, nil when it has no limit, and always nil on a local board

---@class dev.board.Backend
---@field describe fun(self: dev.board.Backend): string the backend and board, as `status` prints them
---@field done_columns fun(self: dev.board.Backend): string[]?, string? the names of the columns marked finished, in board order, or nil and a message
---@field column_map table<string, string>? the `[board.columns]` map the runner resolves into `roles`
---@field roles dev.board.Roles? the column set of this run, which the runner sets before a command
---@field card fun(self: dev.board.Backend, id: string): dev.board.Card?, string? the card with that id, or nil and a message
---@field cards fun(self: dev.board.Backend): dev.board.Card[]?, string? every card in column order, or nil and a message
---@field has_field fun(self: dev.board.Backend, key: string): boolean?, string? whether the board defines the custom field with that key, or nil and a message
---@field next fun(self: dev.board.Backend, column: string, opts: dev.board.NextOpts?): dev.board.Card?, string? the top unclaimed, unblocked card of that column without needs:human, or nil and a message when it failed
---@field add fun(self: dev.board.Backend, name: string, column: string, opts: dev.board.AddOpts?): dev.board.Card?, string? the new card
---@field entered fun(self: dev.board.Backend): table<string, string>?, string? the time each card entered its column, as an RFC 3339 stamp by card id, or nil and a message
---@field set_size fun(self: dev.board.Backend, id: string, color: string, fence: integer?): boolean?, string? the card given the palette colour of that value, checked against the claim's fence when one is given
---@field set_labels fun(self: dev.board.Backend, id: string, labels: string[], fence: integer?): boolean?, string? the card's whole label list replaced, checked against the claim's fence when one is given
---@field add_outcome fun(self: dev.board.Backend, id: string, text: string, fence: integer?): boolean?, string? an outcome appended to the card, checked against the claim's fence when one is given
---@field set_outcome fun(self: dev.board.Backend, id: string, outcome: string, fields: {name: string?, done: boolean?}, fence: integer?): boolean?, string? the wording or the tick of the outcome with that id changed, checked against the claim's fence when one is given
---@field delete_outcome fun(self: dev.board.Backend, id: string, outcome: string, fence: integer?): boolean?, string? the outcome with that id removed from the card, checked against the claim's fence when one is given
---@field set_description fun(self: dev.board.Backend, id: string, text: string, fence: integer?): boolean?, string? the card's description replaced, checked against the claim's fence when one is given
---@field set_name fun(self: dev.board.Backend, id: string, name: string, fence: integer?): boolean?, string? the card's title replaced, checked against the claim's fence when one is given
---@field set_checks fun(self: dev.board.Backend, id: string, runs: string[], fence: integer?): boolean?, string? the card's checks rows replaced by one row per command, checked against the claim's fence when one is given
---@field set_field fun(self: dev.board.Backend, id: string, key: string, value: string|string[]|table[]|dev.json.Null, fence: integer?): boolean?, string? the custom field with that key replaced whole by the value, where json.null clears it, checked against the claim's fence when one is given
---@field note fun(self: dev.board.Backend, id: string, body: string, fence: integer?, opts: dev.board.NoteOpts?): boolean?, string? a comment added to the card, of kind agent unless opts names one, checked against the claim's fence when one is given
---@field ask fun(self: dev.board.Backend, id: string, question: dev.board.Ask, fence: integer?): boolean?, string? a structured question posted on the card, which Pomb moves to Blocked with needs:human, or nil and Pomb's refusal
---@field answer fun(self: dev.board.Backend, id: string, choice: integer, quote: string, fence: integer?): boolean?, string? the card's open question answered with the choice and the owner's quote, so Pomb moves the card to that choice's column, or nil and a message
---@field comments fun(self: dev.board.Backend, id: string): dev.board.Comment[]?, string? the card's comments, oldest first
---@field edit_note fun(self: dev.board.Backend, id: string, comment: string, body: string): boolean?, string? the body of one of the caller's own comments replaced, or nil and a message
---@field delete_note fun(self: dev.board.Backend, id: string, comment: string): boolean?, string? one of the caller's own comments deleted, or nil and a message
---@field bin? fun(self: dev.board.Backend, id: string): boolean?, string? the card moved to the recycle bin, or nil and a message when the backend refuses
---@field link fun(self: dev.board.Backend, id: string, kind: string, other: string): boolean?, string? a link of that kind (`blocked_by`, `blocks`, `related` or `parent`, which names the other card as the epic) from the card to the card with that full id, which may sit on another board; linking twice changes nothing
---@field links fun(self: dev.board.Backend, id: string): dev.board.Link[]?, string? the links the card holds plus a `blocks`, `related` or `child` entry for each link another card holds on it, in the order the backend gives them
---@field unlink fun(self: dev.board.Backend, id: string, kind: string, other: string): boolean?, string? the link of that kind from the card to the card with that full id removed, or nil and a message when the card holds no such link or the backend refuses the change
---@field family fun(self: dev.board.Backend, id: string): dev.board.Family?, string? the card's epic and the count of its children
---@field other_board fun(self: dev.board.Backend, name: string): dev.board.Backend?, string? the backend of another board on the same server, or nil and a message
---@field boards fun(self: dev.board.Backend): string[]?, string? the names of the boards the token sees, in the server's order, or nil and a message
---@field columns fun(self: dev.board.Backend, name: string?): dev.board.ColumnRow[]?, string? the columns of the named board, or of this one when nil, in board order, or nil and a message
---@field wait fun(self: dev.board.Backend, after: string?, kinds: string[]?, timeout: integer?): dev.board.Events?, string?, string?, boolean? the events after the cursor, oldest first, held up to `timeout` seconds (50 when nil) until there is one; with no cursor it answers at once with none and the board's current cursor. On an expired cursor it returns nil, a message and the oldest cursor that still resumes, when Pomb holds too many open waits for the token it returns nil, a message, nil and true, and on any other failure nil and a message
---@field move fun(self: dev.board.Backend, id: string, column: string, opts: dev.board.MoveOpts?): boolean?, string? the card moved to a column at a zero-based position, the top when nil, checked against the claim's fence when one is given
---@field claim fun(self: dev.board.Backend, id: string, claimant: string, ttl: integer, fence: integer?, opts: dev.board.ClaimOpts?): integer?, string? the fence of the claim, renewed when the caller's live fence is given
---@field release fun(self: dev.board.Backend, id: string, fence: integer): boolean?, string? the claim given up
---@field keepalive fun(self: dev.board.Backend, id: string, fence: integer, ticks: integer, state: string): integer?, string? the pid of a detached loop that renews the claim every tick until the state file loses the fence or the ticks run out

---@class dev.board.Link
---@field kind string `blocked_by`, `blocks`, `related`, `parent` or `child`, as seen from the card
---@field id string the other card's full id
---@field board string? the other card's board name, nil for the card's own board

---@class dev.board.Family
---@field parent {id: string, name: string}? the epic the card is part of
---@field epic boolean whether the card is an epic, Pomb's kind epic or a card with children
---@field children {done: integer, total: integer}? how many of the card's children are done, nil when it has none

---@class dev.board.NoteOpts
---@field kind string? the comment's kind, lowercase
---@field author string? the label the comment is written under

---@class dev.board.MoveOpts
---@field fence integer? the claim fence the move is checked against
---@field position integer? the zero-based place in the column, the top when nil

---@class dev.board.Comment
---@field id string the comment's full id
---@field who string the token's name, else the kind of actor that wrote it
---@field at string when it was written, as an RFC 3339 stamp
---@field body string its text
---@field kind string? its kind tag, when it has one
---@field author string? the role label it was written under, when it has one
---@field actor string? the kind of actor that wrote it, `human` or `agent`, when known
---@field question dev.board.Question? the structured question the comment holds, with its answer once given

---@class dev.board.Question
---@field text string the question
---@field answer table<string, any>? how the question was answered, nil while it is open

---@class dev.board.Ask
---@field text string? the question
---@field choices {label: string, column: string}[] the choices in order, each with the column the card moves to
---@field recommended integer? the number of the recommended choice
---@field why string? why the agent cannot decide alone

---@class dev.board.NextOpts
---@field label string? the label the card must carry
---@field max_size integer? the most Pomodori the card may be, nil for any size

---@class dev.board.AddOpts
---@field description string? the card's description
---@field color string? the standard value of the palette colour to give it
---@field labels string[]? the labels to give it
---@field checks string[] the run commands to give it, one checks row each
---@field outcomes string[]? the Done when outcomes to give it, one subtask each

---@class dev.board.Layout
---@field find fun(self: dev.board.Layout): boolean?, string? whether the board exists, or nil and a message
---@field create fun(self: dev.board.Layout): boolean?, string? the board made, with the name of the template it came from
---@field read fun(self: dev.board.Layout): dev.board.LayoutState?, string? the board's columns, colours and cards
---@field add_column fun(self: dev.board.Layout, name: string, is_done: boolean): boolean?, string? a column at the end
---@field rename_column fun(self: dev.board.Layout, id: string, name: string): boolean?, string? a column given a new name, its cards kept
---@field move_column fun(self: dev.board.Layout, id: string, position: integer): boolean?, string? a column moved, 0 first
---@field mark_done fun(self: dev.board.Layout, id: string): boolean?, string? a column made the one of finished cards
---@field mark_blocked fun(self: dev.board.Layout, id: string): boolean?, string?, boolean? a column made the one of cards waiting on an answer, third value true when it changed one
---@field set_color fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a colour's label, description, default flag or enabled flag
---@field set_card fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a card's name or colour
---@field add_checks_field fun(self: dev.board.Layout): boolean?, string? the checks field defined on the board
---@field add_roles fun(self: dev.board.Layout): (string[]|false)?, string? the standard agent roles granted to the board, the names this call created, or false when the board has no roles

---@class dev.board.LayoutColumn
---@field id string the column's id
---@field name string the column's name
---@field is_done boolean whether a card in it counts as finished
---@field is_blocked boolean? whether it holds the cards waiting on an answer, nil when the backend sends no such key

---@class dev.board.LayoutState
---@field columns dev.board.LayoutColumn[] the columns in board order
---@field colors {id: string, value: string, label: string, description: string, is_default: boolean, enabled: boolean}[] the palette
---@field cards {id: string, name: string, color_id: string?}[] every card
---@field has_checks boolean whether the board has the checks field

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

---The backends a project may name.
M.Backend = { POMB = "pomb", LOCAL = "local" }

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

---The comment kinds `note --kind` accepts.
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
    M.NoteKind.QUESTION,
    M.NoteKind.BLOCKED,
    M.NoteKind.STATUS,
    M.NoteKind.DONE,
}

---The most characters of the label `note --as` sends, which Pomb enforces.
M.AUTHOR_CHARS = 80

---The prefix of the comment `check` writes, which no note may begin with.
M.CHECK_PREFIX = "dev-check:"

---The prefix of the comment `review` writes, which no note may begin with.
M.REVIEW_PREFIX = "dev-review:"

M.TURN_PREFIX = "dev-turn:"

---The prefix of the comment a claim writes, which no note may begin with.
M.CLAIM_PREFIX = "dev-claim:"

local RESERVED_PREFIXES = { M.CHECK_PREFIX, M.REVIEW_PREFIX, M.TURN_PREFIX, M.CLAIM_PREFIX }

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

---The roles a column map names, in board order.
M.ROLES = { "icebox", "backlog", "ready", "progress", "review", "verify", "release", "blocked" }

---The name each role has when the config map does not rename it.
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

---@class dev.board.Roles
---@field icebox string the column of free-form cards, which are never scaffolded or checked
---@field backlog string the column of new cards, which planners size and split
---@field ready string the column a worker takes cards from
---@field progress string the column of cards being worked, where a move keeps a claim's loop alive
---@field review string the column of cards waiting for review
---@field verify string the column of cards waiting for a verifier
---@field release string the column of cards waiting to reach main and go live
---@field blocked string the column of cards that wait on the owner
---@field done string? the mapped column of finished cards, nil when the config names none
---@field finished string[] the names of the columns the backend marks finished, in board order
---@field list string[] the column names in board order, the mapped or default Done last
---@field stale table<string, boolean> the columns where a card that sits untouched is stale
local Roles = {}
Roles.__index = Roles

---Resolve the column set of one command run.
---@param map table<string, any>? the `[board.columns]` table, keyed by role
---@param finished string[]? the names of the columns the backend marks finished
---@return dev.board.Roles
function M.roles(map, finished)
    map = map or {}
    local roles = setmetatable({ finished = finished or {} }, Roles)
    local list = {}
    for _, role in ipairs(M.ROLES) do
        local name = map[role]
        roles[role] = type(name) == "string" and name ~= "" and name or M.DEFAULT_NAMES[role]
        list[#list + 1] = roles[role]
    end
    local done = map.done
    if type(done) == "string" and done ~= "" then
        roles.done = done
    end
    list[#list + 1] = roles.done or roles.finished[1] or M.DEFAULT_NAMES.done
    roles.list = list
    roles.stale = {
        [roles.backlog] = true,
        [roles.ready] = true,
        [roles.progress] = true,
        [roles.review] = true,
        [roles.verify] = true,
        [roles.release] = true,
    }
    return roles
end

---The column `discard` moves a card to: the mapped done column, else the first finished one.
---@return string
function Roles:done_column()
    return self.done or self.finished[1] or M.DEFAULT_NAMES.done
end

---Name a column from its full name or a role name, in any case.
---@param word string `ready`, `progress`, `Review`, a finished column's name and so on
---@return string? column the column's name, or nil when it is not one of the board's
function Roles:column(word)
    local lowered = word:lower():gsub("%s+", " ")
    for _, role in ipairs(M.ROLES) do
        if role == lowered then
            return self[role]
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
---@return string names the column names and the role words
function Roles:help()
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
    return table.concat(names, ", ") .. " (or a role such as progress or review, in any case)"
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
            "a " .. noun .. " id needs at least " .. M.MIN_PREFIX .. " hex characters: " .. word
    end
    local found
    for _, item in ipairs(items) do
        if item.id:lower():sub(1, #prefix) == prefix then
            if item.id:lower() == prefix then
                return item
            end
            if found then
                return nil, word .. " matches more than one " .. noun .. ", give more characters"
            end
            found = item
        end
    end
    if not found then
        return nil, "no " .. noun .. " starts with " .. word
    end
    return found
end

---The headings of card format v2, in order.
M.HEADINGS = { "Problem", "Change", "Out of scope" }

---The fewest and the most Done when outcomes a planned card has.
M.MIN_OUTCOMES = 3
M.MAX_OUTCOMES = 7
M.MIN_EPIC_OUTCOMES = 1
M.MAX_EPIC_OUTCOMES = 3

local PROBLEM = M.HEADINGS[1]
local CHANGE = M.HEADINGS[2]
local OUT_OF_SCOPE = M.HEADINGS[3]
local DONE_WHEN = "Done when"

local function lines_of(description)
    return ((description or "") .. "\n"):gmatch("(.-)\n")
end

local function heading_of(line)
    return line:match("^##%s+(.-)%s*$")
end

---Give a description the three v2 headings, filling Problem from the text given. A text that
---already holds a v2 heading or the v1 Done when heading is kept as it is.
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

---Warn about the hex ids, hashes and paths in prose. Text under a `## Change` heading is left out,
---and so is a URL.
---@param prose string? the description or note
---@return string[] warnings one line per offending word, in order, without repeats
function M.prose_warnings(prose)
    local warnings, seen, in_change = {}, {}, false
    local function warn(kind, word)
        local line = "card prose holds " .. kind .. ": " .. word
        if not seen[line] then
            seen[line] = true
            warnings[#warnings + 1] = line
        end
    end
    for line in lines_of(prose) do
        local name = heading_of(line)
        if name then
            in_change = name == CHANGE
        elseif not in_change then
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
---@return {name: string, done: boolean}[]? items the checklist items in order, nil when there are none
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

---Build a card format v2 description from the text of each section.
---@param problem string? the Problem text
---@param change string? the Change text
---@param out_of_scope string? the Out of scope text
---@return string description the three headings with their text
function M.compose(problem, change, out_of_scope)
    local texts = { problem, change, out_of_scope }
    local parts = {}
    for i, heading in ipairs(M.HEADINGS) do
        local body = (texts[i] or ""):match("^%s*(.-)%s*$")
        parts[i] = "## " .. heading .. "\n" .. (body ~= "" and body .. "\n" or "")
    end
    return table.concat(parts, "\n")
end

---List what a card lacks of card format v2 outside Icebox: each missing heading, and Problem text.
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
        missing[#missing + 1] = "text under ## " .. problem
    end
    return missing
end

---List the shapes card format v2 refuses outside Icebox: a Change or Out of scope section with no
---text under it, and a Problem text with a line that starts `Change:` or `Out of scope:`.
---@param description string? the card's description
---@return string[] shapes the problems, empty when the sections have the right shape
function M.shapes(description)
    local seen, filled = sections(description)
    local shapes = {}
    for _, heading in ipairs({ CHANGE, OUT_OF_SCOPE }) do
        if seen[heading] and not filled[heading] then
            shapes[#shapes + 1] = "text under ## " .. heading
        end
    end
    local current, misplaced = nil, false
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
        elseif
            current == PROBLEM and (line:find("^%s*Change:") or line:find("^%s*Out of scope:"))
        then
            misplaced = true
        end
    end
    if misplaced then
        shapes[#shapes + 1] = "a Problem free of Change: and Out of scope: lines"
    end
    return shapes
end

local function checklist_items(description)
    local items, current = 0, nil
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
        elseif current == DONE_WHEN and line:find("^%s*[-*]%s%[[ xX]%]%s+%S") then
            items = items + 1
        end
    end
    return items
end

---@class dev.board.Unplanned
---@field color string? the card's colour
---@field description string? the card's description
---@field outcomes integer how many outcomes it has
---@field need_outcomes boolean whether it needs one
---@field children integer how many children it has, 0 for a card that is no epic
---@field sections boolean? whether the v2 sections are checked, true when nil

---The refusal for an epic whose outcome count is out of range.
---@param outcomes integer how many outcomes the epic has
---@return string problem the epic rule and the count
local function epic_outcomes(outcomes)
    return M.MIN_EPIC_OUTCOMES
        .. " to "
        .. M.MAX_EPIC_OUTCOMES
        .. " Done when outcomes for an epic, not "
        .. outcomes
end

---List what a card outside Icebox lacks: a size of 1, 2, 3 or 3+, each v2 section with text under
---Problem, and, when asked, at least one Done when outcome. A v1 `## Done when` checklist item
---counts as an outcome. An epic, a card with children, needs 1 to 3 outcomes as its final check.
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
    end
    if card.need_outcomes then
        if card.outcomes == 0 and checklist_items(description) == 0 then
            missing[#missing + 1] = "Done when outcomes"
        elseif card.children > 0 and card.outcomes > M.MAX_EPIC_OUTCOMES then
            missing[#missing + 1] = epic_outcomes(card.outcomes)
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

---List what a card lacks of card format v2 to enter Ready: each missing or empty section, and
---Done when outcomes. The outcomes are 3 to 7 subtasks, or 1 to 3 for an epic, and a card with none
---is accepted when its description has a v1 `## Done when` checklist item.
---@param description string? the card's description
---@param outcomes integer how many outcomes the card has
---@param children integer how many children the card has
---@return string[] missing the problems, empty when the card follows the format
function M.missing(description, outcomes, children)
    local seen, filled = sections(description)
    local items = checklist_items(description)
    local missing = {}
    for _, heading in ipairs(M.HEADINGS) do
        if not seen[heading] then
            missing[#missing + 1] = "## " .. heading
        elseif heading == PROBLEM and not filled[heading] then
            missing[#missing + 1] = "text under ## " .. heading
        end
    end
    for _, shape in ipairs(M.shapes(description)) do
        missing[#missing + 1] = shape
    end
    if children > 0 then
        if outcomes == 0 and items == 0 then
            missing[#missing + 1] = M.MIN_EPIC_OUTCOMES
                .. " to "
                .. M.MAX_EPIC_OUTCOMES
                .. " Done when outcomes for an epic"
        elseif outcomes > M.MAX_EPIC_OUTCOMES then
            missing[#missing + 1] = epic_outcomes(outcomes)
        end
    elseif outcomes == 0 and items == 0 then
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
---@param opts {holders: boolean?, progress: boolean?}? `holders` adds the claim holder before the name, `progress` the ticked outcomes before the holder
---@return string[] cells id prefix, column, size, labels, the ticks and the holder when asked for, and name
function M.cells(card, opts)
    opts = opts or {}
    local labels = #card.labels > 0 and table.concat(card.labels, ",") or "-"
    local cells = { card.id:sub(1, M.MIN_PREFIX), card.column, card.size, labels }
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

return M
