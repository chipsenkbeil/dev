local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")
local toml = require("@dev/toml")

local function tree(project, user)
    -- Make a project and a home
    local root = support.tempdir()
    local home = support.tempdir()

    -- Write the project config when given
    if project then
        assert(fs.mkdir(root .. "/.dev", { parents = true }))
        assert(fs.write(root .. "/.dev/config.toml", project))
    end

    -- Write the user config when given
    if user then
        assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
        assert(fs.write(home .. "/.config/dev/config.toml", user))
    end
    return root, home
end

local function get(root, home, key)
    local script = string.format(
        "local v = require('@dev/config').get(%q, %q); require('@dev/os').stdout:write(type(v), ':', tostring(v))",
        root,
        key
    )
    local out, code =
        dev_os.capture(support.eval(script), { stderr = "stdout", env = { HOME = home } })
    return out, code
end

testing.test("get reads the user file", function()
    local root, home = tree(nil, table.concat({ "[remote]", 'runner = "ci"', "" }, "\n"))
    testing.eq(get(root, home, "remote.runner"), "string:ci")
    testing.eq(get(root, home, "remote.other"), "nil:nil")
    testing.eq(get(root, home, "remote.runner.deeper"), "nil:nil")
end)

testing.test("a project value beats the user value and the rest falls through", function()
    local root, home = tree(
        table.concat({ "[remote]", 'runner = "mine"', "" }, "\n"),
        table.concat({ "[remote]", 'runner = "ci"', "other = 2", "" }, "\n")
    )
    testing.eq(get(root, home, "remote.runner"), "string:mine")
    testing.eq(get(root, home, "remote.other"), "number:2")
end)

testing.test("a project false still beats the user value", function()
    local root, home = tree("flag = false\n", "flag = true\n")
    testing.eq(get(root, home, "flag"), "boolean:false")
end)

testing.test("get reads a nested table across the two files", function()
    local root, home = tree(
        table.concat({ "[board]", 'backend = "pomb"', 'name = "dotfiles"', "" }, "\n"),
        table.concat({ "[board.pomb]", 'url = "https://x"', 'token = "pass:Agents/t"', "" }, "\n")
    )
    testing.eq(get(root, home, "board.backend"), "string:pomb")
    testing.eq(get(root, home, "board.pomb.url"), "string:https://x")
    testing.eq(get(root, home, "board.pomb.token"), "string:pass:Agents/t")
end)

testing.test("get is nil with no files", function()
    local root, home = tree()
    testing.eq(get(root, home, "remote.runner"), "nil:nil")
end)

testing.test("get ends with the path, line and exit 1 for a malformed project file", function()
    local root, home = tree(table.concat({ "a = 1", "b = ", "" }, "\n"), nil)
    local out, code = get(root, home, "a")
    testing.eq(code, 1)
    testing.ok(out:find(root .. "/.dev/config.toml:2:", 1, true), out)
end)

local function lines(list)
    return table.concat(list, "\n")
end

local REQUIRED_SET = lines({
    "[board.pomb]",
    'url = "u"',
    'token = "pass:a"',
    "[gerrit]",
    'host = "h"',
    "",
})

local HOST_ONLY = lines({ "[gerrit]", 'host = "h"', "" })

local function wizard(user, terminal, input)
    -- Make a project and a home, with the user config when given
    local root = support.sandbox({}, {})
    local home = support.tempdir()
    local path = home .. "/.config/dev/config.toml"
    if user then
        assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
        assert(fs.write(path, user))
    end

    -- Run the wizard with the answers
    local out, code = support.dev(root, { "config" }, {
        input = input,
        env = {
            HOME = home,
            NO_COLOR = "1",
            FAKE_TTY = terminal and "1" or "0",
            FAKE_DEV = "1",
        },
    })

    -- Hand back what it printed and what it wrote
    return out, code, fs.read(path)
end

testing.test(
    "dev config asks for each missing key on a terminal and appends the answers",
    function()
        -- Run the wizard on a config that has only the host
        local out, code, body = wizard(
            lines({ "# mine", "[gerrit]", 'host = "h"', "" }),
            true,
            lines({ "https://pomb.example", "pass:dev/pomb", "", "29418", "src/, lib/", "" })
        )
        testing.eq(code, 0)

        -- Ask only for the keys that are missing
        testing.ok(out:find("gerrit.host: set", 1, true), out)
        testing.ok(out:find("Wrote board.pomb.url to ", 1, true), out)

        -- Append the answers and keep the comment
        testing.ok(body:find("# mine\n", 1, true), body)
        testing.eq(assert(toml.parse(body)), {
            gerrit = { host = "h", port = 29418 },
            board = {
                pomb = { url = "https://pomb.example", token = "pass:dev/pomb" },
                ship = { source_roots = { "src/", "lib/" } },
            },
        })
    end
)

testing.test("dev config asks a required key again after a blank answer", function()
    local input = lines({ "", "https://u", "pass:a/b", "host.example", "", "", "", "" })
    local _, code, body = wizard(nil, true, input)
    testing.eq(code, 0)
    testing.eq(assert(toml.parse(body)).gerrit, { host = "host.example" })
end)

testing.test("dev config exits 0 with no gerrit.host when the required keys are set", function()
    local out, code = wizard(lines({ "[board.pomb]", 'url = "u"', 'token = "pass:a"', "" }), false)
    testing.eq(code, 0)
    testing.ok(out:find("gerrit.host: unset\n", 1, true), out)
end)

testing.test(
    "dev config lists each key without a terminal and exits 1 for a required one",
    function()
        -- Run the wizard without a terminal
        local out, code, body = wizard(HOST_ONLY, false)
        testing.eq(code, 1)

        -- List each key and mark the required ones that are unset
        testing.eq(
            out,
            table.concat({
                "board.pomb.url: unset, required",
                "board.pomb.token: unset, required",
                "gerrit.host: set",
                "board.pomb.field_prefix: unset",
                "gerrit.port: unset",
                "board.ship.source_roots: unset",
                "",
            }, "\n")
        )

        -- Leave the file as it was
        testing.eq(body, HOST_ONLY)
    end
)

testing.test(
    "dev config lists each key without a terminal and exits 0 when the required are set",
    function()
        local out, code = wizard(REQUIRED_SET, false)
        testing.eq(code, 0)
        testing.ok(out:find("board.pomb.token: set\n", 1, true), out)
    end
)

testing.test(
    "dev config refuses a token that is not a pass reference and writes nothing for it",
    function()
        -- Answer the token with a raw value
        local out, code, body = wizard(nil, true, lines({ "https://u", "raw-made-up-value", "" }))
        testing.eq(code, 1)

        -- Refuse it without echoing it
        testing.ok(out:find("takes only a pass:<entry> reference", 1, true), out)
        testing.eq(out:find("raw-made-up-value", 1, true), nil)

        -- Write the url and no token
        testing.eq(assert(toml.parse(body)), { board = { pomb = { url = "https://u" } } })
        testing.eq(body:find("token", 1, true), nil)
    end
)

testing.test("dev config takes a pass reference after it refused another answer", function()
    -- Answer the token with two bad references and then a good one
    local input = lines({ "https://u", "pass:", "pass:../x", "pass:ok/ref", "h", "", "", "", "" })
    local out, code, body = wizard(nil, true, input)
    testing.eq(code, 0)

    -- Keep the reference out of the output
    testing.eq(out:find("pass:ok/ref", 1, true), nil)

    -- Write the good reference
    testing.eq(assert(toml.parse(body)).board.pomb.token, "pass:ok/ref")
end)

testing.test("dev config refuses a port that is not in range", function()
    local input = lines({ "", "abc", "1000000000000000000", "70000", "22", "", "" })
    local out, _, body = wizard(REQUIRED_SET, true, input)
    testing.ok(out:find("gerrit.port takes a whole number from 1 to 65535.", 1, true), out)
    testing.eq(assert(toml.parse(body)).gerrit, { host = "h", port = 22 })
end)

testing.test("dev config stops with a sentence when the key cannot be added to the file", function()
    local user = lines({ '[board."pomb"]', 'url = "u"', "" })
    local out, code = wizard(user, true, lines({ "pass:a", "h", "", "", "" }))
    testing.eq(code, 1)
    testing.ok(out:find("config.toml: board.pomb.token: The file would not parse", 1, true), out)
end)

local function board_without_url(opts)
    -- Make a Pomb project and a home with no config
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "pomb"',
            'name = "x"',
            "",
        }, "\n"),
    }, {})
    local home = support.tempdir()

    -- Run a board command and answer the url prompt
    local out, code = support.dev(root, { "board", "next" }, {
        input = "https://pomb.example\n",
        env = {
            HOME = home,
            NO_COLOR = "1",
            DEV_AGENT = opts.agent,
            FAKE_TTY = opts.terminal and "1" or "0",
            FAKE_DEV = "1",
        },
    })

    -- Hand back what it printed and what it wrote
    return out, code, fs.read(home .. "/.config/dev/config.toml")
end

testing.test(
    "a missing Pomb url starts the prompt on a terminal and the command carries on",
    function()
        -- Run a board command on a terminal with no url
        local out, _, body = board_without_url({ terminal = true, agent = "" })

        -- Prompt for the url and say where it went
        testing.ok(out:find("Pomb URL: ", 1, true), out)
        testing.ok(out:find("Wrote board.pomb.url to ", 1, true), out)

        -- Write the answer and accept it
        testing.eq(
            assert(toml.parse(body)),
            { board = { pomb = { url = "https://pomb.example" } } }
        )
        testing.eq(out:find("must be an http or https address", 1, true), nil)
    end
)

testing.test("a missing Pomb url refuses with the dev config sentence without a prompt", function()
    local cases = {
        { terminal = false, agent = "" },
        { terminal = true, agent = "x/implementer/y" },
    }
    for _, case in ipairs(cases) do
        local out, code, body = board_without_url(case)
        testing.eq(code, 1, out)
        testing.ok(out:find("Run `dev config` to set it.", 1, true), out)
        testing.eq(out:find("Pomb URL: ", 1, true), nil)
        testing.eq(body, nil)
    end
end)

testing.test("dev config refuses an argument", function()
    local root = support.sandbox({}, {})
    local _, code = support.dev(root, { "config", "extra" }, { env = { HOME = support.tempdir() } })
    testing.eq(code, 2)
end)

testing.test("get validates the user file even when the project sets the key", function()
    local root, home = tree("x = 1\n", "x = \n")
    local out, code = get(root, home, "x")
    testing.eq(code, 1)
    testing.ok(out:find(home .. "/.config/dev/config.toml:1:", 1, true), out)
end)
