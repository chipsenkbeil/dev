local root = arg[0]:match("^(.*)/tests/lua/") or "."
package.path = table.concat({
    root .. "/tests/lua/?.lua",
    root .. "/lua/?.lua",
    root .. "/.dev/lua/?.lua",
    package.path,
}, ";")
