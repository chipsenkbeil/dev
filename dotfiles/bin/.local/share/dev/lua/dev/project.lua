local devos = require("dev.os")
local fs = require("dev.fs")

---@class dev.project
local M = {}

local PRUNED_DIRS = { node_modules = true, target = true }
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

---Directory of dev's own code, holding `main.lua` and `legacy.bash`.
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

local function has_lua_file(dir)
    for _, name in ipairs(fs.list(dir) or {}) do
        local path = fs.join(dir, name)
        local stat = fs.stat(path)
        local kind = stat and stat.kind
        if name:sub(1, 1) ~= "." then
            if kind == "file" and name:find("%.lua$") then
                return true
            end
            if kind == "dir" and not PRUNED_DIRS[name] and has_lua_file(path) then
                return true
            end
        end
    end
    return false
end

---Name the project's language by the files in its root.
---@param root string project root
---@return "rust"|"love2d"|"godot"|"node"|"lua"|"make"|nil type nil when no file points to a type
function M.detect_type(root)
    if fs.is_file(root .. "/Cargo.toml") then
        return "rust"
    elseif fs.is_file(root .. "/main.lua") and fs.is_file(root .. "/conf.lua") then
        return "love2d"
    elseif fs.is_file(root .. "/project.godot") then
        return "godot"
    elseif fs.is_file(root .. "/package.json") then
        return "node"
    elseif has_lua_file(root) then
        return "lua"
    elseif fs.is_file(root .. "/Makefile") then
        return "make"
    end
end

return M
