local dev_os = require("dev.os")
local fs = require("dev.fs")

---@alias dev.vcs.Backend "jj"|"git"

---@class dev.vcs.BaseOpts
---@field quiet boolean? add `--color never` for jj

---@class dev.vcs
---@field JJ "jj" the jj backend
---@field GIT "git" the git backend
---@field LABEL table<dev.vcs.Backend, string> the backend's name at the start of a message
local M = { JJ = "jj", GIT = "git", LABEL = { jj = "jj", git = "Git" } }

local function lines_of(text)
    local out = {}
    for line in text:gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

---Pick the backend a project uses.
---
---A project with `.jj` uses jj when jj is installed or `.git` is missing. Otherwise a project with
---`.git` uses git.
---@param root string absolute path of the project root
---@return dev.vcs.Backend? backend nil when the project has neither
---@return string? err why there is no backend
function M.backend(root)
    local git = fs.exists(root .. "/.git")
    if fs.is_dir(root .. "/.jj") and (dev_os.which("jj") or not git) then
        return M.JJ
    end
    if git then
        return M.GIT
    end
    return nil, "neither .jj nor .git found in " .. root
end

---Pick the backend and check its tool is installed.
---@param root string absolute path of the project root
---@return dev.vcs.Backend? backend nil on failure
---@return string? err why there is no usable backend
function M.require(root)
    local backend, err = M.backend(root)
    if backend == M.JJ and not dev_os.which("jj") then
        return nil, "jj not found, install with: brew install jj"
    end
    return backend, err
end

---Add words to the end of a command.
---@param base string[] the command so far
---@param ... string the words to add
---@return string[] argv a new command
function M.with(base, ...)
    local argv = { unpack(base) }
    for _, word in ipairs({ ... }) do
        argv[#argv + 1] = word
    end
    return argv
end

---The argv prefix that runs jj or git on a project.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@param opts dev.vcs.BaseOpts? how to run it
---@return string[] argv the command words before the subcommand
function M.base(root, backend, opts)
    if backend == M.JJ then
        if opts and opts.quiet then
            return { "jj", "--no-pager", "--color", "never", "-R", root }
        end
        return { "jj", "--no-pager", "-R", root }
    end
    return { "git", "-C", root }
end

---List the project's remotes by name.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@return string[] names the remotes, empty when the listing fails
function M.remotes(root, backend)
    local base = M.base(root, backend, { quiet = true })
    local argv = backend == M.JJ and M.with(base, "git", "remote", "list") or M.with(base, "remote")
    local out, code = dev_os.capture(argv)
    if code ~= 0 then
        return {}
    end
    local names = {}
    for _, line in ipairs(lines_of(out)) do
        names[#names + 1] = line:match("^%S+")
    end
    return names
end

---List the project's branches or bookmarks by name.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@return string[] names the branches, empty when the listing fails
function M.branches(root, backend)
    local base = M.base(root, backend, { quiet = true })
    local argv
    if backend == M.JJ then
        argv = M.with(base, "bookmark", "list", "-T", 'name ++ "\\n"')
    else
        argv = M.with(base, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    end
    local out, code = dev_os.capture(argv)
    if code ~= 0 then
        return {}
    end
    return lines_of(out)
end

---Delete the branch or bookmark `name`, when the project lists it.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@param name string the branch or bookmark
---@return boolean? deleted true when deleted, false when no branch has the name, nil when the
---   delete failed
---@return string? why what the tool printed when the delete failed
function M.delete_branch(root, backend, name)
    local listed = false
    for _, branch in ipairs(M.branches(root, backend)) do
        listed = listed or branch == name
    end
    if not listed then
        return false
    end
    local base = M.base(root, backend, { quiet = true })
    local argv
    if backend == M.JJ then
        argv = M.with(base, "bookmark", "delete", name)
    else
        argv = M.with(base, "branch", "-D", name)
    end
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        return nil, (out:gsub("\n$", ""))
    end
    return true
end

---List the project's tracked files.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@return string? names the paths, each ended by NUL, nil on failure
---@return string? err why the listing failed
function M.files(root, backend)
    local argv = { "git", "ls-files", "-z" }
    if backend == M.JJ then
        argv = { "jj", "file", "list", "-T", [[path.display() ++ "\0"]] }
    end
    local out, code = dev_os.capture(argv, { cwd = root })
    if code ~= 0 then
        return nil, "Cannot list the tracked files with " .. backend .. "."
    end
    return out
end

---Pick `master` or `main`, whichever the list holds.
---@param names string[] branch names
---@return string? name the trunk's name
function M.trunk(names)
    for _, want in ipairs({ "master", "main" }) do
        for _, name in ipairs(names) do
            if name == want then
                return want
            end
        end
    end
    return nil
end

---Name the trunk branch of a git remote, as `remote/branch`.
---@param root string absolute path of the project root
---@param remote string the remote of record
---@return string? ref the remote-tracking ref of its master or main branch
---@return string? err why the remote has none
function M.remote_trunk(root, remote)
    local prefix = remote .. "/"
    local argv = M.with(
        M.base(root, M.GIT, { quiet = true }),
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/remotes/" .. remote
    )
    local out, code = dev_os.capture(argv, { stderr = "null" })
    local names = {}
    for line in (code == 0 and out or ""):gmatch("[^\n]+") do
        if line:sub(1, #prefix) == prefix then
            names[#names + 1] = line:sub(#prefix + 1)
        end
    end
    local trunk = M.trunk(names)
    if trunk == nil then
        return nil, string.format("%s has no master or main branch", remote)
    end
    return prefix .. trunk
end

---Read a git config value from the repository's own store.
---
---For a jj project that is the git store under `.jj`.
---@param root string absolute path of the project root
---@param backend dev.vcs.Backend the project's backend
---@param key string the config key
---@return string value the value, empty when unset
function M.config(root, backend, key)
    local argv
    if backend == M.JJ then
        local dir = dev_os.capture(M.with(M.base(root, backend), "git", "root"))
        argv = { "git", "--git-dir=" .. dir:gsub("\n$", ""), "config", "--get", key }
    else
        argv = { "git", "-C", root, "config", "--get", key }
    end
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return ""
    end
    return (out:gsub("\n$", ""))
end

return M
