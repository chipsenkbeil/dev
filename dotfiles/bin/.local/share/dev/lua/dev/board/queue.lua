local fs = require("dev.fs")
local json = require("dev.json")
local store = require("dev.board.store")

local PRIVATE = { private = true }
local FILE_NAME_UNSAFE = "[^%w._-]"

---The changes made while Pomb could not be reached, kept in order in one file
---beside the local boards. The file holds the commands as typed and never a
---token, and only its owner can read it.
---@class dev.board.queue
local M = { Replay = { DONE = "done", STOP = "stop" } }

---@class dev.board.queue.Entry
---@field sub string the subcommand, such as `move`
---@field args string[] its arguments as typed
---@field at string when it was queued, as an RFC 3339 stamp

---@class dev.board.queue.Queue
---@field path string the queue's file
local Queue = {}
Queue.__index = Queue

---Open the queue of a board.
---@param name string the board's name
---@return dev.board.queue.Queue queue the queue, which may be empty
function M.new(name)
    local safe = name:gsub(FILE_NAME_UNSAFE, "_")
    return setmetatable({ path = store.dir() .. "/" .. safe .. ".queue" }, Queue)
end

local function line_of(text, offset)
    local _, breaks = text:sub(1, offset - 1):gsub("\n", "")
    return breaks + 1
end

local function load(path)
    if not fs.exists(path) then
        return {}
    end
    local text, err = fs.read(path)
    if not text then
        return nil, "cannot read " .. path .. ": " .. tostring(err)
    end
    local doc, message = json.decode(text)
    if doc == nil then
        local offset = tonumber(tostring(message):match("offset (%d+)")) or 1
        return nil, path .. ":" .. line_of(text, offset) .. ": " .. tostring(message)
    end
    if type(doc) ~= "table" or doc == json.null or (next(doc) ~= nil and doc[1] == nil) then
        return nil, path .. ":1: not a list of queued commands"
    end
    for index, entry in ipairs(doc) do
        if type(entry) ~= "table" or type(entry.sub) ~= "string" or type(entry.args) ~= "table" then
            return nil, path .. ": entry " .. index .. " is not a queued command"
        end
    end
    return doc
end

local function save(path, entries)
    if #entries == 0 then
        os.remove(path)
        return true
    end
    local text, err = json.encode(entries)
    if not text then
        return nil, err
    end
    return store.write(path, text .. "\n", PRIVATE)
end

---List the queued changes.
---@return dev.board.queue.Entry[]? entries the changes in the order they were made
---@return string? message why the file could not be read
function Queue:list()
    return load(self.path)
end

---Count the queued changes.
---@return integer? count how many are waiting, 0 when there is no file, nil when it is malformed
---@return string? message why the file could not be used
function Queue:count()
    local entries, message = load(self.path)
    if not entries then
        return nil, message
    end
    return #entries
end

---Add a change at the end.
---@param sub string the subcommand
---@param args string[] its arguments as typed
---@return true? ok true on success
---@return string? message why it could not be kept
function Queue:push(sub, args)
    return store.locked(self.path, PRIVATE, function()
        local entries, message = load(self.path)
        if not entries then
            return nil, message
        end
        entries[#entries + 1] = { sub = sub, args = args, at = store.stamp() }
        return save(self.path, entries)
    end)
end

---Replay the changes in order while holding the queue's lock.
---
---Each change leaves the file as soon as `replay` has dealt with it. A process
---that dies while `replay` runs leaves that change queued, so delivery is at
---least once. The first change that `replay` answers `M.Replay.STOP` for stays,
---with every change behind it.
---@param replay fun(entry: dev.board.queue.Entry): "done"|"stop" deals with one change
---@return integer? handled how many left the queue, nil when the file could not be used
---@return string? message why it could not be used
function Queue:drain(replay)
    return store.locked(self.path, PRIVATE, function()
        local entries, message = load(self.path)
        if not entries then
            return nil, message
        end
        local handled = 0
        while #entries > 0 do
            if replay(entries[1]) == M.Replay.STOP then
                break
            end
            table.remove(entries, 1)
            handled = handled + 1
            local ok, err = save(self.path, entries)
            if not ok then
                return nil, err
            end
        end
        return handled
    end)
end

return M
