local testing = require("@dev/testing")
local markdown = require("@dev/ui/markdown")
local text = require("@dev/text")

local DOC = table.concat({
    "# demo: a topic",
    "",
    "Prose with **bold** and `code` that is long enough to wrap at forty columns.",
    "",
    "## Steps",
    "",
    "- first with `x`",
    "  continued here",
    "  - nested item",
    "1. one",
    "2. two",
    "",
    "| Name | Does |",
    "|---|---|",
    "| `a` | short |",
    "| `bb` | A longer description that has to wrap inside its cell |",
    "",
    "```",
    'dev board add "a fenced line that is never wrapped, however long it is"',
    "```",
    "",
}, "\n")

testing.test("plain rendering drops the markers and wraps prose and cells", function()
    local want = table.concat({
        "demo: a topic",
        "",
        "Prose with bold and code that is long",
        "enough to wrap at forty columns.",
        "",
        "Steps",
        "",
        "  • first with x continued here",
        "    • nested item",
        "  1. one",
        "  2. two",
        "",
        "  Name  Does",
        "  a     short",
        "  bb    A longer description that has to",
        "        wrap inside its cell",
        "",
        '  dev board add "a fenced line that is never wrapped, however long it is"',
        "",
    }, "\n")
    testing.eq(markdown(DOC, { width = 40, color = false }), want)
end)

testing.test("colour rendering paints headings, bold, code and the table header", function()
    local want = table.concat({
        "\27[1mdemo:\27[0m \27[1ma\27[0m \27[1mtopic\27[0m",
        "",
        "Prose with \27[1mbold\27[0m and \27[36mcode\27[0m that is long",
        "enough to wrap at forty columns.",
        "",
        "\27[1mSteps\27[0m",
        "",
        "  • first with \27[36mx\27[0m continued here",
        "    • nested item",
        "  1. one",
        "  2. two",
        "",
        "  \27[1mName\27[0m  \27[1mDoes\27[0m",
        "  \27[36ma\27[0m     short",
        "  \27[36mbb\27[0m    A longer description that has to",
        "        wrap inside its cell",
        "",
        '  \27[36mdev board add "a fenced line that is never wrapped, however long it is"\27[0m',
        "",
    }, "\n")
    testing.eq(markdown(DOC, { width = 40, color = true }), want)
end)

testing.test("a fenced line is never wrapped and prose never passes the width", function()
    local out = markdown(DOC, { width = 40, color = false })
    for line in out:gmatch("[^\n]+") do
        if not line:find("dev board add", 1, true) then
            testing.ok(text.width(line) <= 40, line)
        end
    end
end)

testing.test("a table narrower than the width keeps one line per row", function()
    local out =
        markdown(table.concat({ "| a | b |", "|---|---|", "| 1 | 2 |", "" }, "\n"), { width = 80 })
    testing.eq(out, table.concat({ "  a  b", "  1  2", "" }, "\n"))
end)

testing.test("empty text renders to nothing", function()
    testing.eq(markdown("", {}), "")
end)

testing.test("code inside bold, an escaped pipe and an empty fence render cleanly", function()
    local source = table.concat({
        "**use `dev help` now**",
        "",
        "```",
        "```",
        "",
        "| a | b |",
        "|---|---|",
        "| x\\|y | `p|q` |",
        "",
    }, "\n")
    local want = table.concat({
        "\27[1muse\27[0m \27[36m\27[1mdev\27[0m \27[36m\27[1mhelp\27[0m \27[1mnow\27[0m",
        "",
        "  \27[1ma\27[0m    \27[1mb\27[0m",
        "  x|y  \27[36mp|q\27[0m",
        "",
    }, "\n")
    local out = markdown(source, {
        width = 80,
        color = true,
    })
    testing.eq(out, want)
end)
