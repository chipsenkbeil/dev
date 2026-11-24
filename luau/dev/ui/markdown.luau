local text = require("dev.text")
local ui = require("dev.ui")

local Style = ui.Style
local INDENT = "  "
local MIN_CELL = 8
local BULLET = "•"
local DEFAULT_WIDTH = 80

---@class dev.ui.markdown.Opts
---@field width integer? columns a line may fill, DEFAULT_WIDTH when absent
---@field color boolean? whether to paint the text, false when absent

local function inline_words(ctx, source, base)
    local segments, i, plain = {}, 1, {}
    local function flush()
        if #plain > 0 then
            segments[#segments + 1] = { table.concat(plain), base }
            plain = {}
        end
    end
    while i <= #source do
        local ch = source:sub(i, i)
        local close
        if ch == "`" then
            close = source:find("`", i + 1, true)
            if close then
                flush()
                segments[#segments + 1] = { source:sub(i + 1, close - 1), Style.CYAN, base }
                i = close + 1
            end
        elseif source:sub(i, i + 1) == "**" then
            close = source:find("**", i + 2, true)
            if close then
                flush()
                local body = source:sub(i + 2, close - 1)
                local at = 1
                while at <= #body do
                    local open = body:find("`", at, true)
                    local shut = open and body:find("`", open + 1, true)
                    if not shut then
                        segments[#segments + 1] = { body:sub(at), Style.BOLD, base }
                        break
                    end
                    if open > at then
                        segments[#segments + 1] = { body:sub(at, open - 1), Style.BOLD, base }
                    end
                    segments[#segments + 1] =
                        { body:sub(open + 1, shut - 1), Style.CYAN, Style.BOLD, base }
                    at = shut + 1
                end
                i = close + 2
            end
        end
        if not close then
            plain[#plain + 1] = ch
            i = i + 1
        end
    end
    flush()

    local words, word = {}, {}
    local function end_word()
        if #word > 0 then
            words[#words + 1] = table.concat(word)
            word = {}
        end
    end
    for _, segment in ipairs(segments) do
        local body = segment[1]
        for gap, run in body:gmatch("(%s*)(%S*)") do
            if gap ~= "" then
                end_word()
            end
            if run ~= "" then
                word[#word + 1] = segment[2] and ui.paint(ctx, run, table.unpack(segment, 2)) or run
            end
        end
    end
    end_word()
    return words
end

local function split_row(line)
    local cells, cell, in_code, i = {}, {}, false, 1
    line = text.trim(line:match("^%s*(.*)$"))
    if line:sub(1, 1) == "|" then
        line = line:sub(2)
    end
    if line:sub(-1) == "|" and line:sub(-2, -2) ~= "\\" then
        line = line:sub(1, -2)
    end
    while i <= #line do
        local ch = line:sub(i, i)
        if ch == "\\" and line:sub(i + 1, i + 1) == "|" then
            cell[#cell + 1] = "|"
            i = i + 1
        elseif ch == "`" then
            in_code = not in_code
            cell[#cell + 1] = ch
        elseif ch == "|" and not in_code then
            cells[#cells + 1] = text.trim(table.concat(cell):match("^%s*(.*)$"))
            cell = {}
        else
            cell[#cell + 1] = ch
        end
        i = i + 1
    end
    cells[#cells + 1] = text.trim(table.concat(cell):match("^%s*(.*)$"))
    return cells
end

local function is_rule(cells)
    for _, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then
            return false
        end
    end
    return #cells > 0
end

local function shrink(natural, longest, budget)
    local widths = {}
    for i, w in ipairs(natural) do
        widths[i] = w
    end
    local function total()
        local sum = #widths > 0 and (#widths - 1) * #text.GAP or 0
        for _, w in ipairs(widths) do
            sum = sum + w
        end
        return sum
    end
    while total() > budget do
        local pick
        for i, w in ipairs(widths) do
            if w > math.max(MIN_CELL, longest[i]) and (not pick or w > widths[pick]) then
                pick = i
            end
        end
        if not pick then
            break
        end
        widths[pick] = widths[pick] - 1
    end
    return widths
end

local function render_table(ctx, rows, width, out)
    local header = rows[1]
    local body = {}
    for i = 2, #rows do
        if not (i == 2 and is_rule(rows[i])) then
            body[#body + 1] = rows[i]
        end
    end
    local all = { header }
    for _, row in ipairs(body) do
        all[#all + 1] = row
    end

    local columns = 0
    for _, row in ipairs(all) do
        columns = math.max(columns, #row)
    end
    local cells, natural, longest = {}, {}, {}
    for r, row in ipairs(all) do
        cells[r] = {}
        for c = 1, columns do
            local words = inline_words(ctx, row[c] or "", r == 1 and Style.BOLD or nil)
            cells[r][c] = words
            local w = text.width(table.concat(words, " "))
            natural[c] = math.max(natural[c] or 0, w)
            for _, word in ipairs(words) do
                longest[c] = math.max(longest[c] or 0, text.width(word))
            end
        end
    end
    local widths = shrink(natural, longest, width - #INDENT)

    local function emit(r)
        local wrapped, height = {}, 1
        for c = 1, columns do
            local words = cells[r][c]
            wrapped[c] = text.wrap(words, widths[c])
            height = math.max(height, #wrapped[c])
        end
        for h = 1, height do
            local parts = {}
            for c = 1, columns do
                local s = wrapped[c][h] or ""
                local pad = c < columns and string.rep(" ", widths[c] - text.width(s)) or ""
                parts[#parts + 1] = s .. pad
            end
            out[#out + 1] = INDENT .. text.trim(table.concat(parts, text.GAP))
        end
    end
    emit(1)
    for r = 2, #all do
        emit(r)
    end
end

local function is_fence(line)
    return line:match("^%s*```") ~= nil
end

local function list_item(line)
    local lead, marker, rest = line:match("^(%s*)([-*+])%s+(.*)$")
    if not lead then
        lead, marker, rest = line:match("^(%s*)(%d+[.)])%s+(.*)$")
    end
    return lead, marker, rest
end

local function starts_block(line)
    return line:match("^%s*$") ~= nil
        or is_fence(line)
        or line:match("^#+%s") ~= nil
        or line:match("^%s*|") ~= nil
        or list_item(line) ~= nil
end

---Turn Markdown into text for a terminal.
---
---Headings and bold become bold, inline code cyan with no backticks, lists keep
---their indent, pipe tables line up to their widest cells and wrap inside a
---cell when the terminal is narrower, prose wraps at the width and fenced code
---never does. With `color` off the markers still go and nothing is painted.
---@param source string the Markdown text
---@param opts dev.ui.markdown.Opts? the width and whether to paint
---@return string rendered the styled text, ending in a newline unless empty
local function render(source, opts)
    opts = opts or {}
    local width = opts.width or DEFAULT_WIDTH
    local ctx = { color = opts.color == true }
    local lines = {}
    for line in (source .. "\n"):gmatch("(.-)\r?\n") do
        lines[#lines + 1] = line
    end
    if lines[#lines] == "" then
        lines[#lines] = nil
    end

    local blocks, i = {}, 1
    local function add(block_lines)
        blocks[#blocks + 1] = block_lines
    end
    while i <= #lines do
        local line = lines[i]
        local out = {}
        if line:match("^%s*$") then
            i = i + 1
        elseif is_fence(line) then
            i = i + 1
            while i <= #lines and not is_fence(lines[i]) do
                out[#out + 1] = INDENT .. ui.paint(ctx, lines[i], Style.CYAN)
                i = i + 1
            end
            i = i + 1
            if #out > 0 then
                add(out)
            end
        elseif line:match("^#+%s") then
            local title = line:match("^#+%s+(.-)%s*$")
            local words = inline_words(ctx, title, Style.BOLD)
            out[1] = table.concat(words, " ")
            i = i + 1
            add(out)
        elseif line:match("^%s*|") then
            local rows = {}
            while i <= #lines and lines[i]:match("^%s*|") do
                rows[#rows + 1] = split_row(lines[i])
                i = i + 1
            end
            render_table(ctx, rows, width, out)
            add(out)
        elseif list_item(line) then
            while i <= #lines and list_item(lines[i]) do
                local lead, marker, rest = list_item(lines[i])
                i = i + 1
                while i <= #lines and not starts_block(lines[i]) and lines[i]:match("^%s") do
                    rest = rest .. " " .. lines[i]:match("^%s*(.-)$")
                    i = i + 1
                end
                local glyph = marker:match("^%d") and marker or BULLET
                local prefix = INDENT .. lead .. glyph .. " "
                local hang = string.rep(" ", text.width(prefix))
                local wrapped = text.wrap(inline_words(ctx, rest), math.max(width - #hang, 1))
                for n, piece in ipairs(wrapped) do
                    out[#out + 1] = (n == 1 and prefix or hang) .. piece
                end
                if #wrapped == 0 then
                    out[#out + 1] = text.trim(prefix)
                end
            end
            add(out)
        else
            local joined = {}
            while i <= #lines and not starts_block(lines[i]) do
                joined[#joined + 1] = lines[i]
                i = i + 1
            end
            add(text.wrap(inline_words(ctx, table.concat(joined, " ")), width))
        end
    end

    local rendered = {}
    for _, block in ipairs(blocks) do
        if #rendered > 0 then
            rendered[#rendered + 1] = ""
        end
        for _, line in ipairs(block) do
            rendered[#rendered + 1] = line
        end
    end
    if #rendered == 0 then
        return ""
    end
    return table.concat(rendered, "\n") .. "\n"
end

return render
