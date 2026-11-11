--[[
Format the Lua roots with stylua.
It uses the config that dev lint checks against.
]]
local checks = require("dotfiles.checks")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)

local files = checks.lua_files(ctx.root)
if #files == 0 then
    return 0
end
if not dev_os.which("stylua") then
    verb.die("stylua not found. Install with: brew install stylua")
end
local prefix = { "stylua", "--config-path", fs.join(ctx.root, checks.lint_dir, "stylua.toml") }
return dev_os.run(checks.with_files(prefix, files), { cwd = ctx.root })
