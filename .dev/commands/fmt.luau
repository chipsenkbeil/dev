local checks = require("@lib/devrepo/checks")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Format the Rust and Luau code",
    group = "Check your work",
    run = function(_, _, ctx)
        local code = 0
        if fs.is_file(fs.join(ctx.root, "Cargo.toml")) then
            dev_command.need("cargo", "rustup")
            code = dev_os.run({ "cargo", "+nightly", "fmt" }, { cwd = ctx.root })
        end
        local files = checks.lua_files(ctx.root)
        if #files == 0 then
            return code
        end
        dev_command.need("stylua", "brew install stylua")
        local config = fs.join(ctx.root, checks.lint_dir, "stylua.toml")
        local prefix = { "stylua", "--config-path", config }
        local styled = dev_os.run(checks.with_files(prefix, files), { cwd = ctx.root })
        return code ~= 0 and code or styled
    end,
})
