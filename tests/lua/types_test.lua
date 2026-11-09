local testing = require("dev.testing")
local fs = require("dev.fs")
local project = require("dev.project")
local support = require("support")
local types = require("dev.cmd.types")

local function tree(files)
    local root = support.tempdir()
    for name, text in pairs(files) do
        assert(fs.write(root .. "/" .. name, text))
    end
    return root
end

local function lines_for(root, verb)
    return types.commands(root, project.detect_type(root) or "none", verb)
end

testing.test("a project with Cargo.toml and package.json is rust", function()
    local root = tree({ ["Cargo.toml"] = "", ["package.json"] = '{"scripts":{"test":"x"}}' })
    testing.eq(project.detect_type(root), "rust")
    testing.eq(lines_for(root, "test"), {
        "cargo nextest run --all-features",
        "cargo test --doc --all-features",
    })
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a Makefile target is preferred for a lua project and named when it is missing",
    function()
        local root =
            tree({ ["x.lua"] = "return 1\n", Makefile = "test:\n\ttrue\nlint :\n\ttrue\n" })
        testing.eq(project.detect_type(root), "lua")
        testing.eq(lines_for(root, "test"), { "make -C " .. root .. " test" })
        testing.eq(lines_for(root, "lint"), { "make -C " .. root .. " lint" })
        testing.eq(lines_for(root, "build"), { "(none: no build target in the Makefile)" })
        testing.eq(lines_for(root, "fmt"), { "stylua " .. root })
        fs.remove(root, { recursive = true })
    end
)

testing.test("a love2d project runs love and has make targets only for test and lint", function()
    local root = tree({ ["main.lua"] = "", ["conf.lua"] = "", Makefile = "lint:\n\ttrue\n" })
    testing.eq(lines_for(root, "run"), { "love " .. root })
    testing.eq(lines_for(root, "lint"), { "make -C " .. root .. " lint" })
    testing.eq(lines_for(root, "test"), { "(none: no test target in the Makefile)" })
    testing.eq(lines_for(root, "build"), { "(none: no built-in build for love2d projects)" })
    fs.remove(root, { recursive = true })
end)

testing.test("a node project names the package.json scripts it has", function()
    local root = tree({ ["package.json"] = '{"scripts":{"test":"echo hi","lint":null}}' })
    testing.eq(lines_for(root, "test"), { "npm --prefix " .. root .. " run test" })
    testing.eq(lines_for(root, "lint"), { "(none: no lint script in package.json)" })
    testing.eq(lines_for(root, "build"), { "(none: no build script in package.json)" })
    fs.remove(root, { recursive = true })
end)

testing.test("the rust lint help quotes the glob the shell would expand", function()
    local root = tree({ ["Cargo.toml"] = "", ["sgconfig.yml"] = "" })
    testing.eq(lines_for(root, "lint"), {
        "cargo +nightly fmt --check",
        "cargo clippy --all-targets --all-features -- -D warnings",
        "ast-grep scan --globs '!target/**'",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("rust fetch adds cargo deny only with a deny.toml", function()
    local root = tree({ ["Cargo.toml"] = "" })
    testing.eq(lines_for(root, "fetch"), { "env CARGO_NET_OFFLINE=false cargo fetch --locked" })
    assert(fs.write(root .. "/deny.toml", ""))
    testing.eq(lines_for(root, "fetch"), {
        "env CARGO_NET_OFFLINE=false cargo fetch --locked",
        "env CARGO_NET_OFFLINE=false cargo deny fetch",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("an undetected project has no built-in", function()
    local root = tree({})
    testing.eq(lines_for(root, "lint"), { "(none: no built-in lint for none projects)" })
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a failing make target ends dev with make's exit code after showing the command",
    function()
        local root = support.sandbox({ ["x.lua"] = "return 1\n", Makefile = "test:\n\ttrue\n" })
        local out, code = support.dev(root, { "-v", "test", "a", "b" }, { code = "3" })
        testing.eq(code, 3)
        testing.ok(out:find("+ make -C " .. root .. " test a b\n", 1, true), out)
        testing.ok(out:find("make -C " .. root .. " test a b cwd=", 1, true), out)
        testing.ok(not out:find("no built-in", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("arguments reach npm after a --, and no -- without arguments", function()
    local root = support.sandbox({ ["package.json"] = '{"scripts":{"test":"x"}}' })
    local out, code = support.dev(root, { "test", "--watch", "a" })
    testing.eq(code, 0)
    testing.ok(out:find("npm --prefix " .. root .. " run test -- --watch a cwd=", 1, true), out)
    out = support.dev(root, { "test" })
    testing.ok(out:find("npm --prefix " .. root .. " run test cwd=", 1, true), out)
    testing.ok(not out:find(" -- ", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "ast-grep and cargo fetch run in the project root, cargo fmt where dev was run",
    function()
        local root =
            support.sandbox({ ["Cargo.toml"] = "", ["sgconfig.yml"] = "", ["deny.toml"] = "" })
        assert(fs.mkdir(root .. "/sub", { parents = true }))
        local out, code = support.dev(root, { "lint" }, { cwd = root .. "/sub" })
        testing.eq(code, 0)
        testing.ok(out:find("ast-grep scan --globs !target/** cwd=" .. root .. "\n", 1, true), out)
        testing.ok(out:find("cargo +nightly fmt --check cwd=" .. root .. "/sub\n", 1, true), out)
        out, code = support.dev(root, { "fetch" }, { cwd = root .. "/sub" })
        testing.eq(code, 0)
        testing.ok(out:find("cargo fetch --locked cwd=" .. root .. "\n", 1, true), out)
        testing.ok(out:find("cargo deny fetch cwd=" .. root .. "\n", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)
