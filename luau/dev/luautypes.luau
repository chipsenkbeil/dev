local fs = require("@dev/fs")
local json = require("@dev/json")
local runtime = require("@dev/runtime")

type Signature = {
    module: string,
    name: string,
    signature: string,
    docs: { string },
    value: boolean,
}

---@class dev.luautypes
local M = {}

---The folder of a project, relative to its root, that holds the generated declarations
M.FOLDER = ".dev/types"

---The value of the `dev` alias in a project's `.luaurc`, which luau-analyze reads
M.ALIAS = "./.dev/types"

local EMBEDDED = "luau/dev"

---The embedded folders, by name under `luau/dev`, that hold no module
local SKIPPED_TOP = { commands = true }

---The `.luaurc` of the declarations folder, which turns the style lints off for its files
local LUAURC = '{ "lint": { "*": false } }\n'

---The `.gitignore` of the declarations folder, which also marks the folder as written by dev
local IGNORE = "*\n"

---The opening lines of a declaration file, with the dev version to fill in
local HEADER = "--!strict\n-- Written by `dev luautypes` from dev %s. Edit nothing here.\n"

---The Luau keywords, which a field name needs quoting to use
local KEYWORDS = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

---Collect the embedded Luau modules as they are, keyed by their path under the declarations folder.
local function embedded_modules(dir: string, prefix: string, files: { [string]: string })
    for _, name in ipairs(runtime.assets(dir)) do
        local path = `{dir}/{name}`
        local text = runtime.asset(path)
        if text and name:find("%.luau$") then
            files[prefix .. name] = text
        elseif not text and not (dir == EMBEDDED and SKIPPED_TOP[name]) then
            embedded_modules(path, `{prefix}{name}/`, files)
        end
    end
end

---Move each module `X.luau` that sits beside a folder `X` to `X/init.luau`.
---
---luau-analyze resolves `@dev/X/Y` only when `X` is the folder, so a file beside its folder hides
---the modules in it. The folder's own `init.luau` is dropped for it, as `@dev/X/init` is not a
---require name luau-analyze accepts.
local function beside_folders(files: { [string]: string })
    local folders = {}
    for path in pairs(files) do
        for folder in path:gmatch("()/") do
            folders[path:sub(1, folder - 1)] = true
        end
    end
    local moved = {}
    for path, text in pairs(files) do
        local stem = path:match("^(.*)%.luau$")
        if stem and folders[stem] then
            moved[`{stem}/init.luau`] = text
            files[path] = nil
        end
    end
    for path, text in pairs(moved) do
        files[path] = text
    end
end

---Write the doc lines of a native member as `---` lines, up to its first heading.
local function doc_text(docs: { string }, indent: string): string
    local lines = {}
    for _, line in ipairs(docs) do
        if line:find("^#") then
            break
        end
        lines[#lines + 1] = line == "" and `{indent}---` or `{indent}--- {line}`
    end
    while lines[#lines] == `{indent}---` do
        lines[#lines] = nil
    end
    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n") .. "\n"
end

---Write the members of one module or handle type as table fields.
local function fields_text(entries: { Signature }): string
    local out = {}
    for _, entry in ipairs(entries) do
        local key = KEYWORDS[entry.name] and `["{entry.name}"]` or entry.name
        out[#out + 1] = `{doc_text(entry.docs, "    ")}    {key}: {entry.signature},\n`
    end
    return table.concat(out)
end

---Tell whether a type name appears in a piece of Luau type text.
local function mentions(text: string, name: string): boolean
    return text:find(`%f[%w_]{name}%f[^%w_]`) ~= nil
end

---Find the handle types a module names, and the ones those names in turn.
local function used_types(
    entries: { Signature },
    types: { [string]: { Signature } }
): { [string]: boolean }
    local used = {}
    local queue = { entries }
    while #queue > 0 do
        local members = table.remove(queue) :: { Signature }
        for name, typed in pairs(types) do
            if not used[name] then
                for _, entry in ipairs(members) do
                    if mentions(entry.signature, name) then
                        used[name] = true
                        queue[#queue + 1] = typed
                        break
                    end
                end
            end
        end
    end
    return used
end

---Write the declaration file of one native module.
local function native_text(
    entries: { Signature },
    types: { [string]: { Signature } },
    version: string
): string
    -- Name the handle types the module uses, in order
    local names = {}
    for name in pairs(used_types(entries, types)) do
        names[#names + 1] = name
    end
    table.sort(names)

    -- Declare each handle type, then return the module's table
    local out = { string.format(HEADER, version) }
    for _, name in ipairs(names) do
        out[#out + 1] = `export type {name} = \{\n{fields_text(types[name])}\}\n`
    end
    out[#out + 1] = `return (nil :: any) :: \{\n{fields_text(entries)}\}\n`
    return table.concat(out)
end

---Group the registered native signatures into module members and handle type members.
---
---A record whose module starts with an uppercase letter belongs to a handle type, and one whose
---module starts with an underscore is left out.
local function grouped(): ({ [string]: { Signature } }, { [string]: { Signature } })
    local modules, types = {}, {}
    for _, entry in ipairs(runtime.signatures()) do
        local name = entry.module
        if not name:find("^_") then
            local into = name:find("^%u") and types or modules
            into[name] = into[name] or {}
            table.insert(into[name], entry)
        end
    end
    for _, group in ipairs({ modules, types }) do
        for _, entries in pairs(group) do
            table.sort(entries, function(a: Signature, b: Signature)
                return a.name < b.name
            end)
        end
    end
    return modules, types
end

---Build every declaration file for the dev that is running.
---
---The embedded Luau modules are written as they are, and each native module is written from the
---signature that sits beside each of its Rust functions. The folder also holds a `.luaurc` that
---turns luau-analyze's style lints off for those files and a `.gitignore` that ignores the folder.
---@return table<string, string> files the file text keyed by path under the declarations folder
function M.files()
    local files = {}
    embedded_modules(EMBEDDED, "", files)
    beside_folders(files)
    local modules, types = grouped()
    for name, entries in pairs(modules) do
        files[`{name}.luau`] = native_text(entries, types, runtime.version)
    end
    files[".luaurc"] = LUAURC
    files[".gitignore"] = IGNORE
    return files
end

---Read the folder a project's `.luaurc` gives the `dev` alias, `FOLDER` when it sets none.
---@param root the project root
---@return the folder, relative to the root
function M.folder(root: string): string
    local text = fs.read(`{root}/.luaurc`)
    local doc = text and json.decode(text)
    local aliases = type(doc) == "table" and doc.aliases
    local folder = type(aliases) == "table" and aliases.dev
    return type(folder) == "string" and folder or M.FOLDER
end

---List the files below a folder, as paths relative to it.
local function listed(dir: string, prefix: string, out: { string })
    for _, name in ipairs(fs.list(dir) or {}) do
        if fs.is_dir(`{dir}/{name}`) then
            listed(`{dir}/{name}`, `{prefix}{name}/`, out)
        else
            out[#out + 1] = prefix .. name
        end
    end
end

---Bring a declarations folder up to date, writing only the files that differ.
---
---A file the folder holds that dev no longer writes is removed. A folder that holds files and no
---`.gitignore` dev wrote is refused, so a wrong alias cannot clear a folder dev does not own.
---@param dest the declarations folder, made when it is missing
---@return how many files were written or removed, nil when the write failed
---@return why the write failed
function M.write(dest: string): (number?, string?)
    local files = M.files()
    if #(fs.list(dest) or {}) > 0 and fs.read(`{dest}/.gitignore`) ~= IGNORE then
        return nil, `{dest} holds files dev did not write`
    end

    -- Make the folder before writing into it
    local ok, reason = fs.mkdir(dest, { parents = true })
    if not ok then
        return nil, reason
    end

    -- Write each file that is missing or differs
    local changed = 0
    local paths = {}
    for path in pairs(files) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    for _, path in ipairs(paths) do
        local target = `{dest}/{path}`
        if fs.read(target) ~= files[path] then
            local made, why = fs.mkdir(fs.dirname(target), { parents = true })
            if made then
                made, why = fs.write(target, files[path])
            end
            if not made then
                return nil, why
            end
            changed += 1
        end
    end

    -- Remove each file dev no longer writes
    local present = {}
    listed(dest, "", present)
    for _, path in ipairs(present) do
        if files[path] == nil then
            local removed, why = fs.remove(`{dest}/{path}`)
            if not removed then
                return nil, why
            end
            changed += 1
        end
    end
    return changed
end

return M
