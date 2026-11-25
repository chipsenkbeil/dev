local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local testenv = require("@dev/testenv")
local testing = require("@dev/testing")
local support = require("./support")

local IDENT = support.GIT_IDENT
local JJ_IDENT = { JJ_CONFIG = "/dev/null", JJ_USER = "t", JJ_EMAIL = "t@t" }
local RUN = 777
local FAILED_JOB = 4242

local function script(root, name, body)
    local path = root .. "/bin/" .. name
    assert(fs.write(path, "#!/bin/sh\n" .. body .. "\n"))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function view_json(status, conclusion, jobs)
    local rows = {}
    for _, job in ipairs(jobs) do
        rows[#rows + 1] = string.format(
            '{"name":"%s","status":"completed","conclusion":"%s","databaseId":%d}',
            job[1],
            job[2],
            job[3]
        )
    end
    return string.format(
        '{"status":"%s","conclusion":"%s","url":"https://example.test/runs/%d","jobs":[%s]}',
        status,
        conclusion,
        RUN,
        table.concat(rows, ",")
    )
end

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")

local function fake_gh(root, view)
    assert(fs.write(root .. "/view.json", view))
    local log = table.concat({
        "build-windows\tTest\terror: one",
        "build-windows\tTest\terror: two",
        "",
    }, "\n")
    assert(fs.write(root .. "/failed.log", log))
    script(
        root,
        "gh",
        table.concat({
            'echo "$*" >> ' .. root .. "/bin/gh.log",
            'case "$1 $2" in',
            '    "run list")',
            "        if [ -f " .. root .. "/dispatched ]; then",
            '            echo "[{\\"databaseId\\":' .. RUN .. ',\\"headSha\\":\\"$GH_SHA\\"}]"',
            "        else",
            "            echo '[]'",
            "        fi ;;",
            '    "workflow run") touch ' .. root .. "/dispatched ;;",
            '    "run view")',
            '        case "$*" in',
            "            *--log-failed*) cat " .. root .. "/failed.log ;;",
            "            *)",
            `                if [ -x {root}/bin/midrun ]; then {root}/bin/midrun; fi`,
            "                cat " .. root .. "/view.json ;;",
            "        esac ;;",
            "esac",
        }, "\n")
    )
end

local function project(view)
    local files = {}
    for _, name in ipairs({ "DESCRIPTION", "dispatch.luau" }) do
        local path = ".dev/commands/release/" .. name
        files[path] = assert(fs.read(REPO .. "/" .. path))
    end
    files[".gitignore"] = "bin/\n*.json\n*.log\ndispatched\n"
    local root = support.sandbox(files, {})
    local bare = support.tempdir()
    support.git(bare, "init", "-q", "--bare")
    support.git(root, "init", "-q", "-b", "master")
    support.git(root, "remote", "add", "origin", bare)
    assert(fs.write(root .. "/a.txt", "one\n"))
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "feat: one")
    fake_gh(root, view)
    return root, bare, support.rev(root, "HEAD")
end

local MIXED = view_json("completed", "success", {
    { "build", "success", 1 },
    { "build-windows", "failure", FAILED_JOB },
    { "publish", "skipped", 3 },
})

local function dispatch(root, sha, words, env)
    local argv = { "release", "dispatch", "--interval", "0", "--keep" }
    for _, word in ipairs(words or {}) do
        argv[#argv + 1] = word
    end
    local set = { GH_SHA = sha }
    for name, value in pairs(env or IDENT) do
        set[name] = value
    end
    return support.dev(root, argv, { env = set })
end

testing.test(
    "dispatch pushes the branch, starts the run and prints each job and its log",
    function()
        local root, bare, sha = project(MIXED)
        local out, code = dispatch(root, sha)
        testing.eq(code, 1, out)
        testing.eq(support.rev(bare, "refs/heads/review-master"), sha)
        testing.eq(testenv.calls(root, "gh"), {
            "run list --repo chipsenkbeil/dev --workflow release.yml --branch review-master --event workflow_dispatch --limit 30 --json databaseId,headSha",
            "workflow run release.yml --repo chipsenkbeil/dev --ref review-master",
            "run list --repo chipsenkbeil/dev --workflow release.yml --branch review-master --event workflow_dispatch --limit 30 --json databaseId,headSha",
            "run view " .. RUN .. " --repo chipsenkbeil/dev --json status,conclusion,url,jobs",
            "run view --repo chipsenkbeil/dev --job " .. FAILED_JOB .. " --log-failed",
        })
        testing.ok(out:find("Started run " .. RUN, 1, true), out)
        testing.ok(out:find("job build: success", 1, true), out)
        testing.ok(out:find("job build-windows: failure", 1, true), out)
        testing.ok(out:find("job publish: skipped", 1, true), out)
        testing.ok(out:find("    build-windows\tTest\terror: one", 1, true), out)
        testing.ok(out:find("    build-windows\tTest\terror: two", 1, true), out)
    end
)

testing.test("dispatch prints the last lines flag of a failed log", function()
    local root, _, sha = project(MIXED)
    local out, code = dispatch(root, sha, { "--lines", "1" })
    testing.eq(code, 1, out)
    testing.ok(not out:find("error: one", 1, true), out)
    testing.ok(out:find("error: two", 1, true), out)
end)

testing.test("dispatch exits 0 and reads no log when every job passes", function()
    local root, _, sha = project(view_json("completed", "success", {
        { "build", "success", 1 },
        { "publish", "skipped", 3 },
    }))
    local out, code = dispatch(root, sha)
    testing.eq(code, 0, out)
    for _, call in ipairs(testenv.calls(root, "gh")) do
        testing.ok(not call:find("--log-failed", 1, true), call)
    end
end)

testing.test("dispatch gives up with exit 1 when the run outlasts the timeout", function()
    local root, _, sha = project(view_json("in_progress", "", {}))
    local out, code = dispatch(root, sha, { "--timeout", "0" })
    testing.eq(code, 1, out)
    testing.ok(out:find("still in_progress after 0s", 1, true), out)
end)

testing.test(
    "dispatch deletes the pushed branch once the run ends unless told to keep it",
    function()
        local root, bare, sha = project(MIXED)
        local env = { GH_SHA = sha }
        local out, code = support.dev(
            root,
            { "release", "dispatch", "--interval", "0" },
            { env = env }
        )
        testing.eq(code, 1, out)
        testing.eq(dev_os.capture({ "git", "-C", bare, "branch", "--list" }), "")
    end
)

testing.test("dispatch maps a slash in the git branch name to a dash", function()
    local root, bare, sha = project(MIXED)
    support.git(root, "checkout", "-q", "-b", "feature/x")
    local _, code = dispatch(root, sha)
    testing.eq(code, 1)
    testing.eq(support.rev(bare, "refs/heads/review-feature-x"), sha)
end)

testing.test("dispatch refuses when gh is missing and pushes nothing", function()
    local root, bare = project(MIXED)
    local out, code = support.dev(
        root,
        { "release", "dispatch" },
        { env = { FAKE_DEV = "1", FAKE_HIDE = "gh" } }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("The gh client is not on PATH.", 1, true), out)
    testing.eq(dev_os.capture({ "git", "-C", bare, "branch", "--list" }), "")
end)

if dev_os.which("jj") then
    local function jj_project(empty_head)
        local root, bare = project(MIXED)
        assert(fs.remove(root .. "/.git", { recursive = true }))
        local made = dev_os.capture(
            { "jj", "git", "init", root },
            { stderr = "stdout", env = JJ_IDENT }
        )
        assert(fs.exists(root .. "/.jj"), made)
        local function jj(...)
            local out, code = dev_os.capture(
                { "jj", "--no-pager", "-R", root, ... },
                { stderr = "stdout", env = JJ_IDENT }
            )
            assert(code == 0, out)
            return (out:gsub("\n$", ""))
        end
        jj("git", "remote", "add", "origin", bare)
        assert(fs.write(root .. "/b.txt", "two\n"))
        jj("describe", "-m", "feat: two")
        if empty_head then
            jj("new")
        end
        local target = if empty_head then "@-" else "@"
        local change = jj("log", "--no-graph", "-r", target, "-T", "change_id.short(12)")
        local commit = jj("log", "--no-graph", "-r", target, "-T", "commit_id")
        return root, bare, change, commit
    end

    testing.test("dispatch names the branch from the jj change id of the current change", function()
        local root, bare, change, commit = jj_project(false)
        local out, code = dispatch(root, commit, {}, JJ_IDENT)
        testing.eq(code, 1, out)
        testing.eq(support.rev(bare, "refs/heads/review-" .. change), commit)
    end)

    testing.test(
        "dispatch leaves the jj working copy on its commit when another workspace fetches mid-run",
        function()
            local root, bare, change, commit = jj_project(false)
            local other = support.tempdir() .. "/other"
            local function jj(dir, ...)
                local out, code = dev_os.capture(
                    { "jj", "--no-pager", "-R", dir, ... },
                    { stderr = "stdout", env = JJ_IDENT }
                )
                assert(code == 0, out)
                return (out:gsub("\n$", ""))
            end
            jj(root, "workspace", "add", other)
            script(root, "midrun", `jj --no-pager -R {other} git fetch >/dev/null 2>&1`)
            local env = { GH_SHA = commit }
            for name, value in pairs(JJ_IDENT) do
                env[name] = value
            end
            local out, code = support.dev(
                root,
                { "release", "dispatch", "--interval", "0" },
                { env = env }
            )
            testing.eq(code, 1, out)
            testing.eq(dev_os.capture({ "git", "-C", bare, "branch", "--list" }), "", out)
            jj(other, "git", "fetch")
            local seen = jj(
                root,
                "log",
                "--no-graph",
                "-r",
                "@",
                "-T",
                'commit_id ++ " " ++ description.first_line()'
            )
            testing.eq(seen, commit .. " feat: two")
            local listed = jj(other, "bookmark", "list", "--all")
            testing.ok(not listed:find("review-" .. change, 1, true), listed)
        end
    )

    testing.test("dispatch sends the parent when the jj working copy is empty", function()
        local root, bare, change, commit = jj_project(true)
        local out, code = dispatch(root, commit, {}, JJ_IDENT)
        testing.eq(code, 1, out)
        testing.eq(support.rev(bare, "refs/heads/review-" .. change), commit)
    end)
end
