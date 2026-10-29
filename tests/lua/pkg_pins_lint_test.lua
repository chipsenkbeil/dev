local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local manifest = require("dev.pkg.manifest")
local release = require("dev.pkg.release")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local PINS = REPO .. "/.dev/releases.tsv"
local PKG = REPO .. "/dotfiles/bin/.local/share/dev/pkg.lua"
local COLUMN = "darwin-x86_64"
local LINT_PINS = { "shellcheck", "shfmt", "stylua" }
local SYSTEM_TOOLS = { "git", "zsh", "dash", "luajit" }
local DROPPED = { "difftastic", "tokei", "watchexec", "hyperfine", "ast-grep" }
local SOURCE_BUILDS = { "bats", "stow" }
local UNAME = '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Darwin ;; esac\n'

local function base_cells()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    local column = assert(manifest.column(rows, COLUMN))
    local cells = {}
    for _, row in ipairs(rows) do
        for _, group in ipairs(row.groups) do
            if group == "base" then
                cells[row.name] = row.fields[column] or ""
            end
        end
    end
    return cells
end

local function set_of(list)
    local set = {}
    for _, name in ipairs(list) do
        set[name] = true
    end
    return set
end

t.test("no base row has an empty darwin-x86_64 cell", function()
    for tool, cell in pairs(base_cells()) do
        t.ok(cell ~= "", tool .. " has an empty " .. COLUMN .. " cell")
    end
end)

t.test("the lint tools are pinned releases and selene builds with cargo", function()
    local cells = base_cells()
    local pins = assert(release.read(PINS))
    for _, tool in ipairs(LINT_PINS) do
        t.eq(cells[tool], "release:" .. tool)
        t.ok(pins[tool], tool .. " has no pin")
    end
    t.eq(cells.selene, "cargo:selene")
end)

t.test("git, zsh and dash are system tools", function()
    local cells = base_cells()
    for _, tool in ipairs(SYSTEM_TOOLS) do
        t.eq(cells[tool], "system:" .. tool)
    end
end)

t.test("the dropped base rows are exactly the dash cells", function()
    local expected = set_of(DROPPED)
    local dashes = {}
    for tool, cell in pairs(base_cells()) do
        if cell == "-" then
            dashes[tool] = true
        end
    end
    t.eq(dashes, expected)
end)

t.test("the Darwin x86_64 dry run prints the release steps for the lint pins", function()
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(dir .. "/stubs"))
    assert(fs.mkdir(dir .. "/home"))
    assert(fs.write(dir .. "/stubs/uname", UNAME))
    assert(devos.run({ "chmod", "755", dir .. "/stubs/uname" }) == 0, "chmod failed")
    local luajit = devos.capture({ "sh", "-c", "command -v luajit" }):gsub("\n$", "")
    local out, code = devos.capture({
        luajit,
        PKG,
        "install",
        "--dry-run",
        "--group",
        "base",
        "--manifest",
        REPO .. "/.dev/tools.tsv",
    }, {
        stderr = "stdout",
        env = {
            PATH = dir .. "/stubs",
            HOME = dir .. "/home",
            DEV_TOOLS_BIN = dir .. "/bin",
        },
    })
    t.eq(code, 0)
    for _, tool in ipairs(LINT_PINS) do
        t.ok(out:find(tool .. " (dry-run):", 1, true), out)
    end
    t.ok(out:find("shellcheck-v0.11.0.darwin.x86_64.tar.xz", 1, true), out)
    t.ok(out:find("shfmt_v3.14.1_darwin_amd64", 1, true), out)
    t.ok(out:find("stylua-macos-x86_64.zip", 1, true), out)
    t.ok(out:find("selene (dry-run):\n      cargo", 1, true), out)
    t.ok(out:find("cargo", 1, true), out)
    for _, tool in ipairs(SOURCE_BUILDS) do
        t.ok(
            out:find(
                tool .. " (dry-run):\n      luajit scripts/install-" .. tool .. ".lua",
                1,
                true
            ),
            out
        )
    end
    for _, tool in ipairs(SYSTEM_TOOLS) do
        t.ok(out:find(tool .. " installed outside dev tools", 1, true), out)
    end
    fs.remove(dir, { recursive = true })
end)

t.test("bats and stow are pinned source builds in the base group", function()
    local cells = base_cells()
    local pins = assert(release.read(PINS))
    for _, tool in ipairs(SOURCE_BUILDS) do
        t.eq(cells[tool], "script:scripts/install-" .. tool .. ".lua,bin:-")
        t.ok(pins[tool], tool .. " has no pin")
        t.ok(fs.is_file(REPO .. "/scripts/install-" .. tool .. ".lua"), tool .. " has no script")
    end
end)
