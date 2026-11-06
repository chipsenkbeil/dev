local ffi = require("ffi")

local t = require("dev.testing")
local claims = require("dev.board.claims")
local store = require("dev.board.store")
local xdg = require("dev.xdg")

ffi.cdef([[int unsetenv(const char *name);]])

local function with_state(value, body)
    local previous = os.getenv("XDG_STATE_HOME")
    if value then
        ffi.C.setenv("XDG_STATE_HOME", value, 1)
    else
        ffi.C.unsetenv("XDG_STATE_HOME")
    end
    local ok, err = pcall(body)
    if previous then
        ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    else
        ffi.C.unsetenv("XDG_STATE_HOME")
    end
    assert(ok, err)
end

t.test("state-dir-absolute uses an absolute XDG_STATE_HOME as given", function()
    with_state("/srv/state", function()
        t.eq(xdg.state_home(), "/srv/state")
    end)
end)

t.test("state-dir-relative falls back to the home default for a relative or empty value", function()
    local home = os.getenv("HOME") or ""
    for _, value in ipairs({ "state", "" }) do
        with_state(value, function()
            t.eq(xdg.state_home(), home .. "/.local/state", value)
            t.eq(claims.dir(), home .. "/.local/state/dev/board", value)
            t.eq(store.dir(), home .. "/.local/state/dev/boards", value)
        end)
    end
    with_state(nil, function()
        t.eq(xdg.state_home(), home .. "/.local/state")
    end)
end)

t.test("state-dir-paths-kept leaves the claim and board files where they were", function()
    with_state("/srv/state", function()
        t.eq(claims.dir(), "/srv/state/dev/board")
        t.eq(store.dir(), "/srv/state/dev/boards")
    end)
end)
