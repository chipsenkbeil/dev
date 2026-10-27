local board = require("dev.board")
local devos = require("dev.os")
local json = require("dev.json")

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

---Pomb over its HTTP API, through curl.
---
---The token comes from `pass` and goes to curl on standard input as a config
---line, so it is in no argument list, no environment variable, no file and no
---output.
---@class dev.board.pomb
local M = {}

---@class dev.board.pomb.Opts
---@field url string the server's base URL
---@field token string `pass:<entry>`, where the worker token is kept
---@field name string the board's name

---@class dev.board.pomb.Detail
---@field id string the board's id
---@field columns {id: string, name: string}[] the columns in board order

---@class dev.board.pomb.Backend: dev.board.Backend
---@field private __opts dev.board.pomb.Opts the server, token reference and board name
---@field private __secret string? the worker token, nil until the first request
---@field private __detail dev.board.pomb.Detail? the board with its columns
---@field private __colors table<string, string>? palette labels by colour id
local Backend = {}
Backend.__index = Backend

local function unavailable(reason)
    return "board unavailable: " .. reason
end

---Read the worker token with `pass`, without a prompt.
---
---A locked store fails at once instead of waiting for a pinentry.
---@param ref string `pass:<entry>`
---@return string? token the token
---@return string? message why it could not be read
function M.token(ref)
    local entry = type(ref) == "string" and ref:match("^pass:(.+)$")
    if not entry or not entry:find(ENTRY_PATTERN) or entry:find("..", 1, true) then
        return nil, "the token must be pass:<entry> in [board.pomb] of ~/.config/dev/config.toml"
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
---@return any? doc the decoded answer
---@return string? message why the call failed
function Backend:__request(method, path, body)
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
    local doc = text and json.decode(text)
    status = tonumber(status)
    if not status or doc == nil then
        return nil, unavailable("pomb sent an answer dev cannot read")
    end
    if status >= HTTP_ERROR then
        local detail = type(doc) == "table" and present(doc.message) or "no message"
        return nil, unavailable("pomb answered " .. status .. ": " .. tostring(detail))
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
    self.__colors = {}
    for _, color in ipairs(palette) do
        self.__colors[color.id] = color.label
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

function Backend:__card(task)
    return {
        id = task.id,
        name = task.name,
        column = self:__column_name(task.column_id),
        size = board.size(self.__colors[present(task.color_id)]),
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

function Backend:add(name, column, description)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local id = self:__column_id(column)
    if not id then
        return nil, unavailable("the board has no " .. column .. " column")
    end
    local body = { name = name, column_id = id }
    if description then
        body.description = description
    end
    local task
    task, message = self:__request("POST", "/api/tasks", body)
    if not task then
        return nil, message
    end
    return self:__card(task)
end

function Backend:note(id, body)
    local ok, message = self:__load()
    if not ok then
        return nil, message
    end
    local made
    made, message = self:__request("POST", "/api/tasks/" .. id .. "/comments", {
        body = body,
        kind = COMMENT_KIND,
    })
    if not made then
        return nil, message
    end
    return true
end

function Backend:move(id, column)
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
        { column_id = target, position = TOP }
    )
    if not moved then
        return nil, message
    end
    return true
end

return M
