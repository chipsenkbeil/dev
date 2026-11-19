local dev_os = require("dev.os")
local fs = require("dev.fs")
local xdg = require("dev.xdg")

local STATE_NAME = "dev/board"
local LOOP_MARK = "board/keepalive.sh"
local CAP_MINUTES = { ["1 pomodoro"] = 50, ["2 pomodori"] = 100 }
local CAP_DEFAULT_MINUTES = 150

---The claims `dev board take` holds: one state file per card, with the pid of
---the keep-alive loop and the fence of the claim. A state file never holds the
---token.
---@class dev.board.claims
local M = {}

---@class dev.board.claims.State
---@field card string the card's full id
---@field fence integer the fence of the claim
---@field pid integer? the keep-alive loop's process id

---The minutes between two renewals.
M.TICK_MINUTES = 5

---The seconds between two renewals.
M.TICK_SECONDS = M.TICK_MINUTES * 60

---The claim's lease in seconds.
M.TTL_SECONDS = 900

---Find the directory that holds the state files.
---@return string dir the `dev/board` directory under the state home
function M.dir()
    return xdg.state_home() .. "/" .. STATE_NAME
end

---Name the state file of a card.
---@param card string the card's full id
---@return string path the file
function M.path(card)
    return M.dir() .. "/" .. card
end

---Count the renewals a card's loop may make before it ends by itself.
---
---The loop lives for twice the card's size: 50 minutes for 1 Pomodoro, 100 for
---2 Pomodori and 150 for anything else, or the given seconds when those run
---longer.
---@param size string the card's size label
---@param seconds integer? the seconds a stretch of work needs the claim for
---@return integer ticks the renewals
---@return integer minutes the loop's lifetime in minutes
function M.cap(size, seconds)
    local minutes = CAP_MINUTES[size:lower()] or CAP_DEFAULT_MINUTES
    if seconds then
        minutes = math.max(minutes, math.ceil(seconds / 60))
    end
    return math.ceil(minutes / M.TICK_MINUTES), minutes
end

---Read a card's state.
---@param card string the card's full id
---@return dev.board.claims.State? state the state, nil when the card has none
function M.read(card)
    local text = fs.read(M.path(card))
    local fence = text and tonumber(text:match("fence=(%d+)"))
    if not fence then
        return nil
    end
    return { card = card, fence = fence, pid = tonumber(text:match("pid=(%d+)")) }
end

---Write a card's state with mode 600.
---@param state dev.board.claims.State the state to keep
---@return true? ok true on success
---@return string? message why it failed
function M.write(state)
    local dir = M.dir()
    local ok, message = fs.mkdir(dir, { parents = true })
    if not ok then
        return nil, message
    end
    local path = M.path(state.card)
    local pending = path .. ".new"
    if dev_os.run({ "chmod", "700", dir }) ~= 0 then
        return nil, "cannot protect " .. dir
    end
    local made = dev_os.run({ "sh", "-c", 'umask 077 && : >"$1"', "sh", pending })
    if made ~= 0 then
        return nil, "cannot write " .. path
    end
    local body =
        string.format("card=%s\nfence=%d\npid=%d\n", state.card, state.fence, state.pid or 0)
    ok, message = fs.write(pending, body)
    if not ok then
        return nil, message
    end
    if dev_os.run({ "mv", "-f", pending, path }) ~= 0 then
        return nil, "cannot write " .. path
    end
    return true
end

local function alive(pid)
    local out = dev_os.capture({ "ps", "-p", tostring(pid), "-o", "command=" }, { stderr = "null" })
    return out:find(LOOP_MARK, 1, true) ~= nil
end

---End a landed card's claim, sending a release only when the claim file held a fence.
---@param backend dev.board.Backend the board backend
---@param card string the card's full id
---@param held dev.board.claims.State? the claim state read before the landing
---@return boolean? sent true when the release went, false when it failed, nil when no fence exists
---@return string? stuck why the release failed
function M.finish(backend, card, held)
    M.stop(card)
    if not held then
        return nil
    end
    local released, stuck = backend:release(card, held.fence)
    return released and true or false, stuck
end

---Stop a card's loop and forget its claim state.
---@param card string the card's full id
---@return dev.board.claims.State? state what was kept, nil when the card had no state
function M.stop(card)
    local state = M.read(card)
    if not state then
        return nil
    end
    fs.remove(M.path(card))
    if state.pid and state.pid > 0 and alive(state.pid) then
        dev_os.run({ "kill", tostring(state.pid) }, { stderr = "null" })
    end
    return state
end

---Keep a card's state with a new loop and stop the loop it had.
---@param state dev.board.claims.State the state with the new loop's pid
---@param old_pid integer? the pid of the loop to stop
---@return true? ok true on success
---@return string? message why the state could not be written
function M.replace(state, old_pid)
    local ok, message = M.write(state)
    if ok and old_pid and old_pid > 0 and old_pid ~= state.pid and alive(old_pid) then
        dev_os.run({ "kill", tostring(old_pid) }, { stderr = "null" })
    end
    return ok, message
end

return M
