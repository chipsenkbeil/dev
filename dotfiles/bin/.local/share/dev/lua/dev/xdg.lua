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

---Find the directory that holds a user's config files.
---@return string dir the absolute XDG config variable when it is set, else `$HOME/.config`
function M.config_home()
    local home = os.getenv("XDG_CONFIG_HOME")
    if not home or home:sub(1, 1) ~= "/" then
        home = (os.getenv("HOME") or "") .. "/.config"
    end
    return home
end

return M
