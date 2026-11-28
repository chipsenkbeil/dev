-- Lint and test dev on trunk after each landing, as a change run does
local CARGO = "export PATH=$HOME/.cargo/bin:$PATH; "
local NIGHTLY_RUSTFMT =
    "cargo +nightly fmt --version || rustup toolchain install nightly --profile minimal -c rustfmt"
local PACMAN_PACKAGES =
    "git jujutsu bats shellcheck shfmt stylua selene luau ast-grep jq go-yq dash stow ripgrep fd sd man-db zsh fish unzip"
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
                ci.sh(CARGO .. "./target/debug/dev test </dev/null", { name = "test" })
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
                    real_root("tests/dev/root_test.sh", "root test")
                    real_root("tests/dev/tools_test.sh", "tools test")
                end)
            end,
        },
    },
}
