local dev_command = require("dev.command")
local dev_os = require("dev.os")

local SUITE = "tests/native/runtime_test.luau"

local function execute(opts, args, ctx)
    local binary = args.binary
    if binary:sub(1, 1) ~= "/" then
        binary = ctx.root .. "/" .. binary
    end

    local out, code = dev_os.capture({ binary, "--version" }, { cwd = ctx.root })
    if code ~= 0 then
        dev_command.die("The binary " .. args.binary .. " did not run --version.")
    end
    local printed = out:gsub("%s+$", "")
    if opts.tag and printed ~= "dev " .. opts.tag then
        dev_command.die(
            "The binary prints " .. printed .. " from --version, not dev " .. opts.tag .. "."
        )
    end
    dev_command.say(printed)

    local argv = { binary, "-l", SUITE }
    dev_command.show(ctx, argv)
    if dev_os.run(argv, { cwd = ctx.root }) ~= 0 then
        dev_command.die("The native suite failed on " .. args.binary .. ".")
    end
    return 0
end

return dev_command({
    summary = "Run the native suite and --version on a release binary",
    group = "Release",
    remote = false,
    long = table.concat({
        "Runs BINARY with `--version` and then BINARY with `-l ",
        "tests/native/runtime_test.luau` in the project root.",
        "",
        "- `--tag TAG` refuses a binary whose `--version` is not `dev TAG`.",
        "- It exits 1 on the first failure and prints what failed.",
        "",
        "```",
        "dev release test target/aarch64-apple-darwin/release/dev --tag v0.1.0-pre.1",
        "```",
    }, "\n"),
    args = { { name = "binary", required = true, help = "The release binary to test" } },
    flags = {
        { name = "tag", kind = "string", help = "The tag --version must print" },
    },
    run = execute,
})
