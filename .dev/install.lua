--[[
remote: false
requires: workspace
Publish this checkout as dev's snapshot and link it into the home directory.
Copy the files an install ships to a new version under the dev snapshot directory and point
`current` at it. The launcher in this checkout runs that copy until the next install, and
DEV_FROM=checkout runs the checkout itself.
Then link ~/.local/bin/dev to the checkout's launcher and ~/.local/share/dev to the checkout,
replacing any link already there, dangling ones included. A file or directory that is not a link
is left alone and fails the install.
]]
local dev_command = require("dev.command")
local fs = require("dev.fs")
local snapshot = require("devrepo.snapshot")

local ctx = ...
dev_command.no_args(ctx)

local LINKS = {
    { path = ".local/bin/dev", target = "/bin/dev" },
    { path = ".local/share/dev", target = "" },
}

local function place(path, target)
    if fs.is_link(path) then
        local ok, message = fs.remove(path)
        if not ok then
            return nil, message
        end
    elseif fs.exists(path) then
        return nil, path .. " is not a link, so it stays. Remove it to link this checkout."
    end
    local ok, message = fs.mkdir(fs.dirname(path), { parents = true })
    if not ok then
        return nil, message
    end
    return fs.symlink(target, path)
end

local home = os.getenv("HOME")
if not home or home == "" then
    dev_command.die("HOME is not set, so dev install has nowhere to link dev.")
end
local root = assert(fs.realpath(ctx.root))

local version, message = snapshot.publish(root, snapshot.dir())
if not version then
    dev_command.die(message)
end
dev_command.say("Published " .. version .. ".")

local failed = false
for _, link in ipairs(LINKS) do
    local path, target = home .. "/" .. link.path, root .. link.target
    local ok, why = place(path, target)
    if ok then
        dev_command.say("Linked " .. path .. " to " .. target .. ".")
    else
        dev_command.note(why)
        failed = true
    end
end
return failed and 1 or 0
