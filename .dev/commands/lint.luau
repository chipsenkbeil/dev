local checks = require("devrepo.checks")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local lintset = require("lintset")
local standalone = require("dev.standalone")
local dev_command = require("dev.command")

local DOC_COLUMNS = 80

local LUA_TOOLS = {
    { "selene", { "--no-exclude", "--config", "STYLE/selene.toml" } },
    { "ast-grep", { "scan", "--config", "STYLE/sgconfig.yml" } },
}

return dev_command({
    summary = "Lint the Rust, shell, bats and Luau code",
    group = "Check your work",
    run = function(_, _, ctx)
        local root = ctx.root
        local failed = false
        local dirty = {}

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

        local function missing(tool, package)
            dev_command.note(
                "Tool "
                    .. tool
                    .. " not found. The "
                    .. tool
                    .. " check is skipped. Install it with brew install "
                    .. (package or tool)
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

        local function lint_rust()
            if not fs.is_file(fs.join(root, "Cargo.toml")) then
                return
            end
            if not dev_os.which("cargo") then
                missing("cargo")
                return
            end
            dev_command.say("> Linting rust")
            run_checked({ "cargo", "+nightly", "fmt", "--check" })
            run_checked({ "cargo", "clippy", "--all-targets", "--", "-D", "warnings" })
        end

        local function lint_lua(files, ci_files)
            local style = fs.join(root, checks.lint_dir)
            if #files > 0 then
                if dev_os.which("stylua") then
                    dev_command.say("> Linting luau with stylua")
                    local config = fs.join(style, "stylua.toml")
                    local prefix = { "stylua", "--config-path", config, "--check" }
                    run_checked(checks.with_files(checks.with_files(prefix, files), ci_files))
                else
                    missing("stylua")
                end
                if dev_os.which("luau-analyze") then
                    dev_command.say("> Type-checking luau with luau-analyze")
                    run_checked(checks.with_files({ "luau-analyze" }, files))
                else
                    missing("luau-analyze", "luau")
                end
            end
            for _, row in ipairs(LUA_TOOLS) do
                local tool, prefix = row[1], { row[1] }
                if #ci_files > 0 then
                    if dev_os.which(tool) then
                        dev_command.say("> Linting lua with " .. tool)
                        for _, word in ipairs(row[2]) do
                            prefix[#prefix + 1] = (word:gsub("^STYLE", style))
                        end
                        run_checked(checks.with_files(prefix, ci_files))
                    else
                        missing(tool)
                    end
                end
            end
            dev_command.say("> Linting luau comments")
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

        lint_rust()

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

        lint_lua(checks.lua_files(root), checks.ci_files(root))

        dev_command.say("> standalone shell")
        for _, line in ipairs(standalone.problems(root)) do
            dev_command.note(line)
            failed = true
        end

        if dev_os.which("ast-grep") then
            dev_command.say("> Testing ast-grep rules")
            run_checked({ "ast-grep", "test", "--config", fs.join(root, "sgconfig.yml") })
        end

        return failed and 1 or 0
    end,
})
