local devos = require("dev.os")
local fs = require("dev.fs")

---@class dev.project
local M = {}

---@enum dev.project.Kind
local Kind = {
    RUST = "rust",
    LOVE2D = "love2d",
    GODOT = "godot",
    NODE = "node",
    LUA = "lua",
    MAKE = "make",
}

local LUA_SEARCH_DEPTH = 4
local stderr = io.stderr
local SHARE = debug.getinfo(1, "S").source:match("^@(.*)/lua/dev/[^/]*$") or "."

local function physical_cwd()
    return (devos.capture({ "pwd", "-P" }):gsub("\n$", ""))
end

local function ancestor_with(markers, cwd, test)
    local dir = cwd
    while dir ~= "/" do
        for _, marker in ipairs(markers) do
            if test(dir .. "/" .. marker) then
                return dir
            end
        end
        dir = fs.dirname(dir)
    end
end

local function vcs_root(argv)
    if not devos.which(argv[1]) then
        return nil
    end
    local out, code = devos.capture(argv, { stderr = "null" })
    if code == 0 then
        return (out:gsub("\n$", ""))
    end
end

---The project types dev knows.
M.Kind = Kind

---The `PS4` that turns on the file and line prefix of a traced bash script.
M.PS4 = "+ ${BASH_SOURCE##*/}:${LINENO}: "

---Directory of dev's own code, holding `main.lua`.
M.share = SHARE

---Find the clone of the dotfiles repository that holds this copy of dev.
---
---`DOTFILES` names it for a user, never for root.
---@return string root absolute path of the clone
function M.dotfiles_root()
    local env = os.getenv("DOTFILES")
    if env and env ~= "" and devos.getuid() ~= 0 then
        return env
    end
    local root = SHARE:match("^(.*)/dotfiles/bin/%.local/share/dev$")
    if not root then
        stderr:write("dev: cannot find the dotfiles clone from ", SHARE, "\n")
        os.exit(1)
    end
    return root
end

---Find the project root.
---
---1. As root we only test that `.jj`, `.git` or `.dev` exists, walking up from
---   the current directory, and run no command.
---2. Otherwise it is `jj root`, then `git rev-parse --show-toplevel`, then the
---   nearest directory holding `.dev`.
---3. With none of those it is the current directory.
---@return string root absolute path of the project
function M.root()
    local cwd = physical_cwd()
    if devos.getuid() == 0 then
        return ancestor_with({ ".jj", ".git", ".dev" }, cwd, fs.exists) or cwd
    end
    return vcs_root({ "jj", "root" })
        or vcs_root({ "git", "rev-parse", "--show-toplevel" })
        or ancestor_with({ ".dev" }, cwd, fs.is_dir)
        or cwd
end

local function has_lua_file(root)
    local out = devos.capture({
        "find",
        "-H",
        root,
        "-mindepth",
        "1",
        "-maxdepth",
        tostring(LUA_SEARCH_DEPTH),
        "(",
        "-name",
        ".*",
        "-o",
        "-name",
        "node_modules",
        "-o",
        "-name",
        "target",
        ")",
        "-prune",
        "-o",
        "-type",
        "f",
        "-name",
        "*.lua",
        "-print",
        "-quit",
    }, { stderr = "null" })
    return out ~= ""
end

---Name the project's language by the files in its root.
---@param root string project root
---@return dev.project.Kind? type nil when no file points to a type
function M.detect_type(root)
    if fs.is_file(root .. "/Cargo.toml") then
        return Kind.RUST
    elseif fs.is_file(root .. "/main.lua") and fs.is_file(root .. "/conf.lua") then
        return Kind.LOVE2D
    elseif fs.is_file(root .. "/project.godot") then
        return Kind.GODOT
    elseif fs.is_file(root .. "/package.json") then
        return Kind.NODE
    elseif has_lua_file(root) then
        return Kind.LUA
    elseif fs.is_file(root .. "/Makefile") then
        return Kind.MAKE
    end
end

return M
