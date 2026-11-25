-- Run a released binary on the target the run names
local CARGO = "export PATH=$HOME/.cargo/bin:$PATH; "

local function posix(tag)
    ci.sh(CARGO .. "cargo build --locked", { title = "Build dev" })
    local verify = "./target/debug/dev release verify " .. tag
    if ci.target:find("^freebsd") then
        verify = "su freebsd -c '" .. verify .. "'"
    end
    ci.sh(CARGO .. verify, { title = "Verify the release" })
end

local function windows(tag)
    ci.sh("set RUSTC_WRAPPER=&& cargo build --locked", { title = "Build dev" })
    ci.sh("target\\debug\\dev.exe release verify " .. tag, { title = "Verify the release" })
end

return {
    jobs = {
        verify = {
            title = "Verify the release on ${target} ${arch}",
            matrix = { { arch = "x86_64" }, { arch = "aarch64" } },
            run = function()
                if #ci.args ~= 1 then
                    error(
                        "Name the release tag after --, as in: ci run .ci/verify.lua --local -- v0.1.0"
                    )
                end
                if ci.target:find("^windows") then
                    windows(ci.args[1])
                else
                    posix(ci.args[1])
                end
            end,
        },
    },
}
