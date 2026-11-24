local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local land = require("@dev/board/land")
local support = require("./support")
local wiring = require("@dev/board/wiring")

local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)
local GERRIT = "ssh://c@g:29418/dotfiles"
local STUB = [[#!/bin/sh
dir=$(dirname "$0")
echo "$*" >>"$dir/calls"
case "$*" in
*"ps -a"*) cat "$dir/all.json" ;;
*) cat "$dir/run.json" ;;
esac
]]
local FAILED_JOBS = '{"run":"r1","status":"failed","jobs":['
    .. '{"job":"lint:linux-x86-dev:1","state":"passed"},'
    .. '{"job":"test:windows:1","state":"failed"},'
    .. '{"job":"test:linux-x86-rust:1","state":"failed"}]}'
local ORIGINAL_PATH = dev_os.getenv("PATH")

local function run(id, source, status, created)
    return string.format(
        '{"run":"%s","repo":"dotfiles","source":"%s","status":"%s","created_at":%d}',
        id,
        source,
        status,
        created
    )
end

local function listing(...)
    return '{"protocol":99,"runs":[' .. table.concat({ ... }, ",") .. "]}"
end

local function must(code, what)
    assert(code == 0, what .. " failed")
end

local function project(remote_url, all)
    local root = assert(fs.realpath(support.tempdir()))
    must(dev_os.run({ "git", "-C", root, "init", "-q" }, { stdout = "null" }), "git init")
    local name = remote_url:find("^ssh:") and "gerrit" or "origin"
    must(
        dev_os.run({ "git", "-C", root, "remote", "add", name, remote_url }, { stdout = "null" }),
        "git remote add"
    )
    local bin = assert(fs.realpath(support.tempdir()))
    assert(fs.write(bin .. "/ci", STUB))
    must(dev_os.run({ "chmod", "755", bin .. "/ci" }), "chmod")
    assert(fs.write(bin .. "/all.json", all))
    assert(fs.write(bin .. "/run.json", FAILED_JOBS))
    dev_os.defaults.env = {
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_NOSYSTEM = "1",
        PATH = bin .. ":" .. ORIGINAL_PATH,
    }
    return root, bin
end

local function calls(bin)
    return fs.read(bin .. "/calls") or ""
end

testing.test(
    "change_run_problem refuses a failed run and names the run and its failed jobs",
    function()
        local root, bin =
            project(GERRIT, listing(run("r1", "pushed@" .. COMMIT:sub(1, 12), "failed", 5)))
        local problem, seen = land.change_run_problem(root, COMMIT)
        testing.ok(problem:find("change run r1", 1, true), problem)
        testing.ok(problem:find("test:windows:1, test:linux-x86-rust:1", 1, true), problem)
        testing.ok(problem:find("--ignore-change-run REASON", 1, true), problem)
        testing.eq(seen, nil)
        testing.ok(calls(bin):find("ps -a --repo dotfiles -n 1000 --json", 1, true), calls(bin))
    end
)

testing.test(
    "change_run_problem judges the newest run of the commit and no other commit's run",
    function()
        local mine = COMMIT:sub(1, 12)
        local root = project(
            GERRIT,
            listing(
                run("old", "pushed@" .. mine, "failed", 1),
                run("new", "pushed@" .. mine, "passed", 9),
                run("other", "pushed@" .. OTHER:sub(1, 12), "failed", 20)
            )
        )
        local problem, seen = land.change_run_problem(root, COMMIT)
        testing.eq(problem, nil)
        testing.ok(seen:find("change run new", 1, true), seen)
        testing.ok(seen:find("is passed", 1, true), seen)
    end
)

testing.test("a run still going lands without the opt-in, and a line says it was seen", function()
    local root = project(GERRIT, listing(run("r2", "pushed@" .. COMMIT:sub(1, 12), "running", 5)))
    local problem, seen = land.change_run_problem(root, COMMIT)
    testing.eq(problem, nil)
    testing.ok(seen:find("change run r2", 1, true), seen)
    testing.ok(seen:find("is running", 1, true), seen)
end)

testing.test("with the opt-in a run still going refuses and names the run", function()
    local root = project(GERRIT, listing(run("r2", "pushed@" .. COMMIT:sub(1, 12), "running", 5)))
    local problem, seen = land.change_run_problem(root, COMMIT, { require_run = true })
    testing.ok(problem:find("change run r2", 1, true), problem)
    testing.ok(problem:find("still going", 1, true), problem)
    testing.ok(problem:find("--ignore-change-run REASON", 1, true), problem)
    testing.eq(seen, nil)
end)

testing.test("an absent run lands, and a line says none was found", function()
    local root = project(GERRIT, listing(run("r3", "pushed@" .. OTHER:sub(1, 12), "failed", 5)))
    local problem, seen, found = land.change_run_problem(root, COMMIT)
    testing.eq(problem, nil)
    testing.eq(found, false)
    testing.ok(seen:find("No change run of commit " .. COMMIT:sub(1, 12), 1, true), seen)
end)

testing.test("a rebased commit with no change run refuses", function()
    local root = project(GERRIT, listing(run("r3", "pushed@" .. OTHER:sub(1, 12), "failed", 5)))
    local problem = land.rebased_run_problem(root, COMMIT)
    testing.ok(problem:find("rebased commit " .. COMMIT:sub(1, 12), 1, true), problem)
    testing.ok(problem:find("`jj submit`", 1, true), problem)
    testing.ok(problem:find("--ignore-change-run REASON", 1, true), problem)
end)

testing.test("a rebased commit with a passed run lands", function()
    local root = project(GERRIT, listing(run("r8", "pushed@" .. COMMIT:sub(1, 12), "passed", 5)))
    local problem, seen = land.rebased_run_problem(root, COMMIT)
    testing.eq(problem, nil)
    testing.ok(seen:find("change run r8", 1, true), seen)
end)

testing.test("a failed ci listing lands, and a line says nothing was looked up", function()
    local root = project(GERRIT, "not json")
    local problem, seen = land.change_run_problem(root, COMMIT)
    testing.eq(problem, nil)
    testing.ok(seen:find("No change run was looked up", 1, true), seen)
end)

testing.test("a repo that is not on gerrit never asks ci", function()
    local root, bin = project(
        "git@github.com:o/r.git",
        listing(run("r4", "pushed@" .. COMMIT:sub(1, 12), "failed", 5))
    )
    testing.eq({ land.change_run_problem(root, COMMIT) }, {})
    testing.eq(calls(bin), "")
end)

local function land_backend(root)
    local backend = { root = root, notes = {} }
    backend.stages = {
        verify = support.COLUMN_NAME.VERIFY,
        release = support.COLUMN_NAME.RELEASE,
        done_column = function()
            return support.COLUMN_NAME.DONE
        end,
    }
    return backend
end

local function committed(root)
    assert(fs.write(root .. "/file.txt", "x\n"))
    local function run_git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null" }), "git")
    end
    run_git("add", "file.txt")
    run_git("commit", "-q", "-m", "feat: x")
    return (dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("%s+$", ""))
end

local function land_lines(root, who)
    local card = {
        id = "81f0e017-0000-4000-8000-000000000000",
        column = support.COLUMN_NAME.VERIFY,
        labels = {},
        outcomes = {},
        checks = {},
    }
    who.name = "dotfiles/lander"
    who.comments = {}
    local problems = wiring.land_problems(land_backend(root), card, who)
    return table.concat(problems, "\n")
end

local function listed_at(root, bin, id, status)
    local head = committed(root)
    assert(fs.write(bin .. "/all.json", listing(run(id, "pushed@" .. head:sub(1, 12), status, 5))))
end

testing.test("land_problems refuses the failed run of the commit to land", function()
    local root, bin = project(GERRIT, listing())
    listed_at(root, bin, "r5", "failed")
    local text = land_lines(root, {})
    testing.ok(text:find("The change run r5 of commit", 1, true), text)
    testing.eq(land_lines(root, { change_run_read = true }):find("change run", 1, true), nil)
end)

testing.test("land_problems lands past a run that is going without the opt-in", function()
    local root, bin = project(GERRIT, listing())
    listed_at(root, bin, "r6", "running")
    testing.eq(land_lines(root, {}):find("The change run r6", 1, true), nil)
end)

testing.test("with the opt-in land_problems refuses a run that is going", function()
    local root, bin = project(GERRIT, listing())
    must(dev_os.run({ "mkdir", root .. "/.dev" }), "mkdir")
    assert(fs.write(root .. "/.git/info/exclude", ".dev/\n"))
    assert(fs.write(root .. "/.dev/config.toml", "[board.land]\nrequire_change_run = true\n"))
    listed_at(root, bin, "r6", "running")
    local text = land_lines(root, {})
    testing.ok(text:find("The change run r6 of commit", 1, true), text)
    testing.ok(text:find("still going", 1, true), text)
end)

testing.test("without the opt-in a commit with no change run lands", function()
    local root, bin = project(GERRIT, listing())
    committed(root)
    testing.eq(land_lines(root, {}):find("change run", 1, true), nil)
    testing.ok(calls(bin):find("ps -a", 1, true), calls(bin))
end)

testing.test("ignore-change-run skips the lookup and the reason reaches the done note", function()
    local root, bin = project(GERRIT, listing())
    listed_at(root, bin, "r7", "failed")
    local text = land_lines(root, { ignore_change_run = "ci is down" })
    testing.eq(text:find("change run", 1, true), nil)
    testing.eq(calls(bin), "")
    local note = land.ignored_run_note("Landed commit abc.", "windows runner is down.")
    testing.eq(note, "Landed commit abc. The change run check was skipped: windows runner is down.")
    testing.eq(land.ignored_run_note("Landed commit abc.", nil), "Landed commit abc.")
end)
