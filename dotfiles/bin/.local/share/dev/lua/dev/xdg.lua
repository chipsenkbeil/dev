---@class dev.xdg
local M = {}

---Find the directory that holds a user's state files.
---@return string dir the absolute XDG state variable when it is set, else `$HOME/.local/state`
function M.state_home()
    local home = os.getenv("XDG_STATE_HOME")
    if not home or home:sub(1, 1) ~= "/" then
        home = (os.getenv("HOME") or "") .. "/.local/state"
    end
    return home
end

return M
