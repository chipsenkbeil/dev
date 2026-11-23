--[[
Run the shell, bats and Lua checks over the repo.
Shellcheck, shfmt and comment spacing cover the bash roots, and the bare-assertion check covers
the bats files. Stylua, selene, ast-grep and the comment checks cover the Lua roots, .dev included.
The style skill's lint templates get the formatter check too, and the rule tests of the Lua and
Rust lint sets run once.
Exit non-zero when any of them reports a finding.
]]
local checks = require("dotfiles.checks")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local dev_command = require("dev.command")

local ctx = ...
dev_command.no_args(ctx)

local root = ctx.root
local failed = false
local dirty = {}

local LUA_TOOLS = {
    { "stylua", { "--config-path", "STYLE/stylua.toml", "--check" }, true },
    { "selene", { "--no-exclude", "--config", "STYLE/selene.toml" } },
    { "ast-grep", { "scan", "--config", "STYLE/ast-grep/sgconfig.yml" } },
}

local RULE_TEST_SETS = { "lua", "rust" }
local DOC_COLUMNS = 80

local function run_checked(argv, opts)
    opts = opts or {}
    opts.cwd = root
    if dev_os.run(argv, opts) ~= 0 then
        failed = true
    end
end

local function report(file, numbers, message)
    for _, number in ipairs(numbers) do
        dev_command.note(string.format("%s:%d: %s", file, number, message))
        failed = true
    end
end

local function missing(tool)
    dev_command.note(
        "Tool "
            .. tool
            .. " not found. The "
            .. tool
            .. " check is skipped. Install it with brew install "
            .. tool
            .. "."
    )
end

local have_shfmt = dev_os.which("shfmt") ~= nil

local function lint_shell(file)
    dev_command.say("> Linting " .. file)
    local head = checks.first_line(root, file)
    if head:find("bash", 1, true) then
        run_checked({ "shellcheck", "-x", "-P", "SCRIPTDIR", file })
    elseif head:find("zsh", 1, true) then
        dev_command.say("  skip (zsh)")
        return
    else
        run_checked({ "shellcheck", "-x", "-P", "SCRIPTDIR", "-s", "sh", file })
    end
    if have_shfmt then
        local code = dev_os.run(
            { "shfmt", "-i", "4", "-d", file },
            { cwd = root, stdout = "null", stderr = "null" }
        )
        if code ~= 0 then
            dirty[#dirty + 1] = file
        end
    end
    report(
        file,
        checks.comment_spacing(fs.read(fs.join(root, file)) or ""),
        "full-line comment directly after code, add a blank line before it"
    )
end

local function lint_lua(files, templates)
    local style = fs.join(root, checks.lint_dir)
    local formatted = checks.with_files(checks.with_files({}, files), templates)
    for _, row in ipairs(LUA_TOOLS) do
        local tool, prefix = row[1], { row[1] }
        local targets = row[3] and formatted or files
        if #targets > 0 then
            if dev_os.which(tool) then
                dev_command.say("> Linting lua with " .. tool)
                for _, word in ipairs(row[2]) do
                    prefix[#prefix + 1] = (word:gsub("^STYLE", style))
                end
                run_checked(checks.with_files(prefix, targets))
            else
                missing(tool)
            end
        end
    end
    dev_command.say("> Linting lua comments")
    package.path = style .. "/../?.lua;" .. package.path
    local lintset = require("lintset")
    for _, file in ipairs(files) do
        local text = fs.read(fs.join(root, file)) or ""
        report(
            file,
            lintset.spacing(text, "--"),
            "full-line comment directly after code, add a blank line before it"
        )
        for _, run in ipairs(lintset.runs(text, "--")) do
            report(
                file,
                { run.line },
                run.count
                    .. " consecutive comment lines, restructure the code or shrink the comment"
            )
        end
    end
end

if not have_shfmt then
    missing("shfmt")
end

for _, file in ipairs(checks.shell_files(root)) do
    lint_shell(file)
end

for _, file in ipairs(checks.bats_files(root)) do
    report(
        file,
        checks.bare_assertions(fs.read(fs.join(root, file)) or ""),
        "a bare [[ ]] assertion never fails a test under bash 3.2, append || false"
    )
end

for _, file in ipairs(checks.doc_files(root)) do
    report(
        file,
        checks.long_lines(fs.read(fs.join(root, file)) or "", DOC_COLUMNS),
        "line wider than " .. DOC_COLUMNS .. " columns, wrap it"
    )
end

if #dirty > 0 then
    dev_command.note("\nshfmt -i 4 would change:")
    for _, file in ipairs(dirty) do
        dev_command.note("  " .. file)
    end
    failed = true
end

local lua_files = checks.lua_files(root)
lint_lua(lua_files, checks.template_files(root))

dev_command.say("> standalone shell")
for _, line in ipairs(require("dev.standalone").problems(root)) do
    dev_command.note(line)
    failed = true
end

if dev_os.which("ast-grep") then
    local sets = fs.join(root, checks.lint_dir, "..")
    for _, set in ipairs(RULE_TEST_SETS) do
        dev_command.say("> Testing " .. set .. " ast-grep rules")
        run_checked({
            "ast-grep",
            "test",
            "--config",
            fs.join(sets, set, "ast-grep", "sgconfig.yml"),
        })
    end
end

return failed and 1 or 0
