local M = { name = "calls" }

function M.one()
    return 1
end

function M.twice(n)
    return n * 2, n
end

return M
