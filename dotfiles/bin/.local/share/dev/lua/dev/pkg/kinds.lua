---@class dev.pkg.kinds
local M = {}

---@enum dev.pkg.Scope
M.Scope = { SYSTEM = "system", USER = "user", THIRD_PARTY = "third_party" }

---@enum dev.pkg.Channel
M.Channel = {
    BARE = "",
    CASK = "cask",
    TAP = "tap",
    AUR = "aur",
    COPR = "copr",
    CARGO = "cargo",
    FLATPAK = "flatpak",
    LUAROCKS = "luarocks",
    RELEASE = "release",
    SCRIPT = "script",
}

---@enum dev.pkg.Manager
M.Manager = { BREW = "brew", PACMAN = "pacman", DNF = "dnf", APT = "apt" }

---The package manager each binary on PATH stands for, in the order they are tried on Linux.
---@type { binary: string, manager: dev.pkg.Manager }[]
M.LINUX_MANAGERS = {
    { binary = "pacman", manager = M.Manager.PACMAN },
    { binary = "dnf", manager = M.Manager.DNF },
    { binary = "apt-get", manager = M.Manager.APT },
}

---@enum dev.pkg.Verb
M.Verb = { INSTALL = "install", REINSTALL = "reinstall" }

---The binary column value that means there is no command to probe.
M.NO_PROBE_BINARY = "-"

---The drivers that have a module, by name.
---@type table<string, boolean>
M.DRIVERS = {
    [M.Manager.BREW] = true,
    [M.Manager.PACMAN] = true,
    [M.Manager.DNF] = true,
    [M.Channel.CARGO] = true,
    [M.Channel.LUAROCKS] = true,
    [M.Channel.SCRIPT] = true,
    [M.Channel.RELEASE] = true,
}

local C, S = M.Channel, M.Scope
local ROUTES = {
    [C.CARGO] = { scope = S.USER, driver = C.CARGO },
    [C.FLATPAK] = { scope = S.USER, driver = C.FLATPAK },
    [C.SCRIPT] = { scope = S.USER, driver = C.SCRIPT },
    [C.RELEASE] = { scope = S.USER, driver = C.RELEASE },
    [C.LUAROCKS] = { scope = S.THIRD_PARTY, driver = C.LUAROCKS },
    [C.AUR] = { scope = S.THIRD_PARTY },
    [C.COPR] = { scope = S.THIRD_PARTY },
}

---Decide who installs a channel and which driver handles it.
---
---A channel with no driver of its own, and every unknown one, goes to the primary manager.
---@param channel string the cell's channel
---@param manager dev.pkg.Manager the primary manager of this OS
---@return dev.pkg.Scope scope the party that installs it
---@return string driver the driver's name, `brew` for `dev.pkg.brew`
function M.route(channel, manager)
    local route = ROUTES[channel]
    if not route then
        return S.SYSTEM, manager
    end
    return route.scope, route.driver or manager
end

return M
