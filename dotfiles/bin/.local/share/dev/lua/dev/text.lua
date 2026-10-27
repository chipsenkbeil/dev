local ESCAPE = "\27%[[%d;]*m"

---@class dev.text
---@field GAP string space between table columns
local M = {
    GAP = "  ",
}

local function is_continuation(byte)
    return byte >= 0x80 and byte < 0xC0
end

---Count the codepoints `s` shows, leaving out color escapes.
---@param s string text that may hold UTF-8 and SGR escapes
---@return integer columns number of display columns, taking each codepoint as one
function M.width(s)
    local plain = s:gsub(ESCAPE, "")
    local n = 0
    for i = 1, #plain do
        if not is_continuation(plain:byte(i)) then
            n = n + 1
        end
    end
    return n
end

---Cut `s` to `width` columns, ending in an ellipsis when it is cut.
---
---Color escapes are kept so a cut line still resets its colors.
---@param s string text that may hold UTF-8 and SGR escapes
---@param width integer columns to keep
---@return string fitted `s` itself when it already fits
function M.fit(s, width)
    if M.width(s) <= width then
        return s
    end
    local out, seen, i = {}, 0, 1
    while i <= #s do
        local esc = s:match("^" .. ESCAPE, i)
        if esc then
            out[#out + 1] = esc
            i = i + #esc
        else
            local j = i + 1
            while j <= #s and is_continuation(s:byte(j)) do
                j = j + 1
            end
            if seen < width - 1 then
                out[#out + 1] = s:sub(i, j - 1)
                seen = seen + 1
            elseif seen == width - 1 then
                out[#out + 1] = "…"
                seen = seen + 1
            end
            i = j
        end
    end
    return table.concat(out)
end

---Cut the whitespace off the end of a string.
---@param s string the text
---@return string trimmed the text without trailing whitespace
function M.trim(s)
    return (s:gsub("%s+$", ""))
end

---Tell whether a list holds a value.
---@param list any[] the list
---@param want any the value to look for
---@return boolean found whether the list has it
function M.contains(list, want)
    for _, item in ipairs(list) do
        if item == want then
            return true
        end
    end
    return false
end

return M
