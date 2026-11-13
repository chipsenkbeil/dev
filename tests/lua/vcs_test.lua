local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local vcs = require("dev.vcs")

local function project(...)
    local root = assert(fs.realpath(support.tempdir()))
    for _, name in ipairs({ ... }) do
        assert(fs.mkdir(root .. "/" .. name))
    end
    return root
end

local function with_jj(present, body)
    local which = dev_os.which
    dev_os.which = function(tool)
        if tool == "jj" then
            return present and "/bin/jj" or nil
        end
        return which(tool)
    end
    local ok, err = pcall(body)
    dev_os.which = which
    assert(ok, err)
end

testing.test("a colocated repo without jj uses git", function()
    local root = project(".jj", ".git")
    with_jj(false, function()
        testing.eq(vcs.backend(root), vcs.GIT)
        testing.eq(vcs.require(root), vcs.GIT)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a colocated repo with jj uses jj", function()
    local root = project(".jj", ".git")
    with_jj(true, function()
        testing.eq(vcs.backend(root), vcs.JJ)
        testing.eq(vcs.require(root), vcs.JJ)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a jj only repo without jj needs jj", function()
    local root = project(".jj")
    with_jj(false, function()
        local backend, err = vcs.require(root)
        testing.eq(backend, nil)
        testing.eq(err, "jj not found, install with: brew install jj")
    end)
    fs.remove(root, { recursive = true })
end)
