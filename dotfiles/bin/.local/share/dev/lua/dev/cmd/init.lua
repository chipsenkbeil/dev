local pomb = require("dev.board.pomb")
local config = require("dev.config")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local help = require("dev.help")
local json = require("dev.json")
local vcs = require("dev.vcs")
local dev_command = require("dev.command")
local dev_text = require("dev.text")
local setup = require("dev.board.setup")

local BOARD_SECONDS = "5"
local BOARD_REFUSED = "401"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }

---@class dev.cmd.init
---@field handlers table<string, fun(ctx: dev.Ctx, reg: dev.Registry): integer> the handler of
---   `init`
local M = { handlers = {} }

---@class dev.cmd.init.Run
---@field ctx dev.Ctx the command's context
---@field root string the project root
---@field dry boolean whether nothing may be written
---@field name string the project's name
---@field hint string the command that adds a remote, `jj git remote add` or `git remote add`
---@field created string[] what was created, or would be
---@field skipped string[] what was already there
---@field human string[] what is left for the owner

local function parse(ctx, reg)
    local opts = { dry = false }
    local args = ctx.args
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--name" then
            if i == #args then
                dev_command.usage_error(ctx, arg .. " needs a value")
            end
            opts[arg:sub(3)] = args[i + 1]
            i = i + 1
        elseif arg == "--dry-run" then
            opts.dry = true
        else
            help.bad_argument(ctx, reg, arg)
        end
        i = i + 1
    end
    return opts
end

local function created(run, item)
    run.created[#run.created + 1] = item
    io.write(run.dry and "would create: " or "created: ", item, "\n")
end

local function skipped(run, item)
    run.skipped[#run.skipped + 1] = item
    io.write("skipped: ", item, "\n")
end

local function leave(run, item)
    run.human[#run.human + 1] = item
end

local function run_or_exit(run, argv, opts)
    dev_command.show(run.ctx, argv)
    local code = dev_os.run(argv, opts)
    if code ~= 0 then
        os.exit(code or 1)
    end
end

local function has(list, want)
    for _, item in ipairs(list) do
        if item == want then
            return true
        end
    end
    return false
end

local function init_vcs(run)
    local root = run.root
    if vcs.backend(root) == vcs.JJ then
        run.hint = "jj git remote add"
        skipped(run, ".jj exists")
    elseif fs.is_file(root .. "/.git") then
        run.hint = "git remote add"
        skipped(run, ".jj: this is a git worktree, colocate jj in the main checkout")
    else
        if fs.exists(root .. "/.git") then
            skipped(run, ".git exists")
        else
            if not run.dry then
                run_or_exit(run, { "git", "-C", root, "init", "-q" })
            end
            created(run, ".git (git init)")
        end
        if dev_os.which("jj") then
            run.hint = "jj git remote add"
            if not run.dry then
                run_or_exit(
                    run,
                    { "jj", "git", "init", "--colocate" },
                    { cwd = root, stdout = "null", stderr = "null" }
                )
            end
            created(run, ".jj (jj git init --colocate)")
        else
            run.hint = "git remote add"
            skipped(run, ".jj (jj not installed, git only)")
        end
    end
end

local function init_board_section(run)
    if setup.has_section(run.root) then
        skipped(run, ".dev/config.toml [board] exists")
        return
    end
    local valid = #run.name > 0
        and #run.name <= setup.NAME_CHARS
        and run.name:find(setup.NAME_PATTERN)
    if not valid then
        leave(
            run,
            "add a [board] section to .dev/config.toml, since "
                .. run.name
                .. " is not a board name"
        )
        return
    end
    if not run.dry then
        local ok, wrote, message = pcall(setup.write_section, run.root, run.name)
        if not ok then
            message = wrote
        end
        if not (ok and wrote) then
            dev_command.die(
                "Cannot write .dev/config.toml. " .. dev_text.sentence(tostring(message))
            )
        end
    end
    created(run, ".dev/config.toml [board]")
end

local function remote_names(run)
    local backend = vcs.backend(run.root)
    if not backend then
        return {}
    end
    if backend == vcs.JJ then
        dev_command.need("jj", "brew install jj")
    end
    return vcs.remotes(run.root, backend)
end

local function init_remotes(run)
    local remotes = remote_names(run)
    if has(remotes, "origin") then
        skipped(run, "remote origin exists")
    else
        io.write(
            "remote origin is missing, create the GitHub repo and run: ",
            run.hint,
            " origin hub:",
            run.name,
            "\n"
        )
        leave(run, "create the GitHub repo, then run: " .. run.hint .. " origin hub:" .. run.name)
    end
end

local function init_board_hint(run)
    local url = os.getenv("POMB_URL")
    if not url or url == "" then
        url = config.user("board.pomb.url")
    end
    local ref = config.user("board.pomb.token")
    if type(url) ~= "string" or url == "" or type(ref) ~= "string" or ref == "" then
        return
    end
    if not (dev_os.which("pass") and dev_os.which("curl")) then
        return
    end
    local token = pomb.token(ref)
    if not token then
        return
    end
    local out, code = dev_os.capture_input(
        {
            "curl",
            "-fsS",
            "--max-time",
            BOARD_SECONDS,
            "-w",
            "\n%{http_code}",
            "-K",
            "-",
            url .. "/api/boards",
        },
        'header = "Authorization: Bearer ' .. token .. '"\n',
        { unset = CHILD_UNSET, stderr = "null" }
    )
    local text, status = out:match("^(.*)\n(%d+)$")
    if status == BOARD_REFUSED then
        leave(
            run,
            "Pomb refused the worker token, so the board check was skipped. "
                .. "A dev board command replaces a stale Keychain token, "
                .. "but a revoked token needs a new one in pass."
        )
        return
    end
    if code ~= 0 or not text then
        return
    end
    local boards = json.decode(text)
    if type(boards) ~= "table" then
        return
    end
    for _, board in ipairs(boards) do
        if type(board) == "table" and board.name == run.name then
            return
        end
    end
    leave(
        run,
        "No Pomb board for " .. run.name .. ". Run `dev board init` to create one in " .. url .. "."
    )
end

local function summarize(run)
    io.write("\nSummary", run.dry and " (dry run, nothing written)" or "", "\n")
    local sections = { { "Created:", run.created }, { "Skipped:", run.skipped } }
    if #run.human > 0 then
        sections[#sections + 1] = { "Left for you:", run.human }
    end
    for _, section in ipairs(sections) do
        io.write(section[1], "\n")
        for _, item in ipairs(section[2]) do
            io.write("  ", item, "\n")
        end
    end
end

---Seed a project with version control, remotes and a board hint.
---
---It takes `--name` and `--dry-run`. Anything already in the project is
---skipped, and a dry run prints `would create:` lines and writes nothing.
---@param ctx dev.Ctx the command's context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.run(ctx, reg)
    local opts = parse(ctx, reg)
    local root = ctx.root
    local run = {
        ctx = ctx,
        root = root,
        dry = opts.dry,
        name = (opts.name ~= nil and opts.name ~= "") and opts.name or fs.basename(root),
        hint = "git remote add",
        created = {},
        skipped = {},
        human = {},
    }
    io.write("init ", run.name, ": dry run ", opts.dry and "1" or "0", "\n")
    init_vcs(run)
    init_board_section(run)
    init_remotes(run)
    init_board_hint(run)
    summarize(run)
    return 0
end

M.handlers["init"] = M.run

return M
