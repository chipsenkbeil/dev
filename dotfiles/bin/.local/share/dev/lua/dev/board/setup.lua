local board = require("dev.board")
local config = require("dev.config")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local toml = require("dev.toml")
local vcs = require("dev.vcs")
local dev_command = require("dev.command")

---The settings and checks `dev board init` and the first board of a project share.
---@class dev.board.setup
local M = { NAME_CHARS = 100, NAME_PATTERN = '^[^%c"\\]+$' }

---Report whether the project's config has a `[board]` section.
---@param root string the project root
---@return boolean has true when the section exists
function M.has_section(root)
    local text = fs.exists(root .. "/.dev/config.toml") and fs.read(root .. "/.dev/config.toml")
    local tree = text and toml.parse(text)
    return type(tree) == "table" and tree.board ~= nil
end

---Read the board's name from the config and the `--name` flag, or die.
---@param ctx dev.Ctx the command context
---@param flags table<string, string> the parsed flags
---@return string name the board's name
---@return boolean missing true when the project has no `[board]` section yet
function M.board_name(ctx, flags)
    local backend = config.get(ctx.root, "board.backend")
    local name = config.get(ctx.root, "board.name")
    if backend == nil and M.has_section(ctx.root) then
        dev_command.die('The `[board]` section needs `backend = "pomb"` in `.dev/config.toml`.')
    end
    if backend ~= nil and backend ~= board.Backend.POMB then
        dev_command.die(
            'The `backend` setting of `[board]` must be "pomb" or "local" in `.dev/config.toml`.'
        )
    end
    local asked = flags["--name"]
    if backend == nil then
        if not asked then
            dev_command.die(
                "This project has no `[board]` section. Pass `--name N` to make a board and write it."
            )
        end
        name = asked
    else
        name = name or fs.basename(ctx.root)
        if asked and asked ~= name then
            dev_command.usage_error(
                ctx,
                "--name " .. asked .. " is not the [board] name " .. tostring(name)
            )
        end
    end
    if
        type(name) ~= "string"
        or #name == 0
        or #name > M.NAME_CHARS
        or not name:find(M.NAME_PATTERN)
    then
        dev_command.die("The board's name must be 1 to 100 characters with no quote or backslash.")
    end
    return name, backend == nil
end

---Append a `[board]` section for a Pomb board to the project's config.
---@param root string the project root
---@param name string the board's name
---@return true? ok true when the section was written
---@return string? message the system's text when the write failed
function M.write_section(root, name)
    local path = root .. "/.dev/config.toml"
    local existing = fs.exists(path) and fs.read(path) or ""
    local gap = existing == "" and "" or (existing:sub(-1) == "\n" and "\n" or "\n\n")
    local section = '[board]\nbackend = "pomb"\nname = ' .. string.format("%q", name) .. "\n"
    assert(toml.parse(existing .. gap .. section), ".dev/config.toml would not parse")
    local ok, message = true, nil
    if not fs.is_dir(root .. "/.dev") then
        ok, message = fs.mkdir(root .. "/.dev")
    end
    if ok then
        ok, message = fs.write(path, existing .. gap .. section)
    end
    if not ok then
        return nil, tostring(message)
    end
    return true
end

---Name this machine.
---@return string host the short hostname
function M.host()
    return (dev_os.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", ""))
end

---Read the lanes the project's config names, or die when they are not a list of names.
---@param ctx dev.Ctx the command context
---@return string[] lanes the lane names
function M.config_lanes(ctx)
    local lanes = config.get(ctx.root, "board.lanes")
    if lanes == nil then
        return {}
    end
    local ok = type(lanes) == "table"
    for _, lane in ipairs(ok and lanes or {}) do
        ok = ok and type(lane) == "string" and lane ~= ""
    end
    if not ok then
        dev_command.die(
            "The `lanes` setting of `[board]` must be a list of lane names in `.dev/config.toml`."
        )
    end
    return lanes
end

local function private_project(root)
    local backend = vcs.backend(root)
    if not backend then
        return true
    end
    local origin = vcs.config(root, backend, "remote.origin.url")
    if origin == "" then
        return true
    end
    if not origin:find("github.com", 1, true) then
        return false
    end
    local out, code = dev_os.capture(
        { "gh", "repo", "view", "--json", "isPrivate", "-q", ".isPrivate" },
        { cwd = root, stderr = "null" }
    )
    return code == 0 and out:find("^true") ~= nil
end

---Make the board of a private project that has none, or die when the project may be public.
---@param ctx dev.Ctx the command context
---@param init_board fun(ctx: dev.Ctx): integer runs `dev board init` and returns its exit code
function M.ensure_board(ctx, init_board)
    if config.get(ctx.root, "board.backend") ~= nil then
        return
    end
    if not private_project(ctx.root) then
        dev_command.die(
            "This project has no board and is public or not known to be private. Ask the owner before it gets one. `dev board init --name N` makes it."
        )
    end
    local name = fs.basename(ctx.root)
    print("This project is private and has no board. Making " .. name .. ".")
    local making = {}
    for key, value in pairs(ctx) do
        making[key] = value
    end
    making.args = { "--name", name }
    local code = init_board(making)
    if code ~= 0 then
        os.exit(code)
    end
end

return M
