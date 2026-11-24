local testing = require("dev.testing")
local header = require("dev.header")

local function sh(...)
    local entries = { "#!/usr/bin/env bash", ... }
    entries[#entries + 1] = ""
    return table.concat(entries, "\n")
end

local function parse(...)
    return assert(header.parse(sh(...), "/p/.dev/commands/x.sh"))
end

testing.test("the summary is the first comment line after the shebang", function()
    local spec = parse("# Do the thing.", "# More words.", "", "echo hi")
    testing.eq(spec.summary, "Do the thing.")
    testing.eq(spec.long, "More words.")
end)

testing.test("a summary line wins over the first comment and stays out of the long text", function()
    local spec = parse("# summary: Short", "# Longer words.")
    testing.eq(spec.summary, "Short")
    testing.eq(spec.long, "Longer words.")
end)

testing.test("shellcheck, group and hidden lines never become the summary", function()
    local spec = parse(
        "# shellcheck disable=SC2034",
        "# group: Boxes",
        "# hidden",
        "# The real one.",
        "echo"
    )
    testing.eq(spec.summary, "The real one.")
    testing.eq(spec.group, "Boxes")
    testing.eq(spec.hidden, true)
end)

testing.test("blank lines before the first comment are skipped", function()
    testing.eq(parse("", "  ", "# After blanks.", "echo").summary, "After blanks.")
end)

testing.test("code before any comment leaves the summary empty", function()
    testing.eq(parse("echo hi", "# Late.").summary, "")
end)

testing.test("a flag line declares its short, kind, choices, default and help", function()
    local spec = parse(
        "# flag: wait short=w kind=number default=30 -- Seconds to wait",
        "# flag: mode choices=a,b required",
        "# flag: label repeatable"
    )
    testing.eq(spec.flags[1], {
        name = "wait",
        short = "w",
        kind = "number",
        default = 30,
        help = "Seconds to wait",
    })
    testing.eq(spec.flags[2].choices, { "a", "b" })
    testing.eq(spec.flags[2].required, true)
    testing.eq(spec.flags[3].repeatable, true)
end)

testing.test("an arg line declares required and list", function()
    local spec = parse("# arg: card required -- The card", "# arg: rest list")
    testing.eq(spec.args[1].required, true)
    testing.eq(spec.args[1].help, "The card")
    testing.eq(spec.args[2].list, true)
end)

testing.test("a flag that names help is refused", function()
    local spec, reason = header.parse(sh("# flag: help"), "/p/x.sh")
    testing.eq(spec, nil)
    testing.ok(reason:find("reserved", 1, true), reason)
end)

testing.test("the old flags and local markers fail with their replacement", function()
    local _, flags_reason = header.parse(sh("# flags: --a"), "/p/x.sh")
    testing.ok(flags_reason:find("# flag: NAME", 1, true), flags_reason)
    local _, local_reason = header.parse(sh("# local"), "/p/x.sh")
    testing.ok(local_reason:find("# runs_local", 1, true), local_reason)
end)

testing.test("a runs_local, passthrough and positional line set their fields", function()
    local spec = parse("# Desc.", "# runs_local", "# passthrough", "# positional")
    testing.eq(spec.runs_local, true)
    testing.eq(spec.passthrough, true)
    testing.eq(spec.positional, true)
    testing.eq(spec.summary, "Desc.")
end)

testing.test("a see_also line lists its help page names", function()
    local spec = parse("# Desc.", "# see_also: boards  flags")
    testing.eq(spec.see_also, { "boards", "flags" })
    testing.eq(spec.long, nil)
end)

testing.test("a fetch and a patch line name the job and the file", function()
    local spec = parse("# Desc.", "# fetch ci out.txt", "# patch job file.diff")
    testing.eq(spec.fetch, { job = "ci", file = "out.txt" })
    testing.eq(spec.patch, { job = "job", file = "file.diff" })
end)

testing.test("a remote line and a requires line set their fields", function()
    local spec = parse("# Desc.", "# remote: false", "# requires: workspace")
    testing.eq(spec.remote, false)
    testing.eq(spec.requires, { "workspace" })
end)

testing.test("an unknown word on a requires line fails the header", function()
    local spec, reason = header.parse(sh("# requires: workspace moon"), "/p/x.sh")
    testing.eq(spec, nil)
    testing.ok(reason:find("moon", 1, true), reason)
end)

testing.test("CRLF line endings do not reach the fields", function()
    local spec = assert(header.parse("#!/bin/sh\r\n# flag: a -- A\r\n", "/p/x.sh"))
    testing.eq(spec.flags[1].help, "A")
end)

testing.test("a powershell header has no shebang", function()
    local spec = assert(header.parse("# summary: Hi\nWrite-Host hi\n", "/p/x.ps1"))
    testing.eq(spec.summary, "Hi")
end)
