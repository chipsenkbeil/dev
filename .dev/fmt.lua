--[[
Format the Lua roots and the style skill's lint templates.
It uses the config that dev lint checks against.
]]
local checks = require("dotfiles.checks")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)

local files = checks.lua_files(ctx.root)
for _, file in ipairs(checks.template_files(ctx.root)) do
    files[#files + 1] = file
end
if #files == 0 then
    return 0
end
if not dev_os.which("stylua") then
    verb.die("stylua not found. Install with: brew install stylua")
end
local prefix = { "stylua", "--config-path", fs.join(ctx.root, checks.lint_dir, "stylua.toml") }
return dev_os.run(checks.with_files(prefix, files), { cwd = ctx.root })
