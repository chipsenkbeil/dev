local dev_command = require("dev.command")
local dev_os = require("dev.os")

local function execute(opts, args, ctx)
    local tool = if opts.zigbuild then "zigbuild" else "build"
    local argv = { "cargo", tool, "--release", "--locked", "--target", args.target }
    dev_command.show(ctx, argv)
    local env = {}
    if opts.tag then
        env.DEV_RELEASE_TAG = opts.tag
    end
    local code = dev_os.run(argv, { cwd = ctx.root, env = env })
    if code ~= 0 then
        dev_command.die("The release build for " .. args.target .. " failed.")
    end
    dev_command.say("target/" .. args.target .. "/release/dev")
    return 0
end

return dev_command({
    summary = "Build the release binary for a Rust target",
    group = "Release",
    remote = false,
    long = table.concat({
        "Runs `cargo build --release --locked --target TARGET` in the project root ",
        "and prints the path of the binary it made.",
        "",
        "- `--tag TAG` sets `DEV_RELEASE_TAG`, so `dev --version` prints TAG.",
        "- `--zigbuild` builds with `cargo zigbuild`, which the static Linux musl ",
        "binary needs.",
        "- The tag workflow runs the same cargo line before any dev exists. This ",
        "command lets a person run it locally.",
        "",
        "```",
        "dev release build aarch64-apple-darwin --tag v0.1.0-pre.1",
        "```",
    }, "\n"),
    args = { { name = "target", required = true, help = "A Rust target triple" } },
    flags = {
        { name = "tag", kind = "string", help = "The tag the binary reports as its version" },
        { name = "zigbuild", kind = "boolean", help = "Build with cargo zigbuild" },
    },
    run = execute,
})
