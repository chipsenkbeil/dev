local spec_check = require("dev.spec")

---The header words dev took before the spec fields existed, and what replaces each.
local GONE = {
    flags = "Declare each flag on its own `# flag: NAME -- HELP` line.",
    ["local"] = "Write `# runs_local` instead.",
}

---@class dev.header
local M = {}

local function skipped(line)
    return line:find("^# *shellcheck ")
end

local function ends_header(line, number)
    return number > 1 and line:find("%S") ~= nil and line:sub(1, 1) ~= "#"
end

local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    return lines
end

local function split_words(text)
    local words = {}
    for word in text:gmatch("[^,]+") do
        words[#words + 1] = word
    end
    return words
end

local function declaration_of(line, path)
    local name = line:match("^# *flag: *(.*)$")
    local body, help = line:match("^# *flag: *(.-) +%-%- *(.*)$")
    if not name then
        return nil
    end
    body = body or name
    local words = {}
    for word in body:gmatch("%S+") do
        words[#words + 1] = word
    end
    local flag = { name = table.remove(words, 1), help = help }
    if flag.name == nil then
        return nil, "The flag line of " .. path .. " has no name."
    end
    for _, word in ipairs(words) do
        local key, value = word:match("^(%a+)=(.*)$")
        if key == "short" then
            flag.short = value
        elseif key == "kind" then
            flag.kind = value
        elseif key == "choices" then
            flag.choices = split_words(value)
        elseif key == "default" then
            flag.default = value
        elseif word == "repeatable" or word == "required" or word == "hidden" then
            flag[word] = true
        else
            return nil,
                "The flag line of "
                    .. path
                    .. " for "
                    .. flag.name
                    .. " holds `"
                    .. word
                    .. "`, which dev does not know."
        end
    end
    if flag.default ~= nil then
        if flag.repeatable then
            flag.default = split_words(flag.default)
        elseif flag.kind == "number" then
            flag.default = tonumber(flag.default)
        elseif flag.kind == "boolean" then
            flag.default = flag.default == "true"
        end
        if flag.default == nil then
            return nil, "The flag line of " .. path .. " for " .. flag.name .. " has a bad default."
        end
    end
    return flag
end

local function arg_of(line, path)
    local body, help = line:match("^# *arg: *(.-) +%-%- *(.*)$")
    body = body or line:match("^# *arg: *(.*)$")
    local words = {}
    for word in body:gmatch("%S+") do
        words[#words + 1] = word
    end
    local arg = { name = table.remove(words, 1), help = help }
    if arg.name == nil then
        return nil, "The arg line of " .. path .. " has no name."
    end
    for _, word in ipairs(words) do
        if word == "required" or word == "list" then
            arg[word] = true
        else
            return nil,
                "The arg line of "
                    .. path
                    .. " for "
                    .. arg.name
                    .. " holds `"
                    .. word
                    .. "`, which dev does not know."
        end
    end
    return arg
end

---Read one line into the spec, and say whether it was a header word.
local function apply(spec, line, path)
    local value = line:match("^# *summary: *(.*)$")
    if value then
        spec.summary = value
        return true
    end
    value = line:match(`^# *{spec_check.SEE_ALSO_FIELD}:(.*)$`)
    if value then
        local names = spec[spec_check.SEE_ALSO_FIELD] or {}
        for name in value:gmatch("%S+") do
            names[#names + 1] = name
        end
        spec[spec_check.SEE_ALSO_FIELD] = names
        return true
    end
    value = line:match("^# *group: *(.*)$")
    if value then
        spec.group = value
        return true
    end
    if line:find("^# *flag:") then
        local flag, reason = declaration_of(line, path)
        if not flag then
            return true, reason
        end
        spec.flags[#spec.flags + 1] = flag
        return true
    end
    if line:find("^# *arg:") then
        local arg, reason = arg_of(line, path)
        if not arg then
            return true, reason
        end
        spec.args[#spec.args + 1] = arg
        return true
    end
    local requires = line:match("^# *requires:(.*)$")
    if requires then
        for word in requires:gmatch("%S+") do
            spec.requires[#spec.requires + 1] = word
        end
        return true
    end
    if line:find("^# *remote: *false *$") then
        spec.remote = false
        return true
    end
    if line:find("^# *globals: *false *$") then
        spec.globals = false
        return true
    end
    local job, file = line:match("^# *fetch +(%S+) +(%S+) *$")
    if job then
        spec.fetch = spec.fetch or { job = job, file = file }
        return true
    end
    job, file = line:match("^# *patch +(%S+) +(%S+) *$")
    if job then
        spec.patch = spec.patch or { job = job, file = file }
        return true
    end
    local word = line:match("^# *([%a_]+) *$")
    if
        word == "hidden"
        or word == "passthrough"
        or word == "runs_local"
        or word == "positional"
    then
        spec[word] = true
        return true
    end
    local gone = line:match("^# *(%a+):") or word
    if gone and GONE[gone] then
        return true,
            "The header of " .. path .. " uses `" .. gone .. "`, which is gone. " .. GONE[gone]
    end
    return false
end

---Parse the header of a `.sh` or `.ps1` command into a spec.
---
---The header is the comment block after the shebang. It ends at the first line that is not a
---comment. The grammar, one line each:
---
---    # summary: TEXT
---    # group: TEXT
---    # see_also: NAME [NAME...]
---    # hidden
---    # flag: NAME [short=S] [kind=K] [choices=a,b] [repeatable] [required] [hidden] [default=V] -- HELP
---    # arg: NAME [required] [list] -- HELP
---    # remote: false
---    # requires: WORD...
---    # passthrough
---    # runs_local
---    # positional
---    # globals: false
---    # fetch JOB FILE
---    # patch JOB FILE
---
---The first plain comment is the summary when no `summary:` line is given, and the other plain
---comments are `long`, the text `dev help` prints. Lines that name `shellcheck` are skipped.
---@param text string contents of the script
---@param path string script path, named in the reasons
---@return dev.Spec? spec the checked spec, with no `run`
---@return string? reason what is wrong with the header
function M.parse(text, path)
    local lines = split_lines(text)
    local first = lines[1] and lines[1]:sub(1, 2) == "#!" and 2 or 1
    local spec = { flags = {}, args = {}, requires = {} }
    local first_comment
    local long = {}
    for number = first, #lines do
        local line = lines[number]
        if ends_header(line, number) then
            break
        end
        if line:sub(1, 1) == "#" and not skipped(line) then
            local known, reason = apply(spec, line, path)
            if reason then
                return nil, reason
            end
            if not known then
                local plain = (line:gsub("^# ?", ""))
                long[#long + 1] = plain
                if first_comment == nil and plain ~= "" then
                    first_comment = #long
                end
            end
        end
    end
    if spec.summary == nil then
        spec.summary = first_comment and long[first_comment] or ""
        if first_comment then
            table.remove(long, first_comment)
            while long[1] == "" do
                table.remove(long, 1)
            end
        end
    end
    spec.long = #long > 0 and table.concat(long, "\n") or nil
    local checked, reason, code = spec_check.validate(spec)
    if not checked then
        return nil, `The header of {path} is wrong. {reason}`, code
    end
    return checked
end

return M
