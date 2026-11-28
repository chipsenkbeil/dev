local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")
local text = require("@dev/text")
local vcs = require("@dev/vcs")

local FIRST_TAG = "v0.1.0"

local function release_tags(root, backend)
    local base = vcs.base(root, backend, { quiet = true })
    local argv = if backend == vcs.JJ
        then vcs.with(base, "tag", "list", "-T", 'name ++ "\\n"')
        else vcs.with(base, "tag", "--list", "v*")
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        dev_command.die(`The tags of {root} cannot be read: {text.trim(out)}`)
    end
    local found = {}
    for line in out:gmatch("[^\n]+") do
        local major, minor, patch = line:match("^v(%d+)%.(%d+)%.(%d+)$")
        if major then
            found[#found + 1] = { tonumber(major), tonumber(minor), tonumber(patch) }
        end
    end
    return found
end

local function newest(found)
    local best
    for _, one in ipairs(found) do
        if
            not best
            or one[1] > best[1]
            or (
                one[1] == best[1] and (one[2] > best[2] or (one[2] == best[2] and one[3] > best[3]))
            )
        then
            best = one
        end
    end
    return best
end

local function step(ctx, argv, failure, undo)
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
    if code ~= 0 then
        if undo then
            dev_command.show(ctx, undo)
            dev_os.capture(undo, { cwd = ctx.root, stderr = "stdout" })
        end
        dev_command.die(`{failure}: {text.trim(out)}`)
    end
    return out
end

local function execute(_, args, ctx)
    local backend, err = vcs.require(ctx.root)
    if not backend then
        dev_command.die(err)
    end
    local rev = args.rev or (if backend == vcs.JJ then "trunk()" else "HEAD")
    local best = newest(release_tags(ctx.root, backend))
    if not best then
        local by_hand = if backend == vcs.JJ
            then `jj tag set {FIRST_TAG} -r REV`
            else `git tag {FIRST_TAG} REV`
        dev_command.die(
            `No release tag vMAJOR.MINOR.PATCH exists. Set the first one by hand, {by_hand}, `
                .. `and push it with dev push --tag {FIRST_TAG}.`
        )
    end
    local tag = `v{best[1]}.{best[2]}.{best[3] + 1}`

    local base = vcs.base(ctx.root, backend, { quiet = true })
    local set = if backend == vcs.JJ
        then vcs.with(base, "tag", "set", tag, "-r", rev)
        else vcs.with(base, "tag", tag, rev)
    step(ctx, set, `The tag {tag} could not be set on {rev}`)
    local unset = if backend == vcs.JJ
        then vcs.with(base, "tag", "delete", tag)
        else vcs.with(base, "tag", "-d", tag)
    step(
        ctx,
        { runtime.exe, "-C", ctx.root, "push", "--tag", tag },
        `The push of {tag} failed and the local tag was removed`,
        unset
    )
    dev_command.say(tag)
    return 0
end

return dev_command({
    summary = "Tag REV with the next patch version and push the tag",
    group = "Release",
    remote = false,
    long = table.concat({
        "Reads the newest `vMAJOR.MINOR.PATCH` tag, sets the next patch version on REV ",
        "and pushes it with `dev push --tag`. A pre-release tag such as ",
        "`v0.1.12-pre.1` is skipped.",
        "",
        "- REV defaults to `trunk()` with jj and `HEAD` with git.",
        "- A minor or major bump is a tag set by hand, and the next run counts from it.",
        "- It prints the new tag. With no release tag it exits 1 and names the first ",
        "tag to set by hand.",
        "- `dev board ship` runs it as the last `[board.release]` checks row, so a ",
        "green ship cuts the tag and a red ship tags nothing.",
        "",
        "```",
        "dev release tag",
        "```",
    }, "\n"),
    args = { { name = "rev", help = "The revision to tag" } },
    run = execute,
})
