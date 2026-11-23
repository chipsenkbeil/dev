local dev_os = require("dev.os")
local fs = require("dev.fs")

---@class devrepo.checks
---@field lint_dir string directory of the Lua lint set's config files, relative to the project root
local M = {}

local LUA_ROOTS = {
    "lua",
    "main.lua",
    "pkg.lua",
    "tests/lua",
    ".dev",
}

local SHELL_ROOTS = {
    "bin",
    "board",
    "tests",
    ".dev",
}

local DOC_ROOTS = { "docs", ".dev/topics", "README.md" }

local CASE_ARM_ENDS = { [";;"] = true, [";&"] = true, [";;&"] = true }
local Kind = { NONE = "none", BLANK = "blank", COMMENT = "comment", CODE = "code", OPEN = "open" }

M.lint_dir = "."

local function lines_of(text)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local rest = text:match("([^\n]+)$")
    if rest then
        lines[#lines + 1] = rest
    end
    return lines
end

---Find the regular files under the roots that exist.
---@param root string absolute project root
---@param roots string[] paths relative to `root`
---@param args string[] extra `find` expressions that follow `-type f`
---@return string[] files relative paths in byte order
function M.find(root, roots, args)
    local argv = { "find" }
    for _, path in ipairs(roots) do
        if fs.exists(fs.join(root, path)) then
            argv[#argv + 1] = path
        end
    end
    if #argv == 1 then
        return {}
    end
    for _, word in ipairs({ "-type", "f" }) do
        argv[#argv + 1] = word
    end
    for _, arg in ipairs(args) do
        argv[#argv + 1] = arg
    end
    argv[#argv + 1] = "-print0"
    local out = dev_os.capture(argv, { cwd = root, stderr = "null" })
    local files = {}
    for path in out:gmatch("([^%z]+)") do
        files[#files + 1] = path
    end
    table.sort(files)
    return files
end

---Append every file to a command prefix.
---@param prefix string[] the command and its leading arguments
---@param files string[] the files to add
---@return string[] argv a new list
function M.with_files(prefix, files)
    local argv = { unpack(prefix) }
    for _, file in ipairs(files) do
        argv[#argv + 1] = file
    end
    return argv
end

---The Lua files the lint and format commands cover.
---@param root string absolute project root
---@return string[] files relative paths in byte order within each root
function M.lua_files(root)
    local files = {}
    for _, path in ipairs(LUA_ROOTS) do
        for _, file in ipairs(M.find(root, { path }, { "-name", "*.lua" })) do
            files[#files + 1] = file
        end
    end
    return files
end

---Read the first line of a file.
---@param root string absolute project root
---@param file string path relative to `root`
---@return string line the first line, empty for an empty or unreadable file
function M.first_line(root, file)
    local text = fs.read(fs.join(root, file)) or ""
    return text:match("^[^\n]*")
end

---The scripts the shell checks cover: a `.sh` name or a first line that names bash.
---@param root string absolute project root
---@return string[] files relative paths in byte order
function M.shell_files(root)
    local files = {}
    for _, file in
        ipairs(M.find(root, SHELL_ROOTS, { "!", "-name", "*.bats", "!", "-name", "*.md" }))
    do
        if file:find("%.sh$") or M.first_line(root, file):find("bash", 1, true) then
            files[#files + 1] = file
        end
    end
    return files
end

---The bats files under tests.
---@param root string absolute project root
---@return string[] files relative paths in byte order
function M.bats_files(root)
    return M.find(root, { "tests" }, { "-name", "*.bats" })
end

---The Markdown files of the dev docs, the topic files and the README.
---@param root string absolute project root
---@return string[] files relative paths in byte order
function M.doc_files(root)
    return M.find(root, DOC_ROOTS, { "-name", "*.md" })
end

---Find the prose lines wider than a limit.
---
---Fenced code, table rows and lines that hold a URL are skipped.
---@param text string contents of a Markdown file
---@param limit integer the widest a prose line may be, in columns
---@return integer[] numbers line numbers of the findings
function M.long_lines(text, limit)
    local found = {}
    local fenced = false
    for number, line in ipairs(lines_of(text)) do
        if line:match("^%s*```") then
            fenced = not fenced
        elseif not fenced and not line:match("^%s*|") and not line:find("://", 1, true) then
            local _, continuations = line:gsub("[\128-\191]", "")
            if #line - continuations > limit then
                found[#found + 1] = number
            end
        end
    end
    return found
end

---Find the full-line comments that directly follow a line of code.
---@param text string contents of a shell script
---@return integer[] numbers line numbers of the findings
function M.comment_spacing(text)
    local found = {}
    local kind, prev_indent, prev_text = Kind.NONE, "", ""
    for number, line in ipairs(lines_of(text)) do
        local body = line:gsub("^%s+", "")
        local indent = line:sub(1, #line - #body)
        if body == "" then
            kind = Kind.BLANK
        elseif body:sub(1, 2) == "#!" then
            kind = Kind.COMMENT
        elseif body:sub(1, 1) == "#" then
            if kind == Kind.CODE and #indent <= #prev_indent then
                if not CASE_ARM_ENDS[prev_text] or indent == prev_indent then
                    found[#found + 1] = number
                end
            end
            kind = Kind.COMMENT
        else
            kind = body:sub(-1) == "{" and Kind.OPEN or Kind.CODE
            prev_indent, prev_text = indent, body
        end
    end
    return found
end

---Find the lines that are a whole `[[ ... ]]` test, which never fails a test under bash 3.2.
---@param text string contents of a bats file
---@return integer[] numbers line numbers of the findings
function M.bare_assertions(text)
    local found = {}
    for number, line in ipairs(lines_of(text)) do
        local body = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #body >= 4 and body:sub(1, 2) == "[[" and body:sub(-2) == "]]" then
            found[#found + 1] = number
        end
    end
    return found
end

return M
