local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")
local support = require("./support")

local function project(files)
    local root = support.tempdir()
    for name, source in pairs(files) do
        local path = root .. "/" .. (name:find("^help/") and ".dev/" or ".dev/commands/") .. name
        if name:find("^docs/") or name:find("^luau/") then
            path = root .. "/" .. name
        end
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        if name:find("%.sh$") then
            assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
        end
    end
    return root
end

local function dev(root, args)
    local argv = { runtime.exe }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return dev_os.capture(argv, { cwd = root, stderr = "null" })
end

local function complete(root, words)
    local args = { "__complete", "--" }
    for _, word in ipairs(words) do
        args[#args + 1] = word
    end
    return dev(root, args)
end

local function values(out)
    local list = {}
    for line in out:gmatch("[^\n]+") do
        list[#list + 1] = line:match("^[^\t]*")
    end
    return list
end

local SPEC = [[return require("@dev/command")({
    summary = "Wait for a thing",
    flags = {
        { name = "wait", short = "w", kind = "number", default = 30, help = "Seconds to wait" },
        { name = "mode", kind = "string", choices = { "fast", "slow" } },
        { name = "label", kind = "string", complete = { "red", "green" } },
    },
    args = { { name = "card", required = true, complete = function() return { "alpha", "beta" } end } },
    run = function() return 0 end,
})
]]

local FILE_SPEC = table.concat({
    'return require("@dev/command")({',
    '    summary = "Take a file",',
    '    args = { { name = "path", complete = "file" } },',
    "    run = function() return 0 end,",
    "})",
    "",
}, "\n")

local function has(list, word)
    for _, value in ipairs(list) do
        if value == word then
            return true
        end
    end
    return false
end

testing.test("a command word completes with its summary and a prefix filters", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n" })
    testing.ok(dev(root, { "__complete", "--", "" }):find("\na\tA command%.\n"))
    local found = values(complete(root, { "a" }))
    testing.ok(has(found, "a"), table.concat(found, ","))
    for _, value in ipairs(found) do
        testing.eq(value:sub(1, 1), "a")
    end
    testing.eq(values(complete(root, { "zz" })), {})
end)

testing.test("hidden commands and helpers are never completed", function()
    local root = project({ ["q.sh"] = "#!/usr/bin/env bash\n# Quiet.\n# hidden\n" })
    testing.ok(not complete(root, { "" }):find("\nq\t") and not complete(root, { "" }):find("^q\t"))
    testing.ok(not complete(root, { "" }):find("__complete", 1, true))
end)

testing.test("a subcommand completes after its parent command", function()
    local out = complete(project({}), { "board", "mo" })
    testing.eq(values(out), { "move" })
end)

testing.test("flags, choices, a list and a function complete from the spec", function()
    local root = project({ ["w.luau"] = SPEC })
    local flags = values(complete(root, { "w", "--" }))
    for _, flag in ipairs({ "--wait", "-w", "--mode", "--label", "--help" }) do
        testing.ok(table.concat(flags, " "):find(flag, 1, true), flag)
    end
    testing.eq(values(complete(root, { "w", "--mode", "" })), { "fast", "slow" })
    testing.eq(values(complete(root, { "w", "--mode", "s" })), { "slow" })
    testing.eq(values(complete(root, { "w", "--label", "" })), { "red", "green" })
    testing.eq(values(complete(root, { "w", "--mode=f" })), { "--mode=fast" })
    testing.eq(values(complete(root, { "w", "" })), { "alpha", "beta" })
    testing.eq(values(complete(root, { "w", "--wait", "5", "b" })), { "beta" })
end)

testing.test("global flags before the command word are skipped", function()
    local root = project({ ["w.luau"] = SPEC })
    testing.eq(values(complete(root, { "-v", "--remote", "w", "--mode", "" })), { "fast", "slow" })
end)

testing.test("a provider that fails prints nothing and the command exits 0", function()
    local root = project({
        ["w.luau"] = SPEC:gsub(
            'complete = function%(%) return { "alpha", "beta" } end',
            'complete = "nosuch"'
        ),
    })
    local out, code = dev_os.capture(
        { runtime.exe, "__complete", "--", "w", "" },
        { cwd = root, stderr = "null" }
    )
    testing.eq(out, "")
    testing.eq(code, 0)
end)

testing.test("the box provider prints nothing without ci", function()
    local root = project({})
    local out, code = dev_os.capture(
        { runtime.exe, "__complete", "--", "box", "show", "" },
        { cwd = root, stderr = "null", env = { PATH = "/usr/bin:/bin" } }
    )
    testing.eq(out, "")
    testing.eq(code, 0)
end)

testing.test("the card cache gives ids and a stale one is not an error", function()
    local root = project({})
    local cache = support.tempdir()
    local board_card = require("@dev/complete/board_card")
    dev_os.setenv("XDG_CACHE_HOME", cache)
    local file = board_card.cache_file(root)
    assert(fs.mkdir(fs.dirname(file), { parents = true }))
    assert(fs.write(file, os.time() .. "\n8af0e001 A card\nnot a card\n"))
    local items = board_card.candidates({ root = root })
    testing.eq(items, { { value = "8af0e001", desc = "A card" } })
    dev_os.setenv("XDG_CACHE_HOME", nil)
end)

testing.test("dev completion prints a script for each shell and refuses another", function()
    local root = project({})
    for _, shell in ipairs({ "bash", "zsh", "fish", "powershell" }) do
        local out, code = dev_os.capture({ runtime.exe, "completion", shell }, { cwd = root })
        testing.eq(code, 0)
        testing.ok(out:find("__complete", 1, true), shell)
    end
    local out, code = dev_os.capture(
        { runtime.exe, "completion", "tcsh" },
        { cwd = root, stderr = "stdout" }
    )
    testing.eq(code, 2)
    testing.ok(out:find("bash, zsh, fish, powershell", 1, true), out)
end)

testing.test("help --check-topics reports a spec that declares -h and exits 1", function()
    local root = project({
        ["a.luau"] = SPEC:gsub('name = "mode"', 'name = "x", short = "h"'),
    })
    local out, code = dev_os.capture(
        { runtime.exe, "help", "--check-topics" },
        { cwd = root, stderr = "stdout" }
    )
    testing.eq(code, 1)
    testing.eq(
        out,
        ".dev/commands/a.luau:1: the spec declares -h or --help, which dev reserves before --\n"
    )
end)

testing.test("the built-in topics are checked from disk when the project is dev itself", function()
    local root = project({
        ["luau/dev/cli.luau"] = "return {}\n",
        ["docs/bad.md"] = "# bad: A topic\n\n`dev nope`\n",
    })
    local out, code = dev_os.capture(
        { runtime.exe, "help", "--check-topics" },
        { cwd = root, stderr = "stdout" }
    )
    testing.eq(code, 1)
    testing.ok(out:find("docs/bad.md:3: `dev nope`: no command nope", 1, true), out)
    local flagged = 0
    for line in out:gmatch("[^\n]+") do
        if line:find("docs/", 1, true) then
            flagged = flagged + 1
        end
    end
    testing.eq(flagged, 1, out)
end)

testing.test("a project topic named like a built-in topic is reported", function()
    local root = project({ ["help/commands.md"] = "# commands: Clash\n\nText.\n" })
    local out, code = dev_os.capture(
        { runtime.exe, "help", "--check-topics" },
        { cwd = root, stderr = "stdout" }
    )
    testing.eq(code, 1)
    testing.ok(
        out:find(
            ".dev/help/commands.md:1: help page commands is also a built-in help page",
            1,
            true
        ),
        out
    )
end)

local function shim(root)
    local bin = root .. "/shim"
    assert(fs.mkdir(bin, { parents = true }))
    local path = bin .. "/dev"
    assert(fs.write(path, '#!/bin/sh\nexec "' .. runtime.exe .. '" "$@"\n'))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    return bin
end

local function bash_words(root, script, words, cword, home)
    local bin = shim(root)
    local quoted = {}
    for _, word in ipairs(words) do
        quoted[#quoted + 1] = "'" .. word:gsub("'", "'\\''") .. "'"
    end
    local program = table.concat({
        "source '" .. script .. "'",
        "COMP_WORDS=(" .. table.concat(quoted, " ") .. ")",
        "COMP_CWORD=" .. cword,
        "_dev_complete",
        'printf "%s\\n" "${COMPREPLY[@]}"',
    }, "\n")
    return dev_os.capture({ "bash", "-c", program }, {
        cwd = root,
        env = { PATH = bin .. ":" .. dev_os.getenv("PATH"), HOME = home or root },
        stderr = "null",
    })
end

local function bash_script(root)
    local path = root .. "/dev-completion.bash"
    assert(fs.write(path, require("@dev/complete/scripts").for_shell("bash")))
    return path
end

testing.test("the bash script joins a flag value split at the equals sign", function()
    local root = project({ ["w.luau"] = SPEC })
    local out = bash_words(root, bash_script(root), { "dev", "w", "--mode", "=", "f" }, 4)
    testing.eq(values(out), { "fast" })
end)

testing.test("the bash script quotes a candidate that holds a space", function()
    local root = project({ ["w.luau"] = FILE_SPEC })
    assert(fs.write(root .. "/with space", ""))
    local out = bash_words(root, bash_script(root), { "dev", "w", "wi" }, 2)
    testing.ok(out:find("with space", 1, true) ~= nil, out)
end)

testing.test("the bash script expands a tilde after -C", function()
    local root = project({ ["w.luau"] = SPEC })
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/x/.dev/commands", { parents = true }))
    assert(fs.write(home .. "/x/.dev/commands/zed.sh", "#!/usr/bin/env bash\n# Zed.\n"))
    assert(dev_os.run({ "chmod", "755", home .. "/x/.dev/commands/zed.sh" }) == 0)
    local out = bash_words(root, bash_script(root), { "dev", "-C", "~/x", "z" }, 3, home)
    testing.eq(values(out), { "zed" })
end)

testing.test("-C through the leading flags completes with that project's commands", function()
    local root = project({})
    local other = project({ ["zed.sh"] = "#!/usr/bin/env bash\n# Zed.\n" })
    testing.ok(values(complete(root, { "-C", other, "z" }))[1] == "zed")
end)

testing.test("a fresh refresh lock keeps a second Tab from starting another refresh", function()
    local board_card = require("@dev/complete/board_card")
    local root = support.tempdir()
    local cache = support.tempdir()
    dev_os.setenv("XDG_CACHE_HOME", cache)
    local file = board_card.cache_file(root)
    assert(fs.mkdir(fs.dirname(file), { parents = true }))
    assert(fs.write(file .. ".lock", tostring(os.time())))
    board_card.candidates({ root = root })
    testing.eq(fs.read(file), nil)
    testing.eq(
        fs.list(fs.dirname(file)),
        { fs.basename(file) .. ".guard", fs.basename(file) .. ".lock" }
    )
end)
