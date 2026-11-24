local testing = require("@dev/testing")
local projmod = require("@lib/projmod")

testing.test("the project library loads", function()
    testing.eq(projmod.code, 3)
end)

testing.test("a failing case fails the run", function()
    testing.eq(projmod.code, 4)
end)
