local t = require("dev.testing")
local header = require("dev.header")

local function sh(...)
    return table.concat({ "#!/usr/bin/env bash", ... }, "\n") .. "\n"
end

t.test("the description is the first comment line after the shebang", function()
    local h = header.parse(sh("# Do the thing.", "# More words.", "", "echo hi"), "sh")
    t.eq(h.desc, "Do the thing.")
    t.eq(h.long, { "Do the thing.", "More words." })
end)

t.test("shellcheck, flags, group and hidden lines never become the description", function()
    local h = header.parse(
        sh(
            "# shellcheck disable=SC2034",
            "# flags: --a",
            "# group: Boxes",
            "# hidden",
            "# The real one.",
            "echo"
        ),
        "sh"
    )
    t.eq(h.desc, "The real one.")
end)

t.test("blank lines before the first comment are skipped", function()
    t.eq(header.parse(sh("", "  ", "# After blanks.", "echo"), "sh").desc, "After blanks.")
end)

t.test("code before any comment leaves the description empty", function()
    t.eq(header.parse(sh("echo hi", "# Late."), "sh").desc, "")
end)

t.test("the long form drops shellcheck, group and hidden lines and stops at code", function()
    local h = header.parse(
        sh(
            "# shellcheck source=x",
            "# Title.",
            "# group: G",
            "# hidden",
            "# flags: --a",
            "# KEY=1 sets it",
            "",
            "# not header"
        ),
        "sh"
    )
    t.eq(h.long, { "Title.", "flags: --a", "KEY=1 sets it" })
end)

t.test("flags split on spaces and commas", function()
    t.eq(header.parse(sh("# Desc.", "# flags: --a, --b  -c"), "sh").flags, { "--a", "--b", "-c" })
end)

t.test("-h and --help are dropped from flags with a warning naming the file", function()
    local h = header.parse(sh("# Desc.", "# flags: --a -h --help --b"), "sh", "/p/.dev/x.sh")
    t.eq(h.flags, { "--a", "--b" })
    t.eq(h.warnings, {
        "dev: /p/.dev/x.sh: the flags line declares -h, which dev reserves before --",
        "dev: /p/.dev/x.sh: the flags line declares --help, which dev reserves before --",
    })
end)

t.test("only the first flags line counts and code ends the search", function()
    t.eq(header.parse(sh("# Desc.", "# flags: --a", "# flags: --b"), "sh").flags, { "--a" })
    t.eq(header.parse(sh("# Desc.", "echo", "# flags: --a"), "sh").flags, {})
end)

t.test("a blank line does not end the flags search", function()
    t.eq(header.parse(sh("# Desc.", "", "# flags: --a"), "sh").flags, { "--a" })
end)

t.test("the group is the first non-empty group line, and hidden is a line by itself", function()
    local h = header.parse(
        sh("# Desc.", "# group:", "# group: First", "# group: Second", "# hidden"),
        "sh"
    )
    t.eq(h.group, "First")
    t.eq(h.hidden, true)
    local plain = header.parse(sh("# Desc.", "# hidden stuff"), "sh")
    t.eq(plain.hidden, false)
    t.eq(plain.group, nil)
end)

t.test("a Lua header is one leading block comment holding the same lines", function()
    local h = header.parse(table.concat({
        "--[[",
        "Run the thing.",
        "group: Share it",
        "hidden",
        "flags: --x, -h --y",
        "KEY=value sets it",
        "]]",
        "local x = 1",
        "-- flags: --nope",
    }, "\n") .. "\n", "lua", "/p/.dev/t.lua")
    t.eq(h.desc, "Run the thing.")
    t.eq(h.group, "Share it")
    t.eq(h.hidden, true)
    t.eq(h.flags, { "--x", "--y" })
    t.eq(h.long, { "Run the thing.", "flags: --x, -h --y", "KEY=value sets it" })
    t.eq(#h.warnings, 1)
end)

t.test("a Lua file with no leading block has an empty header", function()
    local h = header.parse("-- Not a block.\nlocal x = 1\n", "lua")
    t.eq(h.desc, "")
    t.eq(h.flags, {})
    t.eq(h.long, {})
end)

t.test("CRLF line endings do not reach the flags or a Lua header", function()
    local h = header.parse("#!/bin/sh\r\n# Desc.\r\n# flags: --a --b\r\n", "sh")
    t.eq(h.flags, { "--a", "--b" })
    local lua =
        header.parse("--[[\r\nLua desc.\r\ngroup: G\r\nflags: --x\r\n]]\r\nlocal x\r\n", "lua")
    t.eq(lua.desc, "Lua desc.")
    t.eq(lua.group, "G")
    t.eq(lua.flags, { "--x" })
end)

t.test("a positional line sets positional and stays out of the description", function()
    local h = header.parse(sh("# positional", "# Takes words.", "echo"), "sh")
    t.eq(h.positional, true)
    t.eq(h.desc, "Takes words.")
    t.eq(h.long, { "Takes words." })
    local lua = header.parse("--[[\nLua desc.\npositional\n]]\nlocal x\n", "lua")
    t.eq(lua.positional, true)
    t.eq(lua.long, { "Lua desc." })
end)

t.test("a positional line needs the word alone", function()
    t.eq(header.parse(sh("# Desc.", "# positional x", "echo"), "sh").positional, false)
    t.eq(header.parse(sh("# Desc.", "echo"), "sh").positional, false)
end)
