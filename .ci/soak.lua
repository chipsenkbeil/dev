-- Loop the signal tests beside CPU burners
local CARGO = "export PATH=$HOME/.cargo/bin:$PATH; "

local PACMAN_PACKAGES = "git jujutsu bats dash stow ripgrep fd sd man-db zsh unzip util-linux"

return {
    jobs = {
        soak = {
            name = "soak on ${target}",
            run = function()
                ci.sh(
                    "missing=$(pacman -T "
                        .. PACMAN_PACKAGES
                        .. ") || sudo pacman -Syu --noconfirm --needed $missing",
                    { name = "install packages" }
                )
                ci.sh(CARGO .. "cargo build --locked", { name = "build dev" })
                ci.sh({ "./target/debug/dev", "soak", table.unpack(ci.args) }, { name = "soak" })
            end,
        },
    },
}
