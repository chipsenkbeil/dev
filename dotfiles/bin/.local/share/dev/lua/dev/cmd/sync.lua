local devos = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")
local templates = require("dev.templates")
local ui = require("dev.ui")
local verb = require("dev.verb")

local NONE = "none"

---@class dev.cmd.sync
local M = {}

local QUESTION = "Overwrite the project's lint files with the templates?"
local CONSEQUENCE =
    "This replaces the copied lint files, the lints block, the lib.rs attributes and the guide part of docs/STYLE.md."
local NO_TERMINAL =
    "sync overwrites files and needs a terminal to confirm, pass --yes to apply without asking, or --check to list drift"

local function parse(ctx)
    local check, yes = false, false
    for _, arg in ipairs(ctx.args) do
        if arg == "--check" then
            check = true
        elseif arg == "--yes" or arg == "-y" then
            yes = true
        end
    end
    return check, yes
end

local function entry_opts(kind, entry, channel)
    return { kind = kind, dest = entry.dest, src = entry.src, channel = channel }
end

local function die(message)
    verb.die("dev: " .. message)
end

local function has_marker(text)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line == templates.STYLE_MARKER then
            return true
        end
    end
    return false
end

local function show_diff(from, to)
    devos.run({ "diff", "-u", from, to })
end

local function stage(tmp, dest, text)
    local path = tmp .. "/" .. dest
    assert(fs.mkdir(fs.dirname(path), { parents = true }))
    assert(fs.write(path, text))
    return path
end

---Describe the command line `dev help sync` shows.
---@param root string absolute path of the project root
---@return string[] lines the text `dev help sync` prints
function M.commands(root)
    local kind = project.detect_type(root) or NONE
    local set = templates.set_for(kind)
    if not set then
        return { "(none: no lint templates for " .. kind .. " projects)" }
    end
    return {
        "diff the project's lint files against "
            .. project.dotfiles_root()
            .. "/"
            .. templates.BASE
            .. "/"
            .. set,
    }
end

---Compare a project's copied lint files with the dotfiles templates, and with `--yes` or a
---confirmation replace them.
---
---It checks the manifest's files, the `[workspace.lints]` block of `Cargo.toml`, the
---library-register attribute of each library crate and the guide part of `docs/STYLE.md`. A
---run with drift and `--check` exits 1.
---@param ctx dev.Ctx the verb's context, whose `args` are `--check`, `--yes` or `-y`
---@return integer code the exit code
function M.run(ctx)
    local root = ctx.root
    local check, yes = parse(ctx)
    local kind = project.detect_type(root) or NONE
    if not templates.set_for(kind) then
        io.write("dev: no lint templates for ", kind, " projects\n")
        return 0
    end
    local dir, dir_err = templates.dir(kind)
    if not dir then
        die(dir_err)
    end
    local has_cargo = fs.is_file(root .. "/Cargo.toml")
    if has_cargo then
        verb.need("yq", "brew install yq")
    end
    local channel = templates.channel(root)
    local drifted = false

    local entries, pending = templates.skip_pending(root, templates.manifest(dir, kind))
    local rendered = {}
    for i, entry in ipairs(entries) do
        local text, err = templates.render(root, entry_opts(kind, entry, channel))
        if not text then
            die(err)
        end
        rendered[i] = text
        local current = fs.is_file(root .. "/" .. entry.dest) and fs.read(root .. "/" .. entry.dest)
        if not current then
            io.write("missing: ", entry.dest, "\n")
            drifted = true
        elseif current ~= text then
            io.write("differs: ", entry.dest, "\n")
            drifted = true
        end
    end

    local lints_old, lints_new = "", ""
    local lints_differ = false
    if has_cargo then
        local err
        lints_new, err = templates.lints_template_block(dir)
        if not lints_new then
            die(err)
        end
        lints_old = templates.lints_project_block(fs.read(root .. "/Cargo.toml") or "")
        lints_differ = lints_old ~= lints_new
        if lints_old == "" then
            io.write("missing: [workspace.lints] block in Cargo.toml\n")
            drifted = true
        elseif lints_differ then
            io.write("differs: [workspace.lints] block in Cargo.toml\n")
            drifted = true
        end
    end

    local snippet = ""
    local missing_libs = {}
    local libs = templates.lib_crates(root)
    if #libs > 0 then
        local snippet_err
        snippet, snippet_err = templates.lib_snippet(dir)
        if not snippet then
            die(snippet_err)
        end
    end
    for _, lib in ipairs(libs) do
        local text = fs.read(root .. "/" .. lib .. "/src/lib.rs") or ""
        if not templates.lib_attr_present(snippet, text) then
            io.write("missing: library-register attribute in ", lib, "/src/lib.rs\n")
            missing_libs[#missing_libs + 1] = lib
            drifted = true
        end
    end

    local style, style_drift = nil, false
    local style_path = root .. "/docs/STYLE.md"
    local guide = templates.style_guide(kind)
    local own = fs.is_file(style_path) and fs.read(style_path)
    if own and has_marker(own) and guide and fs.is_file(guide) then
        local err
        style, err = templates.render_style(root, guide)
        if not style then
            die(err)
        end
        if style ~= own then
            io.write('differs: docs/STYLE.md above "', templates.STYLE_MARKER, '"\n')
            style_drift = true
            drifted = true
        end
    end

    if #pending > 0 then
        io.write(
            "pending: ",
            table.concat(pending, ", "),
            " left alone until the project ports it to Lua\n"
        )
    end
    if not drifted then
        io.write("up to date\n")
        return 0
    end
    if check then
        return 1
    end
    local context = ui.context({ color = false })
    if not yes and not context.interactive then
        die(NO_TERMINAL)
    end

    local tmp = assert(fs.mktemp({ dir = true }))
    for i, entry in ipairs(entries) do
        local new = stage(tmp, entry.dest, rendered[i])
        local old = root .. "/" .. entry.dest
        show_diff(fs.is_file(old) and old or "/dev/null", new)
    end
    if has_cargo and lints_differ then
        show_diff(stage(tmp, "lints.old", lints_old), stage(tmp, "lints.new", lints_new))
    end
    local shown = (snippet:gsub("\n+$", ""))
    for _, lib in ipairs(missing_libs) do
        io.write("would insert into ", lib, "/src/lib.rs:\n", shown, "\n")
    end
    if style_drift then
        show_diff(style_path, stage(tmp, "STYLE.md", style))
    end
    fs.remove(tmp, { recursive = true })

    if not yes and not ui.confirm(context, QUESTION, CONSEQUENCE) then
        io.write("aborted\n")
        return 0
    end
    local code = 0
    local function failed(err)
        verb.note("dev: " .. tostring(err))
        code = 1
    end
    for _, entry in ipairs(entries) do
        local ok, err = templates.install(root, entry_opts(kind, entry, channel))
        if not ok then
            failed(err)
        end
    end
    if has_cargo and lints_differ then
        local path = root .. "/Cargo.toml"
        local ok, err = fs.write(path, templates.lints_replace(fs.read(path) or "", lints_new))
        if not ok then
            failed(err)
        end
    end
    for _, lib in ipairs(missing_libs) do
        local path = root .. "/" .. lib .. "/src/lib.rs"
        local ok, err = fs.write(path, templates.lib_attr_insert(snippet, fs.read(path) or ""))
        if not ok then
            failed(err)
        end
    end
    if style_drift then
        local ok, err = fs.write(style_path, style)
        if not ok then
            failed(err)
        end
    end
    io.write("synced\n")
    return code
end

return M
