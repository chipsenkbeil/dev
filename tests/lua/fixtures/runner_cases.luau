local testing = require("@dev/testing")

testing.test("alpha case", function()
    testing.eq(1, 1)
end)

testing.test("beta case", function()
    testing.eq(2, 2)
end)
