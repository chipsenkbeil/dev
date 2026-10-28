local board = require("dev.board")
local claims = require("dev.board.claims")
local devos = require("dev.os")
local json = require("dev.json")
local project = require("dev.project")

local present = json.present
local PASS_TIMEOUT_SECONDS = "10"
local PASS_GPG_OPTS = "--pinentry-mode error --batch"
local CONNECT_SECONDS = "10"
local REQUEST_SECONDS = "30"
local TIMED_OUT = 124
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"
local ENTRY_PATTERN = "^[%w_./][%w_. /-]*$"
local URL_PATTERN = "^https?://[%w%.%-]+:?%d*[%w%._~/%-]*$"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }
local HTTP_ERROR = 400
local TOP = 0
local COMMENT_KIND = "agent"
local BAD_REF = "the token must be pass:<entry> in [board.pomb] of ~/.config/dev/config.toml"
local KEEPALIVE_SCRIPT = "/board/keepalive.sh"
local TEMPLATE = "agent project"
local UTC_STAMP = "!%Y-%m-%dT%H:%M:%S"
local STAMP_CHARS = 19
local PAGE_LIMIT = 500
local FORBIDDEN = 403
local NOT_YOURS = "that comment is not yours to change"

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

---@class dev.board.pomb.Detail
---@field id string the board's id
---@field columns {id: string, name: string}[] the columns in board order

---@class dev.board.pomb.Backend: dev.board.Backend, dev.board.Layout
---@field private __opts dev.board.pomb.Opts the server, token reference and board name
---@field private __secret string? the token, nil until the first request
---@field private __detail dev.board.pomb.Detail? the board with its columns
---@field private __colors table<string, string>? palette labels by colour id
---@field private __values table<string, string>? palette colour values by colour id
---@field private __ids table<string, string>? palette colour ids by colour value
---@field private __id string? the board's id, once found or created
local Backend = {}
Backend.__index = Backend

local function unavailable(reason)
    return "board unavailable: " .. reason
end

local function entry_of(ref)
    local entry = type(ref) == "string" and ref:match("^pass:(.+)$")
    if entry and entry:find(ENTRY_PATTERN) and not entry:find("..", 1, true) then
        return entry
    end
end

---Read the worker token with `pass`, without a prompt.
---
---A locked store fails at once instead of waiting for a pinentry.
---@param ref string `pass:<entry>`
---@return string? token the token
---@return string? message why it could not be read
function M.token(ref)
    local entry = entry_of(ref)
    if not entry then
        return nil, BAD_REF
    end
    local out, code = devos.capture({ "timeout", PASS_TIMEOUT_SECONDS, "pass", "show", entry }, {
        env = { PASSWORD_STORE_GPG_OPTS = PASS_GPG_OPTS },
        unset = CHILD_UNSET,
        stdin = "null",
        stderr = "null",
    })
    if code == TIMED_OUT then
        return nil, unavailable("pass timed out")
    elseif code ~= 0 then
        return nil, unavailable("pass is locked or has no entry " .. entry)
    end
    local token = out:match("^[^\n]*")
    if not token:find(TOKEN_PATTERN) then
        return nil, unavailable("pass gave a token that is empty or not plain text")
    end
    return token
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
---@return any? doc the decoded answer
---@return string? message why the call failed
---@return integer? status the HTTP status when pomb refused the call
function Backend:__request(method, path, body, fence)
    if not self.__secret then
        local token, message = M.token(self.__opts.token)
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
        REQUEST_SECONDS,
        "-K",
        "-",
        "-X",
        method,
        "-H",
        "Content-Type: application/json",
        "-w",
        "\n%{http_code}",
    }
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
    if status >= HTTP_ERROR then
        local detail = type(doc) == "table" and present(doc.message) or "no message"
        return nil, unavailable("pomb answered " .. status .. ": " .. tostring(detail)), status
    end
    return doc
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
        return nil, unavailable("pomb has no board named " .. self.__opts.name)
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

function Backend:__card(task)
    return {
        claimant = holder(task.claim),
        id = task.id,
        name = task.name,
        column = self:__column_name(task.column_id),
        size = board.size(self.__colors[present(task.color_id)]),
        color = present(task.color_id) and (self.__values[task.color_id] or "unknown") or nil,
        labels = task.labels or {},
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

function Backend:next()
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local ready = self:__column_id(board.READY)
    if not ready then
        return nil, unavailable("the board has no Ready column")
    end
    local page
    page, message = self:__request(
        "GET",
        "/api/boards/"
            .. self.__detail.id
            .. "/tasks?limit=1&ready=true&claimed=false&column_id="
            .. ready
    )
    if not page then
        return nil, message
    end
    local top = page.items[1]
    if not top then
        return nil
    end
    local task
    task, message = self:__request("GET", "/api/tasks/" .. top.id)
    if not task then
        return nil, message
    end
    return self:__card(task)
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
    local body = { name = name, column_id = id }
    if opts and opts.color then
        body.color_id, message = self:__color_id(opts.color)
        if not body.color_id then
            return nil, message
        end
    end
    if opts and opts.description then
        body.description = opts.description
    end
    if opts and opts.labels then
        body.labels = opts.labels
    end
    local task
    task, message = self:__request("POST", "/api/tasks", body)
    if not task then
        return nil, message
    end
    return self:__card(task)
end

function Backend:note(id, body, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local made
    made, message = self:__request("POST", "/api/tasks/" .. id .. "/comments", {
        body = body,
        kind = COMMENT_KIND,
    }, fence)
    if not made then
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
        found[#found + 1] = {
            id = comment.id,
            who = present(comment.token_name) or present(comment.actor_kind) or "unknown",
            at = present(comment.created_at) or "",
            body = present(comment.body) or "",
        }
    end
    return found
end

function Backend:edit_note(id, comment, body)
    local done, message, status =
        self:__request("PATCH", "/api/tasks/" .. id .. "/comments/" .. comment, { body = body })
    if not done then
        return nil, status == FORBIDDEN and NOT_YOURS or message
    end
    return true
end

function Backend:delete_note(id, comment)
    local done, message, status =
        self:__request("DELETE", "/api/tasks/" .. id .. "/comments/" .. comment)
    if not done then
        return nil, status == FORBIDDEN and NOT_YOURS or message
    end
    return true
end

function Backend:move(id, column, fence)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local target = self:__column_id(column)
    if not target then
        return nil, unavailable("the board has no " .. column .. " column")
    end
    local moved
    moved, message = self:__request(
        "POST",
        "/api/tasks/" .. id .. "/move",
        { column_id = target, position = TOP },
        fence
    )
    if not moved then
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

---Use a token already in hand instead of reading one with `pass`.
---@param secret string the token, held in memory only
function Backend:authorize(secret)
    self.__secret = secret
end

---Ask which scope the token in use carries.
---@return string? scope the token's scope, nil when it could not be read
---@return string? message why it could not be read
function Backend:scope()
    local who, message = self:__request("GET", "/api/v1/auth/whoami")
    if not who then
        return nil, message
    end
    return present(who.scope) or "none"
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
    return nil, unavailable("pomb has no board named " .. self.__opts.name)
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
    local columns, colors, cards = {}, {}, {}
    for _, column in ipairs(detail.columns) do
        columns[#columns + 1] = {
            id = column.id,
            name = column.name,
            is_done = column.is_done == true,
        }
    end
    for _, color in ipairs(palette) do
        colors[#colors + 1] = {
            id = color.id,
            value = color.value,
            label = color.label,
            description = color.description or "",
            is_default = color.is_default == true,
        }
    end
    for _, task in ipairs(export.tasks) do
        cards[#cards + 1] = {
            id = task.id,
            name = task.name,
            color_id = present(task.color_id),
        }
    end
    return { columns = columns, colors = colors, cards = cards }
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

function Backend:set_card(id, fields)
    local done, message = self:__request("PATCH", "/api/tasks/" .. id, fields)
    if not done then
        return nil, message
    end
    return true
end

return M
