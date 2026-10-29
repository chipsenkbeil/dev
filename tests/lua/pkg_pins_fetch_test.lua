local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local manifest = require("dev.pkg.manifest")
local release = require("dev.pkg.release")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local PINS = REPO .. "/.dev/releases.tsv"
local SHA256_HEX_DIGITS = 64
local COLUMN = "darwin-x86_64"
local ARCH_WORDS = { "x86_64", "amd64", "universal" }
local PINNED_TOOLS = { "ripgrep", "fd", "jq", "yq", "sd", "gh", "jujutsu" }

local function release_cells()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    local column = assert(manifest.column(rows, COLUMN))
    local cells = {}
    for _, row in ipairs(rows) do
        local name = (row.fields[column] or ""):match("^release:([^,]+)")
        if name then
            cells[row.name] = name
        end
    end
    return cells
end

local function names_arch(url)
    for _, word in ipairs(ARCH_WORDS) do
        if url:find(word, 1, true) then
            return true
        end
    end
    return false
end

t.test("every release cell of the Intel macOS column has a pin", function()
    local pins = assert(release.read(PINS))
    for tool, name in pairs(release_cells()) do
        t.ok(pins[name], tool .. " names the pin " .. name .. ", which .dev/releases.tsv lacks")
    end
end)

t.test("the first base tools route through a release pin on Intel macOS", function()
    local cells = release_cells()
    for _, tool in ipairs(PINNED_TOOLS) do
        t.ok(cells[tool], tool .. " has no release: cell in " .. COLUMN)
    end
end)

t.test("every pin has a 64 digit sha256 and an https url naming the architecture", function()
    local pins = assert(release.read(PINS))
    for name, pin in pairs(pins) do
        t.ok(
            #pin.sha256 == SHA256_HEX_DIGITS and pin.sha256:find("^%x+$"),
            name .. " has a bad sha256"
        )
        t.ok(pin.url:find("^https://"), name .. " url is not https")
        t.ok(names_arch(pin.url), name .. " url names no x86_64, amd64 or universal asset")
    end
end)
