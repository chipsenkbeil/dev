local testing = require("@dev/testing")
local pipelines = require("@dev/pipelines")

testing.test("the base pipeline runs on the target it is given", function()
    local text = pipelines.jobs(false, "linux-x86-dev")
    testing.ok(text:find('target = "linux-x86-dev"', 1, true), text)
    testing.eq(text:find("@TARGET@", 1, true), nil)
end)

testing.test("the rust pipeline runs on the target it is given", function()
    local text = pipelines.jobs(true, "linux-x86-rust")
    testing.ok(text:find('target = "linux-x86-rust"', 1, true), text)
    testing.eq(text:find("@TARGET@", 1, true), nil)
end)

testing.test("a pipeline with no target gets the TARGET placeholder", function()
    for _, rust in ipairs({ false, true }) do
        local text = pipelines.jobs(rust)
        testing.ok(text:find('target = "TARGET"', 1, true), text)
    end
end)
