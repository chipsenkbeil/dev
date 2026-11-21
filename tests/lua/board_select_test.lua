local testing = require("dev.testing")
local board_select = require("dev.board.select")
local support = require("support")

local LIB = "dotfiles/bin/.local/share/dev/lua/dev/"

local function sources()
    return {
        [LIB .. "fs.lua"] = "return {}",
        [LIB .. "text.lua"] = "return {}",
        [LIB .. "board.lua"] = 'local fs = require("dev.fs")',
        [LIB .. "cmd/board.lua"] = 'local board = require("dev.board")',
        [LIB .. "driver.lua"] = 'return require("dev.drv." .. name)',
        [LIB .. "drv/apt.lua"] = "return {}",
        [LIB .. "orphan.lua"] = "return {}",
        ["tests/lua/support.lua"] = 'local fs = require("dev.fs")',
        ["tests/lua/text_test.lua"] = 'local text = require("dev.text")',
        ["tests/lua/board_test.lua"] = 'local board = require("dev.board")',
        ["tests/lua/cmd_test.lua"] = 'local cmd = require("dev.cmd.board")',
        ["tests/lua/driver_test.lua"] = 'local driver = require("dev.driver")',
        ["tests/lua/ui_test.lua"] = 'local support = require("support")',
        ["tests/dev/help.bats"] = "run dev help",
        ["tests/dev/other.bats"] = "run dev other",
    }
end

testing.test("a changed module picks the Lua suites that require it", function()
    local got = board_select.pick(sources(), { LIB .. "text.lua" })
    testing.eq(got, { "tests/lua/text_test.lua" })
end)

testing.test("a changed module picks the suites that require it through another module", function()
    local got = board_select.pick(sources(), { LIB .. "fs.lua" })
    testing.eq(
        got,
        { "tests/lua/board_test.lua", "tests/lua/cmd_test.lua", "tests/lua/ui_test.lua" }
    )
end)

testing.test(
    "a changed module picks the suites that load it through a concatenated require",
    function()
        local got = board_select.pick(sources(), { LIB .. "drv/apt.lua" })
        testing.eq(got, { "tests/lua/driver_test.lua" })
    end
)

testing.test("a changed module picks only the suites that load it", function()
    local all = sources()
    for i = 1, 50 do
        all["tests/dev/cli" .. i .. ".bats"] = "run dev help"
        all["tests/lua/cli" .. i .. "_test.lua"] = 'local support = require("support")'
    end
    local got = board_select.pick(all, { LIB .. "text.lua" })
    testing.ok(#got < 40)
    testing.eq(got, { "tests/lua/text_test.lua" })
end)

testing.test("a changed suite alone picks only itself", function()
    local got = board_select.pick(sources(), { "tests/lua/text_test.lua" })
    testing.eq(got, { "tests/lua/text_test.lua" })
end)

testing.test("a module and a suite pick both", function()
    local got = board_select.pick(sources(), { LIB .. "text.lua", "tests/lua/board_test.lua" })
    testing.eq(got, { "tests/lua/board_test.lua", "tests/lua/text_test.lua" })
end)

testing.test(
    "a changed module leaves out a suite that only runs dev or reads its source",
    function()
        local all = sources()
        all["tests/lua/env_test.lua"] = 'local env = require("dev.testenv")'
        all["tests/lua/reads_test.lua"] = 'local text = fs.read(dir .. "/text.lua")'
        local got = board_select.pick(all, { LIB .. "text.lua" })
        testing.eq(got, { "tests/lua/text_test.lua" })
    end
)

testing.test("a file that is not a Lua module leaves the map unsure", function()
    testing.eq(board_select.pick(sources(), { LIB .. "text.lua", "docs/dev/modules.md" }), nil)
end)

testing.test("a change that touches a non-Lua file runs the whole suite", function()
    for _, path in ipairs({ "src/main.rs", "Cargo.toml", ".dev/verb.lua", ".dev/__helper.sh" }) do
        testing.eq(board_select.pick(sources(), { LIB .. "text.lua", path }), nil)
        testing.eq(board_select.pick(sources(), { path }), nil)
    end
end)

testing.test("a module a verb loads leaves the map unsure, directly or through another", function()
    local all = sources()
    all[".dev/bump.lua"] = 'local fs = require("dev.fs")'
    testing.eq(board_select.pick(all, { LIB .. "fs.lua" }), nil)
    all[".dev/bump.lua"] = 'local board = require("dev.board")'
    testing.eq(board_select.pick(all, { LIB .. "fs.lua" }), nil)
    testing.eq(board_select.pick(all, { LIB .. "board.lua" }), nil)
end)

testing.test("a module a verb does not reach still picks its suites", function()
    local all = sources()
    all[".dev/bump.lua"] = 'local fs = require("dev.fs")'
    testing.eq(board_select.pick(all, { LIB .. "text.lua" }), { "tests/lua/text_test.lua" })
end)

testing.test("a test helper leaves the map unsure", function()
    testing.eq(board_select.pick(sources(), { "tests/lua/support.lua" }), nil)
end)

testing.test("a module no Lua suite reaches leaves the map unsure", function()
    testing.eq(board_select.pick(sources(), { LIB .. "orphan.lua" }), nil)
end)

testing.test("one module no suite reaches leaves the map unsure beside a covered one", function()
    testing.eq(board_select.pick(sources(), { LIB .. "text.lua", LIB .. "orphan.lua" }), nil)
end)

testing.test("an empty change leaves the map unsure", function()
    testing.eq(board_select.pick(sources(), {}), nil)
end)

testing.test("a plain remote test row is narrowed to the picked suites", function()
    local all = sources()
    local original = board_select.sources
    board_select.sources = function()
        return all
    end
    local argv, count = board_select.narrow("/x", { "dev", "--remote", "test" }, function()
        return { "tests/lua/text_test.lua" }
    end)
    board_select.sources = original
    testing.eq(argv, { "dev", "--remote", "test", "--", "tests/lua/text_test.lua" })
    testing.eq(count, 1)
end)

testing.test("a row that names suites or runs another command is left whole", function()
    local called = false
    local function touched()
        called = true
        return { "tests/lua/text_test.lua" }
    end
    for _, row in ipairs({
        { "dev", "--remote", "test", "--", "tests/lua/a_test.lua" },
        { "dev", "--remote", "lint" },
        { "dev", "test" },
    }) do
        local argv, count = board_select.narrow("/x", row, touched)
        testing.eq(argv, row)
        testing.eq(count, 0)
    end
    testing.eq(called, false)
end)

testing.test("a plain row stays whole when the change cannot be read or placed", function()
    local row = { "dev", "--remote", "test" }
    local argv, count = board_select.narrow("/x", row, function()
        return nil
    end)
    testing.eq(argv, row)
    testing.eq(count, 0)
end)

testing.test("narrow_rows narrows each plain test row and reports it", function()
    local all = sources()
    local original = board_select.sources
    board_select.sources = function()
        return all
    end
    local lint = { "dev", "--remote", "lint" }
    local plain = { "dev", "--remote", "test" }
    local negated = { "dev", "--remote", "test" }
    local told = {}
    local got = board_select.narrow_rows(
        "/x",
        { "dev --remote lint", "dev --remote test", "! dev --remote test" },
        { lint, plain, negated },
        function()
            return { "tests/lua/text_test.lua" }
        end,
        function(row, count)
            told[#told + 1] = { row, count }
        end
    )
    board_select.sources = original
    testing.eq(got[1], lint)
    testing.eq(got[2], { "dev", "--remote", "test", "--", "tests/lua/text_test.lua" })
    testing.eq(got[3], negated)
    testing.eq(told, { { 2, 1 } })
end)

testing.test("sources reads the Lua files and suites under a root", function()
    local root = support.sandbox({
        ["a/lua/m.lua"] = "return 1",
        ["tests/x_test.sh"] = "echo",
        ["tests/y.bats"] = "echo",
        ["other/z.sh"] = "echo",
    }, {})
    local got = board_select.sources(root)
    testing.eq(got["a/lua/m.lua"], "return 1")
    testing.ok(got["tests/x_test.sh"])
    testing.ok(got["tests/y.bats"])
    testing.eq(got["other/z.sh"], nil)
end)
