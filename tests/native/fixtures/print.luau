local shown = setmetatable({}, {
    __tostring = function()
        return "shown"
    end,
})
print(1, nil, true, shown)
