local t = require("dev.testing")
local ui = require("dev.ui")

local plain = ui.context({ color = false, interactive = false, width = 80 })

t.test("spinner_line joins glyph, label, detail and elapsed time", function()
    t.eq(
        ui.spinner_line(plain, {
            frame = 5,
            label = "Creating myproject-wqz",
            detail = "cloning myproject",
            seconds = 41,
        }),
        "⠼ Creating myproject-wqz · cloning myproject 0:41"
    )
end)

t.test("spinner_line wraps the frame after the tenth", function()
    t.eq(
        ui.spinner_line(plain, { frame = 11, label = "x", detail = "y", seconds = 0 }),
        "⠋ x · y 0:00"
    )
end)

t.test("spinner_line drops the separator when there is no detail", function()
    t.eq(
        ui.spinner_line(plain, { frame = 1, label = "x", detail = "", seconds = 75 }),
        "⠋ x 1:15"
    )
end)

t.test("spin without a terminal returns the exit code", function()
    t.eq(ui.spin(plain, "x", { "sh", "-c", "exit 4" }), 4)
end)

t.test("spin with capture and no terminal returns the code and standard output", function()
    local code, out = ui.spin(plain, "x", { "sh", "-c", "echo hi; echo no >&2; exit 4" }, {
        capture = true,
    })
    t.eq(code, 4)
    t.eq(out, "hi\n")
end)
