local board = require("dev.board")
local claims = require("dev.board.claims")
local devos = require("dev.os")
local json = require("dev.json")
local project = require("dev.project")
local tokenfile = require("dev.board.tokenfile")

local present = json.present
local PASSLOCK_SCRIPT = "/board/passlock.sh"
local KEYCHAIN_SCRIPT = "/board/keychain.sh"
local KEYCHAIN_SOURCE = "keychain"
local UNAUTHORIZED = 401
local ISSUED_VARIABLE = "DEV_BOARD_TOKEN"
local ISSUED_REFUSED = "the issued token in DEV_BOARD_TOKEN was refused by pomb"
local FILE_REFUSED = "the role token file for DEV_AGENT was refused by pomb"
local FILE_EXPIRED =
    "the role token file for DEV_AGENT expired; mint it again with dev board token mint"
local AGENT_VARIABLE = "DEV_AGENT"
local ROLES_LIST_PATH = "/api/v1/agent-roles"
local CHILDREN_PATH = "/api/v1/auth/tokens/children"
local CONFLICT = 409
local LIMIT_REACHED = "wip_limit_reached"
local FULL = "full"
local NOT_FOUND = 404
local UNKNOWN_ROLE = "unknown_role"
local ISSUED_BAD = "DEV_BOARD_TOKEN holds a token that is not plain text"
local CONNECT_SECONDS = "10"
local REQUEST_SECONDS = 30
local WAIT_SECONDS = 50
local WAIT_MARGIN_SECONDS = 10
local GONE = 410
local CURSOR_EXPIRED = "cursor_expired"
local TOO_MANY_REQUESTS = 429
local TOO_MANY_WAITS = "too_many_waits"
local TIMED_OUT = 124
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"
local ENTRY_PATTERN = "^[%w_./][%w_. /-]*$"
local URL_PATTERN = "^https?://[%w%.%-]+:?%d*[%w%._~/%-]*$"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }
local HTTP_ERROR = 400
local TOP = 0
local COMMENT_KIND = "agent"
local QUESTION_KIND = "question"
local DEFAULT_AUTHOR = "api-token"
local ACTORS = { user = "human", api_token = "agent" }
local BAD_REF = "the token must be pass:<entry> in [board.pomb] of ~/.config/dev/config.toml"
local KEEPALIVE_SCRIPT = "/board/keepalive.sh"
local TEMPLATE = "agent project"
local UTC_STAMP = "!%Y-%m-%dT%H:%M:%S"
local STAMP_CHARS = 19
local PAGE_LIMIT = 500
local FORBIDDEN = 403
local PERMISSION_DENIED = "permission_denied"
local EXCEEDS_GRANT = "exceeds_grant"
local TOKEN_EXPIRED = "token_expired"
local WHOAMI_PATH = "/api/v1/auth/whoami"
local EXPIRED = "the role token expired; mint it again from its issuer"
local ROLES_PATH = "/api/v1/agent-roles/standard"
local CARD_LOCKED = "card_locked"
local LINKS_DELETE = "links.delete"
local SUBTASKS_DELETE = "subtasks.delete"
local ADMIN = "admin"
local ALL_BOARDS = "all"
local NEEDS_LEAD =
    "pomb refused the delete: it needs subtasks.delete, which only the lead token holds. Set [board.pomb] lead_token in ~/.config/dev/config.toml"
local NOT_YOURS = "that comment is not yours to change"
local LOCKED = "pomb locked this card while it is labelled "
    .. board.NEEDS_HUMAN
    .. ": comments, moves and edits are refused until the owner answers and the label is removed."
    .. " Reordering and resizing stay refused on it until pomb ships fff0e011"
local CHECKS_DEFINITION = {
    key = board.CHECKS_FIELD,
    label = "Checks",
    kind = "table",
    required = true,
    columns = {
        { key = board.CHECKS_RUN, label = "Run", kind = "text", options = {}, required = true },
        { key = "on", label = "On", kind = "multiselect", options = { "local" }, required = false },
    },
}

---Pomb over its HTTP API, through curl.
---
---The token comes from `pass` and goes to curl on standard input as a config
---line, so it is in no argument list, no environment variable, no file and no
---output.
---@class dev.board.pomb
local M = {}

---@class dev.board.pomb.Opts
---@field url string the server's base URL
---@field token string? `pass:<entry>`, where the token is kept, unneeded when `authorize` gives one
---@field name string the board's name
---@field lead boolean? true to send the configured token and never the issued or filed one

---@class dev.board.pomb.Detail
---@field id string the board's id
---@field columns {id: string, name: string}[] the columns in board order

---@class dev.board.pomb.Backend: dev.board.Backend, dev.board.Layout
---@field private __opts dev.board.pomb.Opts the server, token reference and board name
---@field private __secret string? the token, nil until the first request
---@field private __healed boolean? nil until a refused Keychain token is replaced
---@field private __filed boolean? true when the token came from the role token file
---@field private __reread boolean? true once an expired file token has been looked up again
---@field private __detail dev.board.pomb.Detail? the board with its columns
---@field private __colors table<string, string>? palette labels by colour id
---@field private __values table<string, string>? palette colour values by colour id
---@field private __ids table<string, string>? palette colour ids by colour value
---@field private __id string? the board's id, once found or created
---@field private __field_keys table<string, boolean>? the keys of the board's custom fields, once asked
local Backend = {}
Backend.__index = Backend

local function unavailable(reason)
    return "board unavailable: " .. reason
end

local function listed(list, word)
    for _, item in ipairs(list) do
        if item == word then
            return true
        end
    end
    return false
end

local function denied(doc, role)
    local permission = present(doc.permission) or "needed"
    local board_id = present(doc.board_id)
    local token = role and ("this token (role " .. role .. ")") or "this token"
    if board_id then
        return unavailable(
            token
                .. " has the "
                .. permission
                .. " permission but is not assigned to board "
                .. board_id
                .. "; add the board to the token"
        )
    end
    return unavailable(
        "pomb answered 403: "
            .. token
            .. " lacks the "
            .. permission
            .. " permission on every board; use a token that has it"
    )
end

---Tell whether a failure means Pomb could not be asked, as opposed to Pomb
---refusing the request.
---
---A request that never left the machine is unreachable: a `pass` that is locked
---or slow, or a curl that could not resolve or connect (exit 5, 6 or 7). A
---timeout, a gateway error and a page that is not JSON may have followed an
---applied change, so they count only for a change that is safe to apply twice.
---Any other answer is a refusal.
---@param message string? what a backend call returned
---@param idempotent boolean? whether the change may be applied twice without harm
---@return boolean unreachable true when the change may wait for a later sync
function M.unreachable(message, idempotent)
    if type(message) ~= "string" then
        return false
    end
    local reasons = {
        "cannot reach .* %(curl exit [567]%)$",
        "pass timed out",
        "pass is locked or has no entry ",
    }
    if idempotent then
        for _, reason in ipairs({
            "cannot reach .* %(curl exit 28%)$",
            "pomb answered 50[234]:",
            "pomb sent an answer dev cannot read",
        }) do
            reasons[#reasons + 1] = reason
        end
    end
    for _, reason in ipairs(reasons) do
        if message:find("^board unavailable: " .. reason) then
            return true
        end
    end
    return false
end

---@type table<string, string> tokens already read in this process, by `pass` entry
local tokens = {}
---@type table<string, boolean> entry -> true when the token came from the macOS Keychain
local from_keychain = {}

local function entry_of(ref)
    local entry = type(ref) == "string" and ref:match("^pass:(.+)$")
    if entry and entry:find(ENTRY_PATTERN) and not entry:find("..", 1, true) then
        return entry
    end
end

---The role token the file for the current `DEV_AGENT` holds.
---@return string? token the token, nil when there is no agent name or no file
---@return string? message why the file is not usable
local function filed()
    local name = os.getenv(AGENT_VARIABLE)
    if not name or name == "" then
        return nil
    end
    local found, message = tokenfile.read(name)
    if not found then
        return nil, message
    end
    if found.expires > 0 and found.expires <= os.time() then
        return nil, FILE_EXPIRED
    end
    if not found.token:find(TOKEN_PATTERN) then
        return nil, "the token file for DEV_AGENT holds a token that is not plain text"
    end
    return found.token
end

---The role token a lead issued, from `DEV_BOARD_TOKEN`.
---@return string? token the token, nil when the variable is unset or empty
---@return string? message why the token is not usable
local function issued()
    local value = os.getenv(ISSUED_VARIABLE)
    if not value or value == "" then
        return nil
    end
    if not value:find(TOKEN_PATTERN) then
        return nil, ISSUED_BAD
    end
    return value
end

---Read the worker token from the Keychain or `pass`, without a prompt.
---
---A locked store fails at once instead of waiting for a pinentry. On a machine
---with `security`, the Keychain answers first and `pass` runs only on a miss.
---Reads queue on one lock shared by every process, and a process reads each
---entry once.
---@param ref string `pass:<entry>`
---@return string? token the token
---@return string? message why it could not be read
function M.token(ref)
    local entry = entry_of(ref)
    if not entry then
        return nil, BAD_REF
    end
    if tokens[entry] then
        return tokens[entry]
    end
    local out, code = devos.capture({ "bash", project.share .. PASSLOCK_SCRIPT, entry }, {
        unset = CHILD_UNSET,
        stdin = "null",
        stderr = "null",
    })
    if code == TIMED_OUT then
        return nil, unavailable("pass timed out")
    elseif code ~= 0 then
        return nil, unavailable("pass is locked or has no entry " .. entry)
    end
    local token, source = out:match("^([^\n]*)\n?([^\n]*)")
    if not token:find(TOKEN_PATTERN) then
        return nil, unavailable("pass gave a token that is empty or not plain text")
    end
    tokens[entry] = token
    from_keychain[entry] = source == KEYCHAIN_SOURCE
    return token
end

---Forget a token that came from the Keychain, to send the next read to `pass`.
---@param ref string `pass:<entry>`
---@return boolean dropped true when the cached item was deleted and the token forgotten
local function forget(ref)
    local entry = entry_of(ref)
    if not entry or not from_keychain[entry] then
        return false
    end
    local _, code = devos.capture({ "bash", project.share .. KEYCHAIN_SCRIPT, "drop", entry }, {
        unset = CHILD_UNSET,
        stdin = "null",
        stderr = "null",
    })
    if code ~= 0 then
        return false
    end
    tokens[entry] = nil
    from_keychain[entry] = nil
    return true
end

---Build a Pomb backend.
---@param opts dev.board.pomb.Opts the server, the token reference and the board
---@return dev.board.Backend? backend the backend
---@return string? message why the options are not usable
function M.new(opts)
    if type(opts.url) ~= "string" or not opts.url:find(URL_PATTERN) then
        return nil, "[board.pomb] url must be an http or https address in ~/.config/dev/config.toml"
    end
    opts.url = opts.url:gsub("/+$", "")
    return setmetatable({ __opts = opts }, Backend)
end

function Backend:describe()
    return "pomb " .. self.__opts.name
end

---@private
---@param method string the HTTP method
---@param path string the path under the server's URL
---@param body table<string, any>? the JSON body
---@param fence integer? the claim fence to send as `If-Claim-Fence`
---@param seconds integer? the whole request's `--max-time`, 30 when nil
---@param file string? a file to send as the `file` part of a multipart body, in place of a JSON body
---@return any? doc the decoded answer
---@return string? message why the call failed
---@return integer? status the HTTP status when pomb refused the call
---@return any? answer the decoded body of a refused call
function Backend:__request(method, path, body, fence, seconds, file)
    if not self.__secret then
        local token, message
        if not self.__opts.lead then
            token, message = issued()
        end
        if message then
            return nil, message
        end
        self.__issued = token and ISSUED_REFUSED or nil
        if not token and not self.__opts.lead then
            token, message = filed()
            if message then
                return nil, message
            end
            self.__issued = token and FILE_REFUSED or nil
            self.__filed = token ~= nil
        end
        if not token then
            token, message = M.token(self.__opts.token)
        end
        if not token then
            return nil, message
        end
        self.__secret = token
    end
    local argv = {
        "curl",
        "-sS",
        "--connect-timeout",
        CONNECT_SECONDS,
        "--max-time",
        string.format("%d", seconds or REQUEST_SECONDS),
        "-K",
        "-",
        "-X",
        method,
        "-w",
        "\n%{http_code}",
    }
    if file then
        argv[#argv + 1] = "-F"
        argv[#argv + 1] = 'file=@"' .. file:gsub('[\\"]', "\\%0") .. '"'
    else
        argv[#argv + 1] = "-H"
        argv[#argv + 1] = "Content-Type: application/json"
    end
    if fence then
        argv[#argv + 1] = "-H"
        argv[#argv + 1] = "If-Claim-Fence: " .. string.format("%d", fence)
    end
    if body then
        argv[#argv + 1] = "--data-raw"
        argv[#argv + 1] = assert(json.encode(body))
    end
    argv[#argv + 1] = self.__opts.url .. path
    local out, code = devos.capture_input(
        argv,
        'header = "Authorization: Bearer ' .. self.__secret .. '"\n',
        { unset = CHILD_UNSET, stderr = "null" }
    )
    if code ~= 0 then
        return nil, unavailable("cannot reach " .. self.__opts.url .. " (curl exit " .. code .. ")")
    end
    local text, status = out:match("^(.*)\n(%d+)$")
    local doc
    if text == "" then
        doc = true
    elseif text then
        doc = json.decode(text)
    end
    status = tonumber(status)
    if not status or doc == nil then
        return nil, unavailable("pomb sent an answer dev cannot read")
    end
    local expired = status == UNAUTHORIZED and type(doc) == "table" and doc.code == TOKEN_EXPIRED
    if expired and self.__filed and not self.__reread then
        self.__reread = true
        local fresh = filed()
        if fresh and fresh ~= self.__secret then
            self.__secret = fresh
            return self:__request(method, path, body, fence, seconds, file)
        end
    end
    if status == UNAUTHORIZED and self.__issued then
        return nil, expired and unavailable(EXPIRED) or self.__issued, status, doc
    end
    if status == UNAUTHORIZED and not self.__healed and forget(self.__opts.token) then
        self.__healed = true
        self.__secret = nil
        return self:__request(method, path, body, fence, seconds, file)
    end
    if expired then
        return nil, unavailable(EXPIRED), status, doc
    end
    if status == FORBIDDEN and type(doc) == "table" and doc.code == PERMISSION_DENIED then
        return nil, denied(doc, self:__role()), status, doc
    end
    if status == FORBIDDEN and type(doc) == "table" and doc.code == EXCEEDS_GRANT then
        local role = self:__role()
        if role then
            local action = present(doc.action)
                or present(doc.permission)
                or present(doc.message)
                or "that"
            return nil,
                unavailable("pomb answered 403: the " .. role .. " role cannot " .. action),
                status,
                doc
        end
    end
    if status == FORBIDDEN and type(doc) == "table" and doc.code == CARD_LOCKED then
        return nil, LOCKED, status, doc
    end
    if status >= HTTP_ERROR then
        local detail = type(doc) == "table" and present(doc.message) or "no message"
        return nil, unavailable("pomb answered " .. status .. ": " .. tostring(detail)), status, doc
    end
    return doc
end

---Read the token's role name from whoami, once, and only for a refusal.
---@private
---@return string? role the role name, or nil when the token has none
function Backend:__role()
    if self.__who ~= nil then
        return self.__who or nil
    end
    self.__who = false
    local who = self:__request("GET", WHOAMI_PATH)
    if type(who) == "table" then
        self.__who = present(who.role_name) or false
    end
    return self.__who or nil
end

---Read the credential behind the token in use from whoami.
---@return {name: string, kind: string, scope: string, role: string?, label: string?, issuer: string?, expires: integer?, boards: string[]|string, permissions: string[]}? who the credential, never its token
---@return string? message why nothing was read
function Backend:whoami()
    local doc, message = self:__request("GET", WHOAMI_PATH)
    if not doc then
        return nil, message
    end
    if type(doc) ~= "table" then
        return nil, unavailable("pomb sent an answer dev cannot read")
    end
    local boards = {}
    if type(doc.boards) == "table" then
        for _, entry in ipairs(doc.boards) do
            boards[#boards + 1] = present(type(entry) == "table" and entry.name or entry) or "?"
        end
    end
    local permissions = {}
    for _, name in ipairs(type(doc.permissions) == "table" and doc.permissions or {}) do
        permissions[#permissions + 1] = tostring(name)
    end
    return {
        name = present(doc.name) or "?",
        kind = present(doc.kind) or "?",
        scope = present(doc.scope) or "?",
        role = present(doc.role_name),
        label = present(doc.label),
        issuer = type(doc.parent_token) == "table" and present(doc.parent_token.name) or nil,
        expires = tonumber(doc.expires_at),
        boards = doc.boards == "all" and "all" or boards,
        permissions = permissions,
    }
end

function Backend:__roles()
    return self.roles or board.roles()
end

function Backend:__load()
    if self.__detail then
        return true
    end
    local boards, message = self:__request("GET", "/api/boards")
    if not boards then
        return nil, message
    end
    local id
    for _, entry in ipairs(boards) do
        if entry.name == self.__opts.name then
            id = entry.id
        end
    end
    if not id then
        return nil, self:__missing()
    end
    local detail
    detail, message = self:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end
    local palette
    palette, message = self:__request("GET", "/api/boards/" .. id .. "/colors")
    if not palette then
        return nil, message
    end
    self.__colors, self.__values, self.__ids = {}, {}, {}
    for _, color in ipairs(palette) do
        self.__colors[color.id] = color.label
        if type(color.value) == "string" then
            self.__values[color.id] = color.value
            self.__ids[color.value] = color.id
        end
    end
    self.__detail = detail
    return true
end

function Backend:__column_id(name)
    for _, column in ipairs(self.__detail.columns) do
        if column.name:lower() == name:lower() then
            return column.id
        end
    end
end

function Backend:__column_done(id)
    for _, column in ipairs(self.__detail.columns) do
        if column.id == id then
            return column.is_done == true
        end
    end
    return false
end

function Backend:done_columns()
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local names = {}
    for _, column in ipairs(self.__detail.columns) do
        if column.is_done == true then
            names[#names + 1] = column.name
        end
    end
    return names
end

function Backend:__column_name(id)
    for _, column in ipairs(self.__detail.columns) do
        if column.id == id then
            return column.name
        end
    end
    return "?"
end

local function holder(claim)
    if type(claim) ~= "table" or type(claim.claimant) ~= "string" then
        return nil
    end
    local expires = present(claim.expires_at)
    if type(expires) == "string" and expires:sub(1, STAMP_CHARS) <= os.date(UTC_STAMP) then
        return nil
    end
    return claim.claimant
end

local function runs_of(task)
    local rows = type(task.fields) == "table" and task.fields[board.CHECKS_FIELD]
    local runs = {}
    if type(rows) == "table" then
        for _, row in ipairs(rows) do
            local run = type(row) == "table" and row[board.CHECKS_RUN]
            if type(run) == "string" then
                runs[#runs + 1] = run
            end
        end
    end
    return runs
end

local function field_names(task, key)
    return board.names(type(task.fields) == "table" and task.fields[key])
end

local function table_rows(runs)
    local rows = {}
    for index, run in ipairs(runs) do
        rows[index] = { [board.CHECKS_RUN] = run }
    end
    return rows
end

function Backend:__fields(id)
    local fields, message = self:__request("GET", "/api/boards/" .. id .. "/fields")
    if not fields then
        return nil, message
    end
    return fields
end

function Backend:has_field(key)
    if not self.__field_keys then
        local ok, message = self:__load()
        if not ok then
            return nil, message
        end
        local fields
        fields, message = self:__fields(self.__detail.id)
        if not fields then
            return nil, message
        end
        local keys = {}
        for _, field in ipairs(fields) do
            keys[field.key] = true
        end
        self.__field_keys = keys
    end
    return self.__field_keys[key] == true
end

---Read the outcomes of a task row.
---
---A missing or null `subtasks` is a card with none.
---@param task table<string, any> the task row of the export
---@return dev.board.Outcome[] outcomes the outcomes dev could read
---@return boolean readable false when `subtasks` is not a list or one of its entries is not an outcome
local function outcomes_of(task)
    local outcomes = {}
    local subtasks = present(task.subtasks)
    if subtasks == nil then
        return outcomes, true
    end
    if type(subtasks) ~= "table" or (subtasks[1] == nil and next(subtasks) ~= nil) then
        return outcomes, false
    end
    local readable = true
    for _, sub in ipairs(subtasks) do
        if type(sub) == "table" and type(sub.name) == "string" then
            outcomes[#outcomes + 1] = {
                id = tostring(sub.id),
                name = sub.name,
                done = sub.done == true,
            }
        else
            readable = false
        end
    end
    return outcomes, readable
end

local function epic_counts(task)
    local total = type(task.children_total) == "number" and task.children_total or 0
    if task.kind ~= board.Kind.EPIC and total == 0 then
        return nil
    end
    return { done = task.children_done or 0, total = total }
end

function Backend:__card(task)
    local outcomes, readable = outcomes_of(task)
    return {
        epic = epic_counts(task),
        kind = task.kind == board.Kind.EPIC and board.Kind.EPIC or board.Kind.TASK,
        checks = runs_of(task),
        allow = field_names(task, board.ALLOW_FIELD),
        tests = field_names(task, board.TESTS_FIELD),
        files = field_names(task, board.FILES_FIELD),
        outcomes = outcomes,
        outcomes_unreadable = not readable,
        claimant = holder(task.claim),
        id = task.id,
        name = task.name,
        column = self:__column_name(task.column_id),
        done = self:__column_done(task.column_id),
        size = board.size(self.__colors[present(task.color_id)]),
        color = present(task.color_id) and (self.__values[task.color_id] or "unknown") or nil,
        labels = task.labels or {},
        description = present(task.description),
    }
end

function Backend:cards()
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local doc
    doc, message = self:__request("GET", "/api/boards/" .. self.__detail.id .. "/export-data")
    if not doc then
        return nil, message
    end
    local order = {}
    for index, column in ipairs(self.__detail.columns) do
        order[column.id] = index
    end
    local tasks = {}
    for _, task in ipairs(doc.tasks) do
        tasks[#tasks + 1] = task
    end
    table.sort(tasks, function(a, b)
        local oa, ob = order[a.column_id] or math.huge, order[b.column_id] or math.huge
        if oa ~= ob then
            return oa < ob
        end
        return (a.position or 0) < (b.position or 0)
    end)
    local cards = {}
    for _, task in ipairs(tasks) do
        cards[#cards + 1] = self:__card(task)
    end
    return cards
end

function Backend:card(id)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local task
    task, message = self:__request("GET", "/api/tasks/" .. id)
    if not task then
        return nil, message
    end
    return self:__card(task)
end

function Backend:entered()
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local times = {}
    local cursor
    repeat
        local page
        page, message = self:__request(
            "GET",
            "/api/boards/"
                .. self.__detail.id
                .. "/tasks?limit="
                .. PAGE_LIMIT
                .. (cursor and "&cursor=" .. cursor or "")
        )
        if not page then
            return nil, message
        end
        for _, task in ipairs(page.items) do
            times[task.id] = present(task.column_entered_at)
        end
        cursor = present(page.next_cursor)
    until cursor == nil
    return times
end

function Backend:next(column, opts)
    local label = opts and opts.label
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local id = self:__column_id(column)
    if not id then
        return nil, unavailable("the board has no " .. column .. " column")
    end
    local ready_filter = column == self:__roles().ready and "&ready=true" or ""
    local cursor
    repeat
        local query = "/api/boards/"
            .. self.__detail.id
            .. "/tasks?limit=50&claimed=false"
            .. ready_filter
            .. "&column_id="
            .. id
        if cursor then
            query = query .. "&cursor=" .. cursor
        end
        local page
        page, message = self:__request("GET", query)
        if not page then
            return nil, message
        end
        for _, item in ipairs(page.items) do
            local task
            task, message = self:__request("GET", "/api/tasks/" .. item.id)
            if not task then
                return nil, message
            end
            local card = self:__card(task)
            local links
            links, message = self:links(item.id)
            if not links then
                return nil, message
            end
            local blocked
            blocked, message = self:__blocked(links)
            if blocked == nil then
                return nil, message
            end
            if
                not card.claimant
                and not blocked
                and board.open_children(card.epic) == 0
                and not board.labelled(card, board.NEEDS_HUMAN)
                and not board.labelled(card, board.RUN)
                and (not label or board.labelled(card, label))
                and board.fits(card, opts and opts.max_size)
            then
                return card
            end
        end
        cursor = present(page.next_cursor)
    until not cursor
end

---Report whether `blocked_by` links hold a card: a linked card holds it unless it is in Done, and
---a card that cannot be read holds it too.
---@param links dev.board.Link[] the links the card holds
---@return boolean? blocked, string? message
function Backend:__blocked(links)
    for _, link in ipairs(links) do
        if link.kind == "blocked_by" then
            local target
            if link.board then
                target = self:other_board(link.board):card(link.id)
            else
                local cards, message = self:cards()
                if not cards then
                    return nil, message
                end
                for _, card in ipairs(cards) do
                    if card.id == link.id then
                        target = card
                    end
                end
            end
            if not target or not target.done then
                return true
            end
        end
    end
    return false
end

function Backend:__color_id(color)
    local id = self.__ids[color]
    if not id then
        return nil, unavailable("the board has no " .. color .. " colour")
    end
    return id
end

function Backend:add(name, column, opts)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local id = self:__column_id(column)
    if not id then
        return nil, unavailable("the board has no " .. column .. " column")
    end
    local outcomes = opts and opts.outcomes or {}
    local final = id
    local roles = self:__roles()
    if #outcomes > 0 and column == roles.ready then
        id = self:__column_id(roles.backlog)
        if not id then
            return nil, unavailable("the board has no " .. roles.backlog .. " column")
        end
    end
    local body = { name = name, column_id = id }
    if opts and opts.epic then
        body.kind = board.Kind.EPIC
    end
    if opts and opts.color then
        body.color_id, message = self:__color_id(opts.color)
        if not body.color_id then
            return nil, message
        end
    end
    if opts and opts.description then
        body.description = opts.description
    end
    local locking = opts and opts.labels and listed(opts.labels, board.NEEDS_HUMAN)
    if opts and opts.labels and not locking then
        body.labels = opts.labels
    end
    if opts and opts.checks and #opts.checks > 0 then
        body.fields = { [board.CHECKS_FIELD] = table_rows(opts.checks) }
    end
    local task
    task, message = self:__request("POST", "/api/tasks", body)
    if not task then
        return nil, message
    end
    task.subtasks = {}
    for index, text in ipairs(outcomes) do
        local made
        made, message =
            self:__request("POST", "/api/tasks/" .. task.id .. "/subtasks", { name = text })
        if not made then
            local unlabelled = ""
            if locking and not self:set_labels(task.id, opts.labels) then
                unlabelled = " (its labels were not set either, so run dev board label on it)"
            end
            return nil,
                task.id:sub(1, board.MIN_PREFIX)
                    .. " was added to "
                    .. column
                    .. " but outcome "
                    .. index
                    .. " of "
                    .. #outcomes
                    .. " was not: "
                    .. message
                    .. unlabelled
        end
        task.subtasks[index] = { id = made.id, name = text, done = false }
    end
    if final ~= id then
        local moved
        moved, message = self:move(task.id, column)
        if not moved then
            return nil,
                task.id:sub(1, board.MIN_PREFIX)
                    .. " was added to "
                    .. roles.backlog
                    .. " with its outcomes but the move to "
                    .. column
                    .. " failed: "
                    .. message
        end
        task.column_id = final
    end
    if locking then
        local labelled
        labelled, message = self:set_labels(task.id, opts.labels)
        if not labelled then
            return nil,
                task.id:sub(1, board.MIN_PREFIX)
                    .. " was added to "
                    .. column
                    .. " but its labels were not set, so run dev board label on it: "
                    .. message
        end
        task.labels = opts.labels
    end
    return self:__card(task)
end

function Backend:note(id, body, fence, opts)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local made
    made, message = self:__request("POST", "/api/tasks/" .. id .. "/comments", {
        body = body,
        kind = opts and opts.kind or COMMENT_KIND,
        author = opts and opts.author,
    }, fence)
    if not made then
        return nil, message
    end
    return true
end

function Backend:escalate(id, tier, reason, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local made
    made, message = self:__request(
        "POST",
        "/api/tasks/" .. id .. "/escalate",
        { tier = tier, reason = reason },
        fence
    )
    if not made then
        return nil, message
    end
    return true
end

function Backend:ask(id, question, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local choices
    for index, choice in ipairs(question.choices) do
        local column = self:__column_id(choice.column)
        if not column then
            return nil, "choice " .. index .. " names " .. choice.column .. ", which is no column"
        end
        choices = choices or {}
        choices[index] = { label = choice.label, column_id = column }
    end
    local made
    made, message = self:__request("POST", "/api/tasks/" .. id .. "/comments", {
        kind = QUESTION_KIND,
        question = {
            text = question.text,
            choices = choices,
            recommended = question.recommended,
            why = question.why,
        },
    }, fence)
    if not made then
        return nil, message
    end
    return true
end

function Backend:answer(id, choice, quote, fence)
    local comments, message = self:comments(id)
    if not comments then
        return nil, message
    end
    local open
    for _, comment in ipairs(comments) do
        if comment.question and not present(comment.question.answer) then
            open = comment
        end
    end
    if not open then
        return nil, "the card holds no open question to answer"
    end
    local done
    done, message = self:__request(
        "POST",
        "/api/tasks/" .. id .. "/comments/" .. open.id .. "/answer",
        { choice = choice, quote = quote },
        fence
    )
    if not done then
        return nil, message
    end
    return true
end

function Backend:comments(id)
    local list, message = self:__request("GET", "/api/tasks/" .. id .. "/comments")
    if not list then
        return nil, message
    end
    local found = {}
    for _, comment in ipairs(list) do
        local author = present(comment.author)
        local actor = ACTORS[comment.actor_kind] or present(comment.actor_kind)
        found[#found + 1] = {
            id = comment.id,
            who = present(comment.token_name) or actor or "unknown",
            actor = actor,
            at = present(comment.created_at) or "",
            body = present(comment.body) or "",
            kind = present(comment.kind),
            author = author ~= DEFAULT_AUTHOR and author or nil,
            question = type(present(comment.question)) == "table" and comment.question or nil,
        }
    end
    return found
end

local function refused_comment(message, status, doc)
    if status == FORBIDDEN and not (type(doc) == "table" and doc.code == CARD_LOCKED) then
        return NOT_YOURS
    end
    return message
end

function Backend:edit_note(id, comment, body)
    local done, message, status, doc =
        self:__request("PATCH", "/api/tasks/" .. id .. "/comments/" .. comment, { body = body })
    if not done then
        return nil, refused_comment(message, status, doc)
    end
    return true
end

function Backend:delete_note(id, comment)
    local done, message, status, doc =
        self:__request("DELETE", "/api/tasks/" .. id .. "/comments/" .. comment)
    if not done then
        return nil, refused_comment(message, status, doc)
    end
    return true
end

function Backend:move(id, column, opts)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local target = self:__column_id(column)
    if not target then
        return nil, unavailable("the board has no " .. column .. " column")
    end
    opts = opts or {}
    local moved, status, doc
    moved, message, status, doc = self:__request(
        "POST",
        "/api/tasks/" .. id .. "/move",
        { column_id = target, position = opts.position or TOP },
        opts.fence
    )
    if not moved then
        if status == CONFLICT and type(doc) == "table" and doc.code == LIMIT_REACHED then
            return nil, present(doc.message) or message, FULL
        end
        return nil, message
    end
    return true
end

function Backend:set_size(id, color, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local color_id
    color_id, message = self:__color_id(color)
    if not color_id then
        return nil, message
    end
    local done
    done, message = self:__request("PATCH", "/api/tasks/" .. id, { color_id = color_id }, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:set_description(id, text, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local done
    done, message = self:__request("PATCH", "/api/tasks/" .. id, { description = text }, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:set_name(id, name, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local done
    done, message = self:__request("PATCH", "/api/tasks/" .. id, { name = name }, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:set_checks(id, runs, fence)
    return self:set_field(id, board.CHECKS_FIELD, table_rows(runs), fence)
end

function Backend:set_field(id, key, value, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local done
    done, message =
        self:__request("PATCH", "/api/tasks/" .. id, { fields = { [key] = value } }, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:set_labels(id, labels, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local done
    done, message = self:__request("PATCH", "/api/tasks/" .. id, { labels = labels }, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:make_epic(id, fence)
    local made, message =
        self:__request("PATCH", "/api/tasks/" .. id, { kind = board.Kind.EPIC }, fence)
    if not made then
        return nil, message
    end
    return true
end

function Backend:add_outcome(id, text, fence)
    local made, message =
        self:__request("POST", "/api/tasks/" .. id .. "/subtasks", { name = text }, fence)
    if not made then
        return nil, message
    end
    return true
end

function Backend:set_outcome(id, outcome, fields, fence)
    local done, message =
        self:__request("PATCH", "/api/tasks/" .. id .. "/subtasks/" .. outcome, fields, fence)
    if not done then
        return nil, message
    end
    return true
end

function Backend:delete_outcome(id, outcome, fence)
    local done, message, status, doc =
        self:__request("DELETE", "/api/tasks/" .. id .. "/subtasks/" .. outcome, nil, fence)
    if not done then
        local needs_lead = status == FORBIDDEN
            and type(doc) == "table"
            and doc.code == PERMISSION_DENIED
            and doc.permission == SUBTASKS_DELETE
        if needs_lead then
            return nil, NEEDS_LEAD
        end
        return nil, message
    end
    return true
end

---@private
---Call `__request` again after a short nap while Pomb answers 503 `busy`.
---@param method string the HTTP method
---@param path string the path under the server's URL
---@param file string? a file to send as the multipart body
---@return any? doc the decoded answer
---@return string? message why the call failed
---@return integer? status the HTTP status when pomb refused the call
---@return any? answer the decoded body of a refused call
function Backend:__patient(method, path, file)
    local busy_code = "busy"
    local busy_status = 503
    local busy_tries = 3
    local busy_nap_seconds = 2
    local upload_seconds = 600
    local doc, message, status, answer
    for tries = 1, busy_tries do
        doc, message, status, answer = self:__request(method, path, nil, nil, upload_seconds, file)
        local busy = status == busy_status and type(answer) == "table" and answer.code == busy_code
        if doc or not busy or tries == busy_tries then
            break
        end
        devos.nap(busy_nap_seconds)
    end
    return doc, message, status, answer
end

function Backend:attachments(id)
    local list, message = self:__patient("GET", "/api/tasks/" .. id .. "/attachments")
    if not list then
        return nil, message
    end
    local found = {}
    for _, row in ipairs(list) do
        found[#found + 1] = { id = row.id, name = row.name, size = row.size }
    end
    return found
end

function Backend:attach(id, path)
    local doc, message = self:__patient("POST", "/api/tasks/" .. id .. "/attachments", path)
    if not doc then
        return nil, message
    end
    local result = type(doc) == "table" and type(doc.results) == "table" and doc.results[1]
    if type(result) ~= "table" then
        return nil, unavailable("pomb sent an answer dev cannot read")
    end
    if type(result.error) == "table" then
        return nil, present(result.error.message) or present(result.error.code) or "refused"
    end
    local made = result.attachment
    if type(made) ~= "table" then
        return nil, unavailable("pomb sent an answer dev cannot read")
    end
    return { id = made.id, name = made.name, size = made.size }
end

function Backend:detach(id, attachment)
    local done, message =
        self:__patient("DELETE", "/api/tasks/" .. id .. "/attachments/" .. attachment)
    if not done then
        return nil, message
    end
    return true
end

function Backend:link(id, kind, other)
    local made, message =
        self:__request("POST", "/api/tasks/" .. id .. "/links", { kind = kind, target_id = other })
    if not made then
        return nil, message
    end
    return true
end

function Backend:links(id)
    local own, message = self:__board_id()
    if not own then
        return nil, message
    end
    local fetched
    fetched, message = self:__request("GET", "/api/tasks/" .. id .. "/links")
    if not fetched then
        return nil, message
    end
    local names
    local found = {}
    for _, link in ipairs(fetched) do
        local home = present(link.board_id)
        local name
        if home and home ~= own then
            if not names then
                local boards
                boards, message = self:__request("GET", "/api/boards")
                if not boards then
                    return nil, message
                end
                names = {}
                for _, entry in ipairs(boards) do
                    names[entry.id] = entry.name
                end
            end
            name = names[home] or home
        end
        found[#found + 1] = { kind = link.kind, id = link.target_id, board = name }
    end
    return found
end

---Remove the link of one kind from `source` to `target`, as the source's own tasks list it.
---@return boolean? removed true when a link was deleted, false when the source has none, nil and a message when Pomb refused
function Backend:__drop_link(source, kind, target)
    local fetched, message = self:__request("GET", "/api/tasks/" .. source .. "/links")
    if not fetched then
        return nil, message
    end
    for _, link in ipairs(fetched) do
        if link.kind == kind and link.target_id == target then
            local gone, status, doc
            gone, message, status, doc =
                self:__request("DELETE", "/api/tasks/" .. source .. "/links/" .. link.id)
            if gone then
                return true
            end
            if
                status == FORBIDDEN
                and type(doc) == "table"
                and doc.permission == LINKS_DELETE
                and present(doc.board_id) == nil
            then
                return nil,
                    "pomb kept the link: this token can delete only the links it created, and this one"
                        .. " was made by another token or before Pomb 0.5.40"
            end
            return nil, message
        end
    end
    return false
end

function Backend:unlink(id, kind, other)
    local source, held, target = id, kind, other
    if kind == "blocks" then
        source, held, target = other, "blocked_by", id
    end
    local removed, message = self:__drop_link(source, held, target)
    if removed == nil then
        return nil, message
    end
    if not removed and kind == "related" then
        removed, message = self:__drop_link(other, kind, id)
        if removed == nil then
            return nil, message
        end
    end
    if not removed then
        return nil, "pomb has no " .. kind .. " link from " .. id .. " to " .. other
    end
    return true
end

function Backend:family(id)
    local task, message = self:__request("GET", "/api/tasks/" .. id)
    if not task then
        return nil, message
    end
    local family = {}
    if type(task.parent) == "table" and type(task.parent.id) == "string" then
        family.parent = { id = task.parent.id, name = tostring(task.parent.name) }
    end
    family.epic = epic_counts(task) ~= nil
    if type(task.children_total) == "number" and task.children_total > 0 then
        family.children = { done = task.children_done or 0, total = task.children_total }
    end
    return family
end

function Backend:boards()
    local found, message = self:__request("GET", "/api/boards")
    if not found then
        return nil, message
    end
    local names = {}
    for _, entry in ipairs(found) do
        names[#names + 1] = entry.name
    end
    return names
end

function Backend:columns(name)
    local home = self
    if name and name ~= self.__opts.name then
        home = self:other_board(name)
    end
    local id, message = home:__board_id()
    if not id then
        return nil, message
    end
    local detail
    detail, message = home:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end
    local rows = {}
    for _, column in ipairs(detail.columns) do
        rows[#rows + 1] = {
            name = column.name,
            is_done = column.is_done == true,
            wip_limit = type(column.wip_limit) == "number" and column.wip_limit or nil,
        }
    end
    return rows
end

function Backend:limits(name)
    -- Limits change on Pomb at any time, so each call reads the board fresh
    local home = self
    if name and name ~= self.__opts.name then
        home = self:other_board(name)
    end
    local id, message = home:__board_id()
    if not id then
        return nil, message
    end
    local detail
    detail, message = home:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end

    -- Pomb names columns by id, so keep each column's name and board position to read the groups
    local limits, names, order = { columns = {}, units = {}, groups = {} }, {}, {}
    for index, column in ipairs(detail.columns) do
        names[column.id] = column.name
        order[column.id] = index
        if type(column.wip_limit) == "number" then
            limits.columns[column.name] = column.wip_limit
            limits.units[column.name] = type(column.limit_unit) == "string" and column.limit_unit
                or "count"
        end
    end

    -- A group lists column ids in any order, and dev reports them by name in board order
    local groups = detail.limit_groups
    for _, group in ipairs(groups == nil and {} or groups) do
        local ids = {}
        for _, column_id in ipairs(group.column_ids) do
            if names[column_id] then
                ids[#ids + 1] = column_id
            end
        end
        table.sort(ids, function(a, b)
            return order[a] < order[b]
        end)
        local columns = {}
        for _, column_id in ipairs(ids) do
            columns[#columns + 1] = names[column_id]
        end
        if #columns > 0 and type(group.limit) == "number" then
            limits.groups[#limits.groups + 1] = {
                columns = columns,
                limit = group.limit,
                count = type(group.count) == "number" and group.count or nil,
            }
        end
    end
    return limits
end

function Backend:limit_groups()
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local detail
    detail, message = self:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end
    local groups = detail.limit_groups
    return type(groups) == "table" and groups or {}
end

function Backend:add_limit_group(names, limit)
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local detail
    detail, message = self:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end
    local ids = {}
    for _, wanted in ipairs(names) do
        for _, column in ipairs(detail.columns) do
            if column.name:lower() == wanted:lower() then
                ids[#ids + 1] = column.id
                break
            end
        end
    end
    if #ids ~= #names then
        return nil, "the board lacks a column of " .. table.concat(names, ", ")
    end
    local made
    made, message = self:__request(
        "POST",
        "/api/boards/" .. id .. "/limit-groups",
        { column_ids = ids, limit = limit }
    )
    if not made then
        return nil, message
    end
    return true
end

function Backend:other_board(name)
    local opts = {}
    for key, value in pairs(self.__opts) do
        opts[key] = value
    end
    opts.name = name
    return setmetatable({
        __opts = opts,
        __secret = self.__secret,
        __filed = self.__filed,
        __reread = self.__reread,
        __healed = self.__healed,
    }, Backend)
end

local function escaped(word)
    return (
        word:gsub("[^%w%-%._~,]", function(char)
            return string.format("%%%02X", char:byte())
        end)
    )
end

function Backend:wait(after, kinds, timeout)
    local loaded, message = self:__load()
    if not loaded then
        return nil, message
    end
    timeout = timeout or WAIT_SECONDS
    local query = { "timeout=" .. string.format("%d", timeout) }
    if after then
        query[#query + 1] = "after=" .. escaped(after)
    end
    if kinds and #kinds > 0 then
        query[#query + 1] = "kinds=" .. escaped(table.concat(kinds, ","))
    end
    local doc, status, answer
    doc, message, status, answer = self:__request(
        "GET",
        "/api/boards/" .. self.__detail.id .. "/events/wait?" .. table.concat(query, "&"),
        nil,
        nil,
        timeout + WAIT_MARGIN_SECONDS
    )
    if not doc then
        if status == GONE and type(answer) == "table" and answer.code == CURSOR_EXPIRED then
            return nil, message, present(answer.oldest_cursor)
        end
        if
            status == TOO_MANY_REQUESTS
            and type(answer) == "table"
            and answer.code == TOO_MANY_WAITS
        then
            return nil, message, nil, true
        end
        return nil, message
    end
    local events = {}
    for _, event in ipairs(doc.events or {}) do
        local column, from = present(event.column_id), present(event.from_column_id)
        local function known(id)
            local name = id and self:__column_name(id)
            return name ~= "?" and name or nil
        end
        events[#events + 1] = {
            kind = event.kind,
            task_id = event.task_id,
            column = known(column),
            from_column = known(from),
            actor = ACTORS[event.actor_kind],
        }
    end
    return { cursor = doc.cursor, events = events }
end

function Backend:claim(id, claimant, ttl, fence)
    local body = { claimant = claimant, ttl_seconds = ttl, fence = fence }
    local claim, message = self:__request("POST", "/api/tasks/" .. id .. "/claim", body)
    if not claim then
        return nil, message
    end
    local taken = present(claim.fence)
    if type(taken) ~= "number" then
        return nil, unavailable("pomb sent a claim with no fence")
    end
    return taken
end

function Backend:release(id, fence)
    local done, message =
        self:__request("POST", "/api/tasks/" .. id .. "/claim/release", { fence = fence })
    if not done then
        return nil, message
    end
    return true
end

function Backend:keepalive(id, fence, ticks, state)
    local entry = entry_of(self.__opts.token)
    if not entry then
        return nil, BAD_REF
    end
    local out, code = devos.capture({
        "sh",
        "-c",
        'set -m; nohup "$@" </dev/null >/dev/null 2>&1 & echo $!',
        "sh",
        "bash",
        project.share .. KEEPALIVE_SCRIPT,
        state,
        id,
        string.format("%d", fence),
        string.format("%d", ticks),
        self.__opts.url,
        entry,
        string.format("%d", claims.TICK_SECONDS),
    }, { unset = CHILD_UNSET, stderr = "null" })
    local pid = tonumber(out:match("%d+"))
    if code ~= 0 or not pid then
        return nil, "cannot start the keep-alive loop"
    end
    return pid
end

local function plural(list)
    return #list > 0 and table.concat(list, ", ") or "none"
end

---Issue a role token as a child of the token in use and keep it in the file of
---`name`, deleting the expired token files on the way.
---
---The token goes to the file and nowhere else.
---@param role string the agent role's name
---@param name string the agent name to issue as, the `DEV_AGENT` of the runner
---@return {role: string, label: string, expires: integer}? issued what was issued, without the token
---@return string? message why nothing was issued
function Backend:mint(role, name)
    local roles, message = self:__request("GET", ROLES_LIST_PATH)
    if not roles then
        return nil, message
    end
    local id
    local names = {}
    for _, row in ipairs(type(roles) == "table" and roles or {}) do
        names[#names + 1] = present(row.name) or "?"
        if row.name == role then
            id = present(row.id)
        end
    end
    if not id then
        table.sort(names)
        return nil, "pomb has no agent role named " .. role .. ", the roles are " .. plural(names)
    end
    local reply, status, doc
    reply, message, status, doc =
        self:__request("POST", CHILDREN_PATH, { name = name, role_id = id })
    local code = type(doc) == "table" and doc.code or nil
    if status == CONFLICT then
        return nil,
            "another token already has the name "
                .. name
                .. ", pick another --as or wait for that token to expire"
    elseif status == HTTP_ERROR and code == UNKNOWN_ROLE then
        return nil, "pomb has no agent role named " .. role
    elseif status == FORBIDDEN and code == EXCEEDS_GRANT then
        return nil,
            "the token in use cannot issue the "
                .. role
                .. " role: it asks for more than this token holds or the role is granted on a board this token lacks ("
                .. (present(doc.message) or "no message")
                .. ")"
    elseif not reply then
        return nil, message
    end
    local raw = type(reply) == "table" and present(reply.raw_token)
    if not raw or not raw:find(TOKEN_PATTERN) then
        return nil, unavailable("pomb sent no usable token")
    end
    local expires = tonumber(reply.expires_at) or 0
    tokenfile.sweep(os.time())
    local ok
    ok, message = tokenfile.write(name, raw, expires)
    if not ok then
        return nil, "cannot keep the token: " .. message
    end
    return {
        role = present(reply.role_name) or role,
        label = present(reply.label) or "none",
        expires = expires,
    }
end

---Revoke the child token of the token in use that was issued as `name`, and
---delete the file of `name`.
---
---A name that no live child holds, or a token Pomb no longer knows, leaves
---nothing to revoke, and the file goes all the same. Pomb refusing the revoke
---keeps the file.
---@param name string the agent name the token was issued as
---@return {revoked: boolean}? done whether a token was revoked, false when none was left
---@return string? message why it failed
function Backend:revoke(name)
    local children, message = self:__request("GET", CHILDREN_PATH)
    if not children then
        return nil, message
    end
    local id
    for _, row in ipairs(type(children) == "table" and children or {}) do
        if row.name == name then
            id = present(row.id)
            break
        end
    end
    local revoked = false
    if id then
        local reply, status
        reply, message, status = self:__request("DELETE", CHILDREN_PATH .. "/" .. id)
        if reply then
            revoked = true
        elseif status ~= NOT_FOUND then
            return nil, message
        end
    end
    local ok
    ok, message = tokenfile.remove(name)
    if not ok then
        return nil, "revoked the token but " .. message
    end
    return { revoked = revoked }
end

---Use a token already in hand instead of reading one with `pass`.
---@param secret string the token, held in memory only
function Backend:authorize(secret)
    self.__secret = secret
end

---Check that the token in use is an admin token, on either server shape.
---
---A server that reports a `scope` is admin when it says so. A server that
---reports `permissions` and `boards` is admin when the token holds every
---permission the catalog lists for the admin preset and is assigned all boards.
---@return boolean? ok true when the token is admin
---@return string? message why not, or why it could not be read
function Backend:admin()
    local who, message = self:__request("GET", WHOAMI_PATH)
    if not who then
        return nil, message
    end
    if type(who.permissions) ~= "table" then
        local scope = present(who.scope) or "none"
        if scope ~= ADMIN then
            return nil, "the approved token has the " .. scope .. " scope, init needs admin"
        end
        return true
    end
    local catalog
    catalog, message = self:__request("GET", "/api/v1/auth/permissions")
    if not catalog then
        return nil, message
    end
    local held = {}
    for _, name in ipairs(who.permissions) do
        held[name] = true
    end
    local missing, wanted = {}, 0
    for _, entry in ipairs(catalog) do
        local presets = type(entry.presets) == "table" and entry.presets or {}
        if present(entry.name) and listed(presets, ADMIN) then
            wanted = wanted + 1
            if not held[entry.name] then
                missing[#missing + 1] = entry.name
            end
        end
    end
    if wanted == 0 then
        return nil, "the permission catalog lists no admin preset, so the token cannot be checked"
    end
    if #missing > 0 then
        return nil,
            "the approved token lacks the "
                .. table.concat(missing, ", ")
                .. " permission, init needs the admin preset"
    end
    if who.boards ~= ALL_BOARDS then
        return nil, "the approved token is assigned only some boards, init needs all of them"
    end
    return true
end

---Say why the board is not in the list the token sees.
---
---A server that reports the token's boards may be hiding the board by
---assignment, which looks the same as a board that does not exist.
---@private
---@return string message the reason
function Backend:__missing()
    local name = self.__opts.name
    local who = self:__request("GET", WHOAMI_PATH)
    if type(who) == "table" and type(who.boards) == "table" then
        local names = {}
        for _, entry in ipairs(who.boards) do
            names[#names + 1] = tostring(present(entry.name) or present(entry.id))
        end
        return unavailable(
            "pomb lists no board named "
                .. name
                .. " for this token, which is assigned only to "
                .. (#names > 0 and table.concat(names, ", ") or "no boards")
                .. "; if the board exists, add it to the token"
        )
    end
    return unavailable("pomb has no board named " .. name)
end
---Find the board's id by name, asking once.
---@private
---@return string? id the board's id
---@return string? message why it cannot be found
function Backend:__board_id()
    if self.__id then
        return self.__id
    end
    local boards, message = self:__request("GET", "/api/boards")
    if not boards then
        return nil, message
    end
    for _, entry in ipairs(boards) do
        if entry.name == self.__opts.name then
            self.__id = entry.id
            return entry.id
        end
    end
    return nil, self:__missing()
end

function Backend:find()
    local boards, message = self:__request("GET", "/api/boards")
    if not boards then
        return nil, message
    end
    for _, entry in ipairs(boards) do
        if entry.name == self.__opts.name then
            self.__id = entry.id
            return true
        end
    end
    return false
end

function Backend:create()
    local templates, message = self:__request("GET", "/api/templates")
    if not templates then
        return nil, message
    end
    local body = { name = self.__opts.name }
    local used
    for _, template in ipairs(templates) do
        if template.name == TEMPLATE then
            body.template_id = template.id
            used = template.name
        end
    end
    local made
    made, message = self:__request("POST", "/api/boards", body)
    if not made then
        return nil, message
    end
    self.__id = made.id
    self.__detail = nil
    self.__field_keys = nil
    return true, used
end

function Backend:read()
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local detail
    detail, message = self:__request("GET", "/api/boards/" .. id)
    if not detail then
        return nil, message
    end
    local palette
    palette, message = self:__request("GET", "/api/boards/" .. id .. "/colors")
    if not palette then
        return nil, message
    end
    local export
    export, message = self:__request("GET", "/api/boards/" .. id .. "/export-data")
    if not export then
        return nil, message
    end
    local fields
    fields, message = self:__fields(id)
    if not fields then
        return nil, message
    end
    local has_checks = false
    for _, field in ipairs(fields) do
        has_checks = has_checks or field.key == board.CHECKS_FIELD
    end
    local columns, colors, cards = {}, {}, {}
    for _, column in ipairs(detail.columns) do
        local blocked = column.is_blocked
        if type(blocked) ~= "boolean" then
            blocked = nil
        end
        columns[#columns + 1] = {
            id = column.id,
            name = column.name,
            is_done = column.is_done == true,
            is_blocked = blocked,
        }
    end
    for _, color in ipairs(palette) do
        colors[#colors + 1] = {
            id = color.id,
            value = color.value,
            label = color.label,
            description = color.description or "",
            is_default = color.is_default == true,
            enabled = color.enabled ~= false,
        }
    end
    for _, task in ipairs(export.tasks) do
        cards[#cards + 1] = {
            id = task.id,
            name = task.name,
            color_id = present(task.color_id),
        }
    end
    return { columns = columns, colors = colors, cards = cards, has_checks = has_checks }
end

function Backend:add_checks_field()
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local made
    made, message = self:__request("POST", "/api/boards/" .. id .. "/fields", CHECKS_DEFINITION)
    if not made then
        return nil, message
    end
    self.__field_keys = nil
    return true
end

function Backend:add_roles()
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local reply, status, doc
    reply, message, status, doc = self:__request("POST", ROLES_PATH, { boards = { id } })
    if not reply then
        if status == FORBIDDEN and type(doc) == "table" and doc.code == EXCEEDS_GRANT then
            return nil,
                unavailable(
                    "the token"
                        .. (self:__role() and (" (role " .. self:__role() .. ")") or "")
                        .. " does not hold board "
                        .. self.__opts.name
                        .. " ("
                        .. id
                        .. "), so it cannot be granted the standard roles; add the board to the token"
                )
        end
        return nil, message
    end
    local created = {}
    if type(reply) == "table" and type(reply.created) == "table" then
        for _, entry in ipairs(reply.created) do
            created[#created + 1] = type(entry) == "table" and entry.name or entry
        end
    end
    return created
end

function Backend:add_column(name, is_done)
    local id, message = self:__board_id()
    if not id then
        return nil, message
    end
    local made
    made, message =
        self:__request("POST", "/api/columns", { board_id = id, name = name, is_done = is_done })
    if not made then
        return nil, message
    end
    return true
end

function Backend:rename_column(id, name)
    local renamed, message = self:__request("PATCH", "/api/columns/" .. id, { name = name })
    if not renamed then
        return nil, message
    end
    return true
end

function Backend:move_column(id, position)
    local moved, message = self:__request("POST", "/api/columns/" .. id .. "/move", {
        position = position,
    })
    if not moved then
        return nil, message
    end
    return true
end

function Backend:mark_done(id)
    local done, message = self:__request("PATCH", "/api/columns/" .. id, { is_done = true })
    if not done then
        return nil, message
    end
    return true
end

function Backend:mark_blocked(id)
    local done, message = self:__request("PATCH", "/api/columns/" .. id, { is_blocked = true })
    if not done then
        return nil, message
    end
    return true, nil, true
end

function Backend:set_color(id, fields)
    local board_id, message = self:__board_id()
    if not board_id then
        return nil, message
    end
    local done
    done, message = self:__request("PATCH", "/api/boards/" .. board_id .. "/colors/" .. id, fields)
    if not done then
        return nil, message
    end
    return true
end

function Backend:bin(id)
    local done, message = self:__request("DELETE", "/api/tasks/" .. id)
    if not done then
        return nil, message
    end
    return true
end

function Backend:set_card(id, fields)
    local done, message = self:__request("PATCH", "/api/tasks/" .. id, fields)
    if not done then
        return nil, message
    end
    return true
end

return M
