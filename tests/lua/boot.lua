local root = arg[0]:match("^(.*)/tests/lua/") or "."
package.path = table.concat({
    root .. "/tests/lua/?.lua",
    root .. "/dotfiles/bin/.local/share/dev/lua/?.lua",
    root .. "/dotfiles/dev/.config/dev/lua/?.lua",
    root .. "/.dev/lua/?.lua",
    package.path,
}, ";")
