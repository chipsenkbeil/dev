-- Run each job on the macOS target
local CARGO = "export PATH=$HOME/.cargo/bin:$PATH; "
local NIGHTLY_RUSTFMT =
    "cargo +nightly fmt --version || rustup toolchain install nightly --profile minimal -c rustfmt"
local BREW_PACKAGES = "jj bats-core jq yq stow sd"

local BATS_SUITES = {
    "tests/dev/confirm.bats",
    "tests/dev/picker.bats",
    "tests/dev/term.bats",
}

local SCRIPT_SUITES = {
    "tests/dev/launcher_test.sh",
}

local LUA_SUITES = {
    "tests/lua/os_test.luau",
    "tests/lua/term_test.luau",
}

return {
    jobs = {
        targets = {
            name = "Build the release binary on ${target}",
            matrix = { { arch = "aarch64" } },
            run = function()
                local triple = "aarch64-apple-darwin"
                ci.sh(
                    CARGO .. "rustup target add " .. triple,
                    { name = "Add the " .. triple .. " target" }
                )
                ci.sh(
                    CARGO .. "cargo build --locked --release --target " .. triple,
                    { name = "Build for " .. triple }
                )
                local binary = "target/" .. triple .. "/release/dev"
                ci.sh(
                    "file "
                        .. binary
                        .. " && ls -l "
                        .. binary
                        .. " && "
                        .. binary
                        .. " -l tests/native/runtime_test.luau",
                    { name = "Run the native suite on the release binary" }
                )
                ci.artifact(binary)
            end,
        },
        build = {
            name = "Format, lint and test the crate on ${target}",
            matrix = { { arch = "aarch64" } },
            run = function()
                ci.sh(CARGO .. NIGHTLY_RUSTFMT, { name = "Find a nightly rustfmt" })
                ci.sh(CARGO .. "cargo +nightly fmt --check", { name = "Check the formatting" })
                ci.sh(CARGO .. "cargo build --locked", { name = "Build for aarch64-apple-darwin" })
                ci.sh(
                    CARGO .. "cargo clippy --locked --all-targets -- -D warnings",
                    { name = "Run clippy" }
                )
                ci.sh(CARGO .. "cargo test --locked", { name = "Run the Rust tests" })
            end,
        },
        test = {
            name = "test on ${target}",
            matrix = { { arch = "aarch64" } },
            run = function()
                ci.sh(
                    "HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet " .. BREW_PACKAGES,
                    { name = "install packages" }
                )
                ci.sh(CARGO .. "cargo build --locked", { name = "build dev" })
                for _, file in ipairs(BATS_SUITES) do
                    ci.sh(
                        "DEV_BIN=$PWD/target/debug/dev bats --tap " .. file .. " </dev/null",
                        { name = "test " .. file }
                    )
                end
                for _, file in ipairs(SCRIPT_SUITES) do
                    ci.sh(
                        "DEV_BIN=$PWD/target/debug/dev bash " .. file .. " </dev/null",
                        { name = "test " .. file }
                    )
                end
                for _, file in ipairs(LUA_SUITES) do
                    ci.sh(
                        "./target/debug/dev -l tests/lua/run.luau " .. file .. " </dev/null",
                        { name = "test " .. file }
                    )
                end
            end,
        },
    },
}
