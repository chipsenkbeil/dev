local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local vcs = require("@dev/vcs")

---A workspace that sits on the change of another workspace, and what keeps it current.
---@class dev.stack
local M = {}

local MARKER = "dev-on"
local SHA_PREFIX_LEN = 12

local function sentence(text)
    text = text:gsub("^%l", string.upper)
    if not text:find("%.$") then
        text ..= "."
    end
    return text
end

local function first_line(text)
    for line in text:gmatch("[^\n]+") do
        if line:find("%S") then
            return line
        end
    end
    return nil
end

---Find the file that marks a workspace as stacked on another one.
---@param path string the workspace folder
---@return string? file the marker file, nil when the folder has no place for one
local function marker_file(path)
    if fs.is_dir(path .. "/.jj") then
        return path .. "/.jj/" .. MARKER
    end
    if fs.is_dir(path .. "/.git") then
        return nil
    end
    local pointer = fs.read(path .. "/.git")
    local dir = pointer and pointer:match("^gitdir: ([^\n]+)")
    if not dir then
        return nil
    end
    if dir:sub(1, 1) ~= "/" and not dir:find("^%a:") then
        dir = fs.join(path, dir)
    end
    return dir .. "/" .. MARKER
end

---@class dev.stack.Marker
---@field on string the name of the workspace this one sits on
---@field tip string? the commit of that workspace's branch this one was last rebased onto, git only

---Read the marker of a workspace.
---@param path string the workspace folder
---@return dev.stack.Marker? marker nil when the workspace is not stacked
function M.read(path)
    local file = marker_file(path)
    local text = file and fs.exists(file) and fs.read(file)
    local on = text and text:match("on=([^\n]+)")
    if not on then
        return nil
    end
    return { on = on, tip = text:match("tip=(%x+)") }
end

---Mark a workspace as stacked on another one.
---@param path string the workspace folder
---@param marker dev.stack.Marker what it sits on
function M.write(path, marker)
    local file = marker_file(path)
    if file == nil then
        return
    end
    local text = "on=" .. marker.on .. "\n"
    if marker.tip then
        text ..= "tip=" .. marker.tip .. "\n"
    end
    assert(fs.write(file, text))
end

---Read the commit a git branch points at.
---@param root string a folder of the repository
---@param branch string the branch name
---@return string? sha nil when the branch does not exist
function M.tip(root, branch)
    local out, code = dev_os.capture(
        vcs.with(
            vcs.base(root, vcs.GIT),
            "rev-parse",
            "--verify",
            "--quiet",
            "refs/heads/" .. branch
        ),
        { stderr = "null" }
    )
    if code ~= 0 then
        return nil
    end
    return (out:gsub("%s+$", ""))
end

local function refresh_jj(root, marker)
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code =
        dev_os.capture(vcs.with(base, "workspace", "update-stale"), { stderr = "stdout" })
    if code ~= 0 then
        return nil,
            sentence(
                "jj could not bring the workspace up to date after "
                    .. marker.on
                    .. " changed: "
                    .. (first_line(out) or "it printed nothing")
            )
    end
    local shape = dev_os.capture(
        vcs.with(base, "log", "-r", "@", "--no-graph", "-T", 'if(conflict, "conflict", "clean")'),
        { stderr = "null" }
    )
    if shape == "conflict" then
        return nil,
            sentence(
                "This workspace holds conflicts after "
                    .. marker.on
                    .. " was rewritten. Resolve them with `jj resolve`. The check and the land "
                    .. "are refused until then"
            )
    end
    return nil
end

local function trunk_tip(root)
    local found = require("@dev/forge").resolve(root)
    local ref = found and vcs.remote_trunk(root, found.remote)
    if not ref then
        return nil
    end
    local out, code = dev_os.capture(
        vcs.with(vcs.base(root, vcs.GIT), "rev-parse", "--verify", "--quiet", ref .. "^{commit}"),
        { stderr = "null" }
    )
    if code ~= 0 then
        return nil
    end
    return (out:gsub("%s+$", ""))
end

local function follow_git(root, marker, now)
    local base = vcs.base(root, vcs.GIT)
    local branch = dev_os.capture(vcs.with(base, "symbolic-ref", "--short", "HEAD"), {
        stderr = "null",
    })
    branch = branch:gsub("%s+$", "")
    local busy = branch == ""
    for _, name in ipairs({ "rebase-merge", "rebase-apply" }) do
        local dir = dev_os.capture(
            vcs.with(base, "rev-parse", "--path-format=absolute", "--git-path", name),
            { stderr = "null" }
        )
        busy = busy or fs.exists((dir:gsub("%s+$", "")))
    end
    if busy then
        return sentence(
            "the branch "
                .. marker.on
                .. " moved, but this worktree is detached or in the middle of a rebase, so it "
                .. "cannot follow. Finish or abort that, then run the command again"
        )
    end
    local dirty = dev_os.capture(
        vcs.with(base, "status", "--porcelain", "--untracked-files=no"),
        { stderr = "null" }
    )
    if dirty:find("%S") then
        return sentence(
            "the branch "
                .. marker.on
                .. " moved, and the branch "
                .. branch
                .. " must follow it, but this worktree holds uncommitted changes. Commit or "
                .. "stash them, then run the command again"
        )
    end
    local out, code = dev_os.capture(
        vcs.with(base, "rebase", "--onto", now, marker.tip, branch),
        { stderr = "stdout" }
    )
    if code == 0 then
        return nil
    end
    local listed = dev_os.capture(
        vcs.with(base, "diff", "--name-only", "--diff-filter=U"),
        { stderr = "null" }
    )
    dev_os.capture(vcs.with(base, "rebase", "--abort"), { stderr = "null" })
    local files = {}
    for line in listed:gmatch("[^\n]+") do
        files[#files + 1] = line
    end
    if #files == 0 then
        return sentence(
            "the branch "
                .. branch
                .. " could not follow "
                .. marker.on
                .. " and stays as it was: "
                .. (first_line(out) or "git printed nothing")
        )
    end
    return sentence(
        "the branch "
            .. marker.on
            .. " moved, and rebasing the branch "
            .. branch
            .. " onto it conflicts in "
            .. table.concat(files, ", ")
            .. ". The branch stays as it was. Rebase it by hand with `git rebase --onto "
            .. now:sub(1, SHA_PREFIX_LEN)
            .. " "
            .. marker.tip:sub(1, SHA_PREFIX_LEN)
            .. " "
            .. branch
            .. "` and resolve the conflicts"
    )
end

---Bring a workspace that sits on another workspace's change up to date before a command runs.
---
---A jj workspace is refreshed with `jj workspace update-stale`, since jj itself rebased its
---change when the other one was rewritten, and a notice says when its change holds conflicts. A
---git worktree is rebased onto the other branch's new tip, and a conflict aborts the rebase and
---refuses the command. A folder that is not stacked is left alone.
---@param root string the folder the command runs in
---@return string? refusal the sentence that refuses the command, nil when it may run
---@return string? notice a sentence to print, with or without a refusal
function M.refresh(root)
    local marker = M.read(root)
    if not marker then
        return nil
    end
    local backend = vcs.backend(root)
    if backend == vcs.JJ then
        return refresh_jj(root, marker)
    end
    if backend ~= vcs.GIT or not marker.tip then
        return nil
    end
    local now = M.tip(root, marker.on)
    local gone = now == nil
    if gone then
        now = trunk_tip(root)
        if now == nil then
            return nil
        end
    end
    if now == marker.tip then
        return nil
    end
    local base = vcs.base(root, vcs.GIT)
    local _, inside = dev_os.capture(
        vcs.with(base, "merge-base", "--is-ancestor", now, "HEAD"),
        { stderr = "null" }
    )
    local refusal
    if inside ~= 0 then
        refusal = follow_git(root, marker, now)
    end
    if refusal then
        return refusal
    end
    if gone then
        fs.remove(assert(marker_file(root)))
    else
        M.write(root, { on = marker.on, tip = now })
    end
    return nil
end

return M
