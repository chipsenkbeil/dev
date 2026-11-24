-- Run each job on the Arch Linux target
local CARGO = "export PATH=$HOME/.cargo/bin:$PATH; "
local RELEASE_TAG = "DEV_RELEASE_TAG=$(git describe --tags --exact-match 2>/dev/null) "
local NIGHTLY_RUSTFMT =
    "cargo +nightly fmt --version || rustup toolchain install nightly --profile minimal -c rustfmt"
local PACMAN_PACKAGES =
    "git jujutsu bats shellcheck shfmt stylua selene ast-grep jq go-yq dash stow ripgrep fd sd man-db zsh unzip"
local ROOT_CLONE = "/root/dev"

local function real_root(file, name)
    local run = "sudo bash -c 'cd "
        .. ROOT_CLONE
        .. " && bash "
        .. file
        .. " </dev/null' >$log 2>&1"
    local check = "if grep -q '^SKIP real-root' $log; then echo 'a real-root case skipped in "
        .. file
        .. "'; exit 1; fi"
    ci.sh(
        "log=$(mktemp); "
            .. run
            .. "; status=$?; cat $log; [ $status -eq 0 ] || exit $status; "
            .. check,
        { name = name }
    )
end

local function shell_quote(word)
    return "'" .. (word:gsub("'", "'\\''")) .. "'"
end

local function selects(file)
    if #ci.args == 0 then
        return true
    end
    for _, arg in ipairs(ci.args) do
        local path = arg:gsub("^%./", ""):gsub("/+$", "")
        if file == path or file:sub(1, #path + 1) == path .. "/" then
            return true
        end
    end
    return false
end

local function prepare()
    ci.sh(
        "command -v pacman >/dev/null || { echo 'This pipeline installs its tools with pacman. Set default_target to an Arch Linux target.'; exit 1; }",
        { name = "check pacman" }
    )
    ci.sh(
        "missing=$(pacman -T "
            .. PACMAN_PACKAGES
            .. ") || sudo pacman -Syu --noconfirm --needed $missing",
        { name = "install packages" }
    )
end

return {
    jobs = {
        lock = {
            name = "Update Cargo.lock for a changed manifest on ${target}",
            run = function()
                ci.sh(CARGO .. "cargo fetch", { name = "Resolve the new dependencies" })
                ci.artifact("Cargo.lock")
            end,
        },
        rustfmt = {
            name = "Format the crate on ${target}",
            run = function()
                ci.sh(
                    CARGO .. "rustup toolchain list; " .. NIGHTLY_RUSTFMT,
                    { name = "Find a nightly rustfmt" }
                )
                ci.sh(
                    CARGO .. "cargo +nightly fmt && tar czf formatted.tgz build.rs src tests/*.rs",
                    { name = "Format the Rust" }
                )
                ci.artifact("formatted.tgz")
            end,
        },
        stylua = {
            name = "Format the Luau on ${target}",
            run = function()
                ci.sh(
                    "command -v stylua || sudo pacman -S --noconfirm --needed stylua",
                    { name = "Find stylua" }
                )
                ci.sh(
                    "stylua luau tests && tar czf stylua.tgz luau tests",
                    { name = "Format the Luau" }
                )
                ci.artifact("stylua.tgz")
            end,
        },
        snapshots = {
            name = "Rewrite the help snapshots on ${target}",
            run = function()
                ci.sh(CARGO .. "cargo build --locked", { name = "Build" })
                ci.sh(
                    "UPDATE_SNAPSHOTS=1 bash tests/dev/help_test.sh </dev/null >snapshots.log; rc=$?; cat snapshots.log; "
                        .. "[ $rc -le 1 ] && tail -n 1 snapshots.log | grep -q ' failed$'",
                    { name = "Rewrite the snapshots" }
                )
                ci.sh(
                    "tar czf snapshots.tgz tests/dev/fixtures/help-snapshots",
                    { name = "Pack the snapshots" }
                )
                ci.artifact("snapshots.tgz")
            end,
        },
        bench = {
            name = "Measure the interrupt hook on ${target}",
            run = function()
                ci.sh(
                    CARGO .. "cargo test --locked --release --test bench -- --ignored --nocapture",
                    { name = "Run the benchmark" }
                )
            end,
        },
        targets = {
            name = "Build the release binary on ${target}",
            run = function()
                local triple = "x86_64-unknown-linux-musl"
                ci.sh(
                    CARGO .. "rustup target add " .. triple,
                    { name = "Add the " .. triple .. " target" }
                )
                ci.sh(
                    CARGO .. RELEASE_TAG .. "cargo zigbuild --locked --release --target " .. triple,
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
            run = function()
                ci.sh(CARGO .. NIGHTLY_RUSTFMT, { name = "Find a nightly rustfmt" })
                ci.sh(CARGO .. "cargo +nightly fmt --check", { name = "Check the formatting" })
                ci.sh(
                    "command -v stylua || sudo pacman -S --noconfirm --needed stylua",
                    { name = "Find stylua" }
                )
                ci.sh("stylua --check luau tests", { name = "Check the Luau formatting" })
                ci.sh(CARGO .. "cargo build --locked", { name = "Build" })
                ci.sh(
                    CARGO .. "cargo clippy --locked --all-targets -- -D warnings",
                    { name = "Run clippy" }
                )
                ci.sh(CARGO .. "cargo test --locked", { name = "Run the Rust tests" })
                ci.sh(
                    "mv luau luau.away && ./target/debug/dev -l tests/native/runtime_test.luau; status=$?; mv luau.away luau; exit $status",
                    { name = "Run the native suite with no luau folder" }
                )
                local triple = "x86_64-unknown-linux-musl"
                ci.sh(
                    CARGO
                        .. "rustup target add "
                        .. triple
                        .. " && cargo zigbuild --locked --target "
                        .. triple,
                    { name = "Build the static binary" }
                )
                local binary = "target/" .. triple .. "/debug/dev"
                ci.sh(
                    "file " .. binary .. " && " .. binary .. " -l tests/native/runtime_test.luau",
                    { name = "Run the static binary in the container" }
                )
                ci.artifact("Cargo.lock")
            end,
        },
        lint = {
            name = "lint on ${target}",
            run = function()
                prepare()
                ci.sh(CARGO .. NIGHTLY_RUSTFMT, { name = "Find a nightly rustfmt" })
                ci.sh(CARGO .. "cargo build --locked", { name = "build" })
                ci.sh(CARGO .. "./target/debug/dev lint </dev/null", { name = "lint" })
            end,
        },
        test = {
            name = "test on ${target}",
            run = function()
                prepare()
                ci.sh(CARGO .. "cargo build --locked --bins --examples", { name = "build" })
                local command = "./target/debug/dev test"
                for _, word in ipairs(ci.args) do
                    command = command .. " " .. shell_quote(word)
                end
                ci.sh(CARGO .. command .. " </dev/null", { name = "test" })
                local root_files = {}
                for _, entry in ipairs({
                    { file = "tests/dev/root_test.sh", name = "root test" },
                    { file = "tests/dev/tools_test.sh", name = "tools test" },
                }) do
                    if selects(entry.file) then
                        root_files[#root_files + 1] = entry
                    end
                end
                if #root_files == 0 then
                    return
                end
                ci.group("Real root", function()
                    ci.sh(
                        "sudo rm -rf " .. ROOT_CLONE .. ' && sudo cp -a "$PWD" ' .. ROOT_CLONE,
                        { name = "copy clone" }
                    )
                    ci.sh(
                        "sudo chown -R root:root "
                            .. ROOT_CLONE
                            .. " && sudo chmod -R go-w "
                            .. ROOT_CLONE,
                        { name = "chown clone" }
                    )
                    for _, entry in ipairs(root_files) do
                        real_root(entry.file, entry.name)
                    end
                end)
            end,
        },
    },
}
