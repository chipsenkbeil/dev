local here = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/fixtures/[^/]*$") or "."
package.path = table.concat({
    here .. "/dotfiles/bin/.local/share/dev/lua/?.lua",
    here .. "/.dev/lua/?.lua",
    package.path,
}, ";")

local distro = table.remove(arg, 1)
local installer = require("dotfiles." .. distro)

local opts = installer.parse(arg)
opts.root = os.getenv("LINUX_ROOT") or here
local uid = os.getenv("LINUX_UID")
opts.uid = uid and tonumber(uid) or nil
os.exit(installer.run(opts))
