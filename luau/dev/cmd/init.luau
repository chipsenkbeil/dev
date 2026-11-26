local pomb = require("@dev/board/pomb")
local config = require("@dev/config")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local http = require("@dev/http")
local json = require("@dev/json")
local vcs = require("@dev/vcs")
local dev_command = require("@dev/command")
local dev_text = require("@dev/text")
local setup = require("@dev/board/setup")

local BOARD_SECONDS = 5
local BOARD_REFUSED = 401
local LIB_FOLDER = ".dev/lib"

---@class dev.cmd.init
local M = {}

---@class dev.cmd.init.Run
---@field ctx dev.Ctx the command's context
---@field root string the project root
---@field dry boolean whether nothing may be written
---@field name string the project's name
---@field hint string the command that adds a remote, `jj git remote add` or `git remote add`
---@field created string[] what was created, or would be
---@field skipped string[] what was already there
---@field human string[] what is left for the owner

local function created(run, item)
    run.created[#run.created + 1] = item
    dev_command.say((run.dry and "would create: " or "created: ") .. item)
end

local function skipped(run, item)
    run.skipped[#run.skipped + 1] = item
    dev_command.say("skipped: " .. item)
end

local function leave(run, item)
    run.human[#run.human + 1] = item
end

local function run_or_exit(run, argv, opts)
    dev_command.show(run.ctx, argv)
    local code = dev_os.run(argv, opts)
    if code ~= 0 then
        dev_os.exit(code or 1)
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

---Add the alias `lib` for `.dev/lib` to a project's `.luaurc`, keeping every key already there.
---
---An existing file is read as plain JSON and written back as compact JSON. A file that holds
---comments or another alias `lib` is left as it is.
---@param root string the project root
---@param dry boolean whether nothing may be written
---@return "created"|"skipped"|"left" outcome what happened
---@return string? message the reason a file was left, or the failure of the write
function M.write_luaurc(root, dry)
    local path = root .. "/.luaurc"
    local doc = {}
    if fs.exists(path) then
        local decoded = json.decode(fs.read(path) or "")
        if type(decoded) ~= "table" or type(decoded.aliases or {}) ~= "table" then
            return "left", ".luaurc is not plain JSON with an aliases object"
        end
        doc = decoded
        if doc.aliases and doc.aliases.lib ~= nil then
            return "skipped"
        end
    end
    doc.aliases = doc.aliases or {}
    doc.aliases.lib = LIB_FOLDER
    if not dry then
        local ok, message = fs.write(path, assert(json.encode(doc)) .. "\n")
        if not ok then
            return "left", tostring(message)
        end
    end
    return "created"
end

local function init_luaurc(run)
    local outcome, message = M.write_luaurc(run.root, run.dry)
    if outcome == "created" then
        created(run, ".luaurc (aliases lib = " .. LIB_FOLDER .. ")")
    elseif outcome == "skipped" then
        skipped(run, ".luaurc aliases lib exists")
    else
        leave(
            run,
            "add the alias lib = " .. LIB_FOLDER .. " to .luaurc, since " .. tostring(message)
        )
    end
end

local function init_board_section(run)
    if setup.has_section(run.root) then
        skipped(run, ".dev/config.toml [board] exists")
        return
    end
    if not setup.valid_name(run.name) then
        leave(
            run,
            `{run.name} is not a board name, so init wrote no [board] section. `
                .. "Add one to .dev/config.toml with a name of 1 to 100 characters."
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
        local owner = config.user("github.owner")
        if type(owner) ~= "string" or owner == "" then
            owner = "OWNER"
        end
        local remote = "git@github.com:" .. owner .. "/" .. run.name .. ".git"
        dev_command.say(
            "remote origin is missing, create the GitHub repo and run: "
                .. run.hint
                .. " origin "
                .. remote
        )
        leave(run, "create the GitHub repo, then run: " .. run.hint .. " origin " .. remote)
    end
end

local function init_board_hint(run)
    local url = dev_os.getenv("POMB_URL")
    if not url or url == "" then
        url = config.user("board.pomb.url")
    end
    local ref = config.user("board.pomb.token")
    if type(url) ~= "string" or url == "" or type(ref) ~= "string" or ref == "" then
        return
    end
    if not dev_os.which("pass") then
        return
    end
    local token = pomb.token(ref)
    if not token then
        return
    end
    local reply = http.request({
        method = "GET",
        url = url .. "/api/boards",
        headers = { Authorization = "Bearer " .. token },
        timeout = BOARD_SECONDS,
    })
    if reply and reply.status == BOARD_REFUSED then
        leave(
            run,
            "Pomb refused the worker token, so the board check was skipped. "
                .. "A dev board command replaces a stale Keychain token, "
                .. "but a revoked token needs a new one in pass."
        )
        return
    end
    if not reply or reply.status < 200 or reply.status >= 300 then
        return
    end
    local boards = json.decode(reply.body)
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
    dev_command.say("\nSummary" .. (run.dry and " (dry run, nothing written)" or ""))
    local sections = { { "Created:", run.created }, { "Skipped:", run.skipped } }
    if #run.human > 0 then
        sections[#sections + 1] = { "Left for you:", run.human }
    end
    for _, section in ipairs(sections) do
        dev_command.say(section[1])
        for _, item in ipairs(section[2]) do
            dev_command.say("  " .. item)
        end
    end
end

---Seed a project with version control, remotes and a board hint.
---
---It takes `--name` and `--dry-run`. Anything already in the project is
---skipped, and a dry run prints `would create:` lines and writes nothing.
---@param opts { name: string?, dry_run: boolean? } the flags
---@param ctx dev.Ctx the command's context
---@return integer code 0
function M.run(opts, ctx)
    local root = ctx.root
    local run = {
        ctx = ctx,
        root = root,
        dry = opts.dry_run == true,
        name = (opts.name ~= nil and opts.name ~= "") and opts.name or fs.basename(root),
        hint = "git remote add",
        created = {},
        skipped = {},
        human = {},
    }
    dev_command.say("init " .. run.name .. ": dry run " .. (run.dry and "1" or "0"))
    init_vcs(run)
    init_luaurc(run)
    init_board_section(run)
    init_remotes(run)
    init_board_hint(run)
    summarize(run)
    return 0
end

return M
