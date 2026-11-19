local dev_os = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")

---@class dev.templates
local M = {}

local BASE = "dotfiles/claude/.claude/skills/style/lint"
local LINT_MARKER = "-- --- project-specific checks below ---"
local DENY_MARKER = "# --- project-specific entries below (dev sync keeps them) ---"
local TEST_MARKER = "-- --- project-specific tests below ---"
local TEST_RETURN = "return code"
local LINTS_TABLE = "^%[workspace%.lints"
local LINT_RETURN = "return lint:finish()"
local LIB_DEST = ".dev/lua/lintset.lua"
local LIB_SRC = "dotfiles/claude/.claude/skills/style/lintset.lua"
local README_SRC = "dotfiles/bin/.local/share/dev/init/README.md"

---The marker line that ends the guide part of a project's `docs/STYLE.md`.
M.STYLE_MARKER = "## This project"

---The marker line that starts the project's own part of `.dev/README.md`.
M.README_MARKER = "## Commands in this repo"

---The `.editorconfig` text for a new project.
M.EDITORCONFIG = [[root = true

[*]
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 4

[{Makefile,*.go}]
indent_style = tab
]]

---The lint sets' directory below the dotfiles clone.
M.BASE = BASE

local Kind = project.Kind
local RUST_SET = "rust"
local SETS = { [Kind.RUST] = RUST_SET, [Kind.LOVE2D] = "lua", [Kind.LUA] = "lua" }

local function strip(text)
    return (text:gsub("\n+$", ""))
end

local function replace(text, old, new)
    local first, last = text:find(old, 1, true)
    if not first then
        return text
    end
    return text:sub(1, first - 1) .. new .. text:sub(last + 1)
end

local function lines_of(text)
    local out = {}
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    if text == "" then
        return {}
    end
    return out
end

local function after_marker(text, marker)
    local found = false
    local out = {}
    for _, line in ipairs(lines_of(text)) do
        if found then
            out[#out + 1] = line
        elseif line == marker then
            found = true
        end
    end
    if not found then
        return nil
    end
    return table.concat(out, "\n")
end

local function read(path)
    local text, err = fs.read(path)
    if not text then
        return nil, "cannot read " .. tostring(err)
    end
    return text
end

---Say whether a project type has a lint set.
---@param kind string the project type
---@return string? set the directory name of its set under the templates, nil for none
function M.set_for(kind)
    return SETS[kind]
end

---Find the lint template directory for a project type.
---@param kind string the project type
---@return string? dir the directory
---@return string? message why there is none
function M.dir(kind)
    local set = SETS[kind]
    if not set then
        return nil, "no lint templates for " .. kind .. " projects"
    end
    local repo = project.dotfiles_root()
    local dir = repo .. "/" .. BASE .. "/" .. set
    if not fs.is_dir(dir) then
        return nil, "no lint templates at " .. dir .. " (set DOTFILES to the dotfiles repo)"
    end
    return dir
end

local function pinned_channel(dir)
    local text = fs.read(dir .. "/rust-toolchain.toml")
    if text then
        for _, line in ipairs(lines_of(text)) do
            if line:find("^channel%s*=") then
                local value = line:gsub("^[^=]*=", ""):gsub('[ "]', "")
                return value
            end
        end
    end
    return nil
end

---Name the Rust channel a project uses.
---
---The channel the project's `rust-toolchain.toml` pins wins, then the one the Rust lint set pins,
---then `stable`.
---@param root string the project root
---@return string channel the channel word
function M.channel(root)
    local own = pinned_channel(root)
    if own then
        return own
    end
    local dir = M.dir(Kind.RUST)
    return dir and pinned_channel(dir) or "stable"
end

---@class dev.templates.Entry
---@field dest string the path in the project
---@field src string the template's absolute path

---List the files a lint set copies into a project.
---@param dir string the template directory
---@param kind string the project type, which adds `love.yml` for love2d
---@return dev.templates.Entry[] entries in the order a sync reports them
function M.manifest(dir, kind)
    local set = fs.basename(dir)
    local roots, scripts
    if set == RUST_SET then
        roots = { "rustfmt.toml", "rust-toolchain.toml", "clippy.toml", "deny.toml" }
        scripts = { "lint.lua", "fmt.lua", "test.lua" }
    else
        roots = { "stylua.toml", "selene.toml", "luajit.yml" }
        if kind == Kind.LOVE2D then
            roots[#roots + 1] = "love.yml"
        end
        scripts = { "lint.lua", "fmt.lua" }
    end
    local out = {}
    for _, name in ipairs(roots) do
        out[#out + 1] = { dest = name, src = dir .. "/" .. name }
    end
    if set == RUST_SET then
        out[#out + 1] = { dest = "stylua.toml", src = dir .. "/../lua/stylua.toml" }
    end
    out[#out + 1] = { dest = "sgconfig.yml", src = dir .. "/ast-grep/sgconfig.yml" }
    for _, name in ipairs(scripts) do
        out[#out + 1] = { dest = ".dev/" .. name, src = dir .. "/" .. name }
    end
    out[#out + 1] = { dest = LIB_DEST, src = dir .. "/../lintset.lua" }
    local found = dev_os.capture(
        { "find", "rules", "rule-test", "-type", "f" },
        { cwd = dir .. "/ast-grep", stderr = "null" }
    )
    local rules = lines_of(found)
    table.sort(rules)
    for _, name in ipairs(rules) do
        out[#out + 1] = { dest = ".dev/ast-grep/" .. name, src = dir .. "/ast-grep/" .. name }
    end
    return out
end

---Take the project's own lines below the marker in one of a project's `.dev` scripts.
---@param root string the project root
---@param script string the script's name in `.dev`
---@param marker string the marker line
---@param final string the script's closing line, which the tail never holds
---@return string tail the lines followed by a blank line, or an empty string
local function script_tail(root, script, marker, final)
    local text = fs.read(root .. "/.dev/" .. script)
    local tail = text and after_marker(text, marker)
    if not tail then
        return ""
    end
    tail = strip(tail)
    local last = tail:match("[^\n]*$")
    if last == final then
        tail = strip(tail:sub(1, #tail - #last))
    end
    tail = tail:gsub("^\n+", "")
    if tail == "" then
        return ""
    end
    return tail .. "\n\n"
end

---Standard Lua globals a lint tail may use
local GLOBAL_NAMES = {}
for name in
    ([[string table os io math require ipairs pairs type tostring tonumber pcall xpcall error
    assert select setmetatable getmetatable rawget rawset rawequal next unpack print package debug
    coroutine jit ffi bit load loadstring dofile arg _G _ENV utf8 collectgarbage self]]):gmatch(
        "%S+"
    )
do
    GLOBAL_NAMES[name] = true
end

local function blank(text)
    return (text:gsub("[^\n]", ""))
end

local function without_text(text)
    text = text:gsub("\\[^\n]", ""):gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
    text = text:gsub("(%-%-%[(=*)%[.-%]%2%])", blank)
    text = text:gsub("(%[(=*)%[.-%]%2%])", blank)
    return (text:gsub("%-%-[^\n]*", ""))
end

local function add_words(set, text)
    for word in text:gmatch("[%a_][%w_]*") do
        set[word] = true
    end
end

local function defined_names(text)
    local set = {}
    for params in text:gmatch("function[%w_%.:%s]*%(([^)]*)%)") do
        add_words(set, params)
    end
    for name in text:gmatch("function%s+([%w_]+)") do
        set[name] = true
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        for names in line:gmatch("local[ \t]+([%w_ \t,]+)") do
            add_words(set, names)
        end
        for names in line:gmatch("for[ \t]+([%w_ \t,]+)[ \t]+in%f[%s]") do
            add_words(set, names)
        end
        for name in line:gmatch("for[ \t]+([%w_]+)[ \t]*=") do
            set[name] = true
        end
        local target = line:match("^[ \t]*([%a_][%w_]*)[ \t]*=[^=]")
        if target then
            set[target] = true
        end
    end
    return set
end

---List the table names the project's own checks in `.dev/lint.lua` use without defining them.
---
---A name counts when the tail uses it as `name.` or `name:` and nothing in the file defines it
---as a local, a function, a parameter or a loop variable, and it is no standard Lua global.
---@param text string the text of `.dev/lint.lua`, as sync would write it
---@return {line: integer, name: string}[] unbound each use, in file order
function M.lint_unbound(text)
    local unbound = {}
    local raws = lines_of(text)
    local scrubbed = without_text(text)
    local lines = lines_of(scrubbed)
    local defined = defined_names(scrubbed)
    local marked = false
    for index, raw in ipairs(raws) do
        if marked then
            local seen = {}
            for start, name in lines[index]:gmatch("()([%a_][%w_]*)[%.:]%f[%a_]") do
                local before = lines[index]:sub(start - 1, start - 1)
                local known = defined[name] or GLOBAL_NAMES[name]
                if not known and before ~= "." and before ~= ":" and not seen[name] then
                    seen[name] = true
                    unbound[#unbound + 1] = { line = index, name = name }
                end
            end
        elseif raw == LINT_MARKER then
            marked = true
        end
    end
    return unbound
end

local function script_head(content, marker)
    local out = {}
    for _, line in ipairs(lines_of(content)) do
        out[#out + 1] = line
        if line == marker then
            break
        end
    end
    return table.concat(out, "\n")
end

---Drop the Lua verbs a project still on bash has not ported.
---
---While any `.dev/<verb>.sh` of the manifest's verbs exists, a Lua verb the project lacks is not
---written, and a Lua verb it already has stays synced. The shared library goes too when no verb
---is left to use it.
---@param root string the project root
---@param entries dev.templates.Entry[] the manifest
---@return dev.templates.Entry[] kept the entries a sync may write
---@return string[] pending the bash verbs left alone, such as `.dev/lint.sh`
function M.skip_pending(root, entries)
    local pending = {}
    for _, entry in ipairs(entries) do
        local verb = entry.dest:match("^%.dev/([^/]+)%.lua$")
        local bash = verb and ".dev/" .. verb .. ".sh"
        if bash and fs.is_file(root .. "/" .. bash) then
            pending[#pending + 1] = bash
        end
    end
    local held = #pending > 0
    local kept, verbs = {}, 0
    for _, entry in ipairs(entries) do
        local verb = entry.dest:match("^%.dev/([^/]+)%.lua$")
        if not (held and verb and not fs.is_file(root .. "/" .. entry.dest)) then
            kept[#kept + 1] = entry
            verbs = verbs + (verb and 1 or 0)
        end
    end
    if held and verbs == 0 then
        local rest = {}
        for _, entry in ipairs(kept) do
            if entry.dest ~= LIB_DEST then
                rest[#rest + 1] = entry
            end
        end
        kept = rest
    end
    return kept, pending
end

local function bracket_depth(line, depth)
    local quote, i = nil, 1
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == "\\" and quote == '"' then
                i = i + 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "#" then
            break
        elseif c == "[" then
            depth = depth + 1
        elseif c == "]" then
            depth = depth - 1
        end
        i = i + 1
    end
    return depth
end

local function advisories_ignore(text)
    local in_table, found, depth = false, nil, 0
    for _, line in ipairs(lines_of(text)) do
        if line == DENY_MARKER then
            break
        end
        if found then
            found[#found + 1] = line
            depth = bracket_depth(line, depth)
            if depth <= 0 then
                break
            end
        elseif line:find("^%[") then
            in_table = line == "[advisories]"
        elseif in_table and line:find("^ignore%s*=") then
            found = { line }
            depth = bracket_depth(line, 0)
            if depth <= 0 then
                break
            end
        end
    end
    return found
end

local function deny_text(root, content)
    local text = fs.read(root .. "/deny.toml")
    local tail = text and after_marker(text, DENY_MARKER)
    if not tail then
        return content
    end
    local cut = content:find(DENY_MARKER, 1, true)
    local head = cut and content:sub(1, cut - 1) or content
    local ignore = advisories_ignore(text)
    if ignore then
        local lines = lines_of(head)
        for i, line in ipairs(lines) do
            if line == "[advisories]" then
                table.insert(lines, i + 1, table.concat(ignore, "\n"))
                break
            end
        end
        head = table.concat(lines, "\n") .. "\n"
    end
    return head .. DENY_MARKER .. "\n" .. strip(tail)
end

---@class dev.templates.render.Opts
---@field kind string the project type
---@field dest string the path in the project
---@field src string the template's path
---@field channel string the Rust channel for `rust-toolchain.toml`

---Make the project's copy of a template.
---@param root string the project root
---@param opts dev.templates.render.Opts which template to render
---@return string? text the file's content
---@return string? message why it could not be read
function M.render(root, opts)
    local kind, dest, channel = opts.kind, opts.dest, opts.channel
    local raw, err = read(opts.src)
    if not raw then
        return nil, err
    end
    local content = strip(raw)
    if dest == "sgconfig.yml" then
        content = replace(content, "  - rules", "  - .dev/ast-grep/rules")
        content = replace(content, "testDir: rule-test", "testDir: .dev/ast-grep/rule-test")
    elseif dest == ".dev/lint.lua" then
        content = script_head(content, LINT_MARKER)
            .. "\n\n"
            .. script_tail(root, "lint.lua", LINT_MARKER, LINT_RETURN)
            .. LINT_RETURN
    elseif dest == ".dev/test.lua" and kind == Kind.RUST then
        content = script_head(content, TEST_MARKER)
            .. "\n\n"
            .. script_tail(root, "test.lua", TEST_MARKER, TEST_RETURN)
            .. TEST_RETURN
    elseif dest == "deny.toml" then
        content = strip(deny_text(root, content))
    elseif dest == "rust-toolchain.toml" then
        local out = {}
        for _, line in ipairs(lines_of(content)) do
            if line:find("^channel = ") then
                line = 'channel = "' .. channel .. '"'
            end
            out[#out + 1] = line
        end
        content = table.concat(out, "\n")
    elseif dest == "selene.toml" and kind == Kind.LUA then
        content = replace(content, 'std = "love"', 'std = "luajit"')
    end
    return content .. "\n"
end

---Write the project's copy of a template.
---@param root string the project root
---@param opts dev.templates.render.Opts which template to write
---@return true? ok true on success
---@return string? message why it failed
function M.install(root, opts)
    local dest = opts.dest
    local text, err = M.render(root, opts)
    if not text then
        return nil, err
    end
    local path = root .. "/" .. dest
    local ok, mkdir_err = fs.mkdir(fs.dirname(path), { parents = true })
    if not ok then
        return nil, mkdir_err
    end
    local wrote, write_err = fs.write(path, text)
    if not wrote then
        return nil, write_err
    end
    return true
end

---Take the lints block of a template without its paste header.
---@param dir string the template directory
---@return string? block the block with a closing newline
---@return string? message why it could not be read
function M.lints_template_block(dir)
    local raw, err = read(dir .. "/workspace-lints.toml")
    if not raw then
        return nil, err
    end
    local block = strip(raw)
    local _, last = block:find("\n\n", 1, true)
    if last then
        block = block:sub(last + 1)
    end
    return block .. "\n"
end

---Take the `[workspace.lints*]` tables of a `Cargo.toml`.
---
---The block runs from the first such table to the next other top-level table or the end, without
---trailing blank lines.
---@param cargo string the `Cargo.toml` text
---@return string block the block with a closing newline, or an empty string
function M.lints_project_block(cargo)
    local on, done, out = false, false, {}
    for _, line in ipairs(lines_of(cargo)) do
        if not done then
            if line:find("^%[") then
                if line:find(LINTS_TABLE) then
                    on = true
                elseif on then
                    done = true
                end
            end
            if on and not done then
                out[#out + 1] = line
            end
        end
    end
    local block = strip(table.concat(out, "\n"))
    if block == "" then
        return ""
    end
    return block .. "\n"
end

---Swap a `Cargo.toml`'s lints block for `block`, or append it when there is none.
---@param cargo string the `Cargo.toml` text
---@param block string the new block, with a closing newline
---@return string text the new text, every line outside the block as it was
function M.lints_replace(cargo, block)
    local has = false
    local all = lines_of(cargo)
    for _, line in ipairs(all) do
        if line:find(LINTS_TABLE) then
            has = true
        end
    end
    if not has then
        return cargo .. "\n" .. block
    end
    local on, done, out = false, false, {}
    for _, line in ipairs(all) do
        if done or (not on and not line:find(LINTS_TABLE)) then
            out[#out + 1] = line
        elseif line:find("^%[") and line:find(LINTS_TABLE) then
            if not on then
                out[#out + 1] = block:gsub("\n$", "")
                on = true
            end
        elseif line:find("^%[") and on then
            on = false
            done = true
            out[#out + 1] = ""
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n") .. "\n"
end

local function glob_segment(segment)
    local escaped = segment:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    return "^" .. escaped:gsub("%*", ".*"):gsub("%?", ".") .. "$"
end

local function expand(base, segments, index, rel, out)
    if index > #segments then
        out[#out + 1] = rel
        return
    end
    local segment = segments[index]
    local prefix = rel == "" and "" or rel .. "/"
    if not segment:find("[%*%?]") then
        if fs.exists(base .. "/" .. prefix .. segment) then
            expand(base, segments, index + 1, prefix .. segment, out)
        end
        return
    end
    local pattern = glob_segment(segment)
    for _, name in ipairs(fs.list(base .. (rel == "" and "" or "/" .. rel)) or {}) do
        if name:find(pattern) and (name:sub(1, 1) ~= "." or segment:sub(1, 1) == ".") then
            expand(base, segments, index + 1, prefix .. name, out)
        end
    end
end

local function members(root, cargo)
    local out, code = dev_os.capture(
        { "yq", "-p", "toml", "-oy", ".workspace.members[]", cargo },
        { stderr = "null" }
    )
    local dirs = {}
    if code == nil then
        return dirs
    end
    for _, pattern in ipairs(lines_of(out)) do
        if pattern ~= "" and pattern ~= "null" then
            local segments = {}
            for part in pattern:gmatch("[^/]+") do
                segments[#segments + 1] = part
            end
            local matches = {}
            expand(root, segments, 1, "", matches)
            for _, dir in ipairs(matches) do
                if fs.is_file(root .. "/" .. dir .. "/Cargo.toml") then
                    dirs[#dirs + 1] = dir
                end
            end
        end
    end
    return dirs
end

---List the member crate directories of a project.
---@param root string the project root
---@return string[] dirs the directories relative to the root, `.` for the root package
local function crate_dirs(root)
    local cargo = root .. "/Cargo.toml"
    if not fs.is_file(cargo) then
        return {}
    end
    local name = dev_os.capture(
        { "yq", "-p", "toml", "-oy", ".package.name", cargo },
        { stderr = "null" }
    )
    local dirs = {}
    if name:gsub("%s+$", "") ~= "null" then
        dirs[1] = "."
    end
    for _, dir in ipairs(members(root, cargo)) do
        dirs[#dirs + 1] = dir
    end
    return dirs
end

local function is_app(root, dir)
    local text = fs.read(root .. "/" .. dir .. "/Cargo.toml") or ""
    for _, line in ipairs(lines_of(text)) do
        if line:find("^publish%s*=%s*false") then
            return true
        end
    end
    return false
end

---List the library crates.
---
---They are the member crates that have a `src/lib.rs` and are not `publish = false`.
---@param root string the project root
---@return string[] dirs the directories relative to the root
function M.lib_crates(root)
    local out = {}
    for _, dir in ipairs(crate_dirs(root)) do
        if fs.is_file(root .. "/" .. dir .. "/src/lib.rs") and not is_app(root, dir) then
            out[#out + 1] = dir
        end
    end
    return out
end

---List the application crates.
---
---They are the member crates marked `publish = false`.
---@param root string the project root
---@return string[] dirs the directories relative to the root
function M.app_crates(root)
    local out = {}
    for _, dir in ipairs(crate_dirs(root)) do
        if is_app(root, dir) then
            out[#out + 1] = dir
        end
    end
    return out
end

---Take the snippet of the library-register lints.
---@param dir string the template directory
---@return string? snippet the file's text
---@return string? message why it could not be read
function M.lib_snippet(dir)
    return read(dir .. "/lib-lints.rs.snippet")
end

---Take the attribute line of a snippet, its last line.
---@param snippet string the snippet text
---@return string line the attribute line
local function lib_attr_line(snippet)
    local all = lines_of(snippet)
    return all[#all] or ""
end

---Say whether a library's `lib.rs` has the attribute line.
---@param snippet string the snippet text
---@param lib string the `lib.rs` text
---@return boolean present whether a line equals the attribute line
function M.lib_attr_present(snippet, lib)
    local want = lib_attr_line(snippet)
    for _, line in ipairs(lines_of(lib)) do
        if line == want then
            return true
        end
    end
    return false
end

---Put the snippet after the leading `//!` block of a `lib.rs`, unless it is there already.
---@param snippet string the snippet text
---@param lib string the `lib.rs` text
---@return string text the new text
function M.lib_attr_insert(snippet, lib)
    if M.lib_attr_present(snippet, lib) then
        return lib
    end
    local all = lines_of(lib)
    local n = 0
    while n < #all and all[n + 1]:find("^//!") do
        n = n + 1
    end
    local out = {}
    for i = 1, n do
        out[#out + 1] = all[i]
    end
    if n > 0 then
        out[#out + 1] = ""
    end
    for _, line in ipairs(lines_of(snippet)) do
        out[#out + 1] = line
    end
    if n < #all and all[n + 1] ~= "" then
        out[#out + 1] = ""
    end
    for i = n + 1, #all do
        out[#out + 1] = all[i]
    end
    return table.concat(out, "\n") .. "\n"
end

---Find the style guide a project type copies into `docs/STYLE.md`.
---@param kind string the project type
---@return string? path the guide's path, nil when the type has none
function M.style_guide(kind)
    local name = SETS[kind]
    if name then
        return project.dotfiles_root() .. "/docs/style/" .. name .. ".md"
    end
end

---Find the offset of the first line that is exactly the marker.
---@param text string the file's text
---@param marker string the marker line
---@return integer? from where that line starts, nil when no line is the marker
local function marker_offset(text, marker)
    local from = 1
    while from <= #text do
        local stop = text:find("\n", from, true) or #text + 1
        if text:sub(from, stop - 1) == marker then
            return from
        end
        from = stop + 1
    end
end

---Join a guide and the project's own section of `docs/STYLE.md`.
---@param root string the project root
---@param guide string the guide's path
---@return string? text the guide, a blank line, then the project's section from the marker
---@return string? message why a file could not be read
function M.render_style(root, guide)
    local head, err = read(guide)
    if not head then
        return nil, err
    end
    local own, own_err = read(root .. "/docs/STYLE.md")
    if not own then
        return nil, own_err
    end
    local from = marker_offset(own, M.STYLE_MARKER)
    if from then
        return head .. "\n" .. own:sub(from)
    end
    return head .. "\n"
end

---Name the path of the `.dev/README.md` template.
---@return string path the template's path below the dotfiles clone
function M.readme_template()
    return project.dotfiles_root() .. "/" .. README_SRC
end

---The file that records which dev modules and functions the dev baked into ci's images provides.
M.BAKED = ".dev/baked.txt"

---List the dev modules a template file requires and the functions it takes from them.
---@param text string the template file's text
---@return string[] calls the sorted entries, each a module or a function
function M.dev_calls(text)
    local found = {}
    local alias = {}
    for name, module in text:gmatch('local ([%a_][%w_]*) = require%("(dev%.[%w_.]+)"%)') do
        alias[name] = module
        found[module] = true
    end
    for module, fn in text:gmatch('require%("(dev%.[%w_.]+)"%)%.([%a_][%w_]*)') do
        found[module] = true
        found[module .. "." .. fn] = true
    end
    local at = 1
    while true do
        local first, last, name, fn = text:find("([%a_][%w_]*)%.([%a_][%w_]*)", at)
        if not first then
            break
        end
        local before = first > 1 and text:sub(first - 1, first - 1) or ""
        if alias[name] and before ~= "." then
            found[alias[name] .. "." .. fn] = true
        end
        at = last + 1
    end
    local out = {}
    for entry in pairs(found) do
        out[#out + 1] = entry
    end
    table.sort(out)
    return out
end

---Pick the paths that dev sync copies into other projects.
---@param paths string[] repo-relative paths, such as the files a commit touches
---@return string[] changed the sorted lint set files, lintset.lua and the README guide template among them
function M.changed(paths)
    local base = BASE .. "/"
    local found = {}
    for _, path in ipairs(paths) do
        if path:sub(1, #base) == base or path == LIB_SRC or path == README_SRC then
            found[#found + 1] = path
        end
    end
    table.sort(found)
    return found
end

---Join the template above its marker and the project's own section of `.dev/README.md`.
---@param root string the project root
---@param template string the template's path
---@return string? text the template's head, then the project's text from the marker to the end
---@return string? message why a file could not be read
function M.render_readme(root, template)
    local text, err = read(template)
    if not text then
        return nil, err
    end
    local own, own_err = read(root .. "/.dev/README.md")
    if not own then
        return nil, own_err
    end
    local from = marker_offset(own, M.README_MARKER)
    local top = marker_offset(text, M.README_MARKER)
    if from and top then
        return text:sub(1, top - 1) .. own:sub(from)
    end
    return text
end

return M
