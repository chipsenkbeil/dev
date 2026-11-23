---@class dev.Header
---@field desc string first comment line, empty when there is none
---@field group string? heading named by the `group:` line
---@field hidden boolean whether a `hidden` line is present
---@field runs_local boolean whether a `local` line is present
---@field remote false? false when a `remote: false` line is present, else nil
---@field requires string[] the words of the `requires:` lines
---@field positional boolean whether a `positional` line is present
---@field fetch dev.header.Fetch? the job and file named by the `fetch` line
---@field patch dev.header.Fetch? the job and file named by the `patch` line
---@field flags string[] words of the `flags:` line, with `-h` and `--help` dropped
---@field long string[] the whole comment block, minus the marker lines
---@field warnings string[] one message per reserved flag the `flags:` line declared

---@class dev.header.Fetch
---@field job string the ci job whose run keeps the file
---@field file string the artifact file the job keeps, below its job directory

---@class dev.header
local M = {}

local RESERVED_FLAGS = { ["-h"] = true, ["--help"] = true }
local KNOWN_REQUIRES = { workspace = true }

local function marker(line)
    return line:find("^# *group:")
        or line:find("^# *remote: *false *$")
        or line:find("^# *requires:")
        or line:find("^# *fetch +%S+ +%S+ *$")
        or line:find("^# *patch +%S+ +%S+ *$")
        or line:find("^# *hidden *$")
        or line:find("^# *local *$")
        or line:find("^# *positional *$")
end

local function skipped(line)
    return line:find("^# *shellcheck ") or marker(line)
end

local function ends_header(line, number)
    return number > 1 and line ~= "" and line:sub(1, 1) ~= "#"
end

local function first_comment(lines)
    for number = 2, #lines do
        local line = lines[number]
        if not (line:find("^%s*$") or skipped(line) or line:find("^# *flags:")) then
            if line:sub(1, 1) ~= "#" then
                return ""
            end
            return (line:gsub("^# ?", ""))
        end
    end
    return ""
end

local function comment_block(lines)
    local block = {}
    for number = 2, #lines do
        local line = lines[number]
        if not line:find("^# *shellcheck ") then
            if line:sub(1, 1) ~= "#" then
                break
            end
            if not marker(line) then
                block[#block + 1] = (line:gsub("^# ?", ""))
            end
        end
    end
    return block
end

local function flag_words(lines, name)
    local flags, warnings = {}, {}
    for number, line in ipairs(lines) do
        if line:find("^# *flags:") then
            local rest = line:gsub("^# *flags: *", ""):gsub(",", " ")
            for word in rest:gmatch("%S+") do
                if RESERVED_FLAGS[word] then
                    warnings[#warnings + 1] = string.format(
                        "The flags line of %s declares %s, which dev reserves before --.",
                        name,
                        word
                    )
                else
                    flags[#flags + 1] = word
                end
            end
            break
        end
        if ends_header(line, number) then
            break
        end
    end
    return flags, warnings
end

local function placement(lines)
    local group, hidden, runs_local, positional, fetch, patch = "", false, false, false, nil, nil
    for number, line in ipairs(lines) do
        local value = line:match("^# *group: *(.*)$")
        local job, file = line:match("^# *fetch +(%S+) +(%S+) *$")
        local patch_job, patch_file = line:match("^# *patch +(%S+) +(%S+) *$")
        if value and group == "" then
            group = value
        elseif job and not fetch then
            fetch = { job = job, file = file }
        elseif patch_job and not patch then
            patch = { job = patch_job, file = patch_file }
        elseif line:find("^# *hidden *$") then
            hidden = true
        elseif line:find("^# *local *$") then
            runs_local = true
        elseif line:find("^# *positional *$") then
            positional = true
        elseif ends_header(line, number) then
            break
        end
    end
    return group, hidden, runs_local, positional, fetch, patch
end

local function declarations(lines, name)
    local remote, requires, warnings = nil, {}, {}
    for number, line in ipairs(lines) do
        local rest = line:match("^# *requires:(.*)$")
        if line:find("^# *remote: *false *$") then
            remote = false
        elseif rest then
            for word in rest:gmatch("%S+") do
                if KNOWN_REQUIRES[word] then
                    requires[#requires + 1] = word
                else
                    warnings[#warnings + 1] = string.format(
                        "The requires line of %s names %s, which dev does not know.",
                        name,
                        word
                    )
                end
            end
        elseif ends_header(line, number) then
            break
        end
    end
    return remote, requires, warnings
end

local function split_lines(text)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function lua_block(text)
    local lines = split_lines((text:gsub("\r", "")) .. "\n")
    local converted = { "#!lua" }
    if lines[1] ~= "--[[" then
        return converted
    end
    for number = 2, #lines do
        if lines[number]:find("^%]%] *$") then
            break
        end
        converted[#converted + 1] = "# " .. lines[number]
    end
    return converted
end

---Parse the header of a verb script.
---
---A shell header is the comment block after the shebang. A Lua header is one
---leading `--[[ ... ]]` block holding the same lines. The first comment line
---is the description, and the `group:`, `hidden`, `local`, `remote: false`, `requires: WORD...`,
---`positional`, `fetch JOB FILE`, `patch JOB FILE` and `flags:` lines set the rest.
---@param text string contents of the script
---@param kind "sh"|"lua" language of the script
---@param name string? script path, named in warnings
---@return dev.Header header the parsed metadata
function M.parse(text, kind, name)
    local lines = kind == "lua" and lua_block(text) or split_lines(text .. "\n")
    local flags, warnings = flag_words(lines, name or "script")
    local group, hidden, runs_local, positional, fetch, patch = placement(lines)
    local remote, requires, declared = declarations(lines, name or "script")
    for _, warning in ipairs(declared) do
        warnings[#warnings + 1] = warning
    end
    return {
        desc = first_comment(lines),
        group = group ~= "" and group or nil,
        hidden = hidden,
        runs_local = runs_local,
        remote = remote,
        requires = requires,
        positional = positional,
        fetch = fetch,
        patch = patch,
        flags = flags,
        long = comment_block(lines),
        warnings = warnings,
    }
end

return M
