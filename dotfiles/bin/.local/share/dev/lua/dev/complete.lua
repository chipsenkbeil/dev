local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local topics = require("dev.topics")

local stderr = io.stderr

---@class dev.complete
local M = {}

---Print `name<TAB>origin<TAB>description` for every command, for shell completion.
---@param _ dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.commands(_, reg)
    for _, row in ipairs(reg:commands()) do
        io.write(row.name, "\t", row.kind, "\t", row.desc, "\n")
    end
    return 0
end

---Print `sub<TAB>origin<TAB>description` for each subcommand of the command named by
---`ctx.args`, one word per level.
---@param ctx dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0, with no output for a word that is no command with subcommands
function M.subs(ctx, reg)
    if reg:is_noun(ctx.args) then
        for _, row in ipairs(reg:subs(ctx.args)) do
            io.write(row.words[#row.words], "\t", row.kind, "\t", row.desc, "\n")
        end
    end
    return 0
end

---Print the flags of the command in `ctx.args`, one word per level, then the global flags.
---@param ctx dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.flags(ctx, reg)
    for _, flag in ipairs(reg:flags(ctx.args)) do
        io.write(flag, "\n")
    end
    for _, flag in ipairs(registry.GLOBAL_FLAGS) do
        io.write(flag, "\n")
    end
    return 0
end

local CI_SECONDS = 3
local CARDS_FRESH_SECONDS = 60

---The `dev board` subcommands whose first argument is a card
local CARD_SUBS = {
    take = true,
    release = true,
    land = true,
    order = true,
    lint = true,
    turn = true,
    show = true,
    notes = true,
    note = true,
    size = true,
    label = true,
    answer = true,
    ask = true,
    escalate = true,
    outcome = true,
    link = true,
    unlink = true,
    links = true,
    epic = true,
    responsible = true,
    due = true,
    delete = true,
    attach = true,
    download = true,
    attachments = true,
    detach = true,
    history = true,
    edit = true,
    rename = true,
    checks = true,
    check = true,
    review = true,
    allow = true,
    tests = true,
    files = true,
    move = true,
    discard = true,
}

---The `ci __complete` kinds a `dev connect` argument takes
local CONNECT_KINDS = { "boxes", "connectables" }

---The `dev box` subcommands whose first argument is a box, with the kinds that complete it
local BOX_SUBS = {
    show = { "boxes" },
    stop = { "boxes" },
    resume = { "boxes" },
    extend = { "boxes" },
    retag = { "boxes" },
    delete = { "boxes" },
    connect = CONNECT_KINDS,
}
local REFRESH_SCRIPT = 'tmp="$1.$$"; { date +%s; dev -C "$2" board ls; } >"$tmp" 2>/dev/null'
    .. ' && mv "$tmp" "$1"; rm -f "$tmp"'

local function cards_file(root)
    local base = os.getenv("XDG_CACHE_HOME")
    if not base or base == "" then
        base = (os.getenv("HOME") or "") .. "/.cache"
    end
    return base .. "/dev/cards-" .. root:gsub("[^%w]", "_")
end

---Print the card ids the cache holds, and start a refresh in the background when it is stale.
---@param root string the project root
local function print_cards(root)
    local file = cards_file(root)
    local text = fs.read(file)
    local stamp = text and tonumber(text:match("^(%d+)\n"))
    if not stamp or os.time() - stamp >= CARDS_FRESH_SECONDS then
        fs.mkdir(fs.dirname(file), { parents = true })
        dev_os.run({
            "sh",
            "-c",
            "(" .. REFRESH_SCRIPT .. ") </dev/null >/dev/null 2>&1 &",
            "sh",
            file,
            root,
        }, { stdout = "null", stderr = "null" })
    end
    for line in (text or ""):gmatch("[^\n]+") do
        local id, rest = line:match("^(%x%x%x%x%x%x%x%x)%s+(.-)%s*$")
        if id then
            io.write(id, "\t", rest, "\n")
        end
    end
end

---Print the ids `ci __complete KIND` lists, or nothing when ci is missing, slow or fails.
---@param kinds string[] the `ci __complete` kinds: `runs`, `boxes` or `connectables`
local function print_ci(kinds)
    if not dev_os.which("ci") then
        return
    end
    for _, kind in ipairs(kinds) do
        local out, code = dev_os.capture_timed({ "ci", "__complete", kind }, CI_SECONDS)
        if code == 0 then
            io.write(out)
        end
    end
end

---Print `value<TAB>label` for each value the next word of the command can take.
---
---`ctx.args` holds the words from the command up to the one being typed. A card id completes after
---a `dev board` subcommand that takes one, a box or connectable name after `dev box` and
---`dev connect`, and a run id after `--run`.
---@param ctx dev.Ctx the context
---@return integer code 0, with no output when nothing completes
function M.args(ctx)
    local words = ctx.args
    if words[#words] == "--run" then
        print_ci({ "runs" })
    elseif words[1] == "connect" and #words == 1 then
        print_ci(CONNECT_KINDS)
    elseif words[1] == "box" and #words == 2 and BOX_SUBS[words[2]] then
        print_ci(BOX_SUBS[words[2]])
    elseif words[1] == "board" and #words == 2 and CARD_SUBS[words[2]] then
        print_cards(ctx.root)
    end
    return 0
end

---Print each problem the topic check finds as `file:line: message` on standard error.
---
---It loads its own registry with the header warnings silenced, since the check
---reports a reserved flag in a flags line as a problem and not as a warning.
---@param ctx dev.Ctx the context
---@return integer code 1 when there is a problem, else 0
function M.check_topics(ctx)
    local reg = registry.load(ctx.root, { warn = function() end })
    local problems = topics.check(reg)
    for _, found in ipairs(problems) do
        stderr:write(found.file, ":", found.line, ": ", found.message, "\n")
    end
    return #problems > 0 and 1 or 0
end

return M
