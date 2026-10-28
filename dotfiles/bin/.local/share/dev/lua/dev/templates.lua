local devos = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")

---@class dev.templates
local M = {}

local BASE = "dotfiles/claude/.claude/skills/style/lint"
local LINT_MARKER = "# --- project-specific checks below ---"
local DENY_MARKER = "# --- project-specific entries below (dev sync keeps them) ---"
local LINTS_TABLE = "^%[workspace%.lints"
local CD_OLD = 'cd "$(dirname "${BASH_SOURCE[0]}")"'
local CD_NEW = 'cd "$(dirname "${BASH_SOURCE[0]}")/.."'
local LIB_OLD = "/../lint-lib.sh"
local LIB_NEW = "/lint-lib.sh"
local SG_OLD = "--config ast-grep/sgconfig.yml"
local SG_NEW = "--config sgconfig.yml"

---The marker line that ends the guide part of a project's `docs/STYLE.md`.
M.STYLE_MARKER = "## This project"

---The lint sets' directory below the dotfiles clone.
M.BASE = BASE

local Kind = project.Kind
local RUST_SET = "rust"
local SETS = { [Kind.RUST] = RUST_SET, [Kind.LOVE2D] = "lua", [Kind.LUA] = "lua" }

local function strip(text)
    return (text:gsub("\n+$", ""))
end

local function substitute(text, old, new, all)
    local out, from = {}, 1
    while true do
        local first, last = text:find(old, from, true)
        if not first then
            break
        end
        out[#out + 1] = text:sub(from, first - 1)
        out[#out + 1] = new
        from = last + 1
        if not all then
            break
        end
    end
    out[#out + 1] = text:sub(from)
    return table.concat(out)
end

local function replace(text, old, new)
    return substitute(text, old, new, false)
end

local function replace_all(text, old, new)
    return substitute(text, old, new, true)
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

---Name the Rust channel a project uses.
---
---The channel the project's `rust-toolchain.toml` pins wins, then the installed stable compiler's
---version, then `stable`.
---@param root string the project root
---@return string channel the channel word
function M.channel(root)
    local text = fs.read(root .. "/rust-toolchain.toml")
    if text then
        for _, line in ipairs(lines_of(text)) do
            if line:find("^channel%s*=") then
                local value = line:gsub("^[^=]*=", ""):gsub('[ "]', "")
                return value
            end
        end
    end
    for _, argv in ipairs({ { "rustc", "+stable", "--version" }, { "rustc", "--version" } }) do
        if devos.which("rustc") then
            local out, code = devos.capture(argv, { stderr = "null" })
            if code == 0 then
                return (out:gsub("^rustc ", ""):match("^(%S+)")) or "stable"
            end
        end
    end
    return "stable"
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
        scripts = { "lint.sh", "fmt.sh", "test.sh" }
    else
        roots = { "stylua.toml", "selene.toml", "luajit.yml" }
        if kind == Kind.LOVE2D then
            roots[#roots + 1] = "love.yml"
        end
        scripts = { "lint.sh", "fmt.sh" }
    end
    local out = {}
    for _, name in ipairs(roots) do
        out[#out + 1] = { dest = name, src = dir .. "/" .. name }
    end
    out[#out + 1] = { dest = "sgconfig.yml", src = dir .. "/ast-grep/sgconfig.yml" }
    for _, name in ipairs(scripts) do
        out[#out + 1] = { dest = ".dev/" .. name, src = dir .. "/" .. name }
    end
    out[#out + 1] = { dest = ".dev/lint-lib.sh", src = dir .. "/../lint-lib.sh" }
    local found = devos.capture(
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

---Take the project's own checks below the marker in a project's `.dev/lint.sh`.
---@param root string the project root
---@return string tail the checks with a leading newline, or an empty string
local function lint_tail(root)
    local text = fs.read(root .. "/.dev/lint.sh")
    local tail = text and after_marker(text, LINT_MARKER)
    tail = tail and strip(tail)
    if tail and tail ~= "" then
        return "\n" .. tail
    end
    return ""
end

local function deny_text(root, content)
    local text = fs.read(root .. "/deny.toml")
    local tail = text and after_marker(text, DENY_MARKER)
    if not tail then
        return content
    end
    local cut = content:find(DENY_MARKER, 1, true)
    local head = cut and content:sub(1, cut - 1) or content
    return head .. DENY_MARKER .. "\n" .. strip(tail)
end

---@class dev.templates.RenderOpts
---@field kind string the project type
---@field dest string the path in the project
---@field src string the template's path
---@field channel string the Rust channel for `rust-toolchain.toml`

---Make the project's copy of a template.
---@param root string the project root
---@param opts dev.templates.RenderOpts which template to render
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
    elseif dest == ".dev/lint.sh" then
        content = replace(content, CD_OLD, CD_NEW)
        content = replace(content, LIB_OLD, LIB_NEW)
        content = replace_all(content, SG_OLD, SG_NEW)
        content = content .. lint_tail(root)
    elseif dest == ".dev/fmt.sh" then
        content = replace(content, CD_OLD, CD_NEW)
        content = replace(content, LIB_OLD, LIB_NEW)
    elseif dest == ".dev/test.sh" then
        content = replace(content, CD_OLD, CD_NEW)
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

---Write the project's copy of a template, executable when it is a script.
---@param root string the project root
---@param opts dev.templates.RenderOpts which template to write
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
    if dest:find("%.sh$") then
        if devos.run({ "chmod", "+x", path }) ~= 0 then
            return nil, "cannot make " .. path .. " executable"
        end
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
    local out, code = devos.capture(
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
    local name = devos.capture(
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
    local from = 1
    while from <= #own do
        local stop = own:find("\n", from, true) or #own + 1
        if own:sub(from, stop - 1) == M.STYLE_MARKER then
            return head .. "\n" .. own:sub(from)
        end
        from = stop + 1
    end
    return head .. "\n"
end

return M
