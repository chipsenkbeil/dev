local fs = require("@dev/fs")
local runtime = require("@dev/runtime")
local testing = require("@dev/testing")

---@class dev.testrun
local M = {}

local ran = {}

local function run_case(case)
    ran[case] = true
    local ok, err = pcall(case.fn)
    if ok then
        print("ok - " .. case.name)
        return 0
    end
    print("not ok - " .. case.name)
    print("    " .. tostring(err))
    return 1
end

---Run the registered cases from the one after `from` and print each result.
---@param from integer how many cases to skip, as counted in registration order
---@param only string? keep the cases whose name contains this text
---@return integer failed how many cases raised
function M.execute(from, only)
    local failed = 0
    for index, case in ipairs(testing.tests()) do
        if index > from and (not only or case.name:find(only, 1, true)) then
            failed += run_case(case)
        else
            ran[case] = true
        end
    end
    return failed
end

---Run the cases a file run with `dev -l` registered and did not already run, after the file has finished.
---@return integer? code 1 when a case failed, 0 when all passed, nil when no case was left to run
function M.finish()
    local pending = false
    local failed = 0
    for _, case in ipairs(testing.tests()) do
        if not ran[case] then
            pending = true
            failed += run_case(case)
        end
    end
    if not pending then
        return nil
    end
    return if failed == 0 then 0 else 1
end

---Run every `*_test.luau` file under a project's `.dev/tests`.
---@param root string absolute path of the project root
---@return integer code 1 when a case failed or a file failed to load, else 0
function M.run(root)
    local dir = root .. "/.dev/tests"
    if not fs.is_dir(dir) then
        print("SKIP .dev/tests (none)")
        return 0
    end
    local names, message = fs.list(dir)
    if not names then
        print("not ok - list .dev/tests")
        print("    " .. tostring(message))
        return 1
    end
    local failed = 0
    for _, name in ipairs(names) do
        if name:find("_test%.luau$") then
            local from = #testing.tests()
            local ok, err = pcall(runtime.dofile, dir .. "/" .. name)
            if ok then
                failed = failed + M.execute(from)
            else
                failed = failed + 1
                print("not ok - load " .. name)
                print("    " .. tostring(err))
            end
        end
    end
    return if failed == 0 then 0 else 1
end

return M
