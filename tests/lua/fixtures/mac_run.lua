local here = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/fixtures/[^/]*$") or "."
package.path = table.concat({
    here .. "/dotfiles/bin/.local/share/dev/lua/?.lua",
    here .. "/.dev/lua/?.lua",
    package.path,
}, ";")
local mac = require("dotfiles.mac")

local opts = mac.parse(arg)
opts.root = os.getenv("MAC_ROOT") or here
local uid = os.getenv("MAC_UID")
opts.uid = uid and tonumber(uid) or nil
local bins = os.getenv("MAC_BREW_BINS")
if bins then
    opts.brew_bins = {}
    for bin in bins:gmatch("[^:]+") do
        opts.brew_bins[#opts.brew_bins + 1] = bin
    end
end
os.exit(mac.run(opts))
