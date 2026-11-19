local testing = require("dev.testing")
local header = require("dev.header")

local function sh(...)
    local entries = { "#!/usr/bin/env bash", ... }
    entries[#entries + 1] = ""
    return table.concat(entries, "\n")
end

testing.test("the description is the first comment line after the shebang", function()
    local h = header.parse(sh("# Do the thing.", "# More words.", "", "echo hi"), "sh")
    testing.eq(h.desc, "Do the thing.")
    testing.eq(h.long, { "Do the thing.", "More words." })
end)

testing.test("shellcheck, flags, group and hidden lines never become the description", function()
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
    testing.eq(h.desc, "The real one.")
end)

testing.test("blank lines before the first comment are skipped", function()
    testing.eq(header.parse(sh("", "  ", "# After blanks.", "echo"), "sh").desc, "After blanks.")
end)

testing.test("code before any comment leaves the description empty", function()
    testing.eq(header.parse(sh("echo hi", "# Late."), "sh").desc, "")
end)

testing.test("the long form drops shellcheck, group and hidden lines and stops at code", function()
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
    testing.eq(h.long, { "Title.", "flags: --a", "KEY=1 sets it" })
end)

testing.test("flags split on spaces and commas", function()
    testing.eq(
        header.parse(sh("# Desc.", "# flags: --a, --b  -c"), "sh").flags,
        { "--a", "--b", "-c" }
    )
end)

testing.test("-h and --help are dropped from flags with a warning naming the file", function()
    local h = header.parse(sh("# Desc.", "# flags: --a -h --help --b"), "sh", "/p/.dev/x.sh")
    testing.eq(h.flags, { "--a", "--b" })
    testing.eq(h.warnings, {
        "The flags line of /p/.dev/x.sh declares -h, which dev reserves before --.",
        "The flags line of /p/.dev/x.sh declares --help, which dev reserves before --.",
    })
end)

testing.test("only the first flags line counts and code ends the search", function()
    testing.eq(header.parse(sh("# Desc.", "# flags: --a", "# flags: --b"), "sh").flags, { "--a" })
    testing.eq(header.parse(sh("# Desc.", "echo", "# flags: --a"), "sh").flags, {})
end)

testing.test("a blank line does not end the flags search", function()
    testing.eq(header.parse(sh("# Desc.", "", "# flags: --a"), "sh").flags, { "--a" })
end)

testing.test(
    "the group is the first non-empty group line, and hidden is a line by itself",
    function()
        local h = header.parse(
            sh("# Desc.", "# group:", "# group: First", "# group: Second", "# hidden"),
            "sh"
        )
        testing.eq(h.group, "First")
        testing.eq(h.hidden, true)
        local plain = header.parse(sh("# Desc.", "# hidden stuff"), "sh")
        testing.eq(plain.hidden, false)
        testing.eq(plain.group, nil)
    end
)

testing.test("a Lua header is one leading block comment holding the same lines", function()
    local h = header.parse(
        table.concat({
            "--[[",
            "Run the thing.",
            "group: Share it",
            "hidden",
            "flags: --x, -h --y",
            "KEY=value sets it",
            "]]",
            "local x = 1",
            "-- flags: --nope",
            "",
        }, "\n"),
        "lua",
        "/p/.dev/t.lua"
    )
    testing.eq(h.desc, "Run the thing.")
    testing.eq(h.group, "Share it")
    testing.eq(h.hidden, true)
    testing.eq(h.flags, { "--x", "--y" })
    testing.eq(h.long, { "Run the thing.", "flags: --x, -h --y", "KEY=value sets it" })
    testing.eq(#h.warnings, 1)
end)

testing.test("a Lua file with no leading block has an empty header", function()
    local h = header.parse("-- Not a block.\nlocal x = 1\n", "lua")
    testing.eq(h.desc, "")
    testing.eq(h.flags, {})
    testing.eq(h.long, {})
end)

testing.test("CRLF line endings do not reach the flags or a Lua header", function()
    local h = header.parse("#!/bin/sh\r\n# Desc.\r\n# flags: --a --b\r\n", "sh")
    testing.eq(h.flags, { "--a", "--b" })
    local lua =
        header.parse("--[[\r\nLua desc.\r\ngroup: G\r\nflags: --x\r\n]]\r\nlocal x\r\n", "lua")
    testing.eq(lua.desc, "Lua desc.")
    testing.eq(lua.group, "G")
    testing.eq(lua.flags, { "--x" })
end)

testing.test("a positional line sets positional and stays out of the description", function()
    local h = header.parse(sh("# positional", "# Takes words.", "echo"), "sh")
    testing.eq(h.positional, true)
    testing.eq(h.desc, "Takes words.")
    testing.eq(h.long, { "Takes words." })
    local lua = header.parse("--[[\nLua desc.\npositional\n]]\nlocal x\n", "lua")
    testing.eq(lua.positional, true)
    testing.eq(lua.long, { "Lua desc." })
end)

testing.test("a fetch line names the job and the file and is not part of the text", function()
    local h = header.parse(sh("# Builds it.", "# fetch client ci", "# More.", "echo"), "sh")
    testing.eq(h.fetch, { job = "client", file = "ci" })
    testing.eq(h.desc, "Builds it.")
    testing.eq(h.long, { "Builds it.", "More." })
    local lua = header.parse("--[[\nBuilds it.\nfetch client ci\n]]\nlocal x\n", "lua")
    testing.eq(lua.fetch, { job = "client", file = "ci" })
    testing.eq(lua.long, { "Builds it." })
end)

testing.test("a fetch line needs exactly a job and a file", function()
    testing.eq(header.parse(sh("# Desc.", "# fetch client", "echo"), "sh").fetch, nil)
    testing.eq(header.parse(sh("# Desc.", "# fetch a b c", "echo"), "sh").fetch, nil)
    testing.eq(header.parse(sh("# Desc.", "echo"), "sh").fetch, nil)
end)

testing.test("a patch line names the job and the file and is not part of the text", function()
    local h = header.parse(sh("# Formats it.", "# patch fmt fmt.patch", "# More.", "echo"), "sh")
    testing.eq(h.patch, { job = "fmt", file = "fmt.patch" })
    testing.eq(h.desc, "Formats it.")
    testing.eq(h.long, { "Formats it.", "More." })
    local lua = header.parse("--[[\nFormats it.\npatch fmt fmt.patch\n]]\nlocal x\n", "lua")
    testing.eq(lua.patch, { job = "fmt", file = "fmt.patch" })
    testing.eq(lua.long, { "Formats it." })
end)

testing.test("a patch line needs exactly a job and a file", function()
    testing.eq(header.parse(sh("# Desc.", "# patch fmt", "echo"), "sh").patch, nil)
    testing.eq(header.parse(sh("# Desc.", "# patch a b c", "echo"), "sh").patch, nil)
    testing.eq(header.parse(sh("# Desc.", "echo"), "sh").patch, nil)
end)

testing.test("a header with a fetch and a patch line keeps both", function()
    local h =
        header.parse(sh("# Desc.", "# fetch client ci", "# patch fmt fmt.patch", "echo"), "sh")
    testing.eq(h.fetch, { job = "client", file = "ci" })
    testing.eq(h.patch, { job = "fmt", file = "fmt.patch" })
end)

testing.test("a positional line needs the word alone", function()
    testing.eq(header.parse(sh("# Desc.", "# positional x", "echo"), "sh").positional, false)
    testing.eq(header.parse(sh("# Desc.", "echo"), "sh").positional, false)
end)
