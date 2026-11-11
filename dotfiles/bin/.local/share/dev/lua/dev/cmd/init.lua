local pomb = require("dev.board.pomb")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local help = require("dev.help")
local json = require("dev.json")
local pipelines = require("dev.pipelines")
local project = require("dev.project")
local templates = require("dev.templates")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

local Kind = project.Kind
local NONE = "none"
local TYPES = {
    [Kind.RUST] = true,
    [Kind.LOVE2D] = true,
    [Kind.LUA] = true,
    [Kind.GODOT] = true,
    [Kind.NODE] = true,
}
local GERRIT = { "ssh", "-p", "29418", "user@gerrit.example.com", "gerrit" }
local GERRIT_HOST = "ssh -p 29418 user@gerrit.example.com gerrit"
local BOARD_TOKEN = "pass:secrets/worker/token/pomb.example.com"
local BOARD_URL = "https://pomb.example.com"
local BOARD_SECONDS = "5"
local BOARD_REFUSED = "401"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }
local STYLE_TAIL = "\n"
    .. templates.STYLE_MARKER
    .. "\n\nRules that apply only to this project go here. Number them P1, P2, and so on. The numbers above only grow, so a project rule never shares a number with a guide rule.\n"
local NEEDS_YQ = "brew install yq"

---@class dev.cmd.init
---@field handlers table<string, fun(ctx: dev.Ctx, reg: dev.Registry): integer> the handler of
---   `init`
local M = { handlers = {} }

---@class dev.cmd.init.Run
---@field ctx dev.Ctx the verb's context
---@field root string the project root
---@field kind string the project type
---@field dry boolean whether nothing may be written
---@field gerrit boolean whether to set up the Gerrit project and remote
---@field name string the project's name
---@field hint string the command that adds a remote, `jj git remote add` or `git remote add`
---@field created string[] what was created, or would be
---@field skipped string[] what was already there
---@field human string[] what is left for the owner

local function parse(ctx, reg)
    local opts = { dry = false, gerrit = true }
    local args = ctx.args
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--type" or arg == "--name" then
            if i == #args then
                verb.usage_error(ctx, arg .. " needs a value")
            end
            opts[arg:sub(3)] = args[i + 1]
            i = i + 1
        elseif arg == "--dry-run" then
            opts.dry = true
        elseif arg == "--no-gerrit" then
            opts.gerrit = false
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

local function die(message)
    verb.die("dev: " .. tostring(message))
end

local function run_or_exit(run, argv, opts)
    verb.show(run.ctx, argv)
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

local function trimmed(text)
    return (text:gsub("\n+$", ""))
end

local function put_text(run, dest, text)
    local path = run.root .. "/" .. dest
    if fs.exists(path) then
        skipped(run, dest .. " exists")
        return
    end
    if not run.dry then
        local ok, err = fs.mkdir(fs.dirname(path), { parents = true })
        if ok then
            ok, err = fs.write(path, text)
        end
        if not ok then
            die(err)
        end
    end
    created(run, dest)
end

local function init_vcs(run)
    local root = run.root
    if fs.is_dir(root .. "/.jj") then
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

local function init_lint_files(run, dir, channel)
    local entries, pending = templates.skip_pending(run.root, templates.manifest(dir, run.kind))
    for _, bash in ipairs(pending) do
        skipped(run, bash .. " exists, left on bash")
    end
    for _, entry in ipairs(entries) do
        local opts = { kind = run.kind, dest = entry.dest, src = entry.src, channel = channel }
        local path = run.root .. "/" .. entry.dest
        if fs.exists(path) then
            skipped(run, entry.dest .. " exists")
        else
            if not run.dry then
                local ok, err = templates.install(run.root, opts)
                if not ok then
                    die(err)
                end
            end
            created(run, entry.dest)
        end
    end
end

local function init_workspace_lints(run, dir)
    local cargo = run.root .. "/Cargo.toml"
    if not fs.is_file(cargo) then
        skipped(run, "workspace lints: no Cargo.toml")
        return
    end
    local text = fs.read(cargo) or ""
    if templates.lints_project_block(text) ~= "" then
        skipped(run, "workspace lints in Cargo.toml exist")
        return
    end
    if not run.dry then
        local block, err = templates.lints_template_block(dir)
        if not block then
            die(err)
        end
        local ok, write_err = fs.write(cargo, templates.lints_replace(text, block))
        if not ok then
            die(write_err)
        end
        if dev_os.which("cargo-sort") then
            local argv = { "cargo", "sort", "--workspace" }
            verb.show(run.ctx, argv)
            dev_os.run(argv, { cwd = run.root, stdout = "null", stderr = "null" })
        end
    end
    created(run, "[workspace.lints] block in Cargo.toml")
    leave(run, 'add "[lints]" with "workspace = true" to each member crate Cargo.toml')
    io.write("reminder: each member crate needs [lints] with workspace = true\n")
    io.write(
        "note: the lints deny warnings, so fix every finding in the same change that adds this block\n"
    )
end

local function init_lib_attrs(run, dir)
    local libs = templates.lib_crates(run.root)
    local snippet
    if #libs > 0 then
        local err
        snippet, err = templates.lib_snippet(dir)
        if not snippet then
            die(err)
        end
    end
    for _, lib in ipairs(libs) do
        local path = run.root .. "/" .. lib .. "/src/lib.rs"
        local text = fs.read(path) or ""
        if templates.lib_attr_present(snippet, text) then
            skipped(run, lib .. "/src/lib.rs has the library-register attribute")
        else
            if not run.dry then
                local ok, err = fs.write(path, templates.lib_attr_insert(snippet, text))
                if not ok then
                    die(err)
                end
            end
            created(run, lib .. "/src/lib.rs library-register attribute")
        end
    end
    for _, app in ipairs(templates.app_crates(run.root)) do
        io.write("application register, no doc lints: ", app, "\n")
    end
end

local function init_lints(run)
    local kind = run.kind
    local dir, err
    if templates.set_for(kind) then
        dir, err = templates.dir(kind)
        if not dir then
            die(err)
        end
    end
    if kind == Kind.RUST then
        init_lint_files(run, dir, templates.channel(run.root))
        init_workspace_lints(run, dir)
        init_lib_attrs(run, dir)
    elseif dir then
        init_lint_files(run, dir, "")
    else
        skipped(run, "lint set: none yet for " .. kind .. " projects")
    end
end

local function init_style(run)
    local set = templates.set_for(run.kind)
    if not set then
        skipped(run, "docs/STYLE.md: no style guide for " .. run.kind .. " projects")
        return
    end
    local path = run.root .. "/docs/STYLE.md"
    local guide = templates.style_guide(run.kind)
    if fs.exists(path) then
        skipped(run, "docs/STYLE.md exists")
    elseif not fs.is_file(guide) then
        skipped(run, "docs/STYLE.md: no " .. set .. " guide at " .. guide)
    else
        put_text(run, "docs/STYLE.md", (fs.read(guide) or "") .. STYLE_TAIL)
    end
end

local function init_readme(run)
    local template = templates.readme_template()
    if fs.is_file(template) then
        put_text(run, ".dev/README.md", fs.read(template) or "")
    else
        skipped(run, ".dev/README.md: no template at " .. template)
    end
end

local function init_ci(run)
    put_text(run, ".ci/jobs.lua", pipelines.jobs(run.kind == Kind.RUST))
end

local function remote_names(run)
    local backend = vcs.backend(run.root)
    if not backend then
        return {}
    end
    if backend == vcs.JJ then
        verb.need("jj", "brew install jj")
    end
    return vcs.remotes(run.root, backend)
end

local function add_remote(run, name, url)
    local backend = vcs.backend(run.root)
    local argv
    if backend == vcs.JJ then
        argv = vcs.with(vcs.base(run.root, backend), "git", "remote", "add", name, url)
    else
        argv = { "git", "-C", run.root, "remote", "add", name, url }
    end
    run_or_exit(run, argv)
end

local function init_gerrit(run)
    local name = run.name
    if run.dry then
        created(
            run,
            "gerrit project "
                .. name
                .. " (create-project when absent) and remote gerrit gr:"
                .. name
        )
        return
    end
    local list = vcs.with(GERRIT, "ls-projects")
    verb.show(run.ctx, list)
    local out, code = dev_os.capture(list, { stderr = "stdout" })
    if code ~= 0 then
        verb.note("Gerrit ls-projects failed.")
        verb.note(trimmed(out))
        leave(
            run,
            "create the Gerrit project and remote: "
                .. GERRIT_HOST
                .. " create-project "
                .. name
                .. ", then "
                .. run.hint
                .. " gerrit gr:"
                .. name
        )
        return
    end
    local known = {}
    for line in out:gmatch("[^\n]+") do
        known[#known + 1] = line
    end
    if has(known, name) then
        skipped(run, "gerrit project " .. name .. " exists")
    else
        local create = vcs.with(GERRIT, "create-project", name)
        verb.show(run.ctx, create)
        if dev_os.run(create) == 0 then
            created(run, "gerrit project " .. name)
        else
            leave(run, "create the Gerrit project: " .. GERRIT_HOST .. " create-project " .. name)
            return
        end
    end
    add_remote(run, "gerrit", "gr:" .. name)
    created(run, "remote gerrit gr:" .. name)
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
    if not run.gerrit then
        skipped(run, "gerrit: --no-gerrit")
    elseif has(remotes, "gerrit") then
        skipped(run, "remote gerrit exists")
    else
        init_gerrit(run)
    end
end

local function init_board_hint(run)
    local url = os.getenv("POMB_URL")
    if not url or url == "" then
        url = BOARD_URL
    end
    if not (dev_os.which("pass") and dev_os.which("curl")) then
        return
    end
    local token = pomb.token(BOARD_TOKEN)
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
    leave(run, "No Pomb board for " .. run.name .. ", create one in " .. url)
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

---Seed a project with lint files, a style guide, a README, a CI pipeline and remotes.
---
---It takes `--type`, `--name`, `--dry-run` and `--no-gerrit`. Anything already in the
---project is skipped, and a dry run prints `would create:` lines and writes nothing.
---@param ctx dev.Ctx the verb's context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.run(ctx, reg)
    local opts = parse(ctx, reg)
    local root = ctx.root
    local kind = opts.type
    if kind == nil or kind == "" then
        kind = project.detect_type(root) or NONE
    elseif not TYPES[kind] then
        verb.usage_error(ctx, "--type takes rust, love2d, lua, godot or node")
    end
    if kind == Kind.RUST and fs.is_file(root .. "/Cargo.toml") then
        verb.need("yq", NEEDS_YQ)
    end
    local run = {
        ctx = ctx,
        root = root,
        kind = kind,
        dry = opts.dry,
        gerrit = opts.gerrit,
        name = (opts.name ~= nil and opts.name ~= "") and opts.name or fs.basename(root),
        hint = "git remote add",
        created = {},
        skipped = {},
        human = {},
    }
    io.write("init ", run.name, ": type ", kind, ", dry run ", opts.dry and "1" or "0", "\n")
    init_vcs(run)
    init_lints(run)
    init_style(run)
    init_readme(run)
    init_ci(run)
    init_remotes(run)
    init_board_hint(run)
    summarize(run)
    return 0
end

M.handlers["init"] = M.run

return M
